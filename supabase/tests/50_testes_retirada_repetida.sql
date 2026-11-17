-- Alerta de retirada repetida: mesmo ativo + mesmo material em até 7 dias
\set ON_ERROR_STOP 1
set client_min_messages = warning;
select id as mur from public.warehouses where code = 'MUR' \gset
select id as contrato from public.contracts where code = 'DEMO-CT-001' \gset
select id as setor from public.sectors where code = 'DEMO-SET-MAN' \gset
select id as func1 from public.employees where registration = 'DEMO-1001' \gset
select id as oleo from public.materials where code = 'DEMO-0001' \gset
select id as filtro from public.materials where code = 'DEMO-0002' \gset
select extract(year from now() at time zone 'America/Recife')::int as ano \gset
\set r1 'a7a70000-0000-4000-8000-000000000001'
\set r2 'a7a70000-0000-4000-8000-000000000002'
\set r3 'a7a70000-0000-4000-8000-000000000003'

begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000a1', true);
insert into storage.objects (bucket_id, name, owner, metadata)
select 'assinaturas', 'MUR/' || :'ano' || '/' || x || '/a.png', auth.uid(), '{"size":100}'
  from unnest(array[:'r1', :'r2', :'r3']) x;
select public.create_movement(format($${"id":"%s","warehouse_id":"%s","contract_id":"%s","sector_id":"%s","requester_employee_id":"%s","fixed_asset_text":"af-777",
  "items":[{"material_id":"%s","quantity_requested":2,"quantity_delivered":2}],"signature":{"storage_path":"MUR/%s/%s/a.png"}}$$,
  :'r1', :'mur', :'contrato', :'setor', :'func1', :'oleo', :'ano', :'r1')::jsonb);
select public.create_movement(format($${"id":"%s","warehouse_id":"%s","contract_id":"%s","sector_id":"%s","requester_employee_id":"%s","fixed_asset_text":"AF-777",
  "items":[{"material_id":"%s","quantity_requested":1,"quantity_delivered":1},{"material_id":"%s","quantity_requested":1,"quantity_delivered":1}],"signature":{"storage_path":"MUR/%s/%s/a.png"}}$$,
  :'r2', :'mur', :'contrato', :'setor', :'func1', :'oleo', :'filtro', :'ano', :'r2')::jsonb);
-- outro ativo, mesmo material: não conta
select public.create_movement(format($${"id":"%s","warehouse_id":"%s","contract_id":"%s","sector_id":"%s","requester_employee_id":"%s","fixed_asset_text":"AF-888",
  "items":[{"material_id":"%s","quantity_requested":1,"quantity_delivered":1}],"signature":{"storage_path":"MUR/%s/%s/a.png"}}$$,
  :'r3', :'mur', :'contrato', :'setor', :'func1', :'oleo', :'ano', :'r3')::jsonb);
commit;

begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', true);
select public.repeat_asset_withdrawals('{}'::jsonb, 7) as rep \gset
select testes.igual((select count(*) from jsonb_array_elements(:'rep'::jsonb -> 'items') e where e ->> 'asset' = 'AF-777')::int, 1, 'detecta mesmo ativo + mesmo material');
select testes.igual((select (e ->> 'times')::int from jsonb_array_elements(:'rep'::jsonb -> 'items') e where e ->> 'asset' = 'AF-777'), 2, 'duas retiradas');
select testes.igual((select (e ->> 'total_qty')::numeric from jsonb_array_elements(:'rep'::jsonb -> 'items') e where e ->> 'asset' = 'AF-777'), 3::numeric, 'soma das quantidades');
select testes.igual((select count(*) from jsonb_array_elements(:'rep'::jsonb -> 'items') e where e ->> 'asset' = 'AF-888')::int, 0, 'outro ativo não entra');
select testes.igual((select count(*) from jsonb_array_elements(:'rep'::jsonb -> 'items') e where e ->> 'material_code' = 'DEMO-0002' and e ->> 'asset' = 'AF-777')::int, 0, 'material retirado uma vez não entra');
select testes.falha($$select public.repeat_asset_withdrawals('{}', 0)$$, 'janela deve ser');
commit;
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000a1', true);
select testes.falha($$select public.repeat_asset_withdrawals('{}', 7)$$, 'Somente gestor ou administrador');
commit;
-- cancelando uma das MEs o alerta some
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', true);
select public.cancel_movement(:'r1', 'Teste do alerta de repetição');
select testes.igual((select count(*) from jsonb_array_elements(public.repeat_asset_withdrawals('{}', 7) -> 'items') e where e ->> 'asset' = 'AF-777')::int, 0, 'ME cancelada não conta');
commit;
\echo '>>> TESTES DE RETIRADA REPETIDA POR ATIVO PASSARAM'
