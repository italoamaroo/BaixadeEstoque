-- =====================================================================
-- 04 - NUMERAÇÃO DA ME, VIEW DE CONSULTA E FUNÇÕES RPC DO FLUXO
-- Toda gravação na ME passa por estas funções (SECURITY DEFINER com
-- verificação explícita de perfil e estoque). Não há política de
-- INSERT/UPDATE/DELETE direto nas tabelas de movimentação.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Geração segura do número da ME
-- INSERT ... ON CONFLICT DO UPDATE bloqueia a linha (estoque, ano) até o
-- fim da transação: duas saídas simultâneas no mesmo estoque recebem
-- números diferentes, e se a transação falhar o número é devolvido
-- (rollback), sem buracos na sequência.
-- ---------------------------------------------------------------------
create or replace function public.next_me_number(p_warehouse_id uuid, p_at timestamptz default now())
returns text
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  s        public.app_settings := public.get_settings();
  v_code   text;
  v_year   int;
  v_seq    int;
  v_number text;
begin
  select code into v_code from public.warehouses where id = p_warehouse_id;
  if v_code is null then
    raise exception 'Estoque não encontrado.' using errcode = 'P0001';
  end if;

  v_year := extract(year from (p_at at time zone s.timezone))::int;

  insert into public.movement_sequences as ms (warehouse_id, year, last_value, updated_at)
  values (p_warehouse_id, v_year, 1, now())
  on conflict (warehouse_id, year)
  do update set last_value = ms.last_value + 1, updated_at = now()
  returning ms.last_value into v_seq;

  v_number := s.me_number_pattern;
  v_number := replace(v_number, '{PREFIXO}', s.me_prefix);
  v_number := replace(v_number, '{ESTOQUE}', v_code);
  v_number := replace(v_number, '{ANO}', v_year::text);
  v_number := replace(v_number, '{SEQ}', lpad(v_seq::text, s.me_sequence_digits, '0'));
  return v_number;
end;
$$;
revoke all on function public.next_me_number(uuid, timestamptz) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- View de consulta das MEs (respeita RLS de quem consulta)
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
  pu.full_name as updated_by_name
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

-- ---------------------------------------------------------------------
-- Predicado único de filtros (usado na lista, no dashboard e no Excel)
-- Chaves aceitas em p_f (todas opcionais):
--   date_from, date_to (AAAA-MM-DD, data local), warehouse_id, me_number,
--   sa_number, status (array), material, material_code, reference, unit,
--   sector_id, service_front_id, service_order, fixed_asset,
--   application_location_id, requester_employee_id, requester,
--   storekeeper_id, responsible_user_id, pending_sa (bool), q (pesquisa rápida)
-- ---------------------------------------------------------------------
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

-- ---------------------------------------------------------------------
-- Lista paginada no servidor
-- ---------------------------------------------------------------------
create or replace function public.search_movements(
  p_filters   jsonb default '{}'::jsonb,
  p_page      int default 1,
  p_page_size int default 25,
  p_sort      text default 'movement_at',
  p_dir       text default 'desc'
)
returns jsonb
language plpgsql stable security invoker
set search_path = public, pg_temp
as $$
declare
  v_tz     text := (public.get_settings()).timezone;
  v_size   int := least(greatest(coalesce(p_page_size, 25), 1), 200);
  v_page   int := greatest(coalesce(p_page, 1), 1);
  v_sort   text := case when p_sort in ('movement_at', 'me_number', 'warehouse_name', 'status', 'sa_number',
                                         'requester_name', 'item_count', 'updated_at', 'sector_name')
                        then p_sort else 'movement_at' end;
  v_asc    boolean := lower(coalesce(p_dir, 'desc')) = 'asc';
  v_total  bigint;
  v_rows   jsonb;
begin
  if not public.is_active_user() then
    raise exception 'Sessão inválida ou usuário inativo.' using errcode = '42501';
  end if;

  with f as (
    select v.* from public.v_movements v
     where public.movement_matches(v, coalesce(p_filters, '{}'::jsonb), v_tz)
  ),
  counted as (select count(*) as total from f),
  page as (
    select * from f
     order by
       case when v_asc then
         case v_sort
           when 'me_number' then me_number
           when 'warehouse_name' then warehouse_name
           when 'status' then status::text
           when 'sa_number' then sa_number
           when 'requester_name' then requester_name
           when 'sector_name' then sector_name
         end end asc nulls last,
       case when not v_asc then
         case v_sort
           when 'me_number' then me_number
           when 'warehouse_name' then warehouse_name
           when 'status' then status::text
           when 'sa_number' then sa_number
           when 'requester_name' then requester_name
           when 'sector_name' then sector_name
         end end desc nulls last,
       case when v_asc and v_sort = 'item_count' then item_count end asc,
       case when not v_asc and v_sort = 'item_count' then item_count end desc,
       case when v_asc and v_sort = 'updated_at' then updated_at end asc,
       case when not v_asc and v_sort = 'updated_at' then updated_at end desc,
       case when v_asc then movement_at end asc,
       case when not v_asc then movement_at end desc,
       me_number desc
     limit v_size offset (v_page - 1) * v_size
  )
  select (select total from counted),
         coalesce((select jsonb_agg(to_jsonb(page)) from page), '[]'::jsonb)
    into v_total, v_rows;

  return jsonb_build_object('total', v_total, 'page', v_page, 'page_size', v_size, 'rows', v_rows);
end;
$$;

-- ---------------------------------------------------------------------
-- Material: busca por QR Code / código e pesquisa manual
-- ---------------------------------------------------------------------
create or replace function public.find_material_by_code(p_code text)
returns jsonb
language plpgsql stable security invoker
set search_path = public, pg_temp
as $$
declare
  v_code text := btrim(coalesce(p_code, ''));
  v_row  jsonb;
begin
  if not public.is_active_user() then
    raise exception 'Sessão inválida ou usuário inativo.' using errcode = '42501';
  end if;

  -- Aceita também URLs/conteúdos com prefixo: usa o último segmento.
  if position('/' in v_code) > 0 then
    v_code := regexp_replace(v_code, '^.*/', '');
  end if;

  if v_code !~ '^[A-Za-z0-9._:/-]{1,80}$' then
    return jsonb_build_object('found', false, 'reason', 'invalido');
  end if;

  select to_jsonb(x) into v_row from (
    select m.id, m.code, m.reference, m.name, m.description, m.unit, m.location,
           m.account_id, a.code as account_code, a.name as account_name,
           m.category_id, mc.name as category_name,
           m.warehouse_id, w.name as warehouse_name,
           m.qr_code, m.active
      from public.materials m
      left join public.accounts a on a.id = m.account_id
      left join public.material_categories mc on mc.id = m.category_id
      left join public.warehouses w on w.id = m.warehouse_id
     where m.qr_code = v_code
        or m.id in (select q.material_id from public.material_qr_codes q where q.code = v_code and q.active)
        or upper(m.code) = upper(v_code)
     order by (m.qr_code = v_code) desc
     limit 1
  ) x;

  if v_row is null then
    return jsonb_build_object('found', false, 'reason', 'nao_cadastrado', 'code', v_code);
  end if;

  return jsonb_build_object('found', true, 'material', v_row);
end;
$$;

create or replace function public.search_materials(
  p_term        text,
  p_only_active boolean default true,
  p_limit       int default 30
)
returns jsonb
language plpgsql stable security invoker
set search_path = public, pg_temp
as $$
declare
  v_term text := btrim(coalesce(p_term, ''));
begin
  if not public.is_active_user() then
    raise exception 'Sessão inválida ou usuário inativo.' using errcode = '42501';
  end if;

  return coalesce((
    select jsonb_agg(to_jsonb(x)) from (
      select m.id, m.code, m.reference, m.name, m.description, m.unit, m.location,
             m.account_id, a.code as account_code, a.name as account_name,
             m.category_id, mc.name as category_name,
             m.warehouse_id, w.name as warehouse_name,
             m.qr_code, m.active
        from public.materials m
        left join public.accounts a on a.id = m.account_id
        left join public.material_categories mc on mc.id = m.category_id
        left join public.warehouses w on w.id = m.warehouse_id
       where (not coalesce(p_only_active, true) or m.active)
         and (v_term = ''
              or m.code ilike '%' || v_term || '%'
              or m.reference ilike '%' || v_term || '%'
              or m.name ilike '%' || v_term || '%'
              or m.description ilike '%' || v_term || '%')
       order by (upper(m.code) = upper(v_term)) desc, m.name
       limit least(greatest(coalesce(p_limit, 30), 1), 100)
    ) x
  ), '[]'::jsonb);
end;
$$;

-- ---------------------------------------------------------------------
-- CRIAÇÃO DA ME (transação única e idempotente)
-- Pré-requisito: a imagem da assinatura já enviada ao bucket
-- 'assinaturas' no caminho {COD_ESTOQUE}/{ANO}/{ID_DA_ME}/arquivo.png
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
  v_status := case when s.require_approval then 'aguardando_aprovacao' else 'aguardando_sa' end;

  insert into public.stock_movements (
    id, me_number, movement_type, movement_at, warehouse_id, contract_id, sector_id,
    service_front_id, service_order_id, service_order_text, fixed_asset_id, fixed_asset_text,
    application_location_id, application_location_text, notes, status,
    requester_employee_id, requester_name, requester_registration, requested_at,
    received_by_employee_id, received_by_name, received_by_registration, received_at,
    storekeeper_id, created_by, updated_by, created_at
  ) values (
    v_id, v_number, 'saida', v_now, v_wh.id, v_contract_id, v_sector_id,
    v_front_id, v_so_id, v_so_text, v_fa_id, v_fa_text,
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

-- ---------------------------------------------------------------------
-- Aprovação (quando o parâmetro require_approval estiver ativo)
-- ---------------------------------------------------------------------
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

  update public.stock_movements
     set status = 'aguardando_sa', approved_by = auth.uid(), approved_at = now()
   where id = p_id;

  return jsonb_build_object('id', p_id, 'status', 'aguardando_sa');
end;
$$;

-- ---------------------------------------------------------------------
-- Informar / corrigir número da SA
-- ---------------------------------------------------------------------
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

-- ---------------------------------------------------------------------
-- Concluir (SA informada e validada)
-- ---------------------------------------------------------------------
create or replace function public.complete_movement(p_id uuid)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_m public.stock_movements;
begin
  if not public.has_any_role(array['equipe_sa', 'gestor', 'admin']::public.app_role[]) then
    raise exception 'Seu perfil não permite concluir a ME.' using errcode = '42501';
  end if;

  select * into v_m from public.stock_movements where id = p_id for update;
  if v_m.id is null or not public.can_access_warehouse(v_m.warehouse_id) then
    raise exception 'ME não encontrada.' using errcode = 'P0002';
  end if;
  if v_m.status <> 'sa_informada' then
    raise exception 'Somente MEs com SA informada podem ser concluídas (status atual: %).', v_m.status using errcode = 'P0001';
  end if;

  perform set_config('app.audit_action', 'me.concluida', true);
  update public.stock_movements
     set status = 'concluida', completed_at = now(), completed_by = auth.uid()
   where id = p_id;

  return jsonb_build_object('id', p_id, 'status', 'concluida');
end;
$$;

-- ---------------------------------------------------------------------
-- Cancelamento lógico
-- ---------------------------------------------------------------------
create or replace function public.cancel_movement(p_id uuid, p_reason text)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_m      public.stock_movements;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if not public.has_any_role(array['gestor', 'admin']::public.app_role[]) then
    raise exception 'Somente gestor ou administrador pode cancelar uma ME.' using errcode = '42501';
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

-- ---------------------------------------------------------------------
-- Correção administrativa (gestor/admin, com justificativa)
-- p_changes: chaves de cabeçalho e/ou "items": [{id, quantity_requested, quantity_delivered, notes}]
-- ---------------------------------------------------------------------
create or replace function public.correct_movement(p_id uuid, p_changes jsonb, p_justification text)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  s         public.app_settings := public.get_settings();
  v_m       public.stock_movements;
  v_just    text := nullif(btrim(coalesce(p_justification, '')), '');
  v_item    jsonb;
  v_req     numeric;
  v_del     numeric;
  v_new_wh  uuid;
  v_cnt     int;
begin
  if not public.has_any_role(array['gestor', 'admin']::public.app_role[]) then
    raise exception 'Somente gestor ou administrador pode corrigir uma ME.' using errcode = '42501';
  end if;
  if v_just is null or length(v_just) < 5 then
    raise exception 'Informe a justificativa da correção (mínimo 5 caracteres).' using errcode = '22023';
  end if;

  select * into v_m from public.stock_movements where id = p_id for update;
  if v_m.id is null or not public.can_access_warehouse(v_m.warehouse_id) then
    raise exception 'ME não encontrada.' using errcode = 'P0002';
  end if;
  if v_m.status = 'cancelada' then
    raise exception 'ME cancelada é somente consulta.' using errcode = 'P0001';
  end if;

  perform set_config('app.correction', 'on', true);
  perform set_config('app.audit_action', 'me.corrigida', true);
  perform set_config('app.justification', v_just, true);

  if p_changes ? 'warehouse_id' then
    v_new_wh := (p_changes ->> 'warehouse_id')::uuid;
    if not exists (select 1 from public.warehouses where id = v_new_wh and active)
       or not public.can_access_warehouse(v_new_wh) then
      raise exception 'Estoque de destino inválido ou sem permissão.' using errcode = '42501';
    end if;
  end if;

  if p_changes ? 'contract_id' and not exists (select 1 from public.contracts where id = (p_changes ->> 'contract_id')::uuid and active) then
    raise exception 'Contrato inválido ou inativo.' using errcode = '22023';
  end if;
  if p_changes ? 'sector_id' and not exists (select 1 from public.sectors where id = (p_changes ->> 'sector_id')::uuid and active) then
    raise exception 'Setor inválido ou inativo.' using errcode = '22023';
  end if;

  update public.stock_movements m set
    warehouse_id = coalesce(v_new_wh, m.warehouse_id),
    contract_id = case when p_changes ? 'contract_id' then (p_changes ->> 'contract_id')::uuid else m.contract_id end,
    sector_id = case when p_changes ? 'sector_id' then (p_changes ->> 'sector_id')::uuid else m.sector_id end,
    service_front_id = case when p_changes ? 'service_front_id' then nullif(p_changes ->> 'service_front_id', '')::uuid else m.service_front_id end,
    service_order_text = case when p_changes ? 'service_order_text' then nullif(btrim(p_changes ->> 'service_order_text'), '') else m.service_order_text end,
    service_order_id = case when p_changes ? 'service_order_text'
                            then (select id from public.service_orders where upper(code) = upper(btrim(p_changes ->> 'service_order_text')) limit 1)
                            else m.service_order_id end,
    fixed_asset_text = case when p_changes ? 'fixed_asset_text' then nullif(btrim(p_changes ->> 'fixed_asset_text'), '') else m.fixed_asset_text end,
    fixed_asset_id = case when p_changes ? 'fixed_asset_text'
                          then (select id from public.fixed_assets where upper(code) = upper(btrim(p_changes ->> 'fixed_asset_text')) limit 1)
                          else m.fixed_asset_id end,
    application_location_id = case when p_changes ? 'application_location_id' then nullif(p_changes ->> 'application_location_id', '')::uuid else m.application_location_id end,
    application_location_text = case when p_changes ? 'application_location_text' then nullif(btrim(p_changes ->> 'application_location_text'), '') else m.application_location_text end,
    notes = case when p_changes ? 'notes' then nullif(btrim(p_changes ->> 'notes'), '') else m.notes end
  where m.id = p_id;

  if jsonb_typeof(p_changes -> 'items') = 'array' then
    for v_item in select * from jsonb_array_elements(p_changes -> 'items') loop
      v_req := (v_item ->> 'quantity_requested')::numeric;
      v_del := (v_item ->> 'quantity_delivered')::numeric;
      if v_req is null or v_req <= 0 or v_del is null or v_del <= 0 then
        raise exception 'As quantidades devem ser maiores que zero.' using errcode = '22023';
      end if;
      if v_del > v_req and not s.allow_delivered_above_requested then
        raise exception 'A quantidade atendida não pode ser maior que a solicitada.' using errcode = '22023';
      end if;
      update public.stock_movement_items
         set quantity_requested = v_req,
             quantity_delivered = v_del,
             notes = case when v_item ? 'notes' then left(nullif(btrim(v_item ->> 'notes'), ''), 500) else notes end
       where id = (v_item ->> 'id')::uuid and movement_id = p_id;
      get diagnostics v_cnt = row_count;
      if v_cnt = 0 then
        raise exception 'Item informado não pertence a esta ME.' using errcode = '22023';
      end if;
    end loop;
  end if;

  return jsonb_build_object('id', p_id, 'status', v_m.status);
end;
$$;

-- ---------------------------------------------------------------------
-- Substituição de assinatura (mantém a anterior no histórico)
-- ---------------------------------------------------------------------
create or replace function public.replace_signature(
  p_id           uuid,
  p_storage_path text,
  p_employee_id  uuid,
  p_reason       text
)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_m       public.stock_movements;
  v_wh      public.warehouses;
  v_emp     public.employees;
  v_obj     record;
  v_reason  text := nullif(btrim(coalesce(p_reason, '')), '');
  v_new_id  uuid;
begin
  if not public.has_any_role(array['gestor', 'admin']::public.app_role[]) then
    raise exception 'Somente gestor ou administrador pode substituir uma assinatura.' using errcode = '42501';
  end if;
  if v_reason is null or length(v_reason) < 5 then
    raise exception 'Informe a justificativa da nova assinatura (mínimo 5 caracteres).' using errcode = '22023';
  end if;

  select * into v_m from public.stock_movements where id = p_id for update;
  if v_m.id is null or not public.can_access_warehouse(v_m.warehouse_id) then
    raise exception 'ME não encontrada.' using errcode = 'P0002';
  end if;
  if v_m.status = 'cancelada' then
    raise exception 'ME cancelada é somente consulta.' using errcode = 'P0001';
  end if;

  select * into v_wh from public.warehouses where id = v_m.warehouse_id;
  if p_storage_path not like v_wh.code || '/%/' || p_id::text || '/%' then
    raise exception 'Caminho da assinatura inválido para esta ME.' using errcode = '22023';
  end if;

  select * into v_emp from public.employees where id = p_employee_id and active;
  if v_emp.id is null then
    raise exception 'Funcionário inválido ou inativo.' using errcode = '22023';
  end if;

  select o.name, nullif(o.metadata ->> 'size', '')::int as size_bytes
    into v_obj
    from storage.objects o
   where o.bucket_id = 'assinaturas' and o.name = p_storage_path;
  if v_obj.name is null then
    raise exception 'Arquivo da nova assinatura não encontrado no armazenamento.' using errcode = '22023';
  end if;

  perform set_config('app.signature_replace', 'on', true);
  perform set_config('app.justification', v_reason, true);

  update public.signatures
     set is_current = false, replaced_at = now(), replaced_by = auth.uid(), replacement_reason = v_reason
   where movement_id = p_id and is_current;

  insert into public.signatures (movement_id, employee_id, signer_name, signer_registration, bucket,
                                 storage_path, mime_type, size_bytes, signed_at, uploaded_by, is_current)
  values (p_id, v_emp.id, v_emp.full_name, v_emp.registration, 'assinaturas',
          p_storage_path, 'image/png', v_obj.size_bytes, now(), auth.uid(), true)
  returning id into v_new_id;

  perform set_config('app.correction', 'on', true);
  perform set_config('app.audit_action', 'me.recebedor_alterado', true);
  update public.stock_movements
     set received_by_employee_id = v_emp.id,
         received_by_name = v_emp.full_name,
         received_by_registration = v_emp.registration,
         received_at = now()
   where id = p_id;

  return jsonb_build_object('id', p_id, 'signature_id', v_new_id);
end;
$$;

-- ---------------------------------------------------------------------
-- Eventos de interface relevantes (impressão, PDF, exportação)
-- ---------------------------------------------------------------------
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
  if p_action not in ('me.impressa', 'me.pdf_gerado', 'me.assinatura_consultada',
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

-- ---------------------------------------------------------------------
-- Exportação (dados reais, mesmos filtros da lista)
-- ---------------------------------------------------------------------
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
               i.notes as item_notes
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
               v.cancel_reason, v.notes
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
-- Dashboard (indicadores separados por unidade de medida)
--   *_mes      = quantidade de MEs
--   *_lines    = quantidade de linhas de itens
--   *_qty      = soma das quantidades atendidas (somente dentro do mesmo material/unidade)
-- Itens e quantidades desconsideram MEs canceladas.
-- ---------------------------------------------------------------------
create or replace function public.dashboard_stats(p_filters jsonb default '{}'::jsonb)
returns jsonb
language plpgsql stable security invoker
set search_path = public, pg_temp
as $$
declare
  v_tz     text := (public.get_settings()).timezone;
  v_today  date := (now() at time zone v_tz)::date;
  v_result jsonb;
begin
  if not public.is_active_user() then
    raise exception 'Sessão inválida ou usuário inativo.' using errcode = '42501';
  end if;

  with _dash_mv as (
    select v.id, v.warehouse_id, v.warehouse_name, v.status, v.movement_at,
           (v.movement_at at time zone v_tz)::date as local_date,
           v.sector_name, v.service_front_name, v.storekeeper_name, v.item_count, v.total_delivered
      from public.v_movements v
     where public.movement_matches(v, coalesce(p_filters, '{}'::jsonb), v_tz)
  )
  select jsonb_build_object(
    'cards', (
      select jsonb_build_object(
        'total_mes',             count(*),
        'today_mes',             count(*) filter (where local_date = v_today),
        'item_lines',            coalesce(sum(item_count) filter (where status <> 'cancelada'), 0),
        'qty_delivered',         coalesce(sum(total_delivered) filter (where status <> 'cancelada'), 0),
        'aguardando_aprovacao',  count(*) filter (where status = 'aguardando_aprovacao'),
        'aguardando_sa',         count(*) filter (where status = 'aguardando_sa'),
        'sa_informada',          count(*) filter (where status = 'sa_informada'),
        'concluida',             count(*) filter (where status = 'concluida'),
        'cancelada',             count(*) filter (where status = 'cancelada')
      ) from _dash_mv
    ),
    'by_warehouse', coalesce((
      select jsonb_agg(jsonb_build_object('warehouse_id', w.id, 'warehouse', w.name, 'code', w.code,
                                          'mes', coalesce(x.mes, 0), 'pending_sa', coalesce(x.pending, 0),
                                          'item_lines', coalesce(x.lines, 0)) order by w.name)
        from public.warehouses w
        left join (
          select warehouse_id, count(*) as mes,
                 count(*) filter (where status = 'aguardando_sa') as pending,
                 sum(item_count) filter (where status <> 'cancelada') as lines
            from _dash_mv group by warehouse_id
        ) x on x.warehouse_id = w.id
       where w.active and public.can_access_warehouse(w.id)
    ), '[]'::jsonb),
    'daily', coalesce((
      select jsonb_agg(jsonb_build_object('date', d, 'warehouse', wn, 'mes', c) order by d, wn)
        from (select local_date as d, warehouse_name as wn, count(*) as c
                from _dash_mv
               where local_date >= coalesce(nullif(p_filters ->> 'date_from', '')::date, v_today - 29)
               group by 1, 2) t
    ), '[]'::jsonb),
    'weekly', coalesce((
      select jsonb_agg(jsonb_build_object('week', wk, 'warehouse', wn, 'mes', c) order by wk, wn)
        from (select date_trunc('week', local_date)::date as wk, warehouse_name as wn, count(*) as c
                from _dash_mv
               where local_date >= coalesce(nullif(p_filters ->> 'date_from', '')::date, v_today - 83)
               group by 1, 2) t
    ), '[]'::jsonb),
    'monthly', coalesce((
      select jsonb_agg(jsonb_build_object('month', mo, 'warehouse', wn, 'mes', c) order by mo, wn)
        from (select to_char(local_date, 'YYYY-MM') as mo, warehouse_name as wn, count(*) as c
                from _dash_mv
               where local_date >= coalesce(nullif(p_filters ->> 'date_from', '')::date, (date_trunc('month', v_today) - interval '11 months')::date)
               group by 1, 2) t
    ), '[]'::jsonb),
    'qty_by_unit', coalesce((
      select jsonb_agg(jsonb_build_object('unit', unit, 'qty', qty) order by qty desc)
        from (select i.unit, sum(i.quantity_delivered) as qty
                from public.stock_movement_items i
                join _dash_mv d on d.id = i.movement_id and d.status <> 'cancelada'
               group by 1) t
    ), '[]'::jsonb),
    'top_materials_lines', coalesce((
      select jsonb_agg(jsonb_build_object('material', name, 'code', code, 'lines', lines) order by lines desc, name)
        from (select i.material_name as name, i.material_code as code, count(*) as lines
                from public.stock_movement_items i
                join _dash_mv d on d.id = i.movement_id and d.status <> 'cancelada'
               group by 1, 2 order by 3 desc, 1 limit 10) t
    ), '[]'::jsonb),
    'top_materials_qty', coalesce((
      select jsonb_agg(jsonb_build_object('material', name, 'code', code, 'unit', unit, 'qty', qty) order by qty desc, name)
        from (select i.material_name as name, i.material_code as code, i.unit, sum(i.quantity_delivered) as qty
                from public.stock_movement_items i
                join _dash_mv d on d.id = i.movement_id and d.status <> 'cancelada'
               group by 1, 2, 3 order by 4 desc, 1 limit 10) t
    ), '[]'::jsonb),
    'by_sector', coalesce((
      select jsonb_agg(jsonb_build_object('label', sector_name, 'mes', c) order by c desc)
        from (select sector_name, count(*) as c from _dash_mv where status <> 'cancelada'
               group by 1 order by 2 desc limit 12) t
    ), '[]'::jsonb),
    'by_service_front', coalesce((
      select jsonb_agg(jsonb_build_object('label', coalesce(service_front_name, 'Não informado'), 'mes', c) order by c desc)
        from (select service_front_name, count(*) as c from _dash_mv where status <> 'cancelada'
               group by 1 order by 2 desc limit 12) t
    ), '[]'::jsonb),
    'by_user', coalesce((
      select jsonb_agg(jsonb_build_object('label', coalesce(storekeeper_name, '—'), 'mes', c) order by c desc)
        from (select storekeeper_name, count(*) as c from _dash_mv where status <> 'cancelada'
               group by 1 order by 2 desc limit 12) t
    ), '[]'::jsonb),
    'pending_aging', coalesce((
      select jsonb_agg(jsonb_build_object('warehouse', warehouse_name, 'bucket', bucket, 'mes', c) order by warehouse_name, ord)
        from (
          select warehouse_name,
                 case when age_days <= 1 then 'Até 1 dia' when age_days <= 3 then '2 a 3 dias'
                      when age_days <= 7 then '4 a 7 dias' else 'Mais de 7 dias' end as bucket,
                 case when age_days <= 1 then 1 when age_days <= 3 then 2 when age_days <= 7 then 3 else 4 end as ord,
                 count(*) as c
            from (select warehouse_name, (v_today - local_date) as age_days from _dash_mv where status = 'aguardando_sa') a
           group by 1, 2, 3
        ) t
    ), '[]'::jsonb)
  ) into v_result;

  return v_result;
end;
$$;
