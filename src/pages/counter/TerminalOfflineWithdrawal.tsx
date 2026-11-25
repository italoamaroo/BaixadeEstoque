import { useCallback, useEffect, useRef, useState } from 'react';
import { CheckCircle2, CloudOff, PackageCheck, Save, ShieldCheck } from 'lucide-react';
import { useAuth } from '@/contexts/AuthContext';
import { useOnlineStatus } from '@/hooks/useOnlineStatus';
import { useOfflineQueue } from '@/hooks/useOfflineQueue';
import { loadTerminalCopy, type AuthorizedTerminalCopy } from '@/lib/terminalOffline';
import { enqueueMovement, syncQueue } from '@/lib/offlineQueue';
import { fmtDateTime, fmtQty } from '@/lib/format';
import { errorMessage } from '@/lib/errors';
import { Button } from '@/components/ui/Button';
import { Alert, Card, CardHeader, EmptyState } from '@/components/ui/Card';
import { SignaturePad } from '@/components/SignaturePad';
import { PhotoCapture } from '@/components/PhotoCapture';

export function TerminalOfflineWithdrawal({ onBack }: { onBack: () => void }) {
  const { userId } = useAuth();
  const online = useOnlineStatus();
  const { items: queued } = useOfflineQueue();
  const [copy, setCopy] = useState<AuthorizedTerminalCopy>();
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [saved, setSaved] = useState(false);
  const [busy, setBusy] = useState(false);
  const [checked, setChecked] = useState(false);
  const [empty, setEmpty] = useState(true);
  const [photo, setPhoto] = useState<string | null>(null);
  const [noCamera, setNoCamera] = useState<string | null>(null);
  const exporter = useRef<() => string | null>(() => null);
  const lock = useRef(false);
  const register = useCallback((fn: () => string | null) => { exporter.current = fn; }, []);
  const unavailable = useCallback((reason: string) => setNoCamera(reason), []);
  const captured = useCallback((_blob: Blob | null, data: string | null) => setPhoto(data), []);
  useEffect(() => {
    let alive = true;
    if (!userId) { setLoading(false); return; }
    loadTerminalCopy(userId).then((v) => { if (alive) { setCopy(v); setLoading(false); } }, () => { if (alive) { setError('Não foi possível ler a lista preparada neste aparelho.'); setLoading(false); } });
    return () => { alive = false; };
  }, [userId]);
  const existing = queued.find((q) => q.kind === 'counter_confirmation' && q.payload.movement_id === copy?.snapshot.movement.id);
  const save = async () => {
    if (!copy || !userId || lock.current) return;
    const signature = exporter.current();
    if (!checked || !signature || (!photo && !noCamera)) { setError('Confira a lista, registre a foto (ou indisponibilidade da câmera) e assine.'); return; }
    lock.current = true; setBusy(true); setError(null);
    try {
      const current = await loadTerminalCopy(userId);
      if (!current || current.request_id !== copy.request_id) throw new Error('A lista autorizada mudou. Reabra esta tela para conferir novamente.');
      const { movement: m, session: s, items } = copy.snapshot;
      const when = new Date().toISOString();
      await enqueueMovement({ id: copy.request_id, kind: 'counter_confirmation', user_id: userId, saved_at: when, offline_at: when,
        warehouse_code: m.warehouse_code, warehouse_name: m.warehouse_name, requester_name: m.requester_name,
        item_count: items.length, items_summary: items.slice(0, 4).map((i) => `${i.material_name} (${fmtQty(i.quantity_delivered)} ${i.unit})`).join(', '),
        signature_data_url: signature, signature_signed_at: when, photo_data_url: photo,
        payload: { movement_id: m.id, movement_at: m.movement_at, me_number: m.me_number, version: s.version, separation_finished_at: m.separation_finished_at,
          items: items.map((i) => ({ id: i.id, quantity_requested: i.quantity_requested, quantity_delivered: i.quantity_delivered })), photo_skipped_reason: photo ? null : noCamera },
      });
      setSaved(true);
      if (navigator.onLine) void syncQueue(userId).catch(() => undefined);
    } catch (e) { setError(errorMessage(e)); } finally { lock.current = false; setBusy(false); }
  };
  if (loading) return <p className="p-6 text-slate-500">Carregando lista autorizada…</p>;
  if (!copy) return <Card><EmptyState icon={<CloudOff className="h-12 w-12" />} title="Nenhuma lista autorizada neste tablet" description="Com internet, o almoxarife precisa parear este tablet, finalizar a separação e aguardar a lista aparecer aqui. Só essa lista poderá ser confirmada sem internet. A atualização 32 do banco também precisa estar aplicada." action={<Button onClick={onBack}>Voltar ao balcão</Button>} />{error && <Alert tone="error">{error}</Alert>}</Card>;
  const { movement: m, items } = copy.snapshot;
  const kind = m.is_rescue ? 'Socorro' : m.is_emergency ? 'Emergencial' : 'Normal';
  if (saved || existing) return <div className="space-y-4"><Card><CheckCircle2 className="mb-3 h-12 w-12 text-emerald-600" /><h1 className="text-xl font-bold">{existing?.status === 'erro' ? 'Confirmação guardada — conferir envio' : 'Confirmação guardada neste tablet'}</h1><p className="mt-2">ME {m.me_number}. A assinatura e as evidências aguardam confirmação do servidor.</p><p className="mt-2 text-sm text-slate-500">A lista não será criada novamente. Quando a conexão voltar, será enviada para esta mesma ME.</p>{existing?.last_error && <div className="mt-3"><Alert tone="error">{existing.last_error}</Alert></div>}<div className="mt-4"><Button onClick={onBack}>Voltar ao balcão</Button></div></Card></div>;
  return <div className="space-y-5">
    <div><h1 className="text-2xl font-bold text-slate-950">Retirada sem internet</h1><p className="mt-1 text-slate-500">Confira os materiais autorizados e registre sua confirmação neste tablet.</p></div>
    <Alert tone={online ? 'info' : 'warning'}>{online ? 'A confirmação será guardada neste aparelho e enviada para a mesma ME.' : 'Sem conexão. A confirmação ficará neste aparelho até a internet voltar.'}</Alert>
    {error && <Alert tone="error">{error}</Alert>}
    <Card><CardHeader title="Dados da retirada" /><div className="grid gap-5 md:grid-cols-2"><div><p className="text-sm text-slate-500">Mecânico / requisitante</p><p className="mt-2 rounded-lg border border-slate-300 p-3 font-semibold">{m.requester_name} · Matrícula {m.requester_registration}</p></div><div><p className="text-sm text-slate-500">Tipo de retirada autorizado</p><div className="mt-2 flex overflow-hidden rounded-lg border border-slate-300">{['Normal', 'Emergencial', 'Socorro'].map((k) => <span key={k} className={`flex-1 px-3 py-3 text-center text-sm ${kind === k ? 'bg-brand-600 font-semibold text-white' : 'bg-slate-50 text-slate-400'}`}>{k}</span>)}</div></div></div>{m.is_rescue && <p className="mt-4 text-sm font-medium text-brand-700">Socorro: após a confirmação, a ME aguardará a conferência do retorno.</p>}</Card>
    <Card><CardHeader title="Materiais da retirada" subtitle="Lista preparada pelo almoxarife. Materiais e quantidades não podem ser alterados no tablet." /><div className="overflow-x-auto"><table className="w-full text-left text-sm"><thead className="bg-slate-50 text-slate-500"><tr><th className="p-3">Material</th><th className="p-3">Unidade</th><th className="p-3 text-right">Quantidade</th></tr></thead><tbody>{items.map((i) => <tr key={i.id} className="border-t border-slate-100"><td className="p-3 font-medium">{i.material_name}<span className="block text-xs font-normal text-slate-400">{i.material_code}</span></td><td className="p-3">{i.unit}</td><td className="p-3 text-right text-lg font-semibold tabular-nums">{fmtQty(i.quantity_delivered)}</td></tr>)}</tbody></table></div></Card>
    <div className="grid items-start gap-5 lg:grid-cols-[1fr_1.5fr]"><Card><CardHeader title="Autorização do almoxarife" /><div className="flex items-center gap-2 rounded-lg border border-emerald-200 bg-emerald-50 p-3 font-semibold text-emerald-800"><ShieldCheck className="h-5 w-5" />Lista autorizada antes da queda</div><p className="mt-3 font-medium">Responsável: {m.storekeeper_name}</p><p className="mt-2 text-sm text-slate-500">Separação finalizada em {fmtDateTime(m.separation_finished_at)}.</p><p className="mt-3 text-xs text-slate-500">Se os materiais recebidos forem diferentes, chame o almoxarife e não confirme esta lista.</p></Card>
      <Card><CardHeader title="Confirmação do mecânico" /><label className="mb-4 flex items-start gap-2 text-sm"><input type="checkbox" className="mt-1 h-4 w-4" checked={checked} onChange={(e) => setChecked(e.target.checked)} />Conferi os materiais e as quantidades recebidas.</label><div className="grid gap-4 sm:grid-cols-[128px_minmax(0,1fr)]"><div><p className="mb-2 text-xs text-slate-500">Foto do mecânico</p><PhotoCapture compact onCapture={captured} onCameraUnavailable={unavailable} /></div><div><p className="mb-2 text-xs text-slate-500">Assinatura do mecânico</p><SignaturePad compact onChange={setEmpty} registerExporter={register} /></div></div></Card></div>
    <div className="sticky bottom-0 flex flex-wrap items-center justify-between gap-3 rounded-xl border border-slate-200 bg-white p-4 shadow-card"><div><p className="font-semibold">ME {m.me_number}</p><p className="text-xs text-slate-500">A ME já existe. Somente a confirmação será sincronizada.</p></div><div className="flex gap-2"><Button variant="secondary" onClick={onBack}>Voltar</Button><Button icon={<Save className="h-5 w-5" />} loading={busy} disabled={empty || !checked || (!photo && !noCamera)} onClick={() => void save()}>Guardar confirmação no tablet</Button></div></div>
  </div>;
}

export function TerminalOfflineQueue() {
  const { userId, settings } = useAuth();
  const online = useOnlineStatus();
  const { items, error } = useOfflineQueue();
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState('');
  const send = async () => {
    if (!userId) return;
    setBusy(true);
    try { const r = await syncQueue(userId, settings?.timezone, true); setMessage(`${r.sent.length} confirmação(ões) enviada(s).${r.stoppedByNetwork ? ' Sem conexão; os dados continuam no aparelho.' : ''}`); }
    catch (e) { setMessage(errorMessage(e)); } finally { setBusy(false); }
  };
  const rows = items.filter((q) => q.kind === 'counter_confirmation');
  return <div className="space-y-4"><div className="flex flex-wrap items-center justify-between gap-3"><h1 className="text-2xl font-bold">Saídas aguardando envio</h1><Button disabled={!online || !rows.length} loading={busy} onClick={() => void send()}>Enviar agora</Button></div><p className="text-sm text-slate-500">Somente confirmações guardadas por esta conta neste tablet. Elas saem da fila após a confirmação do servidor.</p>{message && <Alert>{message}</Alert>}{error && <Alert tone="error">Não foi possível consultar a fila do aparelho.</Alert>}{rows.length === 0 ? <Card><EmptyState icon={<PackageCheck className="h-10 w-10" />} title="Nenhuma confirmação aguardando envio" /></Card> : rows.map((q) => <Card key={q.id}><h2 className="font-semibold">ME {String(q.payload.me_number)} · {q.requester_name}</h2><p className="mt-1 text-sm">{q.items_summary}</p><p className="mt-2 text-xs text-slate-500">Assinada em {fmtDateTime(q.signature_signed_at)} · {q.warehouse_name}</p>{q.last_error && <div className="mt-3"><Alert tone={q.status === 'erro' ? 'error' : 'warning'}>{q.last_error}</Alert></div>}</Card>)}</div>;
}
