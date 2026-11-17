-- =====================================================================
-- BALCÃO DE SEPARAÇÃO (leitor QR sem fio + tela do solicitante)
-- Fluxo: almoxarife abre a ME no balcão (status rascunho = "Em separação")
--   -> bipa os materiais (cada leitura é gravada na hora)
--   -> FINALIZAR SEPARAÇÃO (aguardando_assinatura = "Aguardando confirmação")
--   -> solicitante confere no tablet e CONFIRMA (assinatura agora; facial plugável)
--   -> ME confirmada segue o fluxo normal (SA / baixa no ERP).
-- O tablet do solicitante usa um usuário com perfil "terminal", pareado à ME
-- por um código de 6 dígitos. O perfil terminal NÃO enxerga as MEs do estoque:
-- só a ME com que está pareado, pelas funções deste arquivo.
-- Pré-requisito: o valor 'terminal' no tipo app_role (arquivo 16a).
-- Pode ser reexecutado.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) Perfil terminal não enxerga MEs pelo vínculo de estoque
-- ---------------------------------------------------------------------
create or replace function public.can_access_warehouse(p_warehouse_id uuid)
returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$
  select public.is_admin()
      or exists (
        select 1
          from public.user_warehouses uw
          join public.profiles p on p.id = uw.user_id
         where uw.user_id = auth.uid()
           and uw.warehouse_id = p_warehouse_id
           and p.active
           and exists (select 1 from public.user_roles ur where ur.user_id = p.id and ur.role <> 'terminal')
      );
$$;

-- Terminal vinculado ao estoque (usado só no pareamento)
create or replace function public.is_terminal_of_warehouse(p_warehouse_id uuid)
returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
      from public.user_warehouses uw
      join public.profiles p on p.id = uw.user_id
      join public.user_roles ur on ur.user_id = p.id and ur.role = 'terminal'
     where uw.user_id = auth.uid() and uw.warehouse_id = p_warehouse_id and p.active
  );
$$;

-- ---------------------------------------------------------------------
-- 2) Campos novos na ME
-- ---------------------------------------------------------------------
alter table public.stock_movements add column if not exists entry_channel text not null default 'assistente';
alter table public.stock_movements add column if not exists separation_finished_at timestamptz;
alter table public.stock_movements add column if not exists confirmed_at timestamptz;
alter table public.stock_movements add column if not exists confirmation_method text;
alter table public.stock_movements drop constraint if exists stock_movements_entry_channel_ck;
alter table public.stock_movements add constraint stock_movements_entry_channel_ck
  check (entry_channel in ('assistente', 'balcao', 'offline'));

-- ---------------------------------------------------------------------
-- 3) Sessões do balcão (vínculo ME <-> almoxarife <-> tablet)
-- ---------------------------------------------------------------------
create table if not exists public.counter_sessions (
  id                  uuid primary key default gen_random_uuid(),
  movement_id         uuid not null unique references public.stock_movements (id),
  warehouse_id        uuid not null references public.warehouses (id),
  opened_by           uuid not null references public.profiles (id),
  pairing_code        text not null,
  pairing_expires_at  timestamptz not null,
  terminal_user_id    uuid references public.profiles (id),
  paired_at           timestamptz,
  status              text not null default 'em_separacao',
  version             integer not null default 1,
  last_event          text,
  last_event_at       timestamptz not null default now(),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  constraint counter_sessions_status_ck
    check (status in ('em_separacao', 'aguardando_confirmacao', 'confirmada', 'cancelada')),
  constraint counter_sessions_code_ck check (pairing_code ~ '^[0-9]{6}$')
);
create unique index if not exists counter_sessions_active_code_uk
  on public.counter_sessions (pairing_code) where status in ('em_separacao', 'aguardando_confirmacao');
create index if not exists counter_sessions_terminal_idx on public.counter_sessions (terminal_user_id, status);
create index if not exists counter_sessions_opened_idx on public.counter_sessions (opened_by, status);

-- Log de cada leitura (inclusive QR não encontrado e leituras repetidas)
create table if not exists public.scan_events (
  id            bigserial primary key,
  movement_id   uuid not null references public.stock_movements (id),
  scan_id       uuid not null unique,
  scanned_code  text,
  material_id   uuid references public.materials (id),
  item_id       uuid,
  quantity      numeric(14,3),
  result        text not null,
  response      jsonb,
  user_id       uuid references public.profiles (id) default auth.uid(),
  created_at    timestamptz not null default now(),
  constraint scan_events_result_ck check (result in (
    'incluido', 'somado', 'ja_incluido', 'nao_encontrado', 'invalido', 'inativo', 'quantidade_invalida'
  ))
);
create index if not exists scan_events_movement_idx on public.scan_events (movement_id, created_at);

-- Tentativas de confirmação pelo solicitante (assinatura agora; facial depois)
create table if not exists public.confirmation_attempts (
  id            uuid primary key default gen_random_uuid(),
  movement_id   uuid not null references public.stock_movements (id),
  employee_id   uuid references public.employees (id),
  method        text not null,
  provider      text,
  result        text not null,
  score         numeric,
  liveness      boolean,
  detail        jsonb,
  consumed_at   timestamptz,
  created_by    uuid references public.profiles (id) default auth.uid(),
  created_at    timestamptz not null default now(),
  constraint confirmation_attempts_method_ck check (method in ('assinatura', 'facial')),
  constraint confirmation_attempts_result_ck check (result in ('sucesso', 'falha', 'cancelada', 'erro'))
);
create index if not exists confirmation_attempts_movement_idx on public.confirmation_attempts (movement_id, created_at);

alter table public.counter_sessions enable row level security;
alter table public.scan_events enable row level security;
alter table public.confirmation_attempts enable row level security;

drop policy if exists counter_sessions_select on public.counter_sessions;
create policy counter_sessions_select on public.counter_sessions
  for select to authenticated using (
    opened_by = auth.uid()
    or terminal_user_id = auth.uid()
    or (public.has_any_role(array['gestor', 'admin']::public.app_role[]) and public.can_access_warehouse(warehouse_id))
  );
drop policy if exists scan_events_select on public.scan_events;
create policy scan_events_select on public.scan_events
  for select to authenticated using (public.can_access_movement(movement_id));
drop policy if exists confirmation_attempts_select on public.confirmation_attempts;
create policy confirmation_attempts_select on public.confirmation_attempts
  for select to authenticated using (public.can_access_movement(movement_id));

grant select on public.counter_sessions, public.scan_events, public.confirmation_attempts to authenticated;
revoke insert, update, delete on public.counter_sessions, public.scan_events, public.confirmation_attempts from authenticated, anon;

do $$
declare t text;
begin
  foreach t in array array['counter_sessions', 'scan_events', 'confirmation_attempts'] loop
    execute format('drop trigger if exists block_delete on public.%I', t);
    execute format('create trigger block_delete before delete on public.%I for each row execute function public.tg_block_delete()', t);
  end loop;
end $$;

create or replace function public.tg_counter_updated_at()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;
drop trigger if exists set_timestamps on public.counter_sessions;
create trigger set_timestamps before update on public.counter_sessions
  for each row execute function public.tg_counter_updated_at();

-- Realtime: as duas telas escutam a sessão (cada mudança incrementa "version")
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables
                      where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'counter_sessions') then
    execute 'alter publication supabase_realtime add table public.counter_sessions';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 4) Funções internas
-- ---------------------------------------------------------------------
create or replace function public._counter_touch(p_movement_id uuid, p_event text, p_status text default null)
returns void
language sql security definer
set search_path = public, pg_temp
as $$
  update public.counter_sessions
     set version = version + 1, last_event = p_event, last_event_at = now(),
         status = coalesce(p_status, status)
   where movement_id = p_movement_id;
$$;

-- Trava a ME do balcão para alteração pelo almoxarife que abriu a separação
create or replace function public._counter_lock_for_owner(p_movement_id uuid)
returns public.stock_movements
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_m public.stock_movements;
begin
  if auth.uid() is null or not public.is_active_user() then
    raise exception 'Sessão inválida ou usuário inativo.' using errcode = '42501';
  end if;
  select * into v_m from public.stock_movements where id = p_movement_id for update;
  if v_m.id is null or not public.can_access_warehouse(v_m.warehouse_id) then
    raise exception 'ME não encontrada.' using errcode = 'P0002';
  end if;
  if v_m.entry_channel <> 'balcao' then
    raise exception 'Esta ME não foi aberta no balcão.' using errcode = 'P0001';
  end if;
  if v_m.storekeeper_id <> auth.uid() then
    raise exception 'Somente o almoxarife que abriu a separação (%) pode alterá-la.',
      (select coalesce(full_name, email) from public.profiles where id = v_m.storekeeper_id) using errcode = '42501';
  end if;
  return v_m;
end;
$$;

create or replace function public._counter_new_code()
returns text
language plpgsql volatile
set search_path = public, pg_temp
as $$
declare
  v_code text;
begin
  loop
    v_code := lpad((floor(random() * 1000000))::int::text, 6, '0');
    exit when not exists (select 1 from public.counter_sessions
                           where pairing_code = v_code and status in ('em_separacao', 'aguardando_confirmacao'));
  end loop;
  return v_code;
end;
$$;

revoke all on function public._counter_touch(uuid, text, text) from public, anon, authenticated;
revoke all on function public._counter_lock_for_owner(uuid) from public, anon, authenticated;
revoke all on function public._counter_new_code() from public, anon, authenticated;

-- Confere se o usuário é um tablet (perfil terminal) ativo do estoque e se está livre
create or replace function public._counter_check_terminal(p_terminal uuid, p_warehouse_id uuid, p_except_movement uuid)
returns void
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare
  v_name text;
begin
  select coalesce(p.full_name, p.email) into v_name
    from public.profiles p
    join public.user_roles ur on ur.user_id = p.id and ur.role = 'terminal'
    join public.user_warehouses uw on uw.user_id = p.id and uw.warehouse_id = p_warehouse_id
   where p.id = p_terminal and p.active;
  if v_name is null then
    raise exception 'Tablet inválido para este estoque.' using errcode = '22023';
  end if;
  if exists (select 1 from public.counter_sessions s
              where s.terminal_user_id = p_terminal
                and s.status in ('em_separacao', 'aguardando_confirmacao')
                and s.movement_id is distinct from p_except_movement) then
    raise exception 'O tablet % está ocupado com outra separação. Escolha outro ou aguarde a confirmação.', v_name
      using errcode = 'P0001';
  end if;
end;
$$;
revoke all on function public._counter_check_terminal(uuid, uuid, uuid) from public, anon, authenticated;

-- Cancelamento (por qualquer caminho) encerra a sessão do balcão
create or replace function public.tg_counter_sync_status()
returns trigger
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  if new.status = 'cancelada' and old.status <> 'cancelada' then
    perform public._counter_touch(new.id, 'me_cancelada', 'cancelada');
  end if;
  return null;
end;
$$;
drop trigger if exists counter_sync_status on public.stock_movements;
create trigger counter_sync_status after update of status on public.stock_movements
  for each row execute function public.tg_counter_sync_status();

-- ---------------------------------------------------------------------
-- 5) Abrir separação no balcão
-- payload: id, warehouse_id, contract_id, sector_id, service_front_id, service_order_text,
--          fixed_asset_text, application_location_id, notes, requester_employee_id,
--          terminal_user_id (tablet escolhido) ou reuse_terminal
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

  select id into v_contract_id from public.contracts where id = nullif(p_payload ->> 'contract_id', '')::uuid and active;
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
    storekeeper_id, created_by, updated_by, created_at
  ) values (
    v_id, v_number, 'saida', v_now, v_wh.id, v_contract_id, v_sector_id,
    v_front_id, v_so_id, v_so_text, v_fa_id, v_fa_text, v_fa_text is not null,
    v_appl_id, nullif(btrim(coalesce(p_payload ->> 'application_location_text', '')), ''),
    nullif(btrim(coalesce(p_payload ->> 'notes', '')), ''), 'rascunho', 'balcao',
    v_requester.id, v_requester.full_name, v_requester.registration, v_now,
    v_requester.id, v_requester.full_name, v_requester.registration,
    v_uid, v_uid, v_uid, v_now
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
                       'tablet_reaproveitado', v_terminal is not null), null);

  return jsonb_build_object('id', v_id, 'me_number', v_number, 'session_id', v_session.id,
                            'pairing_code', v_code, 'terminal_paired', v_terminal is not null, 'created', true);
end;
$$;

-- ---------------------------------------------------------------------
-- 6) Leitura / inclusão de material
-- payload: movement_id, scan_id (uuid único por leitura), code OU material_id,
--          quantity (padrão 1), on_duplicate ('avisar' | 'somar' | 'nova_linha')
-- Resultado: incluido | somado | ja_incluido | nao_encontrado | invalido | inativo | quantidade_invalida
-- ---------------------------------------------------------------------
create or replace function public.counter_add(p_payload jsonb)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  s           public.app_settings := public.get_settings();
  v_mid       uuid;
  v_scan      uuid;
  v_prev      jsonb;
  v_m         public.stock_movements;
  v_code      text := nullif(btrim(coalesce(p_payload ->> 'code', '')), '');
  v_mat_id    uuid;
  v_mat       record;
  v_qty       numeric;
  v_mode      text := coalesce(nullif(p_payload ->> 'on_duplicate', ''), 'avisar');
  v_item      public.stock_movement_items;
  v_resp      jsonb;
  v_result    text;
  v_line      int;
  v_manual    boolean := v_code is null;
begin
  begin
    v_mid := (p_payload ->> 'movement_id')::uuid;
    v_scan := (p_payload ->> 'scan_id')::uuid;
    v_mat_id := nullif(p_payload ->> 'material_id', '')::uuid;
  exception when others then
    raise exception 'Leitura inválida.' using errcode = '22023';
  end;
  if v_mid is null or v_scan is null then
    raise exception 'ME e identificador da leitura são obrigatórios.' using errcode = '22023';
  end if;
  if v_mode not in ('avisar', 'somar', 'nova_linha') then
    raise exception 'Opção de leitura repetida inválida.' using errcode = '22023';
  end if;

  v_m := public._counter_lock_for_owner(v_mid);
  -- inicializa o registro do material (fica nulo quando o código não é encontrado)
  select m.*, null::text as account_code, null::text as account_name into v_mat from public.materials m where false;

  -- Mesma leitura reenviada (rede instável): devolve a resposta original
  select response into v_prev from public.scan_events where scan_id = v_scan;
  if v_prev is not null then
    return v_prev || jsonb_build_object('repetida', true);
  end if;

  if v_m.status <> 'rascunho' then
    raise exception 'Separação finalizada: novas leituras estão bloqueadas nesta ME.' using errcode = 'P0001';
  end if;

  begin
    v_qty := coalesce(nullif(p_payload ->> 'quantity', '')::numeric, 1);
  exception when others then
    v_qty := null;
  end;

  -- Localiza o material (mesmas regras da leitura por câmera)
  if v_code is not null then
    if position('/' in v_code) > 0 then
      v_code := regexp_replace(v_code, '^.*/', '');
    end if;
    if v_code !~ '^[A-Za-z0-9._:/-]{1,80}$' then
      v_result := 'invalido';
    else
      select m.id into v_mat_id
        from public.materials m
       where m.qr_code = v_code
          or m.id in (select q.material_id from public.material_qr_codes q where q.code = v_code and q.active)
          or upper(m.code) = upper(v_code)
       order by (m.qr_code = v_code) desc
       limit 1;
      if v_mat_id is null then
        v_result := 'nao_encontrado';
      end if;
    end if;
  end if;

  if v_result is null then
    select m.*, a.code as account_code, a.name as account_name into v_mat
      from public.materials m left join public.accounts a on a.id = m.account_id
     where m.id = v_mat_id;
    if v_mat.id is null then
      v_result := 'nao_encontrado';
    elsif not v_mat.active then
      v_result := 'inativo';
    elsif v_qty is null or v_qty <= 0 or v_qty > 999999 then
      v_result := 'quantidade_invalida';
    end if;
  end if;

  if v_result is null then
    select * into v_item from public.stock_movement_items
     where movement_id = v_mid and material_id = v_mat.id order by line_number limit 1;

    if v_item.id is not null and (v_mode = 'avisar' or (v_mode = 'nova_linha' and not s.allow_duplicate_material_lines)) then
      v_result := 'ja_incluido';
    elsif v_item.id is not null and v_mode = 'somar' then
      update public.stock_movement_items
         set quantity_requested = quantity_requested + v_qty,
             quantity_delivered = quantity_delivered + v_qty,
             updated_by = auth.uid()
       where id = v_item.id
      returning * into v_item;
      v_result := 'somado';
    else
      if (select count(*) from public.stock_movement_items where movement_id = v_mid) >= 200 then
        raise exception 'Limite de 200 itens por ME.' using errcode = '22023';
      end if;
      select coalesce(max(line_number), 0) + 1 into v_line from public.stock_movement_items where movement_id = v_mid;
      insert into public.stock_movement_items (
        movement_id, line_number, material_id, material_code, material_reference, material_name,
        unit, location, account_code, account_name, quantity_requested, quantity_delivered,
        entry_method, scanned_code, created_by, updated_by
      ) values (
        v_mid, v_line, v_mat.id, v_mat.code, v_mat.reference, v_mat.name,
        v_mat.unit, v_mat.location, v_mat.account_code, v_mat.account_name, v_qty, v_qty,
        case when v_manual then 'pesquisa_manual' else 'qr_code' end::public.item_entry_method,
        left(v_code, 80), auth.uid(), auth.uid()
      ) returning * into v_item;
      v_result := 'incluido';
    end if;
  end if;

  v_resp := jsonb_build_object(
    'result', v_result,
    'code', v_code,
    'item_id', v_item.id,
    'material_id', coalesce(v_mat.id, v_mat_id),
    'material_code', coalesce(v_item.material_code, v_mat.code),
    'material_name', coalesce(v_item.material_name, v_mat.name),
    'unit', coalesce(v_item.unit, v_mat.unit),
    'quantity_requested', v_item.quantity_requested,
    'quantity_delivered', v_item.quantity_delivered
  );

  insert into public.scan_events (movement_id, scan_id, scanned_code, material_id, item_id, quantity, result, response)
  values (v_mid, v_scan, left(coalesce(v_code, p_payload ->> 'code'), 120), v_mat.id, v_item.id, v_qty, v_result, v_resp);

  if v_result in ('incluido', 'somado') then
    perform public._counter_touch(v_mid, case when v_result = 'incluido' then 'item_incluido' else 'quantidade_alterada' end);
  end if;
  return v_resp;
end;
$$;

-- Altera quantidades de um item durante a separação
create or replace function public.counter_set_quantity(p_item_id uuid, p_requested numeric, p_delivered numeric)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  s       public.app_settings := public.get_settings();
  v_item  public.stock_movement_items;
  v_m     public.stock_movements;
begin
  select * into v_item from public.stock_movement_items where id = p_item_id;
  if v_item.id is null then
    raise exception 'Item não encontrado.' using errcode = 'P0002';
  end if;
  v_m := public._counter_lock_for_owner(v_item.movement_id);
  if v_m.status <> 'rascunho' then
    raise exception 'Separação finalizada: os itens estão bloqueados.' using errcode = 'P0001';
  end if;
  if p_requested is null or p_requested <= 0 or p_delivered is null or p_delivered <= 0 then
    raise exception 'Quantidade inválida: informe valores maiores que zero.' using errcode = '22023';
  end if;
  if p_requested > 999999 or p_delivered > 999999 then
    raise exception 'Quantidade acima do limite permitido.' using errcode = '22023';
  end if;
  if p_delivered > p_requested and not s.allow_delivered_above_requested then
    raise exception 'A quantidade atendida não pode ser maior que a solicitada.' using errcode = '22023';
  end if;
  update public.stock_movement_items
     set quantity_requested = p_requested, quantity_delivered = p_delivered, updated_by = auth.uid()
   where id = p_item_id
  returning * into v_item;
  perform public._counter_touch(v_item.movement_id, 'quantidade_alterada');
  return jsonb_build_object('item_id', v_item.id, 'quantity_requested', v_item.quantity_requested,
                            'quantity_delivered', v_item.quantity_delivered);
end;
$$;

-- Remove um item durante a separação
create or replace function public.counter_remove_item(p_item_id uuid)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_item  public.stock_movement_items;
  v_m     public.stock_movements;
begin
  select * into v_item from public.stock_movement_items where id = p_item_id;
  if v_item.id is null then
    raise exception 'Item não encontrado.' using errcode = 'P0002';
  end if;
  v_m := public._counter_lock_for_owner(v_item.movement_id);
  if v_m.status <> 'rascunho' then
    raise exception 'Separação finalizada: os itens estão bloqueados.' using errcode = 'P0001';
  end if;
  delete from public.stock_movement_items where id = p_item_id;
  perform public._counter_touch(v_item.movement_id, 'item_removido');
  return jsonb_build_object('item_id', p_item_id, 'material_name', v_item.material_name);
end;
$$;

-- FINALIZAR SEPARAÇÃO: bloqueia leituras e libera a confirmação no tablet
create or replace function public.counter_finish(p_movement_id uuid)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_m public.stock_movements;
begin
  v_m := public._counter_lock_for_owner(p_movement_id);
  if v_m.status <> 'rascunho' then
    raise exception 'Esta separação já foi finalizada (status: %).', v_m.status using errcode = 'P0001';
  end if;
  if not exists (select 1 from public.stock_movement_items where movement_id = p_movement_id) then
    raise exception 'Inclua pelo menos um material antes de finalizar a separação.' using errcode = '22023';
  end if;
  perform set_config('app.audit_action', 'me.separacao_finalizada', true);
  update public.stock_movements
     set status = 'aguardando_assinatura', separation_finished_at = now(), updated_by = auth.uid()
   where id = p_movement_id;
  perform public._counter_touch(p_movement_id, 'separacao_finalizada', 'aguardando_confirmacao');
  return jsonb_build_object('id', p_movement_id, 'status', 'aguardando_assinatura');
end;
$$;

-- Reabre a separação (antes da confirmação), por exemplo se o solicitante apontar divergência
create or replace function public.counter_reopen(p_movement_id uuid, p_reason text default null)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_m public.stock_movements;
begin
  v_m := public._counter_lock_for_owner(p_movement_id);
  if v_m.status <> 'aguardando_assinatura' then
    raise exception 'Somente separações aguardando confirmação podem ser reabertas (status: %).', v_m.status
      using errcode = 'P0001';
  end if;
  perform set_config('app.audit_action', 'me.separacao_reaberta', true);
  perform set_config('app.justification', coalesce(nullif(btrim(coalesce(p_reason, '')), ''), 'Separação reaberta no balcão'), true);
  update public.stock_movements
     set status = 'rascunho', separation_finished_at = null, updated_by = auth.uid()
   where id = p_movement_id;
  perform public._counter_touch(p_movement_id, 'separacao_reaberta', 'em_separacao');
  return jsonb_build_object('id', p_movement_id, 'status', 'rascunho');
end;
$$;

-- Novo código de pareamento (o anterior expirou)
create or replace function public.counter_new_pairing_code(p_movement_id uuid)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_m    public.stock_movements;
  v_code text;
begin
  v_m := public._counter_lock_for_owner(p_movement_id);
  if v_m.status not in ('rascunho', 'aguardando_assinatura') then
    raise exception 'A separação já foi encerrada.' using errcode = 'P0001';
  end if;
  v_code := public._counter_new_code();
  update public.counter_sessions
     set pairing_code = v_code, pairing_expires_at = now() + interval '30 minutes'
   where movement_id = p_movement_id;
  perform public._counter_touch(p_movement_id, 'codigo_renovado');
  return jsonb_build_object('pairing_code', v_code);
end;
$$;

-- ---------------------------------------------------------------------
-- 7) Tablet do solicitante (perfil terminal)
-- ---------------------------------------------------------------------
create or replace function public.counter_pair(p_code text)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_s public.counter_sessions;
begin
  if auth.uid() is null or not public.is_active_user() or not public.has_role('terminal') then
    raise exception 'Somente o tablet do solicitante (perfil Terminal) pode ser pareado.' using errcode = '42501';
  end if;
  select * into v_s from public.counter_sessions
   where pairing_code = btrim(coalesce(p_code, '')) and status in ('em_separacao', 'aguardando_confirmacao')
   for update;
  if v_s.id is null or v_s.pairing_expires_at < now() then
    raise exception 'Código inválido ou expirado. Peça ao almoxarife um código novo.' using errcode = 'P0002';
  end if;
  if not public.is_terminal_of_warehouse(v_s.warehouse_id) then
    raise exception 'Este tablet não está liberado para o estoque desta ME.' using errcode = '42501';
  end if;
  if v_s.terminal_user_id is not null and v_s.terminal_user_id <> auth.uid() then
    raise exception 'Esta ME já está pareada com outro tablet.' using errcode = 'P0001';
  end if;

  -- Um tablet acompanha uma ME por vez
  update public.counter_sessions
     set terminal_user_id = null, paired_at = null, version = version + 1, last_event = 'terminal_desconectado', last_event_at = now()
   where terminal_user_id = auth.uid() and id <> v_s.id and status in ('em_separacao', 'aguardando_confirmacao');

  update public.counter_sessions
     set terminal_user_id = auth.uid(), paired_at = now(), version = version + 1, last_event = 'terminal_pareado', last_event_at = now()
   where id = v_s.id;

  perform public.write_audit('balcao.terminal_pareado', 'counter_sessions', v_s.id::text, v_s.movement_id, v_s.warehouse_id,
                             null, jsonb_build_object('terminal', auth.uid()), null);
  return jsonb_build_object('session_id', v_s.id, 'movement_id', v_s.movement_id);
end;
$$;

-- Fotografia da sessão para as duas telas (almoxarife dono, tablet pareado, gestor/admin)
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
      'fixed_asset', v_m.fixed_asset_text
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

-- Registra tentativa de confirmação que não deu certo (cancelada, falha, erro)
create or replace function public.counter_register_attempt(p_movement_id uuid, p_method text, p_result text, p_detail jsonb default null)
returns uuid
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_s  public.counter_sessions;
  v_id uuid;
begin
  select * into v_s from public.counter_sessions where movement_id = p_movement_id;
  if v_s.id is null or v_s.terminal_user_id is distinct from auth.uid() then
    raise exception 'Tablet não pareado com esta ME.' using errcode = '42501';
  end if;
  if p_method not in ('assinatura', 'facial') or p_result not in ('falha', 'cancelada', 'erro') then
    -- "sucesso" nunca vem do navegador: a assinatura é validada em counter_confirm
    -- e o facial será registrado pelo servidor (Edge Function) com a chave de serviço.
    raise exception 'Tentativa inválida.' using errcode = '22023';
  end if;
  insert into public.confirmation_attempts (movement_id, employee_id, method, result, detail)
  values (p_movement_id, (select requester_employee_id from public.stock_movements where id = p_movement_id),
          p_method, p_result, p_detail)
  returning id into v_id;
  perform public._counter_touch(p_movement_id, 'confirmacao_' || p_result);
  return v_id;
end;
$$;

-- CONFIRMAR ME (tablet pareado). method = 'assinatura' (signature_path) ou 'facial' (verification_id)
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

-- Separações em andamento do usuário (para retomar)
create or replace function public.counter_my_open()
returns jsonb
language sql stable security definer
set search_path = public, pg_temp
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'movement_id', m.id, 'me_number', m.me_number, 'status', m.status, 'requester_name', m.requester_name,
           'item_count', m.item_count, 'created_at', m.created_at, 'terminal_paired', s.terminal_user_id is not null,
           'warehouse_name', w.name) order by m.created_at desc), '[]'::jsonb)
    from public.counter_sessions s
    join public.stock_movements m on m.id = s.movement_id
    join public.warehouses w on w.id = m.warehouse_id
   where s.opened_by = auth.uid() and s.status in ('em_separacao', 'aguardando_confirmacao');
$$;

-- ---------------------------------------------------------------------
-- 7b) Tablets do estoque (escolha do tablet sem digitar código)
-- ---------------------------------------------------------------------
create or replace function public.counter_list_terminals(p_warehouse_id uuid)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null or not public.is_active_user()
     or not public.has_any_role(array['almoxarife', 'gestor', 'admin']::public.app_role[])
     or not public.can_access_warehouse(p_warehouse_id) then
    raise exception 'Sem permissão para este estoque.' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'user_id', p.id,
             'name', coalesce(p.full_name, p.email),
             'busy_me_number', (select m.me_number from public.counter_sessions s join public.stock_movements m on m.id = s.movement_id
                                 where s.terminal_user_id = p.id and s.status in ('em_separacao', 'aguardando_confirmacao')
                                 order by s.created_at desc limit 1),
             'last_used_by_me', (select max(s.created_at) from public.counter_sessions s
                                  where s.terminal_user_id = p.id and s.opened_by = auth.uid())
           ) order by coalesce(p.full_name, p.email))
      from public.profiles p
      join public.user_roles ur on ur.user_id = p.id and ur.role = 'terminal'
      join public.user_warehouses uw on uw.user_id = p.id and uw.warehouse_id = p_warehouse_id
     where p.active), '[]'::jsonb);
end;
$$;

-- Liga (ou troca) o tablet de uma separação em andamento
create or replace function public.counter_set_terminal(p_movement_id uuid, p_terminal_user_id uuid)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_m public.stock_movements;
begin
  v_m := public._counter_lock_for_owner(p_movement_id);
  if v_m.status not in ('rascunho', 'aguardando_assinatura') then
    raise exception 'A separação já foi encerrada.' using errcode = 'P0001';
  end if;
  if p_terminal_user_id is not null then
    perform public._counter_check_terminal(p_terminal_user_id, v_m.warehouse_id, p_movement_id);
  end if;
  update public.counter_sessions
     set terminal_user_id = p_terminal_user_id,
         paired_at = case when p_terminal_user_id is null then null else now() end,
         version = version + 1,
         last_event = case when p_terminal_user_id is null then 'terminal_desconectado' else 'terminal_pareado' end,
         last_event_at = now()
   where movement_id = p_movement_id;
  perform public.write_audit('balcao.terminal_pareado', 'counter_sessions', p_movement_id::text, p_movement_id, v_m.warehouse_id,
                             null, jsonb_build_object('terminal', p_terminal_user_id, 'escolhido_pelo_almoxarife', true), null);
  return jsonb_build_object('movement_id', p_movement_id, 'terminal_user_id', p_terminal_user_id);
end;
$$;

-- ---------------------------------------------------------------------
-- 8) Assinatura enviada pelo tablet pareado (somente na pasta da ME pareada)
-- ---------------------------------------------------------------------
create or replace function public.counter_terminal_can_upload(p_name text)
returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
      from public.counter_sessions s
      join public.warehouses w on w.id = s.warehouse_id
     where s.terminal_user_id = auth.uid()
       and s.status = 'aguardando_confirmacao'
       and w.code = split_part(p_name, '/', 1)
       and s.movement_id::text = split_part(p_name, '/', 3)
  );
$$;
grant execute on function public.counter_terminal_can_upload(text) to authenticated;

drop policy if exists "assinaturas: envio pelo tablet do balcão" on storage.objects;
create policy "assinaturas: envio pelo tablet do balcão"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'assinaturas'
    and name ~* '\.(png|jpe?g|webp)$'
    and public.counter_terminal_can_upload(name)
  );


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

-- ---------------------------------------------------------------------
-- 8b) Almoxarife pode cancelar uma separação em andamento (com justificativa)
-- ---------------------------------------------------------------------
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
  -- (Em separação/Aguardando confirmação no balcão, Aguardando SA, Aguardando aprovação ou,
  --  em ME sem ativo, Aguardando baixa no ERP),
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
     and v_m.status not in ('rascunho', 'aguardando_assinatura', 'aguardando_sa', 'aguardando_aprovacao')
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

-- ---------------------------------------------------------------------
-- 9) Permissões
-- ---------------------------------------------------------------------
revoke all on function public.counter_open(jsonb) from public, anon;
revoke all on function public.counter_add(jsonb) from public, anon;
revoke all on function public.counter_set_quantity(uuid, numeric, numeric) from public, anon;
revoke all on function public.counter_remove_item(uuid) from public, anon;
revoke all on function public.counter_finish(uuid) from public, anon;
revoke all on function public.counter_reopen(uuid, text) from public, anon;
revoke all on function public.counter_new_pairing_code(uuid) from public, anon;
revoke all on function public.counter_pair(text) from public, anon;
revoke all on function public.counter_snapshot(uuid) from public, anon;
revoke all on function public.counter_register_attempt(uuid, text, text, jsonb) from public, anon;
revoke all on function public.counter_confirm(uuid, jsonb) from public, anon;
revoke all on function public.counter_my_open() from public, anon;
grant execute on function public.counter_open(jsonb) to authenticated;
grant execute on function public.counter_add(jsonb) to authenticated;
grant execute on function public.counter_set_quantity(uuid, numeric, numeric) to authenticated;
grant execute on function public.counter_remove_item(uuid) to authenticated;
grant execute on function public.counter_finish(uuid) to authenticated;
grant execute on function public.counter_reopen(uuid, text) to authenticated;
grant execute on function public.counter_new_pairing_code(uuid) to authenticated;
grant execute on function public.counter_pair(text) to authenticated;
grant execute on function public.counter_snapshot(uuid) to authenticated;
grant execute on function public.counter_register_attempt(uuid, text, text, jsonb) to authenticated;
grant execute on function public.counter_confirm(uuid, jsonb) to authenticated;
grant execute on function public.counter_my_open() to authenticated;
grant execute on function public.is_terminal_of_warehouse(uuid) to authenticated;
revoke all on function public.counter_list_terminals(uuid) from public, anon;
revoke all on function public.counter_set_terminal(uuid, uuid) from public, anon;
grant execute on function public.counter_list_terminals(uuid) to authenticated;
grant execute on function public.counter_set_terminal(uuid, uuid) to authenticated;
