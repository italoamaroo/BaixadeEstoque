\set ON_ERROR_STOP 1
select id as mur from public.warehouses where code='MUR' \gset
select id as contrato from public.contracts where code='DEMO-CT-001' \gset
select id as setor from public.sectors where code='DEMO-SET-MAN' \gset
select id as func from public.employees where registration='DEMO-1001' \gset
select id as mat,qr_code as qr from public.materials where code='DEMO-0001' \gset
select extract(year from now() at time zone 'America/Recife')::int as ano \gset
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-0000000000a1',true);
select public.counter_open(jsonb_build_object('id','b6b60000-0000-4000-8000-000000000001','warehouse_id',:'mur','contract_id',:'contrato','sector_id',:'setor','requester_employee_id',:'func','rescue',true,'fixed_asset_text','TESTE-TABLET-OFF')) as aberta \gset
select public.counter_add(jsonb_build_object('movement_id','b6b60000-0000-4000-8000-000000000001','scan_id',gen_random_uuid(),'code',:'qr','quantity',5));
select public.counter_finish('b6b60000-0000-4000-8000-000000000001');
commit;
-- Preparo antigo para verificar que a assinatura conserva o horário real informado pelo aparelho.
update public.stock_movements set separation_finished_at=now()-interval '3 hours' where id='b6b60000-0000-4000-8000-000000000001';
select (:'aberta'::jsonb->>'pairing_code') as codigo \gset
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-0000000000e1',true);
select public.counter_pair(:'codigo');
select public.counter_snapshot('b6b60000-0000-4000-8000-000000000001') as snap \gset
select testes.igual((:'snap'::jsonb->'session'->>'offline_ready')::boolean,true,'tablet recebe capacidade offline após migração');
select testes.igual((:'snap'::jsonb->'movement'->>'is_rescue')::boolean,true,'tipo socorro chega ao tablet');
insert into storage.objects(bucket_id,name,owner,metadata) values('assinaturas','MUR/'||:'ano'||'/b6b60000-0000-4000-8000-000000000001/offline.png',auth.uid(),'{"size":100}');
select jsonb_build_object('request_id','b6b60000-0000-4000-8000-000000000002','signed_at',now()-interval '2 hours',
 'version',:'snap'::jsonb->'session'->'version','separation_finished_at',:'snap'::jsonb->'movement'->'separation_finished_at',
 'items',:'snap'::jsonb->'items',
 'signature_path','MUR/'||:'ano'||'/b6b60000-0000-4000-8000-000000000001/offline.png','photo_skipped_reason','Câmera indisponível no teste local') as payload \gset
select testes.falha(format($$select public.counter_confirm_offline('b6b60000-0000-4000-8000-000000000001',%L::jsonb || jsonb_build_object('version',99999))$$,:'payload'),'autorização ou lista mudou');
select testes.falha(format($$select public.counter_confirm_offline('b6b60000-0000-4000-8000-000000000001',jsonb_set(%L::jsonb,'{items,0,quantity_delivered}','99'))$$,:'payload'),'quantidades diferem');
select testes.falha(format($$select public.counter_confirm_offline('b6b60000-0000-4000-8000-000000000001',%L::jsonb || '{"signed_at":"2000-01-01T00:00:00Z"}')$$,:'payload'),'fora do período');
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-0000000000e2',true);
select testes.falha(format($$select public.counter_confirm_offline('b6b60000-0000-4000-8000-000000000001',%L::jsonb)$$,:'payload'),'Tablet não pareado');
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-0000000000e1',true);
select testes.igual((public.counter_confirm_offline('b6b60000-0000-4000-8000-000000000001',:'payload'::jsonb)->>'status'),'aguardando_retorno','confirmação offline conclui recebimento e socorro aguarda retorno');
select testes.igual((public.counter_confirm_offline('b6b60000-0000-4000-8000-000000000001',:'payload'::jsonb)->>'repetida')::boolean,true,'reenvio é idempotente');
select testes.igual((select count(*)::int from public.counter_offline_receipts where movement_id='b6b60000-0000-4000-8000-000000000001'),1,'um único comprovante');
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-00000000000a',true);
select testes.igual((select signed_at=now()-interval '2 hours' from public.signatures where movement_id='b6b60000-0000-4000-8000-000000000001' and is_current),true,'horário de assinatura preservado');
select testes.igual((select count(*)::int from public.signatures where movement_id='b6b60000-0000-4000-8000-000000000001'),1,'assinatura não duplicada');
rollback;
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-0000000000a1',true);
select testes.falha($$select public.counter_confirm_offline('b6b60000-0000-4000-8000-000000000001','{}')$$,'Somente terminal ativo');
rollback;
select '>>> TESTES TABLET OFFLINE PASSARAM';
