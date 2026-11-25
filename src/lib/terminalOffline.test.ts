import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { CounterSnapshot } from './api';
const cache = vi.hoisted(() => new Map<string, unknown>());
vi.mock('./offlineDb', () => ({ kvGet: async (key: string) => cache.get(key), kvSet: async (key: string, value: unknown) => { cache.set(key, value); }, kvDel: async (key: string) => { cache.delete(key); } }));
import { loadTerminalCopy, saveTerminalCopy } from './terminalOffline';
const snapshot = () => ({ session: { id: 's', offline_ready: true, status: 'aguardando_confirmacao', version: 4, pairing_code: '123456' }, movement: { id: 'm', status: 'aguardando_assinatura', separation_finished_at: new Date().toISOString() }, items: [{ id: 'i', quantity_delivered: 2 }] } as unknown as CounterSnapshot);
beforeEach(() => { cache.clear(); });
describe('lista autorizada para o tablet offline', () => {
  it('não permite iniciar sem autorização nem expõe o código de pareamento', async () => {
    await saveTerminalCopy('u', { ...snapshot(), session: { ...snapshot().session, status: 'em_separacao' } });
    expect(await loadTerminalCopy('u')).toBeUndefined();
    await saveTerminalCopy('u', snapshot());
    expect((await loadTerminalCopy('u'))?.snapshot.session.pairing_code).toBeNull();
    expect(await loadTerminalCopy('outra-conta')).toBeUndefined();
  });
  it('conserva o identificador na mesma versão e renova quando a lista muda', async () => {
    await saveTerminalCopy('u', snapshot()); const first = await loadTerminalCopy('u');
    await saveTerminalCopy('u', snapshot()); expect((await loadTerminalCopy('u'))?.request_id).toBe(first?.request_id);
    await saveTerminalCopy('u', { ...snapshot(), session: { ...snapshot().session, version: 5 } });
    expect((await loadTerminalCopy('u'))?.request_id).not.toBe(first?.request_id);
    await saveTerminalCopy('u', null); expect(await loadTerminalCopy('u')).toBeUndefined();
  });
  it('recusa cache vencido e banco sem capacidade offline', async () => {
    await saveTerminalCopy('u', snapshot());
    const copy = cache.get('cache:terminal-authorized:u') as { saved_at: string }; copy.saved_at = '2000-01-01T00:00:00Z';
    expect(await loadTerminalCopy('u')).toBeUndefined();
    await saveTerminalCopy('u', { ...snapshot(), session: { ...snapshot().session, offline_ready: undefined } });
    expect(await loadTerminalCopy('u')).toBeUndefined();
  });
});
