import { downloadBlob } from './excel';
import { readSheetMatrix } from './import';
import type { LookupTable } from './constants';

/** Colunas aceitas na planilha de cadastros auxiliares (ativos fixos, locais de aplicação etc.). */
export const LOOKUP_IMPORT_COLUMNS = [
  { key: 'code', header: 'codigo' },
  { key: 'name', header: 'nome' },
  { key: 'kind', header: 'tipo' },
  { key: 'active', header: 'ativo' },
] as const;

const CODE = ['codigo', 'código', 'cod', 'cod.', 'code', 'sigla', 'numero', 'número', 'nº', 'n°', 'id'];
const NAME = ['nome', 'descricao', 'descrição', 'desc', 'denominacao', 'denominação', 'name', 'nome / descricao', 'nome/descricao'];
const KIND = ['tipo', 'kind', 'categoria do registro'];
const ACTIVE = ['ativo', 'situacao', 'situação', 'status', 'active'];

/** Sinônimos extras por tabela (ex.: em ativos fixos, "Ativo", "Patrimônio" ou "Plaqueta" é o código). */
const EXTRA_CODE: Partial<Record<LookupTable, string[]>> = {
  fixed_assets: ['ativo', 'ativo fixo', 'cod ativo', 'codigo do ativo', 'código do ativo', 'numero do ativo', 'nº do ativo', 'patrimonio', 'patrimônio', 'plaqueta', 'tag', 'placa', 'af'],
  application_locations: ['local', 'cod local', 'codigo do local', 'código do local', 'local de aplicacao', 'local de aplicação'],
  service_orders: ['os', 'o.s.', 'ordem de servico', 'ordem de serviço', 'numero da os', 'nº da os'],
  contracts: ['contrato', 'numero do contrato', 'nº do contrato'],
  sectors: ['setor', 'cod setor'],
  accounts: ['conta', 'conta contabil', 'conta contábil', 'centro de custo'],
};
const EXTRA_NAME: Partial<Record<LookupTable, string[]>> = {
  fixed_assets: ['descricao do ativo', 'descrição do ativo', 'equipamento', 'veiculo', 'veículo', 'bem'],
  application_locations: ['descricao do local', 'descrição do local', 'nome do local'],
};

function norm(s: string): string {
  return s
    .normalize('NFD')
    .replace(/[̀-ͯ]/g, '')
    .toLowerCase()
    .trim()
    .replace(/[_\s]+/g, ' ');
}

function cellText(raw: unknown): string {
  if (raw === null || raw === undefined) return '';
  if (typeof raw === 'object') {
    const o = raw as { text?: unknown; result?: unknown; richText?: { text: string }[] };
    if (o.richText) return o.richText.map((r) => r.text).join('').trim();
    if (o.text !== undefined) return String(o.text).trim();
    if (o.result !== undefined) return String(o.result).trim();
  }
  return String(raw).trim();
}

function toBool(v: string): boolean | undefined {
  const s = norm(v);
  if (!s) return undefined;
  if (['sim', 's', 'true', '1', 'ativo', 'yes', 'a'].includes(s)) return true;
  if (['nao', 'n', 'false', '0', 'inativo', 'no', 'i', 'baixado'].includes(s)) return false;
  return undefined;
}

function headerMapper(table: LookupTable) {
  const code = [...(EXTRA_CODE[table] ?? []), ...CODE].map(norm);
  const name = [...(EXTRA_NAME[table] ?? []), ...NAME].map(norm);
  const kind = KIND.map(norm);
  // em ativos fixos a coluna "ativo" é o código do ativo, não a situação
  const active = ACTIVE.map(norm).filter((a) => !code.includes(a));
  return (h: string): string | null => {
    const n = norm(h);
    if (!n) return null;
    if (code.includes(n)) return 'code';
    if (name.includes(n)) return 'name';
    if (table === 'service_fronts' && kind.includes(n)) return 'kind';
    if (active.includes(n)) return 'active';
    return null;
  };
}

/** Converte a planilha em linhas {code, name, kind?, active?}. Procura o cabeçalho nas 15 primeiras linhas. */
export function lookupMatrixToRows(table: LookupTable, matrix: unknown[][]): Record<string, unknown>[] {
  const map = headerMapper(table);
  let headerIdx = -1;
  let keys: (string | null)[] = [];
  for (let i = 0; i < Math.min(matrix.length, 15); i++) {
    const k = (matrix[i] ?? []).map((h) => map(cellText(h)));
    if (k.includes('code') && k.includes('name')) {
      headerIdx = i;
      keys = k;
      break;
    }
  }
  if (headerIdx < 0) throw new Error('Cabeçalho não encontrado: a planilha precisa ter as colunas "codigo" e "nome" (ou "descricao").');
  return matrix
    .slice(headerIdx + 1)
    .map((line) => {
      const out: Record<string, unknown> = {};
      keys.forEach((k, i) => {
        if (!k) return;
        const v = cellText((line ?? [])[i]);
        if (k === 'active') {
          const b = toBool(v);
          if (b !== undefined) out.active = b;
        } else if (out[k] === undefined || out[k] === '') out[k] = v;
      });
      return out;
    })
    .filter((r) => String(r.code ?? '').trim() !== '' || String(r.name ?? '').trim() !== '');
}

export async function parseLookupFile(table: LookupTable, file: File): Promise<Record<string, unknown>[]> {
  return lookupMatrixToRows(table, await readSheetMatrix(file));
}

const EXAMPLES: Partial<Record<LookupTable, [string, string][]>> = {
  fixed_assets: [
    ['AF-0101', 'Caminhão compactador 15m³ - placa ABC1D23'],
    ['AF-0102', 'Pá carregadeira 924K'],
  ],
  application_locations: [
    ['LOC-OFI', 'Oficina central'],
    ['LOC-PAT', 'Pátio de manobras'],
  ],
};

export async function downloadLookupTemplate(table: LookupTable, fileLabel: string) {
  const ExcelJS = (await import('exceljs')).default;
  const wb = new ExcelJS.Workbook();
  const ws = wb.addWorksheet('cadastro');
  const cols = LOOKUP_IMPORT_COLUMNS.filter((c) => c.key !== 'kind' || table === 'service_fronts');
  ws.columns = cols.map((c) => ({ header: c.header, key: c.key, width: c.key === 'name' ? 44 : 18 }));
  for (const [code, name] of EXAMPLES[table] ?? [['COD-01', 'Descrição do registro']]) {
    ws.addRow({ code, name, kind: 'equipamento', active: 'sim' });
  }
  ws.getRow(1).font = { bold: true };
  const buf = await wb.xlsx.writeBuffer();
  downloadBlob(
    new Blob([buf], { type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' }),
    `modelo_importacao_${fileLabel}.xlsx`,
  );
}
