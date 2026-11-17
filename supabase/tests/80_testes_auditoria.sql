-- Auditoria (fase 1): máscara, limpeza, integridade, consulta e exportação somente por função
\set ON_ERROR_STOP 1
set client_min_messages = warning;
select id as mur from public.warehouses where code = 'MUR' \gset
\set me1 '11111111-1111-4111-8111-111111111111'
\set corr 'abcdef12-3456-4789-8abc-def012345678'

-- 1) Máscara: nome omitido, matrícula mascarada (alteração feita pelo dono do banco = ator "sistema")
select full_name as nome_original from public.employees where registration = 'DEMO-1001' \gset
update public.employees set full_name = 'Fulano Mascarado Teste' where registration = 'DEMO-1001';
select testes.igual((select new_data ->> 'full_name' from public.audit_logs where entity = 'employees' order by chain_seq desc limit 1), '[omitido]', 'nome do funcionário não vai para o log');
select testes.igual((select count(*) from public.audit_logs where new_data::text like '%Mascarado%' or old_data::text like '%Mascarado%')::int, 0, 'nome real não aparece em nenhum evento');
select testes.igual((select actor_type || '|' || category from public.audit_logs order by chain_seq desc limit 1), 'sistema|cadastro', 'ator e categoria classificados');
update public.employees set full_name = :'nome_original' where registration = 'DEMO-1001';
select testes.igual(public.audit_mask('employees', '{"registration":"DEMO-1001","full_name":"X Y"}') ->> 'registration', '****01', 'matrícula mascarada');
select testes.igual(public.audit_mask('profiles', '{"email":"italo.teste@empresa.com"}') ->> 'email', 'i***@empresa.com', 'e-mail mascarado');
select testes.igual(public.audit_clean_text(E'linha1\nlinha2\r\u0007fim'), 'linha1 linha2  fim', 'caracteres de controle removidos (injeção em log)');

-- 2) Segredos removidos, IP só em evento de segurança, correlação gravada
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', true);
select set_config('request.headers', format('{"x-forwarded-for":"10.1.2.3, 10.0.0.1","user-agent":"TesteNavegador/1.0","x-correlation-id":"%s"}', :'corr'), true);
select public.log_event('etiquetas.impressas', null, '{"quantidade":3,"token":"abc123","senha":"segredo","Authorization":"Bearer x"}');
select testes.falha($$select count(*) from public.audit_logs$$, 'permission denied');
select testes.falha($$select public.audit_event('x', 'y', null, null, null, null, null)$$, 'permission denied');
select testes.falha($$insert into public.audit_logs (action, entity) values ('forjado', 'x')$$, 'permission denied');
select testes.falha($$select * from public.audit_anchors$$, 'permission denied');
commit;
select testes.igual((select new_data ->> 'token' || '|' || (new_data ->> 'senha') || '|' || (new_data ->> 'Authorization') from public.audit_logs where action = 'etiquetas.impressas' order by chain_seq desc limit 1), '[removido]|[removido]|[removido]', 'segredos nunca gravados');
select testes.igual((select new_data ->> 'quantidade' from public.audit_logs where action = 'etiquetas.impressas' order by chain_seq desc limit 1), '3', 'contexto útil mantido');
select testes.igual((select coalesce(ip_address, 'sem-ip') from public.audit_logs where action = 'etiquetas.impressas' order by chain_seq desc limit 1), 'sem-ip', 'IP não gravado em evento comum');
select testes.igual((select correlation_id::text from public.audit_logs where action = 'etiquetas.impressas' order by chain_seq desc limit 1), :'corr', 'identificador de correlação gravado');
select testes.igual((select user_email is null and schema_version = 2 and severity = 'aviso' from public.audit_logs where action = 'etiquetas.impressas' order by chain_seq desc limit 1), true, 'e-mail não copiado; versão e criticidade');

-- 2b) Correlação: mesma transação = mesmo id; outra transação = outro id
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', true);
select public.log_event('etiquetas.impressas', null, '{"lote":"A"}');
select public.log_event('etiquetas.impressas', null, '{"lote":"B"}');
commit;
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', true);
select public.log_event('etiquetas.impressas', null, '{"lote":"C"}');
commit;
select testes.igual((select count(distinct correlation_id) from public.audit_logs where action = 'etiquetas.impressas' and new_data ->> 'lote' in ('A', 'B'))::int, 1, 'eventos da mesma operação compartilham a correlação');
select testes.igual((select count(distinct correlation_id) from public.audit_logs where action = 'etiquetas.impressas' and new_data ->> 'lote' in ('A', 'C'))::int, 2, 'operações diferentes têm correlações diferentes');

-- 3) Justificativa com quebra de linha é limpa
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000c1', true);
select public.correct_movement(:'me1', '{"notes":"Ajuste de teste da auditoria"}', E'Correcao com\nlinha falsa [admin] aprovado');
select testes.igual((select position(chr(10) in (e ->> 'justification')) from jsonb_array_elements(public.movement_audit(:'me1')) e where e ->> 'action' = 'me.corrigida' order by (e ->> 'chain_seq')::bigint desc limit 1), 0, 'quebra de linha removida da justificativa');
commit;

select count(*) as antes from public.audit_logs where action = 'auditoria.consultada' and user_id = '00000000-0000-0000-0000-0000000000c1' \gset
-- 4) Consulta pelo gestor: sem IP/e-mail, limites, evento de consulta só na página 1
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000c1', true);
select set_config('request.headers', '{"x-forwarded-for":"10.9.9.9"}', true);
select public.search_audit('{}', 1, 500) as g1 \gset
select testes.igual((:'g1'::jsonb ->> 'page_size')::int, 100, 'página limitada a 100');
select testes.igual((select count(*) from jsonb_array_elements(:'g1'::jsonb -> 'rows') e where e ->> 'ip_address' is not null or e ->> 'user_email' is not null or e ->> 'user_agent' is not null)::int, 0, 'gestor não vê IP, navegador nem e-mail');
select testes.igual((select count(*) from jsonb_array_elements(:'g1'::jsonb -> 'rows') e where e ->> 'warehouse_id' is null)::int, 0, 'gestor só vê eventos de estoques');
select testes.falha($$select public.search_audit('{"date_from":"2025-01-01","date_to":"2026-12-31"}', 1, 50)$$, 'máximo 366 dias');
select testes.falha($$select public.search_audit('{"date_from":"2026-12-31","date_to":"2026-01-01"}', 1, 50)$$, 'data inicial');
select testes.falha($$select public.export_audit('{}', 'Auditoria interna do mês')$$, 'Somente o administrador');
select testes.falha($$select public.audit_verify_chain()$$, 'Somente o administrador');
select testes.falha($$select public.audit_create_anchor()$$, 'Somente o administrador');
select public.search_audit('{}', 2, 50);
select testes.igual(jsonb_array_length(public.export_movements('{}', 'resumo')) >= 1, true, 'gestor exporta MEs');
commit;
select testes.igual((select count(*) from public.audit_logs where action = 'auditoria.consultada' and user_id = '00000000-0000-0000-0000-0000000000c1')::int, :antes + 1, 'consulta registrada uma vez (página 1)');
select testes.igual((select (new_data ->> 'registros')::int >= 1 from public.audit_logs where action = 'exportacao.dados' order by chain_seq desc limit 1), true, 'exportação de MEs registrada no servidor');
select testes.igual((select new_data ->> 'tipo' from public.audit_logs where action = 'exportacao.dados' order by chain_seq desc limit 1), 'resumo', 'tipo da exportação registrado');

-- 5) Admin: busca com filtros e texto especial, exportação com finalidade
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', true);
select testes.igual((public.search_audit('{"category":"exportacao"}', 1, 50) ->> 'total')::int >= 2, true, 'filtro por categoria');
select testes.igual((public.search_audit(format('{"correlation_id":"%s"}', :'corr')::jsonb, 1, 50) ->> 'total')::int, 1, 'filtro por correlação');
select testes.igual((public.search_audit('{"q":"%_\\''); drop table x;--"}', 1, 50) ->> 'total')::int, 0, 'texto de busca tratado como literal');
select testes.falha($$select public.export_audit('{}', 'curto')$$, 'finalidade da exportação');
select testes.igual(jsonb_array_length(public.export_audit('{"category":"exportacao"}', 'Auditoria interna mensal')) >= 2, true, 'admin exporta com finalidade');
commit;
select testes.igual((select justification from public.audit_logs where action = 'auditoria.exportada' order by chain_seq desc limit 1), 'Auditoria interna mensal', 'exportação da auditoria registrada com finalidade');

-- 6) Integridade: verificação, âncora e conferência
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', true);
select set_config('request.headers', '{"x-forwarded-for":"10.5.5.5","user-agent":"TesteNavegador/2.0"}', true);
select testes.igual((public.audit_verify_chain() ->> 'ok')::boolean, true, 'encadeamento íntegro');
select public.audit_create_anchor() as anc \gset
select testes.igual((:'anc'::jsonb ->> 'ok')::boolean, true, 'âncora gerada');
select testes.igual((public.audit_check_anchor((:'anc'::jsonb ->> 'last_seq')::bigint, :'anc'::jsonb ->> 'last_hash') ->> 'ok')::boolean, true, 'âncora confere');
select testes.igual(public.audit_check_anchor((:'anc'::jsonb ->> 'last_seq')::bigint, repeat('a', 64)) ->> 'problem', 'hash_diferente_da_ancora', 'âncora falsa detectada');
select testes.falha($$select public.audit_check_anchor(1, 'xyz')$$, 'Âncora inválida');
commit;
select testes.igual((select result || '|' || coalesce(ip_address, 'sem-ip') from public.audit_logs where action = 'auditoria.ancora_conferida' order by chain_seq desc limit 1), 'falha|10.5.5.5', 'conferência com falha registrada, com IP (evento de segurança)');
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', true);
select testes.igual((select count(*) from jsonb_array_elements(public.search_audit('{"action":"auditoria.ancora_conferida","result":"falha"}', 1, 50) -> 'rows') e where e ->> 'ip_address' = '10.5.5.5')::int >= 1, true, 'admin vê o IP do evento de segurança');
commit;

-- 7) Adulteração pelo dono do banco é detectada (dentro de transação desfeita no fim)
begin;
alter table public.audit_logs disable trigger block_change;
update public.audit_logs set new_data = '{"alterado":true}' where chain_seq = 5;
alter table public.audit_logs enable trigger block_change;
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', true);
select public.audit_verify_chain() as v1 \gset
select testes.igual((:'v1'::jsonb ->> 'problem') || '@' || (:'v1'::jsonb ->> 'problem_seq'), 'conteudo_alterado@5', 'alteração de conteúdo detectada');
rollback;

begin;
alter table public.audit_logs disable trigger block_change;
delete from public.audit_logs where chain_seq = 6;
alter table public.audit_logs enable trigger block_change;
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', true);
select public.audit_verify_chain() as v2 \gset
select testes.igual((:'v2'::jsonb ->> 'problem') || '@' || (:'v2'::jsonb ->> 'problem_seq'), 'evento_removido@6', 'exclusão de evento detectada');
rollback;

-- Inserção direta pelo dono do banco também entra no encadeamento
insert into public.audit_logs (action, entity) values ('teste.insercao_direta', 'teste');
select testes.igual((public._audit_verify(null) ->> 'ok')::boolean, true, 'encadeamento íntegro após todas as operações');
select testes.falha($$update public.audit_logs set action = 'x' where chain_seq = 1$$, 'não podem ser alterados');

\echo '>>> TESTES DE AUDITORIA PASSARAM'
