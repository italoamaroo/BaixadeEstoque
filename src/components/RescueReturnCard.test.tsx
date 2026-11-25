import { act } from 'react';
import { createRoot, type Root } from 'react-dom/client';
import { beforeEach, afterEach, describe, it, expect, vi } from 'vitest';
import { RescueReturnCard } from './RescueReturnCard';
import type { MovementItem, MovementRow } from '@/types/db';
const api = vi.hoisted(() => ({ save: vi.fn() }));
vi.mock('@/lib/api', () => ({ returnRescue: api.save }));
const movement = { id: 'm', is_rescue: true, status: 'aguardando_retorno' } as MovementRow;
const items = [{ id: 'i', material_name: 'Peça', unit: 'UN', quantity_delivered: 5 }] as MovementItem[];
let root: Root; let container: HTMLDivElement;
async function render(m = movement, rows = items, canReturn = true) {
  await act(async () => root.render(<RescueReturnCard key={m.rescue_returned_at ?? 'new'} movement={m} items={rows} canReturn={canReturn} onSaved={() => {}} />));
}
describe('conferência do socorro', () => {
  beforeEach(() => { vi.stubGlobal('IS_REACT_ACT_ENVIRONMENT', true); container = document.createElement('div'); root = createRoot(container); api.save.mockReset().mockResolvedValue({}); });
  afterEach(async () => { await act(async () => root.unmount()); vi.unstubAllGlobals(); });
  it('não envia conferência sem confirmação do mecânico', async () => {
    await render();
    await act(async () => container.querySelector('button')!.click());
    expect(api.save).not.toHaveBeenCalled();
    expect(container.textContent).toContain('Confirme a conferência com o mecânico');
  });
  it('mostra o consumo parcial separado do retirado e devolvido', async () => {
    await render({ ...movement, rescue_returned_at: '2026-11-25T12:00:00Z', rescue_return_note: 'Conferido' }, [{ ...items[0], quantity_delivered: 2, rescue_quantity_out: 5, rescue_quantity_returned: 3 }]);
    expect(container.textContent).toContain('Utilizado em parte');
    expect([...container.querySelectorAll('tbody td')].map((e) => e.textContent)).toEqual(['Peça (UN)', '5', '2', '3']);
    expect(container.querySelector('button')).toBeNull();
  });
  it('devolução total é sem consumo, preservando a retirada', async () => {
    await render({ ...movement, status: 'concluida', rescue_returned_at: '2026-11-25T12:00:00Z' }, [{ ...items[0], quantity_delivered: 0, rescue_quantity_out: 5, rescue_quantity_returned: 5 }]);
    expect(container.textContent).toContain('Sem consumo — devolução total');
    expect([...container.querySelectorAll('tbody td')].map((e) => e.textContent)).toEqual(['Peça (UN)', '5', '0', '5']);
  });
  it('perfil de consulta não recebe formulário de conferência', async () => {
    await render(movement, items, false);
    expect(container.querySelector('input')).toBeNull();
    expect(container.querySelector('button')).toBeNull();
  });
});
