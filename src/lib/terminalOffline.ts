import type { CounterSnapshot } from './api';
import { kvDel, kvGet, kvSet } from './offlineDb';
import { CACHE_VALID_MS } from './offlineCache';

export interface AuthorizedTerminalCopy { snapshot: CounterSnapshot; saved_at: string; request_id: string }
const key = (user: string) => `cache:terminal-authorized:${user}`;
export function isAuthorizedTerminalSnapshot(s: CounterSnapshot | null): s is CounterSnapshot {
  return Boolean(s?.session.offline_ready && s.session.status === 'aguardando_confirmacao' && s.movement.status === 'aguardando_assinatura' && s.movement.separation_finished_at && s.items.length);
}
export async function saveTerminalCopy(user: string, snapshot: CounterSnapshot | null) {
  if (!isAuthorizedTerminalSnapshot(snapshot)) { await kvDel(key(user)); return; }
  const prev = await kvGet<AuthorizedTerminalCopy>(key(user));
  const same = prev?.snapshot.movement.id === snapshot.movement.id && prev.snapshot.session.version === snapshot.session.version;
  await kvSet(key(user), { snapshot: { ...snapshot, session: { ...snapshot.session, pairing_code: null } }, saved_at: new Date().toISOString(), request_id: same ? prev.request_id : crypto.randomUUID() });
}
export async function loadTerminalCopy(user: string): Promise<AuthorizedTerminalCopy | undefined> {
  const copy = await kvGet<AuthorizedTerminalCopy>(key(user));
  const age = copy ? Date.now() - new Date(copy.saved_at).getTime() : NaN;
  if (!copy || !isAuthorizedTerminalSnapshot(copy.snapshot) || !Number.isFinite(age) || age < 0 || age > CACHE_VALID_MS) {
    await kvDel(key(user)); return undefined;
  }
  return copy;
}
