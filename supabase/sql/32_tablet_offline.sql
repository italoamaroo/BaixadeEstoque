-- 32: confirmação offline no tablet, somente de lista previamente finalizada e pareada.
begin;
create table if not exists public.counter_offline_receipts (
 request_id uuid primary key, movement_id uuid not null unique references public.stock_movements(id),
 terminal_user_id uuid not null references public.profiles(id), signed_at timestamptz not null,
 received_at timestamptz not null default now(), signature_path text not null, authorized_version bigint not null
);
alter table public.counter_offline_receipts enable row level security;
revoke all on public.counter_offline_receipts from public,anon,authenticated;
grant select on public.counter_offline_receipts to authenticated;
drop policy if exists counter_offline_receipts_read on public.counter_offline_receipts;
create policy counter_offline_receipts_read on public.counter_offline_receipts for select to authenticated using (
 public.is_active_user() and ((terminal_user_id=auth.uid() and exists(select 1 from public.counter_sessions cs where cs.movement_id=counter_offline_receipts.movement_id and cs.terminal_user_id=auth.uid() and public.is_terminal_of_warehouse(cs.warehouse_id))) or (public.has_any_role(array['almoxarife','gestor','admin']::public.app_role[]) and public.can_access_movement(movement_id))));
drop trigger if exists counter_offline_receipts_immutable on public.counter_offline_receipts;
create trigger counter_offline_receipts_immutable before update or delete on public.counter_offline_receipts for each row execute function public.tg_block_delete();
create or replace function public.counter_snapshot(p_movement_id uuid default null)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare
  v_s public.counter_sessions;
  v_m public.stock_movements;
begin
  if auth.uid() is null or not public.is_active_user() then
    raise exception 'Sessão inválida ou usuário inativo.' using errcode = '42501';
  end if;

  if p_movement_id is null then
    -- tablet: ME ativa pareada (ou a última confirmada/cancelada nos últimos 2 minutos)
    select * into v_s from public.counter_sessions
     where terminal_user_id = auth.uid()
       and (status in ('em_separacao', 'aguardando_confirmacao') or last_event_at > now() - interval '2 minutes')
     order by (status in ('em_separacao', 'aguardando_confirmacao')) desc, last_event_at desc
     limit 1;
    if v_s.id is null then
      return null;
    end if;
  else
    select * into v_s from public.counter_sessions where movement_id = p_movement_id;
    if v_s.id is null then
      raise exception 'Separação não encontrada.' using errcode = 'P0002';
    end if;
    if not (v_s.opened_by = auth.uid() or v_s.terminal_user_id = auth.uid()
            or (public.has_any_role(array['gestor', 'admin']::public.app_role[]) and public.can_access_warehouse(v_s.warehouse_id))) then
      raise exception 'Separação não encontrada.' using errcode = 'P0002';
    end if;
  end if;

  select * into v_m from public.stock_movements where id = v_s.movement_id;

  return jsonb_build_object(
    'session', jsonb_build_object(
      'offline_ready', true, 'id', v_s.id, 'status', v_s.status, 'version', v_s.version, 'last_event', v_s.last_event,
      'last_event_at', v_s.last_event_at, 'terminal_paired', v_s.terminal_user_id is not null,
      'paired_at', v_s.paired_at,
      -- o código só é mostrado ao almoxarife/gestor
      'pairing_code', case when v_s.terminal_user_id = auth.uid() then null else v_s.pairing_code end,
      'pairing_expires_at', v_s.pairing_expires_at,
      'terminal_name', (select coalesce(full_name, email) from public.profiles where id = v_s.terminal_user_id)
    ),
    'movement', jsonb_build_object(
      'id', v_m.id, 'me_number', v_m.me_number, 'status', v_m.status,
      'warehouse_id', v_m.warehouse_id, 'warehouse_name', (select name from public.warehouses where id = v_m.warehouse_id),
      'warehouse_code', (select code from public.warehouses where id = v_m.warehouse_id),
      'requester_name', v_m.requester_name, 'requester_registration', v_m.requester_registration,
      'storekeeper_name', (select coalesce(full_name, email) from public.profiles where id = v_m.storekeeper_id),
      'movement_at', v_m.movement_at, 'separation_finished_at', v_m.separation_finished_at,
      'confirmed_at', v_m.confirmed_at, 'cancel_reason', v_m.cancel_reason,
      'item_count', v_m.item_count, 'total_delivered', v_m.total_delivered,
      'fixed_asset', v_m.fixed_asset_text,
      'is_rescue', v_m.is_rescue, 'is_emergency', v_m.is_emergency
    ),
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', i.id, 'line_number', i.line_number, 'material_code', i.material_code,
               'material_name', i.material_name, 'unit', i.unit,
               'quantity_requested', i.quantity_requested, 'quantity_delivered', i.quantity_delivered,
               'created_at', i.created_at, 'updated_at', i.updated_at) order by i.line_number)
        from public.stock_movement_items i where i.movement_id = v_m.id), '[]'::jsonb)
  );
end;
$$;
create or replace function public.counter_confirm(p_movement_id uuid, p_payload jsonb)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  s          public.app_settings := public.get_settings();
  v_m        public.stock_movements;
  v_s        public.counter_sessions;
  v_wh       public.warehouses;
  v_method   text := coalesce(p_payload ->> 'method', '');
  v_path     text;
  v_obj      record;
  v_att      public.confirmation_attempts;
  v_year     int;
  v_status   public.movement_status;
  v_now      timestamptz := now();
  v_photo    text := nullif(btrim(coalesce(p_payload ->> 'photo_path', '')), '');
  v_no_photo text := nullif(btrim(coalesce(p_payload ->> 'photo_skipped_reason', '')), '');
  v_pobj     record;
begin
  if auth.uid() is null or not public.is_active_user() then
    raise exception 'Sessão inválida ou usuário inativo.' using errcode = '42501';
  end if;

  select * into v_m from public.stock_movements where id = p_movement_id for update;
  select * into v_s from public.counter_sessions where movement_id = p_movement_id for update;
  if v_m.id is null or v_s.id is null or v_s.terminal_user_id is distinct from auth.uid() then
    raise exception 'Tablet não pareado com esta ME.' using errcode = '42501';
  end if;
  if v_m.confirmed_at is not null or v_s.status = 'confirmada' then
    raise exception 'A ME % já foi confirmada.', v_m.me_number using errcode = 'P0001';
  end if;
  if v_m.status = 'rascunho' then
    raise exception 'A separação ainda não foi finalizada pelo almoxarife.' using errcode = 'P0001';
  end if;
  if v_m.status <> 'aguardando_assinatura' then
    raise exception 'A ME % não pode ser confirmada (status: %).', v_m.me_number, v_m.status using errcode = 'P0001';
  end if;

  select * into v_wh from public.warehouses where id = v_m.warehouse_id;
  v_year := extract(year from (v_m.movement_at at time zone s.timezone))::int;

  -- Foto do solicitante (evidência da retirada; visível só para gestor/admin)
  if v_photo is not null then
    if v_photo not like v_wh.code || '/' || v_year::text || '/' || v_m.id::text || '/%' then
      raise exception 'Foto inválida para esta ME.' using errcode = '22023';
    end if;
    select o.name, nullif(o.metadata ->> 'size', '')::int as size_bytes,
           coalesce(o.metadata ->> 'mimetype', 'image/jpeg') as mime_type
      into v_pobj from storage.objects o where o.bucket_id = 'fotos-retirada' and o.name = v_photo;
    if v_pobj.name is null then
      raise exception 'Foto do solicitante não encontrada. Tire a foto novamente.' using errcode = '22023';
    end if;
  elsif v_no_photo is null and v_method = 'assinatura' then
    raise exception 'Tire a foto do solicitante antes de confirmar.' using errcode = '22023';
  end if;

  if v_method = 'assinatura' then
    v_path := nullif(btrim(coalesce(p_payload ->> 'signature_path', '')), '');
    if v_path is null or v_path not like v_wh.code || '/' || v_year::text || '/' || v_m.id::text || '/%' then
      raise exception 'Assinatura inválida para esta ME.' using errcode = '22023';
    end if;
    select o.name, nullif(o.metadata ->> 'size', '')::int as size_bytes,
           coalesce(o.metadata ->> 'mimetype', 'image/png') as mime_type
      into v_obj from storage.objects o where o.bucket_id = 'assinaturas' and o.name = v_path;
    if v_obj.name is null then
      raise exception 'Arquivo da assinatura não encontrado. Tente assinar novamente.' using errcode = '22023';
    end if;
    insert into public.confirmation_attempts (movement_id, employee_id, method, provider, result, consumed_at, detail)
    values (v_m.id, v_m.requester_employee_id, 'assinatura', 'assinatura_digital', 'sucesso', v_now,
            jsonb_build_object('storage_path', v_path, 'foto', v_photo, 'sem_foto_motivo', v_no_photo))
    returning * into v_att;
    insert into public.signatures (movement_id, employee_id, signer_name, signer_registration, bucket, storage_path,
                                   mime_type, size_bytes, signed_at, uploaded_by, is_current)
    values (v_m.id, v_m.requester_employee_id, v_m.requester_name, v_m.requester_registration, 'assinaturas', v_path,
            case when v_obj.mime_type in ('image/png', 'image/jpeg', 'image/webp') then v_obj.mime_type else 'image/png' end,
            v_obj.size_bytes, coalesce(nullif(current_setting('app.counter_offline_signed_at',true),'')::timestamptz,v_now), auth.uid(), true);
  elsif v_method = 'facial' then
    -- A verificação facial é gravada pelo servidor (Edge Function); aqui só é consumida, uma única vez.
    select * into v_att from public.confirmation_attempts
     where id = nullif(p_payload ->> 'verification_id', '')::uuid
       and movement_id = v_m.id and method = 'facial' and result = 'sucesso'
       and consumed_at is null and created_at > v_now - interval '5 minutes'
     for update;
    if v_att.id is null then
      raise exception 'Validação facial não encontrada, expirada ou já utilizada. Faça a validação novamente.' using errcode = '22023';
    end if;
    update public.confirmation_attempts set consumed_at = v_now where id = v_att.id;
  else
    raise exception 'Método de confirmação inválido.' using errcode = '22023';
  end if;

  if v_photo is not null then
    insert into public.movement_photos (movement_id, employee_id, bucket, storage_path, kind, mime_type, size_bytes, taken_at, uploaded_by)
    values (v_m.id, v_m.requester_employee_id, 'fotos-retirada', v_photo, 'confirmacao_balcao',
            case when v_pobj.mime_type in ('image/jpeg', 'image/webp', 'image/png') then v_pobj.mime_type else 'image/jpeg' end,
            v_pobj.size_bytes, v_now, auth.uid())
    on conflict (storage_path) do nothing;
  end if;

  -- Emergencial: concluída na confirmação, apenas para controle (sem SA e sem baixa no ERP)
  v_status := case when v_m.is_rescue then 'aguardando_retorno'::public.movement_status
                        when v_m.is_emergency then 'concluida'
                   when s.require_approval then 'aguardando_aprovacao'
                   when v_m.requires_sa then 'aguardando_sa'
                   else 'sa_informada' end;

  perform set_config('app.audit_action', 'me.confirmada', true);
  perform set_config('app.source', 'balcao', true);
  perform set_config('app.justification', 'Confirmada pelo solicitante (' || v_method || ')', true);
  update public.stock_movements
     set status = v_status, confirmed_at = v_now, confirmation_method = v_method, received_at = coalesce(nullif(current_setting('app.counter_offline_signed_at',true),'')::timestamptz,v_now),
         completed_at = case when v_m.is_emergency then v_now else completed_at end,
         completed_by = case when v_m.is_emergency then v_m.storekeeper_id else completed_by end,
         updated_by = auth.uid()
   where id = v_m.id;
  perform public._counter_touch(v_m.id, 'me_confirmada', 'confirmada');

  perform public.write_audit('me.confirmacao_registrada', 'stock_movements', v_m.id::text, v_m.id, v_m.warehouse_id, null,
    jsonb_build_object('me_number', v_m.me_number, 'solicitante', v_m.requester_name, 'metodo', v_method,
                       'tentativa', v_att.id, 'itens', v_m.item_count, 'total_atendido', v_m.total_delivered,
                       'almoxarife', v_m.storekeeper_id, 'status', v_status,
                       'foto', v_photo is not null, 'sem_foto_motivo', v_no_photo,
                       'emergencial', v_m.is_emergency), null);

  return jsonb_build_object('id', v_m.id, 'me_number', v_m.me_number, 'status', v_status);
end;
$$;

create or replace function public.counter_confirm_offline(p_movement_id uuid,p_payload jsonb) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare m public.stock_movements; cs public.counter_sessions; receipt public.counter_offline_receipts;
 req uuid; signed timestamptz; expected jsonb; supplied jsonb; result jsonb; path text;
begin
 if auth.uid() is null or not public.is_active_user() or not public.has_role('terminal') then
  raise exception 'Somente terminal ativo pode enviar a confirmação offline.' using errcode='42501';
 end if;
 select * into m from public.stock_movements where id=p_movement_id for update;
 select * into cs from public.counter_sessions where movement_id=p_movement_id for update;
 if m.id is null or cs.id is null or cs.terminal_user_id is distinct from auth.uid() or not public.is_terminal_of_warehouse(m.warehouse_id) then
  raise exception 'Tablet não pareado ou estoque sem acesso.' using errcode='42501';
 end if;
 req:=(p_payload->>'request_id')::uuid;
 if req is null then raise exception 'Identificador da confirmação é obrigatório.'; end if;
 select * into receipt from public.counter_offline_receipts where request_id=req;
 if found then
  if receipt.movement_id<>m.id or receipt.terminal_user_id<>auth.uid() then raise exception 'Identificador já utilizado.' using errcode='42501'; end if;
  return jsonb_build_object('id',m.id,'me_number',m.me_number,'status',m.status,'repetida',true);
 end if;
 if cs.status<>'aguardando_confirmacao' or m.status<>'aguardando_assinatura' or m.separation_finished_at is null then
  raise exception 'A lista não está mais autorizada para confirmação. Confira a ME com o almoxarife.';
 end if;
 if (p_payload->>'version')::bigint is distinct from cs.version or (p_payload->>'separation_finished_at')::timestamptz is distinct from m.separation_finished_at then
  raise exception 'A autorização ou lista mudou. Confira novamente com o almoxarife.';
 end if;
 signed:=(p_payload->>'signed_at')::timestamptz;
 if signed is null or signed>now()+interval '5 minutes' or signed<now()-interval '7 days' or signed<m.separation_finished_at-interval '5 minutes' then
  raise exception 'Data da assinatura offline fora do período autorizado (até 7 dias).';
 end if;
 if jsonb_typeof(p_payload->'items') is distinct from 'array' or jsonb_array_length(p_payload->'items')>200 then raise exception 'Lista de materiais inválida.'; end if;
 select coalesce(jsonb_agg(jsonb_build_object('id',id,'quantity_requested',quantity_requested,'quantity_delivered',quantity_delivered) order by id),'[]'::jsonb) into expected from public.stock_movement_items where movement_id=m.id;
 select coalesce(jsonb_agg(jsonb_build_object('id',x.id,'quantity_requested',x.quantity_requested,'quantity_delivered',x.quantity_delivered) order by x.id),'[]'::jsonb) into supplied
 from jsonb_to_recordset(p_payload->'items') as x(id uuid,quantity_requested numeric,quantity_delivered numeric);
 if expected<>supplied then raise exception 'Materiais ou quantidades diferem da lista autorizada. Confira com o almoxarife.'; end if;
 path:=p_payload->>'signature_path';
 if not exists(select 1 from storage.objects where bucket_id='assinaturas' and name=path and owner=auth.uid()) then raise exception 'Assinatura não pertence ao terminal.' using errcode='42501'; end if;
 if nullif(p_payload->>'photo_path','') is not null and not exists(select 1 from storage.objects where bucket_id='fotos-retirada' and name=p_payload->>'photo_path' and owner=auth.uid()) then raise exception 'Foto não pertence ao terminal.' using errcode='42501'; end if;
 perform set_config('app.counter_offline_signed_at',signed::text,true);
 result:=public.counter_confirm(m.id,jsonb_build_object('method','assinatura','signature_path',path,'photo_path',p_payload->>'photo_path','photo_skipped_reason',p_payload->>'photo_skipped_reason'));
 perform set_config('app.counter_offline_signed_at','',true);
 insert into public.counter_offline_receipts(request_id,movement_id,terminal_user_id,signed_at,signature_path,authorized_version) values(req,m.id,auth.uid(),signed,path,cs.version);
 perform public.audit_event('me.confirmacao_offline','stock_movements',m.id::text,m.id,m.warehouse_id,null,
  jsonb_build_object('request_id',req,'assinada_em',signed,'sincronizada_em',now(),'versao_autorizada',cs.version),null);
 return result;
end; $$;
revoke all on function public.counter_confirm_offline(uuid,jsonb) from public,anon;
grant execute on function public.counter_confirm_offline(uuid,jsonb) to authenticated;
comment on table public.counter_offline_receipts is 'Comprovantes de confirmação offline, vinculados à guarda da ME. Sem exclusão automática.';
commit;
