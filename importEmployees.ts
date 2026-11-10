import { downloadBlob } from './excel';
import { parseCsv } from './import';

/** Colunas aceitas na planilha de funcionários (requisitantes/recebedores). */
export const EMPLOYEE_COLUMNS = [
  { key: 'registration', header: 'matricula', aliases: ['matricula', 'matrícula', 'mat', 'mat.', 'registro', 're', 'chapa', 'cracha', 'crachá', 'codigo', 'código', 'cod', 'cod. funcionario', 'codigo do funcionario', 'id'] },
  { key: 'full_name', header: 'nome', aliases: ['nome', 'nome completo', 'funcionario', 'funcionário', 'colaborador', 'empregado', 'nome do funcionario', 'nome do colaborador'] },
  { key: 'job_title', header: 'cargo', aliases: ['cargo', 'funcao', 'função', 'ocupacao', 'ocupação', 'cargo/funcao'] },
  { key: 'sector', header: 'setor', aliases: ['setor', 'departamento', 'depto', 'area', 'área', 'lotacao', 'lotação', 'centro de custo', 'secao', 'seção'] },
  { key: 'active', header: 'ativo', aliases: ['ativo', 'situacao', 'situação', 'status', 'active'] },
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
  for (const c of EMPLOYEE_COLUMNS) if ((c.aliases as readonly string[]).map(norm).includes(n)) return c.key;
  return null;
}

function cellText(raw: unknown): string {
  if (raw === null || raw === undefined) return '';
  if (typeof raw === 'object') {
    const o = raw as { text?: unknown; result?: unknown; richText?: { text: string }[] };
    if (o.richText) return o.richText.map((r) => r.text).join('').trim();
    if (o.text !== undefined) return String(o.text).trim();
    if (o.result !== undefined) return String(o.result).trim();
  }
  if (typeof raw === 'number' && Number.isInteger(raw)) return String(raw);
  return String(raw).trim();
}

function toBool(v: string): boolean | undefined {
  const s = norm(v);
  if (!s) return undefined;
  if (['sim', 's', 'true', '1', 'ativo', 'yes', 'a'].includes(s)) return true;
  if (['nao', 'n', 'false', '0', 'inativo', 'no', 'desligado', 'demitido', 'i'].includes(s)) return false;
  return undefined;
}

/** Converte a planilha em linhas de funcionário. Procura o cabeçalho nas 15 primeiras linhas. */
export function employeeMatrixToRows(matrix: unknown[][]): Record<string, unknown>[] {
  let headerIdx = -1;
  let keys: (string | null)[] = [];
  for (let i = 0; i < Math.min(matrix.length, 15); i++) {
    const k = (matrix[i] ?? []).map((h) => mapHeader(cellText(h)));
    if (k.includes('registration') && k.includes('full_name')) {
      headerIdx = i;
      keys = k;
      break;
    }
  }
  if (headerIdx < 0) {
    throw new Error('Cabeçalho não encontrado: a planilha precisa ter as colunas "matricula" e "nome".');
  }
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
    .filter((r) => Object.values(r).some((v) => v !== '' && v !== undefined));
}

export async function parseEmployeesFile(file: File): Promise<Record<string, unknown>[]> {
  if (file.size > 5 * 1024 * 1024) throw new Error('Arquivo maior que 5 MB.');
  if (/\.xls$/i.test(file.name)) {
    throw new Error('Arquivo .xls (Excel antigo) não é suportado. No Excel, use "Salvar como" > "Pasta de Trabalho do Excel (.xlsx)".');
  }
  if (/\.csv$/i.test(file.name) || file.type === 'text/csv') {
    return employeeMatrixToRows(parseCsv(await file.text()));
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
    return employeeMatrixToRows(matrix);
  }
  throw new Error('Formato não suportado. Use .xlsx ou .csv.');
}

export async function downloadEmployeesTemplate() {
  const ExcelJS = (await import('exceljs')).default;
  const wb = new ExcelJS.Workbook();
  const ws = wb.addWorksheet('funcionarios');
  ws.columns = EMPLOYEE_COLUMNS.map((c) => ({ header: c.header, key: c.key, width: c.key === 'full_name' ? 36 : 20 }));
  ws.addRow({ registration: '12345', full_name: 'José Carlos da Silva', job_title: 'Mecânico', sector: 'Manutenção mecânica', active: 'sim' });
  ws.addRow({ registration: '12346', full_name: 'Maria Aparecida Santos', job_title: 'Eletricista', sector: 'Manutenção elétrica', active: 'sim' });
  ws.getRow(1).font = { bold: true };
  const buf = await wb.xlsx.writeBuffer();
  downloadBlob(new Blob([buf], { type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' }), 'modelo_importacao_funcionarios.xlsx');
}
