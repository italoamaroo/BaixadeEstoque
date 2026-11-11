import { useCallback, useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { CheckCircle2, Lock, PlayCircle, ShieldAlert, Trash2, Unlock } from 'lucide-react';
import { toast } from 'sonner';
import clsx from 'clsx';
import { Alert, Card, CardHeader, EmptyState, PageHeader } from '@/components/ui/Card';
import { Input, Select, Textarea } from '@/components/ui/Field';
import { Button } from '@/components/ui/Button';
import { Badge } from '@/components/ui/Badge';
import { Modal } from '@/components/ui/Modal';
import { PageLoader } from '@/components/ui/Spinner';
import { useAuth } from '@/contexts/AuthContext';
import {
  approveRetentionPolicy,
  createLegalHold,
  decidePurge,
  getSecurityOverview,
  releaseLegalHold,
  requestPurge,
  runSecurityChecks,
  setRetentionPolicy,
  updateSecurityAlert,
  type PurgeRequest,
  type RetentionPolicy,
  type SecurityAlert,
  type SecurityOverview,
} from '@/lib/api';
import { ALERT_RULE_LABELS, ALERT_STATUS_LABELS, AUDIT_CATEGORY_LABELS, AUDIT_SEVERITY_LABELS } from '@/lib/constants';
import { errorMessage } from '@/lib/errors';
import { fmtDate, fmtDateTime, fmtInt } from '@/lib/format';

type Tab = 'alertas' | 'retencao' | 'legal' | 'descarte';

const SEVERITY_STYLE: Record<string, string> = {
  critico: 'bg-red-50 text-red-700 ring-red-300',
  aviso: 'bg-amber-50 text-amber-800 ring-amber-300',
  info: 'bg-slate-100 text-slate-700 ring-slate-300',
};
const STATUS_STYLE: Record<string, string> = {
  aberto: 'bg-red-50 text-red-700 ring-red-300',
  em_analise: 'bg-amber-50 text-amber-800 ring-amber-300',
  encerrado: 'bg-emerald-50 text-emerald-800 ring-emerald-300',
};

function today(offsetDays = 0) {
  const d = new Date(Date.now() + offsetDays * 864e5);
  return new Date(d.getTime() - d.getTimezoneOffset() * 60000).toISOString().slice(0, 10);
}
const catLabel = (c: string | null) => (c ? AUDIT_CATEGORY_LABELS[c] ?? c : 'Todas as categorias');

export function SecurityPage() {
  const { userId } = useAuth();
  const [data, setData] = useState<SecurityOverview | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [tab, setTab] = useState<Tab>('alertas');
  const [running, setRunning] = useState(false);

  const load = useCallback(async () => {
    try {
      setError(null);
      setData(await getSecurityOverview());
    } catch (err) {
      setError(errorMessage(err));
    }
  }, []);
  useEffect(() => {
    void load();
  }, [load]);

  async function runChecks() {
    setRunning(true);
    try {
      const r = await runSecurityChecks();
      toast.success(
        `Verificações concluídas: integridade ${r.integridade.ok ? 'ok' : 'COM PROBLEMA'}, ${r.alertas} alerta(s), ${r.importados_auth} evento(s) do Supabase Auth importados.`,
      );
      await load();
    } catch (err) {
      toast.error(errorMessage(err));
    } finally {
      setRunning(false);
    }
  }

  if (error) return <Alert tone="error" title="Não foi possível carregar a tela de segurança">{error}</Alert>;
  if (!data) return <PageLoader />;
  const admin = data.is_admin;
  const tabs: { id: Tab; label: string }[] = [
    { id: 'alertas', label: `Alertas${data.open_count ? ` (${data.open_count})` : ''}` },
    ...(admin
      ? ([
          { id: 'retencao', label: 'Retenção' },
          { id: 'legal', label: 'Retenção legal' },
          { id: 'descarte', label: 'Descarte' },
        ] as const)
      : []),
  ];

  return (
    <div className="space-y-4">
      <PageHeader
        title="Segurança"
        subtitle="Alertas de segurança, prazos de retenção da auditoria, retenção legal e descarte com dupla aprovação."
        actions={
          admin && (
            <Button icon={<PlayCircle className="h-4 w-4" />} loading={running} onClick={() => void runChecks()}>
              Rodar verificações agora
            </Button>
          )
        }
      />

      <Card>
        <div className="grid gap-3 text-sm sm:grid-cols-3">
          <div>
            <p className="text-slate-500">Alertas em aberto</p>
            <p className="text-2xl font-semibold text-slate-900">
              {data.open_count}
              {data.open_critical > 0 && <span className="ml-2 text-base text-red-700">({data.open_critical} crítico{data.open_critical > 1 ? 's' : ''})</span>}
            </p>
          </div>
          <div>
            <p className="text-slate-500">Última verificação automática</p>
            <p className="font-medium text-slate-900">
              {data.last_checks ? fmtDateTime(data.last_checks.at) : 'Nunca executada'}
              {data.last_checks && (
                <span className={clsx('ml-2', data.last_checks.integridade ? 'text-emerald-700' : 'text-red-700')}>
                  {data.last_checks.integridade ? 'integridade ok' : 'integridade com problema'}
                </span>
              )}
            </p>
          </div>
          {admin && (
            <div>
              <p className="text-slate-500">Agendamento (pg_cron)</p>
              <p className={clsx('font-medium', data.cron ? 'text-emerald-700' : 'text-amber-700')}>
                {data.cron ? 'Ativo — verifica de hora em hora' : 'Desativado — use o botão “Rodar verificações agora”'}
              </p>
            </div>
          )}
        </div>
      </Card>

      {tabs.length > 1 && (
        <div role="tablist" className="flex flex-wrap gap-1 border-b border-slate-200">
          {tabs.map((t) => (
            <button
              key={t.id}
              role="tab"
              aria-selected={tab === t.id}
              type="button"
              onClick={() => setTab(t.id)}
              className={clsx(
                '-mb-px border-b-2 px-4 py-2 text-sm font-medium',
                tab === t.id ? 'border-brand-700 text-brand-800' : 'border-transparent text-slate-600 hover:text-slate-900',
              )}
            >
              {t.label}
            </button>
          ))}
        </div>
      )}

      {tab === 'alertas' && <AlertsTab alerts={data.alerts} admin={admin} onChanged={load} />}
      {tab === 'retencao' && admin && <RetentionTab policies={data.policies ?? []} onChanged={load} />}
      {tab === 'legal' && admin && <LegalHoldTab data={data} onChanged={load} />}
      {tab === 'descarte' && admin && <PurgeTab data={data} userId={userId} onChanged={load} />}
    </div>
  );
}

// ---------------------------------------------------------------------------
function AlertsTab({ alerts, admin, onChanged }: { alerts: SecurityAlert[]; admin: boolean; onChanged: () => Promise<void> }) {
  const [editing, setEditing] = useState<SecurityAlert | null>(null);
  const [status, setStatus] = useState<SecurityAlert['status']>('em_analise');
  const [resolution, setResolution] = useState('');
  const [busy, setBusy] = useState(false);

  function open(a: SecurityAlert) {
    setEditing(a);
    setStatus(a.status === 'aberto' ? 'em_analise' : 'encerrado');
    setResolution('');
  }
  async function save() {
    if (!editing) return;
    setBusy(true);
    try {
      await updateSecurityAlert(editing.id, status, resolution.trim() || null);
      toast.success('Alerta atualizado.');
      setEditing(null);
      await onChanged();
    } catch (err) {
      toast.error(errorMessage(err));
    } finally {
      setBusy(false);
    }
  }

  if (!alerts.length) {
    return (
      <Card>
        <EmptyState icon={<CheckCircle2 className="h-8 w-8 text-emerald-600" />} title="Nenhum alerta" description="Não há alertas abertos nem encerrados nos últimos 90 dias." />
      </Card>
    );
  }
  return (
    <Card padded={false}>
      <ul className="divide-y divide-slate-100">
        {alerts.map((a) => (
          <li key={a.id} className="flex flex-wrap items-start gap-3 px-4 py-3">
            <ShieldAlert className={clsx('mt-0.5 h-5 w-5 shrink-0', a.severity === 'critico' ? 'text-red-600' : 'text-amber-600')} />
            <div className="min-w-0 flex-1">
              <div className="flex flex-wrap items-center gap-2">
                <p className="font-medium text-slate-900">{a.title}</p>
                <Badge className={SEVERITY_STYLE[a.severity]}>{AUDIT_SEVERITY_LABELS[a.severity] ?? a.severity}</Badge>
                <Badge className={STATUS_STYLE[a.status]}>{ALERT_STATUS_LABELS[a.status]}</Badge>
              </div>
              <p className="mt-0.5 text-xs text-slate-500">
                {ALERT_RULE_LABELS[a.rule] ?? a.rule} · aberto em {fmtDateTime(a.created_at)}
                {a.occurrences > 1 && ` · ${a.occurrences} ocorrências (última ${fmtDateTime(a.last_seen_at)})`}
              </p>
              {a.details && (
                <p className="mt-1 break-all font-mono text-xs text-slate-600">
                  {Object.entries(a.details)
                    .filter(([, v]) => v !== null && typeof v !== 'object')
                    .map(([k, v]) => `${k}: ${String(v)}`)
                    .join(' · ')}
                </p>
              )}
              {a.resolution && (
                <p className="mt-1 text-sm text-slate-700">
                  <span className="font-medium">Tratamento:</span> {a.resolution}
                  {a.handled_by_name && <span className="text-slate-500"> — {a.handled_by_name}, {fmtDateTime(a.handled_at)}</span>}
                </p>
              )}
            </div>
            {admin && a.status !== 'encerrado' && (
              <Button size="sm" variant="secondary" onClick={() => open(a)}>
                Tratar
              </Button>
            )}
          </li>
        ))}
      </ul>
      {!admin && <p className="border-t border-slate-100 px-4 py-2 text-xs text-slate-500">Somente o administrador trata alertas e vê os detalhes técnicos.</p>}

      <Modal
        open={!!editing}
        onClose={() => setEditing(null)}
        busy={busy}
        title="Tratar alerta"
        description={editing?.title}
        footer={
          <>
            <Button variant="secondary" onClick={() => setEditing(null)} disabled={busy}>
              Voltar
            </Button>
            <Button loading={busy} disabled={status === 'encerrado' && resolution.trim().length < 5} onClick={() => void save()}>
              Salvar
            </Button>
          </>
        }
      >
        <div className="space-y-3">
          <Select label="Situação" value={status} onChange={(e) => setStatus(e.target.value as SecurityAlert['status'])}>
            <option value="em_analise">Em análise</option>
            <option value="encerrado">Encerrado</option>
          </Select>
          <Textarea
            label="Tratamento (o que foi verificado e feito)"
            hint={status === 'encerrado' ? 'Obrigatório para encerrar (mínimo de 5 caracteres).' : 'Opcional.'}
            rows={3}
            maxLength={1000}
            value={resolution}
            onChange={(e) => setResolution(e.target.value)}
          />
        </div>
      </Modal>
    </Card>
  );
}

// ---------------------------------------------------------------------------
function RetentionTab({ policies, onChanged }: { policies: RetentionPolicy[]; onChanged: () => Promise<void> }) {
  const [editing, setEditing] = useState<RetentionPolicy | null>(null);
  const [days, setDays] = useState('');
  const [basis, setBasis] = useState('');
  const [busy, setBusy] = useState(false);

  async function save() {
    if (!editing) return;
    setBusy(true);
    try {
      await setRetentionPolicy(editing.category, Number(days), basis.trim());
      toast.success('Prazo salvo como proposta. Aprove para valer.');
      setEditing(null);
      await onChanged();
    } catch (err) {
      toast.error(errorMessage(err));
    } finally {
      setBusy(false);
    }
  }
  async function approve(p: RetentionPolicy) {
    try {
      await approveRetentionPolicy(p.category);
      toast.success(`Prazo de ${catLabel(p.category)} aprovado.`);
      await onChanged();
    } catch (err) {
      toast.error(errorMessage(err));
    }
  }

  return (
    <div className="space-y-3">
      <Alert tone="warning" title="Os prazos vêm como PROPOSTA">
        Nenhum evento é descartado automaticamente. Os prazos sugeridos precisam ser validados com o jurídico e a contabilidade e depois aprovados aqui. Incidentes
        exigem no mínimo 5 anos. Qualquer alteração volta o prazo para “proposta”.
      </Alert>
      <Card padded={false}>
        <div className="overflow-x-auto">
          <table className="min-w-full text-sm">
            <thead className="bg-slate-50 text-left text-xs uppercase tracking-wide text-slate-500">
              <tr>
                <th className="px-4 py-2">Categoria</th>
                <th className="px-4 py-2">Prazo</th>
                <th className="px-4 py-2">Fundamento</th>
                <th className="px-4 py-2">Situação</th>
                <th className="px-4 py-2 text-right">Eventos</th>
                <th className="px-4 py-2" />
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100">
              {policies.map((p) => (
                <tr key={p.category} className="align-top">
                  <td className="px-4 py-2 font-medium text-slate-900">{catLabel(p.category)}</td>
                  <td className="whitespace-nowrap px-4 py-2">{p.retain_days ? `${fmtInt(p.retain_days)} dias` : '—'}</td>
                  <td className="px-4 py-2 text-slate-600">{p.basis ?? '—'}</td>
                  <td className="whitespace-nowrap px-4 py-2">
                    {p.status === 'aprovada' ? (
                      <span className="text-emerald-700">
                        Aprovada{p.approved_by_name && ` por ${p.approved_by_name}`}
                        <br />
                        <span className="text-xs text-slate-500">{fmtDate(p.approved_at)}</span>
                      </span>
                    ) : (
                      <span className="text-amber-700">Proposta</span>
                    )}
                  </td>
                  <td className="px-4 py-2 text-right">{fmtInt(p.events)}</td>
                  <td className="whitespace-nowrap px-4 py-2 text-right">
                    <Button
                      size="sm"
                      variant="ghost"
                      onClick={() => {
                        setEditing(p);
                        setDays(p.retain_days ? String(p.retain_days) : '');
                        setBasis(p.basis ?? '');
                      }}
                    >
                      Alterar
                    </Button>
                    {p.status === 'proposta' && p.retain_days && (
                      <Button size="sm" variant="secondary" onClick={() => void approve(p)}>
                        Aprovar
                      </Button>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </Card>

      <Modal
        open={!!editing}
        onClose={() => setEditing(null)}
        busy={busy}
        title={`Prazo de retenção — ${editing ? catLabel(editing.category) : ''}`}
        footer={
          <>
            <Button variant="secondary" onClick={() => setEditing(null)} disabled={busy}>
              Voltar
            </Button>
            <Button loading={busy} disabled={!(Number(days) >= 30) || basis.trim().length < 5} onClick={() => void save()}>
              Salvar como proposta
            </Button>
          </>
        }
      >
        <div className="space-y-3">
          <Input label="Prazo (dias)" type="number" min={30} max={7300} value={days} onChange={(e) => setDays(e.target.value)} hint="Entre 30 e 7300 dias (20 anos)." />
          <Textarea label="Fundamento (lei, contrato ou decisão interna)" rows={3} maxLength={500} value={basis} onChange={(e) => setBasis(e.target.value)} />
        </div>
      </Modal>
    </div>
  );
}

// ---------------------------------------------------------------------------
function LegalHoldTab({ data, onChanged }: { data: SecurityOverview; onChanged: () => Promise<void> }) {
  const [creating, setCreating] = useState(false);
  const [reason, setReason] = useState('');
  const [from, setFrom] = useState(today(-30));
  const [to, setTo] = useState(today());
  const [category, setCategory] = useState('');
  const [releasing, setReleasing] = useState<number | null>(null);
  const [releaseReason, setReleaseReason] = useState('');
  const [busy, setBusy] = useState(false);

  async function create() {
    setBusy(true);
    try {
      await createLegalHold(reason.trim(), from, to, category || null);
      toast.success('Retenção legal aberta. Os eventos do período não podem ser descartados.');
      setCreating(false);
      setReason('');
      await onChanged();
    } catch (err) {
      toast.error(errorMessage(err));
    } finally {
      setBusy(false);
    }
  }
  async function release() {
    if (releasing === null) return;
    setBusy(true);
    try {
      await releaseLegalHold(releasing, releaseReason.trim());
      toast.success('Retenção legal liberada.');
      setReleasing(null);
      setReleaseReason('');
      await onChanged();
    } catch (err) {
      toast.error(errorMessage(err));
    } finally {
      setBusy(false);
    }
  }

  const holds = data.holds ?? [];
  return (
    <div className="space-y-3">
      <Card>
        <CardHeader
          title="Retenção legal"
          subtitle="Use quando houver investigação, incidente, processo ou pedido de autoridade. Enquanto ativa, nenhum evento do período é descartado."
          actions={
            <Button icon={<Lock className="h-4 w-4" />} onClick={() => setCreating(true)}>
              Abrir retenção legal
            </Button>
          }
        />
        {!holds.length ? (
          <p className="text-sm text-slate-500">Nenhuma retenção legal registrada.</p>
        ) : (
          <ul className="divide-y divide-slate-100">
            {holds.map((h) => (
              <li key={h.id} className="flex flex-wrap items-start gap-3 py-3">
                <div className="min-w-0 flex-1">
                  <p className="font-medium text-slate-900">
                    {fmtDate(h.date_from)} a {fmtDate(h.date_to)} · {catLabel(h.category)}
                    {h.released_at ? <span className="ml-2 text-sm text-slate-500">(liberada)</span> : <span className="ml-2 text-sm text-red-700">(ativa)</span>}
                  </p>
                  <p className="text-sm text-slate-700">{h.reason}</p>
                  <p className="text-xs text-slate-500">
                    Aberta por {h.created_by_name ?? '—'} em {fmtDateTime(h.created_at)}
                    {h.released_at && ` · liberada em ${fmtDateTime(h.released_at)}: ${h.release_reason ?? ''}`}
                  </p>
                </div>
                {!h.released_at && (
                  <Button size="sm" variant="secondary" icon={<Unlock className="h-4 w-4" />} onClick={() => setReleasing(h.id)}>
                    Liberar
                  </Button>
                )}
              </li>
            ))}
          </ul>
        )}
      </Card>

      <Modal
        open={creating}
        onClose={() => setCreating(false)}
        busy={busy}
        title="Abrir retenção legal"
        footer={
          <>
            <Button variant="secondary" onClick={() => setCreating(false)} disabled={busy}>
              Voltar
            </Button>
            <Button loading={busy} disabled={reason.trim().length < 10 || !from || !to || from > to} onClick={() => void create()}>
              Abrir
            </Button>
          </>
        }
      >
        <div className="space-y-3">
          <Textarea label="Motivo" hint="Mínimo de 10 caracteres." rows={3} maxLength={500} value={reason} onChange={(e) => setReason(e.target.value)} />
          <div className="grid gap-3 sm:grid-cols-2">
            <Input label="De" type="date" value={from} onChange={(e) => setFrom(e.target.value)} />
            <Input label="Até" type="date" value={to} onChange={(e) => setTo(e.target.value)} />
          </div>
          <Select label="Categoria" value={category} onChange={(e) => setCategory(e.target.value)}>
            <option value="">Todas as categorias</option>
            {Object.entries(AUDIT_CATEGORY_LABELS).map(([k, v]) => (
              <option key={k} value={k}>
                {v}
              </option>
            ))}
          </Select>
        </div>
      </Modal>

      <Modal
        open={releasing !== null}
        onClose={() => setReleasing(null)}
        busy={busy}
        title="Liberar retenção legal"
        footer={
          <>
            <Button variant="secondary" onClick={() => setReleasing(null)} disabled={busy}>
              Voltar
            </Button>
            <Button loading={busy} disabled={releaseReason.trim().length < 10} onClick={() => void release()}>
              Liberar
            </Button>
          </>
        }
      >
        <Textarea label="Motivo da liberação" hint="Mínimo de 10 caracteres." rows={3} maxLength={500} value={releaseReason} onChange={(e) => setReleaseReason(e.target.value)} />
      </Modal>
    </div>
  );
}

// ---------------------------------------------------------------------------
function PurgeTab({ data, userId, onChanged }: { data: SecurityOverview; userId: string | null; onChanged: () => Promise<void> }) {
  const approved = (data.policies ?? []).filter((p) => p.status === 'aprovada' && p.retain_days);
  const [category, setCategory] = useState(approved[0]?.category ?? '');
  const [before, setBefore] = useState('');
  const [reason, setReason] = useState('');
  const [deciding, setDeciding] = useState<{ req: PurgeRequest; approve: boolean } | null>(null);
  const [note, setNote] = useState('');
  const [busy, setBusy] = useState(false);
  const policy = approved.find((p) => p.category === category);
  const maxDate = policy?.retain_days ? today(-policy.retain_days) : '';
  const singleAdmin = (data.admins ?? 0) < 2;

  async function request() {
    setBusy(true);
    try {
      await requestPurge(category, before, reason.trim());
      toast.success('Pedido de descarte registrado. Outro administrador precisa aprovar.');
      setReason('');
      await onChanged();
    } catch (err) {
      toast.error(errorMessage(err));
    } finally {
      setBusy(false);
    }
  }
  async function decide() {
    if (!deciding) return;
    setBusy(true);
    try {
      const r = await decidePurge(deciding.req.id, deciding.approve, note.trim());
      toast.success(r.status === 'executado' ? `Descarte executado: ${r.eventos ?? 0} evento(s).` : 'Pedido rejeitado.');
      setDeciding(null);
      setNote('');
      await onChanged();
    } catch (err) {
      toast.error(errorMessage(err));
    } finally {
      setBusy(false);
    }
  }

  const purges = data.purges ?? [];
  return (
    <div className="space-y-3">
      <Alert tone="info" title="Como funciona o descarte">
        O descarte apaga o conteúdo dos eventos vencidos (dados, IP, usuário) e mantém o esqueleto do encadeamento, para a verificação de integridade continuar
        válida. Exige pedido de um administrador e aprovação de <strong>outro</strong> administrador. Eventos em retenção legal nunca são descartados. Veja também
        a <Link className="text-brand-700 underline" to="/admin/auditoria">Auditoria</Link>.
      </Alert>
      {singleAdmin && (
        <Alert tone="warning" title="Só existe um administrador ativo">
          O descarte precisa de dois administradores diferentes (um pede, outro aprova). Cadastre um segundo administrador para usar esta função.
        </Alert>
      )}

      <Card>
        <CardHeader title="Pedir descarte" subtitle="Somente categorias com prazo de retenção aprovado." />
        {!approved.length ? (
          <p className="text-sm text-slate-500">Nenhuma categoria tem prazo aprovado. Aprove um prazo na aba Retenção.</p>
        ) : (
          <div className="grid gap-3 sm:grid-cols-3">
            <Select label="Categoria" value={category} onChange={(e) => setCategory(e.target.value)}>
              {approved.map((p) => (
                <option key={p.category} value={p.category}>
                  {catLabel(p.category)} ({p.retain_days} dias)
                </option>
              ))}
            </Select>
            <Input label="Eventos anteriores a" type="date" max={maxDate} value={before} onChange={(e) => setBefore(e.target.value)} hint={maxDate && `Até ${fmtDate(maxDate)}.`} />
            <Input label="Motivo" value={reason} maxLength={500} onChange={(e) => setReason(e.target.value)} hint="Mínimo de 10 caracteres." />
            <div className="sm:col-span-3">
              <Button
                variant="danger"
                icon={<Trash2 className="h-4 w-4" />}
                loading={busy && !deciding}
                disabled={singleAdmin || !before || (maxDate !== '' && before > maxDate) || reason.trim().length < 10}
                onClick={() => void request()}
              >
                Pedir descarte
              </Button>
            </div>
          </div>
        )}
      </Card>

      <Card padded={false}>
        <div className="px-4 pt-4">
          <CardHeader title="Pedidos de descarte" />
        </div>
        {!purges.length ? (
          <p className="px-4 pb-4 text-sm text-slate-500">Nenhum pedido.</p>
        ) : (
          <ul className="divide-y divide-slate-100">
            {purges.map((r) => (
              <li key={r.id} className="flex flex-wrap items-start gap-3 px-4 py-3">
                <div className="min-w-0 flex-1">
                  <p className="font-medium text-slate-900">
                    {catLabel(r.category)} antes de {fmtDate(r.before_date)} · {fmtInt(r.events)} evento(s)
                    <span
                      className={clsx(
                        'ml-2 text-sm',
                        r.status === 'pendente' ? 'text-amber-700' : r.status === 'executado' ? 'text-red-700' : 'text-slate-500',
                      )}
                    >
                      ({r.status}
                      {r.status === 'executado' && r.purged !== null && `: ${fmtInt(r.purged)} descartados`})
                    </span>
                  </p>
                  <p className="text-sm text-slate-700">{r.reason}</p>
                  <p className="text-xs text-slate-500">
                    Pedido por {r.requested_by_name ?? '—'} em {fmtDateTime(r.requested_at)}
                    {r.decided_at && ` · decidido por ${r.decided_by_name ?? '—'} em ${fmtDateTime(r.decided_at)}: ${r.decision_note ?? ''}`}
                  </p>
                </div>
                {r.status === 'pendente' &&
                  (r.requested_by === userId ? (
                    <span className="text-xs text-slate-500">Aguardando outro administrador</span>
                  ) : (
                    <div className="flex gap-2">
                      <Button size="sm" variant="secondary" onClick={() => setDeciding({ req: r, approve: false })}>
                        Rejeitar
                      </Button>
                      <Button size="sm" variant="danger" onClick={() => setDeciding({ req: r, approve: true })}>
                        Aprovar descarte
                      </Button>
                    </div>
                  ))}
              </li>
            ))}
          </ul>
        )}
      </Card>

      <Modal
        open={!!deciding}
        onClose={() => setDeciding(null)}
        busy={busy}
        title={deciding?.approve ? 'Aprovar e executar o descarte' : 'Rejeitar o pedido de descarte'}
        description={
          deciding?.approve
            ? `O conteúdo de ${fmtInt(deciding.req.events)} evento(s) será apagado de forma definitiva. Esta ação não pode ser desfeita.`
            : undefined
        }
        footer={
          <>
            <Button variant="secondary" onClick={() => setDeciding(null)} disabled={busy}>
              Voltar
            </Button>
            <Button variant={deciding?.approve ? 'danger' : 'primary'} loading={busy} disabled={note.trim().length < 5} onClick={() => void decide()}>
              {deciding?.approve ? 'Aprovar e descartar' : 'Rejeitar'}
            </Button>
          </>
        }
      >
        <Textarea label="Justificativa da decisão" hint="Mínimo de 5 caracteres." rows={3} maxLength={500} value={note} onChange={(e) => setNote(e.target.value)} />
      </Modal>
    </div>
  );
}
