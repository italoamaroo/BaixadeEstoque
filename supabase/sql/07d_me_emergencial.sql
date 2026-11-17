-- =====================================================================
-- 07d (= migração 21) - CONTRATO FIXO, LOCAL DE APLICAÇÃO FIXO ( - ) E ME EMERGENCIAL
-- * Parâmetros ganham "contrato padrão": a tela já vem com o contrato fixo
--   e o servidor usa esse contrato quando nenhum é enviado.
-- * Local de aplicação: sem local cadastrado, a ME grava "-".
-- * ME emergencial: retirada só para controle. Exige motivo, não vai para a
--   equipe de SA nem para a baixa no ERP; fica "Concluída" ao ser registrada
--   (assistente) ou confirmada pelo solicitante (balcão).
-- Pré-requisito: 14 a 20. Pode ser reexecutado.
-- =====================================================================

alter table public.app_settings
  add column if not exists default_contract_id uuid references public.contracts (id) on delete set null;

-- Se houver um único contrato ativo, ele vira o contrato padrão
update public.app_settings s
   set default_contract_id = (select id from public.contracts where active limit 1)
 where s.id = 1 and s.default_contract_id is null
   and (select count(*) from public.contracts where active) = 1;

alter table public.stock_movements add column if not exists is_emergency boolean not null default false;
alter table public.stock_movements add column if not exists emergency_reason text;
alter table public.stock_movements drop constraint if exists stock_movements_emergency_ck;
alter table public.stock_movements add constraint stock_movements_emergency_ck check (
  not is_emergency or length(btrim(coalesce(emergency_reason, ''))) between 5 and 500
);
create index if not exists stock_movements_emergency_idx on public.stock_movements (is_emergency) where is_emergency;

-- ---------------------------------------------------------------------
-- Visão das MEs (novas colunas no final)
-- ---------------------------------------------------------------------
create or replace view public.v_movements
with (security_invoker = true)
as
select
  m.id,
  m.me_number,
  m.movement_type,
  m.movement_at,
  m.warehouse_id,
  w.code  as warehouse_code,
  w.name  as warehouse_name,
  m.contract_id,
  c.code  as contract_code,
  c.name  as contract_name,
  m.sector_id,
  se.name as sector_name,
  m.service_front_id,
  sf.name as service_front_name,
  coalesce(so.code, m.service_order_text) as service_order,
  coalesce(fa.code, m.fixed_asset_text)   as fixed_asset,
  m.application_location_id,
  coalesce(al.name, m.application_location_text) as application_location,
  m.notes,
  m.status,
  m.requester_employee_id,
  m.requester_name,
  m.requester_registration,
  m.requested_at,
  m.received_by_employee_id,
  m.received_by_name,
  m.received_by_registration,
  m.received_at,
  m.approved_by,
  pa.full_name as approved_by_name,
  m.approved_at,
  m.storekeeper_id,
  pk.full_name as storekeeper_name,
  m.sa_number,
  m.sa_informed_at,
  m.sa_informed_by,
  ps.full_name as sa_informed_by_name,
  m.completed_at,
  m.completed_by,
  pc.full_name as completed_by_name,
  m.cancelled_at,
  m.cancelled_by,
  px.full_name as cancelled_by_name,
  m.cancel_reason,
  m.item_count,
  m.total_requested,
  m.total_delivered,
  (select string_agg(i.material_name, '; ' order by i.line_number)
     from (select material_name, line_number
             from public.stock_movement_items
            where movement_id = m.id
            order by line_number
            limit 3) i) as materials_summary,
  m.is_demo,
  m.created_at,
  m.created_by,
  m.updated_at,
  m.updated_by,
  pu.full_name as updated_by_name,
  m.is_emergency,
  m.emergency_reason
from public.stock_movements m
join public.warehouses w on w.id = m.warehouse_id
join public.contracts c on c.id = m.contract_id
join public.sectors se on se.id = m.sector_id
left join public.service_fronts sf on sf.id = m.service_front_id
left join public.service_orders so on so.id = m.service_order_id
left join public.fixed_assets fa on fa.id = m.fixed_asset_id
left join public.application_locations al on al.id = m.application_location_id
left join public.profiles pa on pa.id = m.approved_by
left join public.profiles pk on pk.id = m.storekeeper_id
left join public.profiles ps on ps.id = m.sa_informed_by
left join public.profiles pc on pc.id = m.completed_by
left join public.profiles px on px.id = m.cancelled_by
left join public.profiles pu on pu.id = m.updated_by;

create or replace function public.movement_matches(v public.v_movements, p_f jsonb, p_tz text)
returns boolean
language sql stable
set search_path = public, pg_temp
as $$
  select
        (nullif(p_f ->> 'date_from', '') is null or (v.movement_at at time zone p_tz)::date >= (p_f ->> 'date_from')::date)
    and (nullif(p_f ->> 'date_to', '')   is null or (v.movement_at at time zone p_tz)::date <= (p_f ->> 'date_to')::date)
    and (nullif(p_f ->> 'warehouse_id', '') is null or v.warehouse_id = (p_f ->> 'warehouse_id')::uuid)
    and (nullif(p_f ->> 'me_number', '') is null or v.me_number ilike '%' || btrim(p_f ->> 'me_number') || '%')
    and (nullif(p_f ->> 'sa_number', '') is null or v.sa_number ilike '%' || btrim(p_f ->> 'sa_number') || '%')
    and (jsonb_typeof(p_f -> 'status') is distinct from 'array'
         or jsonb_array_length(p_f -> 'status') = 0
         or v.status::text in (select jsonb_array_elements_text(p_f -> 'status')))
    and (coalesce((p_f ->> 'pending_sa')::boolean, false) = false or v.status = 'aguardando_sa')
    and (nullif(p_f ->> 'emergency', '') is null
         or (p_f ->> 'emergency' = 'sim' and v.is_emergency)
         or (p_f ->> 'emergency' = 'nao' and not v.is_emergency))
    and (nullif(p_f ->> 'sector_id', '') is null or v.sector_id = (p_f ->> 'sector_id')::uuid)
    and (nullif(p_f ->> 'service_front_id', '') is null or v.service_front_id = (p_f ->> 'service_front_id')::uuid)
    and (nullif(p_f ->> 'application_location_id', '') is null or v.application_location_id = (p_f ->> 'application_location_id')::uuid)
    and (nullif(p_f ->> 'service_order', '') is null or v.service_order ilike '%' || btrim(p_f ->> 'service_order') || '%')
    and (nullif(p_f ->> 'fixed_asset', '') is null or v.fixed_asset ilike '%' || btrim(p_f ->> 'fixed_asset') || '%')
    and (nullif(p_f ->> 'requester_employee_id', '') is null or v.requester_employee_id = (p_f ->> 'requester_employee_id')::uuid)
    and (nullif(p_f ->> 'requester', '') is null
         or v.requester_name ilike '%' || btrim(p_f ->> 'requester') || '%'
         or v.requester_registration ilike '%' || btrim(p_f ->> 'requester') || '%')
    and (nullif(p_f ->> 'storekeeper_id', '') is null or v.storekeeper_id = (p_f ->> 'storekeeper_id')::uuid)
    and (nullif(p_f ->> 'responsible_user_id', '') is null
         or (p_f ->> 'responsible_user_id')::uuid in (v.created_by, v.updated_by, v.sa_informed_by, v.approved_by, v.cancelled_by, v.completed_by))
    and (
      (nullif(p_f ->> 'material', '') is null and nullif(p_f ->> 'material_code', '') is null
       and nullif(p_f ->> 'reference', '') is null and nullif(p_f ->> 'unit', '') is null)
      or exists (
        select 1 from public.stock_movement_items i
         where i.movement_id = v.id
           and (nullif(p_f ->> 'material', '') is null
                or i.material_name ilike '%' || btrim(p_f ->> 'material') || '%'
                or i.material_code ilike '%' || btrim(p_f ->> 'material') || '%'
                or i.material_reference ilike '%' || btrim(p_f ->> 'material') || '%')
           and (nullif(p_f ->> 'material_code', '') is null or i.material_code ilike '%' || btrim(p_f ->> 'material_code') || '%')
           and (nullif(p_f ->> 'reference', '') is null or i.material_reference ilike '%' || btrim(p_f ->> 'reference') || '%')
           and (nullif(p_f ->> 'unit', '') is null or upper(i.unit) = upper(btrim(p_f ->> 'unit')))
      )
    )
    and (nullif(p_f ->> 'q', '') is null
         or v.me_number ilike '%' || btrim(p_f ->> 'q') || '%'
         or v.sa_number ilike '%' || btrim(p_f ->> 'q') || '%'
         or v.requester_name ilike '%' || btrim(p_f ->> 'q') || '%'
         or v.requester_registration ilike '%' || btrim(p_f ->> 'q') || '%'
         or exists (select 1 from public.stock_movement_items i
                     where i.movement_id = v.id
                       and (i.material_name ilike '%' || btrim(p_f ->> 'q') || '%'
                            or i.material_code ilike '%' || btrim(p_f ->> 'q') || '%')));
$$;

create or replace function public.export_movements(p_filters jsonb default '{}'::jsonb, p_kind text default 'resumo')
returns jsonb
language plpgsql stable security invoker
set search_path = public, pg_temp
as $$
declare
  v_tz  text := (public.get_settings()).timezone;
  v_out jsonb;
begin
  if not public.has_any_role(array['gestor', 'admin', 'equipe_sa']::public.app_role[]) then
    raise exception 'Seu perfil não permite exportar dados.' using errcode = '42501';
  end if;

  if p_kind = 'itens' then
    select coalesce(jsonb_agg(to_jsonb(x) order by x.movement_at desc, x.me_number, x.line_number), '[]'::jsonb)
      into v_out
      from (
        select v.me_number, v.movement_at, v.warehouse_name, i.line_number, i.material_code,
               i.material_reference, i.material_name, i.unit, i.quantity_requested, i.quantity_delivered,
               i.location, coalesce(i.account_code || ' - ' || i.account_name, i.account_code) as account,
               v.contract_code || ' - ' || v.contract_name as contract, v.sector_name,
               v.service_front_name, v.service_order, v.fixed_asset, v.application_location,
               v.requester_name, v.requester_registration, v.sa_number, v.status, v.storekeeper_name,
               i.notes as item_notes, v.is_emergency, v.emergency_reason
          from public.v_movements v
          join public.stock_movement_items i on i.movement_id = v.id
         where public.movement_matches(v, coalesce(p_filters, '{}'::jsonb), v_tz)
         order by v.movement_at desc
         limit 50000
      ) x;
  else
    select coalesce(jsonb_agg(to_jsonb(x) order by x.movement_at desc), '[]'::jsonb)
      into v_out
      from (
        select v.me_number, v.movement_at, v.warehouse_name,
               v.contract_code || ' - ' || v.contract_name as contract, v.sector_name,
               v.service_front_name, v.service_order, v.fixed_asset, v.application_location,
               v.requester_name, v.requester_registration, v.item_count, v.total_delivered,
               v.sa_number, v.status, v.storekeeper_name, v.sa_informed_at, v.sa_informed_by_name,
               v.cancel_reason, v.notes, v.is_emergency, v.emergency_reason
          from public.v_movements v
         where public.movement_matches(v, coalesce(p_filters, '{}'::jsonb), v_tz)
         order by v.movement_at desc
         limit 20000
      ) x;
  end if;

  return v_out;
end;
$$;

-- ---------------------------------------------------------------------
-- Parâmetros: contrato padrão
-- ---------------------------------------------------------------------
create or replace function public.update_settings(p jsonb)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  if not public.is_admin() then
    raise exception 'Somente administrador pode alterar os parâmetros.' using errcode = '42501';
  end if;

  if p ? 'sa_number_pattern' then
    begin
      perform 'TESTE' ~ (p ->> 'sa_number_pattern');
    exception when others then
      raise exception 'Expressão regular da SA inválida.' using errcode = '22023';
    end;
  end if;
  if p ? 'timezone' and not exists (select 1 from pg_timezone_names where name = p ->> 'timezone') then
    raise exception 'Fuso horário inválido.' using errcode = '22023';
  end if;

  if nullif(p ->> 'default_contract_id', '') is not null
     and not exists (select 1 from public.contracts where id = (p ->> 'default_contract_id')::uuid and active) then
    raise exception 'Contrato padrão inválido ou inativo.' using errcode = '22023';
  end if;

  perform set_config('app.source', 'administracao', true);

  update public.app_settings s set
    me_prefix = coalesce(upper(p ->> 'me_prefix'), s.me_prefix),
    me_number_pattern = coalesce(p ->> 'me_number_pattern', s.me_number_pattern),
    me_sequence_digits = coalesce((p ->> 'me_sequence_digits')::smallint, s.me_sequence_digits),
    require_approval = coalesce((p ->> 'require_approval')::boolean, s.require_approval),
    allow_delivered_above_requested = coalesce((p ->> 'allow_delivered_above_requested')::boolean, s.allow_delivered_above_requested),
    allow_duplicate_material_lines = coalesce((p ->> 'allow_duplicate_material_lines')::boolean, s.allow_duplicate_material_lines),
    sa_number_unique = coalesce((p ->> 'sa_number_unique')::boolean, s.sa_number_unique),
    sa_number_pattern = coalesce(p ->> 'sa_number_pattern', s.sa_number_pattern),
    auto_complete_on_sa = coalesce((p ->> 'auto_complete_on_sa')::boolean, s.auto_complete_on_sa),
    timezone = coalesce(p ->> 'timezone', s.timezone),
    company_name = coalesce(nullif(btrim(p ->> 'company_name'), ''), s.company_name),
    default_contract_id = case when p ? 'default_contract_id' then nullif(p ->> 'default_contract_id', '')::uuid
                               else s.default_contract_id end
  where s.id = 1;

  return (select to_jsonb(s) from public.app_settings s where s.id = 1);
end;
$$;

-- ---------------------------------------------------------------------
-- Saída pelo assistente (inclui saída offline)
-- ---------------------------------------------------------------------
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
  v_at           timestamptz;             -- data/hora real da retirada
  v_offline      boolean := false;
  v_emergency    boolean := false;
  v_emerg_reason text := nullif(btrim(coalesce(p_payload ->> 'emergency_reason', '')), '');
begin
  -- Saída registrada sem internet: usa a data/hora real da retirada (até 7 dias atrás)
  if nullif(p_payload ->> 'offline_at', '') is not null then
    begin
      v_at := (p_payload ->> 'offline_at')::timestamptz;
    exception when others then
      raise exception 'Data/hora da saída offline inválida.' using errcode = '22023';
    end;
    if v_at > v_now + interval '5 minutes' or v_at < v_now - interval '7 days' then
      raise exception 'Saída offline com data fora do prazo (até 7 dias). Registre pela contingência em papel.' using errcode = '22023';
    end if;
    v_offline := true;
  else
    v_at := v_now;
  end if;

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
  -- Contrato fixo: sem contrato no envio, usa o contrato padrão dos parâmetros
  select id into v_contract_id from public.contracts
   where id = coalesce(nullif(p_payload ->> 'contract_id', '')::uuid, s.default_contract_id) and active;
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

  -- ME emergencial: somente controle (não vai para a SA nem para a baixa no ERP)
  begin
    v_emergency := coalesce(nullif(p_payload ->> 'emergency', '')::boolean, false);
  exception when others then
    raise exception 'Indicador de ME emergencial inválido.' using errcode = '22023';
  end;
  if v_emergency then
    if v_emerg_reason is null or length(v_emerg_reason) < 5 then
      raise exception 'Informe o motivo da retirada emergencial (mínimo de 5 caracteres).' using errcode = '22023';
    end if;
    if length(v_emerg_reason) > 500 then
      raise exception 'O motivo da emergência deve ter no máximo 500 caracteres.' using errcode = '22023';
    end if;
  else
    v_emerg_reason := null;
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
  v_year := extract(year from (v_at at time zone s.timezone))::int;
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
    v_signed_at := coalesce(nullif(v_sig ->> 'signed_at', '')::timestamptz, v_at);
  exception when others then
    v_signed_at := v_at;
  end;
  if v_signed_at > v_now + interval '5 minutes' or v_signed_at < v_at - interval '1 day' then
    v_signed_at := v_at;
  end if;

  -- 8) Gravação
  perform set_config('app.creating', 'on', true);
  perform set_config('app.source', case when v_offline then 'offline' else coalesce(nullif(p_payload ->> 'source', ''), 'app') end, true);

  v_number := public.next_me_number(v_wh.id, v_at);
  -- Sem ativo fixo: não precisa de SA, vai direto para a baixa no ERP (status sa_informada sem número de SA)
  -- Emergencial: já nasce concluída, apenas para controle
  v_status := case when v_emergency then 'concluida'
                   when s.require_approval then 'aguardando_aprovacao'
                   when v_fa_text is null then 'sa_informada'
                   else 'aguardando_sa' end;

  insert into public.stock_movements (
    id, me_number, movement_type, movement_at, warehouse_id, contract_id, sector_id,
    service_front_id, service_order_id, service_order_text, fixed_asset_id, fixed_asset_text, requires_sa,
    application_location_id, application_location_text, notes, status, entry_channel,
    requester_employee_id, requester_name, requester_registration, requested_at,
    received_by_employee_id, received_by_name, received_by_registration, received_at,
    storekeeper_id, created_by, updated_by, created_at,
    is_emergency, emergency_reason, completed_at, completed_by
  ) values (
    v_id, v_number, 'saida', v_at, v_wh.id, v_contract_id, v_sector_id,
    v_front_id, v_so_id, v_so_text, v_fa_id, v_fa_text, v_fa_text is not null and not v_emergency,
    v_appl_id, coalesce(nullif(btrim(coalesce(p_payload ->> 'application_location_text', '')), ''),
                        case when v_appl_id is null then '-' end),
    nullif(btrim(coalesce(p_payload ->> 'notes', '')), ''), v_status, case when v_offline then 'offline' else 'assistente' end,
    v_requester.id, v_requester.full_name, v_requester.registration, v_at,
    v_receiver.id, v_receiver.full_name, v_receiver.registration, v_signed_at,
    v_uid, v_uid, v_uid, v_now,
    v_emergency, v_emerg_reason, case when v_emergency then v_now end, case when v_emergency then v_uid end
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
                       'requisitante', v_requester.full_name, 'estoque', v_wh.name,
                       'emergencial', v_emergency, 'motivo_emergencia', v_emerg_reason),
    null
  );

  perform set_config('app.creating', 'off', true);

  return jsonb_build_object('id', v_id, 'me_number', v_number, 'status', v_status, 'emergency', v_emergency, 'created', true);
end;
$$;

-- ---------------------------------------------------------------------
-- Balcão: abertura e confirmação
-- ---------------------------------------------------------------------
create or replace function public.counter_open(p_payload jsonb)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_uid          uuid := auth.uid();
  v_id           uuid;
  v_existing     public.stock_movements;
  v_wh           public.warehouses;
  v_requester    public.employees;
  v_contract_id  uuid;
  v_sector_id    uuid;
  v_front_id     uuid;
  v_appl_id      uuid;
  v_so_text      text;
  v_so_id        uuid;
  v_fa_text      text;
  v_fa_id        uuid;
  v_number       text;
  v_now          timestamptz := now();
  v_code         text;
  v_terminal     uuid;
  v_session      public.counter_sessions;
  v_emergency    boolean := false;
  v_emerg_reason text := nullif(btrim(coalesce(p_payload ->> 'emergency_reason', '')), '');
begin
  if v_uid is null or not public.is_active_user() then
    raise exception 'Sessão inválida ou usuário inativo.' using errcode = '42501';
  end if;
  if not public.has_any_role(array['almoxarife', 'gestor', 'admin']::public.app_role[]) then
    raise exception 'Seu perfil não permite registrar saídas de material.' using errcode = '42501';
  end if;

  begin
    v_id := (p_payload ->> 'id')::uuid;
  exception when others then
    raise exception 'Identificador da movimentação inválido.' using errcode = '22023';
  end;
  if v_id is null then
    raise exception 'Identificador da movimentação é obrigatório.' using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(v_id::text, 0));

  select * into v_existing from public.stock_movements where id = v_id;
  if found then
    if v_existing.created_by <> v_uid then
      raise exception 'Identificador de movimentação já utilizado.' using errcode = '23505';
    end if;
    select * into v_session from public.counter_sessions where movement_id = v_id;
    return jsonb_build_object('id', v_id, 'me_number', v_existing.me_number, 'session_id', v_session.id,
                              'pairing_code', v_session.pairing_code, 'terminal_paired', v_session.terminal_user_id is not null,
                              'created', false);
  end if;

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

  -- Contrato fixo: sem contrato no envio, usa o contrato padrão dos parâmetros
  select id into v_contract_id from public.contracts
   where id = coalesce(nullif(p_payload ->> 'contract_id', '')::uuid, (public.get_settings()).default_contract_id) and active;
  if v_contract_id is null then
    raise exception 'Informe um contrato ativo.' using errcode = '22023';
  end if;
  select id into v_sector_id from public.sectors where id = nullif(p_payload ->> 'sector_id', '')::uuid and active;
  if v_sector_id is null then
    raise exception 'Informe um setor ativo.' using errcode = '22023';
  end if;
  if nullif(p_payload ->> 'service_front_id', '') is not null then
    select id into v_front_id from public.service_fronts where id = (p_payload ->> 'service_front_id')::uuid and active;
    if v_front_id is null then
      raise exception 'Frente de serviço/equipamento inválida ou inativa.' using errcode = '22023';
    end if;
  end if;
  if nullif(p_payload ->> 'application_location_id', '') is not null then
    select id into v_appl_id from public.application_locations where id = (p_payload ->> 'application_location_id')::uuid and active;
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

  -- ME emergencial: somente controle (não vai para a SA nem para a baixa no ERP)
  begin
    v_emergency := coalesce(nullif(p_payload ->> 'emergency', '')::boolean, false);
  exception when others then
    raise exception 'Indicador de ME emergencial inválido.' using errcode = '22023';
  end;
  if v_emergency then
    if v_emerg_reason is null or length(v_emerg_reason) < 5 then
      raise exception 'Informe o motivo da retirada emergencial (mínimo de 5 caracteres).' using errcode = '22023';
    end if;
    if length(v_emerg_reason) > 500 then
      raise exception 'O motivo da emergência deve ter no máximo 500 caracteres.' using errcode = '22023';
    end if;
  else
    v_emerg_reason := null;
  end if;

  select * into v_requester from public.employees where id = nullif(p_payload ->> 'requester_employee_id', '')::uuid;
  if v_requester.id is null then
    raise exception 'Identifique o funcionário solicitante.' using errcode = '22023';
  end if;
  if not v_requester.active then
    raise exception 'O funcionário % está inativo.', v_requester.full_name using errcode = '22023';
  end if;

  perform set_config('app.source', 'balcao', true);
  perform set_config('app.audit_action', 'me.balcao_aberta', true);
  v_number := public.next_me_number(v_wh.id, v_now);

  insert into public.stock_movements (
    id, me_number, movement_type, movement_at, warehouse_id, contract_id, sector_id,
    service_front_id, service_order_id, service_order_text, fixed_asset_id, fixed_asset_text, requires_sa,
    application_location_id, application_location_text, notes, status, entry_channel,
    requester_employee_id, requester_name, requester_registration, requested_at,
    received_by_employee_id, received_by_name, received_by_registration,
    storekeeper_id, created_by, updated_by, created_at,
    is_emergency, emergency_reason
  ) values (
    v_id, v_number, 'saida', v_now, v_wh.id, v_contract_id, v_sector_id,
    v_front_id, v_so_id, v_so_text, v_fa_id, v_fa_text, v_fa_text is not null and not v_emergency,
    v_appl_id, coalesce(nullif(btrim(coalesce(p_payload ->> 'application_location_text', '')), ''),
                        case when v_appl_id is null then '-' end),
    nullif(btrim(coalesce(p_payload ->> 'notes', '')), ''), 'rascunho', 'balcao',
    v_requester.id, v_requester.full_name, v_requester.registration, v_now,
    v_requester.id, v_requester.full_name, v_requester.registration,
    v_uid, v_uid, v_uid, v_now,
    v_emergency, v_emerg_reason
  );

  -- Tablet escolhido pelo almoxarife (terminal_user_id) ou, se não informado e
  -- reuse_terminal = true, o tablet da separação anterior deste almoxarife (se livre)
  if nullif(p_payload ->> 'terminal_user_id', '') is not null then
    v_terminal := (p_payload ->> 'terminal_user_id')::uuid;
    perform public._counter_check_terminal(v_terminal, v_wh.id, null);
  elsif coalesce((p_payload ->> 'reuse_terminal')::boolean, false) then
    select s.terminal_user_id into v_terminal
      from public.counter_sessions s
     where s.opened_by = v_uid and s.warehouse_id = v_wh.id and s.terminal_user_id is not null
     order by s.created_at desc limit 1;
    if v_terminal is not null and exists (
         select 1 from public.counter_sessions s
          where s.terminal_user_id = v_terminal and s.status in ('em_separacao', 'aguardando_confirmacao')) then
      v_terminal := null; -- tablet ocupado em outra separação
    end if;
  end if;

  v_code := public._counter_new_code();
  insert into public.counter_sessions (movement_id, warehouse_id, opened_by, pairing_code, pairing_expires_at,
                                       terminal_user_id, paired_at, last_event)
  values (v_id, v_wh.id, v_uid, v_code, v_now + interval '30 minutes',
          v_terminal, case when v_terminal is not null then v_now end, 'me_aberta')
  returning * into v_session;

  perform public.write_audit('me.balcao_aberta', 'stock_movements', v_id::text, v_id, v_wh.id, null,
    jsonb_build_object('me_number', v_number, 'solicitante', v_requester.full_name, 'estoque', v_wh.name,
                       'tablet_reaproveitado', v_terminal is not null,
                       'emergencial', v_emergency, 'motivo_emergencia', v_emerg_reason), null);

  return jsonb_build_object('id', v_id, 'me_number', v_number, 'session_id', v_session.id,
                            'pairing_code', v_code, 'terminal_paired', v_terminal is not null, 'created', true);
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

  -- Emergencial: concluída na confirmação, apenas para controle (sem SA e sem baixa no ERP)
  v_status := case when v_m.is_emergency then 'concluida'
                   when s.require_approval then 'aguardando_aprovacao'
                   when v_m.requires_sa then 'aguardando_sa'
                   else 'sa_informada' end;

  perform set_config('app.audit_action', 'me.confirmada', true);
  perform set_config('app.source', 'balcao', true);
  perform set_config('app.justification', 'Confirmada pelo solicitante (' || v_method || ')', true);
  update public.stock_movements
     set status = v_status, confirmed_at = v_now, confirmation_method = v_method, received_at = v_now,
         completed_at = case when v_m.is_emergency then v_now else completed_at end,
         completed_by = case when v_m.is_emergency then v_m.storekeeper_id else completed_by end,
         updated_by = auth.uid()
   where id = v_m.id;
  perform public._counter_touch(v_m.id, 'me_confirmada', 'confirmada');

  perform public.write_audit('me.confirmada', 'stock_movements', v_m.id::text, v_m.id, v_m.warehouse_id, null,
    jsonb_build_object('me_number', v_m.me_number, 'solicitante', v_m.requester_name, 'metodo', v_method,
                       'tentativa', v_att.id, 'itens', v_m.item_count, 'total_atendido', v_m.total_delivered,
                       'almoxarife', v_m.storekeeper_id, 'status', v_status,
                       'foto', v_photo is not null, 'sem_foto_motivo', v_no_photo,
                       'emergencial', v_m.is_emergency), null);

  return jsonb_build_object('id', v_m.id, 'me_number', v_m.me_number, 'status', v_status);
end;
$$;

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
      'id', v_s.id, 'status', v_s.status, 'version', v_s.version, 'last_event', v_s.last_event,
      'last_event_at', v_s.last_event_at, 'terminal_paired', v_s.terminal_user_id is not null,
      'paired_at', v_s.paired_at,
      -- o código só é mostrado ao almoxarife/gestor
      'pairing_code', case when v_s.terminal_user_id = auth.uid() then null else v_s.pairing_code end,
      'pairing_expires_at', v_s.pairing_expires_at,
      'terminal_name', (select coalesce(full_name, email) from public.profiles where id = v_s.terminal_user_id)
    ),
    'movement', jsonb_build_object(
      'id', v_m.id, 'me_number', v_m.me_number, 'status', v_m.status,
      'warehouse_name', (select name from public.warehouses where id = v_m.warehouse_id),
      'warehouse_code', (select code from public.warehouses where id = v_m.warehouse_id),
      'requester_name', v_m.requester_name, 'requester_registration', v_m.requester_registration,
      'storekeeper_name', (select coalesce(full_name, email) from public.profiles where id = v_m.storekeeper_id),
      'movement_at', v_m.movement_at, 'separation_finished_at', v_m.separation_finished_at,
      'confirmed_at', v_m.confirmed_at, 'cancel_reason', v_m.cancel_reason,
      'item_count', v_m.item_count, 'total_delivered', v_m.total_delivered,
      'fixed_asset', v_m.fixed_asset_text,
      'is_emergency', v_m.is_emergency
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

grant select on public.v_movements to authenticated;
grant execute on function public.movement_matches(public.v_movements, jsonb, text) to authenticated;
grant execute on function public.export_movements(jsonb, text) to authenticated;
grant execute on function public.update_settings(jsonb) to authenticated;
grant execute on function public.create_movement(jsonb) to authenticated;
grant execute on function public.counter_open(jsonb) to authenticated;
grant execute on function public.counter_confirm(uuid, jsonb) to authenticated;
grant execute on function public.counter_snapshot(uuid) to authenticated;
