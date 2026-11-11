import { useCallback, useEffect, useMemo, useState } from 'react';
import { useSearchParams } from 'react-router-dom';
import { AlertTriangle, CalendarDays, CheckCircle2, Clock, Plus, Siren, Trash2 } from 'lucide-react';
import { toast } from 'sonner';
import clsx from 'clsx';
import { Alert, Card, CardHeader, EmptyState, PageHeader } from '@/components/ui/Card';
import { Input, Select, Textarea } from '@/components/ui/Field';
import { Button } from '@/components/ui/Button';
import { Badge } from '@/components/ui/Badge';
import { Modal } from '@/components/ui/Modal';
import { PageLoader } from '@/components/ui/Spinner';
import {
  addHoliday,
  addIncidentNote,
  closeIncident,
  getIncident,
  getIncidentOverview,
  openIncident,
  removeHoliday,
  updateIncident,
  updatePrivacySettings,
  type DeadlineStatus,
  type Holiday,
  type IncidentOverview,
  type PrivacySettings,
  type SecurityIncident,
} from '@/lib/api';
import { errorMessage } from '@/lib/errors';
import { fmtDate, fmtDateTime } from '@/lib/format';

const STATUS_LABEL: Record<SecurityIncident['status'], string> = { aberto: 'Aberto', em_tratamento: 'Em tratamento', encerrado: 'Encerrado' };
const STATUS_STYLE: Record<SecurityIncident['status'], string> = {
  aberto: 'bg-red-50 text-red-700 ring-red-300',
  em_tratamento: 'bg-amber-50 text-amber-800 ring-amber-300',
  encerrado: 'bg-emerald-50 text-emerald-800 ring-emerald-300',
};
const RISK_LABEL: Record<SecurityIncident['risk_level'], string> = {
  a_avaliar: 'A avaliar',
  sem_risco_relevante: 'Sem risco ou dano relevante',
  risco_relevante: 'Pode causar risco ou dano relevante',
};
// Art. 5º da Res. CD/ANPD 15/2024 (critérios cumulativos com o efeito significativo)
const RISK_CRITERIA: Record<string, string> = {
  dados_sensiveis: 'Dados pessoais sensíveis',
  vulneraveis: 'Dados de crianças, adolescentes ou idosos',
  dados_financeiros: 'Dados financeiros',
  autenticacao: 'Dados de autenticação em sistemas (senhas, tokens)',
  sigilo: 'Dados protegidos por sigilo legal, judicial ou profissional',
  larga_escala: 'Dados em larga escala',
};
const DATA_CATEGORY_SUGGESTIONS = ['nome', 'matrícula', 'e-mail', 'assinatura', 'foto do rosto', 'IP / navegador', 'senha', 'setor / cargo'];
const DEADLINE_STYLE: Record<string, string> = {
  pendente: 'text-amber-700',
  atrasado: 'text-red-700 font-semibold',
  cumprido: 'text-emerald-700',
  cumprido_com_atraso: 'text-red-700',
};
const DEADLINE_LABEL: Record<string, string> = {
  pendente: 'pendente',
  atrasado: 'VENCIDO',
  cumprido: 'cumprido',
  cumprido_com_atraso: 'cumprido com atraso',
};

/** ISO -> valor de <input type="datetime-local"> no fuso do aparelho */
function toLocalInput(iso: string | null | undefined) {
  if (!iso) return '';
  const d = new Date(iso);
  return new Date(d.getTime() - d.getTimezoneOffset() * 60000).toISOString().slice(0, 16);
}
function fromLocalInput(v: string) {
  return v ? new Date(v).toISOString() : null;
}

function DeadlineLine({ label, due, left, status }: { label: string; due: string | null; left: number | null; status: DeadlineStatus }) {
  if (!due) return null;
  return (
    <div className="flex flex-wrap items-baseline justify-between gap-2 py-1 text-sm">
      <span className="text-slate-600">{label}</span>
      <span className={clsx(status ? DEADLINE_STYLE[status] : 'text-slate-700')}>
        até {fmtDate(due)}
        {status && ` · ${DEADLINE_LABEL[status]}`}
        {left !== null && status === 'pendente' && ` · ${left} dia${left === 1 ? '' : 's'} úte${left === 1 ? 'l' : 'is'}`}
      </span>
    </div>
  );
}

export function IncidentsPage() {
  const [params, setParams] = useSearchParams();
  const [data, setData] = useState<IncidentOverview | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [tab, setTab] = useState<'incidentes' | 'config'>('incidentes');
  const [creating, setCreating] = useState(false);
  const selectedId = Number(params.get('id')) || null;

  const load = useCallback(async () => {
    try {
      setError(null);
      setData(await getIncidentOverview());
    } catch (err) {
      setError(errorMessage(err));
    }
  }, []);
  useEffect(() => {
    void load();
  }, [load]);
  useEffect(() => {
    if (params.get('alerta')) setCreating(true);
  }, [params]);

  if (error) return <Alert tone="error" title="Não foi possível carregar os incidentes">{error}</Alert>;
  if (!data) return <PageLoader />;
  const s = data.settings;
  const pending = [!s.controller_name && 'controlador', !s.dpo_name && 'encarregado', s.small_agent === null && 'porte da empresa'].filter(Boolean);

  return (
    <div className="space-y-4">
      <PageHeader
        title="Incidentes de segurança"
        subtitle="Registro conforme o art. 10 da Resolução CD/ANPD nº 15/2024, com os prazos de comunicação em dias úteis."
        actions={
          <Button icon={<Plus className="h-4 w-4" />} onClick={() => setCreating(true)}>
            Registrar incidente
          </Button>
        }
      />
      {pending.length > 0 && (
        <Alert tone="warning" title="Configuração LGPD a definir">
          Falta definir: {pending.join(', ')}. Essas decisões são da empresa (jurídico/diretoria). Enquanto o porte não for definido, os prazos são calculados
          pelo prazo simples (3 dias úteis), que é o mais curto.{' '}
          <button type="button" className="font-medium underline" onClick={() => setTab('config')}>
            Abrir configuração
          </button>
        </Alert>
      )}

      <div role="tablist" className="flex gap-1 border-b border-slate-200">
        {(
          [
            ['incidentes', `Incidentes (${data.incidents.filter((i) => i.status !== 'encerrado').length} em aberto)`],
            ['config', 'Configuração LGPD e feriados'],
          ] as const
        ).map(([id, label]) => (
          <button
            key={id}
            type="button"
            role="tab"
            aria-selected={tab === id}
            onClick={() => setTab(id)}
            className={clsx(
              '-mb-px border-b-2 px-4 py-2 text-sm font-medium',
              tab === id ? 'border-brand-700 text-brand-800' : 'border-transparent text-slate-600 hover:text-slate-900',
            )}
          >
            {label}
          </button>
        ))}
      </div>

      {tab === 'incidentes' &&
        (selectedId ? (
          <IncidentDetail
            id={selectedId}
            onBack={() => {
              params.delete('id');
              setParams(params);
              void load();
            }}
          />
        ) : (
          <IncidentList incidents={data.incidents} onOpen={(id) => setParams({ id: String(id) })} />
        ))}
      {tab === 'config' && <ConfigTab settings={s} holidays={data.holidays} onChanged={load} />}

      <NewIncidentModal
        open={creating}
        alerts={data.open_alerts}
        initialAlert={Number(params.get('alerta')) || null}
        onClose={() => {
          setCreating(false);
          if (params.get('alerta')) {
            params.delete('alerta');
            setParams(params);
          }
        }}
        onCreated={(id) => {
          setCreating(false);
          setTab('incidentes');
          setParams({ id: String(id) });
          void load();
        }}
      />
    </div>
  );
}

// ---------------------------------------------------------------------------
function IncidentList({ incidents, onOpen }: { incidents: SecurityIncident[]; onOpen: (id: number) => void }) {
  if (!incidents.length) {
    return (
      <Card>
        <EmptyState
          icon={<CheckCircle2 className="h-8 w-8 text-emerald-600" />}
          title="Nenhum incidente registrado"
          description="Registre aqui qualquer incidente de segurança, inclusive os que não forem comunicados à ANPD (art. 10)."
        />
      </Card>
    );
  }
  return (
    <Card padded={false}>
      <ul className="divide-y divide-slate-100">
        {incidents.map((i) => {
          const p = i.prazos;
          const late = p.anpd_situacao === 'atrasado' || p.titulares_situacao === 'atrasado';
          return (
            <li key={i.id}>
              <button type="button" onClick={() => onOpen(i.id)} className="flex w-full flex-wrap items-start gap-3 px-4 py-3 text-left hover:bg-slate-50">
                <Siren className={clsx('mt-0.5 h-5 w-5 shrink-0', i.status === 'encerrado' ? 'text-slate-400' : late ? 'text-red-600' : 'text-amber-600')} />
                <div className="min-w-0 flex-1">
                  <div className="flex flex-wrap items-center gap-2">
                    <span className="font-mono text-sm text-slate-500">{i.code}</span>
                    <span className="font-medium text-slate-900">{i.title}</span>
                    <Badge className={STATUS_STYLE[i.status]}>{STATUS_LABEL[i.status]}</Badge>
                  </div>
                  <p className="mt-0.5 text-xs text-slate-500">
                    Conhecido em {fmtDateTime(i.known_at)} · risco: {RISK_LABEL[i.risk_level]}
                  </p>
                  {i.status !== 'encerrado' && p.aplica && (
                    <p className={clsx('mt-0.5 text-xs', late ? 'font-semibold text-red-700' : 'text-amber-700')}>
                      <Clock className="mr-1 inline h-3.5 w-3.5" />
                      ANPD até {fmtDate(p.anpd_prazo)} ({DEADLINE_LABEL[p.anpd_situacao ?? 'pendente']}) · titulares até {fmtDate(p.titulares_prazo)} (
                      {DEADLINE_LABEL[p.titulares_situacao ?? 'pendente']})
                    </p>
                  )}
                </div>
              </button>
            </li>
          );
        })}
      </ul>
    </Card>
  );
}

// ---------------------------------------------------------------------------
function NewIncidentModal({
  open,
  alerts,
  initialAlert,
  onClose,
  onCreated,
}: {
  open: boolean;
  alerts: IncidentOverview['open_alerts'];
  initialAlert: number | null;
  onClose: () => void;
  onCreated: (id: number) => void;
}) {
  const [title, setTitle] = useState('');
  const [knownAt, setKnownAt] = useState('');
  const [description, setDescription] = useState('');
  const [alertId, setAlertId] = useState('');
  const [busy, setBusy] = useState(false);
  useEffect(() => {
    if (open) {
      const a = alerts.find((x) => x.id === initialAlert);
      setTitle(a ? a.title : '');
      setKnownAt(toLocalInput(new Date().toISOString()));
      setDescription('');
      setAlertId(a ? String(a.id) : '');
    }
  }, [open, alerts, initialAlert]);

  async function save() {
    setBusy(true);
    try {
      const id = await openIncident({
        title: title.trim(),
        known_at: fromLocalInput(knownAt) ?? undefined,
        description: description.trim() || undefined,
        alert_id: alertId ? Number(alertId) : null,
      });
      toast.success('Incidente registrado.');
      onCreated(id);
    } catch (err) {
      toast.error(errorMessage(err));
    } finally {
      setBusy(false);
    }
  }

  return (
    <Modal
      open={open}
      onClose={onClose}
      busy={busy}
      title="Registrar incidente"
      description="Registre assim que tomar conhecimento. Os detalhes podem ser completados depois."
      footer={
        <>
          <Button variant="secondary" onClick={onClose} disabled={busy}>
            Voltar
          </Button>
          <Button loading={busy} disabled={title.trim().length < 5 || !knownAt} onClick={() => void save()}>
            Registrar
          </Button>
        </>
      }
    >
      <div className="space-y-3">
        <Input label="Título" value={title} maxLength={200} onChange={(e) => setTitle(e.target.value)} hint="Ex.: tablet perdido, acesso indevido, planilha enviada por engano." />
        <Input label="Quando a empresa tomou conhecimento" type="datetime-local" value={knownAt} onChange={(e) => setKnownAt(e.target.value)} />
        <Textarea label="O que aconteceu (opcional)" rows={3} maxLength={5000} value={description} onChange={(e) => setDescription(e.target.value)} />
        {alerts.length > 0 && (
          <Select label="Alerta de origem (opcional)" value={alertId} onChange={(e) => setAlertId(e.target.value)}>
            <option value="">Nenhum</option>
            {alerts.map((a) => (
              <option key={a.id} value={a.id}>
                {a.title} ({fmtDate(a.created_at)})
              </option>
            ))}
          </Select>
        )}
      </div>
    </Modal>
  );
}

// ---------------------------------------------------------------------------
type Form = {
  title: string;
  status: 'aberto' | 'em_tratamento';
  known_at: string;
  personal_data_known_at: string;
  occurred_at: string;
  description: string;
  data_categories: string;
  data_nature: string;
  sensitive_data: '' | 'sim' | 'nao';
  affected_count: string;
  affected_count_note: string;
  risk_criteria: string[];
  risk_level: SecurityIncident['risk_level'];
  risk_assessment: string;
  measures: string;
  anpd_communicated_at: string;
  anpd_protocol: string;
  titulares_communicated_at: string;
  communication_form: string;
  communication_content: string;
  no_communication_reason: string;
};
function toForm(i: SecurityIncident): Form {
  return {
    title: i.title,
    status: i.status === 'encerrado' ? 'em_tratamento' : i.status,
    known_at: toLocalInput(i.known_at),
    personal_data_known_at: toLocalInput(i.personal_data_known_at),
    occurred_at: toLocalInput(i.occurred_at),
    description: i.description ?? '',
    data_categories: i.data_categories.join(', '),
    data_nature: i.data_nature ?? '',
    sensitive_data: i.sensitive_data === null ? '' : i.sensitive_data ? 'sim' : 'nao',
    affected_count: i.affected_count === null ? '' : String(i.affected_count),
    affected_count_note: i.affected_count_note ?? '',
    risk_criteria: i.risk_criteria,
    risk_level: i.risk_level,
    risk_assessment: i.risk_assessment ?? '',
    measures: i.measures ?? '',
    anpd_communicated_at: toLocalInput(i.anpd_communicated_at),
    anpd_protocol: i.anpd_protocol ?? '',
    titulares_communicated_at: toLocalInput(i.titulares_communicated_at),
    communication_form: i.communication_form ?? '',
    communication_content: i.communication_content ?? '',
    no_communication_reason: i.no_communication_reason ?? '',
  };
}
function toPayload(f: Form): Partial<SecurityIncident> {
  return {
    title: f.title,
    status: f.status,
    known_at: fromLocalInput(f.known_at) ?? undefined,
    personal_data_known_at: fromLocalInput(f.personal_data_known_at),
    occurred_at: fromLocalInput(f.occurred_at),
    description: f.description,
    data_categories: f.data_categories
      .split(/[,;\n]/)
      .map((x) => x.trim())
      .filter(Boolean),
    data_nature: f.data_nature,
    sensitive_data: f.sensitive_data === '' ? null : f.sensitive_data === 'sim',
    affected_count: f.affected_count === '' ? null : Number(f.affected_count),
    affected_count_note: f.affected_count_note,
    risk_criteria: f.risk_criteria,
    risk_level: f.risk_level,
    risk_assessment: f.risk_assessment,
    measures: f.measures,
    anpd_communicated_at: fromLocalInput(f.anpd_communicated_at),
    anpd_protocol: f.anpd_protocol,
    titulares_communicated_at: fromLocalInput(f.titulares_communicated_at),
    communication_form: f.communication_form,
    communication_content: f.communication_content,
    no_communication_reason: f.no_communication_reason,
  } as Partial<SecurityIncident>;
}

function Section({ n, title, children }: { n: string; title: string; children: React.ReactNode }) {
  return (
    <fieldset className="space-y-3 rounded-lg border border-slate-200 p-4">
      <legend className="px-1 text-sm font-semibold text-slate-800">
        <span className="mr-1 text-slate-500">{n}</span>
        {title}
      </legend>
      {children}
    </fieldset>
  );
}

function IncidentDetail({ id, onBack }: { id: number; onBack: () => void }) {
  const [inc, setInc] = useState<SecurityIncident | null>(null);
  const [form, setForm] = useState<Form | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [note, setNote] = useState('');
  const [closing, setClosing] = useState(false);
  const [closingNote, setClosingNote] = useState('');

  const load = useCallback(async () => {
    try {
      const i = await getIncident(id);
      setInc(i);
      setForm(toForm(i));
    } catch (err) {
      setError(errorMessage(err));
    }
  }, [id]);
  useEffect(() => {
    void load();
  }, [load]);

  const dirty = useMemo(() => !!inc && !!form && JSON.stringify(toForm(inc)) !== JSON.stringify(form), [inc, form]);
  if (error) return <Alert tone="error" title="Não foi possível abrir o incidente">{error}</Alert>;
  if (!inc || !form) return <PageLoader />;
  const closed = inc.status === 'encerrado';
  const p = inc.prazos;
  const set = <K extends keyof Form>(k: K, v: Form[K]) => setForm({ ...form, [k]: v });

  async function save() {
    setBusy(true);
    try {
      await updateIncident(id, toPayload(form!));
      toast.success('Incidente salvo.');
      await load();
    } catch (err) {
      toast.error(errorMessage(err));
    } finally {
      setBusy(false);
    }
  }
  async function sendNote() {
    setBusy(true);
    try {
      await addIncidentNote(id, note.trim());
      setNote('');
      await load();
    } catch (err) {
      toast.error(errorMessage(err));
    } finally {
      setBusy(false);
    }
  }
  async function close() {
    setBusy(true);
    try {
      await closeIncident(id, closingNote.trim());
      toast.success('Incidente encerrado.');
      setClosing(false);
      await load();
    } catch (err) {
      toast.error(errorMessage(err));
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center gap-2">
        <Button variant="ghost" size="sm" onClick={onBack}>
          ← Voltar à lista
        </Button>
        <span className="font-mono text-sm text-slate-500">{inc.code}</span>
        <Badge className={STATUS_STYLE[inc.status]}>{STATUS_LABEL[inc.status]}</Badge>
      </div>

      <Card>
        <CardHeader title="Prazos de comunicação" subtitle="Res. CD/ANPD 15/2024, arts. 6º e 9º. Contados em dias úteis a partir do dia seguinte ao conhecimento de que o incidente afetou dados pessoais." />
        {p.motivo && <p className="mb-2 text-sm text-amber-800">{p.motivo}.</p>}
        <div className="divide-y divide-slate-100">
          <DeadlineLine label="Comunicação à ANPD (art. 6º)" due={p.anpd_prazo} left={p.anpd_dias_restantes} status={p.anpd_situacao} />
          <DeadlineLine label="Comunicação aos titulares (art. 9º)" due={p.titulares_prazo} left={p.titulares_dias_restantes} status={p.titulares_situacao} />
          <DeadlineLine label="Declaração da comunicação aos titulares (art. 9º, § 4º)" due={p.declaracao_prazo} left={null} status={null} />
          <DeadlineLine label="Complementação à ANPD (art. 6º, § 3º)" due={p.complementacao_prazo} left={null} status={null} />
        </div>
        <p className="mt-2 text-xs text-slate-500">
          {p.pequeno_porte === null
            ? 'Porte da empresa a definir: usando o prazo simples (o mais curto).'
            : p.pequeno_porte
              ? 'Agente de pequeno porte: prazos em dobro (art. 6º, § 8º; art. 9º, § 6º).'
              : 'Não é agente de pequeno porte: prazo simples.'}{' '}
          A contagem exclui o dia do conhecimento e pula fins de semana e feriados cadastrados (interpretação a validar com o jurídico).
        </p>
      </Card>

      {closed && (
        <Alert tone="success" title={`Encerrado em ${fmtDateTime(inc.closed_at)} por ${inc.closed_by_name ?? '—'}`}>
          {inc.closing_note}
        </Alert>
      )}

      <fieldset disabled={closed || busy} className="space-y-4">
        <Section n="I" title="Identificação e data de conhecimento">
          <Input label="Título" value={form.title} maxLength={200} onChange={(e) => set('title', e.target.value)} />
          <div className="grid gap-3 sm:grid-cols-3">
            <Input label="Conhecimento do incidente" type="datetime-local" value={form.known_at} onChange={(e) => set('known_at', e.target.value)} />
            <Input
              label="Soube que afetou dados pessoais"
              type="datetime-local"
              value={form.personal_data_known_at}
              onChange={(e) => set('personal_data_known_at', e.target.value)}
              hint="Início dos prazos de comunicação."
            />
            <Input label="Quando ocorreu (se souber)" type="datetime-local" value={form.occurred_at} onChange={(e) => set('occurred_at', e.target.value)} />
          </div>
          {!closed && (
            <Select label="Situação" value={form.status} onChange={(e) => set('status', e.target.value as Form['status'])}>
              <option value="aberto">Aberto</option>
              <option value="em_tratamento">Em tratamento</option>
            </Select>
          )}
        </Section>

        <Section n="II" title="Circunstâncias">
          <Textarea label="Descrição geral de como o incidente ocorreu" rows={4} maxLength={5000} value={form.description} onChange={(e) => set('description', e.target.value)} />
        </Section>

        <Section n="III" title="Natureza e categoria dos dados afetados">
          <Input
            label="Categorias (separe por vírgula)"
            value={form.data_categories}
            onChange={(e) => set('data_categories', e.target.value)}
            hint={`Sugestões: ${DATA_CATEGORY_SUGGESTIONS.join(', ')}.`}
          />
          <Textarea label="Natureza dos dados" rows={2} maxLength={5000} value={form.data_nature} onChange={(e) => set('data_nature', e.target.value)} />
          <Select label="Envolve dado sensível?" value={form.sensitive_data} onChange={(e) => set('sensitive_data', e.target.value as Form['sensitive_data'])}>
            <option value="">Não avaliado</option>
            <option value="sim">Sim</option>
            <option value="nao">Não</option>
          </Select>
        </Section>

        <Section n="IV" title="Titulares afetados">
          <div className="grid gap-3 sm:grid-cols-3">
            <Input label="Número de titulares" type="number" min={0} value={form.affected_count} onChange={(e) => set('affected_count', e.target.value)} />
            <div className="sm:col-span-2">
              <Input
                label="Observação (estimativa, quando não for exato)"
                value={form.affected_count_note}
                maxLength={5000}
                onChange={(e) => set('affected_count_note', e.target.value)}
              />
            </div>
          </div>
        </Section>

        <Section n="V" title="Avaliação do risco e possíveis danos">
          <div>
            <p className="mb-1 text-sm font-medium text-slate-700">Critérios do art. 5º presentes</p>
            <div className="grid gap-1 sm:grid-cols-2">
              {Object.entries(RISK_CRITERIA).map(([k, label]) => (
                <label key={k} className="flex items-center gap-2 text-sm text-slate-700">
                  <input
                    type="checkbox"
                    className="h-4 w-4 rounded border-slate-300"
                    checked={form.risk_criteria.includes(k)}
                    onChange={(e) => set('risk_criteria', e.target.checked ? [...form.risk_criteria, k] : form.risk_criteria.filter((x) => x !== k))}
                  />
                  {label}
                </label>
              ))}
            </div>
            <p className="mt-1 text-xs text-slate-500">
              A comunicação é obrigatória quando o incidente pode afetar significativamente interesses e direitos dos titulares E envolve ao menos um destes critérios.
            </p>
          </div>
          <Select label="Conclusão" value={form.risk_level} onChange={(e) => set('risk_level', e.target.value as Form['risk_level'])}>
            {Object.entries(RISK_LABEL).map(([k, v]) => (
              <option key={k} value={k}>
                {v}
              </option>
            ))}
          </Select>
          <Textarea label="Avaliação do risco e possíveis danos aos titulares" rows={3} maxLength={5000} value={form.risk_assessment} onChange={(e) => set('risk_assessment', e.target.value)} />
        </Section>

        <Section n="VI" title="Medidas de correção e mitigação">
          <Textarea label="Medidas adotadas" rows={3} maxLength={5000} value={form.measures} onChange={(e) => set('measures', e.target.value)} />
        </Section>

        <Section n="VII" title="Comunicação (se houve)">
          <div className="grid gap-3 sm:grid-cols-3">
            <Input label="Comunicado à ANPD em" type="datetime-local" value={form.anpd_communicated_at} onChange={(e) => set('anpd_communicated_at', e.target.value)} />
            <Input label="Protocolo da ANPD" value={form.anpd_protocol} maxLength={5000} onChange={(e) => set('anpd_protocol', e.target.value)} />
            <Input label="Comunicado aos titulares em" type="datetime-local" value={form.titulares_communicated_at} onChange={(e) => set('titulares_communicated_at', e.target.value)} />
          </div>
          <Input label="Forma da comunicação" value={form.communication_form} maxLength={5000} onChange={(e) => set('communication_form', e.target.value)} hint="Ex.: e-mail individual, aviso no mural, carta." />
          <Textarea label="Conteúdo da comunicação" rows={3} maxLength={5000} value={form.communication_content} onChange={(e) => set('communication_content', e.target.value)} />
        </Section>

        <Section n="VIII" title="Motivo da ausência de comunicação (quando for o caso)">
          <Textarea label="Por que não foi comunicado" rows={2} maxLength={5000} value={form.no_communication_reason} onChange={(e) => set('no_communication_reason', e.target.value)} />
        </Section>
      </fieldset>

      {!closed && (
        <div className="sticky bottom-0 z-10 flex flex-wrap justify-end gap-2 border-t border-slate-200 bg-white/95 py-3 backdrop-blur">
          <Button variant="secondary" onClick={() => setClosing(true)} disabled={busy || dirty}>
            Encerrar incidente
          </Button>
          <Button loading={busy} disabled={!dirty} onClick={() => void save()}>
            Salvar alterações
          </Button>
        </div>
      )}

      <Card>
        <CardHeader title="Histórico" subtitle="Anotações e alterações. Nada aqui é apagado." />
        <ul className="space-y-2">
          {(inc.notes ?? []).map((n) => (
            <li key={n.id} className="text-sm">
              <span className="text-xs text-slate-500">
                {fmtDateTime(n.created_at)} · {n.created_by_name ?? '—'}
              </span>
              <p className={clsx(n.kind === 'nota' ? 'text-slate-900' : 'text-slate-600')}>{n.body}</p>
            </li>
          ))}
        </ul>
        <div className="mt-3 flex flex-wrap items-end gap-2">
          <div className="min-w-0 flex-1">
            <Textarea label="Nova anotação" rows={2} maxLength={5000} value={note} onChange={(e) => setNote(e.target.value)} />
          </div>
          <Button variant="secondary" disabled={note.trim().length < 3 || busy} onClick={() => void sendNote()}>
            Anotar
          </Button>
        </div>
      </Card>

      <Modal
        open={closing}
        onClose={() => setClosing(false)}
        busy={busy}
        title="Encerrar incidente"
        description="O sistema confere se os itens obrigatórios do registro (art. 10, § 1º) estão preenchidos. Depois de encerrado, só é possível anotar."
        footer={
          <>
            <Button variant="secondary" onClick={() => setClosing(false)} disabled={busy}>
              Voltar
            </Button>
            <Button loading={busy} disabled={closingNote.trim().length < 10} onClick={() => void close()}>
              Encerrar
            </Button>
          </>
        }
      >
        <Textarea label="Resumo do encerramento" hint="Mínimo de 10 caracteres." rows={3} maxLength={2000} value={closingNote} onChange={(e) => setClosingNote(e.target.value)} />
      </Modal>
    </div>
  );
}

// ---------------------------------------------------------------------------
function ConfigTab({ settings, holidays, onChanged }: { settings: PrivacySettings; holidays: Holiday[]; onChanged: () => Promise<void> }) {
  const [f, setF] = useState({
    controller_name: settings.controller_name ?? '',
    controller_doc: settings.controller_doc ?? '',
    dpo_name: settings.dpo_name ?? '',
    dpo_contact: settings.dpo_contact ?? '',
    small_agent: settings.small_agent === null ? '' : settings.small_agent ? 'sim' : 'nao',
  });
  const [busy, setBusy] = useState(false);
  const [hDay, setHDay] = useState('');
  const [hName, setHName] = useState('');
  const [hScope, setHScope] = useState<Holiday['scope']>('municipal');

  async function save() {
    setBusy(true);
    try {
      await updatePrivacySettings({
        controller_name: f.controller_name,
        controller_doc: f.controller_doc,
        dpo_name: f.dpo_name,
        dpo_contact: f.dpo_contact,
        small_agent: f.small_agent === '' ? null : f.small_agent === 'sim',
      });
      toast.success('Configuração salva.');
      await onChanged();
    } catch (err) {
      toast.error(errorMessage(err));
    } finally {
      setBusy(false);
    }
  }
  async function addH() {
    setBusy(true);
    try {
      await addHoliday(hDay, hName.trim(), hScope);
      setHDay('');
      setHName('');
      await onChanged();
    } catch (err) {
      toast.error(errorMessage(err));
    } finally {
      setBusy(false);
    }
  }
  async function delH(day: string) {
    try {
      await removeHoliday(day);
      await onChanged();
    } catch (err) {
      toast.error(errorMessage(err));
    }
  }

  return (
    <div className="space-y-4">
      <Card>
        <CardHeader
          title="Agentes de tratamento"
          subtitle="Decisões da empresa (jurídico/diretoria). Deixe em branco o que ainda não foi decidido; nada é presumido."
        />
        <div className="grid gap-3 sm:grid-cols-2">
          <Input label="Controlador (razão social)" value={f.controller_name} maxLength={200} onChange={(e) => setF({ ...f, controller_name: e.target.value })} />
          <Input label="CNPJ do controlador" value={f.controller_doc} maxLength={40} onChange={(e) => setF({ ...f, controller_doc: e.target.value })} />
          <Input label="Encarregado (DPO)" value={f.dpo_name} maxLength={200} onChange={(e) => setF({ ...f, dpo_name: e.target.value })} />
          <Input label="Contato do encarregado" value={f.dpo_contact} maxLength={200} onChange={(e) => setF({ ...f, dpo_contact: e.target.value })} />
          <Select label="Agente de pequeno porte (Res. CD/ANPD 2/2022)?" value={f.small_agent} onChange={(e) => setF({ ...f, small_agent: e.target.value })}>
            <option value="">A definir (usa o prazo simples)</option>
            <option value="sim">Sim — prazos em dobro</option>
            <option value="nao">Não — prazo simples</option>
          </Select>
        </div>
        <div className="mt-3 flex items-center justify-between gap-2">
          <p className="text-xs text-slate-500">{settings.updated_by_name ? `Última alteração por ${settings.updated_by_name} em ${fmtDateTime(settings.updated_at)}.` : ''}</p>
          <Button loading={busy} onClick={() => void save()}>
            Salvar
          </Button>
        </div>
      </Card>

      <Card>
        <CardHeader
          title="Feriados (para contar dias úteis)"
          subtitle="Os nacionais de 2026 e 2027 já vêm cadastrados. Cadastre os feriados estaduais e municipais dos locais de trabalho."
        />
        <div className="grid gap-3 sm:grid-cols-4">
          <Input label="Data" type="date" value={hDay} onChange={(e) => setHDay(e.target.value)} />
          <div className="sm:col-span-2">
            <Input label="Nome" value={hName} maxLength={120} onChange={(e) => setHName(e.target.value)} />
          </div>
          <Select label="Abrangência" value={hScope} onChange={(e) => setHScope(e.target.value as Holiday['scope'])}>
            <option value="municipal">Municipal</option>
            <option value="estadual">Estadual</option>
            <option value="nacional">Nacional</option>
            <option value="empresa">Da empresa</option>
          </Select>
        </div>
        <div className="mt-2 flex justify-end">
          <Button variant="secondary" icon={<CalendarDays className="h-4 w-4" />} disabled={!hDay || hName.trim().length < 2 || busy} onClick={() => void addH()}>
            Cadastrar feriado
          </Button>
        </div>
        <ul className="mt-3 divide-y divide-slate-100 text-sm">
          {holidays.map((h) => (
            <li key={h.day} className="flex items-center gap-3 py-1.5">
              <span className="w-24 font-mono text-slate-600">{fmtDate(h.day)}</span>
              <span className="flex-1 text-slate-900">{h.name}</span>
              <span className="text-xs text-slate-500">{h.scope}</span>
              <button type="button" title={`Remover ${h.name}`} className="rounded p-1 text-slate-400 hover:bg-red-50 hover:text-red-600" onClick={() => void delH(h.day)}>
                <Trash2 className="h-4 w-4" />
              </button>
            </li>
          ))}
        </ul>
      </Card>
      <Alert tone="info" title="Lembrete">
        <AlertTriangle className="mr-1 inline h-4 w-4" />O registro aqui não substitui a comunicação oficial: a comunicação à ANPD é feita pelo formulário da própria ANPD.
        Registre aqui a data e o protocolo.
      </Alert>
    </div>
  );
}
