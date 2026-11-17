-- =====================================================================
-- 07f (= migração 23) - SEGURANÇA: LOGIN, ACESSO NEGADO, ALERTAS, RETENÇÃO E DESCARTE
--      (fase 2 do plano de auditoria e LGPD)
--
-- * Login com sucesso, falha e saída relatados pela tela no momento em que
--   acontecem (falha: sem login, com limite contra abuso e e-mail mascarado).
--   Troca de senha, recuperação e criação de usuário importadas do log do
--   Supabase Auth (auth.audit_log_entries), quando ele estiver gravando no banco.
-- * Acesso negado relatado pela tela (marcado como relato_da_tela), com limite.
-- * Alertas de segurança: falhas de login, acessos negados repetidos, volume de
--   exportação, perfil de administrador concedido/retirado, quebra da
--   integridade, coleta parada, retenção vencendo, descarte executado.
-- * Retenção por categoria (proposta -> aprovada), retenção legal (bloqueia
--   descarte) e descarte com DUPLA APROVAÇÃO (dois administradores diferentes).
--   O descarte apaga o CONTEÚDO do evento e preserva o esqueleto do
--   encadeamento de hash (a verificação continua íntegra).
-- * Verificações periódicas por pg_cron, quando disponível (senão: botão
--   "Rodar verificações agora" na tela Segurança).
-- * Corrige o evento duplicado da confirmação no balcão.
--
-- Pré-requisito: 22. Pode ser reexecutado.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) Tabelas
-- ---------------------------------------------------------------------
alter table public.audit_logs add column if not exists purged_at        timestamptz;
alter table public.audit_logs add column if not exists purge_request_id bigint;

create table if not exists public.security_alerts (
  id            bigint generated always as identity primary key,
  created_at    timestamptz not null default now(),
  last_seen_at  timestamptz not null default now(),
  rule          text not null,
  severity      text not null default 'aviso' check (severity in ('info', 'aviso', 'critico')),
  title         text not null,
  details       jsonb,
  dedupe_key    text not null default '',
  occurrences   integer not null default 1,
  status        text not null default 'aberto' check (status in ('aberto', 'em_analise', 'encerrado')),
  handled_by    uuid references public.profiles (id),
  handled_at    timestamptz,
  resolution    text
);
create unique index if not exists security_alerts_open_uk on public.security_alerts (rule, dedupe_key) where status <> 'encerrado';
create index if not exists security_alerts_status_idx on public.security_alerts (status, created_at desc);

create table if not exists public.auth_login_failures (
  email_hash    text not null,
  window_start  timestamptz not null,
  attempts      integer not null default 0,
  masked_email  text,
  last_ip       text,
  last_at       timestamptz not null default now(),
  primary key (email_hash, window_start)
);
create index if not exists auth_login_failures_last_idx on public.auth_login_failures (last_at desc);

create table if not exists public.security_state (
  key         text primary key,
  value       jsonb,
  updated_at  timestamptz not null default now()
);

create table if not exists public.audit_retention_policies (
  category     text primary key,
  retain_days  integer check (retain_days is null or retain_days between 30 and 7300),
  basis        text,
  status       text not null default 'proposta' check (status in ('proposta', 'aprovada')),
  updated_by   uuid references public.profiles (id),
  updated_at   timestamptz not null default now(),
  approved_by  uuid references public.profiles (id),
  approved_at  timestamptz
);

-- Propostas técnicas (NÃO aprovadas). Prazos sem fundamento ficam vazios.
insert into public.audit_retention_policies (category, retain_days, basis) values
  ('autenticacao', 180,  'Proposta: 6 meses (Marco Civil art. 15, se aplicável) - validar com o jurídico'),
  ('autorizacao',  180,  'Proposta: 6 meses - validar com o jurídico'),
  ('privacidade',  730,  'Proposta: 2 anos (investigação interna) - boa prática'),
  ('exportacao',   730,  'Proposta: 2 anos (investigação interna) - boa prática'),
  ('auditoria',    730,  'Proposta: 2 anos - boa prática'),
  ('incidente',    1825, 'Mínimo de 5 anos (Res. CD/ANPD 15/2024, art. 10)'),
  ('dados',        null, 'A definir com a contabilidade (prazo fiscal da baixa)'),
  ('cadastro',     null, 'A definir'),
  ('permissao',    null, 'A definir'),
  ('configuracao', null, 'A definir')
on conflict (category) do nothing;

create table if not exists public.audit_legal_holds (
  id              bigint generated always as identity primary key,
  reason          text not null check (length(btrim(reason)) between 10 and 500),
  date_from       date not null,
  date_to         date not null,
  category        text,
  created_by      uuid references public.profiles (id),
  created_at      timestamptz not null default now(),
  released_by     uuid references public.profiles (id),
  released_at     timestamptz,
  release_reason  text,
  check (date_from <= date_to)
);

create table if not exists public.audit_purge_requests (
  id             bigint generated always as identity primary key,
  category       text not null,
  before_date    date not null,
  events         integer not null,
  reason         text not null,
  status         text not null default 'pendente' check (status in ('pendente', 'executado', 'rejeitado')),
  requested_by   uuid not null references public.profiles (id),
  requested_at   timestamptz not null default now(),
  decided_by     uuid references public.profiles (id),
  decided_at     timestamptz,
  decision_note  text,
  executed_at    timestamptz,
  purged         integer
);

do $$
declare t text;
begin
  foreach t in array array['security_alerts', 'auth_login_failures', 'security_state',
                           'audit_retention_policies', 'audit_legal_holds', 'audit_purge_requests'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
  end loop;
end $$;

-- Descarte: a única alteração permitida em audit_logs é apagar o conteúdo de um evento,
-- dentro da função de descarte, mantendo a sequência e os hashes.
create or replace function public.tg_block_audit_change()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'UPDATE'
     and coalesce(current_setting('app.audit_purge', true), '') = 'on'
     and new.id = old.id and new.chain_seq = old.chain_seq and new.prev_hash = old.prev_hash
     and new.row_hash = old.row_hash and new.event_id = old.event_id and new.action = old.action
     and new.occurred_at = old.occurred_at and new.category is not distinct from old.category
     and old.purged_at is null and new.purged_at is not null and new.purge_request_id is not null
     and new.old_data is null and new.new_data is null and new.justification is null
     and new.ip_address is null and new.user_agent is null and new.user_id is null and new.user_email is null
     and new.entity_id is null
  then
    return new;
  end if;
  raise exception 'Registros de auditoria não podem ser alterados ou excluídos.' using errcode = 'P0001';
end;
$$;

-- ---------------------------------------------------------------------
-- 2) Alertas
-- ---------------------------------------------------------------------
create or replace function public._raise_alert(p_rule text, p_severity text, p_title text, p_key text, p_details jsonb)
returns bigint
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_id bigint;
begin
  update public.security_alerts
     set occurrences = occurrences + 1, last_seen_at = now(), details = coalesce(p_details, details)
   where rule = p_rule and dedupe_key = coalesce(p_key, '') and status <> 'encerrado'
  returning id into v_id;
  if v_id is null then
    insert into public.security_alerts (rule, severity, title, dedupe_key, details)
    values (p_rule, p_severity, left(p_title, 200), coalesce(p_key, ''), p_details)
    returning id into v_id;
    perform public.audit_event('alerta.aberto', 'security_alerts', v_id::text, null, null, null,
      jsonb_build_object('regra', p_rule, 'criticidade', p_severity, 'titulo', left(p_title, 200)));
  end if;
  return v_id;
end;
$$;
revoke all on function public._raise_alert(text, text, text, text, jsonb) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 3) Classificação, interface única com regras de alerta e verificação com descarte
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
    when v_uid is null and p_action like 'auth.%' then 'anonimo'
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

  -- Regras de alerta avaliadas no próprio registro
  if p_entity = 'user_roles' and ((p_new ->> 'role') = 'admin' or (p_old ->> 'role') = 'admin') then
    perform public._raise_alert('perfil_admin', 'critico',
      case when p_new ->> 'role' = 'admin' then 'Perfil de administrador concedido' else 'Perfil de administrador retirado' end,
      coalesce(p_entity_id, '') || ':' || coalesce(p_new ->> 'role', p_old ->> 'role', ''),
      jsonb_build_object('usuario_afetado', coalesce(p_new ->> 'user_id', p_old ->> 'user_id'), 'por', v_uid, 'acao', p_action));
  end if;
  if p_action in ('exportacao.dados', 'auditoria.exportada') and v_uid is not null then
    if (select count(*) from public.audit_logs where user_id = v_uid and action in ('exportacao.dados', 'auditoria.exportada')
          and occurred_at > now() - interval '24 hours') = 10 then
      perform public._raise_alert('exportacoes_volume', 'aviso', '10 exportações em 24 horas pelo mesmo usuário', v_uid::text,
        jsonb_build_object('usuario', v_uid));
    end if;
  end if;
end;
$$;

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
    elsif r.purged_at is null and r.row_hash is distinct from public.audit_row_hash(r.prev_hash, r) then
      v_issue := 'conteudo_alterado'; v_bad := r.chain_seq; exit;
    elsif r.purged_at is not null and not exists (
            select 1 from public.audit_purge_requests q
             where q.id = r.purge_request_id and q.status = 'executado' and q.category = r.category
               and r.occurred_at < (q.before_date::timestamp at time zone (public.get_settings()).timezone)) then
      v_issue := 'descarte_nao_autorizado'; v_bad := r.chain_seq; exit;
    end if;
    v_seq := r.chain_seq;
    v_prev := r.row_hash;
  end loop;
  return jsonb_build_object('ok', v_issue is null, 'checked', v_n, 'last_seq', v_seq, 'last_hash', v_prev,
                            'problem', v_issue, 'problem_seq', v_bad);
end;
$$;
revoke all on function public._audit_verify(bigint) from public, anon, authenticated;
revoke all on function public.audit_event(text, text, text, uuid, uuid, jsonb, jsonb, text, text, text) from public, anon, authenticated;

-- Confirmação no balcão: o gatilho já registra 'me.confirmada'; os detalhes vão em evento próprio
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

  perform public.write_audit('me.confirmacao_registrada', 'stock_movements', v_m.id::text, v_m.id, v_m.warehouse_id, null,
    jsonb_build_object('me_number', v_m.me_number, 'solicitante', v_m.requester_name, 'metodo', v_method,
                       'tentativa', v_att.id, 'itens', v_m.item_count, 'total_atendido', v_m.total_delivered,
                       'almoxarife', v_m.storekeeper_id, 'status', v_status,
                       'foto', v_photo is not null, 'sem_foto_motivo', v_no_photo,
                       'emergencial', v_m.is_emergency), null);

  return jsonb_build_object('id', v_m.id, 'me_number', v_m.me_number, 'status', v_status);
end;
$$;

-- ---------------------------------------------------------------------
-- 4) Login (relatado pela tela) e importação do log do Supabase Auth
-- ---------------------------------------------------------------------
-- Falha de login: chamada SEM sessão. E-mail guardado só mascarado e como hash
-- (hash com prefixo fixo NÃO é anonimização: serve só para contar tentativas).
create or replace function public.report_login_failure(p_email text)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_email   text := lower(btrim(left(coalesce(p_email, ''), 254)));
  v_hash    text;
  v_masked  text;
  v_window  timestamptz := date_trunc('hour', now()) + floor(extract(minute from now()) / 15) * interval '15 minutes';
  v_count   integer;
  v_recent  bigint;
  v_ip      text := nullif(split_part(coalesce(public.request_header('x-forwarded-for'), public.request_header('x-real-ip'), ''), ',', 1), '');
begin
  if v_email = '' or position('@' in v_email) = 0 then
    return;
  end if;
  -- proteção contra inundação: acima de 300 relatos por minuto, só registra o alerta
  select coalesce(sum(attempts), 0) into v_recent from public.auth_login_failures where last_at > now() - interval '1 minute';
  if v_recent > 300 then
    perform public._raise_alert('falhas_login_em_massa', 'critico', 'Muitas falhas de login no último minuto', '',
      jsonb_build_object('falhas_ultimo_minuto', v_recent));
    return;
  end if;

  v_hash := encode(sha256(convert_to('baixas-estoque:' || v_email, 'UTF8')), 'hex');
  v_masked := public.audit_mask_email(v_email);
  insert into public.auth_login_failures (email_hash, window_start, attempts, masked_email, last_ip, last_at)
  values (v_hash, v_window, 1, v_masked, left(v_ip, 64), now())
  on conflict (email_hash, window_start) do update
    set attempts = public.auth_login_failures.attempts + 1, last_ip = excluded.last_ip, last_at = now()
  returning attempts into v_count;

  -- um evento por conta e janela de 15 min (mais um ao atingir 5), sem inundar a trilha
  if v_count in (1, 5) then
    perform public.audit_event('auth.falha_login', 'auth', v_masked, null, null, null,
      jsonb_build_object('tentativas_na_janela', v_count), null, 'falha', 'credenciais_invalidas');
  end if;
  if v_count = 5 then
    perform public._raise_alert('falhas_login', 'aviso', '5 falhas de login em 15 minutos: ' || v_masked, v_hash,
      jsonb_build_object('conta', v_masked, 'tentativas', v_count, 'janela', v_window));
  end if;

  delete from public.auth_login_failures where window_start < now() - interval '7 days';
end;
$$;

create or replace function public.auth_log_session(p_action text)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_act text := case p_action when 'login' then 'auth.login' when 'logout' then 'auth.logout' end;
begin
  if v_uid is null or v_act is null then
    return;
  end if;
  if exists (select 1 from public.audit_logs where user_id = v_uid and action = v_act and occurred_at > now() - interval '10 seconds') then
    return;
  end if;
  if public.is_active_user() then
    perform public.audit_event(v_act, 'auth', v_uid::text, null, null, null, null);
  else
    perform public.audit_event(v_act, 'auth', v_uid::text, null, null, null, null, null, 'negado', 'usuario_inativo');
  end if;
end;
$$;

-- Importa do Supabase Auth os eventos que a tela não vê (senha, recuperação, criação de usuário).
create or replace function public.security_import_auth_events()
returns integer
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_since timestamptz;
  v_last  timestamptz;
  v_n     integer := 0;
  r       record;
  v_act   text;
begin
  if to_regclass('auth.audit_log_entries') is null then
    return 0;
  end if;
  select (value ->> 'since')::timestamptz into v_since from public.security_state where key = 'auth_import';
  v_since := coalesce(v_since, now() - interval '1 day');
  v_last := v_since;
  for r in execute
    'select id, created_at, ip_address, payload from auth.audit_log_entries where created_at > $1 order by created_at limit 1000'
    using v_since loop
    v_act := case (r.payload ->> 'action')
      when 'user_recovery_requested' then 'auth.recuperacao_solicitada'
      when 'user_updated_password'   then 'auth.senha_alterada'
      when 'user_signedup'           then 'auth.usuario_criado'
      when 'user_invited'            then 'auth.usuario_criado'
      when 'user_deleted'            then 'auth.usuario_excluido'
      when 'user_modified'           then 'auth.usuario_alterado'
      else null end;
    v_last := greatest(v_last, r.created_at);
    if v_act is not null then
      insert into public.audit_logs (occurred_at, user_id, action, entity, entity_id, new_data, source, ip_address,
                                     schema_version, category, actor_type, result, severity)
      values (r.created_at,
              case when (r.payload ->> 'actor_id') ~* '^[0-9a-f-]{36}$' then (r.payload ->> 'actor_id')::uuid end,
              v_act, 'auth', r.id::text,
              jsonb_build_object('origem', 'supabase_auth', 'evento_original', r.payload ->> 'action'),
              'supabase_auth', nullif(left(r.ip_address::text, 64), ''), 2, 'autenticacao', 'usuario', 'sucesso', 'aviso');
      v_n := v_n + 1;
    end if;
  end loop;
  insert into public.security_state (key, value, updated_at)
  values ('auth_import', jsonb_build_object('since', v_last, 'importados', v_n), now())
  on conflict (key) do update set value = excluded.value, updated_at = now();
  return v_n;
end;
$$;

-- ---------------------------------------------------------------------
-- 5) Acesso negado relatado pela tela
-- ---------------------------------------------------------------------
create or replace function public.log_access_denied(p_operation text, p_code text default null)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_n   integer;
begin
  if v_uid is null then
    return;
  end if;
  select count(*) into v_n from public.audit_logs
   where user_id = v_uid and action = 'acesso.negado' and occurred_at > now() - interval '1 hour';
  if v_n >= 30 then
    return; -- limite contra abuso
  end if;
  perform public.audit_event('acesso.negado', 'interface', public.audit_clean_text(p_operation, 80), null, null, null,
    jsonb_build_object('operacao', public.audit_clean_text(p_operation, 80), 'codigo', public.audit_clean_text(p_code, 20),
                       'origem', 'relato_da_tela'),
    null, 'negado', coalesce(public.audit_clean_text(p_code, 20), 'sem_permissao'));
  if v_n + 1 = 10 then
    perform public._raise_alert('acessos_negados', 'aviso', '10 acessos negados em 1 hora para o mesmo usuário', v_uid::text,
      jsonb_build_object('usuario', v_uid, 'ultima_operacao', public.audit_clean_text(p_operation, 80)));
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- 6) Verificações periódicas (pg_cron ou botão)
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

  insert into public.security_state (key, value, updated_at)
  values ('last_checks', jsonb_build_object('at', now(), 'integridade', v_chain -> 'ok', 'importados_auth', v_imp, 'alertas', v_alerts), now())
  on conflict (key) do update set value = excluded.value, updated_at = now();

  return jsonb_build_object('integridade', v_chain, 'importados_auth', v_imp, 'alertas', v_alerts, 'at', now());
end;
$$;
revoke all on function public._security_checks() from public, anon, authenticated;

create or replace function public.security_run_checks()
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v jsonb;
begin
  if not public.is_admin() then
    raise exception 'Somente o administrador roda as verificações de segurança.' using errcode = '42501';
  end if;
  v := public._security_checks();
  perform public.audit_event('seguranca.verificacao', 'security_alerts', null, null, null, null,
    jsonb_build_object('integridade', v -> 'integridade' -> 'ok', 'alertas', v -> 'alertas', 'importados_auth', v -> 'importados_auth'));
  return v;
end;
$$;

-- Consulta da auditoria mostra quando o conteúdo do evento foi descartado
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
    'severity', a.severity, 'correlation_id', a.correlation_id, 'chain_seq', a.chain_seq)
    || jsonb_build_object('purged_at', a.purged_at);
$$;
revoke all on function public._audit_public(public.audit_logs, boolean) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 7) Tela de Segurança
-- ---------------------------------------------------------------------
create or replace function public.security_overview()
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare
  v_admin boolean := public.is_admin();
  v       jsonb;
begin
  if not public.is_active_user() or not (v_admin or public.has_role('gestor')) then
    raise exception 'Seu perfil não permite ver os alertas de segurança.' using errcode = '42501';
  end if;
  v := jsonb_build_object(
    'is_admin', v_admin,
    'alerts', coalesce((select jsonb_agg(to_jsonb(a) - case when v_admin then '' else 'details' end
                                         || jsonb_build_object('handled_by_name', (select full_name from public.profiles where id = a.handled_by))
                                         order by (a.status = 'encerrado'), a.last_seen_at desc)
                          from (select * from public.security_alerts
                                 where status <> 'encerrado' or handled_at > now() - interval '90 days'
                                 order by last_seen_at desc limit 200) a), '[]'::jsonb),
    'last_checks', (select value from public.security_state where key = 'last_checks'),
    'open_count', (select count(*) from public.security_alerts where status <> 'encerrado'),
    'open_critical', (select count(*) from public.security_alerts where status <> 'encerrado' and severity = 'critico'));
  if v_admin then
    v := v || jsonb_build_object(
      'policies', coalesce((select jsonb_agg(to_jsonb(p) || jsonb_build_object(
                              'approved_by_name', (select full_name from public.profiles where id = p.approved_by),
                              'updated_by_name', (select full_name from public.profiles where id = p.updated_by),
                              'events', (select count(*) from public.audit_logs l where l.category = p.category and l.purged_at is null))
                              order by p.category) from public.audit_retention_policies p), '[]'::jsonb),
      'holds', coalesce((select jsonb_agg(to_jsonb(h) || jsonb_build_object('created_by_name', (select full_name from public.profiles where id = h.created_by))
                              order by h.released_at nulls first, h.created_at desc) from public.audit_legal_holds h), '[]'::jsonb),
      'purges', coalesce((select jsonb_agg(to_jsonb(r) || jsonb_build_object(
                              'requested_by_name', (select full_name from public.profiles where id = r.requested_by),
                              'decided_by_name', (select full_name from public.profiles where id = r.decided_by))
                              order by r.requested_at desc) from (select * from public.audit_purge_requests order by requested_at desc limit 50) r), '[]'::jsonb),
      'admins', (select count(*) from public.user_roles ur join public.profiles pr on pr.id = ur.user_id where ur.role = 'admin' and pr.active),
      'cron', (to_regclass('cron.job') is not null));
  end if;
  return v;
end;
$$;

create or replace function public.security_alert_update(p_id bigint, p_status text, p_resolution text default null)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_old  public.security_alerts;
  v_note text := public.audit_clean_text(btrim(coalesce(p_resolution, '')), 1000);
begin
  if not public.is_admin() then
    raise exception 'Somente o administrador trata alertas.' using errcode = '42501';
  end if;
  if p_status not in ('aberto', 'em_analise', 'encerrado') then
    raise exception 'Situação inválida.' using errcode = '22023';
  end if;
  select * into v_old from public.security_alerts where id = p_id for update;
  if v_old.id is null then
    raise exception 'Alerta não encontrado.' using errcode = 'P0002';
  end if;
  if v_old.status = 'encerrado' then
    raise exception 'Alerta já encerrado.' using errcode = 'P0001';
  end if;
  if p_status = 'encerrado' and length(v_note) < 5 then
    raise exception 'Para encerrar, descreva o tratamento (mínimo de 5 caracteres).' using errcode = '22023';
  end if;
  update public.security_alerts
     set status = p_status, handled_by = auth.uid(), handled_at = now(), resolution = nullif(v_note, '')
   where id = p_id;
  perform public.audit_event('alerta.atualizado', 'security_alerts', p_id::text, null, null,
    jsonb_build_object('situacao', v_old.status), jsonb_build_object('situacao', p_status, 'regra', v_old.rule), nullif(v_note, ''));
end;
$$;

-- ---------------------------------------------------------------------
-- 8) Retenção, retenção legal e descarte com dupla aprovação
-- ---------------------------------------------------------------------
create or replace function public.retention_set_policy(p_category text, p_days integer, p_basis text)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_old public.audit_retention_policies;
begin
  if not public.is_admin() then
    raise exception 'Somente o administrador altera a retenção.' using errcode = '42501';
  end if;
  select * into v_old from public.audit_retention_policies where category = p_category for update;
  if v_old.category is null then
    raise exception 'Categoria inválida.' using errcode = '22023';
  end if;
  if p_days is not null and (p_days < 30 or p_days > 7300) then
    raise exception 'O prazo deve ficar entre 30 e 7300 dias.' using errcode = '22023';
  end if;
  if p_category = 'incidente' and (p_days is null or p_days < 1825) then
    raise exception 'Incidentes devem ser guardados por no mínimo 5 anos (1825 dias).' using errcode = '22023';
  end if;
  if length(btrim(coalesce(p_basis, ''))) < 5 then
    raise exception 'Informe o fundamento do prazo.' using errcode = '22023';
  end if;
  -- qualquer mudança volta para "proposta" e exige nova aprovação
  update public.audit_retention_policies
     set retain_days = p_days, basis = public.audit_clean_text(btrim(p_basis), 500), status = 'proposta',
         updated_by = auth.uid(), updated_at = now(), approved_by = null, approved_at = null
   where category = p_category;
  perform public.audit_event('retencao.alterada', 'audit_retention_policies', p_category, null, null,
    jsonb_build_object('dias', v_old.retain_days, 'situacao', v_old.status),
    jsonb_build_object('dias', p_days, 'fundamento', public.audit_clean_text(btrim(p_basis), 500)));
end;
$$;

create or replace function public.retention_approve_policy(p_category text)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v public.audit_retention_policies;
begin
  if not public.is_admin() then
    raise exception 'Somente o administrador aprova a retenção.' using errcode = '42501';
  end if;
  select * into v from public.audit_retention_policies where category = p_category for update;
  if v.category is null then
    raise exception 'Categoria inválida.' using errcode = '22023';
  end if;
  if v.retain_days is null then
    raise exception 'Defina o prazo antes de aprovar.' using errcode = '22023';
  end if;
  update public.audit_retention_policies set status = 'aprovada', approved_by = auth.uid(), approved_at = now()
   where category = p_category;
  perform public.audit_event('retencao.aprovada', 'audit_retention_policies', p_category, null, null, null,
    jsonb_build_object('dias', v.retain_days, 'fundamento', v.basis));
end;
$$;

create or replace function public.legal_hold_create(p_reason text, p_from date, p_to date, p_category text default null)
returns bigint
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_id bigint;
begin
  if not public.is_admin() then
    raise exception 'Somente o administrador abre retenção legal.' using errcode = '42501';
  end if;
  if length(btrim(coalesce(p_reason, ''))) < 10 then
    raise exception 'Informe o motivo (mínimo de 10 caracteres).' using errcode = '22023';
  end if;
  if p_from is null or p_to is null or p_from > p_to then
    raise exception 'Período inválido.' using errcode = '22023';
  end if;
  insert into public.audit_legal_holds (reason, date_from, date_to, category, created_by)
  values (public.audit_clean_text(btrim(p_reason), 500), p_from, p_to, nullif(p_category, ''), auth.uid())
  returning id into v_id;
  perform public.audit_event('retencao_legal.aberta', 'audit_legal_holds', v_id::text, null, null, null,
    jsonb_build_object('de', p_from, 'ate', p_to, 'categoria', nullif(p_category, '')), public.audit_clean_text(btrim(p_reason), 500));
  return v_id;
end;
$$;

create or replace function public.legal_hold_release(p_id bigint, p_reason text)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  if not public.is_admin() then
    raise exception 'Somente o administrador libera retenção legal.' using errcode = '42501';
  end if;
  if length(btrim(coalesce(p_reason, ''))) < 10 then
    raise exception 'Informe o motivo da liberação (mínimo de 10 caracteres).' using errcode = '22023';
  end if;
  update public.audit_legal_holds set released_by = auth.uid(), released_at = now(),
         release_reason = public.audit_clean_text(btrim(p_reason), 500)
   where id = p_id and released_at is null;
  if not found then
    raise exception 'Retenção legal não encontrada ou já liberada.' using errcode = 'P0002';
  end if;
  perform public.audit_event('retencao_legal.liberada', 'audit_legal_holds', p_id::text, null, null, null, null,
    public.audit_clean_text(btrim(p_reason), 500));
end;
$$;

-- Eventos que podem ser descartados (prazo vencido, sem retenção legal ativa)
create or replace function public._purge_candidates(p_category text, p_before date)
returns setof bigint
language sql stable security definer
set search_path = public, pg_temp
as $$
  select l.id from public.audit_logs l
   where l.category = p_category and l.purged_at is null
     and l.occurred_at < (p_before::timestamp at time zone (public.get_settings()).timezone)
     and not exists (select 1 from public.audit_legal_holds h
                      where h.released_at is null
                        and (h.category is null or h.category = l.category)
                        and (l.occurred_at at time zone (public.get_settings()).timezone)::date between h.date_from and h.date_to);
$$;
revoke all on function public._purge_candidates(text, date) from public, anon, authenticated;

create or replace function public.purge_request(p_category text, p_before date, p_reason text)
returns bigint
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_pol  public.audit_retention_policies;
  v_n    integer;
  v_id   bigint;
  v_tz   text := (public.get_settings()).timezone;
begin
  if not public.is_admin() then
    raise exception 'Somente o administrador pede descarte.' using errcode = '42501';
  end if;
  select * into v_pol from public.audit_retention_policies where category = p_category;
  if v_pol.category is null or v_pol.status <> 'aprovada' or v_pol.retain_days is null then
    raise exception 'A retenção desta categoria ainda não foi aprovada.' using errcode = 'P0001';
  end if;
  if p_before is null or p_before > (now() at time zone v_tz)::date - v_pol.retain_days then
    raise exception 'A data deve respeitar o prazo de % dias desta categoria.', v_pol.retain_days using errcode = '22023';
  end if;
  if length(btrim(coalesce(p_reason, ''))) < 10 then
    raise exception 'Informe o motivo (mínimo de 10 caracteres).' using errcode = '22023';
  end if;
  if exists (select 1 from public.audit_purge_requests where status = 'pendente' and category = p_category) then
    raise exception 'Já existe um pedido de descarte pendente para esta categoria.' using errcode = 'P0001';
  end if;
  select count(*) into v_n from public._purge_candidates(p_category, p_before);
  if v_n = 0 then
    raise exception 'Não há eventos a descartar nesse período (ou estão em retenção legal).' using errcode = 'P0002';
  end if;
  insert into public.audit_purge_requests (category, before_date, events, reason, requested_by)
  values (p_category, p_before, v_n, public.audit_clean_text(btrim(p_reason), 500), auth.uid())
  returning id into v_id;
  perform public.audit_event('auditoria.descarte_solicitado', 'audit_purge_requests', v_id::text, null, null, null,
    jsonb_build_object('categoria', p_category, 'antes_de', p_before, 'eventos', v_n), public.audit_clean_text(btrim(p_reason), 500));
  return v_id;
end;
$$;

-- Segundo administrador decide. Aprovado = executa na hora.
create or replace function public.purge_decide(p_id bigint, p_approve boolean, p_note text)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_req  public.audit_purge_requests;
  v_pol  public.audit_retention_policies;
  v_note text := public.audit_clean_text(btrim(coalesce(p_note, '')), 500);
  v_n    integer := 0;
  v_tz   text := (public.get_settings()).timezone;
begin
  if not public.is_admin() then
    raise exception 'Somente o administrador decide o descarte.' using errcode = '42501';
  end if;
  select * into v_req from public.audit_purge_requests where id = p_id for update;
  if v_req.id is null or v_req.status <> 'pendente' then
    raise exception 'Pedido não encontrado ou já decidido.' using errcode = 'P0002';
  end if;
  if v_req.requested_by = auth.uid() then
    raise exception 'O descarte precisa ser aprovado por OUTRO administrador.' using errcode = '42501';
  end if;
  if length(v_note) < 5 then
    raise exception 'Registre a justificativa da decisão (mínimo de 5 caracteres).' using errcode = '22023';
  end if;

  if not coalesce(p_approve, false) then
    update public.audit_purge_requests set status = 'rejeitado', decided_by = auth.uid(), decided_at = now(), decision_note = v_note
     where id = p_id;
    perform public.audit_event('auditoria.descarte_rejeitado', 'audit_purge_requests', p_id::text, null, null, null,
      jsonb_build_object('categoria', v_req.category), v_note);
    return jsonb_build_object('status', 'rejeitado');
  end if;

  -- revalida: política aprovada e prazo
  select * into v_pol from public.audit_retention_policies where category = v_req.category;
  if v_pol.status <> 'aprovada' or v_pol.retain_days is null
     or v_req.before_date > (now() at time zone v_tz)::date - v_pol.retain_days then
    raise exception 'A política de retenção mudou desde o pedido. Faça um novo pedido.' using errcode = 'P0001';
  end if;

  perform set_config('app.audit_purge', 'on', true);
  update public.audit_logs l
     set old_data = null, new_data = null, justification = null, ip_address = null, user_agent = null,
         user_id = null, user_email = null, entity_id = null, purged_at = now(), purge_request_id = p_id
   where l.id in (select public._purge_candidates(v_req.category, v_req.before_date));
  get diagnostics v_n = row_count;
  perform set_config('app.audit_purge', '', true);

  update public.audit_purge_requests
     set status = 'executado', decided_by = auth.uid(), decided_at = now(), decision_note = v_note,
         executed_at = now(), purged = v_n
   where id = p_id;
  perform public.audit_event('auditoria.descarte_executado', 'audit_purge_requests', p_id::text, null, null, null,
    jsonb_build_object('categoria', v_req.category, 'antes_de', v_req.before_date, 'eventos', v_n,
                       'solicitado_por', v_req.requested_by), v_note);
  perform public._raise_alert('descarte_executado', 'aviso', 'Descarte de eventos de auditoria executado (' || v_req.category || ')',
    p_id::text, jsonb_build_object('pedido', p_id, 'eventos', v_n));
  return jsonb_build_object('status', 'executado', 'eventos', v_n);
end;
$$;


-- ---------------------------------------------------------------------
-- 9) Agendamento (pg_cron, se disponível)
-- ---------------------------------------------------------------------
do $$
begin
  begin
    create extension if not exists pg_cron;
  exception when others then
    raise notice 'pg_cron indisponível: use o botão "Rodar verificações agora" na tela Segurança.';
  end;
  if to_regclass('cron.job') is not null then
    begin
      perform cron.unschedule(jobid) from cron.job where jobname = 'baixas-verificacoes-seguranca';
      perform cron.schedule('baixas-verificacoes-seguranca', '17 * * * *', 'select public._security_checks()');
    exception when others then
      raise notice 'Não foi possível agendar: %', sqlerrm;
    end;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 10) Permissões
-- ---------------------------------------------------------------------
revoke all on function public.report_login_failure(text) from public;
grant execute on function public.report_login_failure(text) to anon, authenticated;
revoke all on function public.security_import_auth_events() from public, anon, authenticated;
revoke all on function public.auth_log_session(text) from public, anon;
grant execute on function public.auth_log_session(text) to authenticated;
revoke all on function public.log_access_denied(text, text) from public, anon;
grant execute on function public.log_access_denied(text, text) to authenticated;
revoke all on function public.security_run_checks() from public, anon;
grant execute on function public.security_run_checks() to authenticated;
revoke all on function public.security_overview() from public, anon;
grant execute on function public.security_overview() to authenticated;
revoke all on function public.security_alert_update(bigint, text, text) from public, anon;
grant execute on function public.security_alert_update(bigint, text, text) to authenticated;
revoke all on function public.retention_set_policy(text, integer, text) from public, anon;
grant execute on function public.retention_set_policy(text, integer, text) to authenticated;
revoke all on function public.retention_approve_policy(text) from public, anon;
grant execute on function public.retention_approve_policy(text) to authenticated;
revoke all on function public.legal_hold_create(text, date, date, text) from public, anon;
grant execute on function public.legal_hold_create(text, date, date, text) to authenticated;
revoke all on function public.legal_hold_release(bigint, text) from public, anon;
grant execute on function public.legal_hold_release(bigint, text) to authenticated;
revoke all on function public.purge_request(text, date, text) from public, anon;
grant execute on function public.purge_request(text, date, text) to authenticated;
revoke all on function public.purge_decide(bigint, boolean, text) from public, anon;
grant execute on function public.purge_decide(bigint, boolean, text) to authenticated;
revoke all on function public.counter_confirm(uuid, jsonb) from public, anon;
grant execute on function public.counter_confirm(uuid, jsonb) to authenticated;
