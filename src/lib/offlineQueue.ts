import { createMovement, uploadSignature } from './api';
import { errorMessage, isNetworkError } from './errors';
import { queueAll, queueDel, queuePut } from './offlineDb';
import { buildSignaturePath, dataUrlToBlob } from './signature';

/**
 * Saídas registradas sem internet. Ficam no aparelho (IndexedDB) com a assinatura
 * e são enviadas sozinhas quando a conexão volta. O envio usa o mesmo id da ME:
 * se a mesma saída for enviada duas vezes, o banco devolve a ME já criada (sem duplicar).
 */
export interface QueuedMovement {
  id: string;
  user_id: string;
  saved_at: string;
  /** data/hora real da retirada (vai para a ME) */
  offline_at: string;
  warehouse_code: string;
  warehouse_name: string;
  requester_name: string;
  item_count: number;
  items_summary: string;
  payload: Record<string, unknown>;
  signature_data_url: string;
  signature_signed_at: string | null;
  signature_path: string | null;
  status: 'pendente' | 'erro';
  attempts: number;
  last_error: string | null;
  last_attempt_at: string | null;
}

export const QUEUE_EVENT = 'baixas-offline-queue';
const notify = () => window.dispatchEvent(new CustomEvent(QUEUE_EVENT));

export async function enqueueMovement(q: Omit<QueuedMovement, 'status' | 'attempts' | 'last_error' | 'last_attempt_at' | 'signature_path'>) {
  await queuePut({ ...q, status: 'pendente', attempts: 0, last_error: null, last_attempt_at: null, signature_path: null });
  notify();
}

export async function listQueued(userId: string | null): Promise<QueuedMovement[]> {
  const all = await queueAll<QueuedMovement>();
  return all.filter((q) => !userId || q.user_id === userId).sort((a, b) => a.saved_at.localeCompare(b.saved_at));
}

export async function discardQueued(id: string) {
  await queueDel(id);
  notify();
}

export interface SyncResult {
  sent: { id: string; me_number: string; offline_at: string }[];
  failed: { id: string; error: string }[];
  stoppedByNetwork: boolean;
}

let syncing: Promise<SyncResult> | null = null;

/** Envia as saídas guardadas. includeErrors = também reenvia as que deram erro (botão "Enviar agora"). */
export function syncQueue(userId: string, timeZone = 'America/Recife', includeErrors = false): Promise<SyncResult> {
  if (syncing) return syncing;
  syncing = (async () => {
    const result: SyncResult = { sent: [], failed: [], stoppedByNetwork: false };
    if (navigator.onLine === false) return { ...result, stoppedByNetwork: true };
    for (const q of await listQueued(userId)) {
      if (q.status === 'erro' && !includeErrors) continue;
      const item: QueuedMovement = { ...q, attempts: q.attempts + 1, last_attempt_at: new Date().toISOString() };
      try {
        const when = new Date(item.offline_at);
        let path = item.signature_path;
        if (!path) {
          path = buildSignaturePath(item.warehouse_code, item.id, timeZone, when);
          await uploadSignature(path, dataUrlToBlob(item.signature_data_url));
          item.signature_path = path;
          await queuePut(item);
        }
        const send = (p: string) =>
          createMovement({
            ...item.payload,
            offline_at: item.offline_at,
            signature: { storage_path: p, signed_at: item.signature_signed_at ?? item.offline_at },
          });
        let res;
        try {
          res = await send(path);
        } catch (err) {
          if (/Caminho da assinatura inválido|não encontrado no armazenamento/i.test(errorMessage(err))) {
            path = buildSignaturePath(item.warehouse_code, item.id, timeZone, new Date(when.getTime() + 1000));
            await uploadSignature(path, dataUrlToBlob(item.signature_data_url));
            item.signature_path = path;
            await queuePut(item);
            res = await send(path);
          } else {
            throw err;
          }
        }
        await queueDel(item.id);
        result.sent.push({ id: item.id, me_number: res.me_number, offline_at: item.offline_at });
      } catch (err) {
        if (isNetworkError(err)) {
          await queuePut({ ...item, status: 'pendente', last_error: 'Sem conexão no momento do envio.' });
          result.stoppedByNetwork = true;
          break;
        }
        const msg = errorMessage(err);
        await queuePut({ ...item, status: 'erro', last_error: msg });
        result.failed.push({ id: item.id, error: msg });
      }
    }
    notify();
    return result;
  })().finally(() => {
    syncing = null;
  });
  return syncing;
}
