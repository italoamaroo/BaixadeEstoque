-- =====================================================================
-- 24 - INCIDENTES DE SEGURANÇA E CONFIGURAÇÃO LGPD
--      (fase 3 do plano de auditoria e LGPD - parte técnica)
--
-- * Registro de incidentes com os campos mínimos do art. 10, § 1º, da
--   Resolução CD/ANPD nº 15/2024 (incisos I a VIII). Incidentes nunca são
--   apagados (o art. 10 exige guarda mínima de 5 anos).
-- * Prazos em dias úteis: comunicação à ANPD (art. 6º) e aos titulares
--   (art. 9º): 3 dias úteis contados do conhecimento de que o incidente
--   afetou dados pessoais; complementação (art. 6º, § 3º): 20 dias úteis da
--   comunicação; declaração da comunicação aos titulares (art. 9º, § 4º):
--   3 dias úteis após o fim do prazo do art. 9º. Em dobro para agente de
--   pequeno porte (art. 6º, § 8º; art. 9º, § 6º) - SÓ quando marcado.
--   Contagem (interpretação técnica, a validar com o jurídico): exclui o dia
--   do conhecimento; pula sábados, domingos e feriados cadastrados.
-- * Configuração LGPD: controlador, encarregado e porte ficam "a definir"
--   até a empresa decidir (D1 e D5). Sem porte definido, vale o prazo simples
--   (o mais curto).
-- * Alertas: prazo de comunicação vencendo/vencido e incidente sem avaliação
--   de risco.
--
-- Pré-requisito: 23. Pode ser reexecutado.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) Tabelas
-- ---------------------------------------------------------------------
create table if not exists public.privacy_settings (
  id               boolean primary key default true check (id),
  controller_name  text,
  controller_doc   text,
  dpo_name         text,
  dpo_contact      text,
  small_agent      boolean,
  updated_by       uuid references public.profiles (id),
  updated_at       timestamptz not null default now()
);
insert into public.privacy_settings (id) values (true) on conflict do nothing;

create table if not exists public.business_holidays (
  day         date primary key,
  name        text not null check (length(btrim(name)) between 2 and 120),
  scope       text not null default 'nacional' check (scope in ('nacional', 'estadual', 'municipal', 'empresa')),
  created_by  uuid references public.profiles (id),
  created_at  timestamptz not null default now()
);
-- Feriados nacionais (Lei 662/1949, Lei 6.802/1980, Lei 14.759/2023 e Sexta-feira Santa).
-- Estaduais e municipais (Pernambuco/Recife/Jaboatão) devem ser cadastrados pelo administrador.
insert into public.business_holidays (day, name) values
  ('2026-01-01', 'Confraternização Universal'), ('2026-04-03', 'Sexta-feira Santa'),
  ('2026-04-21', 'Tiradentes'), ('2026-05-01', 'Dia do Trabalho'),
  ('2026-09-07', 'Independência'), ('2026-10-12', 'Nossa Senhora Aparecida'),
  ('2026-11-02', 'Finados'), ('2026-11-15', 'Proclamação da República'),
  ('2026-11-20', 'Dia Nacional de Zumbi e da Consciência Negra'), ('2026-12-25', 'Natal'),
  ('2027-01-01', 'Confraternização Universal'), ('2027-03-26', 'Sexta-feira Santa'),
  ('2027-04-21', 'Tiradentes'), ('2027-05-01', 'Dia do Trabalho'),
  ('2027-09-07', 'Independência'), ('2027-10-12', 'Nossa Senhora Aparecida'),
  ('2027-11-02', 'Finados'), ('2027-11-15', 'Proclamação da República'),
  ('2027-11-20', 'Dia Nacional de Zumbi e da Consciência Negra'), ('2027-12-25', 'Natal')
on conflict (day) do nothing;

create table if not exists public.security_incidents (
  id                         bigint generated always as identity primary key,
  code                       text not null unique,
  title                      text not null check (length(btrim(title)) between 5 and 200),
  status                     text not null default 'aberto' check (status in ('aberto', 'em_tratamento', 'encerrado')),
  known_at                   timestamptz not null,          -- I  data de conhecimento do incidente
  personal_data_known_at     timestamptz,                   --    conhecimento de que afetou dados pessoais (início dos prazos)
  occurred_at                timestamptz,
  description                text,                          -- II circunstâncias
  data_categories            text[] not null default '{}',  -- III categoria dos dados
  data_nature                text,                          -- III natureza dos dados
  sensitive_data             boolean,
  affected_count             integer check (affected_count is null or affected_count >= 0), -- IV
  affected_count_note        text,
  risk_criteria              text[] not null default '{}',  --    critérios do art. 5º
  risk_level                 text not null default 'a_avaliar'
                             check (risk_level in ('a_avaliar', 'sem_risco_relevante', 'risco_relevante')),
  risk_assessment            text,                          -- V  avaliação do risco e possíveis danos
  measures                   text,                          -- VI medidas de correção e mitigação
  anpd_communicated_at       timestamptz,                   -- VII
  anpd_protocol              text,
  titulares_communicated_at  timestamptz,
  communication_form         text,
  communication_content      text,
  no_communication_reason    text,                          -- VIII
  alert_id                   bigint references public.security_alerts (id),
  created_by                 uuid references public.profiles (id),
  created_at                 timestamptz not null default now(),
  updated_by                 uuid references public.profiles (id),
  updated_at                 timestamptz not null default now(),
  closed_by                  uuid references public.profiles (id),
  closed_at                  timestamptz,
  closing_note               text
);
create index if not exists security_incidents_status_idx on public.security_incidents (status, created_at desc);

create table if not exists public.security_incident_notes (
  id           bigint generated always as identity primary key,
  incident_id  bigint not null references public.security_incidents (id),
  kind         text not null default 'nota' check (kind in ('nota', 'alteracao', 'status')),
  body         text not null,
  created_by   uuid references public.profiles (id),
  created_at   timestamptz not null default now()
);
create index if not exists security_incident_notes_idx on public.security_incident_notes (incident_id, created_at);

do $$
declare t text;
begin
  foreach t in array array['privacy_settings', 'business_holidays', 'security_incidents', 'security_incident_notes'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
  end loop;
end $$;

-- Incidentes e o histórico deles nunca são apagados; o histórico não é alterado.
create or replace function public.tg_block_incident_delete()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  raise exception 'Registros de incidente não podem ser excluídos (guarda mínima de 5 anos).' using errcode = 'P0001';
end;
$$;
drop trigger if exists block_delete on public.security_incidents;
create trigger block_delete before delete on public.security_incidents
  for each row execute function public.tg_block_incident_delete();
drop trigger if exists block_change on public.security_incident_notes;
create trigger block_change before update or delete on public.security_incident_notes
  for each row execute function public.tg_block_incident_delete();

-- ---------------------------------------------------------------------
-- 2) Classificação dos novos eventos (incidente.* = crítico, guarda mínima de 5 anos)
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

-- ---------------------------------------------------------------------
-- 3) Dias úteis
-- ---------------------------------------------------------------------
create or replace function public.is_business_day(p_day date)
returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$
  select extract(isodow from p_day) < 6 and not exists (select 1 from public.business_holidays h where h.day = p_day);
$$;

-- Data em que termina o prazo de N dias úteis contados a partir do dia seguinte a p_from.
create or replace function public.business_days_add(p_from date, p_days integer)
returns date
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare
  d date := p_from;
  n integer := 0;
begin
  if p_from is null or p_days is null then
    return null;
  end if;
  while n < p_days loop
    d := d + 1;
    if public.is_business_day(d) then
      n := n + 1;
    end if;
  end loop;
  return d;
end;
$$;

-- Dias úteis de p_from (exclusive) até p_to (inclusive); negativo quando p_to já passou.
create or replace function public.business_days_between(p_from date, p_to date)
returns integer
language sql stable security definer
set search_path = public, pg_temp
as $$
  select case
    when p_from is null or p_to is null then null
    when p_to >= p_from then (select count(*)::int from generate_series(p_from + 1, p_to, interval '1 day') g where public.is_business_day(g::date))
    else -(select count(*)::int from generate_series(p_to + 1, p_from, interval '1 day') g where public.is_business_day(g::date))
  end;
$$;

-- ---------------------------------------------------------------------
-- 4) Prazos de um incidente
-- ---------------------------------------------------------------------
create or replace function public._incident_deadlines(i public.security_incidents)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare
  v_tz      text := coalesce((public.get_settings()).timezone, 'America/Recife');
  v_small   boolean := (select small_agent from public.privacy_settings where id);
  v_mult    integer := case when v_small then 2 else 1 end;
  v_today   date := (now() at time zone v_tz)::date;
  v_start   date := (i.personal_data_known_at at time zone v_tz)::date;
  v_applies boolean := i.personal_data_known_at is not null and i.risk_level <> 'sem_risco_relevante';
  v_anpd    date;
  v_tit     date;
  v_decl    date;
  v_compl   date;
  v_anpd_done date := (i.anpd_communicated_at at time zone v_tz)::date;
  v_tit_done  date := (i.titulares_communicated_at at time zone v_tz)::date;
begin
  if v_applies then
    v_anpd := public.business_days_add(v_start, 3 * v_mult);
    v_tit  := public.business_days_add(v_start, 3 * v_mult);
    v_decl := public.business_days_add(v_tit, 3);
  end if;
  if v_anpd_done is not null then
    v_compl := public.business_days_add(v_anpd_done, 20 * v_mult);
  end if;
  return jsonb_build_object(
    'aplica', v_applies,
    'motivo', case
      when i.personal_data_known_at is null then 'Informe quando se soube que o incidente afetou dados pessoais'
      when i.risk_level = 'sem_risco_relevante' then 'Avaliado como sem risco ou dano relevante: comunicação não obrigatória (registre o motivo)'
      when i.risk_level = 'a_avaliar' then 'Risco ainda não avaliado: os prazos já estão correndo'
    end,
    'pequeno_porte', v_small,
    'multiplicador', v_mult,
    'hoje', v_today,
    'anpd_prazo', v_anpd,
    'anpd_dias_restantes', case when v_applies and v_anpd_done is null then public.business_days_between(v_today, v_anpd) end,
    'anpd_situacao', case when not v_applies then null
                          when v_anpd_done is not null then case when v_anpd_done <= v_anpd then 'cumprido' else 'cumprido_com_atraso' end
                          when v_today > v_anpd then 'atrasado' else 'pendente' end,
    'titulares_prazo', v_tit,
    'titulares_dias_restantes', case when v_applies and v_tit_done is null then public.business_days_between(v_today, v_tit) end,
    'titulares_situacao', case when not v_applies then null
                               when v_tit_done is not null then case when v_tit_done <= v_tit then 'cumprido' else 'cumprido_com_atraso' end
                               when v_today > v_tit then 'atrasado' else 'pendente' end,
    'declaracao_prazo', v_decl,
    'complementacao_prazo', v_compl
  );
end;
$$;

create or replace function public._incident_view(i public.security_incidents)
returns jsonb
language sql stable security definer
set search_path = public, pg_temp
as $$
  select to_jsonb(i)
    || jsonb_build_object(
      'created_by_name', (select full_name from public.profiles where id = i.created_by),
      'updated_by_name', (select full_name from public.profiles where id = i.updated_by),
      'closed_by_name',  (select full_name from public.profiles where id = i.closed_by),
      'prazos', public._incident_deadlines(i));
$$;

-- ---------------------------------------------------------------------
-- 5) Configuração LGPD e feriados
-- ---------------------------------------------------------------------
create or replace function public.incident_overview()
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
begin
  if not public.is_admin() then
    raise exception 'Somente o administrador acessa os incidentes de segurança.' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'settings', (select to_jsonb(s) - 'id' || jsonb_build_object('updated_by_name', (select full_name from public.profiles where id = s.updated_by))
                   from public.privacy_settings s where s.id),
    'holidays', coalesce((select jsonb_agg(to_jsonb(h) - 'created_by' order by h.day) from public.business_holidays h
                           where h.day >= current_date - 31), '[]'),
    'incidents', coalesce((select jsonb_agg(public._incident_view(i) order by (i.status = 'encerrado'), i.created_at desc)
                            from public.security_incidents i), '[]'),
    'open_alerts', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'title', a.title, 'severity', a.severity, 'created_at', a.created_at) order by a.created_at desc)
                              from public.security_alerts a where a.status <> 'encerrado'), '[]'));
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
  select array_agg(key order by key) into v_changed
    from jsonb_each(to_jsonb(v_new)) n
   where key in ('controller_name', 'controller_doc', 'dpo_name', 'dpo_contact', 'small_agent')
     and n.value is distinct from to_jsonb(v_old) -> key;
  if v_changed is null then
    return;
  end if;
  update public.privacy_settings
     set controller_name = v_new.controller_name, controller_doc = v_new.controller_doc,
         dpo_name = v_new.dpo_name, dpo_contact = v_new.dpo_contact, small_agent = v_new.small_agent,
         updated_by = auth.uid(), updated_at = now()
   where id;
  -- Na trilha vão só os nomes dos campos (o nome do encarregado é dado pessoal)
  perform public.audit_event('privacidade.configuracao_alterada', 'privacy_settings', null, null, null, null,
    jsonb_build_object('campos', v_changed, 'pequeno_porte', v_new.small_agent));
end;
$$;

create or replace function public.holiday_add(p_day date, p_name text, p_scope text)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  if not public.is_admin() then
    raise exception 'Somente o administrador cadastra feriados.' using errcode = '42501';
  end if;
  if p_day is null or length(btrim(coalesce(p_name, ''))) < 2 then
    raise exception 'Informe a data e o nome do feriado.' using errcode = 'P0001';
  end if;
  if coalesce(p_scope, '') not in ('nacional', 'estadual', 'municipal', 'empresa') then
    raise exception 'Abrangência inválida.' using errcode = 'P0001';
  end if;
  insert into public.business_holidays (day, name, scope, created_by)
  values (p_day, btrim(left(p_name, 120)), p_scope, auth.uid())
  on conflict (day) do update set name = excluded.name, scope = excluded.scope;
  perform public.audit_event('privacidade.feriado_cadastrado', 'business_holidays', p_day::text, null, null, null,
    jsonb_build_object('data', p_day, 'nome', btrim(left(p_name, 120)), 'abrangencia', p_scope));
end;
$$;

create or replace function public.holiday_remove(p_day date)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v public.business_holidays;
begin
  if not public.is_admin() then
    raise exception 'Somente o administrador remove feriados.' using errcode = '42501';
  end if;
  delete from public.business_holidays where day = p_day returning * into v;
  if v.day is null then
    raise exception 'Feriado não encontrado.' using errcode = 'P0001';
  end if;
  perform public.audit_event('privacidade.feriado_removido', 'business_holidays', p_day::text, null, null,
    jsonb_build_object('data', v.day, 'nome', v.name, 'abrangencia', v.scope), null);
end;
$$;

-- ---------------------------------------------------------------------
-- 6) Incidentes
-- ---------------------------------------------------------------------
create or replace function public.incident_open(p jsonb)
returns bigint
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_tz    text := coalesce((public.get_settings()).timezone, 'America/Recife');
  v_title text := btrim(coalesce(p ->> 'title', ''));
  v_known timestamptz := coalesce((p ->> 'known_at')::timestamptz, now());
  v_alert bigint := nullif(p ->> 'alert_id', '')::bigint;
  v_year  integer;
  v_seq   integer;
  v_id    bigint;
  v_code  text;
begin
  if not public.is_admin() then
    raise exception 'Somente o administrador registra incidentes de segurança.' using errcode = '42501';
  end if;
  if length(v_title) not between 5 and 200 then
    raise exception 'Dê um título ao incidente (5 a 200 caracteres).' using errcode = 'P0001';
  end if;
  if v_known > now() + interval '5 minutes' then
    raise exception 'A data de conhecimento não pode estar no futuro.' using errcode = 'P0001';
  end if;
  if v_alert is not null and not exists (select 1 from public.security_alerts where id = v_alert) then
    raise exception 'Alerta não encontrado.' using errcode = 'P0001';
  end if;
  v_year := extract(year from (now() at time zone v_tz))::int;
  perform pg_advisory_xact_lock(704200124);
  select count(*) + 1 into v_seq from public.security_incidents where code like 'INC-' || v_year || '-%';
  v_code := 'INC-' || v_year || '-' || lpad(v_seq::text, 3, '0');

  insert into public.security_incidents (code, title, known_at, description, alert_id, created_by, updated_by)
  values (v_code, v_title, v_known, nullif(btrim(left(p ->> 'description', 5000)), ''), v_alert, auth.uid(), auth.uid())
  returning id into v_id;
  insert into public.security_incident_notes (incident_id, kind, body, created_by)
  values (v_id, 'status', 'Incidente registrado' || case when v_alert is not null then ' a partir do alerta nº ' || v_alert else '' end, auth.uid());

  -- O alerta de origem passa para "em análise"
  if v_alert is not null and exists (select 1 from public.security_alerts where id = v_alert and status = 'aberto') then
    update public.security_alerts set status = 'em_analise', handled_by = auth.uid(), handled_at = now(),
           resolution = coalesce(resolution, 'Tratado como incidente ' || v_code)
     where id = v_alert;
    perform public.audit_event('alerta.atualizado', 'security_alerts', v_alert::text, null, null, null,
      jsonb_build_object('status', 'em_analise', 'incidente', v_code));
  end if;

  perform public.audit_event('incidente.registrado', 'security_incidents', v_code, null, null, null,
    jsonb_build_object('codigo', v_code, 'conhecimento', v_known, 'alerta', v_alert));
  return v_id;
end;
$$;

create or replace function public.incident_get(p_id bigint)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare
  i public.security_incidents;
begin
  if not public.is_admin() then
    raise exception 'Somente o administrador acessa os incidentes de segurança.' using errcode = '42501';
  end if;
  select * into i from public.security_incidents where id = p_id;
  if i.id is null then
    raise exception 'Incidente não encontrado.' using errcode = 'P0001';
  end if;
  return public._incident_view(i) || jsonb_build_object('notes', coalesce((
    select jsonb_agg(jsonb_build_object('id', n.id, 'kind', n.kind, 'body', n.body, 'created_at', n.created_at,
                                        'created_by_name', (select full_name from public.profiles where id = n.created_by)) order by n.created_at, n.id)
      from public.security_incident_notes n where n.incident_id = p_id), '[]'));
end;
$$;

create or replace function public.incident_update(p_id bigint, p jsonb)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_old     public.security_incidents;
  v_new     public.security_incidents;
  v_allowed text[] := array['title', 'status', 'known_at', 'personal_data_known_at', 'occurred_at', 'description',
                             'data_categories', 'data_nature', 'sensitive_data', 'affected_count', 'affected_count_note',
                             'risk_criteria', 'risk_level', 'risk_assessment', 'measures', 'anpd_communicated_at',
                             'anpd_protocol', 'titulares_communicated_at', 'communication_form', 'communication_content',
                             'no_communication_reason'];
  v_texts   text[] := array['title', 'description', 'data_nature', 'affected_count_note', 'risk_assessment', 'measures',
                             'anpd_protocol', 'communication_form', 'communication_content', 'no_communication_reason'];
  v_clean   jsonb := '{}';
  v_changed text[];
  k         text;
  v         jsonb;
  c         text;
  v_limit   timestamptz := now() + interval '5 minutes';
begin
  if not public.is_admin() then
    raise exception 'Somente o administrador altera incidentes de segurança.' using errcode = '42501';
  end if;
  select * into v_old from public.security_incidents where id = p_id for update;
  if v_old.id is null then
    raise exception 'Incidente não encontrado.' using errcode = 'P0001';
  end if;
  if v_old.status = 'encerrado' then
    raise exception 'Incidente encerrado não pode ser alterado; acrescente uma anotação.' using errcode = 'P0001';
  end if;

  for k, v in select * from jsonb_each(coalesce(p, '{}')) loop
    if not (k = any (v_allowed)) then
      raise exception 'Campo não permitido: %', k using errcode = 'P0001';
    end if;
    if jsonb_typeof(v) = 'string' and btrim(v #>> '{}') = '' then
      v := 'null'::jsonb;
    elsif k = any (v_texts) and jsonb_typeof(v) = 'string' then
      v := to_jsonb(btrim(v #>> '{}'));
    end if;
    v_clean := v_clean || jsonb_build_object(k, v);
  end loop;
  v_new := jsonb_populate_record(v_old, v_clean);

  -- Validações
  if length(btrim(coalesce(v_new.title, ''))) not between 5 and 200 then
    raise exception 'Título com 5 a 200 caracteres.' using errcode = 'P0001';
  end if;
  if v_new.status not in ('aberto', 'em_tratamento') then
    raise exception 'Para encerrar, use o botão Encerrar incidente.' using errcode = 'P0001';
  end if;
  if v_new.risk_level not in ('a_avaliar', 'sem_risco_relevante', 'risco_relevante') then
    raise exception 'Nível de risco inválido.' using errcode = 'P0001';
  end if;
  if v_new.known_at is null or greatest(v_new.known_at, coalesce(v_new.personal_data_known_at, v_new.known_at), coalesce(v_new.occurred_at, v_new.known_at),
              coalesce(v_new.anpd_communicated_at, v_new.known_at), coalesce(v_new.titulares_communicated_at, v_new.known_at)) > v_limit then
    raise exception 'As datas não podem estar no futuro.' using errcode = 'P0001';
  end if;
  if v_new.personal_data_known_at < v_new.known_at then
    raise exception 'O conhecimento de que afetou dados pessoais não pode ser anterior ao conhecimento do incidente.' using errcode = 'P0001';
  end if;
  if v_new.occurred_at > v_new.known_at then
    raise exception 'A data de ocorrência não pode ser posterior à de conhecimento.' using errcode = 'P0001';
  end if;
  if (v_new.anpd_communicated_at is not null or v_new.titulares_communicated_at is not null) and v_new.personal_data_known_at is null then
    raise exception 'Informe quando se soube que o incidente afetou dados pessoais antes de registrar comunicações.' using errcode = 'P0001';
  end if;
  if coalesce(array_length(v_new.data_categories, 1), 0) > 20
     or exists (select 1 from unnest(v_new.data_categories) x where length(btrim(x)) not between 1 and 80) then
    raise exception 'Categorias de dados: até 20, com até 80 caracteres cada.' using errcode = 'P0001';
  end if;
  v_new.data_categories := array(select distinct btrim(x) from unnest(v_new.data_categories) x order by 1);
  if exists (select 1 from unnest(v_new.risk_criteria) x
              where x not in ('dados_sensiveis', 'vulneraveis', 'dados_financeiros', 'autenticacao', 'sigilo', 'larga_escala')) then
    raise exception 'Critério de risco inválido.' using errcode = 'P0001';
  end if;
  v_new.risk_criteria := array(select distinct x from unnest(v_new.risk_criteria) x order by 1);
  foreach c in array v_texts loop
    if length(coalesce(to_jsonb(v_new) ->> c, '')) > 5000 then
      raise exception 'Texto longo demais (máximo de 5000 caracteres).' using errcode = 'P0001';
    end if;
  end loop;

  select array_agg(n.key order by n.key) into v_changed
    from jsonb_each(to_jsonb(v_new)) n
   where n.key = any (v_allowed) and n.value is distinct from to_jsonb(v_old) -> n.key;
  if v_changed is null then
    return public._incident_view(v_old);
  end if;

  update public.security_incidents set
    title = v_new.title, status = v_new.status, known_at = v_new.known_at, personal_data_known_at = v_new.personal_data_known_at,
    occurred_at = v_new.occurred_at, description = v_new.description, data_categories = v_new.data_categories,
    data_nature = v_new.data_nature, sensitive_data = v_new.sensitive_data, affected_count = v_new.affected_count,
    affected_count_note = v_new.affected_count_note, risk_criteria = v_new.risk_criteria, risk_level = v_new.risk_level,
    risk_assessment = v_new.risk_assessment, measures = v_new.measures, anpd_communicated_at = v_new.anpd_communicated_at,
    anpd_protocol = v_new.anpd_protocol, titulares_communicated_at = v_new.titulares_communicated_at,
    communication_form = v_new.communication_form, communication_content = v_new.communication_content,
    no_communication_reason = v_new.no_communication_reason, updated_by = auth.uid(), updated_at = now()
  where id = p_id
  returning * into v_new;

  insert into public.security_incident_notes (incident_id, kind, body, created_by)
  values (p_id, case when 'status' = any (v_changed) then 'status' else 'alteracao' end,
          'Campos alterados: ' || (select string_agg(coalesce(('{"title":"título","status":"situação","known_at":"conhecimento do incidente",
             "personal_data_known_at":"conhecimento de dados pessoais afetados","occurred_at":"data de ocorrência","description":"circunstâncias",
             "data_categories":"categorias de dados","data_nature":"natureza dos dados","sensitive_data":"dado sensível",
             "affected_count":"número de titulares","affected_count_note":"observação sobre titulares","risk_criteria":"critérios de risco",
             "risk_level":"conclusão do risco","risk_assessment":"avaliação do risco","measures":"medidas","anpd_communicated_at":"comunicação à ANPD",
             "anpd_protocol":"protocolo da ANPD","titulares_communicated_at":"comunicação aos titulares","communication_form":"forma da comunicação",
             "communication_content":"conteúdo da comunicação","no_communication_reason":"motivo da ausência de comunicação"}'::jsonb ->> fld), fld), ', ')
             from unnest(v_changed) fld)
          || case when 'status' = any (v_changed) then ' (agora: ' || replace(v_new.status, '_', ' ') || ')' else '' end, auth.uid());
  -- Na trilha: só os nomes dos campos e os marcos (o texto do incidente pode conter dados pessoais)
  perform public.audit_event('incidente.atualizado', 'security_incidents', v_new.code, null, null, null,
    jsonb_build_object('campos', v_changed, 'situacao', v_new.status, 'risco', v_new.risk_level,
                       'comunicado_anpd', v_new.anpd_communicated_at, 'comunicado_titulares', v_new.titulares_communicated_at));
  return public._incident_view(v_new);
end;
$$;

create or replace function public.incident_add_note(p_id bigint, p_body text)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_code text;
begin
  if not public.is_admin() then
    raise exception 'Somente o administrador anota incidentes.' using errcode = '42501';
  end if;
  select code into v_code from public.security_incidents where id = p_id;
  if v_code is null then
    raise exception 'Incidente não encontrado.' using errcode = 'P0001';
  end if;
  if length(btrim(coalesce(p_body, ''))) not between 3 and 5000 then
    raise exception 'Escreva a anotação (3 a 5000 caracteres).' using errcode = 'P0001';
  end if;
  insert into public.security_incident_notes (incident_id, kind, body, created_by) values (p_id, 'nota', btrim(p_body), auth.uid());
  perform public.audit_event('incidente.anotado', 'security_incidents', v_code, null, null, null, jsonb_build_object('codigo', v_code));
end;
$$;

create or replace function public.incident_close(p_id bigint, p_note text)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  i public.security_incidents;
  v_missing text[] := '{}';
begin
  if not public.is_admin() then
    raise exception 'Somente o administrador encerra incidentes.' using errcode = '42501';
  end if;
  select * into i from public.security_incidents where id = p_id for update;
  if i.id is null then
    raise exception 'Incidente não encontrado.' using errcode = 'P0001';
  end if;
  if i.status = 'encerrado' then
    raise exception 'Incidente já encerrado.' using errcode = 'P0001';
  end if;
  if length(btrim(coalesce(p_note, ''))) < 10 then
    raise exception 'Descreva o encerramento (mínimo de 10 caracteres).' using errcode = 'P0001';
  end if;
  -- Campos mínimos do art. 10, § 1º, da Res. CD/ANPD 15/2024
  if i.description is null then v_missing := array_append(v_missing, 'descrição das circunstâncias (II)'); end if;
  if coalesce(array_length(i.data_categories, 1), 0) = 0 and i.data_nature is null then
    v_missing := array_append(v_missing, 'natureza e categoria dos dados (III)');
  end if;
  if i.affected_count is null and i.affected_count_note is null then v_missing := array_append(v_missing, 'número de titulares (IV)'); end if;
  if i.risk_level = 'a_avaliar' or i.risk_assessment is null then v_missing := array_append(v_missing, 'avaliação do risco (V)'); end if;
  if i.risk_level = 'risco_relevante' then
    if i.personal_data_known_at is null then v_missing := array_append(v_missing, 'data em que se soube que afetou dados pessoais'); end if;
    if i.anpd_communicated_at is null then v_missing := array_append(v_missing, 'data da comunicação à ANPD (VII)'); end if;
    if i.titulares_communicated_at is null then v_missing := array_append(v_missing, 'data da comunicação aos titulares (VII)'); end if;
    if i.communication_form is null then v_missing := array_append(v_missing, 'forma da comunicação (VII)'); end if;
  elsif i.risk_level = 'sem_risco_relevante' and coalesce(length(i.no_communication_reason), 0) < 10 then
    v_missing := array_append(v_missing, 'motivo da ausência de comunicação (VIII)');
  end if;
  if cardinality(v_missing) > 0 then
    raise exception 'Para encerrar, preencha: %.', array_to_string(v_missing, '; ') using errcode = 'P0001';
  end if;

  update public.security_incidents
     set status = 'encerrado', closed_by = auth.uid(), closed_at = now(), closing_note = btrim(left(p_note, 2000)),
         updated_by = auth.uid(), updated_at = now()
   where id = p_id;
  insert into public.security_incident_notes (incident_id, kind, body, created_by)
  values (p_id, 'status', 'Incidente encerrado: ' || btrim(left(p_note, 2000)), auth.uid());
  perform public.audit_event('incidente.encerrado', 'security_incidents', i.code, null, null, null,
    jsonb_build_object('codigo', i.code, 'risco', i.risk_level, 'prazos', public._incident_deadlines(i)));
end;
$$;

-- ---------------------------------------------------------------------
-- Verificações periódicas: inclui os prazos dos incidentes
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

  insert into public.security_state (key, value, updated_at)
  values ('last_checks', jsonb_build_object('at', now(), 'integridade', v_chain -> 'ok', 'importados_auth', v_imp, 'alertas', v_alerts), now())
  on conflict (key) do update set value = excluded.value, updated_at = now();

  return jsonb_build_object('integridade', v_chain, 'importados_auth', v_imp, 'alertas', v_alerts, 'at', now());
end;
$$;

-- ---------------------------------------------------------------------
-- 7) Permissões
-- ---------------------------------------------------------------------
revoke all on function public.tg_block_incident_delete() from public, anon, authenticated;
revoke all on function public._incident_deadlines(public.security_incidents) from public, anon, authenticated;
revoke all on function public._incident_view(public.security_incidents) from public, anon, authenticated;
revoke all on function public._security_checks() from public, anon, authenticated;
do $$
declare f text;
begin
  foreach f in array array['is_business_day(date)', 'business_days_add(date, integer)', 'business_days_between(date, date)',
                           'incident_overview()', 'privacy_settings_update(jsonb)', 'holiday_add(date, text, text)',
                           'holiday_remove(date)', 'incident_open(jsonb)', 'incident_get(bigint)', 'incident_update(bigint, jsonb)',
                           'incident_add_note(bigint, text)', 'incident_close(bigint, text)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
