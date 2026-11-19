-- 29: guarda adicional por 10 anos civis desde a criação.
-- Aplicar após 28. Sem exclusão automática; não recupera dados já removidos.
-- Acesso aos modelos arquivados não é concedido à aplicação.
begin;

create or replace function public.retention_created_until(p_created_at timestamptz)
returns timestamptz language sql stable security definer
set search_path = public, pg_temp as $$
  select ((p_created_at at time zone coalesce((public.get_settings()).timezone,'America/Recife'))
           + interval '10 years') at time zone coalesce((public.get_settings()).timezone,'America/Recife');
$$;
revoke all on function public.retention_created_until(timestamptz) from public, anon, authenticated;

-- O cadastro operacional pode ser removido/inativado normalmente. Seu histórico
-- fica isolado: nenhuma RPC de reconhecimento consulta esta tabela.
create table if not exists public.employee_faces_archive (
  original_id bigint primary key,
  employee_id uuid not null references public.employees(id),
  descriptor real[] not null,
  source text not null,
  created_at timestamptz not null,
  created_by uuid references public.profiles(id),
  archived_at timestamptz not null default now()
);
alter table public.employee_faces_archive enable row level security;
revoke all on public.employee_faces_archive from public, anon, authenticated, service_role;
create or replace function public.archive_employee_face()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  insert into public.employee_faces_archive(original_id,employee_id,descriptor,source,created_at,created_by)
  values(old.id,old.employee_id,old.descriptor,old.source,old.created_at,old.created_by)
  on conflict(original_id) do nothing;
  return old;
end; $$;
revoke all on function public.archive_employee_face() from public, anon, authenticated;
drop trigger if exists employee_faces_retention_archive on public.employee_faces;
create trigger employee_faces_retention_archive before delete on public.employee_faces
for each row execute function public.archive_employee_face();

-- Não admitir eliminação/alteração silenciosa do arquivo, inclusive pela API de serviço.
create or replace function public.protect_retention_archive()
returns trigger language plpgsql set search_path = public, pg_temp as $$
begin
  raise exception 'Arquivo de retenção protegido; descarte exige procedimento específico de revisão.' using errcode='42501';
end; $$;
revoke all on function public.protect_retention_archive() from public, anon, authenticated;
drop trigger if exists employee_faces_archive_protected on public.employee_faces_archive;
create trigger employee_faces_archive_protected before update or delete on public.employee_faces_archive
for each row execute function public.protect_retention_archive();

drop trigger if exists employee_faces_archive_no_truncate on public.employee_faces_archive;
create trigger employee_faces_archive_no_truncate before truncate on public.employee_faces_archive
for each statement execute function public.protect_retention_archive();

-- Tentativas ficam disponíveis para investigação; sem limpeza automática.
create or replace function public.protect_face_attempt_retention()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if public.retention_created_until(old.created_at)>now() then
    raise exception 'Tentativa facial em guarda por 10 anos desde a criação.' using errcode='42501';
  end if;
  return old;
end; $$;
revoke all on function public.protect_face_attempt_retention() from public, anon, authenticated;
drop trigger if exists face_attempts_retention on public.face_attempts;
create trigger face_attempts_retention before delete on public.face_attempts
for each row execute function public.protect_face_attempt_retention();

-- Congela o marco original dos modelos; recadastro gera novos IDs.
create or replace function public.protect_face_creation()
returns trigger language plpgsql set search_path = public, pg_temp as $$
begin
  if new is distinct from old then
    raise exception 'Modelo facial imutável; utilize o recadastro para substituir.' using errcode='42501';
  end if;
  return new;
end; $$;
revoke all on function public.protect_face_creation() from public, anon, authenticated;
drop trigger if exists employee_faces_immutable on public.employee_faces;
create trigger employee_faces_immutable before update on public.employee_faces
for each row execute function public.protect_face_creation();

-- O campo legado usa dias e alimenta alertas. O bloqueio real usa ANOS CIVIS
-- abaixo, de modo que 3650 dias nunca antecipe o prazo em anos bissextos.
update public.audit_retention_policies
set retain_days=greatest(coalesce(retain_days,3650),3650),
    basis='Decisão do responsável em 19/11/2026: 10 anos civis desde a criação; sem exclusão automática.',
    status='aprovada', updated_by=null, updated_at=now(), approved_by=null, approved_at=now()
where retain_days is null or retain_days < 3650;

-- Revalida o piso inclusive para solicitações de descarte criadas antes desta migração.
create or replace function public._purge_candidates(p_category text, p_before date)
returns setof bigint language sql stable security definer set search_path = public, pg_temp as $$
  select l.id from public.audit_logs l
  where l.category=p_category and l.purged_at is null
    and l.occurred_at < (p_before::timestamp at time zone (public.get_settings()).timezone)
    and public.retention_created_until(l.occurred_at) <= now()
    and (l.movement_id is null or exists (select 1 from public.stock_movements m
      where m.id=l.movement_id and public.retention_created_until(
        case when m.status='cancelada' then m.cancelled_at when m.status='concluida' then m.completed_at end)<=now()))
    and not exists (select 1 from public.audit_legal_holds h
      where h.released_at is null and (h.category is null or h.category=l.category)
        and (l.occurred_at at time zone (public.get_settings()).timezone)::date between h.date_from and h.date_to);
$$;
revoke all on function public._purge_candidates(text,date) from public, anon, authenticated;

-- Inventário de cópias efetivamente geradas. Não representa configuração do
-- provedor nem afirma que existe backup só porque uma política foi instalada.
create table if not exists public.retention_backups (
  id uuid primary key default gen_random_uuid(),
  object_name text not null unique check(length(object_name) between 1 and 200),
  sha256 text not null check(sha256 ~ '^[0-9a-f]{64}$'),
  created_at timestamptz not null,
  registered_at timestamptz not null default now(),
  scope text not null check(scope in ('banco','banco_e_storage'))
);
alter table public.retention_backups enable row level security;
revoke all on public.retention_backups from public, anon, authenticated, service_role;
drop trigger if exists retention_backups_protected on public.retention_backups;
create trigger retention_backups_protected before update or delete on public.retention_backups
for each row execute function public.protect_retention_archive();
create or replace function public.register_retention_backup(p_name text,p_sha256 text,p_created_at timestamptz,p_scope text)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare v_id uuid;
begin
  if p_created_at is null or not isfinite(p_created_at) or p_created_at > now()+interval '5 minutes' then
    raise exception 'Data de criação do backup inválida.' using errcode='22023';
  end if;
  insert into public.retention_backups(object_name,sha256,created_at,scope)
  values(p_name,p_sha256,p_created_at,p_scope) returning id into v_id;
  return v_id;
end; $$;
revoke all on function public.register_retention_backup(text,text,timestamptz,text) from public, anon, authenticated;
grant execute on function public.register_retention_backup(text,text,timestamptz,text) to service_role;

create or replace function public.additional_retention_summary()
returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare v jsonb;
begin
  if not public.is_admin() then
    raise exception 'Somente administrador com MFA.' using errcode='42501';
  end if;
  with records as (
    select 'cadastros_faciais' category, created_at from public.employee_faces
    union all select 'cadastros_faciais',created_at from public.employee_faces_archive
    union all select 'logs',occurred_at from public.audit_logs where purged_at is null and movement_id is null
    union all select 'tentativas_faciais',created_at from public.face_attempts
    union all select 'backups',created_at from public.retention_backups
  ), totals as (
    select category,count(*) total,
      count(*) filter(where public.retention_created_until(created_at)<=now()) review_due,
      min(public.retention_created_until(created_at)) filter(where public.retention_created_until(created_at)>now()) next_review_at
    from records group by category
  ) select coalesce(jsonb_object_agg(category,jsonb_build_object('total',total,'review_due',review_due,'next_review_at',next_review_at)),'{}') into v from totals;
  return jsonb_build_object('years',10,'basis_event','criacao','automatic_deletion',false,
    'categories',v,'backup_provider_configured',false,
    'offline_scope','Fila não sincronizada no aparelho; após envio, guarda junto da ME. Cache de acesso não é arquivo.');
end; $$;
revoke all on function public.additional_retention_summary() from public, anon;
grant execute on function public.additional_retention_summary() to authenticated;
comment on table public.employee_faces_archive is 'Histórico de modelos removidos: 10 anos desde criação original; isolado do reconhecimento e sem leitura pela aplicação.';
comment on table public.retention_backups is 'Inventário de backups: 10 anos desde criação de cada cópia. Arquivos externos e sua durabilidade precisam de configuração operacional.';
commit;
