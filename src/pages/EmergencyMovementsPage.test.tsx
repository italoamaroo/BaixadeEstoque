import { act } from 'react';
import { createRoot, type Root } from 'react-dom/client';
import { MemoryRouter } from 'react-router-dom';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { EmergencyMovementsPage } from './EmergencyMovementsPage';
import { MovementsPage } from './MovementsPage';

const mocks = vi.hoisted(() => ({
  search: vi.fn(), repeat: vi.fn(),
  current: { id: 'mur' } as { id: string } | null,
  exportAllowed: true, repeatAllowed: false,
}));
vi.mock('@/contexts/AuthContext', () => ({ useAuth: () => ({
  can: (permission: string) => permission === 'exportExcel' ? mocks.exportAllowed : permission === 'viewRepeatAlerts' ? mocks.repeatAllowed : permission === 'viewMovements',
  warehouses: [{ id: 'mur', name: 'Muribeca' }, { id: 'dir', name: 'Dois Irmãos' }],
}) }));
vi.mock('@/contexts/WarehouseContext', () => ({ useWarehouse: () => ({ current: mocks.current }) }));
vi.mock('@/hooks/useRealtimeMovements', () => ({ useRealtimeMovements: () => {} }));
vi.mock('@/hooks/useLookups', () => ({ useLookups: () => ({ data: {} }) }));
vi.mock('@/components/InformSaModal', () => ({ InformSaModal: () => null }));
vi.mock('@/lib/api', () => ({ searchMovements: mocks.search, getRepeatAssetWithdrawals: mocks.repeat, listProfiles: async () => [] }));

let root: Root;
let container: HTMLDivElement;
const row = {
  id: 'me-1', me_number: 'ME-MUR-2026-001', status: 'concluida', is_emergency: true,
  movement_at: '2026-11-17T12:00:00Z', updated_at: '2026-11-17T12:00:00Z',
  item_count: 2, requester_name: 'Solicitante', warehouse_name: 'Muribeca',
  emergency_reason: 'Manutenção emergencial do equipamento', fixed_asset: 'CAM-01', materials_summary: 'Parafuso, porca',
};
const render = async (url = '/emergenciais', emergency = true) => {
  await act(async () => root.render(
    <MemoryRouter initialEntries={[url]} future={{ v7_startTransition: true, v7_relativeSplatPath: true }}>
      {emergency ? <EmergencyMovementsPage /> : <MovementsPage />}
    </MemoryRouter>,
  ));
};
const clickText = async (text: string) => {
  const button = [...container.querySelectorAll('button')].find((node) => node.textContent?.trim() === text);
  expect(button, text).toBeDefined();
  await act(async () => button!.click());
};

describe('consulta exclusiva de MEs emergenciais', () => {
  beforeEach(() => {
    vi.stubGlobal('IS_REACT_ACT_ENVIRONMENT', true);
    mocks.current = { id: 'mur' };
    mocks.exportAllowed = true;
    mocks.repeatAllowed = false;
    mocks.search.mockReset().mockResolvedValue({ rows: [row], total: 30 });
    mocks.repeat.mockReset().mockResolvedValue({ total: 0, items: [] });
    container = document.createElement('div');
    root = createRoot(container);
  });
  afterEach(async () => {
    await act(async () => root.unmount());
    vi.unstubAllGlobals();
  });

  it('ignora filtros conflitantes na URL e exporta apenas emergenciais', async () => {
    await render('/emergenciais?emergency=nao&pending_sa=true&sa_number=123');
    expect(mocks.search.mock.lastCall?.[0]).toMatchObject({ emergency: 'sim', pending_sa: false, sa_number: '', warehouse_id: 'mur' });
    const href = container.querySelector<HTMLAnchorElement>('a[href^="/exportar?"]')!.getAttribute('href')!;
    const filters = new URLSearchParams(href.split('?')[1]);
    expect(filters.get('emergency')).toBe('sim');
    expect(filters.get('warehouse_id')).toBe('mur');
    expect(filters.has('pending_sa')).toBe(false);
    expect(container.textContent).toContain(row.emergency_reason);
    expect(container.textContent).toContain('30 MEs emergenciais encontradas');
    expect(container.querySelector('a[href="/movimentacoes/me-1"]')).not.toBeNull();
    expect(container.querySelector('button[title="Informar SA"]')).toBeNull();
    expect(mocks.repeat).not.toHaveBeenCalled();
  });

  it('mantém o recorte e o estoque ao limpar filtros e trocar de página', async () => {
    await render('/emergenciais?requester=Nome');
    await clickText('Limpar filtros');
    expect(mocks.search.mock.lastCall?.[0]).toMatchObject({ emergency: 'sim', warehouse_id: 'mur', requester: '' });
    expect(container.textContent).not.toContain('Tipo de ME');
    expect(container.textContent).not.toContain('Somente pendência de SA');
    await act(async () => container.querySelector<HTMLButtonElement>('button[aria-label="Próxima página"]')!.click());
    expect(mocks.search.mock.lastCall?.[0]).toMatchObject({ emergency: 'sim', warehouse_id: 'mur' });
    expect(mocks.search.mock.lastCall?.[1]).toBe(2);
  });

  it('acompanha o seletor do topo e permite o consolidado', async () => {
    await render();
    mocks.current = { id: 'dir' };
    await render();
    expect(mocks.search.mock.lastCall?.[0]).toMatchObject({ emergency: 'sim', warehouse_id: 'dir' });
    mocks.current = null;
    await render();
    expect(mocks.search.mock.lastCall?.[0]).toMatchObject({ emergency: 'sim', warehouse_id: '' });
  });

  it('respeita permissão de exportação e consulta alertas apenas quando permitido', async () => {
    mocks.exportAllowed = false;
    mocks.repeatAllowed = true;
    await render();
    expect(container.querySelector('a[href^="/exportar?"]')).toBeNull();
    expect(mocks.repeat.mock.lastCall?.[0]).toMatchObject({ emergency: 'sim', warehouse_id: 'mur' });
  });

  it('preserva a consulta de MEs normais na tela de movimentações', async () => {
    await render('/movimentacoes?emergency=nao', false);
    expect(mocks.search.mock.lastCall?.[0].emergency).toBe('nao');
    expect(container.textContent).toContain('Tipo de ME');
    expect(container.querySelector('h1')?.textContent).toBe('Movimentações');
  });
});
