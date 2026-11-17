-- =====================================================================
-- 25 - PEDIDOS DE TITULARES (LGPD art. 18) - fase 4 do plano
--
-- * Registro dos pedidos dos titulares (colaboradores): direitos do art. 18
--   pedidos, canal, conferência de identidade, prazo, resposta e histórico.
--   Pedidos nunca são apagados.
-- * Prazo de resposta configurável (padrão 15 dias corridos, referência do
--   art. 19, II - declaração completa de confirmação/acesso). Para os demais
--   direitos não há prazo regulamentado: o padrão é o mesmo, a validar.
-- * Relatório "o que o sistema guarda sobre este funcionário" (apoio ao
--   direito de acesso), registrado na auditoria.
-- * Canal de atendimento (D6) fica "a definir" até a empresa decidir.
-- * Alerta de prazo de resposta vencendo/vencido.
--
-- A minimização e a validade da cópia offline do tablet ficam no site
-- (só nome e matrícula; 7 dias; apagada ao sair).
--
-- Pré-requisito: 24. Pode ser reexecutado.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) Tabelas
-- ---------------------------------------------------------------------
alter table public.privacy_settings add column if not exists titular_channel text;
alter table public.privacy_settings add column if not exists titular_response_days integer not null default 15;
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'privacy_settings_titular_days_ck') then
    alter table public.privacy_settings add constraint privacy_settings_titular_days_ck check (titular_response_days between 1 and 90);
  end if;
end $$;

create table if not exists public.data_subject_requests (
  id                      bigint generated always as identity primary key,
  code                    text not null unique,
  received_at             timestamptz not null,
  channel                 text,
  requester_name          text not null check (length(btrim(requester_name)) between 3 and 160),
  requester_registration  text,
  employee_id             uuid references public.employees (id),
  rights                  text[] not null,
  description             text,
  identity_verified       boolean not null default false,
  identity_method         text,
  status                  text not null default 'recebido'
                          check (status in ('recebido', 'em_analise', 'atendido', 'atendido_parcialmente', 'indeferido')),
  due_date                date not null,
  responded_at            timestamptz,
  response_summary        text,
  denial_reason           text,
  created_by              uuid references public.profiles (id),
  created_at              timestamptz not null default now(),
  updated_by              uuid references public.profiles (id),
  updated_at              timestamptz not null default now(),
  check (cardinality(rights) between 1 and 10)
);
create index if not exists data_subject_requests_status_idx on public.data_subject_requests (status, due_date);

create table if not exists public.data_subject_request_notes (
  id          bigint generated always as identity primary key,
  request_id  bigint not null references public.data_subject_requests (id),
  kind        text not null default 'nota' check (kind in ('nota', 'alteracao', 'status')),
  body        text not null,
  created_by  uuid references public.profiles (id),
  created_at  timestamptz not null default now()
);
create index if not exists data_subject_request_notes_idx on public.data_subject_request_notes (request_id, created_at);

do $$
declare t text;
begin
  foreach t in array array['data_subject_requests', 'data_subject_request_notes'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
  end loop;
end $$;

create or replace function public.tg_block_dsr_delete()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  raise exception 'Pedidos de titulares e o histórico deles não podem ser excluídos.' using errcode = 'P0001';
end;
$$;
drop trigger if exists block_delete on public.data_subject_requests;
create trigger block_delete before delete on public.data_subject_requests
  for each row execute function public.tg_block_dsr_delete();
drop trigger if exists block_change on public.data_subject_request_notes;
create trigger block_change before update or delete on public.data_subject_request_notes
  for each row execute function public.tg_block_dsr_delete();

-- ---------------------------------------------------------------------
-- 2) Classificação (titular.* = privacidade) e configuração do canal (D6)
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

create or replace function public.privacy_settings_update(p jsonb)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_old public.privacy_settings;
  v_new public.privacy_settings;
  v_changed text[];
  k text;
begin
  if not public.is_admin() then
    raise exception 'Somente o administrador altera a configuração LGPD.' using errcode = '42501';
  end if;
  select * into v_old from public.privacy_settings where id for update;
  v_new := v_old;
  if p ? 'controller_name' then v_new.controller_name := nullif(btrim(left(p ->> 'controller_name', 200)), ''); end if;
  if p ? 'controller_doc'  then v_new.controller_doc  := nullif(btrim(left(p ->> 'controller_doc', 40)), ''); end if;
  if p ? 'dpo_name'        then v_new.dpo_name        := nullif(btrim(left(p ->> 'dpo_name', 200)), ''); end if;
  if p ? 'dpo_contact'     then v_new.dpo_contact     := nullif(btrim(left(p ->> 'dpo_contact', 200)), ''); end if;
  if p ? 'small_agent'     then v_new.small_agent     := (p ->> 'small_agent')::boolean; end if;
  if p ? 'titular_channel' then v_new.titular_channel := nullif(btrim(left(p ->> 'titular_channel', 300)), ''); end if;
  if p ? 'titular_response_days' then
    v_new.titular_response_days := coalesce((p ->> 'titular_response_days')::int, 15);
    if v_new.titular_response_days not between 1 and 90 then
      raise exception 'Prazo de resposta entre 1 e 90 dias.' using errcode = 'P0001';
    end if;
  end if;
  select array_agg(key order by key) into v_changed
    from jsonb_each(to_jsonb(v_new)) n
   where key in ('controller_name', 'controller_doc', 'dpo_name', 'dpo_contact', 'small_agent', 'titular_channel', 'titular_response_days')
     and n.value is distinct from to_jsonb(v_old) -> key;
  if v_changed is null then
    return;
  end if;
  update public.privacy_settings
     set controller_name = v_new.controller_name, controller_doc = v_new.controller_doc,
         dpo_name = v_new.dpo_name, dpo_contact = v_new.dpo_contact, small_agent = v_new.small_agent,
         titular_channel = v_new.titular_channel, titular_response_days = v_new.titular_response_days,
         updated_by = auth.uid(), updated_at = now()
   where id;
  -- Na trilha vão só os nomes dos campos (o nome do encarregado é dado pessoal)
  perform public.audit_event('privacidade.configuracao_alterada', 'privacy_settings', null, null, null, null,
    jsonb_build_object('campos', v_changed, 'pequeno_porte', v_new.small_agent));
end;
$$;

-- ---------------------------------------------------------------------
-- 3) Funções
-- ---------------------------------------------------------------------
-- Direitos do art. 18 (I a IX) e oposição (§ 2º)
create or replace function public._dsr_valid_rights(p text[])
returns boolean
language sql immutable
set search_path = public, pg_temp
as $$
  select coalesce(cardinality(p), 0) between 1 and 10
     and not exists (select 1 from unnest(p) r where r not in (
       'confirmacao', 'acesso', 'correcao', 'anonimizacao_bloqueio_eliminacao', 'portabilidade',
       'eliminacao_consentimento', 'info_compartilhamento', 'info_nao_consentir', 'revogacao_consentimento', 'oposicao'));
$$;

create or replace function public._dsr_view(r public.data_subject_requests)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare
  v_tz    text := coalesce((public.get_settings()).timezone, 'America/Recife');
  v_today date := (now() at time zone v_tz)::date;
  v_open  boolean := r.status in ('recebido', 'em_analise');
  v_done  date := (r.responded_at at time zone v_tz)::date;
begin
  return to_jsonb(r) || jsonb_build_object(
    'created_by_name', (select full_name from public.profiles where id = r.created_by),
    'updated_by_name', (select full_name from public.profiles where id = r.updated_by),
    'employee', (select jsonb_build_object('id', e.id, 'registration', e.registration, 'full_name', e.full_name)
                   from public.employees e where e.id = r.employee_id),
    'dias_restantes', case when v_open then r.due_date - v_today end,
    'situacao_prazo', case
      when v_open and v_today > r.due_date then 'atrasado'
      when v_open then 'pendente'
      when v_done <= r.due_date then 'cumprido'
      else 'cumprido_com_atraso' end);
end;
$$;

create or replace function public.dsr_overview()
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
begin
  if not public.is_admin() then
    raise exception 'Somente o administrador acessa os pedidos de titulares.' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'settings', (select jsonb_build_object('titular_channel', s.titular_channel, 'titular_response_days', s.titular_response_days,
                                           'dpo_name', s.dpo_name, 'dpo_contact', s.dpo_contact)
                   from public.privacy_settings s where s.id),
    'requests', coalesce((select jsonb_agg(public._dsr_view(r) order by (r.status in ('recebido', 'em_analise')) desc, r.due_date, r.id desc)
                           from public.data_subject_requests r), '[]'));
end;
$$;

create or replace function public.dsr_open(p jsonb)
returns bigint
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_tz     text := coalesce((public.get_settings()).timezone, 'America/Recife');
  v_days   integer := (select titular_response_days from public.privacy_settings where id);
  v_recv   timestamptz := coalesce(nullif(p ->> 'received_at', '')::timestamptz, now());
  v_name   text := btrim(coalesce(p ->> 'requester_name', ''));
  v_reg    text := nullif(btrim(left(coalesce(p ->> 'requester_registration', ''), 30)), '');
  v_emp    uuid := nullif(p ->> 'employee_id', '')::uuid;
  v_rights text[] := array(select distinct jsonb_array_elements_text(coalesce(p -> 'rights', '[]')) order by 1);
  v_year   integer;
  v_seq    integer;
  v_code   text;
  v_id     bigint;
begin
  if not public.is_admin() then
    raise exception 'Somente o administrador registra pedidos de titulares.' using errcode = '42501';
  end if;
  if length(v_name) not between 3 and 160 then
    raise exception 'Informe o nome de quem fez o pedido.' using errcode = 'P0001';
  end if;
  if not public._dsr_valid_rights(v_rights) then
    raise exception 'Escolha ao menos um direito pedido (art. 18).' using errcode = 'P0001';
  end if;
  if v_recv > now() + interval '5 minutes' then
    raise exception 'A data do pedido não pode estar no futuro.' using errcode = 'P0001';
  end if;
  if v_emp is not null and not exists (select 1 from public.employees where id = v_emp) then
    raise exception 'Funcionário não encontrado.' using errcode = 'P0001';
  end if;
  if v_emp is null and v_reg is not null then
    select id into v_emp from public.employees where registration = v_reg;
  end if;

  v_year := extract(year from (now() at time zone v_tz))::int;
  perform pg_advisory_xact_lock(704200125);
  select count(*) + 1 into v_seq from public.data_subject_requests where code like 'SOL-' || v_year || '-%';
  v_code := 'SOL-' || v_year || '-' || lpad(v_seq::text, 3, '0');

  insert into public.data_subject_requests (code, received_at, channel, requester_name, requester_registration, employee_id,
                                            rights, description, due_date, created_by, updated_by)
  values (v_code, v_recv, nullif(btrim(left(coalesce(p ->> 'channel', ''), 200)), ''), v_name, v_reg, v_emp, v_rights,
          nullif(btrim(left(coalesce(p ->> 'description', ''), 5000)), ''),
          (v_recv at time zone v_tz)::date + v_days, auth.uid(), auth.uid())
  returning id into v_id;
  insert into public.data_subject_request_notes (request_id, kind, body, created_by)
  values (v_id, 'status', 'Pedido registrado; prazo de resposta: ' || v_days || ' dias', auth.uid());
  -- Na trilha: código e direitos (sem o nome de quem pediu)
  perform public.audit_event('titular.pedido_registrado', 'data_subject_requests', v_code, null, null, null,
    jsonb_build_object('codigo', v_code, 'direitos', v_rights, 'vinculado_a_funcionario', v_emp is not null));
  return v_id;
end;
$$;

create or replace function public.dsr_get(p_id bigint)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare
  r public.data_subject_requests;
begin
  if not public.is_admin() then
    raise exception 'Somente o administrador acessa os pedidos de titulares.' using errcode = '42501';
  end if;
  select * into r from public.data_subject_requests where id = p_id;
  if r.id is null then
    raise exception 'Pedido não encontrado.' using errcode = 'P0001';
  end if;
  return public._dsr_view(r) || jsonb_build_object('notes', coalesce((
    select jsonb_agg(jsonb_build_object('id', n.id, 'kind', n.kind, 'body', n.body, 'created_at', n.created_at,
                                        'created_by_name', (select full_name from public.profiles where id = n.created_by)) order by n.created_at, n.id)
      from public.data_subject_request_notes n where n.request_id = p_id), '[]'));
end;
$$;

create or replace function public.dsr_update(p_id bigint, p jsonb)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  r        public.data_subject_requests;
  v_new    public.data_subject_requests;
  v_changed text[] := '{}';
begin
  if not public.is_admin() then
    raise exception 'Somente o administrador altera pedidos de titulares.' using errcode = '42501';
  end if;
  select * into r from public.data_subject_requests where id = p_id for update;
  if r.id is null then
    raise exception 'Pedido não encontrado.' using errcode = 'P0001';
  end if;
  if r.status not in ('recebido', 'em_analise') then
    raise exception 'Pedido já respondido; acrescente uma anotação.' using errcode = 'P0001';
  end if;
  v_new := r;
  if p ? 'status' then
    if p ->> 'status' not in ('recebido', 'em_analise') then
      raise exception 'Para responder, use o botão Registrar resposta.' using errcode = 'P0001';
    end if;
    v_new.status := p ->> 'status';
  end if;
  if p ? 'rights' then
    v_new.rights := array(select distinct jsonb_array_elements_text(coalesce(p -> 'rights', '[]')) order by 1);
    if not public._dsr_valid_rights(v_new.rights) then
      raise exception 'Escolha ao menos um direito pedido (art. 18).' using errcode = 'P0001';
    end if;
  end if;
  if p ? 'employee_id' then
    v_new.employee_id := nullif(p ->> 'employee_id', '')::uuid;
    if v_new.employee_id is not null and not exists (select 1 from public.employees where id = v_new.employee_id) then
      raise exception 'Funcionário não encontrado.' using errcode = 'P0001';
    end if;
  end if;
  if p ? 'channel' then v_new.channel := nullif(btrim(left(coalesce(p ->> 'channel', ''), 200)), ''); end if;
  if p ? 'description' then v_new.description := nullif(btrim(left(coalesce(p ->> 'description', ''), 5000)), ''); end if;
  if p ? 'identity_verified' then v_new.identity_verified := coalesce((p ->> 'identity_verified')::boolean, false); end if;
  if p ? 'identity_method' then v_new.identity_method := nullif(btrim(left(coalesce(p ->> 'identity_method', ''), 500)), ''); end if;
  if v_new.identity_verified and v_new.identity_method is null then
    raise exception 'Descreva como a identidade foi conferida.' using errcode = 'P0001';
  end if;

  select array_agg(n.key order by n.key) into v_changed
    from jsonb_each(to_jsonb(v_new)) n
   where n.key in ('status', 'rights', 'employee_id', 'channel', 'description', 'identity_verified', 'identity_method')
     and n.value is distinct from to_jsonb(r) -> n.key;
  if v_changed is null then
    return;
  end if;
  update public.data_subject_requests
     set status = v_new.status, rights = v_new.rights, employee_id = v_new.employee_id, channel = v_new.channel,
         description = v_new.description, identity_verified = v_new.identity_verified, identity_method = v_new.identity_method,
         updated_by = auth.uid(), updated_at = now()
   where id = p_id;
  insert into public.data_subject_request_notes (request_id, kind, body, created_by)
  values (p_id, case when 'status' = any (v_changed) then 'status' else 'alteracao' end,
          'Alterado: ' || (select string_agg(coalesce(('{"status":"situação","rights":"direitos pedidos","employee_id":"funcionário vinculado",
             "channel":"canal","description":"descrição","identity_verified":"identidade conferida","identity_method":"forma de conferência"}'::jsonb ->> fld), fld), ', ')
             from unnest(v_changed) fld), auth.uid());
  perform public.audit_event('titular.pedido_atualizado', 'data_subject_requests', r.code, null, null, null,
    jsonb_build_object('codigo', r.code, 'campos', v_changed, 'situacao', v_new.status, 'identidade_conferida', v_new.identity_verified));
end;
$$;

create or replace function public.dsr_respond(p_id bigint, p_outcome text, p_summary text, p_denial_reason text)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  r public.data_subject_requests;
begin
  if not public.is_admin() then
    raise exception 'Somente o administrador responde pedidos de titulares.' using errcode = '42501';
  end if;
  select * into r from public.data_subject_requests where id = p_id for update;
  if r.id is null then
    raise exception 'Pedido não encontrado.' using errcode = 'P0001';
  end if;
  if r.status not in ('recebido', 'em_analise') then
    raise exception 'Pedido já respondido.' using errcode = 'P0001';
  end if;
  if coalesce(p_outcome, '') not in ('atendido', 'atendido_parcialmente', 'indeferido') then
    raise exception 'Resultado inválido.' using errcode = 'P0001';
  end if;
  if not r.identity_verified then
    raise exception 'Confira e registre a identidade de quem pediu antes de responder.' using errcode = 'P0001';
  end if;
  if length(btrim(coalesce(p_summary, ''))) < 10 then
    raise exception 'Resuma a resposta dada (mínimo de 10 caracteres).' using errcode = 'P0001';
  end if;
  if p_outcome <> 'atendido' and length(btrim(coalesce(p_denial_reason, ''))) < 10 then
    raise exception 'Explique o motivo de não atender (art. 18, § 4º; mínimo de 10 caracteres).' using errcode = 'P0001';
  end if;
  update public.data_subject_requests
     set status = p_outcome, responded_at = now(), response_summary = btrim(left(p_summary, 5000)),
         denial_reason = case when p_outcome <> 'atendido' then btrim(left(p_denial_reason, 5000)) end,
         updated_by = auth.uid(), updated_at = now()
   where id = p_id;
  insert into public.data_subject_request_notes (request_id, kind, body, created_by)
  values (p_id, 'status', 'Resposta registrada: ' || replace(p_outcome, '_', ' '), auth.uid());
  perform public.audit_event('titular.pedido_respondido', 'data_subject_requests', r.code, null, null, null,
    jsonb_build_object('codigo', r.code, 'resultado', p_outcome, 'no_prazo', (now() at time zone coalesce((public.get_settings()).timezone, 'America/Recife'))::date <= r.due_date));
end;
$$;

create or replace function public.dsr_add_note(p_id bigint, p_body text)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_code text;
begin
  if not public.is_admin() then
    raise exception 'Somente o administrador anota pedidos de titulares.' using errcode = '42501';
  end if;
  select code into v_code from public.data_subject_requests where id = p_id;
  if v_code is null then
    raise exception 'Pedido não encontrado.' using errcode = 'P0001';
  end if;
  if length(btrim(coalesce(p_body, ''))) not between 3 and 5000 then
    raise exception 'Escreva a anotação (3 a 5000 caracteres).' using errcode = 'P0001';
  end if;
  insert into public.data_subject_request_notes (request_id, kind, body, created_by) values (p_id, 'nota', btrim(p_body), auth.uid());
  perform public.audit_event('titular.pedido_anotado', 'data_subject_requests', v_code, null, null, null, jsonb_build_object('codigo', v_code));
end;
$$;

-- O que o sistema guarda sobre um funcionário (apoio ao direito de acesso, art. 18, II, e art. 19)
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
    'eventos_de_auditoria_sobre_o_cadastro', (select count(*) from public.audit_logs a where a.entity = 'employees' and a.entity_id = e.id::text),
    'observacoes', jsonb_build_array(
      'Os registros de saída finalizados não podem ser apagados: servem de prova da movimentação de material.',
      'A trilha de auditoria guarda o nome do funcionário omitido e a matrícula mascarada.',
      'Cópias de assinatura e foto podem ser fornecidas mediante pedido, após conferência de identidade.'));

  if p_request_id is not null then
    insert into public.data_subject_request_notes (request_id, kind, body, created_by)
    values (p_request_id, 'nota', 'Relatório de dados do titular gerado', auth.uid());
  end if;
  perform public.audit_event('titular.relatorio_gerado', 'employees', e.id::text, null, null, null,
    jsonb_build_object('pedido', v_code, 'retiradas', jsonb_array_length(v_out -> 'retiradas')));
  return v_out;
end;
$$;

-- ---------------------------------------------------------------------
-- 4) Verificações periódicas: inclui o prazo dos pedidos de titulares
-- ---------------------------------------------------------------------
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

  insert into public.security_state (key, value, updated_at)
  values ('last_checks', jsonb_build_object('at', now(), 'integridade', v_chain -> 'ok', 'importados_auth', v_imp, 'alertas', v_alerts), now())
  on conflict (key) do update set value = excluded.value, updated_at = now();

  return jsonb_build_object('integridade', v_chain, 'importados_auth', v_imp, 'alertas', v_alerts, 'at', now());
end;
$$;

-- ---------------------------------------------------------------------
-- 5) Permissões
-- ---------------------------------------------------------------------
revoke all on function public.tg_block_dsr_delete() from public, anon, authenticated;
revoke all on function public._dsr_view(public.data_subject_requests) from public, anon, authenticated;
revoke all on function public._dsr_valid_rights(text[]) from public, anon, authenticated;
revoke all on function public._security_checks() from public, anon, authenticated;
do $$
declare f text;
begin
  foreach f in array array['dsr_overview()', 'dsr_open(jsonb)', 'dsr_get(bigint)', 'dsr_update(bigint, jsonb)',
                           'dsr_respond(bigint, text, text, text)', 'dsr_add_note(bigint, text)',
                           'dsr_employee_report(uuid, bigint)', 'privacy_settings_update(jsonb)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
