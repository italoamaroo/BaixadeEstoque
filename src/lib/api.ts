import { supabase, SIGNATURE_BUCKET } from './supabase';
import { toAppError, AppError, isNetworkError } from './errors';
import { toRpcFilters, type MovementFilters } from './filters';
import type {
  Access,
  AdminUser,
  AppRole,
  AuditLog,
  DashboardData,
  Employee,
  Lookup,
  Material,
  MovementItem,
  MovementRow,
  SaRecord,
  Settings,
  SignatureRecord,
  StatusHistory,
  Warehouse,
} from '@/types/db';
import type { LookupTable } from './constants';

async function rpc<T>(fn: string, args?: Record<string, unknown>): Promise<T> {
  const { data, error } = await supabase.rpc(fn, args);
  if (error) throw toAppError(error);
  return data as T;
}

function unwrap<T>(res: { data: T | null; error: unknown }): T {
  if (res.error) throw toAppError(res.error);
  return res.data as T;
}

/** Repete operações idempotentes em falha de rede (backoff curto). */
export async function withRetry<T>(fn: () => Promise<T>, attempts = 3): Promise<T> {
  let last: unknown;
  for (let i = 0; i < attempts; i++) {
    try {
      return await fn();
    } catch (err) {
      last = err;
      if (!isNetworkError(err) || i === attempts - 1) throw err;
      await new Promise((r) => setTimeout(r, 800 * (i + 1)));
    }
  }
  throw last;
}

// ---------------------------------------------------------------------------
// Sessão / acesso
// ---------------------------------------------------------------------------
export const getAccess = () => rpc<Access>('my_access');
export const updateMyProfile = (full_name: string, default_warehouse_id: string | null) =>
  rpc<void>('update_my_profile', { p_full_name: full_name, p_default_warehouse_id: default_warehouse_id });

// ---------------------------------------------------------------------------
// Movimentações
// ---------------------------------------------------------------------------
export interface SearchResult {
  total: number;
  page: number;
  page_size: number;
  rows: MovementRow[];
}

export const searchMovements = (filters: Partial<MovementFilters>, page: number, pageSize: number, sort: string, dir: 'asc' | 'desc') =>
  rpc<SearchResult>('search_movements', {
    p_filters: toRpcFilters(filters),
    p_page: page,
    p_page_size: pageSize,
    p_sort: sort,
    p_dir: dir,
  });

export const getDashboard = (filters: Partial<MovementFilters>) =>
  rpc<DashboardData>('dashboard_stats', { p_filters: toRpcFilters(filters) });

export const exportMovements = (filters: Partial<MovementFilters>, kind: 'resumo' | 'itens') =>
  rpc<Record<string, unknown>[]>('export_movements', { p_filters: toRpcFilters(filters), p_kind: kind });

export const logEvent = (action: string, movementId?: string | null, details?: Record<string, unknown>) =>
  rpc<void>('log_event', { p_action: action, p_movement_id: movementId ?? null, p_details: details ?? null }).catch(() => {
    /* registro de interface não deve bloquear o usuário */
  });

export interface FindMaterialResult {
  found: boolean;
  reason?: 'invalido' | 'nao_cadastrado';
  code?: string;
  material?: Material;
}
export const findMaterialByCode = (code: string) => rpc<FindMaterialResult>('find_material_by_code', { p_code: code });
export const searchMaterials = (term: string, onlyActive = true, limit = 30) =>
  rpc<Material[]>('search_materials', { p_term: term, p_only_active: onlyActive, p_limit: limit });

export interface MovementDetail {
  movement: MovementRow;
  items: MovementItem[];
  signatures: SignatureRecord[];
  saRecords: SaRecord[];
  history: StatusHistory[];
}

export async function getMovementDetail(id: string): Promise<MovementDetail | null> {
  const [m, items, sigs, sa, hist] = await Promise.all([
    supabase.from('v_movements').select('*').eq('id', id).maybeSingle(),
    supabase.from('stock_movement_items').select('*').eq('movement_id', id).order('line_number'),
    supabase.from('signatures').select('*').eq('movement_id', id).order('uploaded_at'),
    supabase.from('erp_sa_records').select('*').eq('movement_id', id).order('informed_at'),
    supabase.from('movement_status_history').select('*').eq('movement_id', id).order('changed_at'),
  ]);
  const movement = unwrap(m) as MovementRow | null;
  if (!movement) return null;
  return {
    movement,
    items: (unwrap(items) ?? []) as MovementItem[],
    signatures: (unwrap(sigs) ?? []) as SignatureRecord[],
    saRecords: (unwrap(sa) ?? []) as SaRecord[],
    history: (unwrap(hist) ?? []) as StatusHistory[],
  };
}

export async function getMovementAudit(id: string): Promise<AuditLog[]> {
  const res = await supabase.from('audit_logs').select('*').eq('movement_id', id).order('occurred_at');
  return (unwrap(res) ?? []) as AuditLog[];
}

/** URL assinada de curta duração (bucket privado). */
export async function getSignatureUrl(path: string, expiresIn = 300): Promise<string> {
  const { data, error } = await supabase.storage.from(SIGNATURE_BUCKET).createSignedUrl(path, expiresIn);
  if (error) throw toAppError(error);
  return data.signedUrl;
}

/**
 * Envia a assinatura ao Storage. Se o arquivo já existir (reenvio após falha
 * de rede em que o upload chegou a ser gravado), considera sucesso.
 */
export async function uploadSignature(path: string, blob: Blob): Promise<void> {
  const { error } = await supabase.storage.from(SIGNATURE_BUCKET).upload(path, blob, {
    contentType: 'image/png',
    upsert: false,
    cacheControl: '31536000',
  });
  if (error) {
    const msg = String((error as { message?: string }).message ?? '');
    const status = String((error as { statusCode?: string | number }).statusCode ?? '');
    if (/already exists|duplicate/i.test(msg) || status === '409') return;
    throw toAppError(error);
  }
}

export interface CreateMovementResult {
  id: string;
  me_number: string;
  status: string;
  created: boolean;
}

export const createMovement = (payload: Record<string, unknown>) =>
  rpc<CreateMovementResult>('create_movement', { p_payload: payload });

export const approveMovement = (id: string, notes?: string) => rpc<unknown>('approve_movement', { p_id: id, p_notes: notes ?? null });
export const informSa = (id: string, sa: string, justification?: string) =>
  rpc<{ status: string; action: string; sa_number: string }>('inform_sa', {
    p_id: id,
    p_sa_number: sa,
    p_justification: justification ?? null,
  });
export const completeMovement = (id: string) => rpc<unknown>('complete_movement', { p_id: id });
export const cancelMovement = (id: string, reason: string) => rpc<unknown>('cancel_movement', { p_id: id, p_reason: reason });
export const correctMovement = (id: string, changes: Record<string, unknown>, justification: string) =>
  rpc<unknown>('correct_movement', { p_id: id, p_changes: changes, p_justification: justification });
export const replaceSignature = (id: string, path: string, employeeId: string, reason: string) =>
  rpc<unknown>('replace_signature', { p_id: id, p_storage_path: path, p_employee_id: employeeId, p_reason: reason });

// ---------------------------------------------------------------------------
// Cadastros
// ---------------------------------------------------------------------------
export async function listWarehouses(includeInactive = false): Promise<Warehouse[]> {
  let q = supabase.from('warehouses').select('*').order('name');
  if (!includeInactive) q = q.eq('active', true);
  return (unwrap(await q) ?? []) as Warehouse[];
}

export async function saveWarehouse(w: Partial<Warehouse> & { code: string; name: string; active: boolean }): Promise<void> {
  const body = { code: w.code.trim().toUpperCase(), name: w.name.trim(), active: w.active };
  const res = w.id
    ? await supabase.from('warehouses').update(body).eq('id', w.id)
    : await supabase.from('warehouses').insert(body);
  unwrap(res);
}

export async function listLookup(table: LookupTable, includeInactive = false): Promise<Lookup[]> {
  let q = supabase.from(table).select('*').order('name');
  if (!includeInactive) q = q.eq('active', true);
  return (unwrap(await q) ?? []) as Lookup[];
}

export async function saveLookup(table: LookupTable, row: Partial<Lookup> & { code: string; name: string; active: boolean }) {
  const body: Record<string, unknown> = { code: row.code.trim(), name: row.name.trim(), active: row.active };
  if (table === 'service_fronts') body.kind = row.kind ?? 'frente';
  const res = row.id ? await supabase.from(table).update(body).eq('id', row.id) : await supabase.from(table).insert(body);
  unwrap(res);
}

export async function listEmployees(opts: { search?: string; includeInactive?: boolean; limit?: number } = {}): Promise<Employee[]> {
  let q = supabase.from('employees').select('*').order('full_name').limit(opts.limit ?? 500);
  if (!opts.includeInactive) q = q.eq('active', true);
  const s = opts.search?.trim();
  if (s) {
    const safe = s.replace(/[%,()]/g, ' ');
    q = q.or(`full_name.ilike.%${safe}%,registration.ilike.%${safe}%`);
  }
  return (unwrap(await q) ?? []) as Employee[];
}

export async function saveEmployee(e: Partial<Employee> & { registration: string; full_name: string; active: boolean }) {
  const body = {
    registration: e.registration.trim(),
    full_name: e.full_name.trim(),
    job_title: e.job_title?.trim() || null,
    sector_id: e.sector_id || null,
    active: e.active,
  };
  const res = e.id ? await supabase.from('employees').update(body).eq('id', e.id) : await supabase.from('employees').insert(body);
  unwrap(res);
}

export interface MaterialListParams {
  search?: string;
  status?: 'todos' | 'ativos' | 'inativos';
  page: number;
  pageSize: number;
}

export async function listMaterials(p: MaterialListParams): Promise<{ rows: Material[]; total: number }> {
  let q = supabase
    .from('materials')
    .select('*, accounts(code, name), material_categories(name), warehouses(name)', { count: 'exact' })
    .order('name')
    .range((p.page - 1) * p.pageSize, p.page * p.pageSize - 1);
  if (p.status === 'ativos') q = q.eq('active', true);
  if (p.status === 'inativos') q = q.eq('active', false);
  const s = p.search?.trim();
  if (s) {
    const safe = s.replace(/[%,()]/g, ' ');
    q = q.or(`code.ilike.%${safe}%,reference.ilike.%${safe}%,name.ilike.%${safe}%,description.ilike.%${safe}%,qr_code.ilike.%${safe}%`);
  }
  const { data, error, count } = await q;
  if (error) throw toAppError(error);
  const rows = (data ?? []).map((r: Record<string, unknown>) => {
    const acc = r.accounts as { code: string; name: string } | null;
    const cat = r.material_categories as { name: string } | null;
    const wh = r.warehouses as { name: string } | null;
    return {
      ...(r as unknown as Material),
      account_code: acc?.code ?? null,
      account_name: acc?.name ?? null,
      category_name: cat?.name ?? null,
      warehouse_name: wh?.name ?? null,
    };
  });
  return { rows, total: count ?? 0 };
}

export async function getMaterialsByIds(ids: string[]): Promise<Material[]> {
  if (!ids.length) return [];
  const res = await supabase.from('materials').select('*').in('id', ids).order('name');
  return (unwrap(res) ?? []) as Material[];
}

export async function saveMaterial(m: Partial<Material> & { code: string; name: string; unit: string; active: boolean }) {
  const body: Record<string, unknown> = {
    code: m.code.trim().toUpperCase(),
    reference: m.reference?.trim() || null,
    name: m.name.trim(),
    description: m.description?.trim() || null,
    unit: m.unit.trim().toUpperCase(),
    location: m.location?.trim() || null,
    account_id: m.account_id || null,
    category_id: m.category_id || null,
    warehouse_id: m.warehouse_id || null,
    active: m.active,
  };
  if (m.qr_code?.trim()) body.qr_code = m.qr_code.trim();
  const res = m.id
    ? await supabase.from('materials').update(body).eq('id', m.id).select().single()
    : await supabase.from('materials').insert(body).select().single();
  return unwrap(res) as Material;
}

export const regenerateQr = (materialId: string) => rpc<string>('regenerate_material_qr', { p_material_id: materialId });
export const markLabelsPrinted = (ids: string[]) => rpc<void>('mark_labels_printed', { p_material_ids: ids }).catch(() => undefined);
export const importMaterials = (rows: Record<string, unknown>[]) =>
  rpc<{ inseridos: number; atualizados: number; erros: { linha: number; codigo: string; erro: string }[] }>('import_materials', {
    p_rows: rows,
  });

export const importEmployees = (rows: Record<string, unknown>[]) =>
  rpc<{ inseridos: number; atualizados: number; erros: { linha: number; codigo: string; erro: string }[] }>('import_employees', {
    p_rows: rows,
  });

// ---------------------------------------------------------------------------
// Usuários, perfis e parâmetros
// ---------------------------------------------------------------------------
export const adminListUsers = () => rpc<AdminUser[]>('admin_list_users');
export const adminSetUserAccess = (
  userId: string,
  fullName: string,
  roles: AppRole[],
  warehouseIds: string[],
  active: boolean,
  defaultWarehouseId: string | null,
) =>
  rpc<unknown>('admin_set_user_access', {
    p_user_id: userId,
    p_full_name: fullName,
    p_roles: roles,
    p_warehouse_ids: warehouseIds,
    p_active: active,
    p_default_warehouse_id: defaultWarehouseId,
  });

/**
 * Criação de usuário no Supabase Auth: feita pela Edge Function "admin-users",
 * que roda no Supabase com a service_role. O navegador nunca recebe essa chave.
 */
export async function adminCreateUser(input: { email: string; full_name: string; password?: string; invite: boolean }) {
  const { data, error } = await supabase.functions.invoke('admin-users', { body: { action: 'create', ...input } });
  if (error) {
    let msg = error.message;
    try {
      const ctx = (error as { context?: Response }).context;
      if (ctx && typeof ctx.json === 'function') {
        const body = await ctx.json();
        if (body?.error) msg = body.error;
      }
    } catch {
      /* mantém mensagem original */
    }
    if (/Failed to send a request|not found|404/i.test(msg)) {
      throw new AppError(
        'A função "admin-users" não está publicada no Supabase. Crie o usuário em Authentication > Users e depois configure o acesso aqui (ver README).',
      );
    }
    throw toAppError({ message: msg });
  }
  if ((data as { error?: string })?.error) throw new AppError((data as { error: string }).error);
  return data as { id: string; email: string };
}

export async function sendPasswordReset(email: string) {
  const { error } = await supabase.auth.resetPasswordForEmail(email, { redirectTo: `${window.location.origin}/redefinir-senha` });
  if (error) throw toAppError(error);
}

export async function getSettings(): Promise<Settings> {
  const res = await supabase.from('app_settings').select('*').eq('id', 1).single();
  return unwrap(res) as Settings;
}
export const updateSettings = (s: Partial<Settings>) => rpc<Settings>('update_settings', { p: s });

export interface ProfileName {
  id: string;
  full_name: string;
  email: string;
  active: boolean;
}
export async function listProfiles(): Promise<ProfileName[]> {
  const res = await supabase.from('profiles').select('id, full_name, email, active').order('full_name');
  return (unwrap(res) ?? []) as ProfileName[];
}

// ---------------------------------------------------------------------------
// Auditoria
// ---------------------------------------------------------------------------
export interface AuditQuery {
  page: number;
  pageSize: number;
  action?: string;
  entity?: string;
  userId?: string;
  dateFrom?: string;
  dateTo?: string;
  search?: string;
}
export async function listAudit(q: AuditQuery): Promise<{ rows: AuditLog[]; total: number }> {
  let query = supabase
    .from('audit_logs')
    .select('*', { count: 'exact' })
    .order('occurred_at', { ascending: false })
    .range((q.page - 1) * q.pageSize, q.page * q.pageSize - 1);
  if (q.action) query = query.ilike('action', `${q.action}%`);
  if (q.entity) query = query.eq('entity', q.entity);
  if (q.userId) query = query.eq('user_id', q.userId);
  if (q.dateFrom) query = query.gte('occurred_at', `${q.dateFrom}T00:00:00-03:00`);
  if (q.dateTo) query = query.lte('occurred_at', `${q.dateTo}T23:59:59.999-03:00`);
  if (q.search?.trim()) {
    const safe = q.search.trim().replace(/[%,()]/g, ' ');
    query = query.or(`entity_id.ilike.%${safe}%,user_email.ilike.%${safe}%,justification.ilike.%${safe}%`);
  }
  const { data, error, count } = await query;
  if (error) throw toAppError(error);
  return { rows: (data ?? []) as AuditLog[], total: count ?? 0 };
}
