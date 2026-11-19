-- Fase 2: login, acesso negado, alertas, retenção, retenção legal e descarte com dupla aprovação
\set ON_ERROR_STOP 1
set client_min_messages = warning;
\set adm '00000000-0000-0000-0000-00000000000a'
\set adm2 '00000000-0000-0000-0000-0000000000ab'
\set almox '00000000-0000-0000-0000-0000000000a1'
\set gestor '00000000-0000-0000-0000-0000000000c1'
select id as mur from public.warehouses where code = 'MUR' \gset

-- 1) Relatos públicos foram revogados: não é permitido fabricar falhas de Auth.
select testes.igual(has_function_privilege('anon','public.report_login_failure(text)','execute'),false,'anon não pode fabricar falhas de login');
select testes.igual((select count(*) from public.auth_login_failures)::int, 0, 'nenhuma falha fabricada');
-- Fixture de alerta confiável para testar seu tratamento abaixo (não é um relato anônimo).
select public._raise_alert('falhas_login','aviso','Alerta de teste gerado pelo servidor','fixture-auth','{}'::jsonb);

-- 2) Login e saída relatados pela tela
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', :'almox', true);
select set_config('request.headers', '{"x-forwarded-for":"10.20.30.40","user-agent":"Tablet/1.0"}', true);
select public.auth_log_session('login');
select public.auth_log_session('login');
select public.auth_log_session('qualquer');
select public.auth_log_session('logout');
commit;
select testes.igual((select count(*) from public.audit_logs where action = 'auth.login' and user_id = :'almox')::int, 1, 'login registrado (repetição em 10 s ignorada)');
select testes.igual((select ip_address || '|' || category from public.audit_logs where action = 'auth.login' and user_id = :'almox'), '10.20.30.40|autenticacao', 'login com IP');
select testes.igual((select count(*) from public.audit_logs where action = 'auth.logout' and user_id = :'almox')::int, 1, 'saída registrada');

-- 3) Acesso negado relatado: limite de 30/hora e alerta no 10º
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', :'almox', true);
select public.log_access_denied(E'cadastros/usuarios\n[falso]', '42501') from generate_series(1, 35);
commit;
select testes.igual((select count(*) from public.audit_logs where action = 'acesso.negado' and user_id = :'almox')::int, 30, 'acessos negados limitados a 30 por hora');
select testes.igual((select result || '|' || reason_code || '|' || (new_data ->> 'origem') from public.audit_logs where action = 'acesso.negado' order by chain_seq desc limit 1), 'negado|42501|relato_da_tela', 'acesso negado marcado como relato da tela');
select testes.igual((select position(chr(10) in entity_id) from public.audit_logs where action = 'acesso.negado' order by chain_seq desc limit 1), 0, 'operação relatada sem quebra de linha');
select testes.igual((select count(*) from public.security_alerts where rule = 'acessos_negados' and dedupe_key = :'almox')::int, 1, 'alerta de acessos negados');

-- 4) Segundo administrador: alerta crítico de perfil admin
insert into auth.users (id, email, raw_user_meta_data) values (:'adm2', 'admin2@teste.local', '{"full_name":"Admin Dois"}') on conflict do nothing;
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', :'adm', true);
select public.admin_set_user_access(:'adm2', 'Admin Dois', '{admin}', array[:'mur']::uuid[], true, :'mur');
commit;
select testes.igual((select severity from public.security_alerts where rule = 'perfil_admin' and status = 'aberto' and title like '%concedido%' limit 1), 'critico', 'alerta crítico ao conceder administrador');

-- 5) Volume de exportação
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', :'gestor', true);
select jsonb_array_length(public.export_movements('{}', 'resumo')) from generate_series(1, 10);
commit;
select testes.igual((select count(*) from public.security_alerts where rule = 'exportacoes_volume' and dedupe_key = :'gestor')::int, 1, 'alerta de volume de exportação');

-- 6) Importação do log do Supabase Auth (só eventos que a tela não vê)
create table if not exists auth.audit_log_entries (instance_id uuid, id uuid primary key, payload json, created_at timestamptz, ip_address varchar(64) default '');
insert into auth.audit_log_entries (id, payload, created_at, ip_address) values
  (gen_random_uuid(), format('{"action":"user_updated_password","actor_id":"%s","actor_username":"almox.mur@teste.local"}', :'almox')::json, now() - interval '5 minutes', '10.0.0.9'),
  (gen_random_uuid(), format('{"action":"token_refreshed","actor_id":"%s"}', :'almox')::json, now() - interval '4 minutes', '10.0.0.9'),
  (gen_random_uuid(), format('{"action":"login","actor_id":"%s"}', :'almox')::json, now() - interval '3 minutes', '10.0.0.9');

-- 7) Visão de segurança e verificações
select id as um_alerta from public.security_alerts order by id limit 1 \gset
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', :'almox', true);
select testes.falha($$select public.security_overview()$$, 'não permite ver os alertas');
select testes.falha($$select public.security_run_checks()$$, 'Somente o administrador');
commit;
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', :'gestor', true);
select public.security_overview() as gv \gset
select testes.igual((:'gv'::jsonb ->> 'is_admin')::boolean, false, 'gestor vê como não-admin');
select testes.igual(:'gv'::jsonb ? 'policies', false, 'gestor não vê retenção');
select testes.igual((select count(*) from jsonb_array_elements(:'gv'::jsonb -> 'alerts') a where a ? 'details')::int, 0, 'gestor não vê detalhes dos alertas');
select testes.falha(format($$select public.security_alert_update(%s, 'encerrado', 'ok ok ok')$$, :um_alerta), 'Somente o administrador');
commit;
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', :'adm', true);
select public.security_run_checks() as chk \gset
select testes.igual((:'chk'::jsonb -> 'integridade' ->> 'ok')::boolean, true, 'verificação: integridade ok');
select testes.igual((:'chk'::jsonb ->> 'importados_auth')::int, 1, 'importa só a troca de senha (renovação de token e login ignorados)');
select testes.igual((public.security_overview() ->> 'admins')::int, 2, 'admin vê quantos administradores existem');
select testes.igual(jsonb_array_length(public.security_overview() -> 'policies'), 10, 'admin vê as políticas de retenção');
commit;
select testes.igual((select ip_address || '|' || actor_type from public.audit_logs where action = 'auth.senha_alterada' and user_id = :'almox'), '10.0.0.9|usuario', 'troca de senha importada com IP');
select testes.igual((select count(*) from public.security_alerts where rule = 'coleta_parada')::int, 0, 'sem alerta de coleta parada (há atividade)');

-- 8) Tratamento de alerta
select id as alerta from public.security_alerts where rule = 'falhas_login' \gset
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', :'adm', true);
select testes.falha(format($$select public.security_alert_update(%s, 'encerrado', '')$$, :alerta), 'descreva o tratamento');
select public.security_alert_update(:alerta, 'em_analise', null);
select public.security_alert_update(:alerta, 'encerrado', 'Usuário errou a senha; orientado');
select testes.falha(format($$select public.security_alert_update(%s, 'aberto', null)$$, :alerta), 'já encerrado');
commit;
select testes.igual((select status || '|' || resolution from public.security_alerts where id = :alerta), 'encerrado|Usuário errou a senha; orientado', 'alerta encerrado com tratamento');
select testes.igual((select count(*) from public.audit_logs where action = 'alerta.atualizado' and entity_id = :'alerta')::int, 2, 'tratamento registrado na auditoria');

-- 9) Retenção, retenção legal e descarte com dupla aprovação
--    eventos anteriores aos dez anos (inseridos pelo dono do banco)
-- Fixture explícita para exercitar a edição/aprovação de propostas legadas.
update public.audit_retention_policies set status='proposta' where category='autenticacao';
update public.audit_retention_policies set retain_days=null,status='proposta' where category='dados';
insert into public.audit_logs (occurred_at, action, entity, entity_id, new_data, ip_address, category, result, severity, schema_version)
values (now() - interval '4000 days', 'auth.login', 'auth', 'antigo-1', '{"x":1}', '1.1.1.1', 'autenticacao', 'sucesso', 'aviso', 2),
       (now() - interval '3999 days', 'auth.login', 'auth', 'antigo-2', '{"x":2}', '1.1.1.2', 'autenticacao', 'sucesso', 'aviso', 2),
       (now() - interval '3998 days', 'auth.login', 'auth', 'antigo-3', '{"x":3}', '1.1.1.3', 'autenticacao', 'sucesso', 'aviso', 2);
select (now() - interval '3998 days')::date as dia_retido \gset

begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', :'adm', true);
select testes.falha($$select public.purge_request('autenticacao', current_date - 200, 'Descarte conforme política')$$, 'ainda não foi aprovada');
select testes.falha($$select public.retention_set_policy('incidente', 365, 'Prazo curto demais')$$, 'no mínimo 5 anos');
select testes.falha($$select public.retention_set_policy('autenticacao', 10, 'Prazo')$$, 'entre 30 e 7300');
select public.retention_set_policy('autenticacao', 180, 'Aprovado pelo jurídico em reunião');
select testes.igual((public.security_overview() -> 'policies') @> '[{"category":"autenticacao","status":"proposta"}]', true, 'alteração volta para proposta');
select public.retention_approve_policy('autenticacao');
select testes.falha($$select public.retention_approve_policy('dados')$$, 'Defina o prazo');
select testes.falha($$select public.legal_hold_create('curto', current_date, current_date)$$, 'mínimo de 10');
select public.legal_hold_create('Investigação interna do login suspeito', :'dia_retido', :'dia_retido', 'autenticacao') as hold \gset
select testes.falha($$select public.purge_request('autenticacao', current_date - 10, 'Descarte conforme política')$$, 'prazo de 180 dias');
select public.purge_request('autenticacao', current_date - 200, 'Descarte conforme política aprovada') as pedido \gset
select testes.falha($$select public.purge_request('autenticacao', current_date - 200, 'Outro pedido igual')$$, 'pendente');
select testes.falha(format($$select public.purge_decide(%s, true, 'Aprovo o descarte')$$, :pedido), 'OUTRO administrador');
commit;
select testes.igual((select events from public.audit_purge_requests where id = :pedido), 2, 'pedido conta só os vencidos fora da retenção legal');

begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', :'adm2', true);
select testes.falha(format($$select public.purge_decide(%s, true, '')$$, :pedido), 'justificativa da decisão');
select testes.igual((public.purge_decide(:pedido, true, 'Conferido: dentro do prazo aprovado') ->> 'eventos')::int, 2, 'descarte executado pelo segundo administrador');
select testes.falha(format($$select public.purge_decide(%s, true, 'De novo')$$, :pedido), 'já decidido');
commit;
select testes.igual((select count(*) from public.audit_logs where entity is not null and action = 'auth.login' and purged_at is not null and new_data is null and ip_address is null and entity_id is null)::int, 2, 'conteúdo e IP apagados nos descartados');
select testes.igual((select new_data ->> 'x' from public.audit_logs where action = 'auth.login' and occurred_at::date = :'dia_retido'::date and ip_address = '1.1.1.3'), '3', 'evento em retenção legal preservado');
select testes.igual((public._audit_verify(null) ->> 'ok')::boolean, true, 'encadeamento íntegro após o descarte');
select testes.igual((select count(*) from public.security_alerts where rule = 'descarte_executado')::int, 1, 'descarte gera alerta para os outros administradores');
select testes.igual((select severity from public.audit_logs where action = 'auditoria.descarte_executado'), 'critico', 'descarte registrado como crítico');

-- descarte forjado pelo dono do banco é detectado
begin;
alter table public.audit_logs disable trigger block_change;
update public.audit_logs set new_data = null, purged_at = now(), purge_request_id = :pedido
 where chain_seq = (select max(chain_seq) from public.audit_logs where action = 'acesso.negado');
alter table public.audit_logs enable trigger block_change;
select testes.igual(public._audit_verify(null) ->> 'problem', 'descarte_nao_autorizado', 'descarte fora de pedido aprovado é detectado');
rollback;

-- o gatilho só aceita apagar TODO o conteúdo, e só dentro da função de descarte
begin;
select set_config('app.audit_purge', 'on', true);
select testes.falha(format($$update public.audit_logs set new_data = null, purged_at = now(), purge_request_id = %s where chain_seq = 3$$, :pedido), 'não podem ser alterados');
rollback;
select testes.falha($$delete from public.audit_logs where chain_seq = 3$$, 'não podem ser alterados');

-- liberação da retenção legal e alerta de retenção vencendo
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', :'adm', true);
select testes.falha(format($$select public.legal_hold_release(%s, 'x')$$, :hold), 'mínimo de 10');
select public.legal_hold_release(:hold, 'Investigação concluída sem achados');
select public.security_run_checks();
commit;
select testes.igual((select count(*) from public.security_alerts where rule = 'retencao_vencendo' and dedupe_key = 'autenticacao')::int, 1, 'alerta de retenção vencendo');

\echo '>>> TESTES DE SEGURANÇA (FASE 2) PASSARAM'
