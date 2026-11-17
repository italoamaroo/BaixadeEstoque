-- Reconhecimento facial no balcão: cadastro, identificação, pedido do tablet, confirmação pelo rosto
\set ON_ERROR_STOP 1
set client_min_messages = warning;
\set adm '00000000-0000-0000-0000-00000000000a'
\set almox '00000000-0000-0000-0000-0000000000a1'
\set gestor '00000000-0000-0000-0000-0000000000c1'
\set tab '00000000-0000-0000-0000-0000000000e1'
\set tab2 '00000000-0000-0000-0000-0000000000e2'
\set f1 'fa000000-0000-4000-8000-000000000001'
\set f2 'fa000000-0000-4000-8000-000000000002'
\set f3 'fa000000-0000-4000-8000-000000000003'
select id as mur from public.warehouses where code = 'MUR' \gset
select id as contrato from public.contracts where code = 'DEMO-CT-001' \gset
select id as setor from public.sectors where code = 'DEMO-SET-MAN' \gset
select id as func1 from public.employees where registration = 'DEMO-1001' \gset
select id as func2 from public.employees where registration = 'DEMO-1002' \gset
select qr_code as oleo_qr from public.materials where code = 'DEMO-0001' \gset
-- "rostos" de teste: vetores de 128 números (pessoa A, B e uma leitura parecida com A)
select jsonb_agg(round((sin(i * 0.37) * 0.2)::numeric, 5) order by i) as ra,
       jsonb_agg(round((cos(i * 0.91) * 0.2)::numeric, 5) order by i) as rb,
       jsonb_agg(round((sin(i * 0.37) * 0.2 + 0.01)::numeric, 5) order by i) as ra2,
       jsonb_agg(round((sin(i * 0.37) * 0.2 + 0.2)::numeric, 5) order by i) as rx
  from generate_series(1, 128) i \gset

-- 1) Acesso e configuração (começa desligado)
select testes.igual((public.face_config() ->> 'enabled')::boolean is not true, true, 'sem login não lê configuração');
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', :'gestor', true);
select testes.falha($$select public.face_overview()$$, 'administrador ou almoxarife');
select testes.falha($$select public.face_settings_update('{"enabled":true}')$$, 'Somente o administrador');
select testes.falha(format($$select public.face_enroll('%s', '[]')$$, :'func1'), 'administrador ou almoxarife');
select testes.falha($$select * from public.employee_faces$$, 'permission denied');
commit;
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', :'tab', true);
select testes.igual((public.face_config() ->> 'enabled')::boolean, false, 'começa desligado');
select testes.igual(public.counter_terminal_warehouses() -> 0 ->> 'id', :'mur', 'tablet sabe o próprio estoque');
select testes.falha(format($$select public.face_identify('%s', '%s', true)$$, :'mur', :'ra'), 'desligado');
commit;
select testes.igual(has_function_privilege('anon', 'public.face_identify(uuid, jsonb, boolean)', 'execute'), false, 'sem acesso anônimo');

-- 2) Cadastro (almoxarife): individual, em lote, validações
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', :'almox', true);
select testes.falha(format($$select public.face_enroll('%s', '[[1,2,3]]')$$, :'func1'), 'Leitura do rosto inválida');
select testes.falha(format($$select public.face_enroll('%s', '[]')$$, :'func1'), 'de 1 a 5');
select testes.igual((public.face_enroll(:'func1', format('[%s, %s]', :'ra', :'ra')::jsonb, 'camera') ->> 'modelos')::int, 2, 'cadastro pela câmera');
select testes.igual((public.face_enroll_bulk(format('[{"registration":"demo-1001","descriptors":[%s]},{"registration":"DEMO-1002","descriptors":[%s]},{"registration":"NAO-EXISTE","descriptors":[%s]},{"registration":"DEMO-1003","descriptors":[[1]]}]',
        :'ra', :'rb', :'rb')::jsonb) -> 'nao_encontrados') ->> 0, 'NAO-EXISTE', 'lote informa matrícula não cadastrada');
select testes.igual((public.face_overview() ->> 'com_rosto')::int, 2, 'dois funcionários com rosto');
commit;
select testes.igual((select count(*) from public.employee_faces where employee_id = :'func1')::int, 1, 'lote substitui os modelos anteriores');
select testes.igual((select string_agg(distinct source, ',') from public.employee_faces where employee_id = :'func1'), 'importacao', 'origem registrada');

-- 3) Liga e identifica no tablet
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', :'adm', true);
select testes.falha($$select public.face_settings_update('{"threshold":0.9}')$$, 'fora da faixa');
select public.face_settings_update('{"enabled":true,"threshold":0.5}');
commit;
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', :'tab2', true);
select testes.falha(format($$select public.face_identify('%s', '%s', true)$$, :'mur', :'ra'), 'não está vinculado');
commit;
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', :'tab', true);
select testes.igual(public.face_identify(:'mur', :'ra2', false) ->> 'reason', 'sem_prova_de_vida', 'sem prova de vida é recusado');
select testes.igual(public.face_identify(:'mur', :'rx', true) ->> 'reason', 'nao_reconhecido', 'rosto desconhecido é recusado');
select public.face_identify(:'mur', :'ra2', true) as ident \gset
select testes.igual(:'ident'::jsonb -> 'employee' ->> 'registration', 'DEMO-1001', 'rosto parecido com A é reconhecido como A');
select testes.igual((:'ident'::jsonb ->> 'similarity')::numeric >= 0.5, true, 'semelhança acima do mínimo');
commit;
select (:'ident'::jsonb ->> 'request_id') as req \gset

-- 4) Almoxarife vê o pedido e abre a ME ligada a ele
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', :'almox', true);
select testes.igual(public.counter_requests_pending(:'mur') -> 0 -> 'employee' ->> 'registration', 'DEMO-1001', 'almoxarife vê quem está no balcão');
select public.counter_open(format($${"id":"%s","warehouse_id":"%s","contract_id":"%s","sector_id":"%s","requester_employee_id":"%s","terminal_user_id":"%s"}$$,
  :'f1', :'mur', :'contrato', :'setor', :'func2', :'tab')::jsonb);
select testes.falha(format($$select public.counter_request_attach('%s', '%s')$$, :'req', :'f1'), 'diferente do reconhecido');
select public.cancel_movement(:'f1', 'Teste: solicitante errado');
select public.counter_open(format($${"id":"%s","warehouse_id":"%s","contract_id":"%s","sector_id":"%s","requester_employee_id":"%s","terminal_user_id":"%s"}$$,
  :'f2', :'mur', :'contrato', :'setor', :'func1', :'tab')::jsonb);
select public.counter_request_attach(:'req', :'f2');
select testes.falha(format($$select public.counter_request_attach('%s', '%s')$$, :'req', :'f2'), 'já foi atendido');
select testes.igual(jsonb_array_length(public.counter_requests_pending(:'mur')), 0, 'pedido sai da lista');
select public.counter_add(format($${"movement_id":"%s","scan_id":"%s","code":"%s"}$$, :'f2', gen_random_uuid(), :'oleo_qr')::jsonb);
select public.counter_finish(:'f2');
commit;
select testes.igual((select requester_identified_by from public.stock_movements where id = :'f2'), 'facial', 'ME marcada como identificada pelo rosto');
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', :'tab', true);
select testes.igual(public.counter_request_status(:'req') ->> 'status', 'atendido', 'tablet sabe que foi atendido');
commit;

-- 5) Confirmação pelo rosto (1:1), sem assinatura e sem foto
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', :'tab', true);
select testes.igual((public.face_confirmation_available(:'f2') ->> 'available')::boolean, true, 'confirmação pelo rosto disponível');
select testes.igual(public.face_verify_confirmation(:'f2', :'rb', true) ->> 'reason', 'nao_reconhecido', 'outra pessoa não confirma');
select public.face_verify_confirmation(:'f2', :'ra2', true) as ver \gset
select testes.igual((:'ver'::jsonb ->> 'ok')::boolean, true, 'solicitante confirmado pelo rosto');
select testes.igual((public.counter_confirm(:'f2', format('{"method":"facial","verification_id":"%s"}', :'ver'::jsonb ->> 'verification_id')::jsonb) ->> 'status') is not null, true, 'ME confirmada pelo rosto');
select testes.falha(format($$select public.counter_confirm('%s', '{"method":"facial","verification_id":"%s"}')$$, :'f2', :'ver'::jsonb ->> 'verification_id'), 'já foi confirmada');
commit;
select testes.igual((select confirmation_method from public.stock_movements where id = :'f2'), 'facial', 'método facial gravado');
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', :'gestor', true);
select testes.igual(public.movement_identification(:'f2') ->> 'identificado_por', 'facial', 'detalhe da ME mostra identificação pelo rosto');
select testes.igual((public.movement_identification(:'f2') ->> 'semelhanca_confirmacao')::numeric > 0.5, true, 'detalhe mostra semelhança da confirmação');
commit;
select testes.igual((select count(*) from public.signatures where movement_id = :'f2')::int + (select count(*) from public.movement_photos where movement_id = :'f2')::int, 0, 'sem assinatura e sem foto');

-- 6) Alternativa: pedido manual; sem rosto cadastrado a confirmação é por assinatura
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', :'tab', true);
select public.counter_request_manual(:'mur', '3 tentativas sem reconhecer') as req2 \gset
commit;
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', :'almox', true);
select testes.igual(public.counter_requests_pending(:'mur') -> 0 ->> 'method', 'manual', 'almoxarife vê pedido sem reconhecimento');
select public.counter_open(format($${"id":"%s","warehouse_id":"%s","contract_id":"%s","sector_id":"%s","requester_employee_id":"%s","terminal_user_id":"%s"}$$,
  :'f3', :'mur', :'contrato', :'setor', (select id from public.employees where registration = 'DEMO-1003'), :'tab')::jsonb);
select public.counter_request_attach(:'req2', :'f3');
select public.counter_add(format($${"movement_id":"%s","scan_id":"%s","code":"%s"}$$, :'f3', gen_random_uuid(), :'oleo_qr')::jsonb);
select public.counter_finish(:'f3');
commit;
select testes.igual((select requester_identified_by from public.stock_movements where id = :'f3'), 'manual', 'ME marcada como identificação manual');
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', :'tab', true);
select testes.igual(public.face_confirmation_available(:'f3') ->> 'reason', 'sem_cadastro', 'sem rosto: confirma por foto e assinatura');
select testes.falha(format($$select public.face_verify_confirmation('%s', '%s', true)$$, :'f3', :'ra'), 'indisponível');
commit;

-- 7) Inativar funcionário apaga o rosto; trilha sem os números do rosto
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', :'almox', true);
select public.face_remove(:'func2');
commit;
update public.employees set active = false where id = :'func1';
select testes.igual((select count(*) from public.employee_faces)::int, 0, 'rosto apagado ao inativar e ao remover');
update public.employees set active = true where id = :'func1';
select testes.igual((select string_agg(distinct category, ',') from public.audit_logs where action like 'biometria.%' and action <> 'biometria.configuracao'), 'privacidade', 'eventos de biometria na categoria privacidade');
select testes.igual((select count(*) from public.audit_logs where action like 'biometria.%' and (coalesce(new_data::text, '') ~ '0\.1[0-9]{3}|descriptor'))::int, 0, 'números do rosto fora da trilha');
select testes.igual((select severity from public.audit_logs where action = 'biometria.configuracao' order by id desc limit 1), 'critico', 'ligar/desligar é evento crítico');
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', :'adm', true);
select testes.igual((public.dsr_employee_report(:'func1') -> 'biometria' ->> 'retiradas_confirmadas_pelo_rosto')::int, 1, 'relatório do titular mostra uso do rosto');
commit;
select testes.igual((public._audit_verify(null) ->> 'ok')::boolean, true, 'encadeamento íntegro');

\echo '>>> TESTES DE RECONHECIMENTO FACIAL PASSARAM'
