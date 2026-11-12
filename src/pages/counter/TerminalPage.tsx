import { useEffect, useRef, useState } from 'react';
import clsx from 'clsx';
import { CheckCircle2, ClipboardCheck, Hand, Link2, LogOut, PackageCheck, PenLine, ScanFace, ScanLine, ShieldCheck, UserRound, Wifi, WifiOff, XCircle } from 'lucide-react';
import { toast } from 'sonner';
import { useAuth } from '@/contexts/AuthContext';
import { useCounterSession } from '@/hooks/useCounterSession';
import { useOnlineStatus } from '@/hooks/useOnlineStatus';
import {
  counterConfirm,
  counterPair,
  counterRegisterAttempt,
  counterRequestCancel,
  counterRequestManual,
  counterRequestStatus,
  counterTerminalWarehouses,
  faceConfirmationAvailable,
  faceIdentify,
  faceVerifyConfirmation,
  getFaceConfig,
  uploadPhoto,
  uploadSignature,
  type CounterSnapshot,
} from '@/lib/api';
import { FaceScanner } from '@/components/FaceScanner';
import { PhotoCapture } from '@/components/PhotoCapture';
import { activeConfirmationMethod, counterSignaturePath } from '@/lib/confirmation';
import { errorMessage } from '@/lib/errors';
import { fmtDateTime, fmtQty, fmtTime } from '@/lib/format';
import { playFeedback } from '@/lib/scanFeedback';
import { dataUrlToBlob } from '@/lib/signature';
import { SignaturePad } from '@/components/SignaturePad';
import { Button } from '@/components/ui/Button';
import { Alert } from '@/components/ui/Card';
import { Modal } from '@/components/ui/Modal';
import { PageLoader } from '@/components/ui/Spinner';

/**
 * Tablet do solicitante (perfil Terminal), em tela cheia.
 * Acompanha em tempo real a ME pareada e coleta a confirmação no final.
 */
export function TerminalPage() {
  const { userId, displayName, signOut } = useAuth();
  const online = useOnlineStatus();
  const { snapshot, loading, error, live, refresh } = useCounterSession({ mode: 'terminal', userId });
  // depois de confirmada/cancelada, a ME some do tablet após 20 s (ou ao tocar em "Conectar a outra separação")
  const [dismissed, setDismissed] = useState<string | null>(null);
  const [switching, setSwitching] = useState(false);
  const [, tick] = useState(0);
  useEffect(() => {
    const t = setInterval(() => tick((n) => n + 1), 5000);
    return () => clearInterval(t);
  }, []);
  const ended = snapshot && (snapshot.session.status === 'confirmada' || snapshot.session.status === 'cancelada');
  const hide =
    !snapshot ||
    (ended && (dismissed === snapshot.session.id || Date.now() - new Date(snapshot.session.last_event_at).getTime() > 20000));

  // som quando a separação termina ou um item entra
  const prev = useRef<{ status?: string; items?: number }>({});
  useEffect(() => {
    if (!snapshot) return;
    const p = prev.current;
    if (p.items !== undefined && snapshot.items.length > p.items) playFeedback('info');
    if (p.status === 'em_separacao' && snapshot.session.status === 'aguardando_confirmacao') playFeedback('ok');
    prev.current = { status: snapshot.session.status, items: snapshot.items.length };
  }, [snapshot]);

  return (
    <div className="flex min-h-screen flex-col bg-slate-50">
      <header className="flex items-center justify-between bg-brand-900 px-4 py-3 text-white">
        <div>
          <p className="font-semibold">Balcão do almoxarifado</p>
          <p className="text-xs text-brand-200">{displayName || 'Terminal do solicitante'}</p>
        </div>
        <div className="flex items-center gap-3">
          <span className={clsx('inline-flex items-center gap-1 text-xs', live && online ? 'text-emerald-300' : 'text-amber-300')}>
            {live && online ? <Wifi className="h-4 w-4" /> : <WifiOff className="h-4 w-4" />}
            {live && online ? 'Ao vivo' : 'Reconectando…'}
          </span>
          {!hide && (
            <button type="button" className="rounded-lg px-3 py-2 text-xs font-semibold text-brand-100 ring-1 ring-white/30 hover:bg-white/10" onClick={() => setSwitching((v) => !v)}>
              {switching ? 'Voltar à separação' : 'Trocar separação'}
            </button>
          )}
          <button type="button" className="rounded-lg p-2 text-brand-100 hover:bg-white/10" title="Sair" onClick={() => void signOut()}>
            <LogOut className="h-5 w-5" />
          </button>
        </div>
      </header>
      <main className="mx-auto w-full max-w-4xl flex-1 p-4 sm:p-6">
        {loading && !snapshot ? (
          <PageLoader label="Conectando…" />
        ) : hide || !snapshot || switching ? (
          <Pairing
            onPaired={() => {
              setSwitching(false);
              void refresh();
            }}
            error={error}
          />
        ) : (
          <Session snapshot={snapshot} onChanged={() => void refresh()} onDismiss={() => setDismissed(snapshot.session.id)} />
        )}
      </main>
    </div>
  );
}

function Pairing({ onPaired, error }: { onPaired: () => void; error: string | null }) {
  const [code, setCode] = useState('');
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const submit = async () => {
    if (!/^\d{6}$/.test(code) || busy) {
      setErr('Digite os 6 números mostrados na tela do almoxarife.');
      return;
    }
    setBusy(true);
    setErr(null);
    try {
      await counterPair(code);
      playFeedback('ok');
      setCode('');
      onPaired();
    } catch (e) {
      playFeedback('error');
      setErr(errorMessage(e));
    } finally {
      setBusy(false);
    }
  };
  return (
    <div className="mx-auto mt-6 max-w-md space-y-5 text-center">
      <RetirarPecas onAttended={onPaired} />
      <Link2 className="mx-auto h-14 w-14 text-brand-600" />
      <div>
        <h1 className="text-2xl font-bold text-slate-900">Conectar a uma separação</h1>
        <p className="mt-1 text-slate-600">Digite o código de 6 números que aparece na tela do almoxarife.</p>
      </div>
      <input
        inputMode="numeric"
        autoComplete="one-time-code"
        maxLength={6}
        value={code}
        onChange={(e) => setCode(e.target.value.replace(/\D/g, '').slice(0, 6))}
        onKeyDown={(e) => {
          if (e.key === 'Enter') void submit();
        }}
        aria-label="Código de pareamento"
        className="w-full rounded-2xl border-2 border-brand-300 bg-white py-4 text-center font-mono text-5xl font-black tracking-[0.4em] outline-none focus:border-brand-600"
        placeholder="••••••"
      />
      {(err || error) && <Alert tone="error">{err ?? error}</Alert>}
      <Button size="lg" block onClick={() => void submit()} loading={busy} disabled={code.length !== 6}>
        Conectar
      </Button>
      <p className="text-xs text-slate-500">Depois de conectado, as próximas separações deste balcão podem aparecer aqui automaticamente.</p>
    </div>
  );
}

const FAIL_TEXT: Record<string, string> = {
  nao_reconhecido: 'Não reconheci o seu rosto.',
  ambiguo: 'Não tive certeza de quem é. Vamos tentar de novo.',
  sem_prova_de_vida: 'Não percebi o movimento do rosto. Vire o rosto devagar quando pedir.',
};

/** "Retirar peças": o solicitante se identifica pelo rosto e o almoxarife já vê quem é. */
function RetirarPecas({ onAttended }: { onAttended: () => void }) {
  const [warehouses, setWarehouses] = useState<{ id: string; name: string }[]>([]);
  const [enabled, setEnabled] = useState(false);
  const [whId, setWhId] = useState<string>('');
  const [state, setState] = useState<
    | { k: 'idle' }
    | { k: 'scan' }
    | { k: 'checking' }
    | { k: 'fail'; reason: string; tries: number }
    | { k: 'wait'; requestId: string; name: string | null }
  >({ k: 'idle' });
  const [tries, setTries] = useState(0);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    // relê a cada 30 s: o administrador pode ligar/desligar com o tablet aberto
    const load = () => {
      getFaceConfig()
        .then((c) => setEnabled(Boolean(c?.enabled)))
        .catch(() => undefined);
      counterTerminalWarehouses()
        .then((w) => w.length && setWarehouses(w))
        .catch(() => undefined);
    };
    load();
    const t = setInterval(load, 30000);
    return () => clearInterval(t);
  }, []);
  useEffect(() => {
    if (!whId && warehouses.length) setWhId(warehouses[0].id);
  }, [warehouses, whId]);

  // aguardando o almoxarife: quando ele abrir a ME, a separação aparece sozinha neste tablet
  const waitId = state.k === 'wait' ? state.requestId : null;
  useEffect(() => {
    if (!waitId) return;
    const t = setInterval(async () => {
      const st = await counterRequestStatus(waitId).catch(() => null);
      if (!st) return;
      if (st.status === 'atendido') {
        clearInterval(t);
        setState({ k: 'idle' });
        setTries(0);
        onAttended();
      } else if (st.status === 'expirado' || st.status === 'cancelado') {
        clearInterval(t);
        setState({ k: 'idle' });
        setErr(st.status === 'expirado' ? 'O pedido expirou. Toque em Retirar peças de novo.' : 'O pedido foi cancelado.');
      }
    }, 3000);
    return () => clearInterval(t);
  }, [waitId, onAttended]);

  if (!enabled || !whId) return null;

  const callStorekeeper = async (reason: string) => {
    setErr(null);
    try {
      const id = await counterRequestManual(whId, reason);
      playFeedback('info');
      setState({ k: 'wait', requestId: id, name: null });
    } catch (e) {
      setErr(errorMessage(e));
    }
  };

  if (state.k === 'wait') {
    return (
      <div className="space-y-3 rounded-2xl bg-emerald-50 p-6 ring-1 ring-emerald-200">
        <UserRound className="mx-auto h-12 w-12 text-emerald-700" />
        {state.name ? (
          <p className="text-2xl font-bold text-emerald-900">Olá, {state.name.split(' ')[0]}!</p>
        ) : (
          <p className="text-2xl font-bold text-emerald-900">O almoxarife foi avisado</p>
        )}
        <p className="text-emerald-800">
          {state.name ? 'O almoxarife já está vendo o seu pedido. Diga o que precisa e acompanhe os itens aqui.' : 'Ele vai te identificar pela matrícula. Aguarde no balcão.'}
        </p>
        <Button
          variant="secondary"
          onClick={() => {
            void counterRequestCancel(state.requestId).catch(() => undefined);
            setState({ k: 'idle' });
          }}
        >
          Cancelar pedido
        </Button>
      </div>
    );
  }

  return (
    <div className="space-y-3 border-b border-slate-200 pb-6">
      {warehouses.length > 1 && (
        <select className="rounded-lg border-slate-300 text-sm" value={whId} onChange={(e) => setWhId(e.target.value)} aria-label="Estoque">
          {warehouses.map((w) => (
            <option key={w.id} value={w.id}>
              {w.name}
            </option>
          ))}
        </select>
      )}
      {state.k === 'idle' && (
        <Button size="xl" block variant="success" icon={<ScanFace className="h-8 w-8" />} className="py-10 text-2xl" onClick={() => (setErr(null), setState({ k: 'scan' }))}>
          RETIRAR PEÇAS
        </Button>
      )}
      {(state.k === 'scan' || state.k === 'checking') && (
        <div className="space-y-3">
          <FaceScanner
            samplesNeeded={3}
            timeoutMs={20000}
            onUnavailable={(r) => setErr(`${r} Toque em “Chamar o almoxarife”.`)}
            onResult={async (r) => {
              setState({ k: 'checking' });
              try {
                const res = await faceIdentify(whId, r.descriptor, r.liveness);
                if (res.ok) {
                  playFeedback('ok');
                  setState({ k: 'wait', requestId: res.request_id, name: res.employee.full_name });
                } else {
                  playFeedback('error');
                  const n = tries + 1;
                  setTries(n);
                  setState({ k: 'fail', reason: res.reason, tries: n });
                }
              } catch (e) {
                setErr(errorMessage(e));
                setState({ k: 'idle' });
              }
            }}
          />
          {state.k === 'checking' && <p className="text-slate-600">Conferindo…</p>}
          <div className="flex justify-center gap-2">
            <Button variant="secondary" onClick={() => setState({ k: 'idle' })}>
              Voltar
            </Button>
            <Button variant="secondary" icon={<Hand className="h-4 w-4" />} onClick={() => void callStorekeeper('Solicitante pediu atendimento sem o rosto')}>
              Chamar o almoxarife
            </Button>
          </div>
        </div>
      )}
      {state.k === 'fail' && (
        <div className="space-y-3">
          <Alert tone="warning" title={FAIL_TEXT[state.reason] ?? 'Não reconheci o seu rosto.'}>
            {state.tries >= 3 ? 'Depois de 3 tentativas, chame o almoxarife: ele te identifica pela matrícula e você confirma com foto e assinatura.' : `Tentativa ${state.tries} de 3.`}
          </Alert>
          <div className="flex flex-wrap justify-center gap-2">
            {state.tries < 3 && (
              <Button icon={<ScanFace className="h-4 w-4" />} onClick={() => setState({ k: 'scan' })}>
                Tentar de novo
              </Button>
            )}
            <Button variant={state.tries >= 3 ? 'primary' : 'secondary'} icon={<Hand className="h-4 w-4" />} onClick={() => void callStorekeeper(`${state.tries} tentativa(s) sem reconhecer (${state.reason})`)}>
              Chamar o almoxarife
            </Button>
          </div>
        </div>
      )}
      {err && <Alert tone="error">{err}</Alert>}
      <p className="text-sm text-slate-500">Ou, se o almoxarife já abriu a separação:</p>
    </div>
  );
}

function Session({ snapshot, onChanged, onDismiss }: { snapshot: CounterSnapshot; onChanged: () => void; onDismiss: () => void }) {
  const m = snapshot.movement;
  const s = snapshot.session;
  const items = snapshot.items;
  const total = items.reduce((a, i) => a + Number(i.quantity_delivered), 0);
  const [summaryOpen, setSummaryOpen] = useState(false);
  const [confirmOpen, setConfirmOpen] = useState(false);
  const waiting = s.status === 'aguardando_confirmacao';
  const done = s.status === 'confirmada';

  // fecha telas de confirmação se o almoxarife reabrir a separação
  useEffect(() => {
    if (!waiting) {
      setSummaryOpen(false);
      setConfirmOpen(false);
    }
  }, [waiting]);

  return (
    <div className="space-y-4">
      <div className="rounded-2xl bg-white p-4 shadow-sm ring-1 ring-slate-200">
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div>
            <p className="text-xs font-semibold uppercase text-slate-500">ME</p>
            <p className="font-mono text-2xl font-bold text-brand-900">{m.me_number}</p>
            <p className="text-slate-700">
              <strong>{m.requester_name}</strong> · matrícula {m.requester_registration}
            </p>
            <p className="text-sm text-slate-500">
              {m.warehouse_name} · almoxarife {m.storekeeper_name}
            </p>
          </div>
          <StatusPill status={s.status} />
        </div>
      </div>

      {done && (
        <div className="rounded-2xl bg-emerald-600 p-6 text-center text-white">
          <CheckCircle2 className="mx-auto h-14 w-14" />
          <p className="mt-2 text-2xl font-bold">ME confirmada</p>
          <p className="text-emerald-100">Confirmada em {fmtDateTime(m.confirmed_at)}. Obrigado!</p>
          <button type="button" onClick={onDismiss} className="mt-3 text-sm font-semibold text-white underline">
            Conectar a outra separação
          </button>
        </div>
      )}
      {s.status === 'cancelada' && (
        <Alert tone="error" title="Esta separação foi cancelada pelo almoxarifado">
          {m.cancel_reason}
          <button type="button" onClick={onDismiss} className="ml-2 font-semibold underline">
            Conectar a outra separação
          </button>
        </Alert>
      )}

      <div className="rounded-2xl bg-white shadow-sm ring-1 ring-slate-200">
        <div className="flex items-center justify-between border-b border-slate-100 px-4 py-3">
          <p className="font-semibold text-slate-900">Materiais entregues</p>
          <p className="text-slate-700">
            <strong>{items.length}</strong> item(ns) · <strong>{fmtQty(total)}</strong> unidade(s)
          </p>
        </div>
        {items.length === 0 ? (
          <div className="px-4 py-12 text-center text-slate-500">
            <ScanLine className="mx-auto mb-2 h-10 w-10 text-slate-300" />
            Aguardando o almoxarife bipar os materiais…
          </div>
        ) : (
          <ul className="divide-y divide-slate-100">
            {[...items].reverse().map((i, idx) => (
              <li key={i.id} className={clsx('flex items-center gap-3 px-4 py-3', idx === 0 && s.status === 'em_separacao' && 'bg-emerald-50')}>
                <div className="min-w-0 flex-1">
                  <p className="text-lg font-semibold leading-tight text-slate-900">{i.material_name}</p>
                  <p className="font-mono text-xs text-slate-500">
                    {i.material_code} · incluído às {fmtTime(i.created_at)}
                  </p>
                </div>
                <p className="whitespace-nowrap text-2xl font-bold text-brand-900">
                  {fmtQty(i.quantity_delivered)} <span className="text-base font-medium text-slate-500">{i.unit}</span>
                </p>
              </li>
            ))}
          </ul>
        )}
      </div>

      {waiting && (
        <Button size="lg" block variant="success" icon={<ClipboardCheck className="h-6 w-6" />} className="py-5 text-xl" onClick={() => setSummaryOpen(true)}>
          CONFIRMAR ME
        </Button>
      )}
      {s.status === 'em_separacao' && (
        <p className="text-center text-sm text-slate-500">O botão CONFIRMAR ME aparece quando o almoxarife finalizar a separação.</p>
      )}

      {/* Resumo para conferência */}
      <Modal
        open={summaryOpen}
        onClose={() => setSummaryOpen(false)}
        size="lg"
        title="Confira a sua retirada"
        description={`${m.me_number} · ${m.requester_name}`}
        footer={
          <>
            <Button variant="secondary" onClick={() => setSummaryOpen(false)}>
              Voltar
            </Button>
            <Button
              variant="success"
              icon={<ShieldCheck className="h-4 w-4" />}
              onClick={() => {
                setSummaryOpen(false);
                setConfirmOpen(true);
              }}
            >
              Está correto, confirmar
            </Button>
          </>
        }
      >
        <table className="w-full text-sm">
          <thead className="text-left text-xs uppercase text-slate-500">
            <tr>
              <th className="py-1">Código</th>
              <th className="py-1">Material</th>
              <th className="py-1 text-right">Quantidade</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-slate-100">
            {items.map((i) => (
              <tr key={i.id}>
                <td className="py-2 font-mono text-xs">{i.material_code}</td>
                <td className="py-2">{i.material_name}</td>
                <td className="whitespace-nowrap py-2 text-right font-semibold">
                  {fmtQty(i.quantity_delivered)} {i.unit}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
        <p className="mt-3 text-sm text-slate-600">
          Total: {items.length} item(ns), {fmtQty(total)} unidade(s). Se algo estiver errado, avise o almoxarife antes de confirmar.
        </p>
      </Modal>

      <ConfirmStep open={confirmOpen} snapshot={snapshot} onClose={() => setConfirmOpen(false)} onDone={onChanged} />
    </div>
  );
}

/**
 * Etapa de validação do solicitante: 1) foto pela câmera frontal; 2) assinatura.
 * O facial (quando definido o fornecedor) entra aqui sem mudar o resto.
 */
function ConfirmStep({ open, snapshot, onClose, onDone }: { open: boolean; snapshot: CounterSnapshot; onClose: () => void; onDone: () => void }) {
  const { settings } = useAuth();
  const method = activeConfirmationMethod();
  const exporter = useRef<() => string | null>(() => null);
  const [phase, setPhase] = useState<'carregando' | 'rosto' | 'foto' | 'assinatura'>('carregando');
  const [faceRun, setFaceRun] = useState(0);
  const [faceMsg, setFaceMsg] = useState<string | null>(null);
  const [photo, setPhoto] = useState<Blob | null>(null);
  const [noCamera, setNoCamera] = useState<string | null>(null);
  const [empty, setEmpty] = useState(true);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const m = snapshot.movement;

  useEffect(() => {
    if (open) {
      setErr(null);
      setEmpty(true);
      setPhase('carregando');
      setFaceMsg(null);
      setPhoto(null);
      setNoCamera(null);
      // com rosto cadastrado e reconhecimento ligado, confirma pelo rosto (sem assinatura e sem foto)
      faceConfirmationAvailable(m.id)
        .then((a) => setPhase(a.available ? 'rosto' : 'foto'))
        .catch(() => setPhase('foto'));
    }
  }, [open, m.id]);

  const confirmByFace = async (descriptor: number[], liveness: boolean) => {
    if (busy) return;
    setBusy(true);
    setErr(null);
    setFaceMsg(null);
    try {
      const v = await faceVerifyConfirmation(m.id, descriptor, liveness);
      if (!v.ok) {
        playFeedback('error');
        if (v.remaining <= 0) {
          setFaceMsg('Não foi possível confirmar pelo rosto. Confirme com foto e assinatura.');
          setPhase('foto');
        } else {
          setFaceMsg(
            `${v.reason === 'sem_prova_de_vida' ? 'Não percebi o movimento do rosto.' : 'O rosto não conferiu com o solicitante desta ME.'} Restam ${v.remaining} tentativa(s).`,
          );
        }
        return;
      }
      await counterConfirm(m.id, { method: 'facial', verification_id: v.verification_id });
      playFeedback('ok');
      toast.success('ME confirmada pelo rosto.');
      onClose();
      onDone();
    } catch (e) {
      playFeedback('error');
      setErr(`${errorMessage(e)} A ME continua aguardando confirmação.`);
    } finally {
      setBusy(false);
    }
  };

  const cancel = () => {
    if (busy) return;
    void counterRegisterAttempt(m.id, method.id, 'cancelada', { etapa: phase }).catch(() => undefined);
    onClose();
  };

  const confirm = async () => {
    if (busy) return;
    const dataUrl = exporter.current();
    if (!dataUrl) {
      setErr('A assinatura está vazia ou muito pequena. Assine na área indicada.');
      return;
    }
    setBusy(true);
    setErr(null);
    try {
      const tz = settings?.timezone ?? 'America/Recife';
      let photoPath: string | null = null;
      if (photo) {
        photoPath = counterSignaturePath(m.warehouse_code, m.id, m.movement_at, tz).replace('assinatura_balcao_', 'foto_solicitante_').replace(/\.png$/, '.jpg');
        await uploadPhoto(photoPath, photo);
      }
      const path = counterSignaturePath(m.warehouse_code, m.id, m.movement_at, tz);
      await uploadSignature(path, dataUrlToBlob(dataUrl));
      await counterConfirm(m.id, {
        method: 'assinatura',
        signature_path: path,
        photo_path: photoPath,
        photo_skipped_reason: photoPath ? null : noCamera ?? 'Câmera indisponível',
      });
      playFeedback('ok');
      toast.success('ME confirmada.');
      onClose();
      onDone();
    } catch (e) {
      playFeedback('error');
      setErr(`${errorMessage(e)} A ME continua aguardando confirmação: tente novamente.`);
      void counterRegisterAttempt(m.id, method.id, 'erro', { mensagem: errorMessage(e) }).catch(() => undefined);
    } finally {
      setBusy(false);
    }
  };

  return (
    <Modal
      open={open}
      onClose={cancel}
      busy={busy}
      size="lg"
      title={
        phase === 'rosto' || phase === 'carregando'
          ? 'Confirme a retirada com o seu rosto'
          : phase === 'foto'
            ? '1 de 2 · Foto do solicitante'
            : '2 de 2 · Assine para confirmar a retirada'
      }
      description={`${m.me_number} · ${m.requester_name} (${m.requester_registration}) · ${fmtDateTime(new Date())}`}
      footer={
        phase === 'rosto' || phase === 'carregando' ? (
          <>
            <Button variant="secondary" icon={<XCircle className="h-4 w-4" />} onClick={cancel}>
              Cancelar
            </Button>
            <Button variant="secondary" icon={<PenLine className="h-4 w-4" />} disabled={busy} onClick={() => setPhase('foto')}>
              Confirmar com foto e assinatura
            </Button>
          </>
        ) : phase === 'foto' ? (
          <>
            <Button variant="secondary" icon={<XCircle className="h-4 w-4" />} onClick={cancel}>
              Cancelar
            </Button>
            {noCamera && !photo ? (
              <Button variant="secondary" onClick={() => setPhase('assinatura')}>
                Continuar sem foto
              </Button>
            ) : (
              <Button icon={<PenLine className="h-4 w-4" />} disabled={!photo} onClick={() => setPhase('assinatura')}>
                Usar esta foto
              </Button>
            )}
          </>
        ) : (
          <>
            <Button variant="secondary" onClick={() => setPhase('foto')} disabled={busy}>
              Voltar à foto
            </Button>
            <Button variant="success" icon={<ShieldCheck className="h-4 w-4" />} onClick={() => void confirm()} loading={busy} disabled={empty}>
              Confirmar ME
            </Button>
          </>
        )
      }
    >
      {phase === 'carregando' ? (
        <p className="py-10 text-center text-slate-500">Preparando…</p>
      ) : phase === 'rosto' ? (
        <div className="space-y-3">
          <p className="text-center text-sm text-slate-600">Olhe para a câmera e, quando pedir, vire o rosto devagar. Nenhuma foto é guardada.</p>
          <FaceScanner key={faceRun} samplesNeeded={2} timeoutMs={20000} onResult={(r) => void confirmByFace(r.descriptor, r.liveness)} onUnavailable={() => setPhase('foto')} />
          {busy && <p className="text-center text-slate-600">Conferindo…</p>}
          {faceMsg && (
            <div className="space-y-2 text-center">
              <Alert tone="warning">{faceMsg}</Alert>
              <Button icon={<ScanFace className="h-4 w-4" />} onClick={() => (setFaceMsg(null), setFaceRun((n) => n + 1))}>
                Tentar de novo
              </Button>
            </div>
          )}
        </div>
      ) : phase === 'foto' ? (
        <div>
          {faceMsg && (
            <div className="mb-3">
              <Alert tone="warning">{faceMsg}</Alert>
            </div>
          )}
          <p className="mb-3 text-sm text-slate-600">
            Posicione o rosto no centro e toque em <strong>Tirar foto</strong>. A foto fica registrada na ME como comprovante da retirada e só a
            gestão tem acesso.
          </p>
          <PhotoCapture onCapture={(b) => setPhoto(b)} onCameraUnavailable={(r) => setNoCamera(r)} />
          {noCamera && !photo && (
            <p className="mt-3 text-center text-sm text-amber-700">Sem câmera, a confirmação segue só com a assinatura e o motivo fica registrado.</p>
          )}
        </div>
      ) : (
        <>
          <SignaturePad
            onChange={(isEmpty) => {
              setEmpty(isEmpty);
              setErr(null);
            }}
            registerExporter={(fn) => {
              exporter.current = fn;
            }}
          />
          {!photo && <p className="mt-2 text-sm text-amber-700">Sem foto: {noCamera ?? 'câmera indisponível'}.</p>}
        </>
      )}
      {err && (
        <div className="mt-3">
          <Alert tone="error">{err}</Alert>
        </div>
      )}
    </Modal>
  );
}

function StatusPill({ status }: { status: CounterSnapshot['session']['status'] }) {
  const map = {
    em_separacao: { label: 'Em separação', cls: 'bg-sky-100 text-sky-800', icon: <ScanLine className="h-5 w-5" /> },
    aguardando_confirmacao: { label: 'Aguardando sua confirmação', cls: 'bg-amber-100 text-amber-900', icon: <PackageCheck className="h-5 w-5" /> },
    confirmada: { label: 'ME confirmada', cls: 'bg-emerald-100 text-emerald-800', icon: <CheckCircle2 className="h-5 w-5" /> },
    cancelada: { label: 'Cancelada', cls: 'bg-red-100 text-red-800', icon: <XCircle className="h-5 w-5" /> },
  }[status];
  return <span className={clsx('inline-flex items-center gap-2 rounded-full px-4 py-2 text-sm font-bold', map.cls)}>{map.icon}{map.label}</span>;
}
