import type { CartItem, Employee } from '@/types/db';
import type { MovementDetails } from './validation';

/**
 * Rascunho da saída em andamento. Fica no sessionStorage do navegador apenas para
 * não perder o preenchimento em falhas simples (queda de conexão, recarregar a página).
 * Não é fonte de dados: a ME só existe depois da confirmação do Supabase.
 */
export interface MovementDraft {
  version: 1;
  id: string; // UUID gerado no cliente = chave de idempotência da ME
  step: number;
  warehouse_id: string;
  cart: CartItem[];
  details: MovementDetails;
  requester: Employee | null;
  receiver: Employee | null; // null = o próprio requisitante recebeu
  signature_data_url: string | null;
  signature_signed_at: string | null;
  signature_path: string | null; // preenchido quando o upload já foi feito
  source: string;
  started_at: string;
}

const PREFIX = 'baixas-estoque:rascunho:';

export function newDraftId(): string {
  const c: Crypto = globalThis.crypto;
  if (typeof c.randomUUID === 'function') return c.randomUUID();
  // fallback RFC4122 v4 (navegadores antigos / contexto não seguro)
  const b = new Uint8Array(16);
  c.getRandomValues(b);
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  const h = [...b].map((x) => x.toString(16).padStart(2, '0')).join('');
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
}

export function emptyDraft(warehouseId = ''): MovementDraft {
  return {
    version: 1,
    id: newDraftId(),
    step: warehouseId ? 1 : 0,
    warehouse_id: warehouseId,
    cart: [],
    details: {
      warehouse_id: warehouseId,
      contract_id: '',
      sector_id: '',
      service_front_id: '',
      service_order_text: '',
      fixed_asset_text: '',
      application_location_id: '',
      application_location_text: '',
      notes: '',
    },
    requester: null,
    receiver: null,
    signature_data_url: null,
    signature_signed_at: null,
    signature_path: null,
    source: 'app',
    started_at: new Date().toISOString(),
  };
}

export function loadDraft(userId: string): MovementDraft | null {
  try {
    const raw = sessionStorage.getItem(PREFIX + userId);
    if (!raw) return null;
    const d = JSON.parse(raw) as MovementDraft;
    return d?.version === 1 && d.id ? d : null;
  } catch {
    return null;
  }
}

export function saveDraft(userId: string, draft: MovementDraft): void {
  try {
    sessionStorage.setItem(PREFIX + userId, JSON.stringify(draft));
  } catch {
    /* armazenamento indisponível ou cheio: segue apenas em memória */
  }
}

export function clearDraft(userId: string): void {
  try {
    sessionStorage.removeItem(PREFIX + userId);
  } catch {
    /* ignore */
  }
}

/** Rascunho usado pelo botão "Duplicar como nova movimentação". */
const DUP_KEY = 'baixas-estoque:duplicar';
export function stashDuplicate(draft: MovementDraft): void {
  try {
    sessionStorage.setItem(DUP_KEY, JSON.stringify(draft));
  } catch {
    /* ignore */
  }
}
export function takeDuplicate(): MovementDraft | null {
  try {
    const raw = sessionStorage.getItem(DUP_KEY);
    sessionStorage.removeItem(DUP_KEY);
    return raw ? (JSON.parse(raw) as MovementDraft) : null;
  } catch {
    return null;
  }
}
