import { useEffect, useRef, useState } from 'react';
import { ArrowLeft, ArrowRight, PenLine, RotateCcw } from 'lucide-react';
import { toast } from 'sonner';
import { SignaturePad } from '@/components/SignaturePad';
import { Button } from '@/components/ui/Button';
import { Alert, Card, KeyValue } from '@/components/ui/Card';
import { useWarehouse } from '@/contexts/WarehouseContext';
import { cartTotals } from '@/lib/cart';
import { fmtDateTime, fmtQty } from '@/lib/format';
import type { StepProps } from './NewMovementPage';

export function StepSignature({ draft, update, next, back }: StepProps) {
  const { options } = useWarehouse();
  const exporter = useRef<() => string | null>(() => null);
  const [empty, setEmpty] = useState(true);
  const [now, setNow] = useState(new Date());
  const [error, setError] = useState<string | null>(null);
  const signer = draft.receiver ?? draft.requester;
  const warehouse = options.find((w) => w.id === draft.warehouse_id);
  const totals = cartTotals(draft.cart);

  useEffect(() => {
    const t = setInterval(() => setNow(new Date()), 30_000);
    return () => clearInterval(t);
  }, []);

  if (!signer) {
    return (
      <Alert tone="warning" title="Requisitante não identificado">
        Volte e identifique o funcionário antes de colher a assinatura.
      </Alert>
    );
  }

  const confirm = () => {
    const dataUrl = exporter.current();
    if (!dataUrl) {
      setError('A assinatura está vazia ou muito pequena. Peça ao funcionário para assinar na área indicada.');
      return;
    }
    update({ signature_data_url: dataUrl, signature_signed_at: new Date().toISOString(), signature_path: null });
    toast.success('Assinatura confirmada.');
    next();
  };

  return (
    <div className="space-y-4">
      <Card>
        <h2 className="text-lg font-semibold text-slate-900">Assinatura de recebimento</h2>
        <p className="mb-4 text-sm text-slate-500">
          Ao assinar, o funcionário confirma o recebimento de {totals.lines} {totals.lines === 1 ? 'item' : 'itens'} (
          {totals.byUnit.map((u) => `${fmtQty(u.qty)} ${u.unit}`).join(' + ')}).
        </p>
        <dl className="mb-4 grid grid-cols-2 gap-3 rounded-xl bg-slate-50 p-4 sm:grid-cols-3">
          <KeyValue label="Funcionário" value={signer.full_name} className="col-span-2 sm:col-span-1" />
          <KeyValue label="Matrícula" value={signer.registration} />
          <KeyValue label="Data e hora" value={fmtDateTime(now)} />
          <KeyValue label="Identificador da ME" value={<span className="font-mono">{draft.id.slice(0, 8).toUpperCase()}</span>} />
          <KeyValue label="Estoque de origem" value={warehouse?.name} />
          {draft.receiver && <KeyValue label="Requisitante" value={draft.requester?.full_name} />}
        </dl>

        {draft.signature_data_url ? (
          <div className="space-y-3">
            <div className="rounded-xl border border-slate-200 bg-white p-2">
              <img src={draft.signature_data_url} alt={`Assinatura de ${signer.full_name}`} className="mx-auto max-h-56" />
            </div>
            <p className="text-sm text-slate-500">Assinado em {fmtDateTime(draft.signature_signed_at)}.</p>
            <Button
              variant="secondary"
              icon={<RotateCcw className="h-4 w-4" />}
              onClick={() => update({ signature_data_url: null, signature_signed_at: null, signature_path: null })}
            >
              Assinar novamente
            </Button>
          </div>
        ) : (
          <SignaturePad
            onChange={(isEmpty) => {
              setEmpty(isEmpty);
              setError(null);
            }}
            registerExporter={(fn) => {
              exporter.current = fn;
            }}
          />
        )}
        {error && <div className="mt-3"><Alert tone="error">{error}</Alert></div>}
      </Card>

      <div className="sticky bottom-20 z-10 flex gap-3 lg:bottom-4">
        <Button variant="secondary" size="lg" icon={<ArrowLeft className="h-5 w-5" />} onClick={back}>
          Voltar
        </Button>
        {draft.signature_data_url ? (
          <Button size="lg" block icon={<ArrowRight className="h-5 w-5" />} onClick={next}>
            Revisar
          </Button>
        ) : (
          <Button size="lg" block icon={<PenLine className="h-5 w-5" />} onClick={confirm} disabled={empty}>
            Confirmar assinatura
          </Button>
        )}
      </div>
    </div>
  );
}
