-- =====================================================================
-- 17 - BALCÃO: ESCOLHA DO TABLET SEM CÓDIGO
-- O almoxarife escolhe o tablet (perfil Terminal do estoque) numa lista ao abrir
-- a separação ou durante ela. O código de 6 dígitos continua como alternativa.
-- Pré-requisito: 16a e 16b já executados. Pode ser reexecutado.
-- =====================================================================
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

revoke all on function public.counter_list_terminals(uuid) from public, anon;
revoke all on function public.counter_set_terminal(uuid, uuid) from public, anon;
grant execute on function public.counter_open(jsonb) to authenticated;
grant execute on function public.counter_list_terminals(uuid) to authenticated;
grant execute on function public.counter_set_terminal(uuid, uuid) to authenticated;
