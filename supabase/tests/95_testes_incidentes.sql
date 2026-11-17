-- Fase 3: incidentes (Res. CD/ANPD 15/2024), prazos em dias úteis, feriados e configuração LGPD
\set ON_ERROR_STOP 1
set client_min_messages = warning;
\set adm '00000000-0000-0000-0000-00000000000a'
\set almox '00000000-0000-0000-0000-0000000000a1'
\set gestor '00000000-0000-0000-0000-0000000000c1'
select extract(year from now() at time zone 'America/Recife')::int as ano \gset
select (now() - interval '30 days') as ha30 \gset
select ((now() - interval '30 days') at time zone 'America/Recife')::date as dia30 \gset
select (now() at time zone 'America/Recife')::date as hoje \gset

-- 1) Dias úteis (exclui o dia inicial; pula fim de semana e feriado)
select testes.igual(public.business_days_add('2026-11-19', 3)::text, '2026-11-25', 'quinta 19/11 + 3 úteis pula 20/11 (feriado) e o fim de semana');
select testes.igual(public.business_days_add('2026-11-13', 3)::text, '2026-11-18', 'sexta + 3 úteis = quarta');
select testes.igual(public.business_days_add('2026-12-31', 1)::text, '2027-01-04', '31/12 + 1 útil pula 1º/01 e o fim de semana');
select testes.igual(public.business_days_between('2026-11-11', '2026-11-16'), 3, 'dias úteis entre datas');
select testes.igual(public.business_days_between('2026-11-16', '2026-11-11'), -3, 'prazo vencido fica negativo');

-- 2) Acesso: só o administrador
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', :'gestor', true);
select testes.falha($$select public.incident_overview()$$, 'Somente o administrador');
select testes.falha($$select public.incident_open('{"title":"Teste do gestor"}')$$, 'Somente o administrador');
select testes.falha($$select public.privacy_settings_update('{"small_agent":true}')$$, 'Somente o administrador');
select testes.falha($$select public.holiday_add('2026-12-08', 'Nossa Senhora da Conceição', 'municipal')$$, 'Somente o administrador');
commit;
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', :'almox', true);
select testes.falha($$select public.incident_get(1)$$, 'Somente o administrador');
commit;
select testes.igual(has_function_privilege('anon', 'public.incident_overview()', 'execute') or has_function_privilege('anon', 'public.incident_update(bigint, jsonb)', 'execute'), false, 'sem acesso anônimo');
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', :'adm', true);
select testes.falha($$select * from public.security_incidents$$, 'permission denied');
select testes.falha($$select * from public.privacy_settings$$, 'permission denied');
commit;

-- 3) Registro a partir de um alerta
select public._raise_alert('acessos_negados', 'aviso', 'Acessos negados repetidos (teste incidente)', 'teste-incidente', '{}') as alerta \gset
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', :'adm', true);
select testes.igual((public.incident_overview() -> 'settings' ->> 'small_agent') is null, true, 'porte começa "a definir"');
select testes.falha($$select public.incident_open('{"title":"abc"}')$$, '5 a 200');
select testes.falha($$select public.incident_open('{"title":"Futuro demais","known_at":"2099-01-01T00:00:00Z"}')$$, 'futuro');
select public.incident_open(format('{"title":"Acesso indevido à planilha de funcionários","known_at":"%s","alert_id":%s,"description":"SEGREDO-XYZ Fulano de Tal"}', :'ha30', :alerta)::jsonb) as inc \gset
select public.incident_open('{"title":"Tablet esquecido no refeitório"}') as inc2 \gset
commit;
select testes.igual((select code from public.security_incidents where id = :inc), 'INC-' || :'ano' || '-001', 'código sequencial do ano');
select testes.igual((select code from public.security_incidents where id = :inc2), 'INC-' || :'ano' || '-002', 'segundo código');
select testes.igual((select status from public.security_alerts where id = :alerta), 'em_analise', 'alerta de origem passa para em análise');

-- 4) Validações da alteração
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', :'adm', true);
select testes.falha(format($$select public.incident_update(%s, '{"created_by":null}')$$, :inc), 'Campo não permitido');
select testes.falha(format($$select public.incident_update(%s, '{"status":"encerrado"}')$$, :inc), 'Encerrar incidente');
select testes.falha(format($$select public.incident_update(%s, '{"occurred_at":"2099-01-01T00:00:00Z"}')$$, :inc), 'futuro');
select testes.falha(format($$select public.incident_update(%s, '{"personal_data_known_at":"2000-01-01T00:00:00Z"}')$$, :inc), 'não pode ser anterior');
select testes.falha(format($$select public.incident_update(%s, '{"anpd_communicated_at":"%s"}')$$, :inc, now()), 'antes de registrar comunicações');
select testes.falha(format($$select public.incident_update(%s, '{"risk_criteria":["inventado"]}')$$, :inc), 'Critério de risco inválido');
select testes.falha(format($$select public.incident_update(%s, '{"risk_level":"talvez"}')$$, :inc), 'Nível de risco inválido');

-- 5) Prazos: conhecimento de dados pessoais há 30 dias e risco não avaliado -> atrasado
select public.incident_update(:inc, format('{"personal_data_known_at":"%s","status":"em_tratamento","data_categories":["nome","matrícula"," nome "]}', :'ha30')::jsonb) as v \gset
select testes.igual(:'v'::jsonb -> 'prazos' ->> 'anpd_prazo', public.business_days_add(:'dia30'::date, 3)::text, 'prazo ANPD = 3 dias úteis');
select testes.igual(:'v'::jsonb -> 'prazos' ->> 'anpd_situacao', 'atrasado', 'prazo vencido sem comunicação');
select testes.igual(:'v'::jsonb -> 'prazos' ->> 'declaracao_prazo', public.business_days_add(public.business_days_add(:'dia30'::date, 3), 3)::text, 'declaração = 3 úteis após o prazo dos titulares');
select testes.igual(:'v'::jsonb ->> 'data_categories', '["matrícula", "nome"]', 'categorias sem repetição e sem espaços');
select testes.igual((:'v'::jsonb -> 'prazos' ->> 'pequeno_porte') is null, true, 'sem porte definido: prazo simples');
-- pequeno porte: prazo em dobro
select public.privacy_settings_update('{"small_agent":true,"dpo_name":"Maria Encarregada","controller_name":"Empresa Teste"}');
select testes.igual(public.incident_get(:inc) -> 'prazos' ->> 'anpd_prazo', public.business_days_add(:'dia30'::date, 6)::text, 'pequeno porte: 6 dias úteis');
select public.privacy_settings_update('{"small_agent":null}');
select testes.igual(public.incident_get(:inc) -> 'prazos' ->> 'anpd_prazo', public.business_days_add(:'dia30'::date, 3)::text, 'porte a definir volta ao prazo simples');
commit;

-- 6) Verificações geram os alertas de prazo e de risco sem avaliação
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', :'adm', true);
select public.security_run_checks();
commit;
select testes.igual((select count(*) from public.security_alerts where rule = 'incidente_prazo' and status = 'aberto' and severity = 'critico')::int, 2, 'alertas críticos de prazo (ANPD e titulares)');
select testes.igual((select count(*) from public.security_alerts where rule = 'incidente_sem_avaliacao' and dedupe_key = :'inc')::int, 1, 'alerta de risco sem avaliação');
select testes.igual((select title like '%VENCIDO%' from public.security_alerts where rule = 'incidente_prazo' and dedupe_key = 'anpd:' || :inc), true, 'alerta diz que venceu');

-- 7) Encerramento exige os campos do art. 10
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', :'adm', true);
select testes.falha(format($$select public.incident_close(%s, 'curto')$$, :inc), 'mínimo de 10');
select testes.falha(format($$select public.incident_close(%s, 'Encerrando o incidente de teste')$$, :inc), 'avaliação do risco (V)');
select public.incident_update(:inc, format($${"risk_level":"risco_relevante","risk_criteria":["larga_escala"],"risk_assessment":"Exposição de nomes e matrículas",
  "affected_count":42,"measures":"Senha trocada","anpd_communicated_at":"%s","anpd_protocol":"ANPD-123"}$$, now())::jsonb) as v2 \gset
select testes.igual(:'v2'::jsonb -> 'prazos' ->> 'anpd_situacao', 'cumprido_com_atraso', 'comunicação fora do prazo fica marcada');
select testes.igual(:'v2'::jsonb -> 'prazos' ->> 'complementacao_prazo', public.business_days_add(:'hoje'::date, 20)::text, 'complementação: 20 dias úteis da comunicação');
select testes.falha(format($$select public.incident_close(%s, 'Encerrando o incidente de teste')$$, :inc), 'comunicação aos titulares (VII)');
select public.incident_update(:inc, format('{"titulares_communicated_at":"%s","communication_form":"E-mail individual","communication_content":"Texto enviado"}', now())::jsonb);
select public.incident_add_note(:inc, 'Reunião com o jurídico realizada');
select public.incident_close(:inc, 'Comunicações feitas e senhas trocadas');
select testes.falha(format($$select public.incident_update(%s, '{"measures":"outra"}')$$, :inc), 'encerrado não pode ser alterado');
select testes.falha(format($$select public.incident_close(%s, 'De novo encerrando')$$, :inc), 'já encerrado');
select public.incident_add_note(:inc, 'Anotação depois do encerramento');
select testes.igual(jsonb_array_length(public.incident_get(:inc) -> 'notes'), 7, 'histórico: registro, 3 alterações, nota, encerramento, nota');

-- sem risco relevante: precisa do motivo da ausência de comunicação
select public.incident_update(:inc2, '{"description":"Tablet achado 20 min depois, bloqueado","data_nature":"Nenhum dado exposto","affected_count":0,"risk_level":"sem_risco_relevante","risk_assessment":"Aparelho bloqueado por senha"}');
select testes.falha(format($$select public.incident_close(%s, 'Tablet recuperado sem acesso')$$, :inc2), 'motivo da ausência de comunicação (VIII)');
select public.incident_update(:inc2, '{"no_communication_reason":"Não houve acesso aos dados: aparelho bloqueado"}');
select testes.igual((public.incident_get(:inc2) -> 'prazos' ->> 'aplica')::boolean, false, 'sem risco relevante: prazos não se aplicam');
select public.incident_close(:inc2, 'Tablet recuperado sem acesso');
commit;

-- 8) Nunca apaga; o histórico não muda
select testes.falha(format($$delete from public.security_incidents where id = %s$$, :inc), 'não podem ser excluídos');
select testes.falha($$update public.security_incident_notes set body = 'x'$$, 'não podem ser excluídos');

-- 9) Trilha: crítica, sem o texto do incidente e sem o nome do encarregado
select testes.igual((select string_agg(distinct category || '|' || severity, ',') from public.audit_logs where action like 'incidente.%'), 'incidente|critico', 'eventos de incidente são críticos');
select testes.igual((select count(*) from public.audit_logs where action like 'incidente.%')::int >= 6, true, 'registro, alterações, anotações e encerramento na trilha');
select testes.igual((select count(*) from public.audit_logs where coalesce(new_data::text, '') || coalesce(old_data::text, '') ~ 'SEGREDO-XYZ|Maria Encarregada|Fulano')::int, 0, 'texto do incidente e nome do encarregado fora da trilha');
select testes.igual((select new_data -> 'campos' from public.audit_logs where action = 'privacidade.configuracao_alterada' order by chain_seq limit 1),
  '["controller_name", "dpo_name", "small_agent"]'::jsonb, 'configuração: só os nomes dos campos');

-- 10) Feriado cadastrado muda o prazo
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', :'adm', true);
select testes.falha($$select public.holiday_add('2026-12-08', 'X', 'municipal')$$, 'nome do feriado');
select testes.falha($$select public.holiday_add('2026-12-08', 'Conceição', 'bairro')$$, 'Abrangência inválida');
select public.holiday_add('2026-12-08', 'Nossa Senhora da Conceição (Recife)', 'municipal');
select testes.igual(public.business_days_add('2026-12-07', 1)::text, '2026-12-09', 'feriado municipal pulado');
select public.holiday_remove('2026-12-08');
select testes.igual(public.business_days_add('2026-12-07', 1)::text, '2026-12-08', 'feriado removido');
select testes.falha($$select public.holiday_remove('2026-12-08')$$, 'não encontrado');
commit;
select testes.igual((select count(*) from public.audit_logs where action in ('privacidade.feriado_cadastrado', 'privacidade.feriado_removido'))::int, 2, 'feriados na trilha');
select testes.igual((public._audit_verify(null) ->> 'ok')::boolean, true, 'encadeamento íntegro');

\echo '>>> TESTES DE INCIDENTES (FASE 3) PASSARAM'
