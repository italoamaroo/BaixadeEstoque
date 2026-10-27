import { useEffect, useMemo, useState } from 'react';
import { useSearchParams } from 'react-router-dom';
import { toast } from 'sonner';
import { Pencil, Plus, Search } from 'lucide-react';
import clsx from 'clsx';
import { Button } from '@/components/ui/Button';
import { ActiveBadge } from '@/components/ui/Badge';
import { Alert, EmptyState, PageHeader } from '@/components/ui/Card';
import { Checkbox, Input, Select } from '@/components/ui/Field';
import { Modal } from '@/components/ui/Modal';
import { PageLoader } from '@/components/ui/Spinner';
import { listLookup, saveLookup } from '@/lib/api';
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
          <Button icon={<Plus className="h-4 w-4" />} onClick={() => open('new')}>
            Novo {meta.singular}
          </Button>
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
    </div>
  );
}
