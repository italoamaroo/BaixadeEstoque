import { act } from 'react';
import { createRoot, type Root } from 'react-dom/client';
import { MemoryRouter, Route, Routes } from 'react-router-dom';
import { beforeEach, afterEach, describe, it, expect, vi } from 'vitest';
import { CounterPage } from './CounterPage';
const m = vi.hoisted(() => ({ scan: undefined as undefined | ((code: string) => void), add: vi.fn(), quantity: vi.fn(), refresh: vi.fn() }));
vi.mock('@/contexts/AuthContext', () => ({ useAuth: () => ({ userId: 'almox' }) }));
vi.mock('@/contexts/WarehouseContext', () => ({ useWarehouse: () => ({ options: [] }) }));
vi.mock('@/hooks/useOnlineStatus', () => ({ useOnlineStatus: () => true }));
vi.mock('@/lib/scanFeedback', () => ({ playFeedback: vi.fn() }));
vi.mock('@/components/MaterialSearch', () => ({ MaterialSearch: () => null }));
vi.mock('./CounterOpenForm', () => ({ CounterOpenForm: () => null }));
vi.mock('@/hooks/useHidScanner', () => ({ normalizeScannedCode: (v: string) => v.trim(), useHidScanner: (_ref: unknown, opts: { onScan: (v: string) => void }) => { m.scan = opts.onScan; return { focus: () => {}, onInputKeyDown: () => {}, onInputBlur: () => {} }; } }));
vi.mock('@/lib/api', () => ({ counterAdd: m.add, counterSetQuantity: m.quantity }));
vi.mock('@/hooks/useCounterSession', () => ({ useCounterSession: () => ({ loading: false, error: null, live: true, refresh: m.refresh, snapshot: {
  session: { status: 'em_separacao', version: 1, terminal_paired: true, terminal_name: 'Tablet teste' },
  movement: { id: 'me', me_number: 'ME-TESTE', status: 'rascunho', warehouse_name: 'Muribeca', requester_name: 'Teste', requester_registration: '1' },
  items: [{ id: 'item', line_number: 1, material_code: 'MAT-TESTE', material_name: 'Material teste', unit: 'UN', quantity_requested: 1, quantity_delivered: 1, created_at: new Date().toISOString(), updated_at: new Date().toISOString() }],
} }) }));
let root: Root; let container: HTMLDivElement;
async function render() { await act(async () => root.render(<MemoryRouter initialEntries={['/balcao/me']} future={{ v7_startTransition: true, v7_relativeSplatPath: true }}><Routes><Route path="balcao/:id" element={<CounterPage />} /></Routes></MemoryRouter>)); }
async function change(label: string, value: string) {
  const input = container.querySelector(`input[aria-label="${label}"]`) as HTMLInputElement;
  await act(async () => { input.focus(); Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value')!.set!.call(input, value); input.dispatchEvent(new Event('input', { bubbles: true })); });
  return input;
}
describe('quantidade no balcão', () => {
  beforeEach(() => { vi.stubGlobal('IS_REACT_ACT_ENVIRONMENT', true); container = document.createElement('div'); document.body.appendChild(container); root = createRoot(container); vi.clearAllMocks(); m.add.mockResolvedValue({ result: 'incluido', material_name: 'Material', quantity_delivered: 1, unit: 'UN' }); m.quantity.mockResolvedValue({}); m.refresh.mockResolvedValue(undefined); });
  afterEach(async () => { await act(async () => root.unmount()); container.remove(); localStorage.clear(); vi.unstubAllGlobals(); });
  it('inclui uma unidade sem perguntar, mesmo com a preferência antiga ativada', async () => {
    localStorage.setItem('baixas-estoque:balcao-perguntar-qtd', 'sim');
    await render();
    await act(async () => m.scan!('MAT-LEITURA-TESTE'));
    expect(m.add).toHaveBeenCalledWith(expect.objectContaining({ code: 'MAT-LEITURA-TESTE', quantity: 1 }));
    expect(container.textContent).not.toContain('Perguntar a quantidade');
    expect(container.querySelector('[role="dialog"]')).toBeNull();
    await act(async () => m.scan!('MAT-OUTRO'));
    expect(m.add.mock.lastCall?.[0].quantity).toBe(1);
  });
  it('solicitada atualiza atendida e grava ambas na mesma operação', async () => {
    await render(); const req = await change('Quantidade solicitada', '5');
    expect((container.querySelector('[aria-label="Quantidade atendida"]') as HTMLInputElement).value).toBe('5');
    await act(async () => req.blur());
    expect(m.quantity).toHaveBeenCalledWith('item', 5, 5);
  });
  it('permite ajustar atendida separadamente e ressincroniza numa nova solicitação', async () => {
    await render(); const del = await change('Quantidade atendida', '0,5'); await act(async () => del.blur());
    expect(m.quantity).toHaveBeenCalledWith('item', 1, 0.5);
    const req = await change('Quantidade solicitada', '3,5'); await act(async () => req.blur());
    expect(m.quantity).toHaveBeenLastCalledWith('item', 3.5, 3.5);
  });
});
