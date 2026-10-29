import { downloadBlob } from './excel';

export const IMPORT_COLUMNS = [
  { key: 'code', header: 'codigo', aliases: ['codigo', 'código', 'code', 'cod', 'cod.', 'codigo do material', 'cod material', 'cod. material', 'codigo produto', 'cod produto', 'cod. produto', 'codigo do produto', 'produto', 'item', 'cod item', 'codigo item', 'sku'] },
  { key: 'name', header: 'nome', aliases: ['nome', 'name', 'nome do material', 'material', 'nome do produto', 'descricao do produto', 'descrição do produto', 'desc produto', 'descricao curta', 'descricao resumida'] },
  { key: 'unit', header: 'unidade', aliases: ['unidade', 'unid', 'unid.', 'un', 'und', 'um', 'u.m.', 'unidade de medida', 'unidade medida', 'unit'] },
  { key: 'reference', header: 'referencia', aliases: ['referencia', 'referência', 'ref', 'ref.', 'reference', 'referencia fabricante', 'part number', 'pn', 'cod fabricante'] },
  { key: 'description', header: 'descricao', aliases: ['descricao', 'descrição', 'desc', 'descricao complementar', 'descrição complementar', 'complemento', 'description', 'observacao'] },
  { key: 'location', header: 'localizacao', aliases: ['localizacao', 'localização', 'local', 'location', 'localiz', 'localiz.', 'endereco', 'endereço', 'posicao', 'prateleira'] },
  { key: 'account_code', header: 'conta', aliases: ['conta', 'codigo da conta', 'conta contabil', 'conta contábil', 'centro de custo', 'account'] },
  { key: 'category_code', header: 'categoria', aliases: ['categoria', 'codigo da categoria', 'grupo', 'familia', 'família', 'category'] },
  { key: 'warehouse_code', header: 'estoque', aliases: ['estoque', 'codigo do estoque', 'almoxarifado', 'warehouse'] },
  { key: 'active', header: 'ativo', aliases: ['ativo', 'active', 'situacao', 'situação', 'status'] },
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

/**
 * Converte a planilha em linhas de material.
 * - procura a linha de cabeçalho nas 15 primeiras linhas (planilhas de ERP costumam ter título acima);
 * - se não houver coluna "nome" mas houver "descrição", usa a descrição como nome.
 */
export function matrixToRows(matrix: unknown[][]): Record<string, unknown>[] {
  let headerIdx = -1;
  let keys: (string | null)[] = [];
  for (let i = 0; i < Math.min(matrix.length, 15); i++) {
    const k = matrix[i].map((h) => mapHeader(cellText(h)));
    if (k.includes('code') && (k.includes('name') || k.includes('description'))) {
      headerIdx = i;
      keys = k;
      break;
    }
  }
  if (headerIdx < 0) {
    throw new Error('Cabeçalho não encontrado: a planilha precisa ter as colunas "codigo", "nome" (ou "descricao") e "unidade".');
  }
  const useDescriptionAsName = !keys.includes('name');
  return matrix
    .slice(headerIdx + 1)
    .map((line) => {
      const out: Record<string, unknown> = {};
      keys.forEach((k, i) => {
        if (!k) return;
        const v = cellText(line[i]);
        if (k === 'active') {
          const b = toBool(v);
          if (b !== undefined) out.active = b;
        } else if (out[k] === undefined || out[k] === '') out[k] = v;
      });
      if (useDescriptionAsName) {
        out.name = out.description ?? '';
        delete out.description;
      }
      return out;
    })
    .filter((r) => Object.values(r).some((v) => v !== '' && v !== undefined));
}

/** Lê a primeira aba de um .xlsx ou um .csv e devolve a matriz de células. */
export async function readSheetMatrix(file: File): Promise<unknown[][]> {
  if (file.size > 5 * 1024 * 1024) throw new Error('Arquivo maior que 5 MB.');
  if (/\.csv$/i.test(file.name) || file.type === 'text/csv') return parseCsv(await file.text());
  if (/\.xls$/i.test(file.name)) {
    throw new Error('Arquivo .xls (Excel antigo) não é suportado. No Excel, use "Salvar como" > "Pasta de Trabalho do Excel (.xlsx)".');
  }
  if (/\.xlsx$/i.test(file.name)) {
    const ExcelJS = (await import('exceljs')).default;
    const wb = new ExcelJS.Workbook();
    await wb.xlsx.load(await file.arrayBuffer());
    const ws = wb.worksheets[0];
    if (!ws) throw new Error('Planilha vazia.');
    const matrix: unknown[][] = [];
    ws.eachRow({ includeEmpty: false }, (row) => {
      matrix.push((row.values as unknown[]).slice(1));
    });
    if (matrix.length === 0) throw new Error('Planilha vazia.');
    return matrix;
  }
  throw new Error('Formato não suportado. Use .xlsx ou .csv.');
}

export async function parseImportFile(file: File): Promise<Record<string, unknown>[]> {
  return matrixToRows(await readSheetMatrix(file));
}

// ---------------------------------------------------------------------------
// Planilha para ETIQUETAS: código obrigatório; cópias, nome e unidade opcionais
// ---------------------------------------------------------------------------
const COPY_ALIASES = ['copias', 'cópias', 'qtd', 'qtde', 'quantidade', 'quant', 'etiquetas', 'qtd etiquetas', 'quantidade de etiquetas', 'copies'];

export interface LabelSheetRow {
  code: string;
  copies: number;
  /** demais colunas reconhecidas (nome, unidade...) para cadastrar itens que não existirem */
  material: Record<string, unknown>;
}

export function labelMatrixToRows(matrix: unknown[][]): LabelSheetRow[] {
  let headerIdx = -1;
  let keys: (string | null)[] = [];
  for (let i = 0; i < Math.min(matrix.length, 15); i++) {
    const k = (matrix[i] ?? []).map((h) => {
      const t = cellText(h);
      return COPY_ALIASES.map(norm).includes(norm(t)) ? 'copies' : mapHeader(t);
    });
    if (k.includes('code')) {
      headerIdx = i;
      keys = k;
      break;
    }
  }
  if (headerIdx < 0) throw new Error('Cabeçalho não encontrado: a planilha precisa ter a coluna "codigo" (código do material).');
  const useDescriptionAsName = !keys.includes('name');
  const byCode = new Map<string, LabelSheetRow>();
  for (const line of matrix.slice(headerIdx + 1)) {
    const material: Record<string, unknown> = {};
    let copies = 1;
    keys.forEach((k, i) => {
      if (!k) return;
      const v = cellText((line ?? [])[i]);
      if (k === 'copies') {
        const n = Math.floor(Number(v.replace(',', '.')));
        copies = Number.isFinite(n) && n > 0 ? Math.min(n, 100) : 1;
      } else if (k === 'active') {
        const b = toBool(v);
        if (b !== undefined) material.active = b;
      } else if (material[k] === undefined || material[k] === '') material[k] = v;
    });
    if (useDescriptionAsName && material.description) {
      material.name = material.description;
      delete material.description;
    }
    const code = String(material.code ?? '').trim().toUpperCase();
    if (!code) continue;
    const prev = byCode.get(code);
    if (prev) prev.copies = Math.min(prev.copies + copies, 100);
    else byCode.set(code, { code, copies, material: { ...material, code } });
  }
  return [...byCode.values()];
}

export async function parseLabelsFile(file: File): Promise<LabelSheetRow[]> {
  return labelMatrixToRows(await readSheetMatrix(file));
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
