-- Testes do balcão de separação (leitor QR sem fio + tablet do solicitante)
\set ON_ERROR_STOP 1
set client_min_messages = warning;
select id as mur from public.warehouses where code = 'MUR' \gset
select id as dir from public.warehouses where code = 'DIR' \gset
select id as contrato from public.contracts where code = 'DEMO-CT-001' \gset
select id as setor from public.sectors where code = 'DEMO-SET-MAN' \gset
select id as func1 from public.employees where registration = 'DEMO-1001' \gset
select id as oleo, qr_code as oleo_qr from public.materials where code = 'DEMO-0001' \gset
select id as filtro from public.materials where code = 'DEMO-0002' \gset
select extract(year from now() at time zone 'America/Recife')::int as ano \gset
\set b1 'b1b1b1b1-0000-4000-8000-000000000001'
\set b2 'b1b1b1b1-0000-4000-8000-000000000002'
\set s1 '5c5c5c5c-0000-4000-8000-000000000001'
\set s2 '5c5c5c5c-0000-4000-8000-000000000002'

insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000000e1', 'tablet.mur@teste.local', '{"full_name":"Tablet Muribeca"}'),
  ('00000000-0000-0000-0000-0000000000e2', 'tablet.dir@teste.local', '{"full_name":"Tablet Dois Irmãos"}')
on conflict do nothing;

begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', true);
select public.update_settings('{"require_approval": false}');
select public.admin_set_user_access('00000000-0000-0000-0000-0000000000e1', 'Tablet Muribeca', '{terminal}', array[:'mur']::uuid[], true, :'mur');
select public.admin_set_user_access('00000000-0000-0000-0000-0000000000e2', 'Tablet Dois Irmãos', '{terminal}', array[:'dir']::uuid[], true, :'dir');
commit;

-- Almoxarife abre a separação
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000a1', true);
select public.counter_open(format($${"id":"%s","warehouse_id":"%s","contract_id":"%s","sector_id":"%s","requester_employee_id":"%s"}$$,
  :'b1', :'mur', :'contrato', :'setor', :'func1')::jsonb) as aberta \gset
select testes.igual((select status::text from public.stock_movements where id = :'b1'), 'rascunho', 'ME aberta em separação');
select testes.igual((:'aberta'::jsonb ->> 'pairing_code') ~ '^[0-9]{6}$', true, 'código de pareamento gerado');
select testes.igual((public.counter_open(format($${"id":"%s","warehouse_id":"%s","contract_id":"%s","sector_id":"%s","requester_employee_id":"%s"}$$,
  :'b1', :'mur', :'contrato', :'setor', :'func1')::jsonb) ->> 'created'), 'false', 'reenvio da abertura não duplica');
commit;
select (:'aberta'::jsonb ->> 'pairing_code') as codigo \gset

-- Tablets: o perfil terminal não enxerga MEs do estoque; só pareia no próprio estoque
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000e2', true);
select testes.falha(format($$select public.counter_pair('%s')$$, :'codigo'), 'não está liberado');
commit;
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000e1', true);
select testes.igual((select count(*) from public.stock_movements)::int, 0, 'terminal não lista MEs do estoque');
select testes.falha($$select public.counter_pair('000000')$$, 'inválido ou expirado');
select testes.igual((public.counter_pair(:'codigo') ->> 'movement_id'), :'b1', 'tablet pareado à ME');
select testes.igual((public.counter_snapshot() -> 'movement' ->> 'me_number') like 'ME-MUR-%', true, 'tablet vê a ME pareada');
select testes.igual((public.counter_snapshot() -> 'session' ->> 'pairing_code') is null, true, 'tablet não vê o código');
select testes.falha(format($$select public.counter_add('{"movement_id":"%s","scan_id":"%s","code":"X"}')$$, :'b1', gen_random_uuid()), 'ME não encontrada');
select testes.falha(format($$select public.counter_confirm('%s', '{"method":"assinatura"}')$$, :'b1'), 'ainda não foi finalizada');
commit;

-- Outro almoxarife não mexe na separação
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000a2', true);
select testes.falha(format($$select public.counter_add('{"movement_id":"%s","scan_id":"%s","code":"%s"}')$$, :'b1', gen_random_uuid(), :'oleo_qr'), 'ME não encontrada');
commit;

-- Bipagens
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000a1', true);
select testes.igual((public.counter_add(format($${"movement_id":"%s","scan_id":"%s","code":"%s"}$$, :'b1', :'s1', :'oleo_qr')::jsonb) ->> 'result'), 'incluido', 'leitura inclui material');
select testes.igual((public.counter_add(format($${"movement_id":"%s","scan_id":"%s","code":"%s"}$$, :'b1', :'s1', :'oleo_qr')::jsonb) ->> 'repetida'), 'true', 'mesma leitura reenviada não duplica');
select testes.igual((select count(*) from public.stock_movement_items where movement_id = :'b1')::int, 1, 'um item após reenvio');
select testes.igual((public.counter_add(format($${"movement_id":"%s","scan_id":"%s","code":"%s"}$$, :'b1', gen_random_uuid(), :'oleo_qr')::jsonb) ->> 'result'), 'ja_incluido', 'avisa item já incluído');
select testes.igual((public.counter_add(format($${"movement_id":"%s","scan_id":"%s","code":"%s","on_duplicate":"somar"}$$, :'b1', gen_random_uuid(), :'oleo_qr')::jsonb) ->> 'quantity_delivered')::numeric, 2::numeric, 'soma ao item existente');
select testes.igual((public.counter_add(format($${"movement_id":"%s","scan_id":"%s","code":"MAT-NAOEXISTE"}$$, :'b1', gen_random_uuid())::jsonb) ->> 'result'), 'nao_encontrado', 'QR não encontrado');
select testes.igual((public.counter_add(format($${"movement_id":"%s","scan_id":"%s","code":"%s","quantity":0}$$, :'b1', gen_random_uuid(), :'oleo_qr')::jsonb) ->> 'result'), 'quantidade_invalida', 'quantidade inválida');
select testes.igual((public.counter_add(format($${"movement_id":"%s","scan_id":"%s","material_id":"%s","quantity":2}$$, :'b1', gen_random_uuid(), :'filtro')::jsonb) ->> 'result'), 'incluido', 'inclusão manual');
select (select id from public.stock_movement_items where movement_id = :'b1' and material_id = :'filtro') as item_filtro \gset
select testes.igual((public.counter_set_quantity(:'item_filtro', 3, 3) ->> 'quantity_delivered')::numeric, 3::numeric, 'altera quantidade');
select testes.falha(format($$select public.counter_set_quantity('%s', 0, 0)$$, :'item_filtro'), 'Quantidade inválida');
select public.counter_remove_item(:'item_filtro');
select testes.igual((select item_count from public.stock_movements where id = :'b1'), 1, 'item removido');
select testes.igual((select count(*) from public.scan_events where movement_id = :'b1')::int, 6, 'todas as leituras registradas');
commit;

-- Finalizar separação
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000a1', true);
select testes.igual((public.counter_finish(:'b1') ->> 'status'), 'aguardando_assinatura', 'separação finalizada');
select testes.falha(format($$select public.counter_add('{"movement_id":"%s","scan_id":"%s","code":"%s"}')$$, :'b1', gen_random_uuid(), :'oleo_qr'), 'novas leituras estão bloqueadas');
select testes.falha(format($$select public.counter_finish('%s')$$, :'b1'), 'já foi finalizada');
select testes.igual((select status from public.counter_sessions where movement_id = :'b1'), 'aguardando_confirmacao', 'tablet avisado');
commit;

-- Confirmação no tablet
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000e1', true);
select testes.falha(format($$select public.counter_register_attempt('%s', 'facial', 'sucesso')$$, :'b1'), 'Tentativa inválida');
select public.counter_register_attempt(:'b1', 'assinatura', 'cancelada');
select testes.falha(format($$select public.counter_confirm('%s', '{"method":"facial","verification_id":"%s"}')$$, :'b1', gen_random_uuid()), 'Validação facial não encontrada');
select testes.falha(format($$select public.counter_confirm('%s', '{"method":"assinatura","signature_path":"MUR/%s/%s/a.png","photo_skipped_reason":"teste"}')$$, :'b1', :'ano', :'b1'), 'não encontrado');
insert into storage.objects (bucket_id, name, owner, metadata)
values ('assinaturas', 'MUR/' || :'ano' || '/' || :'b1' || '/assinatura_1.png', auth.uid(), '{"size": 100}');
select testes.falha(format($$select public.counter_confirm('%s', '{"method":"assinatura","signature_path":"MUR/%s/%s/assinatura_1.png"}')$$, :'b1', :'ano', :'b1'), 'Tire a foto do solicitante');
select testes.falha(format($$select public.counter_confirm('%s', '{"method":"assinatura","signature_path":"MUR/%s/%s/assinatura_1.png","photo_path":"MUR/%s/%s/foto.jpg"}')$$, :'b1', :'ano', :'b1', :'ano', :'b1'), 'Foto do solicitante não encontrada');
insert into storage.objects (bucket_id, name, owner, metadata)
values ('fotos-retirada', 'MUR/' || :'ano' || '/' || :'b1' || '/foto_1.jpg', auth.uid(), '{"size": 5000, "mimetype": "image/jpeg"}');
select testes.igual((public.counter_confirm(:'b1', format($${"method":"assinatura","signature_path":"MUR/%s/%s/assinatura_1.png","photo_path":"MUR/%s/%s/foto_1.jpg"}$$, :'ano', :'b1', :'ano', :'b1')::jsonb) ->> 'status'),
                    'sa_informada', 'ME confirmada com foto (sem ativo: direto para baixa no ERP)');
select testes.falha(format($$select public.counter_confirm('%s', '{"method":"assinatura"}')$$, :'b1'), 'já foi confirmada');
commit;
select testes.igual((select confirmation_method from public.stock_movements where id = :'b1'), 'assinatura', 'método registrado');
select testes.igual((select count(*) from public.confirmation_attempts where movement_id = :'b1')::int, 2, 'tentativas registradas');
select testes.igual((select status from public.counter_sessions where movement_id = :'b1'), 'confirmada', 'sessão confirmada');
select testes.igual((select count(*) from public.signatures where movement_id = :'b1')::int, 1, 'assinatura vinculada');
select testes.igual((select count(*) from public.movement_photos where movement_id = :'b1')::int, 1, 'foto vinculada');
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000a1', true);
select testes.igual((select count(*) from public.movement_photos where movement_id = :'b1')::int, 0, 'almoxarife não vê a foto');
select testes.igual((select count(*) from storage.objects where bucket_id = 'fotos-retirada')::int, 0, 'almoxarife não lê o arquivo da foto');
commit;
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', true);
select testes.igual((select count(*) from public.movement_photos where movement_id = :'b1')::int, 1, 'administrador vê a foto');
commit;

begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000a1', true);
select testes.falha(format($$select public.counter_set_quantity('%s', 5, 5)$$, (select id from public.stock_movement_items where movement_id = :'b1' limit 1)), 'bloqueados');
select testes.falha(format($$select public.counter_reopen('%s')$$, :'b1'), 'Somente separações aguardando confirmação');
-- Nova separação reaproveita o tablet livre e pode ser cancelada pelo almoxarife
select testes.igual((public.counter_open(format($${"id":"%s","warehouse_id":"%s","contract_id":"%s","sector_id":"%s","requester_employee_id":"%s","fixed_asset_text":"AF-1","reuse_terminal":true}$$,
  :'b2', :'mur', :'contrato', :'setor', :'func1')::jsonb) ->> 'terminal_paired'), 'true', 'tablet reaproveitado');
select public.counter_add(format($${"movement_id":"%s","scan_id":"%s","code":"%s"}$$, :'b2', :'s2', :'oleo_qr')::jsonb);
select public.counter_finish(:'b2');
select testes.igual((public.counter_reopen(:'b2', 'Solicitante pediu outro item') ->> 'status'), 'rascunho', 'separação reaberta');
select testes.igual((public.cancel_movement(:'b2', 'Solicitante desistiu da retirada') ->> 'status'), 'cancelada', 'almoxarife cancela separação');
select testes.igual((select status from public.counter_sessions where movement_id = :'b2'), 'cancelada', 'sessão encerrada no cancelamento');
select testes.igual(jsonb_array_length(public.counter_my_open()), 0, 'nenhuma separação em aberto');
commit;
\echo '>>> TESTES DO BALCÃO PASSARAM'

-- Escolha do tablet pelo almoxarife (sem código)
\set b3 'b1b1b1b1-0000-4000-8000-000000000003'
\set b4 'b1b1b1b1-0000-4000-8000-000000000004'
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000a1', true);
select testes.igual((select count(*) from jsonb_array_elements(public.counter_list_terminals(:'mur')))::int, 1, 'lista só os tablets do estoque');
select testes.falha(format($$select public.counter_list_terminals('%s')$$, :'dir'), 'Sem permissão');
select testes.igual((public.counter_open(format($${"id":"%s","warehouse_id":"%s","contract_id":"%s","sector_id":"%s","requester_employee_id":"%s","terminal_user_id":"00000000-0000-0000-0000-0000000000e1"}$$,
  :'b3', :'mur', :'contrato', :'setor', :'func1')::jsonb) ->> 'terminal_paired'), 'true', 'abre já ligada ao tablet escolhido');
select testes.falha(format($$select public.counter_open('{"id":"%s","warehouse_id":"%s","contract_id":"%s","sector_id":"%s","requester_employee_id":"%s","terminal_user_id":"00000000-0000-0000-0000-0000000000e1"}')$$,
  :'b4', :'mur', :'contrato', :'setor', :'func1'), 'ocupado');
select testes.falha(format($$select public.counter_open('{"id":"%s","warehouse_id":"%s","contract_id":"%s","sector_id":"%s","requester_employee_id":"%s","terminal_user_id":"00000000-0000-0000-0000-0000000000e2"}')$$,
  :'b4', :'mur', :'contrato', :'setor', :'func1'), 'Tablet inválido');
select public.counter_open(format($${"id":"%s","warehouse_id":"%s","contract_id":"%s","sector_id":"%s","requester_employee_id":"%s"}$$,
  :'b4', :'mur', :'contrato', :'setor', :'func1')::jsonb);
select testes.falha(format($$select public.counter_set_terminal('%s', '00000000-0000-0000-0000-0000000000e1')$$, :'b4'), 'ocupado');
select public.cancel_movement(:'b3', 'Teste de troca de tablet');
select testes.igual((public.counter_set_terminal(:'b4', '00000000-0000-0000-0000-0000000000e1') ->> 'terminal_user_id'), '00000000-0000-0000-0000-0000000000e1', 'tablet ligado durante a separação');
commit;
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000e1', true);
select testes.igual((public.counter_snapshot() -> 'movement' ->> 'id'), :'b4', 'tablet mostra a separação escolhida sem código');
commit;
\echo '>>> TESTES DE ESCOLHA DE TABLET PASSARAM'
