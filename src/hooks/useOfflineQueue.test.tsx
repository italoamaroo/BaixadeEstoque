import { act } from 'react';
import { createRoot, type Root } from 'react-dom/client';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { useOfflineQueue } from './useOfflineQueue';

const mocks = vi.hoisted(() => ({ userId: 'user-a' as string | null, listQueued: vi.fn() }));
vi.mock('@/contexts/AuthContext', () => ({ useAuth: () => ({ userId: mocks.userId }) }));
vi.mock('@/lib/offlineQueue', () => ({ QUEUE_EVENT: 'test-queue-change', listQueued: mocks.listQueued }));

let root: Root;
let container: HTMLDivElement;
function Queue() {
  const { items, error, loading } = useOfflineQueue();
  return <div>{loading ? 'carregando' : error ? 'erro' : items.map((item) => item.id).join(',')}</div>;
}

describe('fila offline por usuário', () => {
  beforeEach(() => {
    vi.stubGlobal('IS_REACT_ACT_ENVIRONMENT', true);
    mocks.userId = 'user-a';
    mocks.listQueued.mockReset();
    container = document.createElement('div');
    root = createRoot(container);
  });
  afterEach(async () => {
    await act(async () => root.unmount());
    vi.unstubAllGlobals();
  });

  it('mostra falha de leitura e recupera ao voltar à janela', async () => {
    mocks.listQueued.mockRejectedValueOnce(new Error('IndexedDB indisponível'));
    await act(async () => root.render(<Queue />));
    expect(container.textContent).toBe('erro');
    mocks.listQueued.mockResolvedValueOnce([{ id: 'me-a' }]);
    await act(async () => { window.dispatchEvent(new Event('focus')); });
    expect(container.textContent).toBe('me-a');
  });

  it('não revela itens da conta anterior durante uma troca de usuário', async () => {
    mocks.listQueued.mockResolvedValueOnce([{ id: 'me-a' }]);
    await act(async () => root.render(<Queue />));
    expect(container.textContent).toBe('me-a');
    mocks.userId = 'user-b';
    mocks.listQueued.mockReturnValueOnce(new Promise(() => {}));
    await act(async () => root.render(<Queue />));
    expect(container.textContent).toBe('carregando');
    mocks.userId = null;
    await act(async () => root.render(<Queue />));
    expect(container.textContent).toBe('');
  });

  it('ignora uma leitura antiga que termina depois da mais recente', async () => {
    let finishOld!: (value: { id: string }[]) => void;
    mocks.listQueued.mockReturnValueOnce(new Promise((resolve) => { finishOld = resolve; }));
    await act(async () => root.render(<Queue />));
    mocks.listQueued.mockResolvedValueOnce([{ id: 'atual' }]);
    await act(async () => { window.dispatchEvent(new Event('test-queue-change')); });
    await act(async () => { finishOld([{ id: 'antiga' }]); });
    expect(container.textContent).toBe('atual');
  });
});
