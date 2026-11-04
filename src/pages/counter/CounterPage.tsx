import { useCallback, useEffect, useRef, useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import clsx from 'clsx';
import {
  Ban,
  CheckCircle2,
  Hand,
  Lock,
  Plus,
  RefreshCw,
  RotateCcw,
  ScanLine,
  Search,
  Tablet,
  Trash2,
  Unlock,
  Wifi,
  WifiOff,
} from 'lucide-react';
import { toast } from 'sonner';
import { useAuth } from '@/contexts/AuthContext';
import { useWarehouse } from '@/contexts/WarehouseContext';
import { useCounterSession } from '@/hooks/useCounterSession';
import { normalizeScannedCode, useHidScanner } from '@/hooks/useHidScanner';
import { useOnlineStatus } from '@/hooks/useOnlineStatus';
import {
  cancelMovement,
  counterAdd,
  counterFinish,
  counterMyOpen,
  counterNewPairingCode,
  counterRemoveItem,
  counterReopen,
  counterSetQuantity,
  counterListTerminals,
  counterSetTerminal,
  type CounterTerminal,
  type CounterScanResponse,
  type CounterSnapshot,
} from '@/lib/api';
import { errorMessage } from '@/lib/errors';
import { fmtDateTime, fmtQty, fmtTime } from '@/lib/format';
import { playFeedback, type FeedbackKind } from '@/lib/scanFeedback';
import { MaterialSearch } from '@/components/MaterialSearch';
import { JustificationModal } from '@/components/JustificationModal';
import { Modal } from '@/components/ui/Modal';
import { Button } from '@/components/ui/Button';
import { Alert, Card, EmptyState, PageHeader } from '@/components/ui/Card';
import { StatusBadge } from '@/components/ui/Badge';
import { Input, Checkbox } from '@/components/ui/Field';
import { PageLoader, Spinner } from '@/components/ui/Spinner';
import { CounterOpenForm } from './CounterOpenForm';

const ASK_QTY_KEY = 'baixas-estoque:balcao-perguntar-qtd';

interface Feedback {
  kind: FeedbackKind;
  title: string;
  detail?: string;
  at: number;
}

/** Balcão do almoxarife: abre a separação, lista as separações em andamento ou mostra a separação ativa. */
export function CounterPage() {
  const { id } = useParams();
  const navigate = useNavigate();
  if (id) return <ActiveCounter movementId={id} onNew={() => navigate('/balcao')} />;
  return <CounterHome onOpened={(mid) => navigate(`/balcao/${mid}`)} />;
}

function CounterHome({ onOpened }: { onOpened: (id: string) => void }) {
  const [open, setOpen] = useState<Awaited<ReturnType<typeof counterMyOpen>> | null>(null);
  useEffect(() => {
    counterMyOpen()
      .then(setOpen)
      .catch(() => setOpen([]));
  }, []);
  return (
    <div>
      <PageHeader
        title="Balcão de separação"
        subtitle="Bipe os materiais com o leitor sem fio enquanto o solicitante acompanha no tablet. Ao terminar, o solicitante confere e confirma a ME."
      />
      {open && open.length > 0 && (
        <Card className="mb-4">
          <h2 className="mb-2 text-sm font-semibold text-slate-700">Separações em andamento</h2>
          <ul className="divide-y divide-slate-100">
            {open.map((o) => (
              <li key={o.movement_id} className="flex flex-wrap items-center justify-between gap-2 py-2">
                <div>
                  <p className="font-mono text-sm font-semibold text-brand-800">{o.me_number}</p>
                  <p className="text-sm text-slate-600">
                    {o.requester_name} · {o.item_count} item(ns) · {o.warehouse_name} · aberta {fmtDateTime(o.created_at)}
                  </p>
                </div>
                <div className="flex items-center gap-2">
                  <StatusBadge status={o.status} />
                  <Button variant="secondary" onClick={() => onOpened(o.movement_id)}>
                    Retomar
                  </Button>
                </div>
              </li>
            ))}
          </ul>
        </Card>
      )}
      <CounterOpenForm onOpened={onOpened} />
    </div>
  );
}

function ActiveCounter({ movementId, onNew }: { movementId: string; onNew: () => void }) {
  const { userId } = useAuth();
  const online = useOnlineStatus();
  const { snapshot, loading, error, live, refresh } = useCounterSession({ mode: 'movement', movementId });
  const { options: warehouseOptions } = useWarehouse();
  const inputRef = useRef<HTMLInputElement>(null);
  const [feedback, setFeedback] = useState<Feedback | null>(null);
  const [pending, setPending] = useState(0);
  const [duplicate, setDuplicate] = useState<{ code: string; resp: CounterScanResponse; qty: number } | null>(null);
  const [askQty, setAskQty] = useState(() => {
    try {
      return localStorage.getItem(ASK_QTY_KEY) === 'sim';
    } catch {
      return false;
    }
  });
  const [qtyPrompt, setQtyPrompt] = useState<string | null>(null);
  const [nextQty, setNextQty] = useState('1');
  const [manualOpen, setManualOpen] = useState(false);
  const [finishOpen, setFinishOpen] = useState(false);
  const [cancelOpen, setCancelOpen] = useState(false);
  const [busy, setBusy] = useState(false);

  const status = snapshot?.movement.status;
  const separating = status === 'rascunho';
  const scannerEnabled = separating && !duplicate && !qtyPrompt && !manualOpen && !finishOpen && !cancelOpen;

  const notify = useCallback((kind: FeedbackKind, title: string, detail?: string) => {
    setFeedback({ kind, title, detail, at: Date.now() });
    playFeedback(kind);
  }, []);

  const handleResponse = useCallback(
    (r: CounterScanResponse, code: string, qty: number) => {
      const name = r.material_name ? `${r.material_code} – ${r.material_name}` : code;
      switch (r.result) {
        case 'incluido':
          notify('ok', r.repetida ? 'Leitura já registrada' : 'Material incluído', `${name} · ${fmtQty(r.quantity_delivered ?? qty)} ${r.unit ?? ''}`);
          break;
        case 'somado':
          notify('ok', 'Quantidade somada', `${name} · agora ${fmtQty(r.quantity_delivered ?? 0)} ${r.unit ?? ''}`);
          break;
        case 'ja_incluido':
          notify('warn', 'Item já incluído nesta ME', name);
          setDuplicate({ code, resp: r, qty });
          break;
        case 'nao_encontrado':
          notify('error', 'QR Code não encontrado', `Código lido: ${code}. Verifique a etiqueta ou use a pesquisa manual.`);
          break;
        case 'invalido':
          notify('error', 'QR Code inválido', `O conteúdo lido não é um código de material: ${code}`);
          break;
        case 'inativo':
          notify('error', 'Material inativo', `${name} está inativo no cadastro e não pode ser baixado.`);
          break;
        case 'quantidade_invalida':
          notify('error', 'Quantidade inválida', 'Informe uma quantidade maior que zero.');
          break;
      }
      void refresh();
    },
    [notify, refresh],
  );

  const send = useCallback(
    async (input: { code?: string; material_id?: string; label: string }, qty: number, mode: 'avisar' | 'somar' = 'avisar') => {
      setPending((n) => n + 1);
      try {
        const r = await counterAdd({
          movement_id: movementId,
          scan_id: crypto.randomUUID(),
          code: input.code,
          material_id: input.material_id,
          quantity: qty,
          on_duplicate: mode,
        });
        handleResponse(r, input.label, qty);
      } catch (e) {
        notify('error', 'Erro de comunicação', `${errorMessage(e)} A leitura de ${input.label} não foi registrada: bipe novamente.`);
      } finally {
        setPending((n) => n - 1);
      }
    },
    [movementId, handleResponse, notify],
  );

  const parsedNextQty = () => {
    const n = Number(String(nextQty).replace(',', '.'));
    return Number.isFinite(n) && n > 0 ? n : NaN;
  };

  const onScan = useCallback(
    (raw: string) => {
      const code = normalizeScannedCode(raw);
      if (!code) return;
      if (!online) {
        notify('error', 'Sem conexão', 'A leitura não foi registrada. Verifique a internet e bipe novamente.');
        return;
      }
      if (askQty) {
        setQtyPrompt(code);
        return;
      }
      const q = parsedNextQty();
      if (!Number.isFinite(q)) {
        notify('error', 'Quantidade inválida', 'Corrija a quantidade da próxima leitura.');
        return;
      }
      void send({ code, label: code }, q);
      setNextQty('1');
    },
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [askQty, online, send, notify, nextQty],
  );

  const scanner = useHidScanner(inputRef, {
    enabled: scannerEnabled,
    onScan,
    onRepeatIgnored: (c) => notify('info', 'Leitura repetida ignorada', `${c} foi bipado duas vezes seguidas.`),
  });

  // Avisa quando o tablet mudar de status (pareado, confirmação, etc.)
  const lastEvent = useRef<string | null>(null);
  useEffect(() => {
    const ev = snapshot?.session.last_event ?? null;
    if (!snapshot || ev === lastEvent.current) return;
    const first = lastEvent.current === null;
    lastEvent.current = ev;
    if (first) return;
    if (ev === 'terminal_pareado') toast.success('Tablet do solicitante conectado.');
    if (ev === 'confirmacao_cancelada') toast.info('O solicitante cancelou a confirmação no tablet.');
    if (ev === 'me_confirmada') {
      playFeedback('ok');
      toast.success(`${snapshot.movement.me_number} confirmada pelo solicitante.`);
    }
  }, [snapshot]);

  if (loading && !snapshot) return <PageLoader label="Carregando separação…" />;
  if (!snapshot) {
    return (
      <EmptyState
        title="Separação não encontrada"
        description={error ?? 'Ela pode ter sido aberta por outro usuário.'}
        action={<Button onClick={onNew}>Nova separação</Button>}
      />
    );
  }

  const m = snapshot.movement;
  const s = snapshot.session;
  const items = snapshot.items;
  const isOwner = true; // o banco recusa alterações de quem não abriu a separação
  void userId;
  const warehouseId = warehouseOptions.find((w) => w.code === m.warehouse_code)?.id ?? null;
  const totalQty = items.reduce((acc, i) => acc + Number(i.quantity_delivered), 0);

  const run = async (fn: () => Promise<unknown>, ok?: string) => {
    if (busy) return;
    setBusy(true);
    try {
      await fn();
      if (ok) toast.success(ok);
      await refresh();
    } catch (e) {
      toast.error(errorMessage(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="space-y-4">
      <PageHeader
        title={
          <span className="flex flex-wrap items-center gap-3">
            <span className="font-mono">{m.me_number}</span>
            <StatusBadge status={m.status} />
          </span>
        }
        subtitle={`${m.warehouse_name} · Solicitante: ${m.requester_name} (${m.requester_registration})${m.fixed_asset ? ` · Ativo ${m.fixed_asset}` : ' · Sem ativo fixo'}`}
        actions={
          <span className={clsx('inline-flex items-center gap-1 text-xs font-medium', live && online ? 'text-emerald-700' : 'text-amber-700')}>
            {live && online ? <Wifi className="h-4 w-4" /> : <WifiOff className="h-4 w-4" />}
            {live && online ? 'Sincronizado' : 'Reconectando…'}
          </span>
        }
      />

      <TerminalCard
        snapshot={snapshot}
        warehouseId={warehouseId}
        busy={busy}
        onNewCode={() => void run(() => counterNewPairingCode(m.id), 'Novo código gerado.')}
        onChanged={() => void refresh()}
      />

      {separating && (
        <Card>
          <div className="flex flex-wrap items-end gap-3">
            <div className="min-w-[260px] flex-1">
              <label htmlFor="balcao-leitura" className="mb-1 block text-sm font-semibold text-slate-700">
                Leitura do QR Code
              </label>
              <div className="relative">
                <ScanLine className="pointer-events-none absolute left-3 top-1/2 h-6 w-6 -translate-y-1/2 text-brand-600" />
                <input
                  id="balcao-leitura"
                  ref={inputRef}
                  autoComplete="off"
                  autoCorrect="off"
                  spellCheck={false}
                  onKeyDown={scanner.onInputKeyDown}
                  onBlur={scanner.onInputBlur}
                  placeholder="Bipe o material…"
                  className="h-14 w-full rounded-xl border-2 border-brand-300 bg-brand-50/40 pl-12 pr-3 font-mono text-lg outline-none focus:border-brand-600 focus:bg-white"
                />
              </div>
              <ScannerState inputRef={inputRef} pending={pending} />
            </div>
            {!askQty && (
              <div className="w-36">
                <Input
                  label="Qtd. da próxima"
                  inputMode="decimal"
                  value={nextQty}
                  onChange={(e) => setNextQty(e.target.value)}
                  onKeyDown={(e) => {
                    if (e.key === 'Enter') {
                      e.preventDefault();
                      scanner.focus();
                      inputRef.current?.focus();
                    }
                  }}
                  inputSize="lg"
                />
              </div>
            )}
            <Button variant="secondary" size="lg" icon={<Search className="h-5 w-5" />} onClick={() => setManualOpen(true)}>
              Pesquisar
            </Button>
          </div>
          <div className="mt-3">
            <Checkbox
              label="Perguntar a quantidade a cada leitura"
              checked={askQty}
              onChange={(v) => {
                setAskQty(v);
                try {
                  localStorage.setItem(ASK_QTY_KEY, v ? 'sim' : 'nao');
                } catch {
                  /* ignore */
                }
              }}
            />
          </div>
          {feedback && <FeedbackBanner feedback={feedback} />}
        </Card>
      )}

      {m.status === 'aguardando_assinatura' && (
        <Alert tone="warning" title="Separação finalizada: aguardando o solicitante confirmar no tablet">
          Novas leituras estão bloqueadas. Se o solicitante apontar alguma divergência, use “Reabrir separação”.
        </Alert>
      )}
      {m.confirmed_at && (
        <Alert tone="success" title={`ME confirmada pelo solicitante em ${fmtDateTime(m.confirmed_at)}`}>
          A ME seguiu para {m.fixed_asset ? 'a equipe de SA' : 'a baixa no ERP'}. Os itens não podem mais ser alterados.
        </Alert>
      )}
      {m.status === 'cancelada' && <Alert tone="error" title="Separação cancelada">{m.cancel_reason}</Alert>}

      <Card padded={false}>
        <div className="flex items-center justify-between border-b border-slate-100 px-4 py-3">
          <h2 className="font-semibold text-slate-900">Materiais separados</h2>
          <p className="text-sm text-slate-600">
            <strong>{items.length}</strong> item(ns) · <strong>{fmtQty(totalQty)}</strong> unidade(s)
          </p>
        </div>
        {items.length === 0 ? (
          <p className="px-4 py-10 text-center text-sm text-slate-500">Nenhum material ainda. Bipe o primeiro QR Code.</p>
        ) : (
          <div className="overflow-x-auto">
            <table className="min-w-full text-sm">
              <thead className="bg-slate-50 text-left text-xs uppercase text-slate-500">
                <tr>
                  <th className="px-3 py-2">#</th>
                  <th className="px-3 py-2">Código</th>
                  <th className="px-3 py-2">Descrição</th>
                  <th className="px-3 py-2 text-right">Solicitada</th>
                  <th className="px-3 py-2 text-right">Atendida</th>
                  <th className="px-3 py-2">Un.</th>
                  <th className="px-3 py-2">Horário</th>
                  <th className="px-3 py-2" />
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-100">
                {[...items].reverse().map((i) => (
                  <ItemRow
                    key={i.id}
                    item={i}
                    editable={separating && isOwner}
                    highlight={Date.now() - new Date(i.updated_at).getTime() < 4000}
                    onSave={(req, del) =>
                      counterSetQuantity(i.id, req, del)
                        .then(() => {
                          notify('info', 'Quantidade alterada', `${i.material_code} – ${i.material_name}: ${fmtQty(del)} ${i.unit}`);
                          void refresh();
                        })
                        .catch((e) => notify('error', 'Quantidade inválida', errorMessage(e)))
                    }
                    onRemove={() =>
                      counterRemoveItem(i.id)
                        .then(() => {
                          notify('info', 'Item removido', `${i.material_code} – ${i.material_name}`);
                          void refresh();
                        })
                        .catch((e) => notify('error', 'Erro de comunicação', errorMessage(e)))
                    }
                  />
                ))}
              </tbody>
            </table>
          </div>
        )}
      </Card>

      <div className="sticky bottom-20 z-10 flex flex-wrap gap-3 rounded-xl bg-white/90 p-2 backdrop-blur lg:bottom-4">
        {separating && (
          <Button size="lg" variant="success" icon={<Lock className="h-5 w-5" />} disabled={items.length === 0 || pending > 0} onClick={() => setFinishOpen(true)}>
            FINALIZAR SEPARAÇÃO
          </Button>
        )}
        {m.status === 'aguardando_assinatura' && (
          <Button size="lg" variant="secondary" icon={<Unlock className="h-5 w-5" />} loading={busy} onClick={() => void run(() => counterReopen(m.id), 'Separação reaberta.')}>
            Reabrir separação
          </Button>
        )}
        {(separating || m.status === 'aguardando_assinatura') && (
          <Button size="lg" variant="ghost" icon={<Ban className="h-5 w-5" />} onClick={() => setCancelOpen(true)}>
            Cancelar separação
          </Button>
        )}
        {(m.confirmed_at || m.status === 'cancelada') && (
          <>
            <Button size="lg" icon={<Plus className="h-5 w-5" />} onClick={onNew}>
              Nova separação
            </Button>
            <Link to={`/movimentacoes/${m.id}`} className="self-center text-sm font-medium text-brand-700 hover:underline">
              Ver detalhes da ME
            </Link>
          </>
        )}
        <Button size="lg" variant="ghost" icon={<RefreshCw className="h-5 w-5" />} onClick={() => void refresh()}>
          Atualizar
        </Button>
      </div>

      {/* Quantidade a cada leitura */}
      <QtyPrompt
        code={qtyPrompt}
        onCancel={() => {
          setQtyPrompt(null);
          notify('info', 'Leitura descartada');
        }}
        onConfirm={(q) => {
          const code = qtyPrompt!;
          setQtyPrompt(null);
          void send({ code, label: code }, q);
        }}
      />

      {/* Item já incluído */}
      <Modal
        open={Boolean(duplicate)}
        onClose={() => setDuplicate(null)}
        title="Item já incluído nesta ME"
        description={duplicate ? `${duplicate.resp.material_code} – ${duplicate.resp.material_name}` : undefined}
        footer={
          <>
            <Button variant="secondary" onClick={() => setDuplicate(null)}>
              Não somar
            </Button>
            <Button
              autoFocus
              icon={<Plus className="h-4 w-4" />}
              onClick={() => {
                const d = duplicate!;
                setDuplicate(null);
                void send(d.resp.material_id ? { material_id: d.resp.material_id, label: d.code } : { code: d.code, label: d.code }, d.qty, 'somar');
              }}
            >
              Somar +{duplicate ? fmtQty(duplicate.qty) : ''}
            </Button>
          </>
        }
      >
        <p className="text-sm text-slate-600">
          Este material já está na lista com {duplicate ? fmtQty(duplicate.resp.quantity_delivered ?? 0) : ''} {duplicate?.resp.unit}. Deseja somar a nova
          quantidade?
        </p>
      </Modal>

      {/* Pesquisa manual */}
      <Modal open={manualOpen} onClose={() => setManualOpen(false)} title="Pesquisar material" size="lg">
        <MaterialSearch
          autoFocus
          onSelect={(mat) => {
            setManualOpen(false);
            const q = askQty ? 1 : parsedNextQty();
            void send({ material_id: mat.id, label: mat.code }, Number.isFinite(q) ? q : 1);
          }}
        />
      </Modal>

      {/* Finalizar */}
      <Modal
        open={finishOpen}
        onClose={() => setFinishOpen(false)}
        busy={busy}
        title="Finalizar separação?"
        description="Novas leituras serão bloqueadas e o tablet mostrará o botão CONFIRMAR ME ao solicitante."
        footer={
          <>
            <Button variant="secondary" onClick={() => setFinishOpen(false)}>
              Voltar
            </Button>
            <Button
              variant="success"
              loading={busy}
              icon={<CheckCircle2 className="h-4 w-4" />}
              onClick={() =>
                void run(async () => {
                  await counterFinish(m.id);
                  setFinishOpen(false);
                  playFeedback('ok');
                }, 'Separação finalizada. Aguardando o solicitante confirmar.')
              }
            >
              Finalizar
            </Button>
          </>
        }
      >
        <p className="text-sm text-slate-600">
          {items.length} item(ns), {fmtQty(totalQty)} unidade(s), para {m.requester_name}.
          {!s.terminal_paired && ' Atenção: nenhum tablet está conectado a esta ME.'}
        </p>
      </Modal>

      <JustificationModal
        open={cancelOpen}
        title="Cancelar separação"
        description="A ME fica registrada como cancelada (não é apagada). Informe o motivo."
        confirmLabel="Cancelar separação"
        tone="danger"
        busy={busy}
        onClose={() => setCancelOpen(false)}
        onConfirm={(reason) =>
          run(async () => {
            await cancelMovement(m.id, reason);
            setCancelOpen(false);
          }, 'Separação cancelada.')
        }
      />
    </div>
  );
}

function TerminalCard({
  snapshot,
  warehouseId,
  busy,
  onNewCode,
  onChanged,
}: {
  snapshot: CounterSnapshot;
  warehouseId: string | null;
  busy: boolean;
  onNewCode: () => void;
  onChanged: () => void;
}) {
  const s = snapshot.session;
  const [choosing, setChoosing] = useState(false);
  const [terminals, setTerminals] = useState<CounterTerminal[] | null>(null);
  const [saving, setSaving] = useState(false);
  const active = s.status === 'em_separacao' || s.status === 'aguardando_confirmacao';

  useEffect(() => {
    if (!choosing || !warehouseId) return;
    counterListTerminals(warehouseId)
      .then(setTerminals)
      .catch(() => setTerminals([]));
  }, [choosing, warehouseId]);

  if (!active) return null;
  const expired = new Date(s.pairing_expires_at).getTime() < Date.now();

  const choose = async (id: string) => {
    setSaving(true);
    try {
      await counterSetTerminal(snapshot.movement.id, id || null);
      toast.success(id ? 'Tablet ligado a esta separação.' : 'Tablet desconectado.');
      setChoosing(false);
      onChanged();
    } catch (e) {
      toast.error(errorMessage(e));
    } finally {
      setSaving(false);
    }
  };

  return (
    <Card>
      <div className="flex flex-wrap items-center justify-between gap-4">
        <div className="flex items-center gap-3">
          <Tablet className={clsx('h-8 w-8', s.terminal_paired ? 'text-emerald-600' : 'text-slate-400')} />
          <div>
            <p className="font-semibold text-slate-900">
              {s.terminal_paired ? `Tablet conectado: ${s.terminal_name ?? 'terminal'}` : 'Nenhum tablet conectado'}
            </p>
            <p className="text-sm text-slate-500">
              {s.terminal_paired
                ? 'O solicitante está acompanhando esta separação em tempo real.'
                : 'Escolha o tablet do solicitante ou digite o código no tablet.'}
            </p>
          </div>
        </div>
        <div className="flex flex-wrap items-center gap-3">
          {!s.terminal_paired && (
            <span className="flex items-center gap-2 text-sm text-slate-500">
              código
              <span className={clsx('select-all font-mono text-2xl font-black tracking-[0.25em]', expired ? 'text-slate-300 line-through' : 'text-brand-800')}>
                {s.pairing_code}
              </span>
              <Button variant="ghost" size="sm" icon={<RotateCcw className="h-4 w-4" />} loading={busy} onClick={onNewCode}>
                {expired ? 'Gerar novo' : 'Novo'}
              </Button>
            </span>
          )}
          <Button variant={s.terminal_paired ? 'secondary' : 'primary'} icon={<Tablet className="h-4 w-4" />} onClick={() => setChoosing((v) => !v)}>
            {s.terminal_paired ? 'Trocar tablet' : 'Escolher tablet'}
          </Button>
        </div>
      </div>
      {choosing && (
        <div className="mt-4 flex flex-wrap gap-2 border-t border-slate-100 pt-4">
          {terminals === null ? (
            <Spinner />
          ) : terminals.length === 0 ? (
            <p className="text-sm text-slate-500">Nenhum tablet cadastrado para este estoque.</p>
          ) : (
            terminals.map((t) => {
              const current = s.terminal_name === t.name && s.terminal_paired;
              const busyElsewhere = Boolean(t.busy_me_number) && t.busy_me_number !== snapshot.movement.me_number;
              return (
                <Button
                  key={t.user_id}
                  variant={current ? 'success' : 'secondary'}
                  disabled={busyElsewhere || saving || current}
                  onClick={() => void choose(t.user_id)}
                >
                  {t.name}
                  {current ? ' (conectado)' : busyElsewhere ? ` — ocupado (${t.busy_me_number})` : ' — livre'}
                </Button>
              );
            })
          )}
          {s.terminal_paired && (
            <Button variant="ghost" disabled={saving} onClick={() => void choose('')}>
              Desconectar tablet
            </Button>
          )}
        </div>
      )}
    </Card>
  );
}

function ScannerState({ inputRef, pending }: { inputRef: React.RefObject<HTMLInputElement | null>; pending: number }) {
  const [focused, setFocused] = useState(true);
  useEffect(() => {
    const t = setInterval(() => setFocused(document.activeElement === inputRef.current), 300);
    return () => clearInterval(t);
  }, [inputRef]);
  return (
    <p className={clsx('mt-1 flex items-center gap-1.5 text-xs font-medium', focused ? 'text-emerald-700' : 'text-amber-700')}>
      {pending > 0 ? <Spinner className="h-3.5 w-3.5" /> : focused ? <ScanLine className="h-3.5 w-3.5" /> : <Hand className="h-3.5 w-3.5" />}
      {pending > 0
        ? 'Registrando leitura…'
        : focused
          ? 'Pronto para a próxima leitura'
          : 'Leitor pronto (a leitura também funciona com o foco fora do campo)'}
    </p>
  );
}

function FeedbackBanner({ feedback }: { feedback: Feedback }) {
  const tone = {
    ok: 'border-emerald-300 bg-emerald-50 text-emerald-900',
    info: 'border-sky-300 bg-sky-50 text-sky-900',
    warn: 'border-amber-300 bg-amber-50 text-amber-900',
    error: 'border-red-300 bg-red-50 text-red-900',
  }[feedback.kind];
  return (
    <div key={feedback.at} role="status" aria-live="assertive" className={clsx('mt-4 animate-[pulse_0.6s_ease-out_1] rounded-xl border-2 px-4 py-3', tone)}>
      <p className="text-base font-bold">{feedback.title}</p>
      {feedback.detail && <p className="text-sm">{feedback.detail}</p>}
      <p className="mt-0.5 text-xs opacity-70">{fmtTime(new Date(feedback.at))}</p>
    </div>
  );
}

function ItemRow({
  item,
  editable,
  highlight,
  onSave,
  onRemove,
}: {
  item: CounterSnapshot['items'][number];
  editable: boolean;
  highlight: boolean;
  onSave: (req: number, del: number) => Promise<unknown>;
  onRemove: () => Promise<unknown>;
}) {
  const [req, setReq] = useState(String(item.quantity_requested));
  const [del, setDel] = useState(String(item.quantity_delivered));
  const [confirmRemove, setConfirmRemove] = useState(false);
  useEffect(() => {
    setReq(String(Number(item.quantity_requested)));
    setDel(String(Number(item.quantity_delivered)));
  }, [item.quantity_requested, item.quantity_delivered]);

  const commit = () => {
    const r = Number(req.replace(',', '.'));
    const d = Number(del.replace(',', '.'));
    if (r === Number(item.quantity_requested) && d === Number(item.quantity_delivered)) return;
    void onSave(r, d);
  };
  const qtyInput = (value: string, set: (v: string) => void, label: string) => (
    <input
      aria-label={label}
      inputMode="decimal"
      value={value}
      onChange={(e) => set(e.target.value)}
      onBlur={commit}
      onKeyDown={(e) => {
        if (e.key === 'Enter') (e.currentTarget as HTMLInputElement).blur();
      }}
      className="w-20 rounded-md border border-slate-300 px-2 py-1 text-right"
    />
  );
  return (
    <tr className={clsx('transition-colors', highlight && 'bg-emerald-50')}>
      <td className="px-3 py-2 text-slate-500">{item.line_number}</td>
      <td className="whitespace-nowrap px-3 py-2 font-mono text-xs">{item.material_code}</td>
      <td className="px-3 py-2 font-medium text-slate-900">{item.material_name}</td>
      <td className="px-3 py-2 text-right">{editable ? qtyInput(req, setReq, 'Quantidade solicitada') : fmtQty(item.quantity_requested)}</td>
      <td className="px-3 py-2 text-right font-semibold">{editable ? qtyInput(del, setDel, 'Quantidade atendida') : fmtQty(item.quantity_delivered)}</td>
      <td className="px-3 py-2">{item.unit}</td>
      <td className="whitespace-nowrap px-3 py-2 text-slate-500">{fmtTime(item.created_at)}</td>
      <td className="px-3 py-2 text-right">
        {editable &&
          (confirmRemove ? (
            <span className="inline-flex gap-1">
              <Button size="sm" variant="danger" onClick={() => void onRemove()}>
                Remover
              </Button>
              <Button size="sm" variant="ghost" onClick={() => setConfirmRemove(false)}>
                Não
              </Button>
            </span>
          ) : (
            <button type="button" title="Remover item" className="rounded p-1.5 text-slate-400 hover:bg-red-50 hover:text-red-600" onClick={() => setConfirmRemove(true)}>
              <Trash2 className="h-4 w-4" />
            </button>
          ))}
      </td>
    </tr>
  );
}

function QtyPrompt({ code, onCancel, onConfirm }: { code: string | null; onCancel: () => void; onConfirm: (q: number) => void }) {
  const [v, setV] = useState('1');
  const [err, setErr] = useState<string | null>(null);
  useEffect(() => {
    if (code) {
      setV('1');
      setErr(null);
    }
  }, [code]);
  const ok = () => {
    const n = Number(v.replace(',', '.'));
    if (!Number.isFinite(n) || n <= 0) {
      setErr('Informe uma quantidade maior que zero.');
      playFeedback('error');
      return;
    }
    onConfirm(n);
  };
  return (
    <Modal
      open={Boolean(code)}
      onClose={onCancel}
      title="Quantidade"
      description={code ? `Código lido: ${code}` : undefined}
      footer={
        <>
          <Button variant="secondary" onClick={onCancel}>
            Descartar leitura
          </Button>
          <Button onClick={ok}>Incluir</Button>
        </>
      }
    >
      <Input
        label="Quantidade"
        inputMode="decimal"
        autoFocus
        value={v}
        error={err}
        onChange={(e) => setV(e.target.value)}
        onFocus={(e) => e.currentTarget.select()}
        onKeyDown={(e) => {
          if (e.key === 'Enter') {
            e.preventDefault();
            ok();
          }
        }}
        inputSize="lg"
      />
    </Modal>
  );
}
