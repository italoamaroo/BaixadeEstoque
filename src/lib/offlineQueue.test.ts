import { beforeEach, describe, expect, it, vi } from 'vitest';
const m = vi.hoisted(() => ({ all: vi.fn(), del: vi.fn(), put: vi.fn(), add: vi.fn(), create: vi.fn(), upload: vi.fn(), confirm: vi.fn(), photo: vi.fn() }));
vi.mock('./offlineDb', () => ({ queueAll: m.all, queueDel: m.del, queuePut: m.put, queueAdd: m.add }));
vi.mock('./api', () => ({ createMovement: m.create, uploadSignature: m.upload, confirmCounterOffline: m.confirm, uploadPhoto: m.photo }));
import { discardQueued, syncQueue } from './offlineQueue';
beforeEach(() => { vi.clearAllMocks(); });
describe('guarda da fila offline', () => {
  it('não descarta uma retirada ainda em guarda', async () => {
    m.all.mockResolvedValue([{ id: 'q', saved_at: new Date().toISOString() }]);
    await expect(discardQueued('q')).rejects.toThrow('Guarda de 10 anos');
    expect(m.del).not.toHaveBeenCalled();
  });
  it('permite revisão após dez anos e não inventa data ausente', async () => {
    m.all.mockResolvedValue([{ id: 'q', saved_at: '2000-01-01T00:00:00Z' }]);
    await discardQueued('q'); expect(m.del).toHaveBeenCalledWith('q');
    m.all.mockResolvedValue([{ id: 'x' }]);
    await expect(discardQueued('x')).rejects.toThrow('Data ausente');
  });
  it('remove transporte somente após preservar a saída no servidor', async () => {
    const q = { id: 'q', user_id: 'u', saved_at: new Date().toISOString(), offline_at: new Date().toISOString(), status: 'pendente', attempts: 0, signature_path: 'path', payload: {} };
    m.all.mockResolvedValue([q]); m.create.mockResolvedValue({ me_number: 'ME-1' });
    const r = await syncQueue('u');
    expect(r.sent).toHaveLength(1); expect(m.del).toHaveBeenCalledWith('q');
    expect(m.create.mock.invocationCallOrder[0]).toBeLessThan(m.del.mock.invocationCallOrder[0]);
  });
});

describe('confirmação offline do tablet', () => {
  it('envia para a ME existente sem chamar criação de uma nova saída', async () => {
    const q = { id: 'receipt-1', user_id: 'terminal', kind: 'counter_confirmation', saved_at: new Date().toISOString(), offline_at: new Date().toISOString(), signature_signed_at: new Date().toISOString(), status: 'pendente', attempts: 0, signature_path: 'MUR/2026/me/signature.png', payload: { movement_id: 'me', movement_at: new Date().toISOString(), version: 4, items: [] } };
    m.all.mockResolvedValue([q]); m.confirm.mockResolvedValue({ me_number: 'ME-EXISTENTE' });
    const r = await syncQueue('terminal');
    expect(r.sent[0].me_number).toBe('ME-EXISTENTE');
    expect(m.confirm).toHaveBeenCalledWith('me', expect.objectContaining({ request_id: 'receipt-1', version: 4 }));
    expect(m.create).not.toHaveBeenCalled();
    expect(m.del).toHaveBeenCalledWith('receipt-1');
  });
  it('mantém a confirmação no aparelho quando a lista foi alterada', async () => {
    const q = { id: 'receipt-2', user_id: 'terminal', kind: 'counter_confirmation', saved_at: new Date().toISOString(), offline_at: new Date().toISOString(), status: 'pendente', attempts: 0, signature_path: 'path', payload: { movement_id: 'me' } };
    m.all.mockResolvedValue([q]); m.confirm.mockRejectedValue(new Error('A autorização ou lista mudou.'));
    const r = await syncQueue('terminal');
    expect(r.failed).toHaveLength(1); expect(m.del).not.toHaveBeenCalled();
    expect(m.put).toHaveBeenCalledWith(expect.objectContaining({ status: 'erro' }));
  });
});
