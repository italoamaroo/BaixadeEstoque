import { supabase } from './supabase';
import { kvClearPrefix, kvGet, kvSet } from './offlineDb';
import type { LookupTable } from './constants';
import type { Access, Employee, Lookup, Material } from '@/types/db';

/**
 * Cópia local dos cadastros para a Nova saída funcionar sem internet:
 * materiais (leitura de QR e pesquisa), funcionários, tabelas auxiliares e o acesso do usuário.
 * Atualizada automaticamente com internet (no máximo a cada 6 h) ou pelo botão "Atualizar dados offline".
 *
 * Minimização (LGPD): do funcionário, só id, nome e matrícula. A cópia vale 7 dias: depois disso
 * é apagada e não é usada. Também é apagada ao sair do sistema. A fila de saídas não enviadas
 * NÃO é apagada (é prova da retirada); ela some quando é enviada.
 */
const LOOKUP_TABLES: LookupTable[] = ['contracts', 'sectors', 'service_fronts', 'service_orders', 'fixed_assets', 'application_locations'];
const MAX_AGE_MS = 6 * 60 * 60 * 1000;
export const CACHE_VALID_MS = 7 * 24 * 60 * 60 * 1000;
const PAGE = 1000;

export interface OfflineCacheInfo {
  updated_at: string;
  materials: number;
  employees: number;
}

/** Apaga a cópia local dos cadastros e do acesso (não mexe na fila de saídas não enviadas). */
export const clearOfflineCache = () => kvClearPrefix('cache:');

const isOld = (iso: string | undefined) => !iso || Date.now() - new Date(iso).getTime() > CACHE_VALID_MS;

/** true = não há cópia, ou ela passou de 7 dias (nesse caso é apagada). */
async function expired(): Promise<boolean> {
  const info = await kvGet<OfflineCacheInfo>('cache:info');
  if (!info) return true;
  if (!isOld(info.updated_at)) return false;
  await kvClearPrefix('cache:info');
  await kvClearPrefix('cache:materials');
  await kvClearPrefix('cache:employees');
  await kvClearPrefix('cache:lookup:');
  return true;
}
async function validGet<T>(key: string): Promise<T | undefined> {
  return (await expired()) ? undefined : kvGet<T>(key);
}

export const cacheInfo = async () => ((await expired()) ? undefined : kvGet<OfflineCacheInfo>('cache:info'));
export const cachedMaterials = () => validGet<Material[]>('cache:materials');
export const cachedEmployees = () => validGet<Employee[]>('cache:employees');
export const cachedLookup = (t: LookupTable) => validGet<Lookup[]>(`cache:lookup:${t}`);
/** Acesso do usuário guardado com a data; vale 7 dias. */
export async function cachedAccess(userId: string): Promise<Access | undefined> {
  const v = await kvGet<{ access?: Access; saved_at?: string }>(`cache:access:${userId}`);
  if (!v?.access || isOld(v.saved_at)) {
    if (v) await kvClearPrefix(`cache:access:${userId}`);
    return undefined;
  }
  return v.access;
}
export const saveAccessCache = (userId: string, access: Access) =>
  kvSet(`cache:access:${userId}`, { access, saved_at: new Date().toISOString() }).catch(() => undefined);
export const saveLookupCache = (t: LookupTable, rows: Lookup[]) => kvSet(`cache:lookup:${t}`, rows).catch(() => undefined);

async function fetchAll<T>(table: string, select: string, filter?: (q: ReturnType<typeof supabase.from>) => unknown): Promise<T[]> {
  const out: T[] = [];
  for (let from = 0; ; from += PAGE) {
    let q = supabase.from(table).select(select).order('id').range(from, from + PAGE - 1);
    if (filter) q = filter(q as never) as typeof q;
    const { data, error } = await q;
    if (error) throw error;
    out.push(...((data ?? []) as T[]));
    if (!data || data.length < PAGE) break;
  }
  return out;
}

let running: Promise<OfflineCacheInfo | undefined> | null = null;

/** Baixa os cadastros para o aparelho. force = ignora a idade da cópia atual. */
export function refreshOfflineCache(force = false): Promise<OfflineCacheInfo | undefined> {
  if (running) return running;
  running = (async () => {
    if (typeof navigator !== 'undefined' && navigator.onLine === false) return cacheInfo();
    const info = await kvGet<OfflineCacheInfo>('cache:info');
    if (!force && info && Date.now() - new Date(info.updated_at).getTime() < MAX_AGE_MS) return info;

    const accounts = await fetchAll<{ id: string; code: string; name: string }>('accounts', 'id, code, name');
    const accMap = new Map(accounts.map((a) => [a.id, a]));
    const raw = await fetchAll<Material>(
      'materials',
      'id, code, reference, name, description, unit, location, account_id, category_id, warehouse_id, qr_code, active',
    );
    const materials = raw.map((m) => ({
      ...m,
      account_code: m.account_id ? accMap.get(m.account_id)?.code ?? null : null,
      account_name: m.account_id ? accMap.get(m.account_id)?.name ?? null : null,
    }));
    // Minimização: o aparelho guarda só id, nome e matrícula (sem cargo, setor ou datas)
    const employees = (
      await fetchAll<Pick<Employee, 'id' | 'registration' | 'full_name'>>('employees', 'id, registration, full_name', (q) =>
        (q as unknown as { eq: (c: string, v: unknown) => unknown }).eq('active', true),
      )
    ).map((e): Employee => ({ ...e, job_title: null, sector_id: null, active: true }));
    for (const t of LOOKUP_TABLES) {
      const rows = await fetchAll<Lookup>(t, '*', (q) => (q as unknown as { eq: (c: string, v: unknown) => unknown }).eq('active', true));
      await saveLookupCache(t, rows.sort((a, b) => a.name.localeCompare(b.name, 'pt-BR')));
    }
    await kvSet('cache:materials', materials);
    await kvSet('cache:employees', employees.sort((a, b) => a.full_name.localeCompare(b.full_name, 'pt-BR')));
    const newInfo = { updated_at: new Date().toISOString(), materials: materials.length, employees: employees.length };
    await kvSet('cache:info', newInfo);
    return newInfo;
  })().finally(() => {
    running = null;
  });
  return running;
}

const norm = (s: string) =>
  s
    .normalize('NFD')
    .replace(/[̀-ͯ]/g, '')
    .toLowerCase();

/** Mesmo comportamento da leitura online: QR, código do material ou URL com o código no final. */
export async function offlineFindMaterial(raw: string): Promise<{ found: boolean; reason?: 'invalido' | 'nao_cadastrado'; code?: string; material?: Material }> {
  let code = raw.trim();
  if (code.includes('/')) code = code.replace(/^.*\//, '');
  if (!/^[A-Za-z0-9._:/-]{1,80}$/.test(code)) return { found: false, reason: 'invalido' };
  const list = (await cachedMaterials()) ?? [];
  const up = code.toUpperCase();
  const m = list.find((x) => x.qr_code === code) ?? list.find((x) => x.code.toUpperCase() === up);
  return m ? { found: true, material: m } : { found: false, reason: 'nao_cadastrado', code };
}

export async function offlineSearchMaterials(term: string, onlyActive = true, limit = 30): Promise<Material[]> {
  const t = norm(term.trim());
  if (!t) return [];
  const list = (await cachedMaterials()) ?? [];
  return list
    .filter((m) => (!onlyActive || m.active) && norm(`${m.code} ${m.reference ?? ''} ${m.name} ${m.description ?? ''}`).includes(t))
    .slice(0, limit);
}

export async function offlineEmployees(search?: string, limit = 500): Promise<Employee[]> {
  const list = (await cachedEmployees()) ?? [];
  const t = norm(search?.trim() ?? '');
  return (t ? list.filter((e) => norm(`${e.full_name} ${e.registration}`).includes(t)) : list).slice(0, limit);
}
