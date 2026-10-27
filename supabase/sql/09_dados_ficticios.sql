-- =====================================================================
-- 09 - DADOS FICTÍCIOS PARA DEMONSTRAÇÃO E TESTE
-- ATENÇÃO: todos os registros abaixo são FICTÍCIOS.
-- Identificação: códigos e matrículas iniciados por "DEMO-".
-- Para remover depois: execute 99_remover_dados_ficticios.sql
--
-- Este script cria cadastros (contratos, setores, frentes, equipamentos,
-- OS, ativos, locais, contas, funcionários e materiais com QR Code).
-- As MEs fictícias (com assinatura real no Storage, SA, concluídas e
-- canceladas) são criadas pelo script "npm run demo:seed", que usa o
-- fluxo verdadeiro do sistema (ver README, seção 14).
-- =====================================================================

insert into public.contracts (code, name) values
  ('DEMO-CT-001', 'Coleta domiciliar - Lote Norte (fictício)'),
  ('DEMO-CT-002', 'Limpeza urbana e varrição - Lote Sul (fictício)'),
  ('DEMO-CT-003', 'Operação do aterro e transbordo (fictício)')
on conflict (code) do nothing;

insert into public.sectors (code, name) values
  ('DEMO-SET-MAN', 'Manutenção mecânica'),
  ('DEMO-SET-ELE', 'Manutenção elétrica'),
  ('DEMO-SET-OPE', 'Operação de coleta'),
  ('DEMO-SET-VAR', 'Varrição e limpeza'),
  ('DEMO-SET-ATE', 'Operação do aterro')
on conflict (code) do nothing;

insert into public.service_fronts (code, name, kind) values
  ('DEMO-FR-01', 'Frente Coleta Zona Norte', 'frente'),
  ('DEMO-FR-02', 'Frente Varrição Centro', 'frente'),
  ('DEMO-FR-03', 'Frente Aterro - Célula 4', 'frente'),
  ('DEMO-EQ-101', 'Caminhão compactador 15m³ - placa DEM0A01', 'equipamento'),
  ('DEMO-EQ-102', 'Caminhão compactador 19m³ - placa DEM0B02', 'equipamento'),
  ('DEMO-EQ-201', 'Pá carregadeira - frota 201', 'equipamento'),
  ('DEMO-EQ-301', 'Trator de esteira - frota 301', 'equipamento')
on conflict (code) do nothing;

insert into public.service_orders (code, name) values
  ('DEMO-OS-24101', 'Troca de óleo e filtros - frota 101'),
  ('DEMO-OS-24102', 'Substituição de pneus - frota 102'),
  ('DEMO-OS-24201', 'Revisão sistema de transmissão - frota 201'),
  ('DEMO-OS-24301', 'Lubrificação geral - frota 301')
on conflict (code) do nothing;

insert into public.fixed_assets (code, name) values
  ('DEMO-AF-0101', 'Caminhão compactador frota 101'),
  ('DEMO-AF-0102', 'Caminhão compactador frota 102'),
  ('DEMO-AF-0201', 'Pá carregadeira frota 201'),
  ('DEMO-AF-0301', 'Trator de esteira frota 301')
on conflict (code) do nothing;

insert into public.application_locations (code, name) values
  ('DEMO-LA-OFI', 'Oficina central'),
  ('DEMO-LA-PAT', 'Pátio de veículos'),
  ('DEMO-LA-CEL', 'Aterro - Célula 4'),
  ('DEMO-LA-BAS', 'Base operacional Zona Norte')
on conflict (code) do nothing;

insert into public.accounts (code, name) values
  ('DEMO-3.1.01', 'Manutenção de frota'),
  ('DEMO-3.1.02', 'Pneus e rodagem'),
  ('DEMO-3.1.05', 'Material de segurança (EPI)'),
  ('DEMO-3.1.07', 'Material de consumo da oficina')
on conflict (code) do nothing;

insert into public.employees (registration, full_name, job_title, sector_id)
select v.reg, v.nome, v.cargo, s.id
  from (values
    ('DEMO-1001', 'José Carlos da Silva',     'Mecânico (fictício)',            'DEMO-SET-MAN'),
    ('DEMO-1002', 'Maria Aparecida Santos',   'Eletricista (fictício)',         'DEMO-SET-ELE'),
    ('DEMO-1003', 'Antônio Ferreira Lima',    'Motorista coletor (fictício)',   'DEMO-SET-OPE'),
    ('DEMO-1004', 'Francisca Oliveira Souza', 'Encarregada de varrição (fictício)', 'DEMO-SET-VAR'),
    ('DEMO-1005', 'Paulo Roberto Barbosa',    'Operador de máquinas (fictício)', 'DEMO-SET-ATE'),
    ('DEMO-1006', 'Edvaldo Pereira Costa',    'Lubrificador (fictício)',        'DEMO-SET-MAN'),
    ('DEMO-1007', 'Severino Alves de Melo',   'Borracheiro (fictício)',         'DEMO-SET-MAN'),
    ('DEMO-1008', 'Luciana Gomes Cavalcanti', 'Técnica de segurança (fictício)', 'DEMO-SET-OPE')
  ) as v(reg, nome, cargo, setor)
  join public.sectors s on s.code = v.setor
on conflict (registration) do nothing;

-- Materiais com QR Code fixo (facilita imprimir e testar)
insert into public.materials (code, reference, name, description, unit, location, account_id, category_id, qr_code)
select v.code, v.ref, v.nome, v.descr, v.un, v.loc, a.id, c.id, v.qr
  from (values
    ('DEMO-0001', 'SAE 15W40 CI-4',   'Óleo lubrificante 15W40',          '[FICTÍCIO] Óleo para motor diesel, balde 20 L', 'L',  'A-01-01', 'DEMO-3.1.01', 'LUB', 'MAT-DEMO000001'),
    ('DEMO-0002', 'PSL 610',          'Filtro de óleo',                   '[FICTÍCIO] Filtro de óleo lubrificante para compactador', 'UN', 'B-02-03', 'DEMO-3.1.01', 'FIL', 'MAT-DEMO000002'),
    ('DEMO-0003', 'PSC 496',          'Filtro de combustível',            '[FICTÍCIO] Filtro separador de água e diesel', 'UN', 'B-02-04', 'DEMO-3.1.01', 'FIL', 'MAT-DEMO000003'),
    ('DEMO-0004', '275/80R22.5',      'Pneu radial 275/80 R22.5',         '[FICTÍCIO] Pneu liso para eixo direcional', 'UN', 'P-01-01', 'DEMO-3.1.02', 'PNE', 'MAT-DEMO000004'),
    ('DEMO-0005', 'NLGI 2 LÍTIO',     'Graxa de lítio NLGI 2',            '[FICTÍCIO] Graxa multiuso, balde 20 kg', 'KG', 'A-01-05', 'DEMO-3.1.01', 'LUB', 'MAT-DEMO000005'),
    ('DEMO-0006', 'B-58',             'Correia em V B-58',                '[FICTÍCIO] Correia do alternador', 'UN', 'C-03-02', 'DEMO-3.1.01', 'TRA', 'MAT-DEMO000006'),
    ('DEMO-0007', '6205-2RS',         'Rolamento 6205-2RS',               '[FICTÍCIO] Rolamento rígido de esferas vedado', 'UN', 'C-04-01', 'DEMO-3.1.01', 'ROL', 'MAT-DEMO000007'),
    ('DEMO-0008', 'CA 12345 TAM 9',   'Luva de proteção nitrílica',       '[FICTÍCIO] Luva de segurança tamanho 9, par', 'PAR','E-01-02', 'DEMO-3.1.05', 'EPI', 'MAT-DEMO000008'),
    ('DEMO-0009', '115X1,0MM',        'Disco de corte 4.1/2"',            '[FICTÍCIO] Disco de corte para inox 115 x 1,0 mm', 'UN', 'D-02-01', 'DEMO-3.1.07', 'ABR', 'MAT-DEMO000009'),
    ('DEMO-0010', 'H7 24V 70W',       'Lâmpada automotiva H7 24V',        '[FICTÍCIO] Lâmpada halógena para farol', 'UN', 'D-05-03', 'DEMO-3.1.01', 'ELE', 'MAT-DEMO000010'),
    ('DEMO-0011', 'ATF DEXRON III',   'Óleo de transmissão ATF',          '[FICTÍCIO] Fluido de transmissão automática, frasco 1 L', 'L', 'A-01-02', 'DEMO-3.1.01', 'LUB', 'MAT-DEMO000011'),
    ('DEMO-0012', 'PA 4520',          'Filtro de ar primário',            '[FICTÍCIO] Elemento filtrante de ar - INATIVO para teste', 'UN', 'B-02-05', 'DEMO-3.1.01', 'FIL', 'MAT-DEMO000012')
  ) as v(code, ref, nome, descr, un, loc, conta, cat, qr)
  left join public.accounts a on a.code = v.conta
  left join public.material_categories c on c.code = v.cat
on conflict (code) do nothing;

-- Um material inativo para testar o bloqueio na leitura
update public.materials set active = false where code = 'DEMO-0012';
