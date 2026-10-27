import { useEffect, useState } from 'react';
import { Minus, Plus } from 'lucide-react';
import { Modal } from '@/components/ui/Modal';
import { Button } from '@/components/ui/Button';
import { Textarea } from '@/components/ui/Field';
import { Alert } from '@/components/ui/Card';
import { MaterialInfo } from '@/components/MaterialInfo';
import { validateQuantities, type CartRules, type DuplicateMode } from '@/lib/cart';
import { fmtQty, parseQty } from '@/lib/format';
import type { CartItem, EntryMethod, Material } from '@/types/db';

export interface PendingMaterial {
  material: Material;
  entry_method: EntryMethod;
  scanned_code: string | null;
}

interface Props {
  pending: PendingMaterial | null;
  existing: CartItem | undefined;
  rules: CartRules;
  onCancel: () => void;
  onConfirm: (req: number, del: number, notes: string, mode: DuplicateMode) => void;
}

function QtyField({ label, value, onChange, unit }: { label: string; value: string; onChange: (v: string) => void; unit: string }) {
  const step = (delta: number) => {
    const n = parseQty(value);
    const next = Math.max(0, (Number.isFinite(n) ? n : 0) + delta);
    onChange(String(Math.round(next * 1000) / 1000).replace('.', ','));
  };
  return (
    <div>
      <p className="mb-1.5 text-sm font-medium text-slate-700">
        {label} <span className="text-slate-400">({unit})</span>
      </p>
      <div className="flex items-stretch">
        <button type="button" className="rounded-l-lg bg-slate-100 px-4 text-slate-700 ring-1 ring-inset ring-slate-300 hover:bg-slate-200" onClick={() => step(-1)} aria-label={`Diminuir ${label}`}>
          <Minus className="h-5 w-5" />
        </button>
        <input
          className="h-14 w-full min-w-0 border-0 text-center text-2xl font-semibold tabular-nums ring-1 ring-inset ring-slate-300 focus:ring-2 focus:ring-brand-600"
          inputMode="decimal"
          value={value}
          onChange={(e) => onChange(e.target.value.replace(/[^0-9.,]/g, ''))}
          onFocus={(e) => e.target.select()}
          aria-label={label}
        />
        <button type="button" className="rounded-r-lg bg-slate-100 px-4 text-slate-700 ring-1 ring-inset ring-slate-300 hover:bg-slate-200" onClick={() => step(1)} aria-label={`Aumentar ${label}`}>
          <Plus className="h-5 w-5" />
        </button>
      </div>
    </div>
  );
}

/** Confirma quantidades do material lido/pesquisado antes de entrar na ME. */
export function AddItemModal({ pending, existing, rules, onCancel, onConfirm }: Props) {
  const [req, setReq] = useState('1');
  const [del, setDel] = useState('1');
  const [delTouched, setDelTouched] = useState(false);
  const [notes, setNotes] = useState('');
  const [mode, setMode] = useState<DuplicateMode>('somar');
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (pending) {
      setReq('1');
      setDel('1');
      setDelTouched(false);
      setNotes('');
      setMode('somar');
      setError(null);
    }
  }, [pending]);

  const reqN = parseQty(req);
  const delN = parseQty(del);
  const short = Number.isFinite(reqN) && Number.isFinite(delN) && delN < reqN && delN > 0;

  const confirm = () => {
    const err = validateQuantities(reqN, delN, rules);
    if (err) {
      setError(err);
      return;
    }
    onConfirm(reqN, delN, notes, mode);
  };

  const m = pending?.material;
  return (
    <Modal
      open={Boolean(pending)}
      onClose={onCancel}
      title={pending?.entry_method === 'qr_code' ? 'Material identificado' : 'Adicionar material'}
      size="lg"
      footer={
        <>
          <Button variant="secondary" size="lg" onClick={onCancel}>
            Cancelar
          </Button>
          <Button size="lg" onClick={confirm} disabled={!m?.active}>
            Adicionar à ME
          </Button>
        </>
      }
    >
      {m && (
        <form
          className="space-y-5"
          onSubmit={(e) => {
            e.preventDefault();
            confirm();
          }}
        >
          <MaterialInfo material={m} />
          {!m.active && <Alert tone="error">Este material está inativo e não pode ser baixado. Procure o administrador.</Alert>}

          {m.active && (
            <>
              {existing && (
                <Alert tone="warning" title="Este material já está na ME">
                  <p>
                    Linha atual: {fmtQty(existing.quantity_requested)} solicitado(s) / {fmtQty(existing.quantity_delivered)} atendido(s).
                  </p>
                  <div className="mt-2 flex flex-wrap gap-4">
                    <label className="inline-flex items-center gap-2">
                      <input type="radio" name="mode" checked={mode === 'somar'} onChange={() => setMode('somar')} />
                      Somar à quantidade existente
                    </label>
                    {rules.allowDuplicateLines && (
                      <label className="inline-flex items-center gap-2">
                        <input type="radio" name="mode" checked={mode === 'separar'} onChange={() => setMode('separar')} />
                        Manter em linha separada
                      </label>
                    )}
                  </div>
                </Alert>
              )}
              <div className="grid gap-4 sm:grid-cols-2">
                <QtyField
                  label="Quantidade solicitada"
                  unit={m.unit}
                  value={req}
                  onChange={(v) => {
                    setReq(v);
                    if (!delTouched) setDel(v);
                    setError(null);
                  }}
                />
                <QtyField
                  label="Quantidade atendida"
                  unit={m.unit}
                  value={del}
                  onChange={(v) => {
                    setDel(v);
                    setDelTouched(true);
                    setError(null);
                  }}
                />
              </div>
              {short && (
                <Alert tone="warning">
                  Atendido {fmtQty(reqN - delN)} {m.unit} a menos que o solicitado. Se quiser, registre o motivo abaixo.
                </Alert>
              )}
              <Textarea
                label={short ? 'Observação do item (motivo da diferença)' : 'Observação do item (opcional)'}
                value={notes}
                onChange={(e) => setNotes(e.target.value)}
                maxLength={500}
                rows={2}
              />
              {error && <Alert tone="error">{error}</Alert>}
              <button type="submit" className="hidden" />
            </>
          )}
        </form>
      )}
    </Modal>
  );
}
