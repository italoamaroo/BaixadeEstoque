import { useEffect, useState } from 'react';
import { useAuth } from '@/contexts/AuthContext';
import { QUEUE_EVENT, listQueued, type QueuedMovement } from '@/lib/offlineQueue';

/** Saídas guardadas no aparelho do usuário logado, atualizadas a cada mudança da fila. */
export function useOfflineQueue() {
  const { userId } = useAuth();
  type QueueState = { userId: string | null; items: QueuedMovement[]; error: boolean; loading: boolean };
  const [state, setState] = useState<QueueState>();
  useEffect(() => {
    if (!userId) return;
    let version = 0;
    const reload = () => {
      const request = ++version;
      void listQueued(userId).then(
        (items) => {
          if (request === version) setState({ userId, items, error: false, loading: false });
        },
        () => {
          if (request === version) setState({ userId, items: [], error: true, loading: false });
        },
      );
    };
    reload();
    window.addEventListener(QUEUE_EVENT, reload);
    window.addEventListener('focus', reload);
    return () => {
      version++;
      window.removeEventListener(QUEUE_EVENT, reload);
      window.removeEventListener('focus', reload);
    };
  }, [userId]);
  return state?.userId === userId && state ? state : { items: [], error: false, loading: Boolean(userId) };
}
