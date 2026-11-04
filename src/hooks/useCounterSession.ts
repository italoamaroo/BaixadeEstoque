import { useCallback, useEffect, useRef, useState } from 'react';
import { supabase } from '@/lib/supabase';
import { counterSnapshot, type CounterSnapshot } from '@/lib/api';
import { errorMessage } from '@/lib/errors';

/**
 * Mantém a "fotografia" da separação sincronizada nas duas telas do balcão.
 * O banco é a fonte da verdade: cada mudança incrementa counter_sessions.version e o
 * Supabase Realtime avisa as telas, que recarregam a fotografia pela função counter_snapshot.
 * Também recarrega ao reconectar, ao voltar para a aba e, por garantia, a cada 20 s.
 *
 * mode 'movement': almoxarife/gestor acompanhando uma ME específica.
 * mode 'terminal': tablet pareado (a ME é descoberta pelo próprio banco).
 */
export function useCounterSession(
  opts: { mode: 'movement'; movementId: string | null } | { mode: 'terminal'; userId: string | null },
) {
  const [snapshot, setSnapshot] = useState<CounterSnapshot | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [live, setLive] = useState(false);
  const seq = useRef(0);
  const key = opts.mode === 'movement' ? opts.movementId : opts.userId;

  const refresh = useCallback(async () => {
    if (!key) {
      setSnapshot(null);
      setLoading(false);
      return;
    }
    const my = ++seq.current;
    try {
      const snap = await counterSnapshot(opts.mode === 'movement' ? key : null);
      if (my !== seq.current) return; // resposta antiga: descarta
      setSnapshot(snap);
      setError(null);
    } catch (e) {
      if (my !== seq.current) return;
      setError(errorMessage(e));
    } finally {
      if (my === seq.current) setLoading(false);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key, opts.mode]);

  useEffect(() => {
    setLoading(true);
    void refresh();
  }, [refresh]);

  useEffect(() => {
    if (!key) return;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const schedule = () => {
      clearTimeout(timer);
      timer = setTimeout(() => void refresh(), 120);
    };
    const filter = opts.mode === 'movement' ? `movement_id=eq.${key}` : `terminal_user_id=eq.${key}`;
    const channel = supabase
      .channel(`balcao-${opts.mode}-${key}-${Math.random().toString(36).slice(2, 8)}`)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'counter_sessions', filter }, schedule)
      .subscribe((status) => {
        setLive(status === 'SUBSCRIBED');
        if (status === 'SUBSCRIBED') schedule();
      });
    const onVisible = () => {
      if (document.visibilityState === 'visible') schedule();
    };
    const onOnline = () => schedule();
    document.addEventListener('visibilitychange', onVisible);
    window.addEventListener('online', onOnline);
    return () => {
      clearTimeout(timer);
      document.removeEventListener('visibilitychange', onVisible);
      window.removeEventListener('online', onOnline);
      void supabase.removeChannel(channel);
    };
  }, [key, opts.mode, refresh]);

  // garantia: sem tempo real (rede bloqueando WebSocket, por exemplo) consulta a cada 3 s; com tempo real, a cada 20 s
  useEffect(() => {
    if (!key) return;
    const poll = setInterval(() => void refresh(), live ? 20000 : 3000);
    return () => clearInterval(poll);
  }, [key, live, refresh]);

  return { snapshot, setSnapshot, loading, error, live, refresh };
}
