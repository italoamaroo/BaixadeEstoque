\set ON_ERROR_STOP 1
begin;
-- Somente fixture de banco local. Todas as alterações são revertidas.
select id as me from public.stock_movements where status='concluida' limit 1 \gset
select set_config('app.internal_totals','on',true);
update public.stock_movements set status='concluida',completed_at='2024-02-29 15:00:00+00' where id=:'me';
set local role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-00000000000a',true);
select testes.igual((public.movement_retention_status(:'me')->>'years')::int,10,'guarda dez anos');
select testes.igual((public.movement_retention_status(:'me')->>'retain_until')::timestamptz,'2034-02-28 15:00:00+00'::timestamptz,'dez anos civis desde conclusão, incluindo bissexto');
select testes.igual(public.movement_retention_status(:'me')->>'basis_event','conclusao'::text,'marco de conclusão');
select testes.igual((public.movement_retention_status(:'me')->>'automatic_deletion')::boolean,false,'sem exclusão automática');
reset role;
update public.stock_movements set status='cancelada',cancelled_at='2030-06-01 12:00:00+00',cancelled_by='00000000-0000-0000-0000-00000000000a',cancel_reason='Fixture de cancelamento' where id=:'me';
set local role authenticated;
select testes.igual(public.movement_retention_status(:'me')->>'basis_event','cancelamento'::text,'cancelamento prevalece sobre conclusão anterior');
select testes.igual((public.movement_retention_status(:'me')->>'retain_until')::timestamptz,'2040-06-01 12:00:00+00'::timestamptz,'dez anos desde cancelamento');
reset role;
update public.stock_movements set status='concluida',completed_at=null where id=:'me';
set local role authenticated;
select testes.igual(public.movement_retention_status(:'me')->>'state','data_de_encerramento_ausente'::text,'não inventar data ausente');
select testes.igual(public.movement_retention_status(:'me')->>'retain_until',null::text,'sem data não calcula fim');
reset role;
update public.stock_movements set status='rascunho' where id=:'me';
set local role authenticated;
select testes.igual(public.movement_retention_status(:'me')->>'state','aguardando_encerramento'::text,'ME aberta não inicia contagem');
reset role;
update public.stock_movements set status='concluida',completed_at='2004-01-01 12:00:00+00' where id=:'me';
set local role authenticated;
select testes.igual(public.movement_retention_status(:'me')->>'state','revisao_pendente'::text,'prazo cumprido exige revisão');
select testes.igual((public.movement_retention_summary()->>'review_due')::int>=1,true,'resumo conta prazo cumprido');
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-0000000000d1',true);
select testes.falha(format('select public.movement_retention_status(%L)',:'me'),'acesso não permitido');
select testes.falha('select public.movement_retention_summary()','Somente gestor');
rollback;
select '>>> TESTES DE RETENÇÃO DE MES PASSARAM' as resultado;
