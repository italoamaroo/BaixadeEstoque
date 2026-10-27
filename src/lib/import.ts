import { downloadBlob } from './excel';

export const IMPORT_COLUMNS = [
  { key: 'code', header: 'codigo', aliases: ['codigo', 'código', 'code', 'cod', 'codigo do material'] },
  { key: 'name', header: 'nome', aliases: ['nome', 'name', 'nome do material', 'material', 'descricao curta'] },
  { key: 'unit', header: 'unidade', aliases: ['unidade', 'unid', 'un', 'unit'] },
  { key: 'reference', header: 'referencia', aliases: ['referencia', 'referência', 'ref', 'reference'] },
  { key: 'description', header: 'descricao', aliases: ['descricao', 'descrição', 'descricao complementar', 'description'] },
  { key: 'location', header: 'localizacao', aliases: ['localizacao', 'localização', 'local', 'location', 'localiz'] },
  { key: 'account_code', header: 'conta', aliases: ['conta', 'codigo da conta', 'account'] },
  { key: 'category_code', header: 'categoria', aliases: ['categoria', 'codigo da categoria', 'category'] },
  { key: 'warehouse_code', header: 'estoque', aliases: ['estoque', 'codigo do estoque', 'warehouse'] },
  { key: 'active', header: 'ativo', aliases: ['ativo', 'active', 'situacao'] },
] as const;

function norm(s: string): string {
  return s
    .normalize('NFD')
    .replace(/[̀-ͯ]/g, '')
    .toLowerCase()
    .trim()
    .replace(/[_\s]+/g, ' ');
}

function mapHeader(h: string): string | null {
  const n = norm(h);
  for (const c of IMPORT_COLUMNS) if ((c.aliases as readonly string[]).map(norm).includes(n)) return c.key;
  return null;
}

function toBool(v: unknown): boolean | undefined {
  if (v === undefined || v === null || v === '') return undefined;
  const s = norm(String(v));
  if (['sim', 's', 'true', '1', 'ativo', 'yes'].includes(s)) return true;
  if (['nao', 'n', 'false', '0', 'inativo', 'no'].includes(s)) return false;
  return undefined;
}

/** Converte CSV simples (com aspas) em matriz. Detecta ; ou , como separador. */
export function parseCsv(text: string): string[][] {
  const clean = text.replace(/^﻿/, '');
  const firstLine = clean.split(/\r?\n/, 1)[0] ?? '';
  const sep = (firstLine.match(/;/g)?.length ?? 0) >= (firstLine.match(/,/g)?.length ?? 0) ? ';' : ',';
  const rows: string[][] = [];
  let row: string[] = [];
  let cur = '';
  let quoted = false;
  for (let i = 0; i < clean.length; i++) {
    const ch = clean[i];
    if (quoted) {
      if (ch === '"' && clean[i + 1] === '"') {
        cur += '"';
        i++;
      } else if (ch === '"') quoted = false;
      else cur += ch;
    } else if (ch === '"') quoted = true;
    else if (ch === sep) {
      row.push(cur);
      cur = '';
    } else if (ch === '\n' || ch === '\r') {
      if (ch === '\r' && clean[i + 1] === '\n') i++;
      row.push(cur);
      rows.push(row);
      row = [];
      cur = '';
    } else cur += ch;
  }
  if (cur !== '' || row.length) {
    row.push(cur);
    rows.push(row);
  }
  return rows.filter((r) => r.some((c) => c.trim() !== ''));
}

export function matrixToRows(matrix: unknown[][]): Record<string, unknown>[] {
  if (matrix.length < 2) return [];
  const keys = matrix[0].map((h) => mapHeader(String(h ?? '')));
  if (!keys.includes('code') || !keys.includes('name')) {
    throw new Error('Cabeçalho inválido: o arquivo precisa ter ao menos as colunas "codigo", "nome" e "unidade".');
  }
  return matrix.slice(1).map((line) => {
    const out: Record<string, unknown> = {};
    keys.forEach((k, i) => {
      if (!k) return;
      const raw = line[i];
      const v = raw === null || raw === undefined ? '' : String(typeof raw === 'object' && 'text' in (raw as object) ? (raw as { text: string }).text : raw).trim();
      if (k === 'active') {
        const b = toBool(v);
        if (b !== undefined) out.active = b;
      } else out[k] = v;
    });
    return out;
  });
}

export async function parseImportFile(file: File): Promise<Record<string, unknown>[]> {
  if (file.size > 5 * 1024 * 1024) throw new Error('Arquivo maior que 5 MB.');
  if (/\.csv$/i.test(file.name) || file.type === 'text/csv') {
    return matrixToRows(parseCsv(await file.text()));
  }
  if (/\.xlsx$/i.test(file.name)) {
    const ExcelJS = (await import('exceljs')).default;
    const wb = new ExcelJS.Workbook();
    await wb.xlsx.load(await file.arrayBuffer());
    const ws = wb.worksheets[0];
    if (!ws) throw new Error('Planilha vazia.');
    const matrix: unknown[][] = [];
    ws.eachRow({ includeEmpty: false }, (row) => {
      const values = (row.values as unknown[]).slice(1);
      matrix.push(values);
    });
    return matrixToRows(matrix);
  }
  throw new Error('Formato não suportado. Use .xlsx ou .csv.');
}

export async function downloadImportTemplate() {
  const ExcelJS = (await import('exceljs')).default;
  const wb = new ExcelJS.Workbook();
  const ws = wb.addWorksheet('materiais');
  ws.columns = IMPORT_COLUMNS.map((c) => ({ header: c.header, key: c.key, width: 22 }));
  ws.addRow({ code: 'MAT-0001', name: 'Óleo lubrificante 15W40', unit: 'L', reference: 'SAE 15W40', description: 'Balde 20 L', location: 'A-01-01', account_code: '', category_code: 'LUB', warehouse_code: '', active: 'sim' });
  ws.getRow(1).font = { bold: true };
  const buf = await wb.xlsx.writeBuffer();
  downloadBlob(new Blob([buf], { type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' }), 'modelo_importacao_materiais.xlsx');
}
