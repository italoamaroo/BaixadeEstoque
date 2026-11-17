-- Contrato fixo, local de aplicação "-" e ME emergencial (somente controle)
\set ON_ERROR_STOP 1
set client_min_messages = warning;
select id as mur from public.warehouses where code = 'MUR' \gset
select id as contrato from public.contracts where code = 'DEMO-CT-001' \gset
select id as setor from public.sectors where code = 'DEMO-SET-MAN' \gset
select id as func1 from public.employees where registration = 'DEMO-1001' \gset
select id as oleo, qr_code as oleo_qr from public.materials where code = 'DEMO-0001' \gset
select extract(year from now() at time zone 'America/Recife')::int as ano \gset
\set e1 'e3e3e3e3-0000-4000-8000-000000000001'
\set e2 'e3e3e3e3-0000-4000-8000-000000000002'
\set e3 'e3e3e3e3-0000-4000-8000-000000000003'
\set e4 'e3e3e3e3-0000-4000-8000-000000000004'

-- Administrador define o contrato padrão (fixo)
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', true);
select testes.falha($$select public.update_settings('{"default_contract_id":"00000000-0000-4000-8000-000000000000"}')$$, 'Contrato padrão inválido');
select testes.igual((public.update_settings(format('{"default_contract_id":"%s","require_approval":true}', :'contrato')::jsonb) ->> 'default_contract_id'), :'contrato', 'contrato padrão gravado');
commit;
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000a1', true);
select testes.falha($$select public.update_settings('{"default_contract_id":null}')$$, 'Somente administrador');
commit;

-- Assistente: sem contrato e sem local -> usa contrato padrão e local "-"; emergencial nasce concluída
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000a1', true);
insert into storage.objects (bucket_id, name, owner, metadata) values
  ('assinaturas', 'MUR/' || :'ano' || '/' || :'e1' || '/a.png', auth.uid(), '{"size":100}'),
  ('assinaturas', 'MUR/' || :'ano' || '/' || :'e2' || '/a.png', auth.uid(), '{"size":100}');
select testes.falha(format($$select public.create_movement('{"id":"%s","warehouse_id":"%s","sector_id":"%s","requester_employee_id":"%s","emergency":true,"emergency_reason":"x","fixed_asset_text":"AF-1","items":[{"material_id":"%s","quantity_requested":1,"quantity_delivered":1}],"signature":{"storage_path":"MUR/%s/%s/a.png"}}')$$,
  :'e1', :'mur', :'setor', :'func1', :'oleo', :'ano', :'e1'), 'motivo da retirada emergencial');
select testes.igual((public.create_movement(format($${"id":"%s","warehouse_id":"%s","sector_id":"%s","requester_employee_id":"%s","emergency":true,
  "emergency_reason":"Quebra do caminhão à noite","fixed_asset_text":"AF-EMERG",
  "items":[{"material_id":"%s","quantity_requested":1,"quantity_delivered":1}],"signature":{"storage_path":"MUR/%s/%s/a.png"}}$$,
  :'e1', :'mur', :'setor', :'func1', :'oleo', :'ano', :'e1')::jsonb) ->> 'status'), 'concluida', 'emergencial já nasce concluída (mesmo com aprovação ligada)');
select testes.igual((select contract_id::text from public.stock_movements where id = :'e1'), :'contrato', 'contrato padrão aplicado');
select testes.igual((select application_location_text from public.stock_movements where id = :'e1'), '-', 'local de aplicação fixo "-"');
select testes.igual((select requires_sa from public.stock_movements where id = :'e1'), false, 'emergencial com ativo não exige SA');
select testes.igual((select is_emergency and completed_at is not null and sa_number is null from public.stock_movements where id = :'e1'), true, 'emergencial concluída sem SA');
select testes.igual((select emergency_reason from public.v_movements where id = :'e1'), 'Quebra do caminhão à noite', 'motivo visível na consulta');
-- Normal continua indo para aprovação/SA
select testes.igual((public.create_movement(format($${"id":"%s","warehouse_id":"%s","sector_id":"%s","requester_employee_id":"%s","fixed_asset_text":"AF-1",
  "items":[{"material_id":"%s","quantity_requested":1,"quantity_delivered":1}],"signature":{"storage_path":"MUR/%s/%s/a.png"}}$$,
  :'e2', :'mur', :'setor', :'func1', :'oleo', :'ano', :'e2')::jsonb) ->> 'status'), 'aguardando_aprovacao', 'ME normal segue o fluxo');
select testes.falha(format($$select public.inform_sa('%s', 'SA-999')$$, :'e1'), 'não');
select testes.falha(format($$select public.complete_movement('%s', 'DOC-1', null)$$, :'e1'), 'Somente MEs aguardando baixa');
commit;

-- Filtro "somente emergenciais"
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', true);
select testes.igual((select count(*) from public.v_movements v where public.movement_matches(v, '{"emergency":"sim"}', 'America/Recife'))::int, 1, 'filtro emergenciais');
select testes.igual((select count(*) from public.v_movements v where public.movement_matches(v, '{"emergency":"nao"}', 'America/Recife') and v.id = :'e1')::int, 0, 'filtro normais exclui emergencial');
select testes.igual((public.export_movements('{"emergency":"sim"}', 'resumo') -> 0 ->> 'is_emergency'), 'true', 'Excel traz a marcação');
select public.update_settings('{"require_approval": false}');
commit;

-- Balcão: emergencial fica concluída na confirmação do solicitante
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000a1', true);
select testes.falha(format($$select public.counter_open('{"id":"%s","warehouse_id":"%s","sector_id":"%s","requester_employee_id":"%s","emergency":true}')$$,
  :'e3', :'mur', :'setor', :'func1'), 'motivo da retirada emergencial');
select public.counter_open(format($${"id":"%s","warehouse_id":"%s","sector_id":"%s","requester_employee_id":"%s","emergency":true,"emergency_reason":"Atendimento fora do horário"}$$,
  :'e3', :'mur', :'setor', :'func1')::jsonb) as aberta \gset
select testes.igual((select contract_id::text || '|' || application_location_text from public.stock_movements where id = :'e3'), :'contrato' || '|-', 'balcão usa contrato fixo e local "-"');
select public.counter_add(format($${"movement_id":"%s","scan_id":"%s","code":"%s"}$$, :'e3', gen_random_uuid(), :'oleo_qr')::jsonb);
select public.counter_finish(:'e3');
commit;
select (:'aberta'::jsonb ->> 'pairing_code') as codigo \gset
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000e1', true);
select public.counter_pair(:'codigo');
insert into storage.objects (bucket_id, name, owner, metadata) values
  ('assinaturas', 'MUR/' || :'ano' || '/' || :'e3' || '/s.png', auth.uid(), '{"size":100}');
select testes.igual((public.counter_confirm(:'e3', format($${"method":"assinatura","signature_path":"MUR/%s/%s/s.png","photo_skipped_reason":"teste"}$$, :'ano', :'e3')::jsonb) ->> 'status'),
  'concluida', 'balcão emergencial concluída na confirmação');
commit;
select testes.igual((select completed_at is not null and completed_by = storekeeper_id and sa_number is null from public.stock_movements where id = :'e3'), true, 'conclusão registrada sem SA/ERP');
select testes.igual((select count(*) from public.audit_logs where entity_id = :'e3' and action = 'me.confirmacao_registrada' and (new_data ->> 'emergencial')::boolean)::int, 1, 'auditoria marca emergencial');

\echo '>>> TESTES DE ME EMERGENCIAL E CONTRATO FIXO PASSARAM'
