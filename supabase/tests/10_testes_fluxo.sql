-- =====================================================================
-- TESTES DE FLUXO, PERMISSÕES E REGRAS (PostgreSQL local com stubs)
-- Executar: npm run test:sql  (ver README > Testes)
-- Cada bloco simula um usuário diferente (role authenticated + JWT sub).
-- =====================================================================
\set ON_ERROR_STOP 1
set client_min_messages = warning;

create schema if not exists testes;
grant usage on schema testes to authenticated;

create or replace function testes.falha(p_sql text, p_trecho text)
returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if position(lower(p_trecho) in lower(sqlerrm)) = 0 then
      raise exception 'FALHOU: erro inesperado para [%]: % (esperado conter "%")', p_sql, sqlerrm, p_trecho;
    end if;
    raise notice 'ok (bloqueado): %', p_trecho;
    return;
  end;
  raise exception 'FALHOU: comando deveria ter sido bloqueado: %', p_sql;
end $$;
grant execute on function testes.falha(text, text) to authenticated;

create or replace function testes.igual(p_obtido anyelement, p_esperado anyelement, p_msg text)
returns void language plpgsql as $$
begin
  if p_obtido is distinct from p_esperado then
    raise exception 'FALHOU: % (obtido=%, esperado=%)', p_msg, p_obtido, p_esperado;
  end if;
  raise notice 'ok: %', p_msg;
end $$;
grant execute on function testes.igual(anyelement, anyelement, text) to authenticated;

-- ---------------------------------------------------------------------
-- Usuários de teste
-- ---------------------------------------------------------------------
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-00000000000a', 'admin@teste.local',  '{"full_name":"Admin Teste"}'),
  ('00000000-0000-0000-0000-0000000000a1', 'almox.mur@teste.local', '{"full_name":"Almox Muribeca"}'),
  ('00000000-0000-0000-0000-0000000000a2', 'almox.dir@teste.local', '{"full_name":"Almox Dois Irmãos"}'),
  ('00000000-0000-0000-0000-0000000000b1', 'sa@teste.local',     '{"full_name":"Equipe SA"}'),
  ('00000000-0000-0000-0000-0000000000c1', 'gestor@teste.local', '{"full_name":"Gestor Teste"}'),
  ('00000000-0000-0000-0000-0000000000d1', 'semperfil@teste.local', '{"full_name":"Sem Perfil"}')
on conflict do nothing;

select public.bootstrap_admin('admin@teste.local', 'Admin Teste');
select testes.falha($$select public.bootstrap_admin('gestor@teste.local')$$, 'Já existe administrador');

select id as mur from public.warehouses where code = 'MUR' \gset
select id as dir from public.warehouses where code = 'DIR' \gset

-- ---------------------------------------------------------------------
-- Admin configura acessos
-- ---------------------------------------------------------------------
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', true);
select public.admin_set_user_access('00000000-0000-0000-0000-0000000000a1', 'Almox Muribeca', '{almoxarife}', array[:'mur']::uuid[], true, :'mur');
select public.admin_set_user_access('00000000-0000-0000-0000-0000000000a2', 'Almox Dois Irmãos', '{almoxarife}', array[:'dir']::uuid[], true, :'dir');
select public.admin_set_user_access('00000000-0000-0000-0000-0000000000b1', 'Equipe SA', '{equipe_sa}', array[:'mur', :'dir']::uuid[], true, null);
select public.admin_set_user_access('00000000-0000-0000-0000-0000000000c1', 'Gestor Teste', '{gestor}', array[:'mur', :'dir']::uuid[], true, null);
select testes.falha($$select public.admin_set_user_access('00000000-0000-0000-0000-00000000000a', 'Admin', '{gestor}', '{}', true, null)$$, 'único administrador');
commit;

-- Não-admin não consegue alterar acessos nem cadastrar material
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000a1', true);
select testes.falha($$select public.admin_set_user_access('00000000-0000-0000-0000-0000000000a1', 'X X X', '{admin}', '{}', true, null)$$, 'Somente administrador');
select testes.falha($$insert into public.materials (code, name, unit) values ('X1', 'Teste', 'UN')$$, 'row-level security');
select testes.falha($$insert into public.stock_movements (id, me_number) values (gen_random_uuid(), 'X')$$, 'permission denied');
select testes.falha($$insert into public.user_roles values (auth.uid(), 'admin')$$, 'permission denied');
commit;

-- ---------------------------------------------------------------------
-- Dados de apoio
-- ---------------------------------------------------------------------
select id as contrato from public.contracts where code = 'DEMO-CT-001' \gset
select id as setor from public.sectors where code = 'DEMO-SET-MAN' \gset
select id as frente from public.service_fronts where code = 'DEMO-EQ-101' \gset
select id as func1 from public.employees where registration = 'DEMO-1001' \gset
select id as func2 from public.employees where registration = 'DEMO-1006' \gset
select id as oleo from public.materials where code = 'DEMO-0001' \gset
select id as filtro from public.materials where code = 'DEMO-0002' \gset
select id as inativo from public.materials where code = 'DEMO-0012' \gset

\set me1 '11111111-1111-4111-8111-111111111111'
\set me2 '22222222-2222-4222-8222-222222222222'
\set me3 '33333333-3333-4333-8333-333333333333'
select extract(year from now() at time zone 'America/Recife')::int as ano \gset

-- ---------------------------------------------------------------------
-- Almoxarife Muribeca: leitura de QR, upload de assinatura e criação da ME
-- ---------------------------------------------------------------------
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000a1', true);

select testes.igual((public.find_material_by_code('MAT-DEMO000001') -> 'material' ->> 'code'), 'DEMO-0001', 'QR Code localiza material');
select testes.igual((public.find_material_by_code('https://app/m/MAT-DEMO000002') -> 'material' ->> 'code'), 'DEMO-0002', 'QR com URL usa último segmento');
select testes.igual((public.find_material_by_code('NAO-EXISTE-123') ->> 'reason'), 'nao_cadastrado', 'QR não cadastrado');
select testes.igual((public.find_material_by_code('<script>') ->> 'reason'), 'invalido', 'QR inválido');
select testes.igual((public.find_material_by_code('MAT-DEMO000012') -> 'material' ->> 'active'), 'false', 'material inativo identificado');
select testes.igual(jsonb_array_length(public.search_materials('filtro')) >= 2, true, 'pesquisa manual por nome');

-- assinatura no Storage (policy de INSERT)
insert into storage.objects (bucket_id, name, owner, metadata)
values ('assinaturas', 'MUR/' || :'ano' || '/' || :'me1' || '/assinatura_1.png', auth.uid(), '{"size": 4567, "mimetype": "image/png"}');
select testes.falha(format($$insert into storage.objects (bucket_id, name, metadata) values ('assinaturas', 'DIR/%s/%s/a.png', '{}')$$, :'ano', :'me1'), 'row-level security');

-- validações
select testes.falha(format($$select public.create_movement('{"id":"%s","warehouse_id":"%s","contract_id":"%s","sector_id":"%s","requester_employee_id":"%s","items":[],"signature":{"storage_path":"x"}}')$$,
  :'me1', :'mur', :'contrato', :'setor', :'func1'), 'pelo menos um material');
select testes.falha(format($$select public.create_movement('{"id":"%s","warehouse_id":"%s","contract_id":"%s","sector_id":"%s","requester_employee_id":"%s","items":[{"material_id":"%s","quantity_requested":0,"quantity_delivered":0}],"signature":{"storage_path":"MUR/%s/%s/assinatura_1.png"}}')$$,
  :'me1', :'mur', :'contrato', :'setor', :'func1', :'oleo', :'ano', :'me1'), 'maior que zero');
select testes.falha(format($$select public.create_movement('{"id":"%s","warehouse_id":"%s","contract_id":"%s","sector_id":"%s","requester_employee_id":"%s","items":[{"material_id":"%s","quantity_requested":2,"quantity_delivered":3}],"signature":{"storage_path":"MUR/%s/%s/assinatura_1.png"}}')$$,
  :'me1', :'mur', :'contrato', :'setor', :'func1', :'oleo', :'ano', :'me1'), 'não pode ser maior');
select testes.falha(format($$select public.create_movement('{"id":"%s","warehouse_id":"%s","contract_id":"%s","sector_id":"%s","requester_employee_id":"%s","items":[{"material_id":"%s","quantity_requested":1,"quantity_delivered":1}],"signature":{"storage_path":"MUR/%s/%s/assinatura_1.png"}}')$$,
  :'me1', :'mur', :'contrato', :'setor', :'func1', :'inativo', :'ano', :'me1'), 'material inativo');
select testes.falha(format($$select public.create_movement('{"id":"%s","warehouse_id":"%s","contract_id":"%s","sector_id":"%s","requester_employee_id":"%s","items":[{"material_id":"%s","quantity_requested":1,"quantity_delivered":1}]}')$$,
  :'me1', :'mur', :'contrato', :'setor', :'func1', :'oleo'), 'assinatura do funcionário é obrigatória');
select testes.falha(format($$select public.create_movement('{"id":"%s","warehouse_id":"%s","contract_id":"%s","sector_id":"%s","requester_employee_id":"%s","items":[{"material_id":"%s","quantity_requested":1,"quantity_delivered":1}],"signature":{"storage_path":"MUR/%s/%s/nao_enviado.png"}}')$$,
  :'me1', :'mur', :'contrato', :'setor', :'func1', :'oleo', :'ano', :'me1'), 'não encontrado no armazenamento');
select testes.falha(format($$select public.create_movement('{"id":"%s","warehouse_id":"%s","contract_id":"%s","sector_id":"%s","requester_employee_id":"%s","items":[{"material_id":"%s","quantity_requested":1,"quantity_delivered":1}],"signature":{"storage_path":"x"}}')$$,
  :'me2', :'dir', :'contrato', :'setor', :'func1', :'oleo'), 'não tem permissão para operar');
select testes.falha(format($$select public.create_movement('{"id":"%s","warehouse_id":"%s","contract_id":"%s","sector_id":"%s","items":[{"material_id":"%s","quantity_requested":1,"quantity_delivered":1}],"signature":{"storage_path":"x"}}')$$,
  :'me1', :'mur', :'contrato', :'setor', :'oleo'), 'requisitante');
select testes.falha(format($$select public.create_movement('{"id":"%s","warehouse_id":"%s","contract_id":"%s","sector_id":"%s","requester_employee_id":"%s","items":[{"material_id":"%s","quantity_requested":1,"quantity_delivered":1},{"material_id":"%s","quantity_requested":1,"quantity_delivered":1}],"signature":{"storage_path":"MUR/%s/%s/assinatura_1.png"}}')$$,
  :'me1', :'mur', :'contrato', :'setor', :'func1', :'oleo', :'oleo', :'ano', :'me1'), 'mais de uma vez');

-- criação válida
select public.create_movement(format($${"id":"%s","warehouse_id":"%s","contract_id":"%s","sector_id":"%s","service_front_id":"%s",
  "service_order_text":"DEMO-OS-24101","fixed_asset_text":"DEMO-AF-0101","requester_employee_id":"%s","received_by_employee_id":"%s",
  "items":[{"material_id":"%s","quantity_requested":20,"quantity_delivered":18,"entry_method":"qr_code","scanned_code":"MAT-DEMO000001","notes":"Faltou 2 L"},
           {"material_id":"%s","quantity_requested":2,"quantity_delivered":2,"entry_method":"pesquisa_manual"}],
  "signature":{"storage_path":"MUR/%s/%s/assinatura_1.png","signed_at":"%s"}}$$,
  :'me1', :'mur', :'contrato', :'setor', :'frente', :'func1', :'func2', :'oleo', :'filtro', :'ano', :'me1', now())::jsonb) as r1 \gset
select testes.igual((:'r1'::jsonb ->> 'me_number'), 'ME-MUR-' || :'ano' || '-000001', 'primeiro número da ME de Muribeca');
select testes.igual((:'r1'::jsonb ->> 'status'), 'aguardando_sa', 'status inicial AGUARDANDO SA');

-- reenvio (duplo clique / falha de rede) devolve a mesma ME
select testes.igual((public.create_movement(format($${"id":"%s","warehouse_id":"%s"}$$, :'me1', :'mur')::jsonb) ->> 'created'), 'false', 'reenvio é idempotente');

select testes.igual((select item_count from public.stock_movements where id = :'me1'), 2, 'totais: 2 itens');
select testes.igual((select total_delivered from public.stock_movements where id = :'me1'), 20.000::numeric, 'totais: 20 unidades atendidas');
select testes.igual((select service_order_id is not null from public.stock_movements where id = :'me1'), true, 'OS vinculada ao cadastro');
select testes.igual((select received_by_name from public.stock_movements where id = :'me1'), 'Edvaldo Pereira Costa', 'recebedor diferente do requisitante');

-- cópia dos dados do material preservada
commit;

update public.materials set name = 'Óleo renomeado' where id = :'oleo';
select testes.igual((select material_name from public.stock_movement_items where movement_id = :'me1' and line_number = 1), 'Óleo lubrificante 15W40', 'histórico preserva nome do material');
update public.materials set name = 'Óleo lubrificante 15W40' where id = :'oleo';

-- ---------------------------------------------------------------------
-- Isolamento entre estoques
-- ---------------------------------------------------------------------
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000a2', true);
select testes.igual((select count(*) from public.stock_movements)::int, 0, 'almoxarife Dois Irmãos não vê MEs de Muribeca');
select testes.igual((select count(*) from public.signatures)::int, 0, 'almoxarife Dois Irmãos não vê assinaturas de Muribeca');
select testes.igual((select count(*) from storage.objects)::int, 0, 'almoxarife Dois Irmãos não lê arquivos de Muribeca');
select testes.igual((public.search_movements('{}', 1, 25) ->> 'total')::int, 0, 'search_movements respeita estoque');

insert into storage.objects (bucket_id, name, owner, metadata)
values ('assinaturas', 'DIR/' || :'ano' || '/' || :'me2' || '/assinatura_1.png', auth.uid(), '{"size": 3000}');
select public.create_movement(format($${"id":"%s","warehouse_id":"%s","contract_id":"%s","sector_id":"%s","requester_employee_id":"%s",
  "items":[{"material_id":"%s","quantity_requested":4,"quantity_delivered":4}],
  "signature":{"storage_path":"DIR/%s/%s/assinatura_1.png"}}$$,
  :'me2', :'dir', :'contrato', :'setor', :'func1', :'filtro', :'ano', :'me2')::jsonb) as r2 \gset
select testes.igual((:'r2'::jsonb ->> 'me_number'), 'ME-DIR-' || :'ano' || '-000001', 'numeração independente para Dois Irmãos');
select testes.falha(format($$select public.inform_sa('%s', 'SA-1')$$, :'me2'), 'não permite informar');
select testes.falha(format($$update public.stock_movements set notes = 'x' where id = '%s'$$, :'me2'), 'permission denied');
select testes.falha(format($$delete from public.stock_movements where id = '%s'$$, :'me2'), 'permission denied');
commit;

-- ---------------------------------------------------------------------
-- Usuário sem perfil
-- ---------------------------------------------------------------------
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000d1', true);
select testes.igual((select count(*) from public.stock_movements)::int, 0, 'usuário sem perfil não vê MEs');
select testes.falha(format($$select public.create_movement('{"id":"%s"}')$$, :'me3'), 'não permite registrar');
commit;

-- ---------------------------------------------------------------------
-- Equipe SA: informar, duplicidade, correção, conclusão
-- ---------------------------------------------------------------------
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000b1', true);
select testes.igual((public.search_movements('{"pending_sa":true}', 1, 25) ->> 'total')::int, 2, 'pendências de SA (2 estoques)');
select testes.falha(format($$select public.inform_sa('%s', '  ')$$, :'me1'), 'Informe o número da SA');
select testes.falha(format($$select public.inform_sa('%s', 'SA #1')$$, :'me1'), 'formato inválido');
select testes.igual((public.inform_sa(:'me1', 'sa-2026-0001') ->> 'status'), 'sa_informada', 'SA informada');
select testes.igual((select sa_number from public.stock_movements where id = :'me1'), 'SA-2026-0001', 'SA normalizada em maiúsculas');
select testes.falha(format($$select public.inform_sa('%s', 'SA-2026-0001')$$, :'me2'), 'já está vinculada');
select testes.falha(format($$select public.inform_sa('%s', 'SA-2026-0009')$$, :'me1'), 'justificativa');
select testes.igual((public.inform_sa(:'me1', 'SA-2026-0009', 'Número digitado errado no ERP') ->> 'action'), 'correcao', 'correção de SA com justificativa');
select testes.igual((public.complete_movement(:'me1') ->> 'status'), 'concluida', 'ME concluída');
select testes.falha(format($$select public.inform_sa('%s', 'SA-2026-0010', 'Ajuste após conclusão')$$, :'me1'), 'Somente gestor');
select testes.falha(format($$select public.cancel_movement('%s', 'Teste de cancelamento')$$, :'me2'), 'Somente gestor');
commit;

-- ---------------------------------------------------------------------
-- Gestor: correção pós-conclusão, cancelamento, auditoria
-- ---------------------------------------------------------------------
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000c1', true);
select testes.igual((public.inform_sa(:'me1', 'SA-2026-0010', 'Ajuste após conclusão') ->> 'status'), 'concluida', 'gestor corrige SA de ME concluída');
select testes.falha(format($$select public.cancel_movement('%s', '')$$, :'me2'), 'justificativa');
select testes.igual((public.cancel_movement(:'me2', 'Material devolvido ao estoque') ->> 'status'), 'cancelada', 'cancelamento lógico');
select testes.falha(format($$select public.cancel_movement('%s', 'De novo cancelando')$$, :'me2'), 'já está cancelada');
select testes.falha(format($$select public.correct_movement('%s', '{"notes":"x"}', 'Correção qualquer')$$, :'me2'), 'somente consulta');
select testes.igual((select count(*) from public.stock_movement_items where movement_id = :'me2')::int, 1, 'cancelamento preserva itens');
select testes.igual((select count(*) from public.signatures where movement_id = :'me2')::int, 1, 'cancelamento preserva assinatura');

select testes.falha(format($$select public.correct_movement('%s', '{"notes":"Ajuste"}', '')$$, :'me1'), 'justificativa');
select public.correct_movement(:'me1', '{"notes":"Ajuste administrativo"}', 'Observação incompleta no registro');
select testes.igual((select notes from public.stock_movements where id = :'me1'), 'Ajuste administrativo', 'correção de ME concluída pelo gestor');

select testes.igual((select count(*) from public.audit_logs where movement_id = :'me1' and action like 'sa.%')::int >= 3, true, 'auditoria registra SA (inclusão e correções)');
select testes.igual((select count(*) from public.audit_logs where movement_id = :'me1' and action = 'item.incluido')::int, 2, 'auditoria registra inclusão de itens');
select testes.igual((select count(*) from public.audit_logs where movement_id = :'me1' and action = 'me.corrigida' and justification is not null)::int >= 1, true, 'auditoria registra justificativa');
select testes.igual((select count(*) from public.movement_status_history where movement_id = :'me1')::int, 3, 'histórico de status (aguardando_sa > sa_informada > concluida)');
select testes.falha($$update public.audit_logs set action = 'x'$$, 'permission denied');
select testes.falha($$delete from public.audit_logs$$, 'permission denied');

select testes.igual((public.dashboard_stats('{}') -> 'cards' ->> 'total_mes')::int, 2, 'dashboard total de MEs');
select testes.igual((public.dashboard_stats('{}') -> 'cards' ->> 'cancelada')::int, 1, 'dashboard canceladas');
select testes.igual((public.dashboard_stats('{}') -> 'cards' ->> 'item_lines')::int, 2, 'dashboard linhas (sem canceladas)');
select testes.igual((public.dashboard_stats(format('{"warehouse_id":"%s"}', :'dir')::jsonb) -> 'cards' ->> 'total_mes')::int, 1, 'dashboard filtrado por estoque');
select testes.igual((public.search_movements('{"material":"filtro"}', 1, 25) ->> 'total')::int, 2, 'filtro por material');
select testes.igual((public.search_movements('{"status":["cancelada"]}', 1, 25) ->> 'total')::int, 1, 'filtro por status');
select testes.igual((public.search_movements('{"sa_number":"0010"}', 1, 25) ->> 'total')::int, 1, 'filtro por SA');
select testes.igual((public.search_movements('{"q":"Silva"}', 1, 25) ->> 'total')::int, 2, 'pesquisa rápida por requisitante');
select testes.igual((public.search_movements(format('{"date_from":"%s","date_to":"%s"}', current_date - 1, current_date + 1)::jsonb, 1, 25) ->> 'total')::int, 2, 'filtro por período');
select testes.igual(jsonb_array_length(public.export_movements('{}', 'itens')), 3, 'exportação detalhada por item');
select testes.igual(jsonb_array_length(public.export_movements(format('{"warehouse_id":"%s"}', :'mur')::jsonb, 'resumo')), 1, 'exportação respeita filtro');
select testes.igual((select count(*) from public.audit_logs)::int > 0, true, 'gestor lê auditoria dos seus estoques');
commit;

-- Almoxarife não exporta
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000a1', true);
select testes.falha($$select public.export_movements('{}', 'resumo')$$, 'não permite exportar');
select testes.igual((select count(*) from public.audit_logs)::int, 0, 'almoxarife não lê auditoria');
commit;

-- Mesmo como dono do banco a exclusão física é bloqueada
select testes.falha(format($$delete from public.stock_movements where id = '%s'$$, :'me1'), 'Exclusão física não permitida');
select testes.falha(format($$update public.stock_movements set me_number = 'X' where id = '%s'$$, :'me1'), 'não podem ser alterados');
select testes.falha(format($$update public.signatures set storage_path = 'x' where movement_id = '%s'$$, :'me1'), 'não pode ser alterada');

\echo '>>> TODOS OS TESTES DE FLUXO PASSARAM'
