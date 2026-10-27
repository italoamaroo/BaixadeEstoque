import { useCallback, useEffect, useState } from 'react';
import { toast } from 'sonner';
import { Pencil, Plus, Search, Users } from 'lucide-react';
import { Button } from '@/components/ui/Button';
import { ActiveBadge } from '@/components/ui/Badge';
import { Alert, EmptyState, PageHeader } from '@/components/ui/Card';
import { Checkbox, Input, Select } from '@/components/ui/Field';
import { Modal } from '@/components/ui/Modal';
import { PageLoader } from '@/components/ui/Spinner';
import { useDebounce } from '@/hooks/useDebounce';
import { useLookups } from '@/hooks/useLookups';
import { listEmployees, saveEmployee } from '@/lib/api';
import { errorMessage } from '@/lib/errors';
import { employeeSchema, fieldErrors, type EmployeeForm } from '@/lib/validation';
import type { Employee } from '@/types/db';

const empty: EmployeeForm = { registration: '', full_name: '', job_title: '', sector_id: '', active: true };

/** Funcionários que requisitam e recebem materiais (não precisam ter login). */
export function EmployeesPage() {
  const { data: lk } = useLookups(['sectors']);
  const [search, setSearch] = useState('');
  const term = useDebounce(search);
  const [showInactive, setShowInactive] = useState(false);
  const [rows, setRows] = useState<Employee[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [editing, setEditing] = useState<Employee | 'new' | null>(null);
  const [form, setForm] = useState<EmployeeForm>(empty);
  const [errors, setErrors] = useState<Record<string, string>>({});
  const [saving, setSaving] = useState(false);
  const sectorName = (id: string | null) => lk.sectors?.find((s) => s.id === id)?.name ?? '—';

  const load = useCallback(async () => {
    setLoading(true);
    try {
      setRows(await listEmployees({ search: term, includeInactive: showInactive, limit: 300 }));
      setError(null);
    } catch (err) {
      setError(errorMessage(err));
    } finally {
      setLoading(false);
    }
  }, [term, showInactive]);

  useEffect(() => {
    void load();
  }, [load]);

  const open = (e: Employee | 'new') => {
    setEditing(e);
    setErrors({});
    setForm(e === 'new' ? empty : { registration: e.registration, full_name: e.full_name, job_title: e.job_title ?? '', sector_id: e.sector_id ?? '', active: e.active });
  };

  const save = async () => {
    const r = employeeSchema.safeParse(form);
    const errs = fieldErrors(r);
    setErrors(errs);
    if (Object.keys(errs).length) return;
    setSaving(true);
    try {
      await saveEmployee({ ...form, id: editing !== 'new' ? editing?.id : undefined } as Employee);
      toast.success('Funcionário salvo.');
      setEditing(null);
      void load();
    } catch (err) {
      toast.error(errorMessage(err));
    } finally {
      setSaving(false);
    }
  };

  return (
    <div>
      <PageHeader
        title="Funcionários"
        subtitle="Requisitantes e recebedores de material. Não precisam ter usuário no sistema."
        actions={
          <Button icon={<Plus className="h-4 w-4" />} onClick={() => open('new')}>
            Novo funcionário
          </Button>
        }
      />
      <div className="mb-4 flex flex-wrap items-center gap-3">
        <div className="relative min-w-[240px] flex-1">
          <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-slate-400" />
          <input className="h-10 w-full rounded-lg border-0 pl-9 text-sm ring-1 ring-inset ring-slate-300" placeholder="Nome ou matrícula" value={search} onChange={(e) => setSearch(e.target.value)} />
        </div>
        <Checkbox label="Mostrar inativos" checked={showInactive} onChange={setShowInactive} />
      </div>
      <div className="rounded-xl border border-slate-200 bg-white shadow-card">
        {error && (
          <div className="p-4">
            <Alert tone="error">{error}</Alert>
          </div>
        )}
        {loading ? (
          <PageLoader />
        ) : rows.length === 0 ? (
          <EmptyState icon={<Users className="h-10 w-10" />} title="Nenhum funcionário encontrado" />
        ) : (
          <div className="overflow-x-auto">
            <table className="min-w-full divide-y divide-slate-200 text-sm">
              <thead className="bg-slate-50 text-xs font-semibold uppercase tracking-wide text-slate-500">
                <tr>
                  <th className="px-3 py-2.5 text-left">Matrícula</th>
                  <th className="px-3 py-2.5 text-left">Nome</th>
                  <th className="px-3 py-2.5 text-left">Cargo</th>
                  <th className="px-3 py-2.5 text-left">Setor</th>
                  <th className="px-3 py-2.5 text-left">Situação</th>
                  <th className="px-3 py-2.5 text-right">Ações</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-100">
                {rows.map((e) => (
                  <tr key={e.id} className={e.active ? '' : 'text-slate-500'}>
                    <td className="whitespace-nowrap px-3 py-2.5 font-mono text-xs">{e.registration}</td>
                    <td className="px-3 py-2.5 font-medium">{e.full_name}</td>
                    <td className="px-3 py-2.5">{e.job_title ?? '—'}</td>
                    <td className="px-3 py-2.5">{sectorName(e.sector_id)}</td>
                    <td className="px-3 py-2.5">
                      <ActiveBadge active={e.active} />
                    </td>
                    <td className="px-3 py-2.5 text-right">
                      <Button size="sm" variant="ghost" icon={<Pencil className="h-4 w-4" />} onClick={() => open(e)}>
                        Editar
                      </Button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>

      <Modal
        open={editing !== null}
        onClose={() => setEditing(null)}
        busy={saving}
        title={editing === 'new' ? 'Novo funcionário' : 'Editar funcionário'}
        footer={
          <>
            <Button variant="secondary" onClick={() => setEditing(null)}>
              Cancelar
            </Button>
            <Button onClick={() => void save()} loading={saving}>
              Salvar
            </Button>
          </>
        }
      >
        <div className="grid gap-4 sm:grid-cols-2">
          <Input label="Matrícula" required value={form.registration} onChange={(e) => setForm((f) => ({ ...f, registration: e.target.value }))} error={errors.registration} maxLength={30} />
          <Input label="Cargo" value={form.job_title} onChange={(e) => setForm((f) => ({ ...f, job_title: e.target.value }))} maxLength={80} />
          <Input label="Nome completo" required value={form.full_name} onChange={(e) => setForm((f) => ({ ...f, full_name: e.target.value }))} error={errors.full_name} wrapClassName="sm:col-span-2" maxLength={160} />
          <Select label="Setor" value={form.sector_id} onChange={(e) => setForm((f) => ({ ...f, sector_id: e.target.value }))}>
            <option value="">Não informado</option>
            {(lk.sectors ?? []).map((s) => (
              <option key={s.id} value={s.id}>
                {s.name}
              </option>
            ))}
          </Select>
          <div className="flex items-end">
            <Checkbox label="Ativo" description="Inativos não podem requisitar." checked={form.active} onChange={(v) => setForm((f) => ({ ...f, active: v }))} />
          </div>
        </div>
      </Modal>
    </div>
  );
}
