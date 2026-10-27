import { useCallback, useEffect, useMemo, useState } from 'react';
import { Link, useNavigate, useParams, useSearchParams } from 'react-router-dom';
import { toast } from 'sonner';
import {
  ArrowLeft,
  Ban,
  CheckCheck,
  Copy,
  FileSignature,
  Hourglass,
  PenLine,
  Printer,
  ShieldCheck,
  Wrench,
} from 'lucide-react';
import { useAuth } from '@/contexts/AuthContext';
import { InformSaModal } from '@/components/InformSaModal';
import { JustificationModal } from '@/components/JustificationModal';
import { Button } from '@/components/ui/Button';
import { Badge, StatusBadge } from '@/components/ui/Badge';
import { Alert, Card, CardHeader, EmptyState, KeyValue, PageHeader } from '@/components/ui/Card';
import { PageLoader, Spinner } from '@/components/ui/Spinner';
import {
  approveMovement,
  cancelMovement,
  completeMovement,
  getMaterialsByIds,
  getMovementAudit,
  getMovementDetail,
  getSignatureUrl,
  listProfiles,
  logEvent,
  type MovementDetail,
} from '@/lib/api';
import { emptyDraft, stashDuplicate } from '@/lib/draft';
import { errorMessage } from '@/lib/errors';
import { fmtDateTime, fmtQty } from '@/lib/format';
import { useRealtimeMovements } from '@/hooks/useRealtimeMovements';
import type { AuditLog, CartItem, Employee, SignatureRecord } from '@/types/db';
import { MovementPrint } from './MovementPrint';
import { MovementTimeline } from './MovementTimeline';
import { CorrectionModal } from './CorrectionModal';
import { ReplaceSignatureModal } from './ReplaceSignatureModal';

function SignatureCard({ sig, autoload, onUrl }: { sig: SignatureRecord; autoload: boolean; onUrl?: (u: string) => void }) {
  const [url, setUrl] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const u = await getSignatureUrl(sig.storage_path);
      setUrl(u);
      onUrl?.(u);
      void logEvent('me.assinatura_consultada', sig.movement_id, { assinatura: sig.id });
    } catch (err) {
      setError(errorMessage(err));
    } finally {
      setLoading(false);
    }
  }, [sig, onUrl]);

  useEffect(() => {
    if (autoload) void load();
  }, [autoload, load]);

  return (
    <div className={sig.is_current ? '' : 'opacity-70'}>
      <div className="flex min-h-[120px] items-center justify-center rounded-lg border border-slate-200 bg-white p-2">
        {url ? (
          <img src={url} alt={`Assinatura de ${sig.signer_name}`} className="max-h-40" />
        ) : loading ? (
          <Spinner className="h-6 w-6 text-brand-600" />
        ) : error ? (
          <p className="text-sm text-red-600">{error}</p>
        ) : (
          <Button variant="secondary" icon={<FileSignature className="h-4 w-4" />} onClick={() => void load()}>
            Ver assinatura
          </Button>
        )}
      </div>
      <p className="mt-2 text-sm text-slate-800">
        {sig.signer_name} <span className="text-slate-500">({sig.signer_registration})</span>
        {!sig.is_current && <Badge className="ml-2 bg-slate-100 text-slate-600 ring-slate-300">Substituída</Badge>}
      </p>
      <p className="text-xs text-slate-500">
        Assinada em {fmtDateTime(sig.signed_at)} · arquivo enviado em {fmtDateTime(sig.uploaded_at)}
      </p>
      {sig.replacement_reason && <p className="text-xs text-slate-600">Motivo da substituição: {sig.replacement_reason} ({fmtDateTime(sig.replaced_at)})</p>}
    </div>
  );
}

export function MovementDetailPage() {
  const { id = '' } = useParams();
  const [params, setParams] = useSearchParams();
  const navigate = useNavigate();
  const { can, settings, warehouses } = useAuth();
  const [detail, setDetail] = useState<MovementDetail | null>(null);
  const [audit, setAudit] = useState<AuditLog[]>([]);
  const [names, setNames] = useState<Record<string, string>>({});
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [tab, setTab] = useState<'itens' | 'historico'>('itens');
  const [modal, setModal] = useState<null | 'sa' | 'cancel' | 'approve' | 'correct' | 'signature'>(null);
  const [busy, setBusy] = useState(false);
  const [printSigUrl, setPrintSigUrl] = useState<string | null>(null);
  const wantsPrint = params.get('imprimir') === '1';
  const auditAllowed = can('viewAudit');

  const load = useCallback(async () => {
    try {
      const d = await getMovementDetail(id);
      setDetail(d);
      setError(null);
      if (d && auditAllowed) setAudit(await getMovementAudit(id));
    } catch (err) {
      setError(errorMessage(err));
    } finally {
      setLoading(false);
    }
  }, [id, auditAllowed]);

  useEffect(() => {
    void load();
    listProfiles()
      .then((p) => setNames(Object.fromEntries(p.map((x) => [x.id, x.full_name]))))
      .catch(() => undefined);
  }, [load]);

  useRealtimeMovements(() => void load());

  const currentSig = useMemo(() => detail?.signatures.find((s) => s.is_current) ?? null, [detail]);

  // Impressão automática (?imprimir=1): espera a assinatura carregar
  useEffect(() => {
    if (!wantsPrint || !detail) return;
    if (currentSig && !printSigUrl) return;
    const t = setTimeout(() => {
      void logEvent('me.impressa', detail.movement.id);
      window.print();
      const p = new URLSearchParams(params);
      p.delete('imprimir');
      setParams(p, { replace: true });
    }, 700);
    return () => clearTimeout(t);
  }, [wantsPrint, detail, currentSig, printSigUrl, params, setParams]);

  if (loading) return <PageLoader />;
  if (error) return <Alert tone="error">{error}</Alert>;
  if (!detail) {
    return (
      <EmptyState
        title="ME não encontrada"
        description="Ela não existe ou pertence a um estoque que você não tem permissão para consultar."
        action={
          <Link to="/movimentacoes" className="font-medium text-brand-700 hover:underline">
            Voltar para movimentações
          </Link>
        }
      />
    );
  }

  const m = detail.movement;
  const isCancelled = m.status === 'cancelada';

  const runAction = async (fn: () => Promise<unknown>, success: string) => {
    if (busy) return;
    setBusy(true);
    try {
      await fn();
      toast.success(success);
      setModal(null);
      await load();
    } catch (err) {
      toast.error(errorMessage(err));
    } finally {
      setBusy(false);
    }
  };

  const duplicate = async () => {
    try {
      const mats = await getMaterialsByIds(detail.items.map((i) => i.material_id));
      const byId = new Map(mats.map((x) => [x.id, x]));
      const inactive = detail.items.filter((i) => !byId.get(i.material_id)?.active);
      const cart: CartItem[] = detail.items
        .filter((i) => byId.get(i.material_id)?.active)
        .map((i, idx) => ({
          key: `dup-${idx}-${Date.now()}`,
          material: byId.get(i.material_id)!,
          quantity_requested: Number(i.quantity_requested),
          quantity_delivered: Number(i.quantity_delivered),
          entry_method: 'pesquisa_manual',
          scanned_code: null,
          notes: '',
        }));
      const draft = emptyDraft(warehouses.some((w) => w.id === m.warehouse_id) ? m.warehouse_id : '');
      draft.cart = cart;
      draft.step = 1;
      draft.source = `duplicada:${m.me_number}`;
      draft.details = {
        warehouse_id: draft.warehouse_id,
        contract_id: m.contract_id,
        sector_id: m.sector_id,
        service_front_id: m.service_front_id ?? '',
        service_order_text: m.service_order ?? '',
        fixed_asset_text: m.fixed_asset ?? '',
        application_location_id: m.application_location_id ?? '',
        application_location_text: m.application_location_id ? '' : (m.application_location ?? ''),
        notes: '',
      };
      draft.requester = {
        id: m.requester_employee_id,
        full_name: m.requester_name,
        registration: m.requester_registration,
        job_title: null,
        sector_id: null,
        active: true,
      } as Employee;
      stashDuplicate(draft);
      if (inactive.length) toast.warning(`${inactive.length} material(is) inativo(s) não foram copiados.`);
      navigate('/nova-saida');
    } catch (err) {
      toast.error(errorMessage(err));
    }
  };

  return (
    <>
      <div className="print:hidden">
        <PageHeader
          back={
            <button type="button" onClick={() => navigate(-1)} className="mb-2 inline-flex items-center gap-1 text-sm text-slate-500 hover:text-slate-800">
              <ArrowLeft className="h-4 w-4" /> Voltar
            </button>
          }
          title={<span className="font-mono">{m.me_number}</span>}
          subtitle={
            <span className="flex flex-wrap items-center gap-2">
              <StatusBadge status={m.status} /> Saída · {m.warehouse_name} · {fmtDateTime(m.movement_at)}
              {m.is_demo && <Badge className="bg-purple-50 text-purple-700 ring-purple-200">Dado fictício</Badge>}
            </span>
          }
          actions={
            <>
              {m.status === 'aguardando_aprovacao' && can('approveMovement') && (
                <Button icon={<ShieldCheck className="h-4 w-4" />} onClick={() => setModal('approve')}>
                  Aprovar
                </Button>
              )}
              {can('informSa') && (m.status === 'aguardando_sa' || m.status === 'sa_informada' || (m.status === 'concluida' && can('correctSaAfterCompletion'))) && (
                <Button variant={m.status === 'aguardando_sa' ? 'warning' : 'secondary'} icon={<Hourglass className="h-4 w-4" />} onClick={() => setModal('sa')}>
                  {m.status === 'aguardando_sa' ? 'Informar SA' : 'Corrigir SA'}
                </Button>
              )}
              {m.status === 'sa_informada' && can('completeMovement') && (
                <Button variant="success" icon={<CheckCheck className="h-4 w-4" />} loading={busy} onClick={() => void runAction(() => completeMovement(m.id), 'ME concluída.')}>
                  Concluir
                </Button>
              )}
              <Button variant="secondary" icon={<Printer className="h-4 w-4" />} onClick={() => setParams({ imprimir: '1' })}>
                Imprimir / PDF
              </Button>
              {can('createMovement') && (
                <Button variant="secondary" icon={<Copy className="h-4 w-4" />} onClick={() => void duplicate()} title="Cria uma NOVA saída com os mesmos dados; exige nova assinatura">
                  Duplicar
                </Button>
              )}
              {!isCancelled && can('correctMovement') && (
                <Button variant="secondary" icon={<Wrench className="h-4 w-4" />} onClick={() => setModal('correct')}>
                  Corrigir
                </Button>
              )}
              {!isCancelled && can('cancelMovement') && (
                <Button variant="danger" icon={<Ban className="h-4 w-4" />} onClick={() => setModal('cancel')}>
                  Cancelar ME
                </Button>
              )}
            </>
          }
        />

        {isCancelled && (
          <div className="mb-4">
            <Alert tone="error" title={`ME cancelada em ${fmtDateTime(m.cancelled_at)} por ${m.cancelled_by_name ?? '—'}`}>
              Motivo: {m.cancel_reason}
            </Alert>
          </div>
        )}

        <div className="grid gap-4 lg:grid-cols-3">
          <Card className="lg:col-span-2">
            <CardHeader title="Dados da movimentação" />
            <dl className="grid grid-cols-2 gap-x-4 gap-y-4 sm:grid-cols-3">
              <KeyValue label="Estoque de origem" value={`${m.warehouse_name} (${m.warehouse_code})`} />
              <KeyValue label="Data" value={fmtDateTime(m.movement_at)} />
              <KeyValue label="Contrato" value={`${m.contract_code} – ${m.contract_name}`} />
              <KeyValue label="Setor" value={m.sector_name} />
              <KeyValue label="Frente / equipamento" value={m.service_front_name} />
              <KeyValue label="Ordem de serviço" value={m.service_order} />
              <KeyValue label="Ativo fixo" value={m.fixed_asset} />
              <KeyValue label="Local de aplicação" value={m.application_location} />
              <KeyValue label="Itens / total atendido" value={`${m.item_count} itens · ${fmtQty(m.total_delivered)}`} />
              <KeyValue label="Observações" value={m.notes} className="col-span-2 sm:col-span-3" />
            </dl>
          </Card>

          <Card>
            <CardHeader title="SA (ERP)" />
            <dl className="space-y-3">
              <KeyValue label="Número da SA" value={m.sa_number ? <span className="font-mono text-base font-semibold">{m.sa_number}</span> : <span className="text-orange-700">Pendente</span>} />
              <KeyValue label="Informada por" value={m.sa_informed_by_name} />
              <KeyValue label="Informada em" value={m.sa_informed_at ? fmtDateTime(m.sa_informed_at) : null} />
              <KeyValue label="Concluída em" value={m.completed_at ? `${fmtDateTime(m.completed_at)} · ${m.completed_by_name ?? ''}` : null} />
            </dl>
          </Card>

          <Card className="lg:col-span-2">
            <CardHeader title="Responsáveis" />
            <dl className="grid grid-cols-2 gap-x-4 gap-y-4 sm:grid-cols-3">
              <KeyValue label="Requisitante" value={`${m.requester_name} (${m.requester_registration})`} />
              <KeyValue label="Requisição em" value={fmtDateTime(m.requested_at)} />
              <KeyValue label="Almoxarife responsável" value={m.storekeeper_name} />
              <KeyValue label="Recebido por" value={m.received_by_name ? `${m.received_by_name} (${m.received_by_registration})` : null} />
              <KeyValue label="Recebido em" value={fmtDateTime(m.received_at)} />
              <KeyValue label="Aprovado por" value={m.approved_by_name ? `${m.approved_by_name} · ${fmtDateTime(m.approved_at)}` : settings?.require_approval ? 'Pendente' : 'Não exigido'} />
              <KeyValue label="Última alteração" value={`${fmtDateTime(m.updated_at)}${m.updated_by_name ? ` · ${m.updated_by_name}` : ''}`} />
            </dl>
          </Card>

          <Card>
            <CardHeader
              title="Assinatura"
              actions={
                !isCancelled && can('replaceSignature') ? (
                  <Button size="sm" variant="ghost" icon={<PenLine className="h-4 w-4" />} onClick={() => setModal('signature')}>
                    Nova
                  </Button>
                ) : undefined
              }
            />
            {detail.signatures.length === 0 ? (
              <p className="text-sm text-slate-500">Sem assinatura registrada.</p>
            ) : (
              <div className="space-y-5">
                {[...detail.signatures]
                  .sort((a, b) => Number(b.is_current) - Number(a.is_current))
                  .map((s) => (
                    <SignatureCard key={s.id} sig={s} autoload={s.is_current && wantsPrint} onUrl={s.is_current ? setPrintSigUrl : undefined} />
                  ))}
              </div>
            )}
          </Card>
        </div>

        <div className="mt-6">
          <div className="mb-3 inline-flex rounded-xl bg-slate-100 p-1">
            {(
              [
                ['itens', `Materiais (${detail.items.length})`],
                ['historico', 'Histórico e auditoria'],
              ] as const
            ).map(([k, label]) => (
              <button
                key={k}
                type="button"
                onClick={() => setTab(k)}
                className={`rounded-lg px-4 py-2 text-sm font-semibold ${tab === k ? 'bg-white text-brand-800 shadow' : 'text-slate-600'}`}
              >
                {label}
              </button>
            ))}
          </div>

          {tab === 'itens' ? (
            <Card padded={false}>
              <div className="overflow-x-auto">
                <table className="min-w-full divide-y divide-slate-200 text-sm">
                  <thead className="bg-slate-50 text-xs font-semibold uppercase tracking-wide text-slate-500">
                    <tr>
                      <th className="px-3 py-2.5 text-left">Item</th>
                      <th className="px-3 py-2.5 text-left">Código</th>
                      <th className="px-3 py-2.5 text-left">Referência</th>
                      <th className="px-3 py-2.5 text-left">Material</th>
                      <th className="px-3 py-2.5 text-left">Unid.</th>
                      <th className="px-3 py-2.5 text-right">Qtd. sol.</th>
                      <th className="px-3 py-2.5 text-right">Qtd. atd.</th>
                      <th className="px-3 py-2.5 text-left">Localiz.</th>
                      <th className="px-3 py-2.5 text-left">Conta</th>
                      <th className="px-3 py-2.5 text-left">Inclusão</th>
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-slate-100">
                    {detail.items.map((i) => {
                      const short = Number(i.quantity_delivered) < Number(i.quantity_requested);
                      return (
                        <tr key={i.id}>
                          <td className="px-3 py-2.5">{i.line_number}</td>
                          <td className="whitespace-nowrap px-3 py-2.5 font-mono text-xs">{i.material_code}</td>
                          <td className="px-3 py-2.5">{i.material_reference ?? '—'}</td>
                          <td className="px-3 py-2.5">
                            {i.material_name}
                            {i.notes && <span className="block text-xs text-slate-500">Obs.: {i.notes}</span>}
                          </td>
                          <td className="px-3 py-2.5">{i.unit}</td>
                          <td className="px-3 py-2.5 text-right tabular-nums">{fmtQty(i.quantity_requested)}</td>
                          <td className={`px-3 py-2.5 text-right font-semibold tabular-nums ${short ? 'text-orange-700' : ''}`}>{fmtQty(i.quantity_delivered)}</td>
                          <td className="px-3 py-2.5">{i.location ?? '—'}</td>
                          <td className="px-3 py-2.5 text-xs">{i.account_code ? `${i.account_code} – ${i.account_name ?? ''}` : '—'}</td>
                          <td className="px-3 py-2.5 text-xs text-slate-500">{i.entry_method === 'qr_code' ? 'QR Code' : 'Pesquisa'}</td>
                        </tr>
                      );
                    })}
                  </tbody>
                </table>
              </div>
            </Card>
          ) : (
            <Card>
              <MovementTimeline history={detail.history} saRecords={detail.saRecords} audit={audit} auditAllowed={auditAllowed} names={names} />
            </Card>
          )}
        </div>
      </div>

      <div className="hidden print:block">
        <MovementPrint detail={detail} signatureUrl={printSigUrl} companyName={settings?.company_name ?? ''} />
      </div>

      <InformSaModal movement={modal === 'sa' ? m : null} onClose={() => setModal(null)} onDone={() => void load()} />
      <JustificationModal
        open={modal === 'cancel'}
        title={`Cancelar ${m.me_number}?`}
        description="O cancelamento é lógico: materiais, assinatura, SA e histórico são preservados."
        confirmLabel="Cancelar ME"
        tone="danger"
        busy={busy}
        onClose={() => setModal(null)}
        onConfirm={(j) => runAction(() => cancelMovement(m.id, j), `${m.me_number} cancelada.`)}
      />
      <JustificationModal
        open={modal === 'approve'}
        title={`Aprovar ${m.me_number}?`}
        description="Após aprovar, a ME segue para lançamento da SA."
        confirmLabel="Aprovar"
        required={false}
        busy={busy}
        onClose={() => setModal(null)}
        onConfirm={(j) => runAction(() => approveMovement(m.id, j || undefined), 'ME aprovada.')}
      />
      <CorrectionModal open={modal === 'correct'} detail={detail} onClose={() => setModal(null)} onDone={() => void load()} />
      <ReplaceSignatureModal open={modal === 'signature'} detail={detail} onClose={() => setModal(null)} onDone={() => void load()} />
    </>
  );
}
