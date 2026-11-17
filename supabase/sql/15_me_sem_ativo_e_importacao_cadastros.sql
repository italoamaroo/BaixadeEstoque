-- =====================================================================
-- 15 - ME SEM ATIVO FIXO VAI DIRETO PARA A BAIXA NO ERP
--      + IMPORTAÇÃO DE CADASTROS AUXILIARES (ativos fixos, locais etc.)
-- Regra: ME com ativo fixo -> Aguardando SA -> equipe SA informa -> almoxarife baixa no ERP.
--        ME sem ativo fixo -> direto "Aguardando baixa no ERP" (sem SA) -> almoxarife baixa no ERP.
-- MEs já existentes não mudam de etapa.
-- Executar uma vez no SQL Editor do Supabase (pode ser reexecutado).
-- =====================================================================
alter table public.stock_movements add column if not exists requires_sa boolean not null default true;

alter table public.stock_movements drop constraint if exists stock_movements_sa_ck;
alter table public.stock_movements add constraint stock_movements_sa_ck check (
  status not in ('sa_informada', 'concluida') or sa_number is not null or not requires_sa
);

create or replace function public.create_movement(p_payload jsonb)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  s              public.app_settings := public.get_settings();
  v_uid          uuid := auth.uid();
  v_id           uuid;
  v_wh           public.warehouses;
  v_existing     public.stock_movements;
  v_requester    public.employees;
  v_receiver     public.employees;
  v_contract_id  uuid;
  v_sector_id    uuid;
  v_front_id     uuid;
  v_appl_id      uuid;
  v_so_text      text;
  v_so_id        uuid;
  v_fa_text      text;
  v_fa_id        uuid;
  v_number       text;
  v_status       public.movement_status;
  v_items        jsonb := p_payload -> 'items';
  v_item         jsonb;
  v_mat          record;
  v_line         int := 0;
  v_req          numeric;
  v_del          numeric;
  v_seen         uuid[] := '{}';
  v_sig          jsonb := p_payload -> 'signature';
  v_sig_path     text;
  v_sig_obj      record;
  v_year         int;
  v_now          timestamptz := now();
  v_signed_at    timestamptz;
begin
  -- 1) Autenticação e perfil
  if v_uid is null or not public.is_active_user() then
    raise exception 'Sessão inválida ou usuário inativo.' using errcode = '42501';
  end if;
  if not public.has_any_role(array['almoxarife', 'gestor', 'admin']::public.app_role[]) then
    raise exception 'Seu perfil não permite registrar saídas de material.' using errcode = '42501';
  end if;

  -- 2) Identificador (chave de idempotência gerada no cliente)
  begin
    v_id := (p_payload ->> 'id')::uuid;
  exception when others then
    raise exception 'Identificador da movimentação inválido.' using errcode = '22023';
  end;
  if v_id is null then
    raise exception 'Identificador da movimentação é obrigatório.' using errcode = '22023';
  end if;

  -- Serializa reenvios com o mesmo identificador (duplo clique / nova tentativa)
  perform pg_advisory_xact_lock(hashtextextended(v_id::text, 0));

  select * into v_existing from public.stock_movements where id = v_id;
  if found then
    if v_existing.created_by <> v_uid then
      raise exception 'Identificador de movimentação já utilizado.' using errcode = '23505';
    end if;
    return jsonb_build_object('id', v_existing.id, 'me_number', v_existing.me_number,
                              'status', v_existing.status, 'created', false);
  end if;

  -- 3) Estoque
  select * into v_wh from public.warehouses where id = nullif(p_payload ->> 'warehouse_id', '')::uuid;
  if v_wh.id is null then
    raise exception 'Selecione o estoque de origem.' using errcode = '22023';
  end if;
  if not v_wh.active then
    raise exception 'O estoque % está inativo.', v_wh.name using errcode = '22023';
  end if;
  if not public.can_access_warehouse(v_wh.id) then
    raise exception 'Você não tem permissão para operar no estoque %.', v_wh.name using errcode = '42501';
  end if;

  -- 4) Dados operacionais
  select id into v_contract_id from public.contracts
   where id = nullif(p_payload ->> 'contract_id', '')::uuid and active;
  if v_contract_id is null then
    raise exception 'Informe um contrato ativo.' using errcode = '22023';
  end if;

  select id into v_sector_id from public.sectors
   where id = nullif(p_payload ->> 'sector_id', '')::uuid and active;
  if v_sector_id is null then
    raise exception 'Informe um setor ativo.' using errcode = '22023';
  end if;

  if nullif(p_payload ->> 'service_front_id', '') is not null then
    select id into v_front_id from public.service_fronts
     where id = (p_payload ->> 'service_front_id')::uuid and active;
    if v_front_id is null then
      raise exception 'Frente de serviço/equipamento inválida ou inativa.' using errcode = '22023';
    end if;
  end if;

  if nullif(p_payload ->> 'application_location_id', '') is not null then
    select id into v_appl_id from public.application_locations
     where id = (p_payload ->> 'application_location_id')::uuid and active;
    if v_appl_id is null then
      raise exception 'Local de aplicação inválido ou inativo.' using errcode = '22023';
    end if;
  end if;

  v_so_text := nullif(btrim(coalesce(p_payload ->> 'service_order_text', '')), '');
  if v_so_text is not null then
    if length(v_so_text) > 40 then
      raise exception 'Ordem de serviço deve ter no máximo 40 caracteres.' using errcode = '22023';
    end if;
    select id into v_so_id from public.service_orders where upper(code) = upper(v_so_text) and active;
  end if;

  v_fa_text := nullif(btrim(coalesce(p_payload ->> 'fixed_asset_text', '')), '');
  if v_fa_text is not null then
    if length(v_fa_text) > 40 then
      raise exception 'Ativo fixo deve ter no máximo 40 caracteres.' using errcode = '22023';
    end if;
    select id into v_fa_id from public.fixed_assets where upper(code) = upper(v_fa_text) and active;
  end if;

  -- 5) Requisitante e recebedor
  select * into v_requester from public.employees
   where id = nullif(p_payload ->> 'requester_employee_id', '')::uuid;
  if v_requester.id is null then
    raise exception 'Identifique o funcionário requisitante.' using errcode = '22023';
  end if;
  if not v_requester.active then
    raise exception 'O funcionário % está inativo.', v_requester.full_name using errcode = '22023';
  end if;

  select * into v_receiver from public.employees
   where id = coalesce(nullif(p_payload ->> 'received_by_employee_id', '')::uuid, v_requester.id);
  if v_receiver.id is null or not v_receiver.active then
    raise exception 'Funcionário que recebeu o material inválido ou inativo.' using errcode = '22023';
  end if;

  -- 6) Itens
  if v_items is null or jsonb_typeof(v_items) <> 'array' or jsonb_array_length(v_items) = 0 then
    raise exception 'A ME precisa ter pelo menos um material.' using errcode = '22023';
  end if;
  if jsonb_array_length(v_items) > 200 then
    raise exception 'Limite de 200 itens por ME.' using errcode = '22023';
  end if;

  -- 7) Assinatura (obrigatória)
  v_year := extract(year from (v_now at time zone s.timezone))::int;
  v_sig_path := nullif(btrim(coalesce(v_sig ->> 'storage_path', '')), '');
  if v_sig_path is null then
    raise exception 'A assinatura do funcionário é obrigatória para finalizar a ME.' using errcode = '22023';
  end if;
  if v_sig_path not like v_wh.code || '/' || v_year::text || '/' || v_id::text || '/%' then
    raise exception 'Caminho da assinatura inválido para esta ME.' using errcode = '22023';
  end if;

  select o.name,
         nullif(o.metadata ->> 'size', '')::int as size_bytes,
         coalesce(o.metadata ->> 'mimetype', 'image/png') as mime_type
    into v_sig_obj
    from storage.objects o
   where o.bucket_id = 'assinaturas' and o.name = v_sig_path;
  if v_sig_obj.name is null then
    raise exception 'Arquivo da assinatura não encontrado no armazenamento. Tente enviar a assinatura novamente.'
      using errcode = '22023';
  end if;

  begin
    v_signed_at := coalesce(nullif(v_sig ->> 'signed_at', '')::timestamptz, v_now);
  exception when others then
    v_signed_at := v_now;
  end;
  if v_signed_at > v_now + interval '5 minutes' or v_signed_at < v_now - interval '1 day' then
    v_signed_at := v_now;
  end if;

  -- 8) Gravação
  perform set_config('app.creating', 'on', true);
  perform set_config('app.source', coalesce(nullif(p_payload ->> 'source', ''), 'app'), true);

  v_number := public.next_me_number(v_wh.id, v_now);
  -- Sem ativo fixo: não precisa de SA, vai direto para a baixa no ERP (status sa_informada sem número de SA)
  v_status := case when s.require_approval then 'aguardando_aprovacao'
                   when v_fa_text is null then 'sa_informada'
                   else 'aguardando_sa' end;

  insert into public.stock_movements (
    id, me_number, movement_type, movement_at, warehouse_id, contract_id, sector_id,
    service_front_id, service_order_id, service_order_text, fixed_asset_id, fixed_asset_text, requires_sa,
    application_location_id, application_location_text, notes, status,
    requester_employee_id, requester_name, requester_registration, requested_at,
    received_by_employee_id, received_by_name, received_by_registration, received_at,
    storekeeper_id, created_by, updated_by, created_at
  ) values (
    v_id, v_number, 'saida', v_now, v_wh.id, v_contract_id, v_sector_id,
    v_front_id, v_so_id, v_so_text, v_fa_id, v_fa_text, v_fa_text is not null,
    v_appl_id, nullif(btrim(coalesce(p_payload ->> 'application_location_text', '')), ''),
    nullif(btrim(coalesce(p_payload ->> 'notes', '')), ''), v_status,
    v_requester.id, v_requester.full_name, v_requester.registration, v_now,
    v_receiver.id, v_receiver.full_name, v_receiver.registration, v_signed_at,
    v_uid, v_uid, v_uid, v_now
  );

  for v_item in select * from jsonb_array_elements(v_items) loop
    v_line := v_line + 1;

    select m.*, a.code as account_code, a.name as account_name
      into v_mat
      from public.materials m
      left join public.accounts a on a.id = m.account_id
     where m.id = nullif(v_item ->> 'material_id', '')::uuid;

    if v_mat.id is null then
      raise exception 'Item %: material não encontrado.', v_line using errcode = '22023';
    end if;
    if not v_mat.active then
      raise exception 'Item % (%): material inativo não pode ser baixado.', v_line, v_mat.name using errcode = '22023';
    end if;
    if v_mat.id = any (v_seen) and not s.allow_duplicate_material_lines then
      raise exception 'O material % aparece mais de uma vez. Some as quantidades em uma única linha.', v_mat.name
        using errcode = '22023';
    end if;
    v_seen := v_seen || v_mat.id;

    begin
      v_req := (v_item ->> 'quantity_requested')::numeric;
      v_del := (v_item ->> 'quantity_delivered')::numeric;
    exception when others then
      raise exception 'Item % (%): quantidade inválida.', v_line, v_mat.name using errcode = '22023';
    end;
    if v_req is null or v_req <= 0 then
      raise exception 'Item % (%): a quantidade solicitada deve ser maior que zero.', v_line, v_mat.name using errcode = '22023';
    end if;
    if v_del is null or v_del <= 0 then
      raise exception 'Item % (%): a quantidade atendida deve ser maior que zero.', v_line, v_mat.name using errcode = '22023';
    end if;
    if v_del > v_req and not s.allow_delivered_above_requested then
      raise exception 'Item % (%): a quantidade atendida não pode ser maior que a solicitada.', v_line, v_mat.name
        using errcode = '22023';
    end if;
    if v_req > 999999 or v_del > 999999 then
      raise exception 'Item % (%): quantidade acima do limite permitido.', v_line, v_mat.name using errcode = '22023';
    end if;

    insert into public.stock_movement_items (
      movement_id, line_number, material_id, material_code, material_reference, material_name,
      unit, location, account_code, account_name, quantity_requested, quantity_delivered,
      entry_method, scanned_code, notes, created_by, updated_by
    ) values (
      v_id, v_line, v_mat.id, v_mat.code, v_mat.reference, v_mat.name,
      v_mat.unit, v_mat.location, v_mat.account_code, v_mat.account_name, v_req, v_del,
      case when v_item ->> 'entry_method' = 'pesquisa_manual' then 'pesquisa_manual' else 'qr_code' end::public.item_entry_method,
      left(nullif(v_item ->> 'scanned_code', ''), 80),
      left(nullif(btrim(coalesce(v_item ->> 'notes', '')), ''), 500),
      v_uid, v_uid
    );
  end loop;

  insert into public.signatures (
    movement_id, employee_id, signer_name, signer_registration, bucket, storage_path,
    mime_type, size_bytes, signed_at, uploaded_by, is_current
  ) values (
    v_id, v_receiver.id, v_receiver.full_name, v_receiver.registration, 'assinaturas', v_sig_path,
    case when v_sig_obj.mime_type in ('image/png', 'image/jpeg', 'image/webp') then v_sig_obj.mime_type else 'image/png' end,
    v_sig_obj.size_bytes, v_signed_at, v_uid, true
  );

  perform public.write_audit(
    'me.finalizada', 'stock_movements', v_id::text, v_id, v_wh.id, null,
    jsonb_build_object('me_number', v_number, 'status', v_status, 'itens', v_line,
                       'requisitante', v_requester.full_name, 'estoque', v_wh.name),
    null
  );

  perform set_config('app.creating', 'off', true);

  return jsonb_build_object('id', v_id, 'me_number', v_number, 'status', v_status, 'created', true);
end;
$$;

create or replace function public.approve_movement(p_id uuid, p_notes text default null)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_m public.stock_movements;
begin
  if not public.has_any_role(array['gestor', 'admin']::public.app_role[]) then
    raise exception 'Somente gestor ou administrador pode aprovar a ME.' using errcode = '42501';
  end if;

  select * into v_m from public.stock_movements where id = p_id for update;
  if v_m.id is null or not public.can_access_warehouse(v_m.warehouse_id) then
    raise exception 'ME não encontrada.' using errcode = 'P0002';
  end if;
  if v_m.status <> 'aguardando_aprovacao' then
    raise exception 'A ME % não está aguardando aprovação (status atual: %).', v_m.me_number, v_m.status using errcode = 'P0001';
  end if;

  perform set_config('app.audit_action', 'me.aprovada', true);
  perform set_config('app.justification', coalesce(p_notes, ''), true);

  -- Com ativo fixo vai para a SA; sem ativo vai direto para a baixa no ERP
  update public.stock_movements
     set status = case when v_m.requires_sa then 'aguardando_sa'::public.movement_status else 'sa_informada'::public.movement_status end,
         approved_by = auth.uid(), approved_at = now()
   where id = p_id;

  return jsonb_build_object('id', p_id, 'status', case when v_m.requires_sa then 'aguardando_sa' else 'sa_informada' end);
end;
$$;

create or replace function public.inform_sa(p_id uuid, p_sa_number text, p_justification text default null)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  s          public.app_settings := public.get_settings();
  v_m        public.stock_movements;
  v_sa       text := upper(btrim(coalesce(p_sa_number, '')));
  v_just     text := nullif(btrim(coalesce(p_justification, '')), '');
  v_action   public.sa_action;
  v_status   public.movement_status;
  v_dup      text;
begin
  if not public.has_any_role(array['equipe_sa', 'gestor', 'admin']::public.app_role[]) then
    raise exception 'Seu perfil não permite informar o número da SA.' using errcode = '42501';
  end if;

  if v_sa = '' then
    raise exception 'Informe o número da SA.' using errcode = '22023';
  end if;
  if v_sa !~ s.sa_number_pattern then
    raise exception 'Número da SA "%" em formato inválido. Use somente letras, números, ponto, barra ou hífen (3 a 30 caracteres).', v_sa
      using errcode = '22023';
  end if;

  select * into v_m from public.stock_movements where id = p_id for update;
  if v_m.id is null or not public.can_access_warehouse(v_m.warehouse_id) then
    raise exception 'ME não encontrada.' using errcode = 'P0002';
  end if;
  if not v_m.requires_sa then
    raise exception 'A ME % não tem ativo fixo e não precisa de SA: a baixa é feita direto no ERP pelo almoxarife.', v_m.me_number
      using errcode = 'P0001';
  end if;

  if v_m.status = 'aguardando_sa' then
    v_action := 'inclusao';
    v_status := case when s.auto_complete_on_sa then 'concluida' else 'sa_informada' end;
  elsif v_m.status = 'sa_informada' then
    v_action := 'correcao';
    v_status := v_m.status;
  elsif v_m.status = 'concluida' then
    if not public.has_any_role(array['gestor', 'admin']::public.app_role[]) then
      raise exception 'A ME % está concluída. Somente gestor ou administrador pode corrigir a SA.', v_m.me_number
        using errcode = '42501';
    end if;
    v_action := 'correcao';
    v_status := v_m.status;
    perform set_config('app.correction', 'on', true);
  else
    raise exception 'Não é possível informar SA para uma ME com status "%".', v_m.status using errcode = 'P0001';
  end if;

  if v_action = 'correcao' then
    if v_m.sa_number = v_sa then
      raise exception 'A ME % já possui a SA %.', v_m.me_number, v_sa using errcode = 'P0001';
    end if;
    if v_just is null or length(v_just) < 5 then
      raise exception 'Para corrigir a SA informe uma justificativa (mínimo 5 caracteres).' using errcode = '22023';
    end if;
  end if;

  if s.sa_number_unique then
    select me_number into v_dup from public.stock_movements
     where upper(sa_number) = v_sa and id <> p_id and status <> 'cancelada'
     limit 1;
    if v_dup is not null then
      raise exception 'A SA % já está vinculada à ME %.', v_sa, v_dup using errcode = '23505';
    end if;
  end if;

  perform set_config('app.audit_action', case v_action when 'inclusao' then 'sa.informada' else 'sa.corrigida' end, true);
  perform set_config('app.justification', coalesce(v_just, ''), true);

  update public.stock_movements
     set sa_number      = v_sa,
         sa_informed_at = now(),
         sa_informed_by = auth.uid(),
         status         = v_status,
         completed_at   = case when v_status = 'concluida' and v_m.status <> 'concluida' then now() else completed_at end,
         completed_by   = case when v_status = 'concluida' and v_m.status <> 'concluida' then auth.uid() else completed_by end
   where id = p_id;

  insert into public.erp_sa_records (movement_id, me_number, sa_number, previous_sa_number, action, justification, informed_by)
  values (p_id, v_m.me_number, v_sa, v_m.sa_number, v_action, v_just, auth.uid());

  return jsonb_build_object('id', p_id, 'me_number', v_m.me_number, 'sa_number', v_sa,
                            'status', v_status, 'action', v_action);
end;
$$;

create or replace function public.cancel_movement(p_id uuid, p_reason text)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_m       public.stock_movements;
  v_reason  text := nullif(btrim(coalesce(p_reason, '')), '');
  v_manager boolean := public.has_any_role(array['gestor', 'admin']::public.app_role[]);
  v_storekeeper boolean := public.has_role('almoxarife');
begin
  -- Gestor/admin: cancelam em qualquer status.
  -- Almoxarife: somente devolução/erro ANTES do lançamento no ERP
  -- (Aguardando SA, Aguardando aprovação ou, em ME sem ativo, Aguardando baixa no ERP),
  -- no estoque autorizado.
  if not v_manager and not v_storekeeper then
    raise exception 'Seu perfil não permite cancelar uma ME.' using errcode = '42501';
  end if;
  if v_reason is null or length(v_reason) < 5 then
    raise exception 'Informe a justificativa do cancelamento (mínimo 5 caracteres).' using errcode = '22023';
  end if;

  select * into v_m from public.stock_movements where id = p_id for update;
  if v_m.id is null or not public.can_access_warehouse(v_m.warehouse_id) then
    raise exception 'ME não encontrada.' using errcode = 'P0002';
  end if;
  if v_m.status = 'cancelada' then
    raise exception 'A ME % já está cancelada.', v_m.me_number using errcode = 'P0001';
  end if;
  if not v_manager
     and v_m.status not in ('aguardando_sa', 'aguardando_aprovacao')
     and not (v_m.status = 'sa_informada' and not v_m.requires_sa) then
    raise exception 'A ME % já tem SA lançada no ERP. Somente gestor ou administrador pode cancelá-la.', v_m.me_number
      using errcode = '42501';
  end if;

  perform set_config('app.audit_action', 'me.cancelada', true);
  perform set_config('app.justification', v_reason, true);
  if v_m.status = 'concluida' then
    perform set_config('app.correction', 'on', true);
  end if;

  update public.stock_movements
     set status = 'cancelada', cancelled_at = now(), cancelled_by = auth.uid(), cancel_reason = v_reason
   where id = p_id;

  return jsonb_build_object('id', p_id, 'status', 'cancelada');
end;
$$;

create or replace function public.complete_movement(
  p_id           uuid,
  p_erp_document text default null,
  p_notes        text default null
)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_m     public.stock_movements;
  v_doc   text := nullif(btrim(coalesce(p_erp_document, '')), '');
  v_notes text := nullif(btrim(coalesce(p_notes, '')), '');
  v_text  text;
begin
  if not public.has_any_role(array['almoxarife', 'gestor', 'admin']::public.app_role[]) then
    raise exception 'Seu perfil não permite confirmar a baixa no ERP.' using errcode = '42501';
  end if;
  if v_doc is not null and length(v_doc) > 60 then
    raise exception 'O documento do ERP deve ter no máximo 60 caracteres.' using errcode = '22023';
  end if;
  if v_notes is not null and length(v_notes) > 500 then
    raise exception 'A observação deve ter no máximo 500 caracteres.' using errcode = '22023';
  end if;

  select * into v_m from public.stock_movements where id = p_id for update;
  if v_m.id is null or not public.can_access_warehouse(v_m.warehouse_id) then
    raise exception 'ME não encontrada.' using errcode = 'P0002';
  end if;
  if v_m.status <> 'sa_informada' then
    raise exception 'Somente MEs aguardando baixa no ERP podem ser confirmadas (status atual: %).', v_m.status
      using errcode = 'P0001';
  end if;

  v_text := case when v_m.sa_number is null then 'Baixa realizada no ERP sem SA (ME sem ativo fixo)'
                 else 'Baixa realizada no ERP com a SA ' || v_m.sa_number end
         || coalesce('. Documento ERP: ' || v_doc, '')
         || coalesce('. Obs.: ' || v_notes, '');

  perform set_config('app.audit_action', 'me.concluida', true);
  perform set_config('app.justification', v_text, true);
  update public.stock_movements
     set status = 'concluida', completed_at = now(), completed_by = auth.uid()
   where id = p_id;

  return jsonb_build_object('id', p_id, 'status', 'concluida', 'sa_number', v_m.sa_number);
end;
$$;

create or replace function public.import_lookups(p_table text, p_rows jsonb)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_row      jsonb;
  v_idx      int := 0;
  v_inserted int := 0;
  v_updated  int := 0;
  v_errors   jsonb := '[]'::jsonb;
  v_code     text;
  v_name     text;
  v_kind     text;
  v_active   boolean;
  v_exists   boolean;
begin
  if not public.can_manage_master_data() then
    raise exception 'Somente administrador ou almoxarife pode importar cadastros.' using errcode = '42501';
  end if;
  if p_table not in ('contracts', 'sectors', 'service_fronts', 'service_orders', 'fixed_assets',
                     'application_locations', 'accounts', 'material_categories') then
    raise exception 'Tabela de cadastro inválida.' using errcode = '22023';
  end if;
  if jsonb_typeof(p_rows) <> 'array' then
    raise exception 'Formato de importação inválido.' using errcode = '22023';
  end if;
  if jsonb_array_length(p_rows) > 5000 then
    raise exception 'Importe no máximo 5.000 linhas por vez.' using errcode = '22023';
  end if;

  perform set_config('app.source', 'importacao', true);

  for v_row in select * from jsonb_array_elements(p_rows) loop
    v_idx := v_idx + 1;
    begin
      v_code := upper(btrim(coalesce(v_row ->> 'code', '')));
      v_name := regexp_replace(btrim(coalesce(v_row ->> 'name', '')), '\s+', ' ', 'g');
      if v_code = '' then raise exception 'código vazio'; end if;
      if length(v_code) > 40 then raise exception 'código com mais de 40 caracteres'; end if;
      if length(v_name) < 2 then raise exception 'nome vazio ou muito curto'; end if;
      v_name := left(v_name, 160);
      v_active := case when v_row ? 'active' then (v_row ->> 'active')::boolean else null end;

      execute format('select exists (select 1 from public.%I where upper(code) = $1)', p_table) into v_exists using v_code;

      if p_table = 'service_fronts' then
        v_kind := lower(btrim(coalesce(v_row ->> 'kind', '')));
        v_kind := case when v_kind like 'equip%' then 'equipamento' when v_kind = '' then null else 'frente' end;
        if v_exists then
          update public.service_fronts
             set name = v_name, kind = coalesce(v_kind, kind), active = coalesce(v_active, active)
           where upper(code) = v_code;
        else
          insert into public.service_fronts (code, name, kind, active)
          values (v_code, v_name, coalesce(v_kind, 'frente'), coalesce(v_active, true));
        end if;
      elsif v_exists then
        execute format('update public.%I set name = $1, active = coalesce($2, active) where upper(code) = $3', p_table)
          using v_name, v_active, v_code;
      else
        execute format('insert into public.%I (code, name, active) values ($1, $2, coalesce($3, true))', p_table)
          using v_code, v_name, v_active;
      end if;

      if v_exists then v_updated := v_updated + 1; else v_inserted := v_inserted + 1; end if;
    exception when others then
      v_errors := v_errors || jsonb_build_object('linha', v_idx, 'codigo', v_row ->> 'code', 'erro', sqlerrm);
    end;
  end loop;

  return jsonb_build_object('inseridos', v_inserted, 'atualizados', v_updated, 'erros', v_errors);
end;
$$;

revoke all on function public.import_lookups(text, jsonb) from public;
grant execute on function public.import_lookups(text, jsonb) to authenticated;

grant execute on function public.create_movement(jsonb) to authenticated;
grant execute on function public.approve_movement(uuid, text) to authenticated;
grant execute on function public.inform_sa(uuid, text, text) to authenticated;
grant execute on function public.cancel_movement(uuid, text) to authenticated;
grant execute on function public.complete_movement(uuid, text, text) to authenticated;
