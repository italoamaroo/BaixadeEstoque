import { beforeEach, describe, expect, it, vi } from 'vitest';
const m = vi.hoisted(() => ({ all: vi.fn(), del: vi.fn(), put: vi.fn(), add: vi.fn(), create: vi.fn(), upload: vi.fn() }));
vi.mock('./offlineDb', () => ({ queueAll: m.all, queueDel: m.del, queuePut: m.put, queueAdd: m.add }));
vi.mock('./api', () => ({ createMovement: m.create, uploadSignature: m.upload }));
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
