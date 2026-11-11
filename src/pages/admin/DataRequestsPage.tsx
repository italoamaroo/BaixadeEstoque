import { useCallback, useEffect, useState } from 'react';
import { useSearchParams } from 'react-router-dom';
import { CheckCircle2, Download, FileSearch, Plus, UserCheck } from 'lucide-react';
import { toast } from 'sonner';
import clsx from 'clsx';
import { Alert, Card, CardHeader, EmptyState, PageHeader } from '@/components/ui/Card';
import { Input, Select, Textarea } from '@/components/ui/Field';
import { Button } from '@/components/ui/Button';
import { Badge } from '@/components/ui/Badge';
import { Modal } from '@/components/ui/Modal';
import { PageLoader } from '@/components/ui/Spinner';
import { EmployeePicker } from '@/components/EmployeePicker';
import {
  addDsrNote,
  getDsr,
  getDsrEmployeeReport,
  getDsrOverview,
  openDsr,
  respondDsr,
  updateDsr,
  updatePrivacySettings,
  type DataSubjectRequest,
  type DsrEmployeeReport,
  type DsrOverview,
} from '@/lib/api';
import { errorMessage } from '@/lib/errors';
import { downloadBlob } from '@/lib/excel';
import { fmtDate, fmtDateTime } from '@/lib/format';
import type { Employee } from '@/types/db';

// Art. 18 da LGPD (I a IX) e oposição (§ 2º)
const RIGHTS: Record<string, string> = {
  confirmacao: 'Confirmação de que há tratamento (I)',
  acesso: 'Acesso aos dados (II)',
  correcao: 'Correção de dados (III)',
  anonimizacao_bloqueio_eliminacao: 'Anonimização, bloqueio ou eliminação de dados desnecessários (IV)',
  portabilidade: 'Portabilidade (V)',
  eliminacao_consentimento: 'Eliminação de dados tratados com consentimento (VI)',
  info_compartilhamento: 'Com quem os dados são compartilhados (VII)',
  info_nao_consentir: 'Possibilidade de não consentir (VIII)',
  revogacao_consentimento: 'Revogação do consentimento (IX)',
  oposicao: 'Oposição ao tratamento (§ 2º)',
};
const STATUS_LABEL: Record<DataSubjectRequest['status'], string> = {
  recebido: 'Recebido',
  em_analise: 'Em análise',
  atendido: 'Atendido',
  atendido_parcialmente: 'Atendido em parte',
  indeferido: 'Indeferido',
};
const STATUS_STYLE: Record<DataSubjectRequest['status'], string> = {
  recebido: 'bg-red-50 text-red-700 ring-red-300',
  em_analise: 'bg-amber-50 text-amber-800 ring-amber-300',
  atendido: 'bg-emerald-50 text-emerald-800 ring-emerald-300',
  atendido_parcialmente: 'bg-emerald-50 text-emerald-800 ring-emerald-300',
  indeferido: 'bg-slate-100 text-slate-700 ring-slate-300',
};
const DEADLINE: Record<DataSubjectRequest['situacao_prazo'], { label: string; cls: string }> = {
  pendente: { label: 'no prazo', cls: 'text-amber-700' },
  atrasado: { label: 'VENCIDO', cls: 'font-semibold text-red-700' },
  cumprido: { label: 'respondido no prazo', cls: 'text-emerald-700' },
  cumprido_com_atraso: { label: 'respondido com atraso', cls: 'text-red-700' },
};
const isOpen = (r: DataSubjectRequest) => r.status === 'recebido' || r.status === 'em_analise';

function toLocalInput(iso: string) {
  const d = new Date(iso);
  return new Date(d.getTime() - d.getTimezoneOffset() * 60000).toISOString().slice(0, 16);
}

async function downloadReport(rep: DsrEmployeeReport) {
  const ExcelJS = (await import('exceljs')).default;
  const wb = new ExcelJS.Workbook();
  const s1 = wb.addWorksheet('Cadastro');
  s1.columns = [
    { header: 'Campo', key: 'k', width: 28 },
    { header: 'Valor', key: 'v', width: 60 },
  ];
  const c = rep.cadastro;
  [
    ['Matrícula', c.matricula],
    ['Nome', c.nome],
    ['Cargo', c.cargo ?? ''],
    ['Setor', c.setor ?? ''],
    ['Ativo', c.ativo ? 'sim' : 'não'],
    ['Cadastrado em', fmtDateTime(c.cadastrado_em)],
    ['Atualizado em', fmtDateTime(c.atualizado_em)],
    ['Retiradas registradas', String(rep.retiradas.length)],
    ['Assinaturas guardadas', String(rep.assinaturas)],
    ['Fotos guardadas', String(rep.fotos)],
    ['Relatório gerado em', fmtDateTime(rep.gerado_em)],
    ['Pedido', rep.pedido ?? ''],
  ].forEach(([k, v]) => s1.addRow({ k, v }));
  rep.observacoes.forEach((o) => s1.addRow({ k: 'Observação', v: o }));
  s1.getRow(1).font = { bold: true };
  const s2 = wb.addWorksheet('Retiradas');
  s2.columns = [
    { header: 'ME', key: 'me', width: 22 },
    { header: 'Data', key: 'data', width: 18 },
    { header: 'Estoque', key: 'estoque', width: 22 },
    { header: 'Situação', key: 'situacao', width: 20 },
    { header: 'Emergencial', key: 'emergencial', width: 12 },
    { header: 'Itens', key: 'itens', width: 8 },
    { header: 'Assinatura', key: 'assinatura', width: 12 },
    { header: 'Foto', key: 'foto', width: 8 },
  ];
  rep.retiradas.forEach((r) =>
    s2.addRow({ ...r, emergencial: r.emergencial ? 'sim' : 'não', assinatura: r.assinatura ? 'sim' : 'não', foto: r.foto ? 'sim' : 'não' }),
  );
  s2.getRow(1).font = { bold: true };
  const buf = await wb.xlsx.writeBuffer();
  downloadBlob(
    new Blob([buf], { type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' }),
    `dados-do-titular-${c.matricula}-${rep.gerado_em.slice(0, 10)}.xlsx`,
  );
}

export function DataRequestsPage() {
  const [params, setParams] = useSearchParams();
  const [data, setData] = useState<DsrOverview | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [creating, setCreating] = useState(false);
  const [config, setConfig] = useState(false);
  const selectedId = Number(params.get('id')) || null;

  const load = useCallback(async () => {
    try {
      setError(null);
      setData(await getDsrOverview());
    } catch (err) {
      setError(errorMessage(err));
    }
  }, []);
  useEffect(() => {
    void load();
  }, [load]);

  if (error) return <Alert tone="error" title="Não foi possível carregar os pedidos">{error}</Alert>;
  if (!data) return <PageLoader />;
  const s = data.settings;

  return (
    <div className="space-y-4">
      <PageHeader
        title="Pedidos de titulares"
        subtitle="Pedidos dos colaboradores sobre os próprios dados (LGPD, art. 18): registro, conferência de identidade, prazo e resposta."
        actions={
          <div className="flex flex-wrap gap-2">
            <Button variant="secondary" onClick={() => setConfig(true)}>
              Canal e prazo
            </Button>
            <Button icon={<Plus className="h-4 w-4" />} onClick={() => setCreating(true)}>
              Registrar pedido
            </Button>
          </div>
        }
      />
      {!s.titular_channel && (
        <Alert tone="warning" title="Canal de atendimento a definir">
          A empresa ainda não definiu por onde o colaborador faz o pedido (decisão D6). Enquanto isso, registre aqui os pedidos que chegarem por qualquer meio.{' '}
          <button type="button" className="font-medium underline" onClick={() => setConfig(true)}>
            Definir canal
          </button>
        </Alert>
      )}

      {selectedId ? (
        <RequestDetail
          id={selectedId}
          onBack={() => {
            params.delete('id');
            setParams(params);
            void load();
          }}
        />
      ) : (
        <RequestList requests={data.requests} days={s.titular_response_days} channel={s.titular_channel} onOpen={(id) => setParams({ id: String(id) })} />
      )}

      <NewRequestModal
        open={creating}
        defaultChannel={s.titular_channel ?? ''}
        onClose={() => setCreating(false)}
        onCreated={(id) => {
          setCreating(false);
          setParams({ id: String(id) });
          void load();
        }}
      />
      <ConfigModal open={config} settings={s} onClose={() => setConfig(false)} onSaved={load} />
    </div>
  );
}

// ---------------------------------------------------------------------------
function RequestList({ requests, days, channel, onOpen }: { requests: DataSubjectRequest[]; days: number; channel: string | null; onOpen: (id: number) => void }) {
  return (
    <>
      <p className="text-sm text-slate-600">
        Prazo de resposta: <strong>{days} dias corridos</strong> a partir do pedido · Canal: <strong>{channel ?? 'a definir'}</strong>
      </p>
      {!requests.length ? (
        <Card>
          <EmptyState icon={<CheckCircle2 className="h-8 w-8 text-emerald-600" />} title="Nenhum pedido registrado" description="Quando um colaborador pedir algo sobre os próprios dados, registre aqui." />
        </Card>
      ) : (
        <Card padded={false}>
          <ul className="divide-y divide-slate-100">
            {requests.map((r) => (
              <li key={r.id}>
                <button type="button" onClick={() => onOpen(r.id)} className="flex w-full flex-wrap items-start gap-3 px-4 py-3 text-left hover:bg-slate-50">
                  <UserCheck className={clsx('mt-0.5 h-5 w-5 shrink-0', isOpen(r) ? (r.situacao_prazo === 'atrasado' ? 'text-red-600' : 'text-amber-600') : 'text-slate-400')} />
                  <div className="min-w-0 flex-1">
                    <div className="flex flex-wrap items-center gap-2">
                      <span className="font-mono text-sm text-slate-500">{r.code}</span>
                      <span className="font-medium text-slate-900">{r.requester_name}</span>
                      <Badge className={STATUS_STYLE[r.status]}>{STATUS_LABEL[r.status]}</Badge>
                    </div>
                    <p className="mt-0.5 text-xs text-slate-500">{r.rights.map((x) => RIGHTS[x]?.replace(/ \(.*\)$/, '') ?? x).join(' · ')}</p>
                    <p className={clsx('mt-0.5 text-xs', DEADLINE[r.situacao_prazo].cls)}>
                      Recebido em {fmtDate(r.received_at)} · responder até {fmtDate(r.due_date)} ({DEADLINE[r.situacao_prazo].label}
                      {r.dias_restantes !== null && r.situacao_prazo === 'pendente' && `, ${r.dias_restantes} dia${r.dias_restantes === 1 ? '' : 's'}`})
                    </p>
                  </div>
                </button>
              </li>
            ))}
          </ul>
        </Card>
      )}
    </>
  );
}

// ---------------------------------------------------------------------------
function RightsChecklist({ value, onChange }: { value: string[]; onChange: (v: string[]) => void }) {
  return (
    <div>
      <p className="mb-1 text-sm font-medium text-slate-700">Direitos pedidos</p>
      <div className="grid gap-1">
        {Object.entries(RIGHTS).map(([k, label]) => (
          <label key={k} className="flex items-center gap-2 text-sm text-slate-700">
            <input
              type="checkbox"
              className="h-4 w-4 rounded border-slate-300"
              checked={value.includes(k)}
              onChange={(e) => onChange(e.target.checked ? [...value, k] : value.filter((x) => x !== k))}
            />
            {label}
          </label>
        ))}
      </div>
    </div>
  );
}

function NewRequestModal({ open, defaultChannel, onClose, onCreated }: { open: boolean; defaultChannel: string; onClose: () => void; onCreated: (id: number) => void }) {
  const [employee, setEmployee] = useState<Employee | null>(null);
  const [name, setName] = useState('');
  const [registration, setRegistration] = useState('');
  const [rights, setRights] = useState<string[]>([]);
  const [channel, setChannel] = useState('');
  const [receivedAt, setReceivedAt] = useState('');
  const [description, setDescription] = useState('');
  const [busy, setBusy] = useState(false);
  useEffect(() => {
    if (open) {
      setEmployee(null);
      setName('');
      setRegistration('');
      setRights([]);
      setChannel(defaultChannel);
      setReceivedAt(toLocalInput(new Date().toISOString()));
      setDescription('');
    }
  }, [open, defaultChannel]);
  useEffect(() => {
    if (employee) {
      setName(employee.full_name);
      setRegistration(employee.registration);
    }
  }, [employee]);

  async function save() {
    setBusy(true);
    try {
      const id = await openDsr({
        requester_name: name.trim(),
        requester_registration: registration.trim() || undefined,
        employee_id: employee?.id ?? null,
        rights,
        channel: channel.trim() || undefined,
        description: description.trim() || undefined,
        received_at: receivedAt ? new Date(receivedAt).toISOString() : undefined,
      });
      toast.success('Pedido registrado.');
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
      title="Registrar pedido de titular"
      footer={
        <>
          <Button variant="secondary" onClick={onClose} disabled={busy}>
            Voltar
          </Button>
          <Button loading={busy} disabled={name.trim().length < 3 || !rights.length} onClick={() => void save()}>
            Registrar
          </Button>
        </>
      }
    >
      <div className="space-y-3">
        <EmployeePicker label="Funcionário (se for do cadastro)" value={employee} onChange={setEmployee} />
        <div className="grid gap-3 sm:grid-cols-2">
          <Input label="Nome de quem pediu" value={name} maxLength={160} onChange={(e) => setName(e.target.value)} />
          <Input label="Matrícula (se tiver)" value={registration} maxLength={30} onChange={(e) => setRegistration(e.target.value)} />
          <Input label="Recebido em" type="datetime-local" value={receivedAt} onChange={(e) => setReceivedAt(e.target.value)} hint="O prazo conta desta data." />
          <Input label="Canal" value={channel} maxLength={200} onChange={(e) => setChannel(e.target.value)} hint="Ex.: e-mail, RH, presencial." />
        </div>
        <RightsChecklist value={rights} onChange={setRights} />
        <Textarea label="O que foi pedido (opcional)" rows={3} maxLength={5000} value={description} onChange={(e) => setDescription(e.target.value)} />
      </div>
    </Modal>
  );
}

function ConfigModal({ open, settings, onClose, onSaved }: { open: boolean; settings: DsrOverview['settings']; onClose: () => void; onSaved: () => Promise<void> }) {
  const [channel, setChannel] = useState('');
  const [days, setDays] = useState('15');
  const [busy, setBusy] = useState(false);
  useEffect(() => {
    if (open) {
      setChannel(settings.titular_channel ?? '');
      setDays(String(settings.titular_response_days));
    }
  }, [open, settings]);
  async function save() {
    setBusy(true);
    try {
      await updatePrivacySettings({ titular_channel: channel.trim() || null, titular_response_days: Number(days) });
      toast.success('Canal e prazo salvos.');
      onClose();
      await onSaved();
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
      title="Canal e prazo de atendimento"
      description="Decisão da empresa (D6). O prazo vale para os pedidos registrados depois da mudança."
      footer={
        <>
          <Button variant="secondary" onClick={onClose} disabled={busy}>
            Voltar
          </Button>
          <Button loading={busy} disabled={!(Number(days) >= 1 && Number(days) <= 90)} onClick={() => void save()}>
            Salvar
          </Button>
        </>
      }
    >
      <div className="space-y-3">
        <Input label="Canal para os pedidos" value={channel} maxLength={300} onChange={(e) => setChannel(e.target.value)} hint="Ex.: e-mail do encarregado, formulário do RH. Em branco = a definir." />
        <Input
          label="Prazo de resposta (dias corridos)"
          type="number"
          min={1}
          max={90}
          value={days}
          onChange={(e) => setDays(e.target.value)}
          hint="Padrão de 15 dias: referência do art. 19, II (confirmação e acesso completos). Para os demais direitos não há prazo regulamentado; valide com o jurídico."
        />
      </div>
    </Modal>
  );
}

// ---------------------------------------------------------------------------
function RequestDetail({ id, onBack }: { id: number; onBack: () => void }) {
  const [r, setR] = useState<DataSubjectRequest | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [rights, setRights] = useState<string[]>([]);
  const [verified, setVerified] = useState(false);
  const [method, setMethod] = useState('');
  const [employee, setEmployee] = useState<Employee | null>(null);
  const [report, setReport] = useState<DsrEmployeeReport | null>(null);
  const [note, setNote] = useState('');
  const [responding, setResponding] = useState(false);
  const [outcome, setOutcome] = useState<'atendido' | 'atendido_parcialmente' | 'indeferido'>('atendido');
  const [summary, setSummary] = useState('');
  const [denial, setDenial] = useState('');

  const load = useCallback(async () => {
    try {
      const x = await getDsr(id);
      setR(x);
      setRights(x.rights);
      setVerified(x.identity_verified);
      setMethod(x.identity_method ?? '');
      setEmployee(x.employee ? ({ ...x.employee, job_title: null, sector_id: null, active: true } as Employee) : null);
    } catch (err) {
      setError(errorMessage(err));
    }
  }, [id]);
  useEffect(() => {
    void load();
  }, [load]);

  if (error) return <Alert tone="error" title="Não foi possível abrir o pedido">{error}</Alert>;
  if (!r) return <PageLoader />;
  const open = isOpen(r);
  const dirty =
    JSON.stringify([...rights].sort()) !== JSON.stringify([...r.rights].sort()) ||
    verified !== r.identity_verified ||
    method !== (r.identity_method ?? '') ||
    (employee?.id ?? null) !== r.employee_id;

  async function run(fn: () => Promise<unknown>, ok?: string) {
    setBusy(true);
    try {
      await fn();
      if (ok) toast.success(ok);
      await load();
    } catch (err) {
      toast.error(errorMessage(err));
    } finally {
      setBusy(false);
    }
  }
  async function genReport() {
    if (!employee) return;
    setBusy(true);
    try {
      const rep = await getDsrEmployeeReport(employee.id, r!.id);
      setReport(rep);
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
        <span className="font-mono text-sm text-slate-500">{r.code}</span>
        <Badge className={STATUS_STYLE[r.status]}>{STATUS_LABEL[r.status]}</Badge>
      </div>

      <Card>
        <CardHeader title={r.requester_name} subtitle={`${r.requester_registration ? `Matrícula ${r.requester_registration} · ` : ''}canal: ${r.channel ?? 'não informado'}`} />
        <p className={clsx('text-sm', DEADLINE[r.situacao_prazo].cls)}>
          Recebido em {fmtDateTime(r.received_at)} · responder até <strong>{fmtDate(r.due_date)}</strong> ({DEADLINE[r.situacao_prazo].label}
          {r.dias_restantes !== null && r.situacao_prazo === 'pendente' && `, ${r.dias_restantes} dia${r.dias_restantes === 1 ? '' : 's'}`})
        </p>
        {r.description && <p className="mt-2 whitespace-pre-wrap text-sm text-slate-700">{r.description}</p>}
      </Card>

      {!open && (
        <Alert tone={r.status === 'indeferido' ? 'warning' : 'success'} title={`${STATUS_LABEL[r.status]} em ${fmtDateTime(r.responded_at)}`}>
          {r.response_summary}
          {r.denial_reason && (
            <>
              <br />
              <strong>Motivo:</strong> {r.denial_reason}
            </>
          )}
        </Alert>
      )}

      <fieldset disabled={!open || busy} className="space-y-4">
        <Card>
          <CardHeader title="Pedido e identidade" subtitle="Antes de responder, confira que quem pediu é o próprio titular." />
          <div className="space-y-3">
            <RightsChecklist value={rights} onChange={setRights} />
            <EmployeePicker label="Funcionário do cadastro" value={employee} onChange={setEmployee} />
            <label className="flex items-center gap-2 text-sm font-medium text-slate-700">
              <input type="checkbox" className="h-4 w-4 rounded border-slate-300" checked={verified} onChange={(e) => setVerified(e.target.checked)} />
              Identidade conferida
            </label>
            <Input label="Como a identidade foi conferida" value={method} maxLength={500} onChange={(e) => setMethod(e.target.value)} hint="Ex.: crachá conferido pelo RH, e-mail corporativo do próprio titular." />
            {open && (
              <div className="flex justify-end">
                <Button
                  disabled={!dirty || !rights.length}
                  loading={busy}
                  onClick={() =>
                    void run(
                      () =>
                        updateDsr(r.id, {
                          rights,
                          identity_verified: verified,
                          identity_method: method.trim() || null,
                          employee_id: employee?.id ?? null,
                          ...(r.status === 'recebido' ? { status: 'em_analise' } : {}),
                        }),
                      'Pedido salvo.',
                    )
                  }
                >
                  Salvar
                </Button>
              </div>
            )}
          </div>
        </Card>
      </fieldset>

      <Card>
        <CardHeader
          title="Dados que o sistema guarda sobre o titular"
          subtitle="Apoio ao direito de acesso: cadastro, retiradas, assinaturas e fotos. A geração fica registrada na auditoria."
          actions={
            <Button variant="secondary" icon={<FileSearch className="h-4 w-4" />} disabled={!r.employee_id || busy} onClick={() => void genReport()}>
              Gerar relatório
            </Button>
          }
        />
        {!r.employee_id && <p className="text-sm text-slate-500">Vincule o pedido a um funcionário do cadastro (e salve) para gerar o relatório.</p>}
        {report && (
          <div className="space-y-2 text-sm">
            <p>
              <strong>{report.cadastro.nome}</strong> · matrícula {report.cadastro.matricula}
              {report.cadastro.cargo && ` · ${report.cadastro.cargo}`}
              {report.cadastro.setor && ` · ${report.cadastro.setor}`}
            </p>
            <p>
              {report.retiradas.length} retirada(s) registrada(s) · {report.assinaturas} assinatura(s) · {report.fotos} foto(s)
            </p>
            <ul className="list-disc pl-5 text-slate-600">
              {report.observacoes.map((o) => (
                <li key={o}>{o}</li>
              ))}
            </ul>
            <Button size="sm" icon={<Download className="h-4 w-4" />} onClick={() => void downloadReport(report)}>
              Baixar relatório (Excel)
            </Button>
          </div>
        )}
      </Card>

      {open && (
        <div className="flex justify-end">
          <Button disabled={busy || dirty} onClick={() => setResponding(true)}>
            Registrar resposta
          </Button>
        </div>
      )}

      <Card>
        <CardHeader title="Histórico" subtitle="Nada aqui é apagado." />
        <ul className="space-y-2">
          {(r.notes ?? []).map((n) => (
            <li key={n.id} className="text-sm">
              <span className="text-xs text-slate-500">
                {fmtDateTime(n.created_at)} · {n.created_by_name ?? '—'}
              </span>
              <p className={n.kind === 'nota' ? 'text-slate-900' : 'text-slate-600'}>{n.body}</p>
            </li>
          ))}
        </ul>
        <div className="mt-3 flex flex-wrap items-end gap-2">
          <div className="min-w-0 flex-1">
            <Textarea label="Nova anotação" rows={2} maxLength={5000} value={note} onChange={(e) => setNote(e.target.value)} />
          </div>
          <Button
            variant="secondary"
            disabled={note.trim().length < 3 || busy}
            onClick={() =>
              void run(async () => {
                await addDsrNote(r.id, note.trim());
                setNote('');
              })
            }
          >
            Anotar
          </Button>
        </div>
      </Card>

      <Modal
        open={responding}
        onClose={() => setResponding(false)}
        busy={busy}
        title="Registrar resposta ao titular"
        description="Registre aqui a resposta já enviada ao titular pelo canal combinado."
        footer={
          <>
            <Button variant="secondary" onClick={() => setResponding(false)} disabled={busy}>
              Voltar
            </Button>
            <Button
              loading={busy}
              disabled={summary.trim().length < 10 || (outcome !== 'atendido' && denial.trim().length < 10)}
              onClick={() =>
                void run(async () => {
                  await respondDsr(r.id, outcome, summary.trim(), outcome === 'atendido' ? null : denial.trim());
                  setResponding(false);
                }, 'Resposta registrada.')
              }
            >
              Registrar
            </Button>
          </>
        }
      >
        <div className="space-y-3">
          {!r.identity_verified && <Alert tone="warning">A identidade ainda não foi conferida: o sistema não aceita a resposta sem isso.</Alert>}
          <Select label="Resultado" value={outcome} onChange={(e) => setOutcome(e.target.value as typeof outcome)}>
            <option value="atendido">Atendido</option>
            <option value="atendido_parcialmente">Atendido em parte</option>
            <option value="indeferido">Indeferido</option>
          </Select>
          <Textarea label="Resumo da resposta dada" rows={3} maxLength={5000} value={summary} onChange={(e) => setSummary(e.target.value)} />
          {outcome !== 'atendido' && (
            <Textarea
              label="Motivo de não atender (art. 18, § 4º)"
              rows={2}
              maxLength={5000}
              value={denial}
              onChange={(e) => setDenial(e.target.value)}
              hint="Ex.: registro de saída finalizado não pode ser apagado (prova da movimentação)."
            />
          )}
        </div>
      </Modal>
    </div>
  );
}
