import type { MovementStatus, Warehouse } from '@/types/db';
import { STATUS_LABELS } from './constants';
import { fmtDate, slugify } from './format';

/** Filtros da lista, do dashboard e da exportação (mesmo formato do RPC movement_matches). */
export interface MovementFilters {
  date_from: string;
  date_to: string;
  warehouse_id: string;
  me_number: string;
  sa_number: string;
  status: MovementStatus[];
  material: string;
  material_code: string;
  reference: string;
  unit: string;
  sector_id: string;
  service_front_id: string;
  service_order: string;
  fixed_asset: string;
  application_location_id: string;
  requester: string;
  storekeeper_id: string;
  responsible_user_id: string;
  pending_sa: boolean;
  q: string;
}

export const EMPTY_FILTERS: MovementFilters = {
  date_from: '',
  date_to: '',
  warehouse_id: '',
  me_number: '',
  sa_number: '',
  status: [],
  material: '',
  material_code: '',
  reference: '',
  unit: '',
  sector_id: '',
  service_front_id: '',
  service_order: '',
  fixed_asset: '',
  application_location_id: '',
  requester: '',
  storekeeper_id: '',
  responsible_user_id: '',
  pending_sa: false,
  q: '',
};

/** Remove chaves vazias antes de enviar ao banco. */
export function toRpcFilters(f: Partial<MovementFilters>): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(f)) {
    if (v === '' || v === null || v === undefined || v === false) continue;
    if (Array.isArray(v) && v.length === 0) continue;
    out[k] = typeof v === 'string' ? v.trim() : v;
  }
  return out;
}

export function countActiveFilters(f: Partial<MovementFilters>): number {
  return Object.keys(toRpcFilters({ ...f, q: '' })).length;
}

export function validateFilters(f: Partial<MovementFilters>): string | null {
  const re = /^\d{4}-\d{2}-\d{2}$/;
  if (f.date_from && !re.test(f.date_from)) return 'Data inicial inválida.';
  if (f.date_to && !re.test(f.date_to)) return 'Data final inválida.';
  if (f.date_from && f.date_to && f.date_from > f.date_to) return 'A data inicial não pode ser maior que a data final.';
  return null;
}

/** Descrição legível dos filtros (cabeçalho do Excel). */
export function describeFilters(f: Partial<MovementFilters>, warehouses: Warehouse[]): string[] {
  const lines: string[] = [];
  if (f.date_from || f.date_to) {
    lines.push(`Período: ${f.date_from ? fmtDate(f.date_from) : 'início'} a ${f.date_to ? fmtDate(f.date_to) : 'hoje'}`);
  }
  const wh = warehouses.find((w) => w.id === f.warehouse_id);
  lines.push(`Estoque: ${wh ? wh.name : 'Todos os autorizados'}`);
  if (f.status?.length) lines.push(`Status: ${f.status.map((s) => STATUS_LABELS[s]).join(', ')}`);
  if (f.pending_sa) lines.push('Somente pendências de SA');
  const extras: [keyof MovementFilters, string][] = [
    ['me_number', 'ME'], ['sa_number', 'SA'], ['material', 'Material'], ['material_code', 'Código'],
    ['reference', 'Referência'], ['unit', 'Unidade'], ['service_order', 'OS'], ['fixed_asset', 'Ativo fixo'],
    ['requester', 'Requisitante'], ['q', 'Pesquisa'],
  ];
  for (const [key, label] of extras) {
    const v = f[key];
    if (typeof v === 'string' && v.trim()) lines.push(`${label}: ${v.trim()}`);
  }
  return lines;
}

/** Ex.: baixas_muribeca_2026-10-01_a_2026-10-31.xlsx */
export function exportFileName(f: Partial<MovementFilters>, warehouses: Warehouse[], kind: 'resumo' | 'itens'): string {
  const wh = warehouses.find((w) => w.id === f.warehouse_id);
  const parts = ['baixas', wh ? slugify(wh.name) : 'todos_estoques'];
  if (f.date_from || f.date_to) {
    parts.push(`${f.date_from || 'inicio'}_a_${f.date_to || 'hoje'}`);
  }
  if (kind === 'itens') parts.push('itens');
  return `${parts.join('_')}.xlsx`;
}

/** Serialização na URL (permite compartilhar/recarregar a consulta). */
export function filtersToSearchParams(f: Partial<MovementFilters>): URLSearchParams {
  const p = new URLSearchParams();
  for (const [k, v] of Object.entries(toRpcFilters(f))) {
    p.set(k, Array.isArray(v) ? v.join(',') : String(v));
  }
  return p;
}

export function filtersFromSearchParams(p: URLSearchParams): MovementFilters {
  const f: MovementFilters = { ...EMPTY_FILTERS, status: [] };
  for (const key of Object.keys(EMPTY_FILTERS) as (keyof MovementFilters)[]) {
    const v = p.get(key);
    if (v === null) continue;
    if (key === 'status') f.status = v.split(',').filter(Boolean) as MovementStatus[];
    else if (key === 'pending_sa') f.pending_sa = v === 'true';
    else (f[key] as string) = v;
  }
  return f;
}
