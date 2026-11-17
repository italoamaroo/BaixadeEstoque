-- =====================================================================
-- 07e (= migração 22) - AUDITORIA: BASE SEGURA (fase 1 do plano de auditoria e LGPD)
--
-- * audit_event: interface única de registro (write_audit vira apelido).
--   Mascara dados pessoais, remove segredos, limpa caracteres de controle,
--   classifica (categoria, criticidade, tipo de ator) e grava na MESMA
--   transação da operação (se a auditoria falhar, a operação falha junto).
-- * Encadeamento de hash SHA-256 (chain_seq + prev_hash + row_hash),
--   verificação de integridade e âncora para guardar FORA do Supabase.
-- * Consulta da auditoria somente por função do servidor (search_audit,
--   movement_audit, export_audit), com limites e evento próprio.
--   Gestor não vê IP, navegador nem e-mail.
-- * Exportação de MEs registrada no servidor (exportacao.dados).
-- * IP e navegador só são guardados em eventos de autenticação/autorização.
--
-- Os registros antigos NÃO são alterados no conteúdo: só recebem o hash
-- (para entrar no encadeamento). Pré-requisito: 01 a 21. Pode ser reexecutado.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) Novas colunas (aditivas)
-- ---------------------------------------------------------------------
alter table public.audit_logs add column if not exists event_id       uuid not null default gen_random_uuid();
alter table public.audit_logs add column if not exists schema_version smallint not null default 1;
alter table public.audit_logs add column if not exists category       text;
alter table public.audit_logs add column if not exists actor_type     text;
alter table public.audit_logs add column if not exists result         text not null default 'sucesso';
alter table public.audit_logs add column if not exists reason_code    text;
alter table public.audit_logs add column if not exists severity       text;
alter table public.audit_logs add column if not exists correlation_id uuid;
alter table public.audit_logs add column if not exists chain_seq      bigint;
alter table public.audit_logs add column if not exists prev_hash      text;
alter table public.audit_logs add column if not exists row_hash       text;

alter table public.audit_logs alter column schema_version set default 2;

alter table public.audit_logs drop constraint if exists audit_logs_result_ck;
alter table public.audit_logs add constraint audit_logs_result_ck check (result in ('sucesso', 'falha', 'negado'));
alter table public.audit_logs drop constraint if exists audit_logs_severity_ck;
alter table public.audit_logs add constraint audit_logs_severity_ck check (severity is null or severity in ('info', 'aviso', 'critico'));

create unique index if not exists audit_logs_event_uk on public.audit_logs (event_id);
create unique index if not exists audit_logs_chain_uk on public.audit_logs (chain_seq);
create index if not exists audit_logs_category_idx on public.audit_logs (category, occurred_at desc);
create index if not exists audit_logs_correlation_idx on public.audit_logs (correlation_id) where correlation_id is not null;

-- Âncoras (histórico; a cópia que vale como prova fica FORA do Supabase)
create table if not exists public.audit_anchors (
  id          bigint generated always as identity primary key,
  created_at  timestamptz not null default now(),
  created_by  uuid references public.profiles (id),
  chain_seq   bigint not null,
  row_hash    text not null,
  checked     bigint not null
);
alter table public.audit_anchors enable row level security;
revoke all on public.audit_anchors from anon, authenticated;

-- ---------------------------------------------------------------------
-- 2) Funções auxiliares: limpeza, máscara, classificação, hash
-- ---------------------------------------------------------------------

-- Remove caracteres de controle (proteção contra injeção em logs) e limita o tamanho
create or replace function public.audit_clean_text(p text, p_max int default 2000)
returns text
language sql immutable
set search_path = public, pg_temp
as $$
  select case when p is null then null
              else left(regexp_replace(p, '[[:cntrl:]]', ' ', 'g'), p_max) end;
$$;

create or replace function public.audit_mask_registration(p text)
returns text
language sql immutable
set search_path = public, pg_temp
as $$
  select case when p is null or btrim(p) = '' then p
              when length(btrim(p)) <= 2 then '**'
              else repeat('*', 4) || right(btrim(p), 2) end;
$$;

create or replace function public.audit_mask_email(p text)
returns text
language sql immutable
set search_path = public, pg_temp
as $$
  select case when p is null or position('@' in p) = 0 then p
              else left(p, 1) || '***@' || split_part(p, '@', 2) end;
$$;

-- Minimização: segredos nunca; nomes e matrículas mascarados (o id continua no evento)
create or replace function public.audit_mask(p_entity text, p_data jsonb)
returns jsonb
language plpgsql immutable
set search_path = public, pg_temp
as $$
declare
  v    jsonb := p_data;
  k    text;
begin
  if v is null or jsonb_typeof(v) <> 'object' then
    return v;
  end if;

  -- segredos e credenciais: removidos em qualquer entidade
  for k in select key from jsonb_object_keys(v) as t(key) loop
    if lower(k) ~ '(password|senha|token|secret|authorization|api_?key|service_role|cookie|jwt)' then
      v := jsonb_set(v, array[k], to_jsonb('[removido]'::text));
    end if;
  end loop;

  -- nomes de pessoas: omitidos (o id da pessoa continua no evento)
  foreach k in array array['full_name', 'requester_name', 'received_by_name', 'signer_name'] loop
    if v ? k and jsonb_typeof(v -> k) = 'string' then
      v := jsonb_set(v, array[k], to_jsonb('[omitido]'::text));
    end if;
  end loop;

  -- matrículas: mascaradas
  foreach k in array array['registration', 'requester_registration', 'received_by_registration', 'signer_registration'] loop
    if v ? k and jsonb_typeof(v -> k) = 'string' then
      v := jsonb_set(v, array[k], to_jsonb(public.audit_mask_registration(v ->> k)));
    end if;
  end loop;

  -- e-mail de usuário
  if v ? 'email' and jsonb_typeof(v -> 'email') = 'string' then
    v := jsonb_set(v, array['email'], to_jsonb(public.audit_mask_email(v ->> 'email')));
  end if;

  return v;
end;
$$;

-- Categoria e criticidade de cada evento
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

-- Hash de uma linha: SHA-256 do hash anterior + conteúdo canônico (jsonb ordena as chaves)
create or replace function public.audit_row_hash(p_prev text, r public.audit_logs)
returns text
language sql immutable
set search_path = public, pg_temp
as $$
  select encode(sha256(convert_to(coalesce(p_prev, '') || '|' || jsonb_build_object(
    'seq', r.chain_seq, 'id', r.id, 'event_id', r.event_id,
    'at', to_char(r.occurred_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
    'user_id', r.user_id, 'user_email', r.user_email, 'action', r.action, 'entity', r.entity,
    'entity_id', r.entity_id, 'movement_id', r.movement_id, 'warehouse_id', r.warehouse_id,
    'old', r.old_data, 'new', r.new_data, 'justification', r.justification, 'source', r.source,
    'ip', r.ip_address, 'ua', r.user_agent, 'v', r.schema_version, 'category', r.category,
    'actor', r.actor_type, 'result', r.result, 'reason', r.reason_code, 'severity', r.severity,
    'correlation', r.correlation_id
  )::text, 'UTF8')), 'hex');
$$;

-- Encadeamento: cada evento novo aponta para o hash do anterior (ordem garantida por trava)
create or replace function public.tg_audit_chain()
returns trigger
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_prev public.audit_logs;
begin
  perform pg_advisory_xact_lock(704200122);
  select * into v_prev from public.audit_logs where chain_seq is not null order by chain_seq desc limit 1;
  new.chain_seq := coalesce(v_prev.chain_seq, 0) + 1;
  new.prev_hash := coalesce(v_prev.row_hash, repeat('0', 64));
  new.row_hash  := public.audit_row_hash(new.prev_hash, new);
  return new;
end;
$$;

-- ---------------------------------------------------------------------
-- 3) Registros antigos: entram no encadeamento (conteúdo preservado)
-- ---------------------------------------------------------------------
do $$
declare
  r      public.audit_logs;
  v_prev text;
  v_seq  bigint;
begin
  if exists (select 1 from public.audit_logs where chain_seq is null) then
    alter table public.audit_logs disable trigger block_change;
    select chain_seq, row_hash into v_seq, v_prev from public.audit_logs
     where chain_seq is not null order by chain_seq desc limit 1;
    v_seq := coalesce(v_seq, 0);
    v_prev := coalesce(v_prev, repeat('0', 64));
    for r in select * from public.audit_logs where chain_seq is null order by id loop
      v_seq := v_seq + 1;
      r.chain_seq := v_seq;
      r.prev_hash := v_prev;
      r.row_hash := public.audit_row_hash(v_prev, r);
      update public.audit_logs set chain_seq = r.chain_seq, prev_hash = r.prev_hash, row_hash = r.row_hash where id = r.id;
      v_prev := r.row_hash;
    end loop;
    alter table public.audit_logs enable trigger block_change;
  end if;
end $$;

drop trigger if exists audit_chain on public.audit_logs;
create trigger audit_chain before insert on public.audit_logs
  for each row execute function public.tg_audit_chain();

-- ---------------------------------------------------------------------
-- 4) Interface única de registro
-- ---------------------------------------------------------------------
create or replace function public.audit_event(
  p_action        text,
  p_entity        text,
  p_entity_id     text,
  p_movement_id   uuid,
  p_warehouse_id  uuid,
  p_old           jsonb,
  p_new           jsonb,
  p_justification text default null,
  p_result        text default 'sucesso',
  p_reason_code   text default null
)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_uid    uuid := auth.uid();
  v_cls    record;
  v_actor  text;
  v_corr   uuid;
  v_hdr    text := public.request_header('x-correlation-id');
  v_net    boolean;
begin
  select * into v_cls from public.audit_classify(p_action, p_entity);
  v_actor := case
    when v_uid is null then 'sistema'
    when public.is_admin() then 'administrador'
    when public.has_role('terminal') and not public.has_any_role(array['almoxarife', 'equipe_sa', 'gestor']::public.app_role[]) then 'terminal'
    else 'usuario' end;
  -- Correlação: todos os eventos da mesma operação (transação) recebem o mesmo id.
  -- Um cabeçalho x-correlation-id válido, quando enviado por integração, tem prioridade.
  if v_hdr ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    v_corr := v_hdr::uuid;
  else
    v_corr := nullif(current_setting('app.correlation_id', true), '')::uuid;
    if v_corr is null then
      v_corr := gen_random_uuid();
      perform set_config('app.correlation_id', v_corr::text, true);
    end if;
  end if;
  -- IP e navegador só onde há finalidade de segurança
  v_net := v_cls.category in ('autenticacao', 'autorizacao') or coalesce(p_result, 'sucesso') <> 'sucesso';

  insert into public.audit_logs (
    user_id, user_email, action, entity, entity_id, movement_id, warehouse_id,
    old_data, new_data, justification, source, ip_address, user_agent,
    schema_version, category, actor_type, result, reason_code, severity, correlation_id
  ) values (
    v_uid, null, public.audit_clean_text(p_action, 80), public.audit_clean_text(p_entity, 80),
    public.audit_clean_text(p_entity_id, 200), p_movement_id, p_warehouse_id,
    public.audit_mask(p_entity, p_old), public.audit_mask(p_entity, p_new),
    public.audit_clean_text(coalesce(p_justification, nullif(current_setting('app.justification', true), '')), 2000),
    coalesce(nullif(current_setting('app.source', true), ''), case when v_uid is null then 'sistema' else 'app' end),
    case when v_net then nullif(split_part(coalesce(public.request_header('x-forwarded-for'), public.request_header('x-real-ip'), ''), ',', 1), '') end,
    case when v_net then public.audit_clean_text(public.request_header('user-agent'), 300) end,
    2, v_cls.category, v_actor, coalesce(p_result, 'sucesso'), public.audit_clean_text(p_reason_code, 80),
    case when coalesce(p_result, 'sucesso') <> 'sucesso' and v_cls.severity = 'info' then 'aviso' else v_cls.severity end,
    v_corr
  );
end;
$$;

-- Compatibilidade: todos os pontos que já chamam write_audit passam pela interface única
create or replace function public.write_audit(
  p_action        text,
  p_entity        text,
  p_entity_id     text,
  p_movement_id   uuid,
  p_warehouse_id  uuid,
  p_old           jsonb,
  p_new           jsonb,
  p_justification text default null
)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  perform public.audit_event(p_action, p_entity, p_entity_id, p_movement_id, p_warehouse_id, p_old, p_new, p_justification);
end;
$$;

revoke all on function public.audit_event(text, text, text, uuid, uuid, jsonb, jsonb, text, text, text) from public, anon, authenticated;
revoke all on function public.write_audit(text, text, text, uuid, uuid, jsonb, jsonb, text) from public, anon, authenticated;
revoke all on function public.audit_row_hash(text, public.audit_logs) from public, anon, authenticated;
revoke all on function public.tg_audit_chain() from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 5) Integridade: verificação e âncora
-- ---------------------------------------------------------------------
create or replace function public._audit_verify(p_upto bigint default null)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare
  r        public.audit_logs;
  v_prev   text := repeat('0', 64);
  v_seq    bigint := 0;
  v_n      bigint := 0;
  v_issue  text;
  v_bad    bigint;
begin
  for r in select * from public.audit_logs
            where p_upto is null or chain_seq <= p_upto
            order by chain_seq loop
    v_n := v_n + 1;
    if r.chain_seq is null then
      v_issue := 'sem_hash'; v_bad := r.id; exit;
    elsif r.chain_seq <> v_seq + 1 then
      v_issue := 'evento_removido'; v_bad := v_seq + 1; exit;
    elsif r.prev_hash is distinct from v_prev then
      v_issue := 'encadeamento_quebrado'; v_bad := r.chain_seq; exit;
    elsif r.row_hash is distinct from public.audit_row_hash(r.prev_hash, r) then
      v_issue := 'conteudo_alterado'; v_bad := r.chain_seq; exit;
    end if;
    v_seq := r.chain_seq;
    v_prev := r.row_hash;
  end loop;
  return jsonb_build_object('ok', v_issue is null, 'checked', v_n, 'last_seq', v_seq, 'last_hash', v_prev,
                            'problem', v_issue, 'problem_seq', v_bad);
end;
$$;
revoke all on function public._audit_verify(bigint) from public, anon, authenticated;

create or replace function public.audit_verify_chain()
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v jsonb;
begin
  if not public.is_admin() then
    raise exception 'Somente o administrador verifica a integridade da auditoria.' using errcode = '42501';
  end if;
  v := public._audit_verify(null);
  perform public.audit_event('auditoria.integridade_verificada', 'audit_logs', null, null, null, null,
    jsonb_build_object('verificados', v -> 'checked', 'ultimo', v -> 'last_seq', 'problema', v -> 'problem', 'em', v -> 'problem_seq'),
    null, case when (v ->> 'ok')::boolean then 'sucesso' else 'falha' end, v ->> 'problem');
  return v;
end;
$$;

create or replace function public.audit_create_anchor()
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v jsonb;
begin
  if not public.is_admin() then
    raise exception 'Somente o administrador gera a âncora da auditoria.' using errcode = '42501';
  end if;
  v := public._audit_verify(null);
  if not (v ->> 'ok')::boolean then
    perform public.audit_event('auditoria.ancora_gerada', 'audit_logs', null, null, null, null, v, null, 'falha', v ->> 'problem');
    return v;
  end if;
  insert into public.audit_anchors (created_by, chain_seq, row_hash, checked)
  values (auth.uid(), (v ->> 'last_seq')::bigint, v ->> 'last_hash', (v ->> 'checked')::bigint);
  perform public.audit_event('auditoria.ancora_gerada', 'audit_logs', v ->> 'last_seq', null, null, null,
    jsonb_build_object('sequencia', v -> 'last_seq', 'hash', v -> 'last_hash'));
  return v || jsonb_build_object('generated_at', now());
end;
$$;

-- Confere uma âncora guardada fora do Supabase: o evento daquela sequência ainda tem o mesmo hash
-- e o encadeamento até ele está íntegro.
create or replace function public.audit_check_anchor(p_seq bigint, p_hash text)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v       jsonb;
  v_ok    boolean;
  v_issue text;
begin
  if not public.is_admin() then
    raise exception 'Somente o administrador confere a âncora da auditoria.' using errcode = '42501';
  end if;
  if p_seq is null or p_seq < 1 or p_hash !~ '^[0-9a-f]{64}$' then
    raise exception 'Âncora inválida: informe a sequência e o hash de 64 caracteres.' using errcode = '22023';
  end if;
  v := public._audit_verify(p_seq);
  if not (v ->> 'ok')::boolean then
    v_ok := false; v_issue := v ->> 'problem';
  elsif (v ->> 'last_seq')::bigint <> p_seq then
    v_ok := false; v_issue := 'evento_removido';
  elsif v ->> 'last_hash' <> lower(p_hash) then
    v_ok := false; v_issue := 'hash_diferente_da_ancora';
  else
    v_ok := true;
  end if;
  perform public.audit_event('auditoria.ancora_conferida', 'audit_logs', p_seq::text, null, null, null,
    jsonb_build_object('sequencia', p_seq, 'confere', v_ok, 'problema', v_issue), null,
    case when v_ok then 'sucesso' else 'falha' end, v_issue);
  return jsonb_build_object('ok', v_ok, 'problem', v_issue, 'checked', v -> 'checked', 'problem_seq', v -> 'problem_seq');
end;
$$;

-- ---------------------------------------------------------------------
-- 6) Consulta e exportação da auditoria (somente por função)
-- ---------------------------------------------------------------------
create or replace function public._audit_rows(p_filters jsonb, p_admin boolean)
returns setof public.audit_logs
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare
  f      jsonb := coalesce(p_filters, '{}'::jsonb);
  v_tz   text := (public.get_settings()).timezone;
  v_from date;
  v_to   date;
  v_q    text;
begin
  begin
    v_to := coalesce(nullif(f ->> 'date_to', '')::date, (now() at time zone v_tz)::date);
    v_from := coalesce(nullif(f ->> 'date_from', '')::date, v_to - 30);
  exception when others then
    raise exception 'Período inválido.' using errcode = '22023';
  end;
  if v_from > v_to then
    raise exception 'A data inicial é maior que a final.' using errcode = '22023';
  end if;
  if v_to - v_from > 366 then
    raise exception 'Consulte no máximo 366 dias por vez.' using errcode = '22023';
  end if;
  v_q := nullif(btrim(coalesce(f ->> 'q', '')), '');
  if v_q is not null then
    v_q := '%' || replace(replace(replace(left(v_q, 100), '\', '\\'), '%', '\%'), '_', '\_') || '%';
  end if;

  return query
    select a.* from public.audit_logs a
     where a.occurred_at >= (v_from::timestamp at time zone v_tz)
       and a.occurred_at <  ((v_to + 1)::timestamp at time zone v_tz)
       and (p_admin or (a.warehouse_id is not null and public.can_access_warehouse(a.warehouse_id)))
       and (nullif(f ->> 'action', '') is null or a.action like replace(replace(f ->> 'action', '%', ''), '_', '\_') || '%')
       and (nullif(f ->> 'entity', '') is null or a.entity = f ->> 'entity')
       and (nullif(f ->> 'category', '') is null or a.category = f ->> 'category')
       and (nullif(f ->> 'result', '') is null or a.result = f ->> 'result')
       and (nullif(f ->> 'severity', '') is null or a.severity = f ->> 'severity')
       and (nullif(f ->> 'user_id', '') is null or a.user_id::text = f ->> 'user_id')
       and (nullif(f ->> 'movement_id', '') is null or a.movement_id::text = f ->> 'movement_id')
       and (nullif(f ->> 'correlation_id', '') is null or a.correlation_id::text = f ->> 'correlation_id')
       and (v_q is null or a.entity_id ilike v_q or a.justification ilike v_q or a.action ilike v_q);
end;
$$;
revoke all on function public._audit_rows(jsonb, boolean) from public, anon, authenticated;

-- Linha para a tela: gestor não recebe IP, navegador nem e-mail
create or replace function public._audit_public(a public.audit_logs, p_admin boolean)
returns jsonb
language sql stable security definer
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'id', a.id, 'event_id', a.event_id, 'occurred_at', a.occurred_at, 'user_id', a.user_id,
    'user_name', (select p.full_name from public.profiles p where p.id = a.user_id),
    'user_email', case when p_admin then a.user_email end,
    'action', a.action, 'entity', a.entity, 'entity_id', a.entity_id, 'movement_id', a.movement_id,
    'warehouse_id', a.warehouse_id, 'old_data', a.old_data, 'new_data', a.new_data,
    'justification', a.justification, 'source', a.source,
    'ip_address', case when p_admin then a.ip_address end,
    'user_agent', case when p_admin then a.user_agent end,
    'category', a.category, 'actor_type', a.actor_type, 'result', a.result, 'reason_code', a.reason_code,
    'severity', a.severity, 'correlation_id', a.correlation_id, 'chain_seq', a.chain_seq);
$$;
revoke all on function public._audit_public(public.audit_logs, boolean) from public, anon, authenticated;

create or replace function public.search_audit(p_filters jsonb default '{}'::jsonb, p_page int default 1, p_page_size int default 50)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_admin boolean := public.is_admin();
  v_size  int := least(greatest(coalesce(p_page_size, 50), 1), 100);
  v_page  int := least(greatest(coalesce(p_page, 1), 1), 1000);
  v_total bigint;
  v_rows  jsonb;
begin
  if not public.is_active_user() or not (v_admin or public.has_role('gestor')) then
    raise exception 'Seu perfil não permite consultar a auditoria.' using errcode = '42501';
  end if;
  select count(*) into v_total from public._audit_rows(p_filters, v_admin);
  select coalesce(jsonb_agg(public._audit_public(s.x, v_admin) order by (s.x).occurred_at desc, (s.x).id desc), '[]'::jsonb)
    into v_rows
    from (select x from public._audit_rows(p_filters, v_admin) x
           order by x.occurred_at desc, x.id desc
           offset (v_page - 1) * v_size limit v_size) s;
  if v_page = 1 then
    perform public.audit_event('auditoria.consultada', 'audit_logs', null, null, null, null,
      jsonb_build_object('filtros', coalesce(p_filters, '{}'::jsonb), 'resultados', v_total));
  end if;
  return jsonb_build_object('rows', v_rows, 'total', v_total, 'page', v_page, 'page_size', v_size);
end;
$$;

-- Histórico de uma ME (tela de detalhe). Quem não é gestor/admin recebe lista vazia.
create or replace function public.movement_audit(p_movement_id uuid)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare
  v_admin boolean := public.is_admin();
begin
  if not public.is_active_user() or not (v_admin or public.has_role('gestor')) or not public.can_access_movement(p_movement_id) then
    return '[]'::jsonb;
  end if;
  return coalesce((select jsonb_agg(public._audit_public(a, v_admin) order by a.occurred_at, a.id)
                     from public.audit_logs a where a.movement_id = p_movement_id), '[]'::jsonb);
end;
$$;

create or replace function public.export_audit(p_filters jsonb, p_reason text)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_reason text := public.audit_clean_text(btrim(coalesce(p_reason, '')), 500);
  v_total  bigint;
  v_rows   jsonb;
begin
  if not public.is_admin() then
    raise exception 'Somente o administrador exporta a auditoria.' using errcode = '42501';
  end if;
  if length(v_reason) < 10 then
    raise exception 'Informe a finalidade da exportação (mínimo de 10 caracteres).' using errcode = '22023';
  end if;
  select count(*) into v_total from public._audit_rows(p_filters, true);
  if v_total > 10000 then
    raise exception 'A exportação tem % eventos. O máximo é 10.000: reduza o período ou use filtros.', v_total using errcode = '22023';
  end if;
  select coalesce(jsonb_agg(public._audit_public(x, true) order by x.occurred_at desc, x.id desc), '[]'::jsonb)
    into v_rows from public._audit_rows(p_filters, true) x;
  perform public.audit_event('auditoria.exportada', 'audit_logs', null, null, null, null,
    jsonb_build_object('filtros', coalesce(p_filters, '{}'::jsonb), 'eventos', v_total), v_reason);
  return v_rows;
end;
$$;

-- A leitura direta da tabela deixa de existir: só pelas funções acima
revoke select on public.audit_logs from authenticated;
drop policy if exists audit_logs_select on public.audit_logs;

-- ---------------------------------------------------------------------
-- 7) Exportação de MEs registrada no servidor
-- ---------------------------------------------------------------------
create or replace function public.audit_export_event(p_kind text, p_filters jsonb, p_count int)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  if not public.is_active_user() or not public.has_any_role(array['gestor', 'admin', 'equipe_sa']::public.app_role[]) then
    raise exception 'Seu perfil não permite exportar dados.' using errcode = '42501';
  end if;
  perform public.audit_event('exportacao.dados', 'stock_movements', null, null, null, null,
    jsonb_build_object('tipo', case when p_kind = 'itens' then 'itens' else 'resumo' end,
                       'registros', p_count, 'filtros', coalesce(p_filters, '{}'::jsonb)));
end;
$$;

-- Exportação de MEs: agora registra o evento no servidor
create or replace function public.export_movements(p_filters jsonb default '{}'::jsonb, p_kind text default 'resumo')
returns jsonb
language plpgsql volatile security invoker
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

  -- registro no servidor (não depende da tela)
  perform public.audit_export_event(p_kind, p_filters, jsonb_array_length(v_out));
  return v_out;
end;
$$;

-- ---------------------------------------------------------------------
-- 8) Permissões
-- ---------------------------------------------------------------------
revoke all on function public.audit_verify_chain() from public, anon;
revoke all on function public.audit_create_anchor() from public, anon;
revoke all on function public.audit_check_anchor(bigint, text) from public, anon;
revoke all on function public.search_audit(jsonb, int, int) from public, anon;
revoke all on function public.movement_audit(uuid) from public, anon;
revoke all on function public.export_audit(jsonb, text) from public, anon;
revoke all on function public.audit_export_event(text, jsonb, int) from public, anon;
revoke all on function public.export_movements(jsonb, text) from public, anon;
grant execute on function public.audit_verify_chain() to authenticated;
grant execute on function public.audit_create_anchor() to authenticated;
grant execute on function public.audit_check_anchor(bigint, text) to authenticated;
grant execute on function public.search_audit(jsonb, int, int) to authenticated;
grant execute on function public.movement_audit(uuid) to authenticated;
grant execute on function public.export_audit(jsonb, text) to authenticated;
grant execute on function public.audit_export_event(text, jsonb, int) to authenticated;
grant execute on function public.export_movements(jsonb, text) to authenticated;
