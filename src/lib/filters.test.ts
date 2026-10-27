import { describe, expect, it } from 'vitest';
import { EMPTY_FILTERS, countActiveFilters, describeFilters, exportFileName, filtersFromSearchParams, filtersToSearchParams, toRpcFilters, validateFilters } from './filters';

const whs = [{ id: 'w1', code: 'MUR', name: 'Muribeca' }, { id: 'w2', code: 'DIR', name: 'Dois Irmãos' }];

describe('filtros', () => {
  it('remove vazios ao enviar ao banco', () => {
    expect(toRpcFilters({ ...EMPTY_FILTERS, warehouse_id: 'w1', status: ['aguardando_sa'], q: '  ' })).toEqual({ warehouse_id: 'w1', status: ['aguardando_sa'], q: '' });
  });
  it('conta filtros ativos', () => {
    expect(countActiveFilters({ ...EMPTY_FILTERS, date_from: '2026-10-01', pending_sa: true })).toBe(2);
  });
  it('valida período', () => {
    expect(validateFilters({ date_from: '2026-10-31', date_to: '2026-10-01' })).toMatch(/maior/);
    expect(validateFilters({ date_from: '2026-10-01', date_to: '2026-10-31' })).toBeNull();
  });
  it('gera nome de arquivo com período e estoque', () => {
    expect(exportFileName({ warehouse_id: 'w1', date_from: '2026-10-01', date_to: '2026-10-31' }, whs, 'resumo')).toBe('baixas_muribeca_2026-10-01_a_2026-10-31.xlsx');
    expect(exportFileName({ warehouse_id: 'w2' }, whs, 'itens')).toBe('baixas_dois_irmaos_itens.xlsx');
  });
  it('descreve filtros para o Excel', () => {
    const lines = describeFilters({ date_from: '2026-10-01', date_to: '2026-10-31', warehouse_id: 'w1', status: ['aguardando_sa'] }, whs);
    expect(lines).toEqual(['Período: 01/10/2026 a 31/10/2026', 'Estoque: Muribeca', 'Status: Aguardando SA']);
  });
  it('ida e volta pela URL', () => {
    const f = { ...EMPTY_FILTERS, status: ['concluida', 'cancelada'] as const, material: 'filtro', pending_sa: true };
    const back = filtersFromSearchParams(filtersToSearchParams({ ...f, status: [...f.status] }));
    expect(back.status).toEqual(['concluida', 'cancelada']);
    expect(back.material).toBe('filtro');
    expect(back.pending_sa).toBe(true);
  });
});
