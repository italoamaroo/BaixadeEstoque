import { useCallback, useEffect, useState } from 'react';
import { useAuth } from '@/contexts/AuthContext';
import { QUEUE_EVENT, listQueued, type QueuedMovement } from '@/lib/offlineQueue';

/** Saídas guardadas no aparelho do usuário logado, atualizadas a cada mudança da fila. */
export function useOfflineQueue() {
  const { userId } = useAuth();
  const [items, setItems] = useState<QueuedMovement[]>([]);
  const reload = useCallback(async () => {
    setItems(userId ? await listQueued(userId) : []);
  }, [userId]);
  useEffect(() => {
    void reload();
    const h = () => void reload();
    window.addEventListener(QUEUE_EVENT, h);
    return () => window.removeEventListener(QUEUE_EVENT, h);
  }, [reload]);
  return { items, reload };
}
