import { useEffect, useRef } from 'react';
import { supabase } from '@/lib/supabase';

/**
 * Assina alterações em stock_movements (Supabase Realtime, respeitando RLS).
 * O callback é agrupado para evitar recargas em rajada.
 */
export function useRealtimeMovements(onChange: () => void, enabled = true) {
  const cb = useRef(onChange);
  cb.current = onChange;

  useEffect(() => {
    if (!enabled) return;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const channel = supabase
      .channel(`movements-${Math.random().toString(36).slice(2)}`)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'stock_movements' }, () => {
        clearTimeout(timer);
        timer = setTimeout(() => cb.current(), 600);
      })
      .subscribe();
    return () => {
      clearTimeout(timer);
      void supabase.removeChannel(channel);
    };
  }, [enabled]);
}
