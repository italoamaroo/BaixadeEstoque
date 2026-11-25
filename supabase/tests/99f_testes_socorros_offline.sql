-- Socorro capturado sem internet: data original, espera do retorno e reenvio idempotente.
\set ON_ERROR_STOP 1
select id as mur from public.warehouses where code='MUR' \gset
select id as contrato from public.contracts where code='DEMO-CT-001' \gset
select id as setor from public.sectors where code='DEMO-SET-MAN' \gset
select id as func from public.employees where registration='DEMO-1001' \gset
select id as mat from public.materials where code='DEMO-0001' \gset
select extract(year from now() at time zone 'America/Recife')::int as ano \gset
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-0000000000a1',true);
insert into storage.objects(bucket_id,name,owner,metadata) values ('assinaturas','MUR/'||:'ano'||'/a5a50000-0000-4000-8000-000000000001/offline.png',auth.uid(),'{"size":100}');
select jsonb_build_object('id','a5a50000-0000-4000-8000-000000000001','rescue',true,'emergency',false,'warehouse_id',:'mur','contract_id',:'contrato','sector_id',:'setor','requester_employee_id',:'func','fixed_asset_text','TESTE-SOC-OFF',
'offline_at',now()-interval '2 hours',
'items',jsonb_build_array(jsonb_build_object('material_id',:'mat','quantity_requested',5,'quantity_delivered',5)),
'signature',jsonb_build_object('storage_path','MUR/'||:'ano'||'/a5a50000-0000-4000-8000-000000000001/offline.png','signed_at',now()-interval '2 hours')) as payload \gset
select testes.igual(public.create_movement(:'payload'::jsonb)->>'status','aguardando_retorno','socorro offline espera retorno');
select testes.igual((select is_rescue and not is_emergency and movement_at=now()-interval '2 hours' and sa_number is null and completed_at is null from public.stock_movements where id='a5a50000-0000-4000-8000-000000000001'),true,'tipo, horário original e bloqueio de lançamento preservados');
select testes.igual(public.create_movement(:'payload'::jsonb)->>'created','false','retentativa devolve ME existente');
select testes.igual((select count(*)::int from public.stock_movements where id='a5a50000-0000-4000-8000-000000000001'),1,'sem duplicação após repetir envio offline');
select testes.igual((select count(*)::int from public.stock_movement_items where movement_id='a5a50000-0000-4000-8000-000000000001'),1,'sem duplicação de itens');
select testes.falha(format($$select public.create_movement(%L::jsonb || '{"offline_at":"2000-01-01T00:00:00Z"}'::jsonb)$$,:'payload'),'fora do prazo');
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-0000000000b1',true);
select testes.igual((select count(*)::int from public.v_movements where id='a5a50000-0000-4000-8000-000000000001'),0,'SA não recebe socorro offline sem retorno conferido');
rollback;
select '>>> TESTES SOCORROS OFFLINE PASSARAM';
