import { useEffect, useState } from 'react';
import { toast } from 'sonner';
import { Modal } from '@/components/ui/Modal';
import { Button } from '@/components/ui/Button';
import { Input, Select, Textarea } from '@/components/ui/Field';
import { Alert } from '@/components/ui/Card';
import { useAuth } from '@/contexts/AuthContext';
import { useLookups } from '@/hooks/useLookups';
import { correctMovement, type MovementDetail } from '@/lib/api';
import { validateQuantities } from '@/lib/cart';
import { errorMessage } from '@/lib/errors';
import { fmtQty, parseQty } from '@/lib/format';
import { justificationSchema } from '@/lib/validation';

interface Props {
  open: boolean;
  detail: MovementDetail;
  onClose: () => void;
  onDone: () => void;
}

/** Correção administrativa (gestor/admin): exige justificativa e fica na auditoria. */
export function CorrectionModal({ open, detail, onClose, onDone }: Props) {
  const { warehouses, settings } = useAuth();
  const { data } = useLookups(['contracts', 'sectors', 'service_fronts', 'application_locations']);
  const m = detail.movement;

  const initial = () => ({
    warehouse_id: m.warehouse_id,
    contract_id: m.contract_id,
    sector_id: m.sector_id,
    service_front_id: m.service_front_id ?? '',
    service_order_text: m.service_order ?? '',
    fixed_asset_text: m.fixed_asset ?? '',
    application_location_id: m.application_location_id ?? '',
    application_location_text: m.application_location_id ? '' : (m.application_location ?? ''),
    notes: m.notes ?? '',
  });

  const [form, setForm] = useState(initial);
  const [qty, setQty] = useState<Record<string, { req: string; del: string }>>({});
  const [just, setJust] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    if (open) {
      setForm(initial());
      setQty(Object.fromEntries(detail.items.map((i) => [i.id, { req: fmtQty(i.quantity_requested), del: fmtQty(i.quantity_delivered) }])));
      setJust('');
      setError(null);
    }
  }, [open]);

  const set = (k: keyof ReturnType<typeof initial>, v: string) => setForm((f) => ({ ...f, [k]: v }));

  const submit = async () => {
    const j = justificationSchema.safeParse(just);
    if (!j.success) return setError(j.error.issues[0].message);

    const base = initial();
    const changes: Record<string, unknown> = {};
    for (const k of Object.keys(form) as (keyof typeof form)[]) {
      if (form[k] !== base[k]) changes[k] = form[k];
    }
    const items: { id: string; quantity_requested: number; quantity_delivered: number }[] = [];
    for (const i of detail.items) {
      const q = qty[i.id];
      if (!q) continue;
      const req = parseQty(q.req);
      const del = parseQty(q.del);
      if (req === Number(i.quantity_requested) && del === Number(i.quantity_delivered)) continue;
      const err = validateQuantities(req, del, {
        allowDeliveredAboveRequested: Boolean(settings?.allow_delivered_above_requested),
        allowDuplicateLines: true,
      });
      if (err) return setError(`Item ${i.line_number}: ${err}`);
      items.push({ id: i.id, quantity_requested: req, quantity_delivered: del });
    }
    if (items.length) changes.items = items;
    if (Object.keys(changes).length === 0) return setError('Nenhuma alteração foi feita.');
    if (changes.warehouse_id && !window.confirm('Você está alterando o ESTOQUE DE ORIGEM de uma ME finalizada. O número da ME é mantido. Confirmar?')) return;

    setBusy(true);
    setError(null);
    try {
      await correctMovement(m.id, changes, just.trim());
      toast.success('Correção registrada na auditoria.');
      onDone();
      onClose();
    } catch (err) {
      setError(errorMessage(err));
    } finally {
      setBusy(false);
    }
  };

  return (
    <Modal
      open={open}
      onClose={onClose}
      busy={busy}
      size="xl"
      title={`Corrigir ${m.me_number}`}
      description="Somente os campos alterados são gravados. A justificativa e os valores anteriores ficam na auditoria."
      footer={
        <>
          <Button variant="secondary" onClick={onClose} disabled={busy}>
            Cancelar
          </Button>
          <Button onClick={() => void submit()} loading={busy}>
            Salvar correção
          </Button>
        </>
      }
    >
      <div className="space-y-5">
        <div className="grid gap-4 sm:grid-cols-2">
          <Select label="Estoque de origem" value={form.warehouse_id} onChange={(e) => set('warehouse_id', e.target.value)} hint="Alteração excepcional.">
            {warehouses.map((w) => (
              <option key={w.id} value={w.id}>
                {w.name}
              </option>
            ))}
          </Select>
          <Select label="Contrato" value={form.contract_id} onChange={(e) => set('contract_id', e.target.value)}>
            {(data.contracts ?? []).map((c) => (
              <option key={c.id} value={c.id}>
                {c.code} – {c.name}
              </option>
            ))}
          </Select>
          <Select label="Setor" value={form.sector_id} onChange={(e) => set('sector_id', e.target.value)}>
            {(data.sectors ?? []).map((c) => (
              <option key={c.id} value={c.id}>
                {c.name}
              </option>
            ))}
          </Select>
          <Select label="Frente / equipamento" value={form.service_front_id} onChange={(e) => set('service_front_id', e.target.value)}>
            <option value="">Não informado</option>
            {(data.service_fronts ?? []).map((c) => (
              <option key={c.id} value={c.id}>
                {c.name}
              </option>
            ))}
          </Select>
          <Input label="Ordem de serviço" value={form.service_order_text} onChange={(e) => set('service_order_text', e.target.value.toUpperCase())} maxLength={40} />
          <Input label="Ativo fixo" value={form.fixed_asset_text} onChange={(e) => set('fixed_asset_text', e.target.value.toUpperCase())} maxLength={40} />
          <Select label="Local de aplicação" value={form.application_location_id} onChange={(e) => set('application_location_id', e.target.value)}>
            <option value="">Outro / texto livre</option>
            {(data.application_locations ?? []).map((c) => (
              <option key={c.id} value={c.id}>
                {c.name}
              </option>
            ))}
          </Select>
          {!form.application_location_id && (
            <Input label="Local (texto)" value={form.application_location_text} onChange={(e) => set('application_location_text', e.target.value)} maxLength={120} />
          )}
          <Textarea label="Observações" value={form.notes} onChange={(e) => set('notes', e.target.value)} wrapClassName="sm:col-span-2" maxLength={2000} />
        </div>

        <div>
          <p className="mb-2 text-sm font-semibold text-slate-800">Quantidades dos itens</p>
          <div className="overflow-x-auto rounded-lg border border-slate-200">
            <table className="min-w-full text-sm">
              <thead className="bg-slate-50 text-xs uppercase text-slate-500">
                <tr>
                  <th className="px-3 py-2 text-left">Item</th>
                  <th className="px-3 py-2 text-left">Material</th>
                  <th className="px-3 py-2">Solicitada</th>
                  <th className="px-3 py-2">Atendida</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-100">
                {detail.items.map((i) => (
                  <tr key={i.id}>
                    <td className="px-3 py-2">{i.line_number}</td>
                    <td className="px-3 py-2">
                      {i.material_name} <span className="text-xs text-slate-500">({i.unit})</span>
                    </td>
                    <td className="px-3 py-2">
                      <input
                        className="h-9 w-24 rounded-md border-0 text-right ring-1 ring-inset ring-slate-300"
                        inputMode="decimal"
                        value={qty[i.id]?.req ?? ''}
                        onChange={(e) => setQty((q) => ({ ...q, [i.id]: { ...q[i.id], req: e.target.value } }))}
                        aria-label={`Solicitada item ${i.line_number}`}
                      />
                    </td>
                    <td className="px-3 py-2">
                      <input
                        className="h-9 w-24 rounded-md border-0 text-right ring-1 ring-inset ring-slate-300"
                        inputMode="decimal"
                        value={qty[i.id]?.del ?? ''}
                        onChange={(e) => setQty((q) => ({ ...q, [i.id]: { ...q[i.id], del: e.target.value } }))}
                        aria-label={`Atendida item ${i.line_number}`}
                      />
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>

        <Textarea label="Justificativa da correção" required value={just} onChange={(e) => setJust(e.target.value)} maxLength={500} />
        {error && <Alert tone="error">{error}</Alert>}
      </div>
    </Modal>
  );
}
