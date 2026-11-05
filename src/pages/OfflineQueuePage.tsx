import { useEffect, useState } from 'react';
import { CloudOff, Database, RefreshCw, Send, Trash2 } from 'lucide-react';
import { toast } from 'sonner';
import { useAuth } from '@/contexts/AuthContext';
import { useOfflineQueue } from '@/hooks/useOfflineQueue';
import { useOnlineStatus } from '@/hooks/useOnlineStatus';
import { cacheInfo, refreshOfflineCache, type OfflineCacheInfo } from '@/lib/offlineCache';
import { discardQueued, syncQueue, type QueuedMovement } from '@/lib/offlineQueue';
import { errorMessage } from '@/lib/errors';
import { fmtDateTime, fmtInt } from '@/lib/format';
import { Button } from '@/components/ui/Button';
import { Alert, Card, CardHeader, EmptyState, PageHeader } from '@/components/ui/Card';
import { Modal } from '@/components/ui/Modal';

/** Saídas registradas sem internet, guardadas neste aparelho. */
export function OfflineQueuePage() {
  const { userId, settings } = useAuth();
  const online = useOnlineStatus();
  const { items } = useOfflineQueue();
  const [info, setInfo] = useState<OfflineCacheInfo | undefined>();
  const [busy, setBusy] = useState(false);
  const [updating, setUpdating] = useState(false);
  const [discard, setDiscard] = useState<QueuedMovement | null>(null);

  useEffect(() => {
    void cacheInfo().then(setInfo);
  }, []);

  const sendNow = async () => {
    if (!userId) return;
    setBusy(true);
    try {
      const r = await syncQueue(userId, settings?.timezone, true);
      if (r.sent.length) toast.success(`${r.sent.length} saída(s) enviada(s): ${r.sent.map((s) => s.me_number).join(', ')}`);
      if (r.stoppedByNetwork) toast.error('Sem conexão com o servidor. As saídas continuam guardadas no aparelho.');
      if (r.failed.length) toast.error(`${r.failed.length} saída(s) com erro. Veja o motivo na lista.`);
    } finally {
      setBusy(false);
    }
  };

  const updateCache = async () => {
    setUpdating(true);
    try {
      const i = await refreshOfflineCache(true);
      setInfo(i);
      toast.success('Dados para uso offline atualizados.');
    } catch (e) {
      toast.error(errorMessage(e));
    } finally {
      setUpdating(false);
    }
  };

  return (
    <div className="space-y-4">
      <PageHeader
        title="Saídas offline"
        subtitle="Saídas registradas sem internet neste aparelho. São enviadas sozinhas quando a conexão volta e recebem o número oficial da ME no envio."
        actions={
          <Button icon={<Send className="h-4 w-4" />} onClick={() => void sendNow()} loading={busy} disabled={!online || items.length === 0}>
            Enviar agora
          </Button>
        }
      />
      {!online && (
        <Alert tone="warning" title="Sem internet">
          As saídas ficam guardadas neste aparelho. Não limpe os dados do navegador nem troque de aparelho antes do envio.
        </Alert>
      )}

      <Card padded={false}>
        {items.length === 0 ? (
          <EmptyState title="Nenhuma saída aguardando envio" description="Tudo o que foi registrado neste aparelho já está no servidor." />
        ) : (
          <ul className="divide-y divide-slate-100">
            {items.map((q) => (
              <li key={q.id} className="flex flex-wrap items-start justify-between gap-3 px-4 py-3">
                <div className="min-w-0">
                  <p className="font-semibold text-slate-900">
                    {q.requester_name} · {q.warehouse_name}
                  </p>
                  <p className="text-sm text-slate-600">
                    Retirada em {fmtDateTime(q.offline_at)} · {fmtInt(q.item_count)} item(ns): {q.items_summary}
                  </p>
                  <p className="font-mono text-xs text-slate-400">Identificador provisório {q.id.slice(0, 8).toUpperCase()}</p>
                  {q.status === 'erro' ? (
                    <p className="mt-1 text-sm font-medium text-red-700">Não enviada: {q.last_error}</p>
                  ) : (
                    <p className="mt-1 text-sm text-sky-700">
                      Aguardando envio{q.attempts ? ` · ${q.attempts} tentativa(s), última em ${fmtDateTime(q.last_attempt_at)}` : ''}
                    </p>
                  )}
                </div>
                <Button variant="ghost" size="sm" icon={<Trash2 className="h-4 w-4" />} onClick={() => setDiscard(q)}>
                  Descartar
                </Button>
              </li>
            ))}
          </ul>
        )}
      </Card>

      <Card>
        <CardHeader
          title={
            <span className="flex items-center gap-2">
              <Database className="h-5 w-5 text-slate-500" /> Dados para uso sem internet
            </span>
          }
          subtitle="Cópia dos materiais, funcionários e cadastros guardada neste aparelho. Atualiza sozinha a cada 6 horas com internet."
          actions={
            <Button variant="secondary" icon={<RefreshCw className="h-4 w-4" />} onClick={() => void updateCache()} loading={updating} disabled={!online}>
              Atualizar agora
            </Button>
          }
        />
        {info ? (
          <p className="text-sm text-slate-600">
            Atualizado em <strong>{fmtDateTime(info.updated_at)}</strong>: {fmtInt(info.materials)} materiais e {fmtInt(info.employees)} funcionários.
          </p>
        ) : (
          <p className="flex items-center gap-2 text-sm text-amber-700">
            <CloudOff className="h-4 w-4" /> Ainda não há cópia neste aparelho. Com internet, toque em “Atualizar agora” antes de precisar do modo offline.
          </p>
        )}
      </Card>

      <Modal
        open={Boolean(discard)}
        onClose={() => setDiscard(null)}
        title="Descartar saída guardada?"
        description="Ela será apagada deste aparelho e NÃO será enviada. Use só se ela já foi lançada de outra forma (por exemplo, em papel)."
        footer={
          <>
            <Button variant="secondary" onClick={() => setDiscard(null)}>
              Voltar
            </Button>
            <Button
              variant="danger"
              onClick={async () => {
                if (!discard) return;
                await discardQueued(discard.id);
                toast.success('Saída descartada do aparelho.');
                setDiscard(null);
              }}
            >
              Descartar
            </Button>
          </>
        }
      >
        {discard && (
          <p className="text-sm text-slate-700">
            {discard.requester_name} · retirada em {fmtDateTime(discard.offline_at)} · {discard.items_summary}
          </p>
        )}
      </Modal>
    </div>
  );
}
