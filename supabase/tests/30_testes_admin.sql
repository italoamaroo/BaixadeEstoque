-- Testes complementares: parâmetros, aprovação, importação e QR Code
\set ON_ERROR_STOP 1
set client_min_messages = warning;
select id as mur from public.warehouses where code = 'MUR' \gset
select id as contrato from public.contracts where code = 'DEMO-CT-001' \gset
select id as setor from public.sectors where code = 'DEMO-SET-MAN' \gset
select id as func1 from public.employees where registration = 'DEMO-1001' \gset
select id as oleo from public.materials where code = 'DEMO-0001' \gset
\set me4 '44444444-4444-4444-8444-444444444444'
select extract(year from now() at time zone 'America/Recife')::int as ano \gset

begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', true);
select testes.falha($$select public.update_settings('{"sa_number_pattern":"(["}')$$, 'inválida');
select (public.update_settings('{"require_approval":true}') ->> 'require_approval') as ok \gset
select testes.igual(:'ok'::text, 'true', 'parâmetro de aprovação ativado');
select public.import_materials('[{"code":"imp-1","name":"Material importado","unit":"un"},{"code":"","name":"x","unit":"UN"},{"code":"IMP-2","name":"Outro","unit":"UN","account_code":"NAO-EXISTE"}]') as imp \gset
select testes.igual((:'imp'::jsonb ->> 'inseridos')::int, 1, 'importação insere linha válida');
select testes.igual(jsonb_array_length(:'imp'::jsonb -> 'erros'), 2, 'importação relata linhas com erro');
select testes.igual((select qr_code like 'MAT-%' from public.materials where code = 'IMP-1'), true, 'QR Code gerado automaticamente');
select public.regenerate_material_qr((select id from public.materials where code = 'IMP-1')) as novo \gset
select testes.igual((select count(*) from public.material_qr_codes q join public.materials m on m.id = q.material_id where m.code = 'IMP-1')::int, 2, 'histórico de QR Codes');
select testes.igual((public.find_material_by_code(:'novo') -> 'material' ->> 'code'), 'IMP-1', 'novo QR localiza material');
commit;

begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000a1', true);
insert into storage.objects (bucket_id, name, owner, metadata)
values ('assinaturas', 'MUR/' || :'ano' || '/' || :'me4' || '/assinatura_1.png', auth.uid(), '{"size": 100}');
select public.create_movement(format($${"id":"%s","warehouse_id":"%s","contract_id":"%s","sector_id":"%s","requester_employee_id":"%s",
  "items":[{"material_id":"%s","quantity_requested":1,"quantity_delivered":1}],"signature":{"storage_path":"MUR/%s/%s/assinatura_1.png"}}$$,
  :'me4', :'mur', :'contrato', :'setor', :'func1', :'oleo', :'ano', :'me4')::jsonb) ->> 'status' as st \gset
select testes.igual(:'st'::text, 'aguardando_aprovacao', 'com aprovação ativa, ME aguarda aprovação');
select testes.falha(format($$select public.approve_movement('%s')$$, :'me4'), 'Somente gestor');
commit;

begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000b1', true);
select testes.falha(format($$select public.inform_sa('%s', 'SA-APR-1')$$, :'me4'), 'Não é possível informar SA');
commit;

begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000c1', true);
select testes.igual((public.approve_movement(:'me4') ->> 'status'), 'aguardando_sa', 'gestor aprova ME');
select testes.igual((select approved_by from public.stock_movements where id = :'me4'), '00000000-0000-0000-0000-0000000000c1'::uuid, 'aprovador registrado');
commit;

update public.app_settings set require_approval = false where id = 1;
\echo '>>> TESTES DE ADMINISTRAÇÃO PASSARAM'

-- Cancelamento pelo almoxarife (devolução antes da SA)
\set me5 '55555555-5555-4555-8555-555555555555'
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000a1', true);
insert into storage.objects (bucket_id, name, owner, metadata)
values ('assinaturas', 'MUR/' || :'ano' || '/' || :'me5' || '/assinatura_1.png', auth.uid(), '{"size": 100}');
select public.create_movement(format($${"id":"%s","warehouse_id":"%s","contract_id":"%s","sector_id":"%s","requester_employee_id":"%s",
  "items":[{"material_id":"%s","quantity_requested":1,"quantity_delivered":1}],"signature":{"storage_path":"MUR/%s/%s/assinatura_1.png"}}$$,
  :'me5', :'mur', :'contrato', :'setor', :'func1', :'oleo', :'ano', :'me5')::jsonb);
select testes.falha(format($$select public.cancel_movement('%s', '')$$, :'me5'), 'justificativa');
select testes.igual((public.cancel_movement(:'me5', 'Devolução do material: sem uso') ->> 'status'), 'cancelada', 'almoxarife cancela ME aguardando SA (devolução)');
commit;

begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000a1', true);
-- me4 (do teste de aprovação) está aguardando SA; informa SA como equipe e tenta cancelar como almoxarife
commit;
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000b1', true);
select public.inform_sa(:'me4', 'SA-APR-0004');
commit;
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000a1', true);
select testes.falha(format($$select public.cancel_movement('%s', 'Devolução do material')$$, :'me4'), 'Somente gestor ou administrador');
commit;
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000a2', true);
select testes.falha(format($$select public.cancel_movement('%s', 'Devolução do material')$$, :'me4'), 'ME não encontrada');
commit;
\echo '>>> TESTES DE CANCELAMENTO PELO ALMOXARIFE PASSARAM'

-- Cadastros pelo almoxarife; equipe SA continua sem acesso
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000a1', true);
select testes.igual((public.import_materials('[{"code":"ALMOX-T1","name":"Item do almoxarife","unit":"UN"}]') ->> 'inseridos')::int, 1, 'almoxarife importa materiais');
select testes.igual((public.import_employees('[{"registration":"ALMOX-F1","full_name":"Funcionário almox"}]') ->> 'inseridos')::int, 1, 'almoxarife importa funcionários');
select testes.falha($$select public.update_settings('{"me_prefix":"XX"}')$$, 'Somente administrador');
commit;
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000b1', true);
select testes.falha($$insert into public.materials (code, name, unit) values ('SA-X1', 'Teste', 'UN')$$, 'row-level security');
select testes.falha($$select public.import_materials('[]')$$, 'Somente administrador ou almoxarife');
commit;
\echo '>>> TESTES DE CADASTRO PELO ALMOXARIFE PASSARAM'
