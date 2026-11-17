import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

function fakeTransaction() {
  const request = { result: 'me-1', error: null, onsuccess: null as (() => void) | null };
  const transaction = {
    objectStore: () => ({ put: () => request, getAll: () => request }),
    oncomplete: null as (() => void) | null,
    onabort: null as (() => void) | null,
    error: null as DOMException | null,
  };
  const connection = {
    result: { transaction: () => transaction },
    onsuccess: null as (() => void) | null,
  };
  vi.stubGlobal('indexedDB', {
    open: () => {
      queueMicrotask(() => connection.onsuccess?.());
      return connection;
    },
  });
  return { request, transaction };
}

describe('fila offline', () => {
  beforeEach(() => vi.resetModules());
  afterEach(() => vi.unstubAllGlobals());

  it('só confirma a gravação ao concluir a transação', async () => {
    const { request, transaction } = fakeTransaction();
    const { queuePut } = await import('./offlineDb');
    const done = vi.fn();
    const saved = queuePut({ id: 'me-1' }).then(done);
    await vi.waitFor(() => expect(transaction.oncomplete).toBeTypeOf('function'));
    request.onsuccess?.();
    await Promise.resolve();
    expect(done).not.toHaveBeenCalled();
    transaction.oncomplete?.();
    await saved;
    expect(done).toHaveBeenCalledOnce();
  });

  it('propaga uma falha ao ler a fila', async () => {
    const { transaction } = fakeTransaction();
    const { queueAll } = await import('./offlineDb');
    const result = queueAll();
    const assertion = expect(result).rejects.toThrow('Armazenamento indisponível');
    await vi.waitFor(() => expect(transaction.onabort).toBeTypeOf('function'));
    transaction.error = new DOMException('Armazenamento indisponível', 'AbortError');
    transaction.onabort?.();
    await assertion;
  });
});
