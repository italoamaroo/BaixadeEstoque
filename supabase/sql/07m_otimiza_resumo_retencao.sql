-- 30: otimiza somente a consulta do resumo de guarda adicional.
-- Aplicar após 29. Não altera prazos, registros, permissões ou configurações de timeout.
begin;
create or replace function public.additional_retention_summary()
returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare
  v jsonb;
  v_tz text;
begin
  if not public.is_admin() then
    raise exception 'Somente administrador com MFA.' using errcode='42501';
  end if;
  -- Ler a configuração uma vez, não várias vezes para cada evento do histórico.
  v_tz := coalesce((public.get_settings()).timezone,'America/Recife');
  with records as (
    select 'cadastros_faciais' category, created_at from public.employee_faces
    union all select 'cadastros_faciais',created_at from public.employee_faces_archive
    union all select 'logs',occurred_at from public.audit_logs where purged_at is null and movement_id is null
    union all select 'tentativas_faciais',created_at from public.face_attempts
    union all select 'falhas_login_legadas',window_start from public.auth_login_failures
    union all select 'backups',created_at from public.retention_backups
  ), deadlines as materialized (
    -- Anos civis e fuso original: não substituir por 3650 dias.
    select category,((created_at at time zone v_tz)+interval '10 years') at time zone v_tz as retain_until
    from records
  ), totals as (
    select category,count(*) total,
      count(*) filter(where retain_until<=now()) review_due,
      min(retain_until) filter(where retain_until>now()) next_review_at
    from deadlines group by category
  ) select coalesce(jsonb_object_agg(category,jsonb_build_object('total',total,'review_due',review_due,'next_review_at',next_review_at)),'{}') into v from totals;
  return jsonb_build_object('years',10,'basis_event','criacao','automatic_deletion',false,
    'categories',v,'backup_provider_configured',false,
    'offline_scope','Fila não sincronizada no aparelho; após envio, guarda junto da ME. Cache de acesso não é arquivo.');
end; $$;
revoke all on function public.additional_retention_summary() from public, anon;
grant execute on function public.additional_retention_summary() to authenticated;
commit;
