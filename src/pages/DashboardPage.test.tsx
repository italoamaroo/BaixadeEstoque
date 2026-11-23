import { act, type ReactNode } from 'react';
import { createRoot, type Root } from 'react-dom/client';
import { MemoryRouter } from 'react-router-dom';
import { beforeEach, afterEach, describe, it, expect, vi } from 'vitest';
import { DashboardPage } from './DashboardPage';

const mocks = vi.hoisted(() => ({ dashboard: vi.fn(), search: vi.fn(), repeat: vi.fn() }));
vi.mock('@/contexts/AuthContext', () => ({ useAuth: () => ({ warehouses: [{ id: 'dir', name: 'Dois Irmãos' }], can: () => false, displayName: 'Teste' }) }));
vi.mock('@/hooks/useHeaderWarehouseFilter', () => ({ useHeaderWarehouseFilter: () => {} }));
vi.mock('@/hooks/useRealtimeMovements', () => ({ useRealtimeMovements: () => {} }));
vi.mock('@/components/FiltersPanel', () => ({ FiltersPanel: () => null }));
vi.mock('@/components/RepeatAssetCard', () => ({ RepeatAssetCard: () => null }));
vi.mock('@/lib/api', () => ({ getDashboard: mocks.dashboard, searchMovements: mocks.search, getRepeatAssetWithdrawals: mocks.repeat }));
vi.mock('recharts', () => {
  const Box = ({ children }: { children?: ReactNode }) => <div>{children}</div>;
  return { Bar: Box, Cell: () => null, BarChart: Box, CartesianGrid: () => null, Legend: () => null, ResponsiveContainer: Box, Tooltip: () => null, XAxis: () => null, YAxis: () => null };
});
const data = {
  cards: { total_mes: 20, today_mes: 3, item_lines: 40, qty_delivered: 50, aguardando_aprovacao: 1, aguardando_sa: 4, sa_informada: 3, concluida: 10, cancelada: 0 },
  by_warehouse: [], daily: [], weekly: [], monthly: [], qty_by_unit: [], top_materials_lines: [], top_materials_qty: [], by_sector: [], by_service_front: [], by_user: [],
  pending_aging: [{ warehouse: 'Dois Irmãos', bucket: 'Mais de 7 dias', mes: 2 }],
};
let root: Root;
let container: HTMLDivElement;
const render = async (url = '/?warehouse_id=dir&requester=Carlos&date_from=2026-11-01') => {
  await act(async () => root.render(<MemoryRouter initialEntries={[url]} future={{ v7_startTransition: true, v7_relativeSplatPath: true }}><DashboardPage /></MemoryRouter>));
};
describe('painel operacional', () => {
  beforeEach(() => {
    vi.stubGlobal('IS_REACT_ACT_ENVIRONMENT', true);
    container = document.createElement('div'); root = createRoot(container);
    mocks.dashboard.mockReset().mockResolvedValue(data);
    mocks.search.mockReset().mockResolvedValue({ rows: [], total: 2 });
    mocks.repeat.mockReset();
  });
  afterEach(async () => { await act(async () => root.unmount()); vi.unstubAllGlobals(); });
  it('preserva os filtros na consulta de pendências e nos atalhos dos cartões', async () => {
    await render();
    expect(mocks.search.mock.calls[0][0]).toMatchObject({ warehouse_id: 'dir', requester: 'Carlos', date_from: '2026-11-01', status: ['aguardando_assinatura', 'aguardando_aprovacao', 'aguardando_sa', 'sa_informada'] });
    const link = [...container.querySelectorAll('a')].find((a) => a.textContent?.includes('Pendentes SA / ERP'))!;
    const query = new URLSearchParams(link.getAttribute('href')!.split('?')[1]);
    expect(query.get('warehouse_id')).toBe('dir'); expect(query.get('requester')).toBe('Carlos');
    expect(query.get('status')).toBe('aguardando_sa,sa_informada');
    expect(link.textContent).toContain('7');
    expect(mocks.repeat).not.toHaveBeenCalled();
  });
  it('não consulta pendências fora do status selecionado', async () => {
    await render('/?status=concluida&warehouse_id=dir');
    expect(mocks.search).not.toHaveBeenCalled();
    expect(container.textContent).toContain('Nenhuma pendência encontrada com estes filtros.');
  });
  it('mostra falha da consulta em vez de dizer que não há pendências', async () => {
    mocks.search.mockRejectedValue(new Error('Servidor indisponível'));
    await render();
    expect(container.textContent).toContain('Não foi possível consultar as pendências');
    expect(container.textContent).not.toContain('Nenhuma pendência encontrada');
    expect(container.textContent).toContain('Concluídas');
  });
  it('oferece a ME pendente e sua próxima ação', async () => {
    mocks.search.mockResolvedValue({ total: 1, rows: [{ id: 'me1', me_number: 'ME-001', status: 'sa_informada', movement_at: new Date().toISOString(), requester_name: 'Carlos', warehouse_name: 'Dois Irmãos' }] });
    await render();
    expect(container.textContent).toContain('Confirmar baixa no ERP');
    expect(container.querySelector('a[href="/movimentacoes/me1"]')).not.toBeNull();
  });
});
