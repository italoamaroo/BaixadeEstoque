-- Fase 4: pedidos de titulares (LGPD art. 18), prazo de resposta e relatório do titular
\set ON_ERROR_STOP 1
set client_min_messages = warning;
\set adm '00000000-0000-0000-0000-00000000000a'
\set gestor '00000000-0000-0000-0000-0000000000c1'
select extract(year from now() at time zone 'America/Recife')::int as ano \gset
select (now() at time zone 'America/Recife')::date as hoje \gset
select (now() - interval '20 days') as ha20 \gset
select id as func1 from public.employees where registration = 'DEMO-1001' \gset
select count(*) as mes_func1 from public.stock_movements where requester_employee_id = :'func1' \gset

-- 1) Acesso: só o administrador
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', :'gestor', true);
select testes.falha($$select public.dsr_overview()$$, 'Somente o administrador');
select testes.falha($$select public.dsr_open('{"requester_name":"Teste","rights":["acesso"]}')$$, 'Somente o administrador');
select testes.falha(format($$select public.dsr_employee_report('%s')$$, :'func1'), 'Somente o administrador');
select testes.falha($$select * from public.data_subject_requests$$, 'permission denied');
commit;
select testes.igual(has_function_privilege('anon', 'public.dsr_open(jsonb)', 'execute') or has_function_privilege('anon', 'public.dsr_employee_report(uuid, bigint)', 'execute'), false, 'sem acesso anônimo');

-- 2) Registro
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', :'adm', true);
select testes.igual((public.dsr_overview() -> 'settings' ->> 'titular_response_days')::int, 15, 'prazo padrão de 15 dias');
select testes.igual((public.dsr_overview() -> 'settings' ->> 'titular_channel') is null, true, 'canal começa "a definir"');
select testes.falha($$select public.dsr_open('{"requester_name":"Jo","rights":["acesso"]}')$$, 'nome de quem fez o pedido');
select testes.falha($$select public.dsr_open('{"requester_name":"Joana Titular Teste","rights":[]}')$$, 'ao menos um direito');
select testes.falha($$select public.dsr_open('{"requester_name":"Joana Titular Teste","rights":["inventado"]}')$$, 'ao menos um direito');
select testes.falha($$select public.dsr_open('{"requester_name":"Joana Titular Teste","rights":["acesso"],"received_at":"2099-01-01T00:00:00Z"}')$$, 'futuro');
select public.dsr_open('{"requester_name":"Joana Titular Teste","requester_registration":"DEMO-1001","rights":["acesso","confirmacao","acesso"],"channel":"e-mail do RH","description":"Quer saber o que temos dela"}') as p1 \gset
select public.dsr_open(format('{"requester_name":"Pedido Antigo Teste","rights":["correcao"],"received_at":"%s"}', :'ha20')::jsonb) as p2 \gset
commit;
select testes.igual((select code from public.data_subject_requests where id = :p1), 'SOL-' || :'ano' || '-001', 'código sequencial do ano');
select testes.igual((select employee_id::text from public.data_subject_requests where id = :p1), :'func1', 'matrícula vincula o funcionário');
select testes.igual((select rights::text from public.data_subject_requests where id = :p1), '{acesso,confirmacao}', 'direitos sem repetição');
select testes.igual((select due_date from public.data_subject_requests where id = :p1), :'hoje'::date + 15, 'prazo = data do pedido + 15 dias');

-- 3) Prazo vencido gera alerta crítico
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', :'adm', true);
select testes.igual(public.dsr_get(:p2) ->> 'situacao_prazo', 'atrasado', 'pedido antigo está atrasado');
select testes.igual((public.dsr_get(:p1) ->> 'dias_restantes')::int, 15, 'dias restantes');
select public.security_run_checks();
commit;
select testes.igual((select severity from public.security_alerts where rule = 'titular_prazo' and dedupe_key = :'p2'), 'critico', 'alerta crítico de resposta vencida');
select testes.igual((select count(*) from public.security_alerts where rule = 'titular_prazo' and dedupe_key = :'p1')::int, 0, 'sem alerta para pedido no prazo');

-- 4) Conferência de identidade e resposta
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', :'adm', true);
select testes.falha(format($$select public.dsr_respond(%s, 'atendido', 'Relatório entregue ao titular', null)$$, :p1), 'Confira e registre a identidade');
select testes.falha(format($$select public.dsr_update(%s, '{"identity_verified":true}')$$, :p1), 'como a identidade foi conferida');
select testes.falha(format($$select public.dsr_update(%s, '{"status":"atendido"}')$$, :p1), 'Registrar resposta');
select public.dsr_update(:p1, '{"identity_verified":true,"identity_method":"Crachá conferido pelo RH","status":"em_analise"}');
select testes.falha(format($$select public.dsr_respond(%s, 'talvez', 'Relatório entregue ao titular', null)$$, :p1), 'Resultado inválido');
select testes.falha(format($$select public.dsr_respond(%s, 'atendido', 'curto', null)$$, :p1), 'mínimo de 10');
select testes.falha(format($$select public.dsr_respond(%s, 'atendido_parcialmente', 'Relatório entregue ao titular', 'x')$$, :p1), 'motivo de não atender');
select public.dsr_employee_report(:'func1', :p1) as rel \gset
select testes.igual(:'rel'::jsonb -> 'cadastro' ->> 'matricula', 'DEMO-1001', 'relatório traz o cadastro');
select testes.igual(jsonb_array_length(:'rel'::jsonb -> 'retiradas'), :mes_func1, 'relatório traz todas as retiradas do titular');
select testes.igual(:'rel'::jsonb ->> 'pedido', 'SOL-' || :'ano' || '-001', 'relatório ligado ao pedido');
select public.dsr_respond(:p1, 'atendido', 'Relatório entregue ao titular em mãos', null);
select testes.falha(format($$select public.dsr_respond(%s, 'atendido', 'Relatório entregue de novo', null)$$, :p1), 'já respondido');
select testes.falha(format($$select public.dsr_update(%s, '{"channel":"outro"}')$$, :p1), 'já respondido');
select public.dsr_add_note(:p1, 'Titular agradeceu');
select testes.igual(public.dsr_get(:p1) ->> 'situacao_prazo', 'cumprido', 'respondido dentro do prazo');
select testes.igual(jsonb_array_length(public.dsr_get(:p1) -> 'notes'), 5, 'histórico: registro, alteração, relatório, resposta, nota');
-- indeferimento exige motivo
select public.dsr_update(:p2, '{"identity_verified":true,"identity_method":"Presencial com documento"}');
select testes.falha(format($$select public.dsr_respond(%s, 'indeferido', 'Pedido de correção analisado', null)$$, :p2), 'motivo de não atender');
select public.dsr_respond(:p2, 'indeferido', 'Pedido de correção analisado', 'Os dados já estavam corretos no cadastro');
select testes.igual(public.dsr_get(:p2) ->> 'situacao_prazo', 'cumprido_com_atraso', 'resposta fora do prazo fica marcada');
commit;

-- 5) Configuração do canal e do prazo
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', :'adm', true);
select testes.falha($$select public.privacy_settings_update('{"titular_response_days":0}')$$, 'entre 1 e 90');
select public.privacy_settings_update('{"titular_channel":"privacidade@empresa.com.br","titular_response_days":30}');
select public.dsr_open('{"requester_name":"Terceiro Pedido Teste","rights":["info_compartilhamento"]}') as p3 \gset
commit;
select testes.igual((select due_date from public.data_subject_requests where id = :p3), :'hoje'::date + 30, 'novo prazo configurado vale para pedidos novos');
select testes.igual((select due_date from public.data_subject_requests where id = :p1), :'hoje'::date + 15, 'pedido antigo mantém o prazo original');

-- 6) Nunca apaga; histórico não muda; trilha sem o nome de quem pediu
select testes.falha(format($$delete from public.data_subject_requests where id = %s$$, :p1), 'não podem ser excluídos');
select testes.falha($$update public.data_subject_request_notes set body = 'x'$$, 'não podem ser excluídos');
select testes.igual((select string_agg(distinct category, ',') from public.audit_logs where action like 'titular.%'), 'privacidade', 'eventos de titular na categoria privacidade');
select testes.igual((select count(*) from public.audit_logs where action like 'titular.%')::int >= 9, true, 'registro, alterações, relatório, respostas e nota na trilha');
select testes.igual((select count(*) from public.audit_logs where action like 'titular.%' and coalesce(new_data::text, '') || coalesce(entity_id, '') ~ 'Joana|Pedido Antigo|Terceiro Pedido|DEMO-1001')::int, 0, 'nome e matrícula do titular fora da trilha');
select testes.igual((public._audit_verify(null) ->> 'ok')::boolean, true, 'encadeamento íntegro');

\echo '>>> TESTES DE PEDIDOS DE TITULARES (FASE 4) PASSARAM'
