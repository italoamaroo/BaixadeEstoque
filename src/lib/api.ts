import { supabase, SIGNATURE_BUCKET } from './supabase';
import { toAppError, AppError, isNetworkError } from './errors';
import { toRpcFilters, type MovementFilters } from './filters';
import { cachedLookup, offlineEmployees, offlineFindMaterial, offlineSearchMaterials, saveLookupCache } from './offlineCache';
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
  MovementStatus,
  SaRecord,
  Settings,
  SignatureRecord,
  StatusHistory,
  Warehouse,
} from '@/types/db';
import type { LookupTable } from './constants';

async function rpc<T>(fn: string, args?: Record<string, unknown>): Promise<T> {
  const { data, error } = await supabase.rpc(fn, args);
  if (error) {
    if ((error as { code?: string }).code === '42501') reportAccessDenied(fn);
    throw toAppError(error);
  }
  return data as T;
}

// ---------------------------------------------------------------------------
// Eventos de segurança relatados pela tela (o banco limita e marca a origem)
// ---------------------------------------------------------------------------
const deniedSent = new Map<string, number>();
/** Relata ao banco um acesso negado (no máximo 1 por operação a cada minuto). Nunca falha. */
export function reportAccessDenied(operation: string) {
  if (operation === 'log_access_denied') return;
  const now = Date.now();
  if (now - (deniedSent.get(operation) ?? 0) < 60_000) return;
  deniedSent.set(operation, now);
  void supabase.rpc('log_access_denied', { p_operation: operation, p_code: '42501' }).then(
    () => undefined,
    () => undefined,
  );
}
/** Login/saída registrados na auditoria. Nunca falha nem atrasa a tela. */
export async function logSession(action: 'login' | 'logout') {
  try {
    await Promise.race([supabase.rpc('auth_log_session', { p_action: action }), new Promise((r) => setTimeout(r, 3000))]);
  } catch {
    /* auditoria de sessão não bloqueia o uso */
  }
}
/** Falha de login (sem sessão). O banco grava só o e-mail mascarado e um hash. */
export function reportLoginFailure(email: string) {
  void supabase.rpc('report_login_failure', { p_email: email }).then(
    () => undefined,
    () => undefined,
  );
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
/** Sem internet, usa a cópia dos cadastros guardada no aparelho (modo offline). */
async function withOfflineFallback<T>(online: () => Promise<T>, offline: () => Promise<T>): Promise<T> {
  if (typeof navigator !== 'undefined' && navigator.onLine === false) return offline();
  try {
    return await online();
  } catch (err) {
    if (isNetworkError(err)) return offline();
    throw err;
  }
}

export const findMaterialByCode = (code: string) =>
  withOfflineFallback(
    () => rpc<FindMaterialResult>('find_material_by_code', { p_code: code }),
    () => offlineFindMaterial(code),
  );
export const searchMaterials = (term: string, onlyActive = true, limit = 30) =>
  withOfflineFallback(
    () => rpc<Material[]>('search_materials', { p_term: term, p_only_active: onlyActive, p_limit: limit }),
    () => offlineSearchMaterials(term, onlyActive, limit),
  );

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
  // somente pelo servidor: gestor/admin; gestor não recebe IP nem e-mail
  const { data, error } = await supabase.rpc('movement_audit', { p_movement_id: id });
  if (error) throw toAppError(error);
  return (data ?? []) as AuditLog[];
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
/** Almoxarife confirma que fez a baixa no ERP com a SA informada (ME vai para Concluída). */
export const completeMovement = (id: string, erpDocument?: string, notes?: string) =>
  rpc<{ id: string; status: string; sa_number: string }>('complete_movement', {
    p_id: id,
    p_erp_document: erpDocument?.trim() || null,
    p_notes: notes?.trim() || null,
  });
export async function getMovementItems(id: string): Promise<MovementItem[]> {
  const r = await supabase.from('stock_movement_items').select('*').eq('movement_id', id).order('line_number');
  return (unwrap(r) ?? []) as MovementItem[];
}
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
  const online = async () => {
    let q = supabase.from(table).select('*').order('name');
    if (!includeInactive) q = q.eq('active', true);
    const rows = (unwrap(await q) ?? []) as Lookup[];
    if (!includeInactive) void saveLookupCache(table, rows);
    return rows;
  };
  if (includeInactive) return online();
  return withOfflineFallback(online, async () => (await cachedLookup(table)) ?? []);
}

export async function saveLookup(table: LookupTable, row: Partial<Lookup> & { code: string; name: string; active: boolean }) {
  const body: Record<string, unknown> = { code: row.code.trim(), name: row.name.trim(), active: row.active };
  if (table === 'service_fronts') body.kind = row.kind ?? 'frente';
  const res = row.id ? await supabase.from(table).update(body).eq('id', row.id) : await supabase.from(table).insert(body);
  unwrap(res);
}

export async function listEmployees(opts: { search?: string; includeInactive?: boolean; limit?: number } = {}): Promise<Employee[]> {
  if (!opts.includeInactive) {
    return withOfflineFallback(
      () => listEmployeesOnline(opts),
      () => offlineEmployees(opts.search, opts.limit ?? 500),
    );
  }
  return listEmployeesOnline(opts);
}

async function listEmployeesOnline(opts: { search?: string; includeInactive?: boolean; limit?: number }): Promise<Employee[]> {
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

/** Busca materiais pelo código (em lotes, para planilhas grandes). */
export async function getMaterialsByCodes(codes: string[]): Promise<Material[]> {
  const unique = [...new Set(codes.map((c) => c.trim().toUpperCase()).filter(Boolean))];
  const out: Material[] = [];
  for (let i = 0; i < unique.length; i += 150) {
    const res = await supabase.from('materials').select('*').in('code', unique.slice(i, i + 150));
    out.push(...((unwrap(res) ?? []) as Material[]));
  }
  return out;
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

/** Importa ativos fixos, locais de aplicação e demais cadastros auxiliares (atualiza pelo código). */
export const importLookups = (table: LookupTable, rows: Record<string, unknown>[]) =>
  rpc<{ inseridos: number; atualizados: number; erros: { linha: number; codigo: string; erro: string }[] }>('import_lookups', {
    p_table: table,
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
  category?: string;
  result?: string;
  severity?: string;
  correlationId?: string;
}

function auditFilters(q: Omit<AuditQuery, 'page' | 'pageSize'>) {
  return {
    action: q.action || undefined,
    entity: q.entity || undefined,
    user_id: q.userId || undefined,
    date_from: q.dateFrom || undefined,
    date_to: q.dateTo || undefined,
    q: q.search?.trim() || undefined,
    category: q.category || undefined,
    result: q.result || undefined,
    severity: q.severity || undefined,
    correlation_id: q.correlationId?.trim() || undefined,
  };
}

/** Consulta da auditoria: só pelo servidor (limite de 100 por página e 366 dias; a consulta é registrada). */
export async function listAudit(q: AuditQuery): Promise<{ rows: AuditLog[]; total: number }> {
  const { data, error } = await supabase.rpc('search_audit', { p_filters: auditFilters(q), p_page: q.page, p_page_size: q.pageSize });
  if (error) throw toAppError(error);
  const r = (data ?? {}) as { rows?: AuditLog[]; total?: number };
  return { rows: r.rows ?? [], total: r.total ?? 0 };
}

/** Exportação da auditoria (somente administrador, com finalidade; máx. 10.000 eventos). */
export async function exportAudit(q: Omit<AuditQuery, 'page' | 'pageSize'>, reason: string): Promise<AuditLog[]> {
  const { data, error } = await supabase.rpc('export_audit', { p_filters: auditFilters(q), p_reason: reason });
  if (error) throw toAppError(error);
  return (data ?? []) as AuditLog[];
}

export interface AuditChainResult {
  ok: boolean;
  checked?: number;
  last_seq?: number;
  last_hash?: string;
  problem?: string | null;
  problem_seq?: number | null;
  generated_at?: string;
}

export async function verifyAuditChain(): Promise<AuditChainResult> {
  const { data, error } = await supabase.rpc('audit_verify_chain');
  if (error) throw toAppError(error);
  return data as AuditChainResult;
}

export async function createAuditAnchor(): Promise<AuditChainResult> {
  const { data, error } = await supabase.rpc('audit_create_anchor');
  if (error) throw toAppError(error);
  return data as AuditChainResult;
}

export async function checkAuditAnchor(seq: number, hash: string): Promise<AuditChainResult> {
  const { data, error } = await supabase.rpc('audit_check_anchor', { p_seq: seq, p_hash: hash });
  if (error) throw toAppError(error);
  return data as AuditChainResult;
}

// ---------------------------------------------------------------------------
// Balcão de separação (leitor QR sem fio + tablet do solicitante)
// ---------------------------------------------------------------------------
export type CounterScanResult =
  | 'incluido'
  | 'somado'
  | 'ja_incluido'
  | 'nao_encontrado'
  | 'invalido'
  | 'inativo'
  | 'quantidade_invalida';

export interface CounterScanResponse {
  result: CounterScanResult;
  code: string | null;
  item_id: string | null;
  material_id: string | null;
  material_code: string | null;
  material_name: string | null;
  unit: string | null;
  quantity_requested: number | null;
  quantity_delivered: number | null;
  repetida?: boolean;
}

export type CounterSessionStatus = 'em_separacao' | 'aguardando_confirmacao' | 'confirmada' | 'cancelada';

export interface CounterSnapshot {
  session: {
    id: string;
    status: CounterSessionStatus;
    version: number;
    last_event: string | null;
    last_event_at: string;
    terminal_paired: boolean;
    paired_at: string | null;
    pairing_code: string | null;
    pairing_expires_at: string;
    terminal_name: string | null;
  };
  movement: {
    id: string;
    me_number: string;
    status: MovementStatus;
    warehouse_name: string;
    warehouse_code: string;
    requester_name: string;
    requester_registration: string;
    storekeeper_name: string;
    movement_at: string;
    separation_finished_at: string | null;
    confirmed_at: string | null;
    cancel_reason: string | null;
    item_count: number;
    total_delivered: number;
    fixed_asset: string | null;
    is_emergency?: boolean;
  };
  items: {
    id: string;
    line_number: number;
    material_code: string;
    material_name: string;
    unit: string;
    quantity_requested: number;
    quantity_delivered: number;
    created_at: string;
    updated_at: string;
  }[];
}

export interface CounterOpenPayload {
  id: string;
  warehouse_id: string;
  contract_id: string;
  sector_id: string;
  service_front_id?: string | null;
  service_order_text?: string | null;
  fixed_asset_text?: string | null;
  application_location_id?: string | null;
  application_location_text?: string | null;
  notes?: string | null;
  emergency?: boolean;
  emergency_reason?: string | null;
  requester_employee_id: string;
  terminal_user_id?: string | null;
  reuse_terminal?: boolean;
}

export const counterOpen = (payload: CounterOpenPayload) =>
  rpc<{ id: string; me_number: string; session_id: string; pairing_code: string; terminal_paired: boolean; created: boolean }>(
    'counter_open',
    { p_payload: payload },
  );

export const counterAdd = (payload: {
  movement_id: string;
  scan_id: string;
  code?: string;
  material_id?: string;
  quantity?: number;
  on_duplicate?: 'avisar' | 'somar' | 'nova_linha';
}) => rpc<CounterScanResponse>('counter_add', { p_payload: payload });

export const counterSetQuantity = (itemId: string, requested: number, delivered: number) =>
  rpc<unknown>('counter_set_quantity', { p_item_id: itemId, p_requested: requested, p_delivered: delivered });
export const counterRemoveItem = (itemId: string) => rpc<unknown>('counter_remove_item', { p_item_id: itemId });
export const counterFinish = (movementId: string) => rpc<unknown>('counter_finish', { p_movement_id: movementId });
export const counterReopen = (movementId: string, reason?: string) =>
  rpc<unknown>('counter_reopen', { p_movement_id: movementId, p_reason: reason ?? null });
export const counterNewPairingCode = (movementId: string) =>
  rpc<{ pairing_code: string }>('counter_new_pairing_code', { p_movement_id: movementId });
export const counterPair = (code: string) => rpc<{ session_id: string; movement_id: string }>('counter_pair', { p_code: code });
export const counterSnapshot = (movementId?: string | null) =>
  rpc<CounterSnapshot | null>('counter_snapshot', { p_movement_id: movementId ?? null });
export const counterRegisterAttempt = (movementId: string, method: 'assinatura' | 'facial', result: 'falha' | 'cancelada' | 'erro', detail?: Record<string, unknown>) =>
  rpc<string>('counter_register_attempt', { p_movement_id: movementId, p_method: method, p_result: result, p_detail: detail ?? null });
export const counterConfirm = (
  movementId: string,
  payload:
    | { method: 'assinatura'; signature_path: string; photo_path?: string | null; photo_skipped_reason?: string | null }
    | { method: 'facial'; verification_id: string },
) => rpc<{ id: string; me_number: string; status: MovementStatus }>('counter_confirm', { p_movement_id: movementId, p_payload: payload });
export const counterMyOpen = () =>
  rpc<
    {
      movement_id: string;
      me_number: string;
      status: MovementStatus;
      requester_name: string;
      item_count: number;
      created_at: string;
      terminal_paired: boolean;
      warehouse_name: string;
    }[]
  >('counter_my_open');

export interface CounterTerminal {
  user_id: string;
  name: string;
  busy_me_number: string | null;
  last_used_by_me: string | null;
}
export const counterListTerminals = (warehouseId: string) =>
  rpc<CounterTerminal[]>('counter_list_terminals', { p_warehouse_id: warehouseId });
export const counterSetTerminal = (movementId: string, terminalUserId: string | null) =>
  rpc<unknown>('counter_set_terminal', { p_movement_id: movementId, p_terminal_user_id: terminalUserId });

/** Tablet sugerido: o último usado por mim (se livre); senão o primeiro livre. */
export function suggestTerminal(list: CounterTerminal[]): string {
  const free = list.filter((t) => !t.busy_me_number);
  const mine = [...free].filter((t) => t.last_used_by_me).sort((a, b) => (b.last_used_by_me ?? '').localeCompare(a.last_used_by_me ?? ''));
  return mine[0]?.user_id ?? free[0]?.user_id ?? '';
}

// ---------------------------------------------------------------------------
// Alerta: mesmo ativo fixo retirando o mesmo material em poucos dias
// ---------------------------------------------------------------------------
export interface RepeatAssetWithdrawal {
  asset: string;
  asset_name: string | null;
  material_id: string;
  material_code: string;
  material_name: string;
  unit: string;
  times: number;
  total_qty: number;
  min_gap_days: number;
  last_at: string;
  occurrences: {
    movement_id: string;
    me_number: string;
    movement_at: string;
    warehouse: string;
    requester: string;
    quantity: number;
    status: MovementStatus;
  }[];
}
export const getRepeatAssetWithdrawals = (filters: Partial<MovementFilters>, days = 7) =>
  rpc<{ days: number; total: number; items: RepeatAssetWithdrawal[] }>('repeat_asset_withdrawals', {
    p_filters: toRpcFilters(filters),
    p_days: days,
  });

// ---------------------------------------------------------------------------
// Foto do solicitante (confirmação no balcão) — visível só para gestor/admin
// ---------------------------------------------------------------------------
export const PHOTO_BUCKET = 'fotos-retirada';
export async function uploadPhoto(path: string, blob: Blob): Promise<void> {
  const { error } = await supabase.storage.from(PHOTO_BUCKET).upload(path, blob, { contentType: blob.type || 'image/jpeg', upsert: false });
  if (error && !/exists|duplicate/i.test(error.message)) throw toAppError(error);
}
export interface MovementPhoto {
  id: string;
  movement_id: string;
  storage_path: string;
  kind: string;
  taken_at: string;
}
export async function getMovementPhotos(movementId: string): Promise<MovementPhoto[]> {
  const r = await supabase.from('movement_photos').select('id, movement_id, storage_path, kind, taken_at').eq('movement_id', movementId).order('taken_at');
  return (unwrap(r) ?? []) as MovementPhoto[];
}
export async function getPhotoUrl(path: string, expiresIn = 300): Promise<string> {
  const { data, error } = await supabase.storage.from(PHOTO_BUCKET).createSignedUrl(path, expiresIn);
  if (error || !data) throw toAppError(error ?? new Error('Foto indisponível.'));
  return data.signedUrl;
}

// ---------------------------------------------------------------------------
// Segurança: alertas, retenção, retenção legal e descarte (fase 2)
// ---------------------------------------------------------------------------
export interface SecurityAlert {
  id: number;
  created_at: string;
  last_seen_at: string;
  rule: string;
  severity: 'info' | 'aviso' | 'critico';
  title: string;
  details?: Record<string, unknown> | null;
  occurrences: number;
  status: 'aberto' | 'em_analise' | 'encerrado';
  handled_at: string | null;
  handled_by_name: string | null;
  resolution: string | null;
}
export interface RetentionPolicy {
  category: string;
  retain_days: number | null;
  basis: string | null;
  status: 'proposta' | 'aprovada';
  updated_at: string;
  updated_by_name: string | null;
  approved_at: string | null;
  approved_by_name: string | null;
  events: number;
}
export interface LegalHold {
  id: number;
  reason: string;
  date_from: string;
  date_to: string;
  category: string | null;
  created_at: string;
  created_by_name: string | null;
  released_at: string | null;
  release_reason: string | null;
}
export interface PurgeRequest {
  id: number;
  category: string;
  before_date: string;
  events: number;
  reason: string;
  status: 'pendente' | 'executado' | 'rejeitado';
  requested_by: string;
  requested_by_name: string | null;
  requested_at: string;
  decided_by_name: string | null;
  decided_at: string | null;
  decision_note: string | null;
  purged: number | null;
}
export interface SecurityOverview {
  is_admin: boolean;
  alerts: SecurityAlert[];
  last_checks: { at: string; integridade: boolean; importados_auth: number; alertas: number } | null;
  open_count: number;
  open_critical: number;
  policies?: RetentionPolicy[];
  holds?: LegalHold[];
  purges?: PurgeRequest[];
  admins?: number;
  cron?: boolean;
}

export const getSecurityOverview = () => rpc<SecurityOverview>('security_overview');
export const runSecurityChecks = () => rpc<{ alertas: number; importados_auth: number; integridade: { ok: boolean } }>('security_run_checks');
export const updateSecurityAlert = (id: number, status: SecurityAlert['status'], resolution: string | null) =>
  rpc<void>('security_alert_update', { p_id: id, p_status: status, p_resolution: resolution });
export const setRetentionPolicy = (category: string, days: number, basis: string) =>
  rpc<void>('retention_set_policy', { p_category: category, p_days: days, p_basis: basis });
export const approveRetentionPolicy = (category: string) => rpc<void>('retention_approve_policy', { p_category: category });
export const createLegalHold = (reason: string, from: string, to: string, category: string | null) =>
  rpc<number>('legal_hold_create', { p_reason: reason, p_from: from, p_to: to, p_category: category });
export const releaseLegalHold = (id: number, reason: string) => rpc<void>('legal_hold_release', { p_id: id, p_reason: reason });
export const requestPurge = (category: string, before: string, reason: string) =>
  rpc<number>('purge_request', { p_category: category, p_before: before, p_reason: reason });
export const decidePurge = (id: number, approve: boolean, note: string) =>
  rpc<{ status: string; eventos?: number }>('purge_decide', { p_id: id, p_approve: approve, p_note: note });
