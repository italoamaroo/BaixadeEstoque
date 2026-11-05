/**
 * Armazenamento local do aparelho (IndexedDB) para o modo offline.
 * - "kv": cópia dos cadastros (materiais, funcionários, tabelas auxiliares, acesso do usuário)
 * - "queue": saídas registradas sem internet, aguardando envio
 * O Supabase continua sendo a fonte oficial: nada aqui substitui o banco.
 */
const DB_NAME = 'baixas-estoque-offline';
const DB_VERSION = 1;

let dbPromise: Promise<IDBDatabase> | null = null;

function open(): Promise<IDBDatabase> {
  if (dbPromise) return dbPromise;
  dbPromise = new Promise((resolve, reject) => {
    if (typeof indexedDB === 'undefined') {
      reject(new Error('Este navegador não permite guardar dados no aparelho.'));
      return;
    }
    const req = indexedDB.open(DB_NAME, DB_VERSION);
    req.onupgradeneeded = () => {
      const db = req.result;
      if (!db.objectStoreNames.contains('kv')) db.createObjectStore('kv');
      if (!db.objectStoreNames.contains('queue')) db.createObjectStore('queue', { keyPath: 'id' });
    };
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => {
      dbPromise = null;
      reject(req.error ?? new Error('Falha ao abrir o armazenamento local.'));
    };
  });
  return dbPromise;
}

function tx<T>(store: 'kv' | 'queue', mode: IDBTransactionMode, fn: (s: IDBObjectStore) => IDBRequest<T>): Promise<T> {
  return open().then(
    (db) =>
      new Promise<T>((resolve, reject) => {
        const t = db.transaction(store, mode);
        const req = fn(t.objectStore(store));
        req.onsuccess = () => resolve(req.result);
        req.onerror = () => reject(req.error);
      }),
  );
}

export const kvGet = <T>(key: string) => tx<T | undefined>('kv', 'readonly', (s) => s.get(key) as IDBRequest<T | undefined>).catch(() => undefined);
export const kvSet = (key: string, value: unknown) => tx('kv', 'readwrite', (s) => s.put(value, key)).then(() => undefined);
export const kvDel = (key: string) => tx('kv', 'readwrite', (s) => s.delete(key)).then(() => undefined);

export const queueAll = <T>() => tx<T[]>('queue', 'readonly', (s) => s.getAll() as IDBRequest<T[]>).catch(() => [] as T[]);
export const queuePut = (value: unknown) => tx('queue', 'readwrite', (s) => s.put(value)).then(() => undefined);
export const queueDel = (id: string) => tx('queue', 'readwrite', (s) => s.delete(id)).then(() => undefined);
