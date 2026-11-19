import { describe, expect, it } from 'vitest';
import { canReviewLocalRetention, createdRetentionUntil } from './retention';
describe('guarda por dez anos civis', () => {
  it('preserva a hora e ajusta 29/02 ao último dia do mês', () => {
    expect(createdRetentionUntil('2024-02-29T15:30:00Z')).toBe('2034-02-28T15:30:00.000Z');
    expect(createdRetentionUntil('2026-11-19T15:30:00Z')).toBe('2036-11-19T15:30:00.000Z');
  });
  it('bloqueia descarte antecipado e datas desconhecidas', () => {
    expect(canReviewLocalRetention('2026-11-19T15:30:00Z', Date.parse('2036-11-19T15:29:59Z'))).toBe(false);
    expect(canReviewLocalRetention('2026-11-19T15:30:00Z', Date.parse('2036-11-19T15:30:00Z'))).toBe(true);
    expect(canReviewLocalRetention('inválida')).toBe(false);
  });
});
