/**
 * Importação da base de fotos: pastas com o CPF de cada funcionário (com subpastas 1..5)
 * e uma planilha que liga CPF à matrícula. Tudo acontece no navegador; o CPF não é enviado.
 */
import { readSheetMatrix } from './import';

export const onlyDigits = (s: string) => s.replace(/\D/g, '');

/** CPF com 11 dígitos (planilhas costumam perder os zeros à esquerda). */
export function normalizeCpf(v: unknown): string | null {
  const d = onlyDigits(String(v ?? ''));
  if (!d || d.length > 11) return null;
  return d.padStart(11, '0');
}

/** Mostra só o final do CPF (para conferência na tela). */
export const maskCpf = (cpf: string) => `***.***.${cpf.slice(6, 9)}-${cpf.slice(9)}`;

const IMG = /\.(jpe?g|png|webp|bmp)$/i;

/** Agrupa as fotos pela pasta com o CPF (qualquer nível do caminho). Até 5 por pessoa. */
export function groupPhotosByCpf(files: { name: string; path: string }[], maxPerPerson = 5): Map<string, string[]> {
  const out = new Map<string, string[]>();
  for (const f of files) {
    if (!IMG.test(f.name)) continue;
    const parts = f.path.split('/').slice(0, -1);
    const seg = parts.reverse().find((p) => /^\d{3}\.?\d{3}\.?\d{3}-?\d{2}$/.test(p.trim()) || /^\d{9,11}$/.test(p.trim()));
    const cpf = seg ? normalizeCpf(seg) : null;
    if (!cpf) continue;
    const list = out.get(cpf) ?? [];
    if (list.length < maxPerPerson) list.push(f.path);
    out.set(cpf, list);
  }
  return out;
}

const norm = (s: string) =>
  s
    .normalize('NFD')
    .replace(/[̀-ͯ]/g, '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, ' ')
    .trim();

/** Lê a planilha CPF → matrícula (procura o cabeçalho nas 15 primeiras linhas). */
export function cpfMapFromMatrix(matrix: unknown[][]): { map: Map<string, string>; cpfHeader: string; regHeader: string } {
  const text = (v: unknown) => {
    if (v && typeof v === 'object') {
      const o = v as { text?: unknown; result?: unknown; richText?: { text: string }[] };
      if (o.richText) return o.richText.map((r) => r.text).join('');
      if (o.text !== undefined) return String(o.text);
      if (o.result !== undefined) return String(o.result);
    }
    return v === null || v === undefined ? '' : String(v);
  };
  for (let i = 0; i < Math.min(matrix.length, 15); i++) {
    const hs = (matrix[i] ?? []).map((h) => norm(text(h)));
    const ci = hs.findIndex((h) => h === 'cpf' || h.startsWith('cpf ') || h.endsWith(' cpf') || h.includes(' cpf '));
    const ri = hs.findIndex((h) => h.startsWith('matric') || ['mat', 'matr', 'registro', 're', 'chapa', 'codigo funcionario', 'cod funcionario'].includes(h));
    if (ci < 0 || ri < 0) continue;
    const map = new Map<string, string>();
    for (const line of matrix.slice(i + 1)) {
      const cpf = normalizeCpf(text((line ?? [])[ci]));
      const reg = text((line ?? [])[ri]).trim();
      if (cpf && reg) map.set(cpf, reg);
    }
    return { map, cpfHeader: text(matrix[i][ci]), regHeader: text(matrix[i][ri]) };
  }
  throw new Error('Não achei na planilha as colunas de CPF e de matrícula. Confira o cabeçalho (ex.: "CPF" e "Matrícula").');
}

export async function readCpfSheet(file: File) {
  return cpfMapFromMatrix(await readSheetMatrix(file));
}
