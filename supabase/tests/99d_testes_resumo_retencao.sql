\set ON_ERROR_STOP 1
begin;
-- Confere o resultado otimizado contra a regra original, incluindo fuso e bissextos.
insert into public.face_attempts(result,created_at) values
 ('sem_rosto','2024-02-29 15:00:00+00'),('sem_rosto','2000-01-01 12:00:00+00');
with records as (
 select 'cadastros_faciais' category,created_at from public.employee_faces
 union all select 'cadastros_faciais',created_at from public.employee_faces_archive
 union all select 'logs',occurred_at from public.audit_logs where purged_at is null and movement_id is null
 union all select 'tentativas_faciais',created_at from public.face_attempts
 union all select 'falhas_login_legadas',window_start from public.auth_login_failures
 union all select 'backups',created_at from public.retention_backups
), totals as (
 select category,count(*) total,
  count(*) filter(where public.retention_created_until(created_at)<=now()) review_due,
  min(public.retention_created_until(created_at)) filter(where public.retention_created_until(created_at)>now()) next_review_at
 from records group by category
)
select coalesce(jsonb_object_agg(category,jsonb_build_object('total',total,'review_due',review_due,'next_review_at',next_review_at)),'{}') as expected from totals \gset
set local role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-00000000000a',true);
select testes.igual(public.additional_retention_summary()->'categories',:'expected'::jsonb,'mesmas contagens e prazos que a regra original');
select testes.igual((public.additional_retention_summary()->>'automatic_deletion')::boolean,false,'sem exclusão automática');
select set_config('request.jwt.claims','{"aal":"aal1"}',true);
select testes.falha('select public.additional_retention_summary()','Somente administrador');
reset role;
select testes.igual(has_function_privilege('anon','public.additional_retention_summary()','execute'),false,'acesso anônimo continua revogado');
rollback;
select '>>> RESUMO OTIMIZADO DE RETENÇÃO PASSOU' as resultado;
