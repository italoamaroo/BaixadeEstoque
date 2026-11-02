import { useEffect, useMemo, useState } from 'react';
import { useSearchParams } from 'react-router-dom';
import { toast } from 'sonner';
import { Download, Pencil, Plus, Search, Upload } from 'lucide-react';
import clsx from 'clsx';
import { Button } from '@/components/ui/Button';
import { ActiveBadge } from '@/components/ui/Badge';
import { Alert, EmptyState, PageHeader } from '@/components/ui/Card';
import { Checkbox, Input, Select } from '@/components/ui/Field';
import { Modal } from '@/components/ui/Modal';
import { PageLoader } from '@/components/ui/Spinner';
import { importLookups, listLookup, saveLookup, withRetry } from '@/lib/api';
import { downloadLookupTemplate, parseLookupFile } from '@/lib/importLookups';
import { fmtInt } from '@/lib/format';
import { LOOKUP_TABLES, type LookupTable } from '@/lib/constants';
import { errorMessage } from '@/lib/errors';
import { fieldErrors, lookupSchema, type LookupForm } from '@/lib/validation';
import { invalidateLookups } from '@/hooks/useLookups';
import type { Lookup } from '@/types/db';

/** Contratos, setores, frentes/equipamentos, OS, ativos fixos, locais, contas e categorias. */
export function LookupsPage() {
  const [params, setParams] = useSearchParams();
  const table = (LOOKUP_TABLES.find((t) => t.table === params.get('tabela'))?.table ?? 'contracts') as LookupTable;
  const meta = LOOKUP_TABLES.find((t) => t.table === table)!;
  const [rows, setRows] = useState<Lookup[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [search, setSearch] = useState('');
  const [editing, setEditing] = useState<Lookup | 'new' | null>(null);
  const [form, setForm] = useState<LookupForm>({ code: '', name: '', active: true, kind: 'frente' });
  const [errors, setErrors] = useState<Record<string, string>>({});
  const [saving, setSaving] = useState(false);
  const [importOpen, setImportOpen] = useState(false);

  const load = async () => {
    setLoading(true);
    try {
      setRows(await listLookup(table, true));
      setError(null);
    } catch (err) {
      setError(errorMessage(err));
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    setSearch('');
    void load();
  }, [table]);

  const filtered = useMemo(() => {
    const s = search.trim().toLowerCase();
    return s ? rows.filter((r) => r.code.toLowerCase().includes(s) || r.name.toLowerCase().includes(s)) : rows;
  }, [rows, search]);

  const open = (r: Lookup | 'new') => {
    setEditing(r);
    setErrors({});
    setForm(r === 'new' ? { code: '', name: '', active: true, kind: 'frente' } : { code: r.code, name: r.name, active: r.active, kind: r.kind ?? 'frente' });
  };

  const save = async () => {
    const r = lookupSchema.safeParse(form);
    const errs = fieldErrors(r);
    setErrors(errs);
    if (Object.keys(errs).length) return;
    setSaving(true);
    try {
      await saveLookup(table, { ...form, id: editing !== 'new' ? editing?.id : undefined });
      invalidateLookups(table);
      toast.success('Registro salvo.');
      setEditing(null);
      void load();
    } catch (err) {
      toast.error(errorMessage(err));
    } finally {
      setSaving(false);
    }
  };

  const toggle = async (r: Lookup) => {
    try {
      await saveLookup(table, { ...r, active: !r.active });
      invalidateLookups(table);
      toast.success(r.active ? 'Registro inativado.' : 'Registro reativado.');
      void load();
    } catch (err) {
      toast.error(errorMessage(err));
    }
  };

  return (
    <div>
      <PageHeader
        title="Cadastros auxiliares"
        subtitle="Registros não são excluídos: inative para impedir novos usos e manter o histórico."
        actions={
          <>
            <Button variant="secondary" icon={<Upload className="h-4 w-4" />} onClick={() => setImportOpen(true)}>
              Importar planilha
            </Button>
            <Button icon={<Plus className="h-4 w-4" />} onClick={() => open('new')}>
              Novo {meta.singular}
            </Button>
          </>
        }
      />
      <div className="mb-4 flex flex-wrap gap-1.5">
        {LOOKUP_TABLES.map((t) => (
          <button
            key={t.table}
            type="button"
            onClick={() => setParams({ tabela: t.table })}
            className={clsx('rounded-full px-3 py-1.5 text-sm font-medium ring-1 ring-inset', t.table === table ? 'bg-brand-700 text-white ring-brand-700' : 'bg-white text-slate-700 ring-slate-300 hover:bg-slate-50')}
          >
            {t.label}
          </button>
        ))}
      </div>
      <div className="rounded-xl border border-slate-200 bg-white shadow-card">
        <div className="border-b border-slate-100 p-3">
          <div className="relative max-w-sm">
            <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-slate-400" />
            <input className="h-9 w-full rounded-lg border-0 pl-9 text-sm ring-1 ring-inset ring-slate-300" placeholder="Filtrar" value={search} onChange={(e) => setSearch(e.target.value)} />
          </div>
        </div>
        {error && (
          <div className="p-4">
            <Alert tone="error">{error}</Alert>
          </div>
        )}
        {loading ? (
          <PageLoader />
        ) : filtered.length === 0 ? (
          <EmptyState title={`Nenhum registro em ${meta.label.toLowerCase()}`} />
        ) : (
          <table className="min-w-full divide-y divide-slate-200 text-sm">
            <thead className="bg-slate-50 text-xs font-semibold uppercase tracking-wide text-slate-500">
              <tr>
                <th className="px-3 py-2.5 text-left">Código</th>
                <th className="px-3 py-2.5 text-left">Nome / descrição</th>
                {table === 'service_fronts' && <th className="px-3 py-2.5 text-left">Tipo</th>}
                <th className="px-3 py-2.5 text-left">Situação</th>
                <th className="px-3 py-2.5 text-right">Ações</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100">
              {filtered.map((r) => (
                <tr key={r.id} className={r.active ? '' : 'text-slate-500'}>
                  <td className="whitespace-nowrap px-3 py-2.5 font-mono text-xs">{r.code}</td>
                  <td className="px-3 py-2.5">{r.name}</td>
                  {table === 'service_fronts' && <td className="px-3 py-2.5">{r.kind === 'equipamento' ? 'Equipamento' : 'Frente de serviço'}</td>}
                  <td className="px-3 py-2.5">
                    <button type="button" onClick={() => void toggle(r)} title="Ativar/inativar">
                      <ActiveBadge active={r.active} />
                    </button>
                  </td>
                  <td className="px-3 py-2.5 text-right">
                    <Button size="sm" variant="ghost" icon={<Pencil className="h-4 w-4" />} onClick={() => open(r)}>
                      Editar
                    </Button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>

      <Modal
        open={editing !== null}
        onClose={() => setEditing(null)}
        busy={saving}
        title={editing === 'new' ? `Novo ${meta.singular}` : `Editar ${meta.singular}`}
        footer={
          <>
            <Button variant="secondary" onClick={() => setEditing(null)} disabled={saving}>
              Cancelar
            </Button>
            <Button onClick={() => void save()} loading={saving}>
              Salvar
            </Button>
          </>
        }
      >
        <div className="space-y-4">
          <Input label="Código" required value={form.code} onChange={(e) => setForm((f) => ({ ...f, code: e.target.value }))} error={errors.code} maxLength={40} />
          <Input label="Nome / descrição" required value={form.name} onChange={(e) => setForm((f) => ({ ...f, name: e.target.value }))} error={errors.name} maxLength={160} />
          {table === 'service_fronts' && (
            <Select label="Tipo" value={form.kind} onChange={(e) => setForm((f) => ({ ...f, kind: e.target.value as 'frente' | 'equipamento' }))}>
              <option value="frente">Frente de serviço</option>
              <option value="equipamento">Equipamento</option>
            </Select>
          )}
          <Checkbox label="Ativo" checked={form.active} onChange={(v) => setForm((f) => ({ ...f, active: v }))} />
        </div>
      </Modal>
      <ImportLookupsModal
        open={importOpen}
        table={table}
        label={meta.label}
        onClose={() => setImportOpen(false)}
        onDone={() => {
          invalidateLookups(table);
          void load();
        }}
      />
    </div>
  );
}

type ImportResult = { inseridos: number; atualizados: number; erros: { linha: number; codigo: string; erro: string }[] };

function ImportLookupsModal({
  open,
  table,
  label,
  onClose,
  onDone,
}: {
  open: boolean;
  table: LookupTable;
  label: string;
  onClose: () => void;
  onDone: () => void;
}) {
  const [rows, setRows] = useState<Record<string, unknown>[] | null>(null);
  const [fileError, setFileError] = useState<string | null>(null);
  const [result, setResult] = useState<ImportResult | null>(null);
  const [busy, setBusy] = useState(false);
  const [progress, setProgress] = useState('');
  const [finished, setFinished] = useState(false);

  useEffect(() => {
    if (open) {
      setRows(null);
      setFileError(null);
      setResult(null);
      setFinished(false);
    }
  }, [open, table]);

  const onFile = async (f: File | undefined) => {
    if (!f) return;
    setFileError(null);
    setResult(null);
    setFinished(false);
    try {
      const parsed = await parseLookupFile(table, f);
      if (parsed.length === 0) throw new Error('Nenhuma linha encontrada no arquivo.');
      setRows(parsed);
    } catch (err) {
      setRows(null);
      setFileError((err as Error).message);
    }
  };

  const run = async () => {
    if (!rows || busy) return;
    setBusy(true);
    setFileError(null);
    const BATCH = 500;
    const total: ImportResult = { inseridos: 0, atualizados: 0, erros: [] };
    try {
      for (let start = 0; start < rows.length; start += BATCH) {
        setProgress(`Importando ${fmtInt(Math.min(start + BATCH, rows.length))} de ${fmtInt(rows.length)}…`);
        const r = await withRetry(() => importLookups(table, rows.slice(start, start + BATCH)));
        total.inseridos += r.inseridos;
        total.atualizados += r.atualizados;
        total.erros.push(...r.erros.map((e) => ({ ...e, linha: e.linha + start })));
        setResult({ ...total, erros: [...total.erros] });
      }
      setFinished(true);
      toast.success(`${fmtInt(total.inseridos)} incluído(s), ${fmtInt(total.atualizados)} atualizado(s).`);
    } catch (err) {
      setFileError(`${errorMessage(err)} Importe o arquivo de novo para concluir (o que já entrou será apenas atualizado).`);
    } finally {
      setBusy(false);
      setProgress('');
      onDone();
    }
  };

  const showKind = table === 'service_fronts';

  return (
    <Modal
      open={open}
      onClose={onClose}
      busy={busy}
      size="lg"
      title={`Importar ${label.toLowerCase()}`}
      description="Planilha .xlsx ou .csv. Código novo é incluído; código já cadastrado tem o nome atualizado."
      footer={
        <>
          <Button variant="ghost" icon={<Download className="h-4 w-4" />} onClick={() => void downloadLookupTemplate(table, label.toLowerCase().normalize('NFD').replace(/[\u0300-\u036f]/g, '').replace(/[^a-z0-9]+/g, '_'))}>
            Baixar modelo
          </Button>
          <Button onClick={() => void run()} loading={busy} disabled={!rows || finished}>
            {busy && progress ? progress : `Importar ${rows ? `${fmtInt(rows.length)} registro(s)` : ''}`}
          </Button>
        </>
      }
    >
      <div className="space-y-4">
        <p className="text-sm text-slate-600">
          Colunas: <code className="rounded bg-slate-100 px-1 text-xs">codigo</code> e{' '}
          <code className="rounded bg-slate-100 px-1 text-xs">nome</code> (ou “descrição”), obrigatórias
          {showKind && (
            <>
              , <code className="rounded bg-slate-100 px-1 text-xs">tipo</code> (frente ou equipamento)
            </>
          )}{' '}
          e <code className="rounded bg-slate-100 px-1 text-xs">{table === 'fixed_assets' ? 'situacao' : 'ativo'}</code> (sim/não), opcional.
          {table === 'fixed_assets' && ' Em ativos fixos também são reconhecidas colunas como “Ativo”, “Patrimônio”, “Plaqueta” ou “Placa” como código.'}
        </p>
        <input type="file" accept=".xlsx,.xls,.csv,text/csv" onChange={(e) => void onFile(e.target.files?.[0])} className="block w-full text-sm" />
        {fileError && <Alert tone="error">{fileError}</Alert>}
        {rows && !result && (
          <div className="max-h-56 overflow-auto rounded border border-slate-200 text-xs">
            <table className="min-w-full">
              <thead className="bg-slate-50">
                <tr>
                  <th className="px-2 py-1 text-left">código</th>
                  <th className="px-2 py-1 text-left">nome</th>
                  {showKind && <th className="px-2 py-1 text-left">tipo</th>}
                  <th className="px-2 py-1 text-left">ativo</th>
                </tr>
              </thead>
              <tbody>
                {rows.slice(0, 20).map((r, i) => (
                  <tr key={i} className="border-t border-slate-100">
                    <td className="px-2 py-1 font-mono">{String(r.code ?? '')}</td>
                    <td className="px-2 py-1">{String(r.name ?? '')}</td>
                    {showKind && <td className="px-2 py-1">{String(r.kind ?? '')}</td>}
                    <td className="px-2 py-1">{r.active === undefined ? '' : r.active ? 'sim' : 'não'}</td>
                  </tr>
                ))}
              </tbody>
            </table>
            {rows.length > 20 && <p className="px-2 py-1 text-slate-500">… e mais {fmtInt(rows.length - 20)} linha(s).</p>}
          </div>
        )}
        {result && (
          <Alert
            tone={result.erros.length ? 'warning' : 'success'}
            title={`${fmtInt(result.inseridos)} incluído(s) · ${fmtInt(result.atualizados)} atualizado(s) · ${fmtInt(result.erros.length)} com erro`}
          >
            {result.erros.length > 0 && (
              <ul className="mt-1 max-h-40 list-disc overflow-auto pl-5">
                {result.erros.slice(0, 200).map((e) => (
                  <li key={e.linha}>
                    Linha {e.linha} ({e.codigo || 'sem código'}): {e.erro}
                  </li>
                ))}
              </ul>
            )}
          </Alert>
        )}
      </div>
    </Modal>
  );
}
