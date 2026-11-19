import { act } from 'react';
import { createRoot, type Root } from 'react-dom/client';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { AdminMfaGate } from './AdminMfaGate';
const m = vi.hoisted(() => ({ assurance: vi.fn(), factors: vi.fn(), verify: vi.fn(), refresh: vi.fn(), policy: vi.fn() }));
vi.mock('@/lib/supabase', () => ({ supabase: { rpc: m.policy, auth: { mfa: { getAuthenticatorAssuranceLevel: m.assurance, listFactors: m.factors, challengeAndVerify: m.verify } } } }));
vi.mock('@/contexts/AuthContext', () => ({ useAuth: () => ({ refreshAccess: m.refresh, signOut: vi.fn() }) }));
let root: Root; let container: HTMLDivElement;
beforeEach(() => {
  vi.stubGlobal('IS_REACT_ACT_ENVIRONMENT', true);
  container = document.createElement('div'); root = createRoot(container);
  m.assurance.mockReset(); m.factors.mockReset(); m.policy.mockReset().mockResolvedValue({ data: false, error: null });
});
afterEach(async () => { await act(async () => root.unmount()); vi.unstubAllGlobals(); });
const render = async () => { await act(async () => root.render(<AdminMfaGate><div>Dados administrativos</div></AdminMfaGate>)); };
describe('segundo fator administrativo', () => {
  it('mantém acesso durante implantação quando a regra ainda não existe no banco', async () => {
    m.policy.mockResolvedValue({ data: null, error: { code: 'PGRST202' } });
    await render(); expect(container.textContent).toContain('Dados administrativos');
    expect(m.assurance).not.toHaveBeenCalled();
  });
  it('não usa compatibilidade em falha de rede ou de autorização', async () => {
    m.policy.mockResolvedValue({ data: null, error: { code: '42501', message: 'Acesso negado' } });
    await render(); expect(container.textContent).not.toContain('Dados administrativos');
  });
  it('não renderiza dados administrativos em sessão AAL1', async () => {
    m.assurance.mockResolvedValue({ data: { currentLevel: 'aal1' }, error: null });
    m.factors.mockResolvedValue({ data: { totp: [{ id: 'fator', status: 'verified' }] }, error: null });
    await render(); expect(container.textContent).not.toContain('Dados administrativos');
    expect(container.textContent).toContain('Código do autenticador');
  });
  it('renderiza a aplicação após AAL2 confirmado pelo SDK', async () => {
    m.assurance.mockResolvedValue({ data: { currentLevel: 'aal2' }, error: null });
    await render(); expect(container.textContent).toContain('Dados administrativos');
  });
  it('falha fechada quando a consulta de assurance retorna erro', async () => {
    m.assurance.mockResolvedValue({ data: null, error: new Error('Falha na verificação') });
    await render(); expect(container.textContent).not.toContain('Dados administrativos');
    expect(container.textContent).toContain('Falha na verificação');
  });
});
