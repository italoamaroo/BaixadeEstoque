import { useCallback, useEffect, useRef, useState } from 'react';
import { Link } from 'react-router-dom';
import { ChevronDown, ChevronRight, Download, FileClock, Link2, Search, ShieldCheck, Stamp, Upload } from 'lucide-react';
import { toast } from 'sonner';
import { Alert, Card, CardHeader, EmptyState, PageHeader } from '@/components/ui/Card';
import { Input, Select, Textarea } from '@/components/ui/Field';
import { Button } from '@/components/ui/Button';
import { Badge } from '@/components/ui/Badge';
import { Modal } from '@/components/ui/Modal';
import { Pagination } from '@/components/ui/Pagination';
import { PageLoader } from '@/components/ui/Spinner';
import { useAuth } from '@/contexts/AuthContext';
import {
  checkAuditAnchor,
  createAuditAnchor,
  exportAudit,
  listAudit,
  listProfiles,
  verifyAuditChain,
  type AuditChainResult,
  type AuditQuery,
  type ProfileName,
} from '@/lib/api';
import {
  AUDIT_ACTION_LABELS,
  AUDIT_CATEGORY_LABELS,
  AUDIT_RESULT_LABELS,
  AUDIT_SEVERITY_LABELS,
  ENTITY_LABELS,
  auditLabel,
} from '@/lib/constants';
import { downloadBlob } from '@/lib/excel';
import { errorMessage } from '@/lib/errors';
import { fmtDateTime } from '@/lib/format';
import type { AuditLog } from '@/types/db';

const PAGE_SIZE = 50;

const PROBLEMS: Record<string, string> = {
  conteudo_alterado: 'o conteúdo de um evento foi alterado',
  evento_removido: 'um evento foi removido',
  encadeamento_quebrado: 'o encadeamento entre eventos foi quebrado',
  sem_hash: 'há evento sem hash',
  hash_diferente_da_ancora: 'o hash atual é diferente do guardado na âncora',
};

function isoDay(d: Date) {
  return new Date(d.getTime() - d.getTimezoneOffset() * 60000).toISOString().slice(0, 10);
}

function defaultFilters(): Omit<AuditQuery, 'page' | 'pageSize'> {
  const today = new Date();
  return {
    dateFrom: isoDay(new Date(today.getTime() - 30 * 864e5)),
    dateTo: isoDay(today),
    action: '',
    entity: '',
    userId: '',
    search: '',
    category: '',
    result: '',
    severity: '',
    correlationId: '',
  };
}

function Diff({ log }: { log: AuditLog }) {
  const keys = Array.from(new Set([...Object.keys(log.new_data ?? {}), ...Object.keys(log.old_data ?? {})])).filter((k) => !['updated_at', 'updated_by'].includes(k));
  if (!keys.length) return <p className="text-xs text-slate-500">Sem detalhes.</p>;
  const show = (v: unknown) => (v === null || v === undefined ? '—' : typeof v === 'object' ? JSON.stringify(v) : String(v));
  return (
    <table className="text-xs">
      <tbody>
        {keys.map((k) => (
          <tr key={k} className="align-top">
            <td className="pr-4 font-mono text-slate-500">{k}</td>
            {log.old_data && <td className="max-w-xs break-all pr-4 text-red-700">{show(log.old_data[k])}</td>}
            <td className="max-w-xs break-all text-emerald-700">{show(log.new_data?.[k])}</td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}

function SeverityBadge({ s }: { s?: string | null }) {
  if (!s || s === 'info') return null;
  return <Badge className={s === 'critico' ? 'bg-red-50 text-red-700 ring-red-200' : 'bg-amber-50 text-amber-800 ring-amber-200'}>{AUDIT_SEVERITY_LABELS[s] ?? s}</Badge>;
}

function ResultBadge({ r }: { r?: string }) {
  if (!r || r === 'sucesso') return null;
  return <Badge className="bg-red-600 text-white ring-red-600">{AUDIT_RESULT_LABELS[r] ?? r}</Badge>;
}

function chainMessage(r: AuditChainResult): string {
  if (r.ok) return `Íntegro: ${r.checked ?? 0} evento(s) conferido(s).`;
  return `Problema encontrado: ${PROBLEMS[r.problem ?? ''] ?? r.problem} (sequência ${r.problem_seq ?? '?'}).`;
}

/** Painel do administrador: verificação, âncora (guardar fora do Supabase) e conferência. */
function IntegrityPanel() {
  const [busy, setBusy] = useState<string | null>(null);
  const [result, setResult] = useState<{ tone: 'success' | 'error'; text: string } | null>(null);
  const fileRef = useRef<HTMLInputElement>(null);

  const run = async (kind: string, fn: () => Promise<void>) => {
    setBusy(kind);
    setResult(null);
    try {
      await fn();
    } catch (e) {
      setResult({ tone: 'error', text: errorMessage(e) });
    } finally {
      setBusy(null);
    }
  };

  const verify = () =>
    run('verify', async () => {
      const r = await verifyAuditChain();
      setResult({ tone: r.ok ? 'success' : 'error', text: chainMessage(r) });
    });

  const anchor = () =>
    run('anchor', async () => {
      const r = await createAuditAnchor();
      if (!r.ok) {
        setResult({ tone: 'error', text: `Âncora não gerada. ${chainMessage(r)}` });
        return;
      }
      const when = r.generated_at ? new Date(r.generated_at) : new Date();
      const text = [
        'ÂNCORA DA AUDITORIA — Baixas de Estoque',
        `gerada_em: ${when.toISOString()}`,
        `sequencia: ${r.last_seq}`,
        `hash: ${r.last_hash}`,
        `eventos_conferidos: ${r.checked}`,
        '',
        'Guarde este arquivo FORA do Supabase (e-mail da TI, pasta de rede).',
        'Para conferir depois: Auditoria > Conferir âncora salva.',
      ].join('\n');
      downloadBlob(new Blob([text], { type: 'text/plain;charset=utf-8' }), `ancora-auditoria-${isoDay(when)}-seq${r.last_seq}.txt`);
      setResult({ tone: 'success', text: `Âncora gerada (sequência ${r.last_seq}). O arquivo foi baixado: guarde-o fora do Supabase.` });
    });

  const check = (file: File | undefined) =>
    file &&
    run('check', async () => {
      const text = await file.text();
      const seq = Number(/sequencia:\s*(\d+)/i.exec(text)?.[1]);
      const hash = /hash:\s*([0-9a-f]{64})/i.exec(text)?.[1];
      if (!seq || !hash) throw new Error('Arquivo de âncora inválido: não encontrei a sequência e o hash.');
      const r = await checkAuditAnchor(seq, hash.toLowerCase());
      setResult({
        tone: r.ok ? 'success' : 'error',
        text: r.ok ? `A âncora confere: nada foi alterado ou removido até a sequência ${seq}.` : `A âncora NÃO confere: ${PROBLEMS[r.problem ?? ''] ?? r.problem}.`,
      });
    });

  return (
    <Card className="mb-4">
      <CardHeader
        title={
          <span className="flex items-center gap-2">
            <ShieldCheck className="h-5 w-5 text-slate-500" /> Integridade da auditoria
          </span>
        }
        subtitle="Cada evento leva o hash do anterior. Gere uma âncora periodicamente e guarde o arquivo fora do Supabase: só assim é possível provar que nada foi reescrito."
      />
      <div className="flex flex-wrap gap-2">
        <Button variant="secondary" icon={<ShieldCheck className="h-4 w-4" />} loading={busy === 'verify'} disabled={Boolean(busy)} onClick={() => void verify()}>
          Verificar integridade
        </Button>
        <Button variant="secondary" icon={<Stamp className="h-4 w-4" />} loading={busy === 'anchor'} disabled={Boolean(busy)} onClick={() => void anchor()}>
          Gerar âncora (baixar)
        </Button>
        <Button variant="secondary" icon={<Upload className="h-4 w-4" />} loading={busy === 'check'} disabled={Boolean(busy)} onClick={() => fileRef.current?.click()}>
          Conferir âncora salva
        </Button>
        <input
          ref={fileRef}
          type="file"
          accept=".txt,text/plain"
          className="hidden"
          onChange={(e) => {
            void check(e.target.files?.[0]);
            e.target.value = '';
          }}
        />
      </div>
      {result && (
        <div className="mt-3">
          <Alert tone={result.tone}>{result.text}</Alert>
        </div>
      )}
    </Card>
  );
}

export function AuditPage() {
  const { hasRole } = useAuth();
  const isAdmin = hasRole('admin');
  const [profiles, setProfiles] = useState<ProfileName[]>([]);
  const [draft, setDraft] = useState(defaultFilters);
  const [q, setQ] = useState(draft);
  const [page, setPage] = useState(1);
  const [rows, setRows] = useState<AuditLog[]>([]);
  const [total, setTotal] = useState(0);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [open, setOpen] = useState<number | null>(null);
  const [exportOpen, setExportOpen] = useState(false);
  const [reason, setReason] = useState('');
  const [exporting, setExporting] = useState(false);
  const seq = useRef(0);

  useEffect(() => {
    listProfiles().then(setProfiles).catch(() => undefined);
  }, []);

  const load = useCallback(async () => {
    const my = ++seq.current;
    setLoading(true);
    try {
      const r = await listAudit({ ...q, page, pageSize: PAGE_SIZE });
      if (my !== seq.current) return;
      setRows(r.rows);
      setTotal(r.total);
      setError(null);
    } catch (err) {
      if (my === seq.current) setError(errorMessage(err));
    } finally {
      if (my === seq.current) setLoading(false);
    }
  }, [q, page]);

  useEffect(() => {
    void load();
  }, [load]);

  const names = Object.fromEntries(profiles.map((p) => [p.id, p.full_name]));
  const set = (k: keyof typeof draft, v: string) => setDraft((d) => ({ ...d, [k]: v }));
  const apply = (next: typeof draft) => {
    setPage(1);
    setDraft(next);
    setQ(next);
  };

  const doExport = async () => {
    setExporting(true);
    try {
      const data = await exportAudit(q, reason.trim());
      const ExcelJS = (await import('exceljs')).default;
      const wb = new ExcelJS.Workbook();
      const ws = wb.addWorksheet('auditoria');
      ws.columns = [
        { header: 'Data/hora', key: 'when', width: 20 },
        { header: 'Sequência', key: 'seq', width: 10 },
        { header: 'Evento', key: 'action', width: 34 },
        { header: 'Categoria', key: 'category', width: 16 },
        { header: 'Criticidade', key: 'severity', width: 12 },
        { header: 'Resultado', key: 'result', width: 10 },
        { header: 'Usuário', key: 'user', width: 26 },
        { header: 'Entidade', key: 'entity', width: 18 },
        { header: 'ID do registro', key: 'entity_id', width: 38 },
        { header: 'Justificativa', key: 'justification', width: 40 },
        { header: 'Correlação', key: 'corr', width: 38 },
        { header: 'IP', key: 'ip', width: 16 },
      ];
      for (const r of data) {
        ws.addRow({
          when: fmtDateTime(r.occurred_at),
          seq: r.chain_seq ?? '',
          action: auditLabel(r.action),
          category: AUDIT_CATEGORY_LABELS[r.category ?? ''] ?? r.category ?? '',
          severity: AUDIT_SEVERITY_LABELS[r.severity ?? ''] ?? '',
          result: AUDIT_RESULT_LABELS[r.result ?? ''] ?? '',
          user: r.user_id ? (r.user_name ?? names[r.user_id] ?? r.user_id) : 'Sistema',
          entity: ENTITY_LABELS[r.entity] ?? r.entity,
          entity_id: r.entity_id ?? '',
          justification: r.justification ?? '',
          corr: r.correlation_id ?? '',
          ip: r.ip_address ?? '',
        });
      }
      ws.getRow(1).font = { bold: true };
      const buf = await wb.xlsx.writeBuffer();
      downloadBlob(new Blob([buf], { type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' }), `auditoria-${q.dateFrom}-a-${q.dateTo}.xlsx`);
      toast.success(`${data.length} evento(s) exportado(s). A exportação foi registrada na auditoria.`);
      setExportOpen(false);
      setReason('');
    } catch (err) {
      toast.error(errorMessage(err));
    } finally {
      setExporting(false);
    }
  };

  return (
    <div>
      <PageHeader
        title="Auditoria"
        subtitle="Trilha imutável: quem fez, quando, o que mudou e com qual resultado. Nomes e matrículas ficam mascarados; cada consulta e exportação também é registrada."
        actions={
          isAdmin ? (
            <Button variant="secondary" icon={<Download className="h-4 w-4" />} onClick={() => setExportOpen(true)}>
              Exportar
            </Button>
          ) : undefined
        }
      />

      {isAdmin && <IntegrityPanel />}

      <form
        className="mb-4 grid gap-3 rounded-xl border border-slate-200 bg-white p-4 shadow-card sm:grid-cols-3 lg:grid-cols-6"
        onSubmit={(e) => {
          e.preventDefault();
          apply(draft);
        }}
      >
        <Input label="De" type="date" required value={draft.dateFrom} onChange={(e) => set('dateFrom', e.target.value)} />
        <Input label="Até" type="date" required value={draft.dateTo} onChange={(e) => set('dateTo', e.target.value)} hint="Até 366 dias" />
        <Select label="Categoria" value={draft.category} onChange={(e) => set('category', e.target.value)}>
          <option value="">Todas</option>
          {Object.entries(AUDIT_CATEGORY_LABELS).map(([k, v]) => (
            <option key={k} value={k}>
              {v}
            </option>
          ))}
        </Select>
        <Select label="Resultado" value={draft.result} onChange={(e) => set('result', e.target.value)}>
          <option value="">Todos</option>
          {Object.entries(AUDIT_RESULT_LABELS).map(([k, v]) => (
            <option key={k} value={k}>
              {v}
            </option>
          ))}
        </Select>
        <Select label="Criticidade" value={draft.severity} onChange={(e) => set('severity', e.target.value)}>
          <option value="">Todas</option>
          {Object.entries(AUDIT_SEVERITY_LABELS).map(([k, v]) => (
            <option key={k} value={k}>
              {v}
            </option>
          ))}
        </Select>
        <Select label="Ação" value={draft.action} onChange={(e) => set('action', e.target.value)}>
          <option value="">Todas</option>
          {Object.entries(AUDIT_ACTION_LABELS).map(([k, v]) => (
            <option key={k} value={k}>
              {v}
            </option>
          ))}
        </Select>
        <Select label="Entidade" value={draft.entity} onChange={(e) => set('entity', e.target.value)}>
          <option value="">Todas</option>
          {Object.entries(ENTITY_LABELS).map(([k, v]) => (
            <option key={k} value={k}>
              {v}
            </option>
          ))}
        </Select>
        <Select label="Usuário" value={draft.userId} onChange={(e) => set('userId', e.target.value)}>
          <option value="">Todos</option>
          {profiles.map((p) => (
            <option key={p.id} value={p.id}>
              {p.full_name}
            </option>
          ))}
        </Select>
        <Input label="Correlação" value={draft.correlationId} onChange={(e) => set('correlationId', e.target.value)} placeholder="id da operação" />
        <div className="flex items-end gap-2 sm:col-span-2 lg:col-span-3">
          <Input label="Texto" value={draft.search} onChange={(e) => set('search', e.target.value)} placeholder="ID do registro, ação ou justificativa" wrapClassName="flex-1" />
          <Button type="submit" icon={<Search className="h-4 w-4" />}>
            Buscar
          </Button>
        </div>
      </form>

      <div className="rounded-xl border border-slate-200 bg-white shadow-card">
        {error && (
          <div className="p-4">
            <Alert tone="error">{error}</Alert>
          </div>
        )}
        {loading && rows.length === 0 ? (
          <PageLoader />
        ) : rows.length === 0 ? (
          <EmptyState icon={<FileClock className="h-10 w-10" />} title="Nenhum evento encontrado" description="Ajuste o período ou os filtros." />
        ) : (
          <>
            <ul className="divide-y divide-slate-100">
              {rows.map((r) => (
                <li key={r.id} className="px-4 py-2.5">
                  <button type="button" className="flex w-full items-start gap-2 text-left" onClick={() => setOpen(open === r.id ? null : r.id)} aria-expanded={open === r.id}>
                    {open === r.id ? <ChevronDown className="mt-0.5 h-4 w-4 text-slate-400" /> : <ChevronRight className="mt-0.5 h-4 w-4 text-slate-400" />}
                    <span className="min-w-0 flex-1">
                      <span className="flex flex-wrap items-center gap-1.5">
                        <span className="font-medium text-slate-900">{auditLabel(r.action)}</span>
                        <span className="text-xs text-slate-500">{AUDIT_CATEGORY_LABELS[r.category ?? ''] ?? ENTITY_LABELS[r.entity] ?? r.entity}</span>
                        <SeverityBadge s={r.severity} />
                        <ResultBadge r={r.result} />
                      </span>
                      <span className="block text-xs text-slate-500">
                        {fmtDateTime(r.occurred_at)} · {r.user_id ? (r.user_name ?? names[r.user_id] ?? r.user_email ?? 'Usuário') : 'Sistema'}
                        {r.ip_address ? ` · IP ${r.ip_address}` : ''}
                        {r.chain_seq ? ` · nº ${r.chain_seq}` : ''}
                      </span>
                      {r.justification && <span className="block text-sm text-slate-700">Justificativa: {r.justification}</span>}
                    </span>
                    {r.movement_id && (
                      <Link to={`/movimentacoes/${r.movement_id}`} onClick={(e) => e.stopPropagation()} className="text-xs font-medium text-brand-700 hover:underline">
                        Ver ME
                      </Link>
                    )}
                  </button>
                  {open === r.id && (
                    <div className="ml-6 mt-2 space-y-2 overflow-x-auto rounded-lg bg-slate-50 p-3">
                      <Diff log={r} />
                      <p className="text-[11px] text-slate-500">
                        {ENTITY_LABELS[r.entity] ?? r.entity}
                        {r.entity_id ? ` · ${r.entity_id}` : ''}
                        {r.reason_code ? ` · motivo: ${r.reason_code}` : ''}
                        {r.source ? ` · origem: ${r.source}` : ''}
                      </p>
                      {r.correlation_id && (
                        <button
                          type="button"
                          className="inline-flex items-center gap-1 text-[11px] font-medium text-brand-700 hover:underline"
                          onClick={() => apply({ ...defaultFilters(), dateFrom: q.dateFrom, dateTo: q.dateTo, correlationId: r.correlation_id ?? '' })}
                        >
                          <Link2 className="h-3 w-3" /> Ver eventos da mesma operação
                        </button>
                      )}
                      {r.user_agent && <p className="text-[11px] text-slate-400">{r.user_agent}</p>}
                    </div>
                  )}
                </li>
              ))}
            </ul>
            <Pagination page={page} pageSize={PAGE_SIZE} total={total} onPage={setPage} />
          </>
        )}
      </div>

      <Modal
        open={exportOpen}
        onClose={() => setExportOpen(false)}
        busy={exporting}
        title="Exportar auditoria"
        description="Exporta os eventos dos filtros atuais (máximo de 10.000). A exportação e a finalidade ficam registradas na própria auditoria. Guarde o arquivo em local restrito."
        footer={
          <>
            <Button variant="secondary" onClick={() => setExportOpen(false)} disabled={exporting}>
              Voltar
            </Button>
            <Button icon={<Download className="h-4 w-4" />} loading={exporting} disabled={reason.trim().length < 10} onClick={() => void doExport()}>
              Exportar
            </Button>
          </>
        }
      >
        <Textarea
          label="Finalidade da exportação"
          required
          rows={3}
          maxLength={500}
          value={reason}
          onChange={(e) => setReason(e.target.value)}
          placeholder="Ex.: apuração interna do cancelamento da ME-01-2026-000010"
          hint="Mínimo de 10 caracteres."
        />
        <p className="mt-2 text-xs text-slate-500">
          Período: {q.dateFrom} a {q.dateTo}
        </p>
      </Modal>
    </div>
  );
}
