-- Saída registrada sem internet (enviada depois)
\set ON_ERROR_STOP 1
set client_min_messages = warning;
select id as mur from public.warehouses where code = 'MUR' \gset
select id as contrato from public.contracts where code = 'DEMO-CT-001' \gset
select id as setor from public.sectors where code = 'DEMO-SET-MAN' \gset
select id as func1 from public.employees where registration = 'DEMO-1001' \gset
select id as oleo from public.materials where code = 'DEMO-0001' \gset
select (now() - interval '2 days') as quando \gset
select extract(year from (:'quando'::timestamptz at time zone 'America/Recife'))::int as ano \gset
\set o1 '0ff10000-0000-4000-8000-000000000001'
\set o2 '0ff10000-0000-4000-8000-000000000002'

begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000a1', true);
insert into storage.objects (bucket_id, name, owner, metadata) values
  ('assinaturas', 'MUR/' || :'ano' || '/' || :'o1' || '/a.png', auth.uid(), '{"size":100}'),
  ('assinaturas', 'MUR/' || :'ano' || '/' || :'o2' || '/a.png', auth.uid(), '{"size":100}');
select public.create_movement(format($${"id":"%s","warehouse_id":"%s","contract_id":"%s","sector_id":"%s","requester_employee_id":"%s","offline_at":"%s",
  "items":[{"material_id":"%s","quantity_requested":1,"quantity_delivered":1}],"signature":{"storage_path":"MUR/%s/%s/a.png","signed_at":"%s"}}$$,
  :'o1', :'mur', :'contrato', :'setor', :'func1', :'quando', :'oleo', :'ano', :'o1', :'quando')::jsonb) as r1 \gset
select testes.igual((select entry_channel from public.stock_movements where id = :'o1'), 'offline', 'canal offline registrado');
select testes.igual((select abs(extract(epoch from movement_at - :'quando'::timestamptz)) < 1 from public.stock_movements where id = :'o1'), true, 'data real da retirada preservada');
select testes.igual((select created_at > movement_at + interval '1 day' from public.stock_movements where id = :'o1'), true, 'data de envio separada');
select testes.igual((public.create_movement(format($${"id":"%s","warehouse_id":"%s","contract_id":"%s","sector_id":"%s","requester_employee_id":"%s","offline_at":"%s",
  "items":[{"material_id":"%s","quantity_requested":1,"quantity_delivered":1}],"signature":{"storage_path":"MUR/%s/%s/a.png"}}$$,
  :'o1', :'mur', :'contrato', :'setor', :'func1', :'quando', :'oleo', :'ano', :'o1')::jsonb) ->> 'me_number'), (:'r1'::jsonb ->> 'me_number'), 'reenvio da fila não duplica');
select testes.falha(format($$select public.create_movement('{"id":"%s","warehouse_id":"%s","contract_id":"%s","sector_id":"%s","requester_employee_id":"%s","offline_at":"%s","items":[{"material_id":"%s","quantity_requested":1,"quantity_delivered":1}],"signature":{"storage_path":"MUR/%s/%s/a.png"}}')$$,
  :'o2', :'mur', :'contrato', :'setor', :'func1', (now() - interval '10 days'), :'oleo', :'ano', :'o2'), 'fora do prazo');
commit;
\echo '>>> TESTES DE SAÍDA OFFLINE PASSARAM'
