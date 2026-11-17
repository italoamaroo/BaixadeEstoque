-- =====================================================================
-- 20 - FOTO DO SOLICITANTE NA CONFIRMAÇÃO DO BALCÃO
-- O tablet tira uma foto do solicitante ao confirmar a ME (junto com a assinatura).
-- A foto fica no bucket privado "fotos-retirada"; só gestor e administrador veem.
-- Sem câmera disponível, a confirmação segue só com assinatura e o motivo fica registrado.
-- Pré-requisito: 16a, 16b e 17. Pode ser reexecutado.
-- =====================================================================
-- ---------------------------------------------------------------------
-- 8c) Foto do solicitante na confirmação (evidência; só gestor/admin veem)
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('fotos-retirada', 'fotos-retirada', false, 2097152, array['image/jpeg', 'image/webp', 'image/png'])
on conflict (id) do nothing;

create table if not exists public.movement_photos (
  id            uuid primary key default gen_random_uuid(),
  movement_id   uuid not null references public.stock_movements (id),
  employee_id   uuid references public.employees (id),
  bucket        text not null default 'fotos-retirada',
  storage_path  text not null unique,
  kind          text not null default 'confirmacao_balcao',
  mime_type     text,
  size_bytes    integer,
  taken_at      timestamptz not null default now(),
  uploaded_by   uuid references public.profiles (id) default auth.uid(),
  created_at    timestamptz not null default now()
);
create index if not exists movement_photos_movement_idx on public.movement_photos (movement_id);
alter table public.movement_photos enable row level security;
drop policy if exists movement_photos_select on public.movement_photos;
create policy movement_photos_select on public.movement_photos
  for select to authenticated using (
    public.has_any_role(array['gestor', 'admin']::public.app_role[]) and public.can_access_movement(movement_id)
  );
grant select on public.movement_photos to authenticated;
revoke insert, update, delete on public.movement_photos from authenticated, anon;
drop trigger if exists block_delete on public.movement_photos;
create trigger block_delete before delete on public.movement_photos for each row execute function public.tg_block_delete();

drop policy if exists "fotos-retirada: leitura por gestor/admin" on storage.objects;
create policy "fotos-retirada: leitura por gestor/admin"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'fotos-retirada'
    and public.has_any_role(array['gestor', 'admin']::public.app_role[])
    and public.can_access_warehouse_code((storage.foldername(name))[1])
  );
drop policy if exists "fotos-retirada: envio pelo tablet do balcão" on storage.objects;
create policy "fotos-retirada: envio pelo tablet do balcão"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'fotos-retirada'
    and name ~* '\.(jpe?g|webp|png)$'
    and public.counter_terminal_can_upload(name)
  );

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
            v_obj.size_bytes, v_now, auth.uid(), true);
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

  v_status := case when s.require_approval then 'aguardando_aprovacao'
                   when v_m.requires_sa then 'aguardando_sa'
                   else 'sa_informada' end;

  perform set_config('app.audit_action', 'me.confirmada', true);
  perform set_config('app.source', 'balcao', true);
  perform set_config('app.justification', 'Confirmada pelo solicitante (' || v_method || ')', true);
  update public.stock_movements
     set status = v_status, confirmed_at = v_now, confirmation_method = v_method, received_at = v_now,
         updated_by = auth.uid()
   where id = v_m.id;
  perform public._counter_touch(v_m.id, 'me_confirmada', 'confirmada');

  perform public.write_audit('me.confirmada', 'stock_movements', v_m.id::text, v_m.id, v_m.warehouse_id, null,
    jsonb_build_object('me_number', v_m.me_number, 'solicitante', v_m.requester_name, 'metodo', v_method,
                       'tentativa', v_att.id, 'itens', v_m.item_count, 'total_atendido', v_m.total_delivered,
                       'almoxarife', v_m.storekeeper_id, 'status', v_status,
                       'foto', v_photo is not null, 'sem_foto_motivo', v_no_photo), null);

  return jsonb_build_object('id', v_m.id, 'me_number', v_m.me_number, 'status', v_status);
end;
$$;

-- registro de consulta da foto na auditoria
create or replace function public.log_event(
  p_action      text,
  p_movement_id uuid default null,
  p_details     jsonb default null
)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_wh uuid;
begin
  if not public.is_active_user() then
    raise exception 'Sessão inválida ou usuário inativo.' using errcode = '42501';
  end if;
  if p_action not in ('me.impressa', 'me.pdf_gerado', 'me.assinatura_consultada', 'me.foto_consultada',
                      'exportacao.excel', 'etiquetas.impressas', 'qr.leitura_nao_encontrada') then
    raise exception 'Evento não permitido.' using errcode = '22023';
  end if;
  if p_movement_id is not null then
    select warehouse_id into v_wh from public.stock_movements where id = p_movement_id;
    if v_wh is null or not public.can_access_warehouse(v_wh) then
      raise exception 'ME não encontrada.' using errcode = 'P0002';
    end if;
  end if;
  if p_details is not null and length(p_details::text) > 4000 then
    p_details := jsonb_build_object('aviso', 'detalhes truncados');
  end if;

  perform public.write_audit(p_action, case when p_movement_id is null then 'interface' else 'stock_movements' end,
                             p_movement_id::text, p_movement_id, v_wh, null, p_details, null);
end;
$$;

grant execute on function public.counter_confirm(uuid, jsonb) to authenticated;
