-- =====================================================================
-- 26 - RECONHECIMENTO FACIAL NO BALCÃO
-- O solicitante toca em "Retirar peças" no tablet; o rosto é reconhecido e o
-- almoxarife já vê quem está pedindo. No final, a confirmação é feita pelo rosto
-- (sem assinatura e sem foto). Quem não for reconhecido segue com foto + assinatura.
--
-- Proteção dos dados (LGPD art. 11 — dado sensível):
--   * o reconhecimento roda no tablet; a imagem do rosto NÃO é enviada nem guardada;
--   * o banco guarda só a "impressão numérica" do rosto (128 números), sem foto e sem CPF;
--   * a comparação é feita no servidor: a base de rostos nunca vai para o tablet;
--   * só cadastro (admin/almoxarife) e o servidor tocam nos modelos; a trilha registra
--     cadastro, remoção e uso, nunca os números do rosto;
--   * funcionário inativado tem os modelos apagados na hora.
-- Começa DESLIGADO: o administrador liga em Cadastros › Reconhecimento facial.
-- Pré-requisito: 16b, 20, 21, 23, 24 e 25. Pode ser reexecutado.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) Tabelas
-- ---------------------------------------------------------------------
create table if not exists public.face_settings (
  id          int primary key default 1 check (id = 1),
  enabled     boolean not null default false,
  threshold   numeric(4,3) not null default 0.5 check (threshold between 0.35 and 0.65),
  margin      numeric(4,3) not null default 0.05 check (margin between 0 and 0.2),
  updated_at  timestamptz not null default now(),
  updated_by  uuid references public.profiles (id)
);
insert into public.face_settings (id) values (1) on conflict (id) do nothing;

create table if not exists public.employee_faces (
  id           bigserial primary key,
  employee_id  uuid not null references public.employees (id),
  descriptor   real[] not null,
  source       text not null,
  created_at   timestamptz not null default now(),
  created_by   uuid references public.profiles (id),
  constraint employee_faces_len_ck check (array_length(descriptor, 1) = 128),
  constraint employee_faces_source_ck check (source in ('importacao', 'camera'))
);
create index if not exists employee_faces_employee_idx on public.employee_faces (employee_id);

-- Pedido de retirada iniciado no tablet ("Retirar peças")
create table if not exists public.counter_requests (
  id                uuid primary key default gen_random_uuid(),
  warehouse_id      uuid not null references public.warehouses (id),
  terminal_user_id  uuid not null references public.profiles (id),
  employee_id       uuid references public.employees (id),
  method            text not null,
  similarity        numeric(4,3),
  reason            text,
  status            text not null default 'pendente',
  movement_id       uuid references public.stock_movements (id),
  created_at        timestamptz not null default now(),
  handled_at        timestamptz,
  handled_by        uuid references public.profiles (id),
  constraint counter_requests_method_ck check (method in ('facial', 'manual')),
  constraint counter_requests_status_ck check (status in ('pendente', 'atendido', 'cancelado', 'expirado')),
  constraint counter_requests_facial_ck check (method <> 'facial' or employee_id is not null)
);
create index if not exists counter_requests_pending_idx on public.counter_requests (warehouse_id, status, created_at);

-- Tentativas de identificação no início (para limite de tentativas e investigação)
create table if not exists public.face_attempts (
  id                bigserial primary key,
  terminal_user_id  uuid references public.profiles (id),
  warehouse_id      uuid references public.warehouses (id),
  employee_id       uuid references public.employees (id),
  result            text not null,
  similarity        numeric(4,3),
  liveness          boolean,
  created_at        timestamptz not null default now(),
  constraint face_attempts_result_ck check (result in ('reconhecido', 'nao_reconhecido', 'ambiguo', 'sem_prova_de_vida', 'sem_rosto'))
);
create index if not exists face_attempts_terminal_idx on public.face_attempts (terminal_user_id, created_at);

alter table public.stock_movements add column if not exists requester_identified_by text;
alter table public.stock_movements add column if not exists requester_request_id uuid;
alter table public.stock_movements drop constraint if exists stock_movements_identified_by_ck;
alter table public.stock_movements add constraint stock_movements_identified_by_ck
  check (requester_identified_by is null or requester_identified_by in ('facial', 'manual'));

do $$
declare t text;
begin
  foreach t in array array['face_settings', 'employee_faces', 'counter_requests', 'face_attempts'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on table public.%I from public, anon, authenticated', t);
  end loop;
end $$;
revoke all on sequence public.employee_faces_id_seq from public, anon, authenticated;
revoke all on sequence public.face_attempts_id_seq from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 2) Funções de apoio
-- ---------------------------------------------------------------------
create or replace function public._face_distance(a real[], b real[])
returns double precision
language sql immutable parallel safe
set search_path = public, pg_temp
as $$
  select sqrt(sum((x - y) ^ 2)) from unnest(a, b) as t(x, y);
$$;

-- Converte e valida um descritor vindo do tablet (128 números finitos)
create or replace function public._face_descriptor(p jsonb)
returns real[]
language plpgsql immutable
set search_path = public, pg_temp
as $$
declare v real[];
begin
  if p is null or jsonb_typeof(p) <> 'array' or jsonb_array_length(p) <> 128 then
    raise exception 'Leitura do rosto inválida.' using errcode = '22023';
  end if;
  select array_agg(x::real order by i) into v from jsonb_array_elements_text(p) with ordinality as t(x, i);
  if exists (select 1 from unnest(v) z where z is null or z = 'NaN'::real or abs(z) > 10) then
    raise exception 'Leitura do rosto inválida.' using errcode = '22023';
  end if;
  return v;
exception when invalid_text_representation or numeric_value_out_of_range then
  raise exception 'Leitura do rosto inválida.' using errcode = '22023';
end;
$$;

revoke all on function public._face_distance(real[], real[]) from public, anon, authenticated;
revoke all on function public._face_descriptor(jsonb) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 3) Configuração e cadastro
-- ---------------------------------------------------------------------
create or replace function public.face_config()
returns jsonb
language sql stable security definer
set search_path = public, pg_temp
as $$
  select jsonb_build_object('enabled', s.enabled, 'threshold', s.threshold, 'margin', s.margin)
    from public.face_settings s where s.id = 1 and public.is_active_user();
$$;

create or replace function public.face_settings_update(p jsonb)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  o public.face_settings;
  n public.face_settings;
begin
  if not public.is_admin() then
    raise exception 'Somente o administrador altera o reconhecimento facial.' using errcode = '42501';
  end if;
  select * into o from public.face_settings where id = 1 for update;
  update public.face_settings set
    enabled   = coalesce((p ->> 'enabled')::boolean, enabled),
    threshold = coalesce((p ->> 'threshold')::numeric, threshold),
    margin    = coalesce((p ->> 'margin')::numeric, margin),
    updated_at = now(), updated_by = auth.uid()
   where id = 1 returning * into n;
  perform public.audit_event('biometria.configuracao', 'face_settings', '1', null, null,
    jsonb_build_object('ligado', o.enabled, 'rigor', o.threshold, 'margem', o.margin),
    jsonb_build_object('ligado', n.enabled, 'rigor', n.threshold, 'margem', n.margin));
  return public.face_config();
exception when check_violation then
  raise exception 'Valores fora da faixa permitida (rigor entre 0,35 e 0,65).' using errcode = '22023';
end;
$$;

create or replace function public.face_overview()
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
begin
  if not public.can_manage_master_data() then
    raise exception 'Somente administrador ou almoxarife.' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'settings', public.face_config(),
    'ativos', (select count(*) from public.employees where active),
    'com_rosto', (select count(distinct f.employee_id) from public.employee_faces f join public.employees e on e.id = f.employee_id where e.active),
    'faces', coalesce((
      select jsonb_agg(jsonb_build_object('employee_id', e.id, 'registration', e.registration, 'full_name', e.full_name,
                                          'modelos', x.n, 'origem', x.src, 'cadastrado_em', x.at) order by e.full_name)
        from (select employee_id, count(*) n, max(created_at) at, string_agg(distinct source, ', ') src
                from public.employee_faces group by employee_id) x
        join public.employees e on e.id = x.employee_id), '[]'));
end;
$$;

create or replace function public._face_store(p_employee public.employees, p_descriptors jsonb, p_source text)
returns int
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  d jsonb;
  n int := 0;
begin
  if p_descriptors is null or jsonb_typeof(p_descriptors) <> 'array' or jsonb_array_length(p_descriptors) not between 1 and 5 then
    raise exception 'Envie de 1 a 5 leituras do rosto.' using errcode = '22023';
  end if;
  delete from public.employee_faces where employee_id = p_employee.id;
  for d in select * from jsonb_array_elements(p_descriptors) loop
    insert into public.employee_faces (employee_id, descriptor, source, created_by)
    values (p_employee.id, public._face_descriptor(d), p_source, auth.uid());
    n := n + 1;
  end loop;
  return n;
end;
$$;
revoke all on function public._face_store(public.employees, jsonb, text) from public, anon, authenticated;

create or replace function public.face_enroll(p_employee_id uuid, p_descriptors jsonb, p_source text default 'camera')
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  e public.employees;
  n int;
begin
  if not public.can_manage_master_data() then
    raise exception 'Somente administrador ou almoxarife cadastra rostos.' using errcode = '42501';
  end if;
  if p_source not in ('importacao', 'camera') then
    raise exception 'Origem inválida.' using errcode = '22023';
  end if;
  select * into e from public.employees where id = p_employee_id;
  if e.id is null then
    raise exception 'Funcionário não encontrado.' using errcode = 'P0001';
  end if;
  if not e.active then
    raise exception 'O funcionário % está inativo.', e.full_name using errcode = '22023';
  end if;
  n := public._face_store(e, p_descriptors, p_source);
  perform public.audit_event('biometria.cadastrada', 'employee_faces', e.id::text, null, null, null,
    jsonb_build_object('modelos', n, 'origem', p_source));
  return jsonb_build_object('employee_id', e.id, 'modelos', n);
end;
$$;

-- Importação em lote: [{registration, descriptors: [[128 números], ...]}], até 100 por chamada
create or replace function public.face_enroll_bulk(p_items jsonb)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  it        jsonb;
  e         public.employees;
  v_ok      int := 0;
  v_models  int := 0;
  v_missing jsonb := '[]';
  v_inact   jsonb := '[]';
  v_bad     jsonb := '[]';
  v_reg     text;
begin
  if not public.can_manage_master_data() then
    raise exception 'Somente administrador ou almoxarife cadastra rostos.' using errcode = '42501';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) not between 1 and 100 then
    raise exception 'Envie de 1 a 100 funcionários por vez.' using errcode = '22023';
  end if;
  for it in select * from jsonb_array_elements(p_items) loop
    v_reg := btrim(coalesce(it ->> 'registration', ''));
    select * into e from public.employees where upper(registration) = upper(v_reg);
    if e.id is null then
      v_missing := v_missing || to_jsonb(v_reg);
    elsif not e.active then
      v_inact := v_inact || to_jsonb(v_reg);
    else
      begin
        v_models := v_models + public._face_store(e, it -> 'descriptors', 'importacao');
        v_ok := v_ok + 1;
      exception when others then
        v_bad := v_bad || to_jsonb(v_reg);
      end;
    end if;
  end loop;
  perform public.audit_event('biometria.importada', 'employee_faces', null, null, null, null,
    jsonb_build_object('funcionarios', v_ok, 'modelos', v_models, 'nao_cadastrados', jsonb_array_length(v_missing),
                       'inativos', jsonb_array_length(v_inact), 'invalidos', jsonb_array_length(v_bad)));
  return jsonb_build_object('cadastrados', v_ok, 'modelos', v_models, 'nao_encontrados', v_missing,
                            'inativos', v_inact, 'invalidos', v_bad);
end;
$$;

create or replace function public.face_remove(p_employee_id uuid)
returns int
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare n int;
begin
  if not public.can_manage_master_data() then
    raise exception 'Somente administrador ou almoxarife remove rostos.' using errcode = '42501';
  end if;
  delete from public.employee_faces where employee_id = p_employee_id;
  get diagnostics n = row_count;
  if n > 0 then
    perform public.audit_event('biometria.removida', 'employee_faces', p_employee_id::text, null, null, null,
      jsonb_build_object('modelos', n, 'motivo', 'manual'));
  end if;
  return n;
end;
$$;

-- Funcionário inativado: o rosto é apagado na hora (não serve mais para nada)
create or replace function public.tg_employee_faces_on_inactive()
returns trigger
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare n int;
begin
  if old.active and not new.active then
    delete from public.employee_faces where employee_id = new.id;
    get diagnostics n = row_count;
    if n > 0 then
      perform public.audit_event('biometria.removida', 'employee_faces', new.id::text, null, null, null,
        jsonb_build_object('modelos', n, 'motivo', 'funcionario_inativado'));
    end if;
  end if;
  return new;
end;
$$;
drop trigger if exists employees_faces_inactive on public.employees;
create trigger employees_faces_inactive after update of active on public.employees
  for each row execute function public.tg_employee_faces_on_inactive();
revoke all on function public.tg_employee_faces_on_inactive() from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 4) Tablet: "Retirar peças" (identificação 1:N) e alternativa manual
-- ---------------------------------------------------------------------
create or replace function public._counter_terminal_check(p_warehouse_id uuid)
returns void
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null or not public.is_active_user() then
    raise exception 'Sessão inválida ou usuário inativo.' using errcode = '42501';
  end if;
  if not public.is_terminal_of_warehouse(p_warehouse_id) then
    raise exception 'Este tablet não está vinculado a este estoque.' using errcode = '42501';
  end if;
end;
$$;
revoke all on function public._counter_terminal_check(uuid) from public, anon, authenticated;

create or replace function public.face_identify(p_warehouse_id uuid, p_descriptor jsonb, p_liveness boolean)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  s        public.face_settings;
  v_d      real[];
  b1       record;
  b2       record;
  v_result text;
  v_req    public.counter_requests;
  v_sim    numeric;
begin
  perform public._counter_terminal_check(p_warehouse_id);
  select * into s from public.face_settings where id = 1;
  if not s.enabled then
    raise exception 'O reconhecimento facial está desligado.' using errcode = 'P0001';
  end if;
  if (select count(*) from public.face_attempts
       where terminal_user_id = auth.uid() and created_at > now() - interval '5 minutes') >= 30 then
    raise exception 'Muitas tentativas seguidas. Aguarde alguns minutos ou chame o almoxarife.' using errcode = 'P0001';
  end if;
  v_d := public._face_descriptor(p_descriptor);

  -- menor distância por funcionário ativo; melhor e segundo melhor
  select x.employee_id, x.d into b1 from (
    select f.employee_id, min(public._face_distance(f.descriptor, v_d)) d
      from public.employee_faces f join public.employees e on e.id = f.employee_id and e.active
     group by f.employee_id) x order by x.d limit 1;
  select x.employee_id, x.d into b2 from (
    select f.employee_id, min(public._face_distance(f.descriptor, v_d)) d
      from public.employee_faces f join public.employees e on e.id = f.employee_id and e.active
     group by f.employee_id) x where x.employee_id is distinct from b1.employee_id order by x.d limit 1;

  v_result := case
    when not coalesce(p_liveness, false) then 'sem_prova_de_vida'
    when b1.employee_id is null or b1.d > s.threshold then 'nao_reconhecido'
    when b2.employee_id is not null and b2.d - b1.d < s.margin then 'ambiguo'
    else 'reconhecido' end;
  v_sim := case when b1.d is not null then greatest(0, round((1 - b1.d)::numeric, 3)) end;

  insert into public.face_attempts (terminal_user_id, warehouse_id, employee_id, result, similarity, liveness)
  values (auth.uid(), p_warehouse_id, case when v_result = 'reconhecido' then b1.employee_id end, v_result,
          case when v_result = 'reconhecido' then v_sim end, coalesce(p_liveness, false));

  if v_result <> 'reconhecido' then
    return jsonb_build_object('ok', false, 'reason', v_result);
  end if;

  update public.counter_requests set status = 'cancelado', handled_at = now()
   where terminal_user_id = auth.uid() and status = 'pendente';
  insert into public.counter_requests (warehouse_id, terminal_user_id, employee_id, method, similarity)
  values (p_warehouse_id, auth.uid(), b1.employee_id, 'facial', v_sim)
  returning * into v_req;
  perform public.audit_event('biometria.identificacao', 'counter_requests', v_req.id::text, null, p_warehouse_id, null,
    jsonb_build_object('semelhanca', v_sim));
  return jsonb_build_object('ok', true, 'request_id', v_req.id, 'similarity', v_sim,
    'employee', (select jsonb_build_object('full_name', e.full_name, 'registration', e.registration)
                   from public.employees e where e.id = b1.employee_id));
end;
$$;

-- Sem reconhecimento: o tablet chama o almoxarife, que identifica pela matrícula
create or replace function public.counter_request_manual(p_warehouse_id uuid, p_reason text)
returns uuid
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare v_id uuid;
begin
  perform public._counter_terminal_check(p_warehouse_id);
  if (select count(*) from public.counter_requests
       where terminal_user_id = auth.uid() and created_at > now() - interval '5 minutes') >= 20 then
    raise exception 'Muitos pedidos seguidos. Aguarde o almoxarife.' using errcode = 'P0001';
  end if;
  update public.counter_requests set status = 'cancelado', handled_at = now()
   where terminal_user_id = auth.uid() and status = 'pendente';
  insert into public.counter_requests (warehouse_id, terminal_user_id, method, reason)
  values (p_warehouse_id, auth.uid(), 'manual', left(nullif(btrim(coalesce(p_reason, '')), ''), 200))
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.counter_request_cancel(p_id uuid)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare r public.counter_requests;
begin
  select * into r from public.counter_requests where id = p_id for update;
  if r.id is null then return; end if;
  if r.terminal_user_id <> auth.uid()
     and not (public.has_any_role(array['almoxarife', 'gestor', 'admin']::public.app_role[]) and public.can_access_warehouse(r.warehouse_id)) then
    raise exception 'Sem permissão.' using errcode = '42501';
  end if;
  if r.status = 'pendente' then
    update public.counter_requests set status = 'cancelado', handled_at = now(), handled_by = auth.uid() where id = p_id;
  end if;
end;
$$;

-- Situação do pedido para o tablet (aguardando ou já atendido)
create or replace function public.counter_request_status(p_id uuid)
returns jsonb
language sql stable security definer
set search_path = public, pg_temp
as $$
  select jsonb_build_object('status', case when r.status = 'pendente' and r.created_at < now() - interval '10 minutes'
                                           then 'expirado' else r.status end,
                            'movement_id', r.movement_id)
    from public.counter_requests r where r.id = p_id and r.terminal_user_id = auth.uid();
$$;

-- Tela do almoxarife: solicitantes esperando no balcão
create or replace function public.counter_requests_pending(p_warehouse_id uuid)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  if not public.has_any_role(array['almoxarife', 'gestor', 'admin']::public.app_role[]) or not public.can_access_warehouse(p_warehouse_id) then
    raise exception 'Sem permissão para este estoque.' using errcode = '42501';
  end if;
  update public.counter_requests set status = 'expirado', handled_at = now()
   where warehouse_id = p_warehouse_id and status = 'pendente' and created_at < now() - interval '10 minutes';
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', r.id, 'method', r.method, 'similarity', r.similarity, 'reason', r.reason, 'created_at', r.created_at,
             'terminal_user_id', r.terminal_user_id, 'terminal_name', p.full_name,
             'employee', case when e.id is not null then jsonb_build_object(
               'id', e.id, 'full_name', e.full_name, 'registration', e.registration, 'job_title', e.job_title,
               'sector_id', e.sector_id, 'active', e.active) end)
           order by r.created_at)
      from public.counter_requests r
      join public.profiles p on p.id = r.terminal_user_id
      left join public.employees e on e.id = r.employee_id
     where r.warehouse_id = p_warehouse_id and r.status = 'pendente'), '[]');
end;
$$;

-- Liga o pedido do tablet à ME aberta pelo almoxarife
create or replace function public.counter_request_attach(p_request_id uuid, p_movement_id uuid)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  r public.counter_requests;
  m public.stock_movements;
  v_s public.counter_sessions;
begin
  select * into r from public.counter_requests where id = p_request_id for update;
  select * into m from public.stock_movements where id = p_movement_id for update;
  select * into v_s from public.counter_sessions where movement_id = p_movement_id;
  if r.id is null or m.id is null or v_s.id is null then
    raise exception 'Pedido ou ME não encontrados.' using errcode = 'P0001';
  end if;
  if m.created_by <> auth.uid() then
    raise exception 'Só quem abriu a ME pode ligá-la ao pedido.' using errcode = '42501';
  end if;
  if r.status <> 'pendente' or r.created_at < now() - interval '10 minutes' then
    raise exception 'Este pedido do tablet já foi atendido, cancelado ou expirou.' using errcode = 'P0001';
  end if;
  if r.warehouse_id <> m.warehouse_id then
    raise exception 'O pedido é de outro estoque.' using errcode = '22023';
  end if;
  if r.employee_id is not null and r.employee_id <> m.requester_employee_id then
    raise exception 'O solicitante da ME é diferente do reconhecido no tablet.' using errcode = '22023';
  end if;
  if v_s.terminal_user_id is distinct from r.terminal_user_id then
    raise exception 'A ME precisa estar no mesmo tablet do pedido.' using errcode = '22023';
  end if;
  update public.counter_requests set status = 'atendido', movement_id = m.id, handled_at = now(), handled_by = auth.uid()
   where id = r.id;
  perform set_config('app.audit_action', 'me.solicitante_identificado', true);
  perform set_config('app.source', 'balcao', true);
  update public.stock_movements set requester_identified_by = r.method, requester_request_id = r.id where id = m.id;
end;
$$;

-- ---------------------------------------------------------------------
-- 5) Confirmação pelo rosto (1:1 com o solicitante da ME)
-- ---------------------------------------------------------------------
create or replace function public.face_confirmation_available(p_movement_id uuid)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare
  m public.stock_movements;
  v_s public.counter_sessions;
  v_fails int;
begin
  select * into m from public.stock_movements where id = p_movement_id;
  select * into v_s from public.counter_sessions where movement_id = p_movement_id;
  if v_s.id is null or v_s.terminal_user_id is distinct from auth.uid() then
    raise exception 'Tablet não pareado com esta ME.' using errcode = '42501';
  end if;
  if not (select enabled from public.face_settings where id = 1) then
    return jsonb_build_object('available', false, 'reason', 'desligado');
  end if;
  if not exists (select 1 from public.employee_faces where employee_id = m.requester_employee_id) then
    return jsonb_build_object('available', false, 'reason', 'sem_cadastro');
  end if;
  select count(*) into v_fails from public.confirmation_attempts
   where movement_id = m.id and method = 'facial' and result = 'falha';
  if v_fails >= 5 then
    return jsonb_build_object('available', false, 'reason', 'muitas_falhas');
  end if;
  return jsonb_build_object('available', true, 'tentativas_restantes', 5 - v_fails);
end;
$$;

create or replace function public.face_verify_confirmation(p_movement_id uuid, p_descriptor jsonb, p_liveness boolean)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  s     public.face_settings;
  m     public.stock_movements;
  v_av  jsonb;
  v_d   real[];
  v_min double precision;
  v_ok  boolean;
  v_sim numeric;
  v_att uuid;
begin
  v_av := public.face_confirmation_available(p_movement_id);
  if not (v_av ->> 'available')::boolean then
    raise exception 'Confirmação pelo rosto indisponível para esta ME (%). Confirme com foto e assinatura.', v_av ->> 'reason'
      using errcode = 'P0001';
  end if;
  select * into s from public.face_settings where id = 1;
  select * into m from public.stock_movements where id = p_movement_id;
  if m.status <> 'aguardando_assinatura' then
    raise exception 'A separação ainda não está pronta para confirmação.' using errcode = 'P0001';
  end if;
  v_d := public._face_descriptor(p_descriptor);
  select min(public._face_distance(f.descriptor, v_d)) into v_min
    from public.employee_faces f where f.employee_id = m.requester_employee_id;
  v_ok := coalesce(p_liveness, false) and v_min <= s.threshold;
  v_sim := greatest(0, round((1 - v_min)::numeric, 3));
  insert into public.confirmation_attempts (movement_id, employee_id, method, provider, result, score, liveness, detail)
  values (m.id, m.requester_employee_id, 'facial', 'reconhecimento_no_tablet', case when v_ok then 'sucesso' else 'falha' end,
          v_sim, coalesce(p_liveness, false),
          jsonb_build_object('rigor', s.threshold, 'motivo', case when not coalesce(p_liveness, false) then 'sem_prova_de_vida'
                                                                  when not v_ok then 'nao_reconhecido' end))
  returning id into v_att;
  if not v_ok then
    return jsonb_build_object('ok', false,
      'reason', case when not coalesce(p_liveness, false) then 'sem_prova_de_vida' else 'nao_reconhecido' end,
      'remaining', (public.face_confirmation_available(p_movement_id) ->> 'tentativas_restantes')::int);
  end if;
  return jsonb_build_object('ok', true, 'verification_id', v_att, 'similarity', v_sim);
end;
$$;

do $$
declare f text;
begin
  foreach f in array array['face_config()', 'face_settings_update(jsonb)', 'face_overview()', 'face_enroll(uuid, jsonb, text)',
                           'face_enroll_bulk(jsonb)', 'face_remove(uuid)', 'face_identify(uuid, jsonb, boolean)',
                           'counter_request_manual(uuid, text)', 'counter_request_cancel(uuid)', 'counter_request_status(uuid)',
                           'counter_requests_pending(uuid)', 'counter_request_attach(uuid, uuid)',
                           'face_confirmation_available(uuid)', 'face_verify_confirmation(uuid, jsonb, boolean)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- 7) Como o solicitante foi identificado e confirmou (tela de detalhe da ME)
-- ---------------------------------------------------------------------
create or replace function public.movement_identification(p_movement_id uuid)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare m public.stock_movements;
begin
  select * into m from public.stock_movements where id = p_movement_id;
  if m.id is null or not public.is_active_user() or not public.can_access_warehouse(m.warehouse_id) then
    return null;
  end if;
  return jsonb_build_object(
    'identificado_por', m.requester_identified_by,
    'confirmado_por', m.confirmation_method,
    'confirmado_em', m.confirmed_at,
    'semelhanca_inicio', (select r.similarity from public.counter_requests r where r.id = m.requester_request_id),
    'semelhanca_confirmacao', (select a.score from public.confirmation_attempts a
                                where a.movement_id = m.id and a.method = 'facial' and a.result = 'sucesso' and a.consumed_at is not null
                                order by a.created_at desc limit 1));
end;
$$;
revoke all on function public.movement_identification(uuid) from public, anon;
grant execute on function public.movement_identification(uuid) to authenticated;

-- Estoques do tablet (o perfil Terminal não recebe a lista de estoques no acesso)
create or replace function public.counter_terminal_warehouses()
returns jsonb
language sql stable security definer
set search_path = public, pg_temp
as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', w.id, 'name', w.name) order by w.name), '[]')
    from public.user_warehouses uw
    join public.warehouses w on w.id = uw.warehouse_id and w.active
   where uw.user_id = auth.uid() and public.is_terminal_of_warehouse(w.id);
$$;
revoke all on function public.counter_terminal_warehouses() from public, anon;
grant execute on function public.counter_terminal_warehouses() to authenticated;

-- ---------------------------------------------------------------------
-- 6) Trilha, alerta e relatório do titular (versões atualizadas)
-- ---------------------------------------------------------------------
create or replace function public.audit_classify(p_action text, p_entity text, out category text, out severity text)
language plpgsql immutable
set search_path = public, pg_temp
as $$
begin
  if p_action like 'auth.%' then
    category := 'autenticacao'; severity := 'aviso';
  elsif p_action like 'acesso.%' then
    category := 'autorizacao'; severity := 'aviso';
  elsif p_entity in ('user_roles', 'user_warehouses', 'profiles') or p_action like 'usuario.%' then
    category := 'permissao'; severity := 'critico';
  elsif p_entity in ('app_settings', 'warehouses') then
    category := 'configuracao'; severity := 'critico';
  elsif p_action like 'incidente.%' then
    category := 'incidente'; severity := 'critico';
  elsif p_action = 'biometria.configuracao' then
    category := 'configuracao'; severity := 'critico';
  elsif p_action like 'biometria.%' then
    category := 'privacidade'; severity := 'aviso';
  elsif p_action like 'titular.%' then
    category := 'privacidade'; severity := 'aviso';
  elsif p_action like 'privacidade.%' then
    category := 'configuracao'; severity := 'critico';
  elsif p_action like 'alerta.%' then
    category := 'incidente'; severity := 'aviso';
  elsif p_action like 'retencao%' or p_action like 'seguranca.%' then
    category := 'auditoria'; severity := 'critico';
  elsif p_action like 'auditoria.descarte_%' then
    category := 'auditoria'; severity := 'critico';
  elsif p_action like 'auditoria.%' then
    category := 'auditoria';
    severity := case when p_action in ('auditoria.exportada', 'auditoria.integridade_verificada', 'auditoria.ancora_conferida') then 'critico' else 'aviso' end;
  elsif p_action in ('me.assinatura_consultada', 'me.foto_consultada') then
    category := 'privacidade'; severity := 'aviso';
  elsif p_action like 'exportacao.%' or p_action in ('me.impressa', 'me.pdf_gerado', 'etiquetas.impressas') then
    category := 'exportacao'; severity := 'aviso';
  elsif p_entity in ('employees', 'materials', 'material_qr_codes', 'contracts', 'sectors', 'service_fronts',
                     'service_orders', 'fixed_assets', 'application_locations', 'accounts', 'material_categories') then
    category := 'cadastro'; severity := 'info';
  else
    category := 'dados'; severity := 'info';
  end if;
end;
$$;

create or replace function public._security_checks()
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_chain   jsonb;
  v_last    timestamptz;
  v_imp     integer;
  v_alerts  integer := 0;
  p         record;
  i         public.security_incidents;
  d         jsonb;
  q         public.data_subject_requests;
  v_today   date := (now() at time zone coalesce((public.get_settings()).timezone, 'America/Recife'))::date;
  v_due     bigint;
begin
  v_imp := public.security_import_auth_events();

  v_chain := public._audit_verify(null);
  if not (v_chain ->> 'ok')::boolean then
    perform public._raise_alert('integridade', 'critico', 'A verificação de integridade da auditoria falhou',
      coalesce(v_chain ->> 'problem_seq', ''), v_chain);
    v_alerts := v_alerts + 1;
  end if;

  select max(occurred_at) into v_last from public.audit_logs where category is distinct from 'auditoria';
  if v_last is null or v_last < now() - interval '72 hours' then
    perform public._raise_alert('coleta_parada', 'aviso', 'Nenhum evento de operação registrado há mais de 72 horas', '',
      jsonb_build_object('ultimo_evento', v_last));
    v_alerts := v_alerts + 1;
  end if;

  for p in select * from public.audit_retention_policies where status = 'aprovada' and retain_days is not null loop
    select count(*) into v_due from public.audit_logs
     where category = p.category and purged_at is null
       and occurred_at < now() - make_interval(days => greatest(p.retain_days - 30, 0));
    if v_due > 0 then
      perform public._raise_alert('retencao_vencendo', 'aviso',
        'Eventos de ' || p.category || ' chegando ao fim do prazo de retenção', p.category,
        jsonb_build_object('categoria', p.category, 'eventos', v_due, 'prazo_dias', p.retain_days));
      v_alerts := v_alerts + 1;
    end if;
  end loop;

  -- Incidentes: prazo de comunicação vencendo (até 1 dia útil) ou vencido; risco sem avaliação
  for i in select * from public.security_incidents where status <> 'encerrado' loop
    d := public._incident_deadlines(i);
    if (d ->> 'aplica')::boolean and i.anpd_communicated_at is null and (d ->> 'anpd_dias_restantes')::int <= 1 then
      perform public._raise_alert('incidente_prazo', 'critico',
        'Incidente ' || i.code || ': prazo de comunicação à ANPD ' ||
        case when (d ->> 'anpd_dias_restantes')::int < 0 then 'VENCIDO em ' else 'vence em ' end || to_char((d ->> 'anpd_prazo')::date, 'DD/MM/YYYY'),
        'anpd:' || i.id, jsonb_build_object('incidente', i.code, 'prazo', d ->> 'anpd_prazo', 'dias_uteis_restantes', d -> 'anpd_dias_restantes'));
      v_alerts := v_alerts + 1;
    end if;
    if (d ->> 'aplica')::boolean and i.titulares_communicated_at is null and (d ->> 'titulares_dias_restantes')::int <= 1 then
      perform public._raise_alert('incidente_prazo', 'critico',
        'Incidente ' || i.code || ': prazo de comunicação aos titulares ' ||
        case when (d ->> 'titulares_dias_restantes')::int < 0 then 'VENCIDO em ' else 'vence em ' end || to_char((d ->> 'titulares_prazo')::date, 'DD/MM/YYYY'),
        'titulares:' || i.id, jsonb_build_object('incidente', i.code, 'prazo', d ->> 'titulares_prazo', 'dias_uteis_restantes', d -> 'titulares_dias_restantes'));
      v_alerts := v_alerts + 1;
    end if;
    if i.risk_level = 'a_avaliar' and i.known_at < now() - interval '24 hours' then
      perform public._raise_alert('incidente_sem_avaliacao', 'aviso',
        'Incidente ' || i.code || ' sem avaliação de risco há mais de 24 horas', i.id::text,
        jsonb_build_object('incidente', i.code));
      v_alerts := v_alerts + 1;
    end if;
  end loop;

  -- Pedidos de titulares: resposta vencendo (até 2 dias) ou vencida
  for q in select * from public.data_subject_requests where status in ('recebido', 'em_analise') and due_date - v_today <= 2 loop
    perform public._raise_alert('titular_prazo', case when v_today > q.due_date then 'critico' else 'aviso' end,
      'Pedido de titular ' || q.code || ': resposta ' || case when v_today > q.due_date then 'VENCIDA em ' else 'vence em ' end
        || to_char(q.due_date, 'DD/MM/YYYY'),
      q.id::text, jsonb_build_object('pedido', q.code, 'prazo', q.due_date));
    v_alerts := v_alerts + 1;
  end loop;

  -- Reconhecimento facial: funcionário com rosto cadastrado confirmando por assinatura com frequência
  -- (pode ser só um cadastro ruim, mas também alguém evitando o reconhecimento)
  if (select enabled from public.face_settings where id = 1) then
    for q in
      select m.requester_employee_id as emp, count(*) as n
        from public.stock_movements m
       where m.confirmation_method = 'assinatura' and m.confirmed_at > now() - interval '7 days'
         and exists (select 1 from public.employee_faces f where f.employee_id = m.requester_employee_id)
       group by m.requester_employee_id having count(*) >= 3
    loop
      perform public._raise_alert('biometria_alternativa', 'aviso',
        'Funcionário com rosto cadastrado confirmou ' || q.n || ' retiradas por assinatura em 7 dias',
        q.emp::text, jsonb_build_object('employee_id', q.emp, 'confirmacoes_por_assinatura', q.n));
      v_alerts := v_alerts + 1;
    end loop;
  end if;

  insert into public.security_state (key, value, updated_at)
  values ('last_checks', jsonb_build_object('at', now(), 'integridade', v_chain -> 'ok', 'importados_auth', v_imp, 'alertas', v_alerts), now())
  on conflict (key) do update set value = excluded.value, updated_at = now();

  return jsonb_build_object('integridade', v_chain, 'importados_auth', v_imp, 'alertas', v_alerts, 'at', now());
end;
$$;
revoke all on function public._security_checks() from public, anon, authenticated;

create or replace function public.dsr_employee_report(p_employee_id uuid, p_request_id bigint default null)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  e       public.employees;
  v_tz    text := coalesce((public.get_settings()).timezone, 'America/Recife');
  v_code  text;
  v_out   jsonb;
begin
  if not public.is_admin() then
    raise exception 'Somente o administrador gera o relatório do titular.' using errcode = '42501';
  end if;
  select * into e from public.employees where id = p_employee_id;
  if e.id is null then
    raise exception 'Funcionário não encontrado.' using errcode = 'P0001';
  end if;
  if p_request_id is not null then
    select code into v_code from public.data_subject_requests where id = p_request_id;
    if v_code is null then
      raise exception 'Pedido não encontrado.' using errcode = 'P0001';
    end if;
  end if;

  v_out := jsonb_build_object(
    'gerado_em', now(),
    'pedido', v_code,
    'cadastro', jsonb_build_object(
      'matricula', e.registration, 'nome', e.full_name, 'cargo', e.job_title,
      'setor', (select s.name from public.sectors s where s.id = e.sector_id),
      'ativo', e.active, 'cadastrado_em', e.created_at, 'atualizado_em', e.updated_at),
    'retiradas', coalesce((
      select jsonb_agg(jsonb_build_object(
               'me', m.me_number,
               'data', to_char(m.movement_at at time zone v_tz, 'DD/MM/YYYY HH24:MI'),
               'estoque', w.name,
               'situacao', m.status,
               'emergencial', coalesce(m.is_emergency, false),
               'itens', (select count(*) from public.stock_movement_items i where i.movement_id = m.id),
               'assinatura', exists (select 1 from public.signatures s where s.movement_id = m.id),
               'foto', exists (select 1 from public.movement_photos f where f.movement_id = m.id))
             order by m.movement_at desc)
        from public.stock_movements m join public.warehouses w on w.id = m.warehouse_id
       where m.requester_employee_id = e.id), '[]'),
    'fotos', (select count(*) from public.movement_photos f
               where f.employee_id = e.id or f.movement_id in (select id from public.stock_movements where requester_employee_id = e.id)),
    'assinaturas', (select count(*) from public.signatures s
                     where s.movement_id in (select id from public.stock_movements where requester_employee_id = e.id)),
    'biometria', (select jsonb_build_object('rosto_cadastrado', count(*) > 0, 'modelos', count(*),
                                            'cadastrado_em', max(f.created_at), 'origem', string_agg(distinct f.source, ', '),
                                            'retiradas_confirmadas_pelo_rosto',
                                            (select count(*) from public.stock_movements m2
                                              where m2.requester_employee_id = e.id and m2.confirmation_method = 'facial'))
                    from public.employee_faces f where f.employee_id = e.id),
    'eventos_de_auditoria_sobre_o_cadastro', (select count(*) from public.audit_logs a where a.entity = 'employees' and a.entity_id = e.id::text),
    'observacoes', jsonb_build_array(
      'Os registros de saída finalizados não podem ser apagados: servem de prova da movimentação de material.',
      'A trilha de auditoria guarda o nome do funcionário omitido e a matrícula mascarada.',
      'Cópias de assinatura e foto podem ser fornecidas mediante pedido, após conferência de identidade.',
      'Do rosto, o sistema guarda só uma representação numérica usada na comparação (sem foto); ela é apagada quando o funcionário é inativado.'));

  if p_request_id is not null then
    insert into public.data_subject_request_notes (request_id, kind, body, created_by)
    values (p_request_id, 'nota', 'Relatório de dados do titular gerado', auth.uid());
  end if;
  perform public.audit_event('titular.relatorio_gerado', 'employees', e.id::text, null, null, null,
    jsonb_build_object('pedido', v_code, 'retiradas', jsonb_array_length(v_out -> 'retiradas')));
  return v_out;
end;
$$;
revoke all on function public.dsr_employee_report(uuid, bigint) from public, anon;
grant execute on function public.dsr_employee_report(uuid, bigint) to authenticated;
