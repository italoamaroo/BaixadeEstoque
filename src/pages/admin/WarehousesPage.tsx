import { useEffect, useState } from 'react';
import { toast } from 'sonner';
import { Pencil, Plus } from 'lucide-react';
import { Button } from '@/components/ui/Button';
import { ActiveBadge } from '@/components/ui/Badge';
import { Alert, PageHeader } from '@/components/ui/Card';
import { Checkbox, Input } from '@/components/ui/Field';
import { Modal } from '@/components/ui/Modal';
import { PageLoader } from '@/components/ui/Spinner';
import { useAuth } from '@/contexts/AuthContext';
import { listWarehouses, saveWarehouse } from '@/lib/api';
import { errorMessage } from '@/lib/errors';
import { fieldErrors, warehouseSchema } from '@/lib/validation';
import type { Warehouse } from '@/types/db';

export function WarehousesPage() {
  const { refreshAccess } = useAuth();
  const [rows, setRows] = useState<Warehouse[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [editing, setEditing] = useState<Warehouse | 'new' | null>(null);
  const [form, setForm] = useState({ code: '', name: '', active: true });
  const [errors, setErrors] = useState<Record<string, string>>({});
  const [saving, setSaving] = useState(false);

  const load = async () => {
    try {
      setRows(await listWarehouses(true));
      setError(null);
    } catch (err) {
      setError(errorMessage(err));
    } finally {
      setLoading(false);
    }
  };
  useEffect(() => {
    void load();
  }, []);

  const save = async () => {
    const r = warehouseSchema.safeParse(form);
    const errs = fieldErrors(r);
    setErrors(errs);
    if (Object.keys(errs).length) return;
    if (editing !== 'new' && editing && editing.code !== form.code.toUpperCase() &&
        !window.confirm('Alterar o código muda o prefixo das PRÓXIMAS MEs deste estoque. As MEs já emitidas mantêm o número original. Continuar?')) return;
    setSaving(true);
    try {
      await saveWarehouse({ ...form, id: editing !== 'new' ? editing?.id : undefined });
      toast.success('Estoque salvo.');
      setEditing(null);
      await load();
      await refreshAccess();
    } catch (err) {
      toast.error(errorMessage(err));
    } finally {
      setSaving(false);
    }
  };

  if (loading) return <PageLoader />;
  return (
    <div>
      <PageHeader
        title="Estoques"
        subtitle="Almoxarifados físicos. O código entra no número da ME (ex.: ME-MUR-2026-000001)."
        actions={
          <Button icon={<Plus className="h-4 w-4" />} onClick={() => (setEditing('new'), setForm({ code: '', name: '', active: true }), setErrors({}))}>
            Novo estoque
          </Button>
        }
      />
      {error && <Alert tone="error">{error}</Alert>}
      <div className="grid gap-3 sm:grid-cols-2">
        {rows.map((w) => (
          <div key={w.id} className="flex items-center justify-between rounded-xl border border-slate-200 bg-white p-4 shadow-card">
            <div>
              <p className="text-lg font-semibold">{w.name}</p>
              <p className="font-mono text-sm text-slate-500">{w.code}</p>
            </div>
            <div className="flex items-center gap-2">
              <ActiveBadge active={w.active ?? true} />
              <Button size="sm" variant="ghost" icon={<Pencil className="h-4 w-4" />} onClick={() => (setEditing(w), setForm({ code: w.code, name: w.name, active: w.active ?? true }), setErrors({}))}>
                Editar
              </Button>
            </div>
          </div>
        ))}
      </div>
      <Modal
        open={editing !== null}
        onClose={() => setEditing(null)}
        busy={saving}
        title={editing === 'new' ? 'Novo estoque' : 'Editar estoque'}
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
        <div className="space-y-4">
          <Input label="Código (2 a 6 caracteres)" required value={form.code} onChange={(e) => setForm((f) => ({ ...f, code: e.target.value.toUpperCase() }))} error={errors.code} maxLength={6} />
          <Input label="Nome" required value={form.name} onChange={(e) => setForm((f) => ({ ...f, name: e.target.value }))} error={errors.name} />
          <Checkbox label="Ativo" description="Estoques inativos não aceitam novas saídas." checked={form.active} onChange={(v) => setForm((f) => ({ ...f, active: v }))} />
        </div>
      </Modal>
    </div>
  );
}
