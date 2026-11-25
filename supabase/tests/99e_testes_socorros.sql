\set ON_ERROR_STOP 1
select id as mur from public.warehouses where code='MUR' \gset
select id as contrato from public.contracts where code='DEMO-CT-001' \gset
select id as setor from public.sectors where code='DEMO-SET-MAN' \gset
select id as func from public.employees where registration='DEMO-1001' \gset
select id as mat from public.materials where code='DEMO-0001' \gset
select extract(year from now() at time zone 'America/Recife')::int as ano \gset
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-00000000000a',true);
select public.update_settings('{"require_approval":false}');
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-0000000000a1',true);
-- Três saídas reais no ambiente descartável: parcial, integral e nenhuma utilização.
insert into storage.objects(bucket_id,name,owner,metadata)
select 'assinaturas','MUR/'||:'ano'||'/'||id||'/a.png',auth.uid(),'{"size":100}'::jsonb
from unnest(array['f1f10000-0000-4000-8000-000000000001','f1f10000-0000-4000-8000-000000000002','f1f10000-0000-4000-8000-000000000003']) id;
select public.create_movement(jsonb_build_object('id',id,'rescue',true,'warehouse_id',:'mur','contract_id',:'contrato','sector_id',:'setor','requester_employee_id',:'func','fixed_asset_text','SOC-TESTE',
'items',jsonb_build_array(jsonb_build_object('material_id',:'mat','quantity_requested',5,'quantity_delivered',5)),
'signature',jsonb_build_object('storage_path','MUR/'||:'ano'||'/'||id||'/a.png')))
from unnest(array['f1f10000-0000-4000-8000-000000000001','f1f10000-0000-4000-8000-000000000002','f1f10000-0000-4000-8000-000000000003']) id;
select testes.igual((select status::text from public.stock_movements where id='f1f10000-0000-4000-8000-000000000001'),'aguardando_retorno','socorro aguarda retorno');
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-00000000000a',true);
select testes.falha($$select public.inform_sa('f1f10000-0000-4000-8000-000000000001','12345',null)$$,'aguardando_retorno');
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-0000000000a1',true);
select testes.falha($$select public.rescue_return('f1f10000-0000-4000-8000-000000000001','[]','conferido')$$,'todos os itens');
select testes.falha($$select public.rescue_return('f1f10000-0000-4000-8000-000000000001',(select jsonb_agg(jsonb_build_object('id',id,'used',6)) from public.stock_movement_items where movement_id='f1f10000-0000-4000-8000-000000000001'),'conferido')$$,'Utilizado deve');
-- Quantidades inválidas não deixam atualização parcial.
select testes.igual((select total_delivered::int from public.stock_movements where id='f1f10000-0000-4000-8000-000000000001'),5,'falha não altera saída');
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-0000000000b1',true);
select testes.igual((select count(*)::int from public.v_movements where id='f1f10000-0000-4000-8000-000000000001'),0,'equipe SA não recebe antes do retorno');
select testes.falha($$select public.rescue_return('f1f10000-0000-4000-8000-000000000001','[]','conferido')$$,'Perfil sem permissão');
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-0000000000a2',true);
select testes.falha($$select public.rescue_return('f1f10000-0000-4000-8000-000000000001','[]','conferido')$$,'sem acesso');
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-0000000000a1',true);
select public.rescue_return('f1f10000-0000-4000-8000-000000000001',(select jsonb_agg(jsonb_build_object('id',id,'used',2)) from public.stock_movement_items where movement_id='f1f10000-0000-4000-8000-000000000001'),'Conferido com mecânico: 2 utilizados e 3 recebidos de volta.');
select testes.igual((select rescue_quantity_out=5 and quantity_delivered=2 and rescue_quantity_returned=3 from public.stock_movement_items where movement_id='f1f10000-0000-4000-8000-000000000001'),true,'parcial preserva retirada e devolução');
select testes.igual((select status::text from public.stock_movements where id='f1f10000-0000-4000-8000-000000000001'),'aguardando_sa','parcial segue SA somente após retorno');
select testes.falha($$select public.rescue_return('f1f10000-0000-4000-8000-000000000001','[]','repetição')$$,'já foi conferido');
select public.rescue_return('f1f10000-0000-4000-8000-000000000002',(select jsonb_agg(jsonb_build_object('id',id,'used',5)) from public.stock_movement_items where movement_id='f1f10000-0000-4000-8000-000000000002'),'Conferido com mecânico: utilizado tudo.');
select public.rescue_return('f1f10000-0000-4000-8000-000000000003',(select jsonb_agg(jsonb_build_object('id',id,'used',0)) from public.stock_movement_items where movement_id='f1f10000-0000-4000-8000-000000000003'),'Conferido com mecânico: devolução total.');
select testes.igual((select status='concluida' and completed_at is not null and total_delivered=0 from public.stock_movements where id='f1f10000-0000-4000-8000-000000000003'),true,'sem consumo encerra preservando ME');
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-0000000000b1',true);
select testes.igual((select count(*)::int from public.v_movements where id='f1f10000-0000-4000-8000-000000000001'),1,'equipe SA recebe após conferência');
rollback;
select '>>> TESTES SOCORROS PASSARAM';

-- Retirada pelo balcão também aguarda retorno depois da assinatura do solicitante.
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-0000000000a1',true);
select public.counter_open(jsonb_build_object('id','f1f10000-0000-4000-8000-000000000004','rescue',true,'warehouse_id',:'mur','contract_id',:'contrato','sector_id',:'setor','requester_employee_id',:'func','fixed_asset_text','SOC-BALCAO')) as aberta \gset
select public.counter_add(jsonb_build_object('movement_id','f1f10000-0000-4000-8000-000000000004','scan_id',gen_random_uuid(),'code',(select qr_code from public.materials where id=:'mat')));
select public.counter_finish('f1f10000-0000-4000-8000-000000000004');
commit;
select (:'aberta'::jsonb->>'pairing_code') as codigo \gset
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-0000000000e1',true);
select public.counter_pair(:'codigo');
insert into storage.objects(bucket_id,name,owner,metadata) values ('assinaturas','MUR/'||:'ano'||'/f1f10000-0000-4000-8000-000000000004/s.png',auth.uid(),'{"size":100}');
select testes.igual((public.counter_confirm('f1f10000-0000-4000-8000-000000000004',jsonb_build_object('method','assinatura','signature_path','MUR/'||:'ano'||'/f1f10000-0000-4000-8000-000000000004/s.png','photo_skipped_reason','simulação técnica')) ->>'status'),'aguardando_retorno','socorro no balcão aguarda retorno');
commit;
select '>>> TESTE SOCORRO BALCÃO PASSOU';
