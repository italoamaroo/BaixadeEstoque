import { act } from 'react';
import { createRoot, type Root } from 'react-dom/client';
import { beforeEach, afterEach, describe, it, expect, vi } from 'vitest';
import { TerminalOfflineWithdrawal } from './TerminalOfflineWithdrawal';
import type { CounterSnapshot } from '@/lib/api';
const mocks = vi.hoisted(() => ({ load: vi.fn(), back: vi.fn(), refresh: vi.fn() }));
vi.mock('@/contexts/AuthContext', () => ({ useAuth: () => ({ userId: 'terminal', settings: {} }) }));
vi.mock('@/hooks/useOnlineStatus', () => ({ useOnlineStatus: () => true }));
vi.mock('@/hooks/useOfflineQueue', () => ({ useOfflineQueue: () => ({ items: [] }) }));
vi.mock('@/lib/terminalOffline', () => ({ loadTerminalCopy: mocks.load }));
vi.mock('@/components/PhotoCapture', () => ({ PhotoCapture: () => null }));
vi.mock('@/components/SignaturePad', () => ({ SignaturePad: () => null }));
let root: Root; let container: HTMLDivElement;
const snap = { session: { offline_ready: true, version: 2, status: 'aguardando_confirmacao' }, movement: { id: 'me', me_number: 'ME-TESTE', requester_name: 'Teste', requester_registration: '1' }, items: [] } as unknown as CounterSnapshot;
const copy = { request_id: 'request', saved_at: new Date().toISOString(), snapshot: snap };
async function render(sourceSnapshot?: CounterSnapshot) { await act(async () => root.render(<TerminalOfflineWithdrawal onBack={mocks.back} onRefresh={mocks.refresh} sourceSnapshot={sourceSnapshot} />)); }
describe('preparo da retirada offline no tablet', () => {
  beforeEach(() => { vi.stubGlobal('IS_REACT_ACT_ENVIRONMENT', true); container = document.createElement('div'); root = createRoot(container); vi.clearAllMocks(); mocks.load.mockReset().mockResolvedValue(undefined); mocks.refresh.mockResolvedValue(undefined); });
  afterEach(async () => { await act(async () => root.unmount()); vi.unstubAllGlobals(); });
  it('mantém a tela aberta sem lista e informa como preparar, sem voltar ao balcão', async () => {
    await render();
    expect(container.textContent).toContain('Retirada sem internet');
    expect(container.textContent).toContain('Finalizar separação');
    expect(container.textContent).toContain('Verificar lista autorizada');
    expect(mocks.back).not.toHaveBeenCalled();
  });
  it('carrega uma lista que chegou depois sem precisar sair da tela', async () => {
    await render();
    mocks.load.mockResolvedValue(copy);
    await render(snap);
    expect(container.textContent).toContain('Materiais da retirada');
    expect(container.textContent).toContain('ME-TESTE');
    expect(mocks.back).not.toHaveBeenCalled();
  });
  it('permite verificar a autorização pela própria tela', async () => {
    await render(); mocks.load.mockResolvedValue(copy);
    const button = [...container.querySelectorAll('button')].find((b) => b.textContent === 'Verificar lista autorizada')!;
    await act(async () => button.click());
    expect(mocks.refresh).toHaveBeenCalledOnce();
    expect(container.textContent).toContain('Materiais da retirada');
  });
  it('distingue atualização pendente de uma lista ainda não finalizada', async () => {
    await render({ ...snap, session: { ...snap.session, offline_ready: undefined } });
    expect(container.textContent).toContain('Atualização offline pendente');
    await render({ ...snap, session: { ...snap.session, status: 'em_separacao' } });
    expect(container.textContent).toContain('Aguardando o almoxarife finalizar a lista');
  });
});
