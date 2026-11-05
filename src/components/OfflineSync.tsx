import { useCallback, useEffect, useRef } from 'react';
import { Link } from 'react-router-dom';
import { CloudOff, CloudUpload } from 'lucide-react';
import { toast } from 'sonner';
import { useAuth } from '@/contexts/AuthContext';
import { useOfflineQueue } from '@/hooks/useOfflineQueue';
import { useOnlineStatus } from '@/hooks/useOnlineStatus';
import { refreshOfflineCache } from '@/lib/offlineCache';
import { syncQueue } from '@/lib/offlineQueue';
import { fmtDateTime } from '@/lib/format';

/**
 * Roda em segundo plano para quem registra saídas:
 * - mantém a cópia dos cadastros no aparelho (para o modo offline);
 * - envia as saídas guardadas assim que a internet volta (e a cada 30 s);
 * - mostra uma faixa com quantas saídas aguardam envio.
 */
export function OfflineSync() {
  const { userId, settings, can } = useAuth();
  const online = useOnlineStatus();
  const { items } = useOfflineQueue();
  const enabled = Boolean(userId) && can('createMovement');
  const running = useRef(false);

  const run = useCallback(async () => {
    if (!enabled || !userId || running.current || !navigator.onLine) return;
    running.current = true;
    try {
      const r = await syncQueue(userId, settings?.timezone);
      for (const s of r.sent) {
        toast.success(`Saída registrada sem internet enviada: ${s.me_number}`, {
          description: `Retirada de ${fmtDateTime(s.offline_at)}.`,
          duration: 8000,
        });
      }
      if (r.failed.length) {
        toast.error(`${r.failed.length} saída(s) guardada(s) não puderam ser enviadas. Veja em "Saídas offline".`, { duration: 10000 });
      }
    } finally {
      running.current = false;
    }
  }, [enabled, userId, settings?.timezone]);

  // cópia dos cadastros (a cada 6 h, com internet)
  useEffect(() => {
    if (enabled && online) void refreshOfflineCache().catch(() => undefined);
  }, [enabled, online]);

  // envio automático
  useEffect(() => {
    if (!enabled) return;
    if (online) void run();
    const t = setInterval(() => void run(), 30000);
    return () => clearInterval(t);
  }, [enabled, online, run, items.length]);

  if (!enabled || items.length === 0) return null;
  const errors = items.filter((i) => i.status === 'erro').length;
  return (
    <Link
      to="/saidas-offline"
      className={
        'flex items-center justify-center gap-2 px-4 py-2 text-sm font-semibold print:hidden ' +
        (errors ? 'bg-red-600 text-white' : online ? 'bg-sky-600 text-white' : 'bg-amber-500 text-amber-950')
      }
    >
      {online ? <CloudUpload className="h-4 w-4" /> : <CloudOff className="h-4 w-4" />}
      {items.length} saída(s) guardada(s) no aparelho
      {errors ? ` · ${errors} com erro` : online ? ' · enviando…' : ' · serão enviadas quando a internet voltar'}
    </Link>
  );
}
