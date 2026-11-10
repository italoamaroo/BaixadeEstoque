import { describe, expect, it } from 'vitest';
import { parseQty, slugify } from './format';
import { saNumberError, materialSchema, firstError } from './validation';
import { parseCsv, matrixToRows, labelMatrixToRows } from './import';
import { mapExportRows } from './excel';
import { toAppError } from './errors';
import { buildSignaturePath } from './signature';
import { can } from './constants';

describe('formatos', () => {
  it('converte quantidades com vírgula', () => {
    expect(parseQty('1,5')).toBe(1.5);
    expect(parseQty('1.250,75')).toBe(1250.75);
    expect(parseQty('2')).toBe(2);
    expect(Number.isNaN(parseQty('abc'))).toBe(true);
  });
  it('slug sem acentos', () => expect(slugify('Dois Irmãos')).toBe('dois_irmaos'));
});

describe('validações', () => {
  const pattern = '^[A-Za-z0-9./-]{3,30}$';
  it('número da SA', () => {
    expect(saNumberError('', pattern)).toMatch(/Informe/);
    expect(saNumberError('SA #1', pattern)).toMatch(/inválido/);
    expect(saNumberError('SA-2026-001', pattern)).toBeNull();
  });
  it('material', () => {
    expect(firstError(materialSchema.safeParse({ code: '', name: 'x', unit: 'UN', active: true }))).toMatch(/código/);
    expect(firstError(materialSchema.safeParse({ code: 'A1', name: 'Filtro', unit: 'UN', active: true, qr_code: '' }))).toBeNull();
  });
});

describe('importação', () => {
  it('lê CSV com ; e aspas e mapeia cabeçalhos em português', () => {
    const csv = '﻿Código;Nome;Unidade;Ativo\nA-1;"Filtro; óleo";UN;sim\nA-2;Graxa;KG;não\n';
    const rows = matrixToRows(parseCsv(csv));
    expect(rows).toEqual([
      { code: 'A-1', name: 'Filtro; óleo', unit: 'UN', active: true },
      { code: 'A-2', name: 'Graxa', unit: 'KG', active: false },
    ]);
  });
  it('rejeita cabeçalho sem código', () => {
    expect(() => matrixToRows([['x', 'y'], ['1', '2']])).toThrow(/Cabeçalho/);
  });
});

describe('excel', () => {
  it('prepara linhas com status e datas', () => {
    const [r] = mapExportRows([{ me_number: 'ME-MUR-2026-000001', movement_at: '2026-10-27T12:30:00Z', status: 'aguardando_sa', quantity_delivered: '2.5' }]);
    expect(r.status_label).toBe('Aguardando SA');
    expect(r.date).toBeInstanceOf(Date);
    expect(r.quantity_delivered).toBe(2.5);
  });
});

describe('erros', () => {
  it('traduz falha de rede e permissão', () => {
    expect(toAppError(new TypeError('Failed to fetch')).isNetwork).toBe(true);
    expect(toAppError({ message: 'new row violates row-level security policy', code: '42501' }).message).toMatch(/permissão/);
    expect(toAppError({ message: 'A SA X já está vinculada à ME Y.', code: '23505' }).message).toMatch(/vinculada/);
  });
});

describe('assinatura e permissões', () => {
  it('caminho no padrão {estoque}/{ano}/{id}/arquivo', () => {
    const p = buildSignaturePath('MUR', '11111111-1111-4111-8111-111111111111', 'America/Recife', new Date('2026-12-31T23:30:00-03:00'));
    expect(p).toMatch(/^MUR\/2026\/11111111-1111-4111-8111-111111111111\/assinatura_\d{14}\.png$/);
  });
  it('perfis', () => {
    expect(can(['almoxarife'], 'createMovement')).toBe(true);
    expect(can(['almoxarife'], 'informSa')).toBe(false);
    expect(can(['equipe_sa'], 'cancelMovement')).toBe(false);
    expect(can(['gestor'], 'cancelMovement')).toBe(true);
  });
});

describe('importação de planilha do ERP', () => {
  it('acha o cabeçalho abaixo do título e usa descrição como nome', () => {
    const rows = matrixToRows([
      ['Relatório de produtos'],
      [],
      ['Cód. Produto', 'Descrição do Produto', 'UM', 'Endereço'],
      ['OP34400710015D', 'Tampa da caixa', 'UN', ''],
      ['', '', '', ''],
    ]);
    expect(rows).toEqual([{ code: 'OP34400710015D', name: 'Tampa da caixa', unit: 'UN', location: '' }]);
  });
  it('usa descrição como nome quando não há coluna nome', () => {
    const rows = matrixToRows([['Código', 'Descrição', 'Unidade'], ['A1', 'Filtro', 'UN']]);
    expect(rows[0]).toEqual({ code: 'A1', name: 'Filtro', unit: 'UN' });
  });
});

describe('planilha de etiquetas', () => {
  it('lê código e cópias, soma repetidos e usa descrição como nome', async () => {
    const { labelMatrixToRows } = await import('./import');
    const rows = labelMatrixToRows([
      ['Lista para etiquetas'],
      ['Cód. Produto', 'Descrição do Produto', 'UM', 'Qtd'],
      ['bc002a83', 'ADESIVO LOCTITE 496 50G', 'UN', 3],
      ['BC002A83', '', '', 2],
      ['AA001466D', 'SERRA COPO', 'PC', ''],
    ]);
    expect(rows.map((r) => [r.code, r.copies])).toEqual([
      ['BC002A83', 5],
      ['AA001466D', 1],
    ]);
    expect(rows[0].material).toMatchObject({ code: 'BC002A83', name: 'ADESIVO LOCTITE 496 50G', unit: 'UN' });
  });
});

describe('etiquetas: localização da planilha', () => {
  it('usa a localização da planilha e separa o mesmo código em locais diferentes', () => {
    const rows = labelMatrixToRows([
      ['codigo', 'copias', 'localizacao'],
      ['kn0821', '2', 'B-18'],
      ['KN0821', '1', 'b-18'],
      ['KN0821', '1', 'C-02'],
      ['AA1', '1', ''],
    ]);
    expect(rows).toHaveLength(3);
    expect(rows[0]).toMatchObject({ code: 'KN0821', copies: 3, location: 'B-18' });
    expect(rows[1]).toMatchObject({ code: 'KN0821', copies: 1, location: 'C-02' });
    expect(rows[2].location).toBeUndefined();
  });
});
