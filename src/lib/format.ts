import { format, formatDistanceToNowStrict, parseISO } from 'date-fns';
import { ptBR } from 'date-fns/locale';

function toDate(value: string | Date | null | undefined): Date | null {
  if (!value) return null;
  const d = typeof value === 'string' ? parseISO(value) : value;
  return Number.isNaN(d.getTime()) ? null : d;
}

export function fmtDate(value: string | Date | null | undefined): string {
  const d = toDate(value);
  return d ? format(d, 'dd/MM/yyyy', { locale: ptBR }) : '—';
}

export function fmtTime(value: string | Date | null | undefined): string {
  const d = toDate(value);
  return d ? format(d, 'HH:mm', { locale: ptBR }) : '—';
}

export function fmtDateTime(value: string | Date | null | undefined): string {
  const d = toDate(value);
  return d ? format(d, "dd/MM/yyyy 'às' HH:mm", { locale: ptBR }) : '—';
}

export function fmtRelative(value: string | Date | null | undefined): string {
  const d = toDate(value);
  return d ? formatDistanceToNowStrict(d, { locale: ptBR, addSuffix: true }) : '—';
}

/** Dias inteiros desde a data (para o tempo de pendência). */
export function daysSince(value: string | Date | null | undefined): number {
  const d = toDate(value);
  if (!d) return 0;
  return Math.max(0, Math.floor((Date.now() - d.getTime()) / 86_400_000));
}

const qtyFmt = new Intl.NumberFormat('pt-BR', { maximumFractionDigits: 3 });
const intFmt = new Intl.NumberFormat('pt-BR');

export function fmtQty(value: number | string | null | undefined): string {
  if (value === null || value === undefined || value === '') return '—';
  const n = typeof value === 'string' ? Number(value) : value;
  return Number.isFinite(n) ? qtyFmt.format(n) : '—';
}

export function fmtInt(value: number | null | undefined): string {
  return intFmt.format(value ?? 0);
}

/** Converte "1,5" ou "1.5" em número. Retorna NaN se inválido. */
export function parseQty(input: string | number): number {
  if (typeof input === 'number') return input;
  const s = input.trim().replace(/\s/g, '');
  if (!s) return NaN;
  const normalized = s.includes(',') ? s.replace(/\./g, '').replace(',', '.') : s;
  if (!/^-?\d+(\.\d+)?$/.test(normalized)) return NaN;
  return Number(normalized);
}

export function todayISO(): string {
  return format(new Date(), 'yyyy-MM-dd');
}

export function isoDaysAgo(days: number): string {
  return format(new Date(Date.now() - days * 86_400_000), 'yyyy-MM-dd');
}

export function firstDayOfMonthISO(): string {
  const d = new Date();
  return format(new Date(d.getFullYear(), d.getMonth(), 1), 'yyyy-MM-dd');
}

export function slugify(text: string): string {
  return text
    .normalize('NFD')
    .replace(/[̀-ͯ]/g, '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '_')
    .replace(/^_+|_+$/g, '');
}
