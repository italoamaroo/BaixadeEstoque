import { useCallback, useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { ChevronDown, ChevronRight, FileClock, Search } from 'lucide-react';
import { Alert, EmptyState, PageHeader } from '@/components/ui/Card';
import { Input, Select } from '@/components/ui/Field';
import { Button } from '@/components/ui/Button';
import { Pagination } from '@/components/ui/Pagination';
import { PageLoader } from '@/components/ui/Spinner';
import { listAudit, listProfiles, type ProfileName } from '@/lib/api';
import { AUDIT_ACTION_LABELS, ENTITY_LABELS, auditLabel } from '@/lib/constants';
import { errorMessage } from '@/lib/errors';
import { fmtDateTime } from '@/lib/format';
import type { AuditLog } from '@/types/db';

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

export function AuditPage() {
  const [profiles, setProfiles] = useState<ProfileName[]>([]);
  const [draft, setDraft] = useState({ action: '', entity: '', userId: '', dateFrom: '', dateTo: '', search: '' });
  const [q, setQ] = useState(draft);
  const [page, setPage] = useState(1);
  const [rows, setRows] = useState<AuditLog[]>([]);
  const [total, setTotal] = useState(0);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [open, setOpen] = useState<number | null>(null);

  useEffect(() => {
    listProfiles().then(setProfiles).catch(() => undefined);
  }, []);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const r = await listAudit({ ...q, page, pageSize: 50 });
      setRows(r.rows);
      setTotal(r.total);
      setError(null);
    } catch (err) {
      setError(errorMessage(err));
    } finally {
      setLoading(false);
    }
  }, [q, page]);

  useEffect(() => {
    void load();
  }, [load]);

  const names = Object.fromEntries(profiles.map((p) => [p.id, p.full_name]));

  return (
    <div>
      <PageHeader title="Auditoria" subtitle="Trilha imutável de operações: quem fez, quando, o que mudou (antes/depois), justificativa e origem." />
      <form
        className="mb-4 grid gap-3 rounded-xl border border-slate-200 bg-white p-4 shadow-card sm:grid-cols-3 lg:grid-cols-6"
        onSubmit={(e) => {
          e.preventDefault();
          setPage(1);
          setQ(draft);
        }}
      >
        <Input label="De" type="date" value={draft.dateFrom} onChange={(e) => setDraft((d) => ({ ...d, dateFrom: e.target.value }))} />
        <Input label="Até" type="date" value={draft.dateTo} onChange={(e) => setDraft((d) => ({ ...d, dateTo: e.target.value }))} />
        <Select label="Ação" value={draft.action} onChange={(e) => setDraft((d) => ({ ...d, action: e.target.value }))}>
          <option value="">Todas</option>
          {Object.entries(AUDIT_ACTION_LABELS).map(([k, v]) => (
            <option key={k} value={k}>
              {v}
            </option>
          ))}
        </Select>
        <Select label="Entidade" value={draft.entity} onChange={(e) => setDraft((d) => ({ ...d, entity: e.target.value }))}>
          <option value="">Todas</option>
          {Object.entries(ENTITY_LABELS).map(([k, v]) => (
            <option key={k} value={k}>
              {v}
            </option>
          ))}
        </Select>
        <Select label="Usuário" value={draft.userId} onChange={(e) => setDraft((d) => ({ ...d, userId: e.target.value }))}>
          <option value="">Todos</option>
          {profiles.map((p) => (
            <option key={p.id} value={p.id}>
              {p.full_name}
            </option>
          ))}
        </Select>
        <div className="flex items-end gap-2">
          <Input label="Texto" value={draft.search} onChange={(e) => setDraft((d) => ({ ...d, search: e.target.value }))} placeholder="ID, e-mail, justificativa" wrapClassName="flex-1" />
          <Button type="submit" icon={<Search className="h-4 w-4" />} aria-label="Buscar" />
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
          <EmptyState icon={<FileClock className="h-10 w-10" />} title="Nenhum evento encontrado" />
        ) : (
          <>
            <ul className="divide-y divide-slate-100">
              {rows.map((r) => (
                <li key={r.id} className="px-4 py-2.5">
                  <button type="button" className="flex w-full items-start gap-2 text-left" onClick={() => setOpen(open === r.id ? null : r.id)} aria-expanded={open === r.id}>
                    {open === r.id ? <ChevronDown className="mt-0.5 h-4 w-4 text-slate-400" /> : <ChevronRight className="mt-0.5 h-4 w-4 text-slate-400" />}
                    <span className="min-w-0 flex-1">
                      <span className="font-medium text-slate-900">{auditLabel(r.action)}</span>
                      <span className="ml-2 text-xs text-slate-500">{ENTITY_LABELS[r.entity] ?? r.entity}</span>
                      <span className="block text-xs text-slate-500">
                        {fmtDateTime(r.occurred_at)} · {r.user_id ? (names[r.user_id] ?? r.user_email) : 'Sistema'} · {r.source}
                        {r.ip_address ? ` · IP ${r.ip_address}` : ''}
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
                    <div className="ml-6 mt-2 overflow-x-auto rounded-lg bg-slate-50 p-3">
                      <Diff log={r} />
                      {r.user_agent && <p className="mt-2 text-[11px] text-slate-400">{r.user_agent}</p>}
                    </div>
                  )}
                </li>
              ))}
            </ul>
            <Pagination page={page} pageSize={50} total={total} onPage={setPage} />
          </>
        )}
      </div>
    </div>
  );
}
