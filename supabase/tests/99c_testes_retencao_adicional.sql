\set ON_ERROR_STOP 1
begin;
select testes.igual(public.retention_created_until('2024-02-29 15:00:00+00'),'2034-02-28 15:00:00+00'::timestamptz,'anos civis, não 3650 dias');
select id as employee from public.employees where active limit 1 \gset
insert into public.employee_faces(employee_id,descriptor,source,created_at)
values(:'employee',array_fill(0.1::real,array[128]),'camera','2024-02-29 15:00:00+00') returning id as face \gset
select testes.falha(format('update public.employee_faces set created_at=now() where id=%s',:face),'Modelo facial imutável');
update public.employees set active=false where id=:'employee';
select testes.igual((select count(*) from public.employee_faces where id=:face)::int,0,'inativo fora da base de reconhecimento');
select testes.igual((select created_at from public.employee_faces_archive where original_id=:face),'2024-02-29 15:00:00+00'::timestamptz,'inativação arquiva com data original');
select testes.falha(format('delete from public.employee_faces_archive where original_id=%s',:face),'Arquivo de retenção protegido');
select testes.falha('truncate public.employee_faces_archive','Arquivo de retenção protegido');
insert into public.audit_logs(occurred_at,action,entity,category) values(now()-interval '9 years','retencao.fixture','fixture','privacidade') returning id as recent \gset
insert into public.audit_logs(occurred_at,action,entity,category) values(now()-interval '11 years','retencao.fixture','fixture','privacidade') returning id as old \gset
select testes.igual(exists(select 1 from public._purge_candidates('privacidade',current_date) x where x=:recent),false,'piso de dez anos independe do corte solicitado');
select testes.igual(exists(select 1 from public._purge_candidates('privacidade',current_date) x where x=:old),true,'evento vencido elegível para procedimento de revisão');
select id as open_me from public.stock_movements where status not in ('concluida','cancelada') limit 1 \gset
insert into public.audit_logs(occurred_at,action,entity,category,movement_id)
values(now()-interval '11 years','retencao.fixture','fixture','privacidade',:'open_me') returning id as linked \gset
select testes.igual(exists(select 1 from public._purge_candidates('privacidade',current_date) x where x=:linked),false,'log antigo de ME aberta não pode ser descartado');
insert into public.face_attempts(result) values('sem_rosto') returning id as attempt \gset
select testes.falha(format('delete from public.face_attempts where id=%s',:attempt),'10 anos');
set local role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-00000000000a',true);
select testes.falha('select descriptor from public.employee_faces_archive','permission denied');
select testes.igual((public.additional_retention_summary()->>'years')::int,10,'admin AAL2 consulta resumo');
select testes.falha($$select public.register_retention_backup('x',repeat('a',64),now(),'banco')$$,'permission denied');
select set_config('request.jwt.claims','{"aal":"aal1"}',true);
select testes.falha('select public.additional_retention_summary()','Somente administrador');
reset role;
set local role service_role;
select public.register_retention_backup('fixture-backup',repeat('a',64),now(),'banco_e_storage');
reset role;
select testes.igual((select count(*) from public.retention_backups where object_name='fixture-backup')::int,1,'backup registrado somente após geração');
rollback;
select '>>> TESTES DE RETENÇÃO ADICIONAL PASSARAM' as resultado;
