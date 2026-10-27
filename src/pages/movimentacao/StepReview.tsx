import { useRef, useState } from 'react';
import { ArrowLeft, CheckCircle2, Pencil, RefreshCw } from 'lucide-react';
import { toast } from 'sonner';
import { Button } from '@/components/ui/Button';
import { Alert, Card, KeyValue } from '@/components/ui/Card';
import { useAuth } from '@/contexts/AuthContext';
import { useWarehouse } from '@/contexts/WarehouseContext';
import { useLookups } from '@/hooks/useLookups';
import { useOnlineStatus } from '@/hooks/useOnlineStatus';
import { createMovement, uploadSignature, withRetry } from '@/lib/api';
import { toPayloadItems, validateCart } from '@/lib/cart';
import { errorMessage, isNetworkError } from '@/lib/errors';
import { fmtDateTime } from '@/lib/format';
import { buildSignaturePath, dataUrlToBlob } from '@/lib/signature';
import { movementDetailsSchema, firstError } from '@/lib/validation';
import type { CreatedInfo, StepProps } from './NewMovementPage';
import { CartList } from './CartList';

type Phase = 'idle' | 'upload' | 'save';

export function StepReview({ draft, update, goTo, back, rules, onCreated }: StepProps & { onCreated: (c: CreatedInfo) => void }) {
  const { settings } = useAuth();
  const { options } = useWarehouse();
  const online = useOnlineStatus();
  const { data } = useLookups(['contracts', 'sectors', 'service_fronts', 'application_locations']);
  const [phase, setPhase] = useState<Phase>('idle');
  const [error, setError] = useState<string | null>(null);
  const lock = useRef(false);

  const warehouse = options.find((w) => w.id === draft.warehouse_id);
  const d = draft.details;
  const name = (list: { id: string; name: string; code?: string }[] | undefined, id?: string) => list?.find((x) => x.id === id)?.name ?? null;

  const problems = [
    ...(warehouse ? [] : ['Estoque de origem não selecionado ou não autorizado.']),
    ...validateCart(draft.cart, rules),
    ...(firstError(movementDetailsSchema.safeParse({ ...d, warehouse_id: draft.warehouse_id })) ? ['Dados da movimentação incompletos.'] : []),
    ...(draft.requester ? [] : ['Requisitante não identificado.']),
    ...(draft.signature_data_url ? [] : ['Assinatura não coletada.']),
  ];

  const submit = async () => {
    // Proteção contra duplo clique: trava síncrona + botão desabilitado
    if (lock.current || problems.length || !warehouse) return;
    lock.current = true;
    setError(null);
    let path = draft.signature_path;
    try {
      // 1) Upload da assinatura (uma vez; reaproveita em novas tentativas)
      if (!path) {
        setPhase('upload');
        path = buildSignaturePath(warehouse.code, draft.id, settings?.timezone);
        const blob = dataUrlToBlob(draft.signature_data_url as string);
        await withRetry(() => uploadSignature(path as string, blob));
        update({ signature_path: path });
      }

      // 2) Gravação transacional da ME (idempotente pelo id)
      setPhase('save');
      const payload = {
        id: draft.id,
        warehouse_id: draft.warehouse_id,
        contract_id: d.contract_id,
        sector_id: d.sector_id,
        service_front_id: d.service_front_id || null,
        service_order_text: d.service_order_text || null,
        fixed_asset_text: d.fixed_asset_text || null,
        application_location_id: d.application_location_id || null,
        application_location_text: d.application_location_id ? null : d.application_location_text || null,
        notes: d.notes || null,
        requester_employee_id: draft.requester?.id,
        received_by_employee_id: (draft.receiver ?? draft.requester)?.id,
        items: toPayloadItems(draft.cart),
        signature: { storage_path: path, signed_at: draft.signature_signed_at },
        source: draft.source,
      };

      let result;
      try {
        result = await withRetry(() => createMovement(payload));
      } catch (err) {
        // Virada de ano ou arquivo ausente: reenvia a assinatura em novo caminho e tenta uma vez
        if (/Caminho da assinatura inválido|não encontrado no armazenamento/i.test(errorMessage(err))) {
          setPhase('upload');
          path = buildSignaturePath(warehouse.code, draft.id, settings?.timezone);
          await withRetry(() => uploadSignature(path as string, dataUrlToBlob(draft.signature_data_url as string)));
          update({ signature_path: path });
          setPhase('save');
          result = await withRetry(() => createMovement({ ...payload, signature: { ...payload.signature, storage_path: path } }));
        } else {
          throw err;
        }
      }

      toast.success(`ME ${result.me_number} gerada com sucesso.`);
      onCreated({ id: result.id, me_number: result.me_number, status: result.status, warehouse_name: warehouse.name });
    } catch (err) {
      const msg = errorMessage(err);
      setError(
        isNetworkError(err)
          ? 'A conexão falhou antes da confirmação do servidor. A ME ainda NÃO foi confirmada. Seus dados e a assinatura foram mantidos — toque em "Tentar novamente". Não há risco de duplicidade.'
          : msg,
      );
    } finally {
      setPhase('idle');
      lock.current = false;
    }
  };

  const busy = phase !== 'idle';
  const signer = draft.receiver ?? draft.requester;

  return (
    <div className="space-y-4">
      <Card>
        <div className="mb-4 flex items-start justify-between gap-3">
          <div>
            <h2 className="text-lg font-semibold text-slate-900">Revisão</h2>
            <p className="text-sm text-slate-500">Confira tudo antes de gerar a ME. Depois de confirmada, os dados ficam bloqueados.</p>
          </div>
        </div>

        <section className="space-y-3">
          <div className="flex items-center justify-between">
            <h3 className="font-semibold text-slate-800">Cabeçalho</h3>
            <button type="button" className="inline-flex items-center gap-1 text-sm font-medium text-brand-700" onClick={() => goTo(2)} disabled={busy}>
              <Pencil className="h-4 w-4" /> Editar
            </button>
          </div>
          <dl className="grid grid-cols-2 gap-3 sm:grid-cols-3">
            <KeyValue label="Tipo" value="Saída" />
            <KeyValue label="Estoque de origem" value={warehouse?.name} />
            <KeyValue label="Contrato" value={name(data.contracts, d.contract_id)} />
            <KeyValue label="Setor" value={name(data.sectors, d.sector_id)} />
            <KeyValue label="Frente / equipamento" value={name(data.service_fronts, d.service_front_id)} />
            <KeyValue label="Ordem de serviço" value={d.service_order_text} />
            <KeyValue label="Ativo fixo" value={d.fixed_asset_text} />
            <KeyValue label="Local de aplicação" value={name(data.application_locations, d.application_location_id) ?? d.application_location_text} />
            <KeyValue label="Observações" value={d.notes} className="col-span-2 sm:col-span-3" />
          </dl>
        </section>

        <hr className="my-5 border-slate-100" />

        <section className="space-y-3">
          <div className="flex items-center justify-between">
            <h3 className="font-semibold text-slate-800">Responsáveis</h3>
            <button type="button" className="inline-flex items-center gap-1 text-sm font-medium text-brand-700" onClick={() => goTo(3)} disabled={busy}>
              <Pencil className="h-4 w-4" /> Editar
            </button>
          </div>
          <dl className="grid grid-cols-2 gap-3 sm:grid-cols-3">
            <KeyValue label="Requisitante" value={draft.requester ? `${draft.requester.full_name} (${draft.requester.registration})` : null} />
            <KeyValue label="Recebido por" value={signer ? `${signer.full_name} (${signer.registration})` : null} />
            <KeyValue label="Assinado em" value={fmtDateTime(draft.signature_signed_at)} />
          </dl>
          {draft.signature_data_url && (
            <div className="rounded-lg border border-slate-200 bg-white p-2">
              <img src={draft.signature_data_url} alt="Assinatura" className="mx-auto max-h-32" />
            </div>
          )}
        </section>

        <hr className="my-5 border-slate-100" />

        <section>
          <div className="mb-3 flex items-center justify-between">
            <h3 className="font-semibold text-slate-800">Materiais</h3>
            <button type="button" className="inline-flex items-center gap-1 text-sm font-medium text-brand-700" onClick={() => goTo(1)} disabled={busy}>
              <Pencil className="h-4 w-4" /> Editar
            </button>
          </div>
          <CartList cart={draft.cart} setCart={() => undefined} rules={rules} readOnly />
        </section>
      </Card>

      {problems.length > 0 && (
        <Alert tone="warning" title="Antes de confirmar, resolva:">
          <ul className="list-disc pl-5">
            {problems.map((p) => (
              <li key={p}>{p}</li>
            ))}
          </ul>
        </Alert>
      )}
      {settings?.require_approval && <Alert tone="info">Após a confirmação, a ME ficará aguardando aprovação do gestor.</Alert>}
      {!online && <Alert tone="error">Sem conexão. Aguarde a internet voltar para confirmar.</Alert>}
      {error && <Alert tone="error" title="ME não confirmada">{error}</Alert>}

      <div className="sticky bottom-20 z-10 flex gap-3 lg:bottom-4">
        <Button variant="secondary" size="lg" icon={<ArrowLeft className="h-5 w-5" />} onClick={back} disabled={busy}>
          Voltar
        </Button>
        <Button
          size="xl"
          variant="success"
          block
          loading={busy}
          disabled={problems.length > 0 || !online}
          icon={error ? <RefreshCw className="h-5 w-5" /> : <CheckCircle2 className="h-6 w-6" />}
          onClick={() => void submit()}
        >
          {phase === 'upload' ? 'Enviando assinatura…' : phase === 'save' ? 'Gerando ME…' : error ? 'Tentar novamente' : 'Confirmar e gerar ME'}
        </Button>
      </div>
    </div>
  );
}
