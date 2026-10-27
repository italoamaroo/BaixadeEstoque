import { useState } from 'react';
import { ChevronDown, ChevronRight } from 'lucide-react';
import type { AuditLog, SaRecord, StatusHistory } from '@/types/db';
import { STATUS_LABELS, auditLabel } from '@/lib/constants';
import { fmtDateTime } from '@/lib/format';
import { StatusBadge } from '@/components/ui/Badge';

interface Props {
  history: StatusHistory[];
  saRecords: SaRecord[];
  audit: AuditLog[];
  auditAllowed: boolean;
  names: Record<string, string>;
}

const HIDDEN_KEYS = new Set(['created_at', 'updated_at', 'created_by', 'updated_by', 'id', 'movement_id']);

function formatValue(v: unknown): string {
  if (v === null || v === undefined || v === '') return '—';
  if (typeof v === 'string' && /^\d{4}-\d{2}-\d{2}T/.test(v)) return fmtDateTime(v);
  if (typeof v === 'string' && v in STATUS_LABELS) return STATUS_LABELS[v as keyof typeof STATUS_LABELS];
  if (typeof v === 'object') return JSON.stringify(v);
  return String(v);
}

function AuditRow({ log, names }: { log: AuditLog; names: Record<string, string> }) {
  const [open, setOpen] = useState(false);
  const keys = Array.from(new Set([...Object.keys(log.new_data ?? {}), ...Object.keys(log.old_data ?? {})])).filter((k) => !HIDDEN_KEYS.has(k));
  return (
    <li className="py-2.5">
      <button type="button" className="flex w-full items-start gap-2 text-left" onClick={() => setOpen((o) => !o)} aria-expanded={open}>
        {keys.length > 0 ? (
          open ? <ChevronDown className="mt-0.5 h-4 w-4 text-slate-400" /> : <ChevronRight className="mt-0.5 h-4 w-4 text-slate-400" />
        ) : (
          <span className="w-4" />
        )}
        <span className="min-w-0 flex-1">
          <span className="font-medium text-slate-900">{auditLabel(log.action)}</span>
          <span className="block text-xs text-slate-500">
            {fmtDateTime(log.occurred_at)} · {log.user_id ? (names[log.user_id] ?? log.user_email) : 'Sistema'} · origem: {log.source}
            {log.ip_address ? ` · IP ${log.ip_address}` : ''}
          </span>
          {log.justification && <span className="mt-0.5 block text-sm text-slate-700">Justificativa: {log.justification}</span>}
        </span>
      </button>
      {open && keys.length > 0 && (
        <div className="ml-6 mt-2 overflow-x-auto rounded-lg bg-slate-50 p-2">
          <table className="text-xs">
            <thead>
              <tr className="text-left text-slate-500">
                <th className="pr-4">Campo</th>
                <th className="pr-4">Valor anterior</th>
                <th>Valor novo</th>
              </tr>
            </thead>
            <tbody>
              {keys.map((k) => (
                <tr key={k} className="align-top">
                  <td className="pr-4 font-mono text-slate-600">{k}</td>
                  <td className="pr-4 text-red-700">{formatValue(log.old_data?.[k])}</td>
                  <td className="text-emerald-700">{formatValue(log.new_data?.[k])}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </li>
  );
}

export function MovementTimeline({ history, saRecords, audit, auditAllowed, names }: Props) {
  return (
    <div className="grid gap-6 lg:grid-cols-2">
      <div className="space-y-6">
        <section>
          <h3 className="mb-3 font-semibold text-slate-800">Histórico de status</h3>
          <ol className="relative space-y-4 border-l-2 border-slate-200 pl-5">
            {history.map((h) => (
              <li key={h.id} className="relative">
                <span className="absolute -left-[27px] top-1 h-3 w-3 rounded-full border-2 border-white bg-brand-600" />
                <div className="flex flex-wrap items-center gap-2">
                  <StatusBadge status={h.to_status} />
                  <span className="text-xs text-slate-500">{fmtDateTime(h.changed_at)}</span>
                </div>
                <p className="mt-1 text-sm text-slate-600">
                  {h.changed_by ? (names[h.changed_by] ?? 'Usuário') : 'Sistema'}
                  {h.from_status ? ` · de ${STATUS_LABELS[h.from_status]}` : ''}
                </p>
                {h.reason && <p className="text-sm text-slate-700">“{h.reason}”</p>}
              </li>
            ))}
          </ol>
        </section>

        <section>
          <h3 className="mb-3 font-semibold text-slate-800">Registros de SA</h3>
          {saRecords.length === 0 ? (
            <p className="text-sm text-slate-500">Nenhuma SA informada ainda.</p>
          ) : (
            <ul className="divide-y divide-slate-100 rounded-lg border border-slate-200">
              {saRecords.map((r) => (
                <li key={r.id} className="px-3 py-2.5 text-sm">
                  <p className="font-medium text-slate-900">
                    {r.action === 'inclusao' ? 'SA informada' : 'SA corrigida'}: <span className="font-mono">{r.sa_number}</span>
                    {r.previous_sa_number && <span className="text-slate-500"> (anterior: {r.previous_sa_number})</span>}
                  </p>
                  <p className="text-xs text-slate-500">
                    {fmtDateTime(r.informed_at)} · {names[r.informed_by] ?? 'Usuário'}
                  </p>
                  {r.justification && <p className="text-slate-700">Justificativa: {r.justification}</p>}
                </li>
              ))}
            </ul>
          )}
        </section>
      </div>

      <section>
        <h3 className="mb-3 font-semibold text-slate-800">Auditoria detalhada</h3>
        {!auditAllowed ? (
          <p className="text-sm text-slate-500">Disponível para gestor e administrador.</p>
        ) : audit.length === 0 ? (
          <p className="text-sm text-slate-500">Nenhum evento registrado.</p>
        ) : (
          <ul className="divide-y divide-slate-100">
            {audit.map((a) => (
              <AuditRow key={a.id} log={a} names={names} />
            ))}
          </ul>
        )}
      </section>
    </div>
  );
}
