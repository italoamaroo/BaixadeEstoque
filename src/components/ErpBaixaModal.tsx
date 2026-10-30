import { useEffect, useState } from 'react';
import { Copy } from 'lucide-react';
import { toast } from 'sonner';
import { Modal } from './ui/Modal';
import { Button } from './ui/Button';
import { Checkbox, Input, Textarea } from './ui/Field';
import { Alert } from './ui/Card';
import { Spinner } from './ui/Spinner';
import { completeMovement, getMovementItems } from '@/lib/api';
import { errorMessage } from '@/lib/errors';
import { fmtDateTime, fmtQty } from '@/lib/format';
import type { MovementItem, MovementRow } from '@/types/db';

interface Props {
  movement: Pick<MovementRow, 'id' | 'me_number' | 'sa_number' | 'warehouse_name' | 'requester_name' | 'movement_at'> | null;
  onClose: () => void;
  onDone: () => void;
}

/** Almoxarife pega a SA informada, faz a baixa no ERP e confirma aqui (ME vai para Concluída). */
export function ErpBaixaModal({ movement, onClose, onDone }: Props) {
  const [items, setItems] = useState<MovementItem[] | null>(null);
  const [doc, setDoc] = useState('');
  const [notes, setNotes] = useState('');
  const [confirmed, setConfirmed] = useState(false);
  const [busy, setBusy] = useState(false);
  const [serverError, setServerError] = useState<string | null>(null);

  useEffect(() => {
    if (!movement) return;
    setDoc('');
    setNotes('');
    setConfirmed(false);
    setServerError(null);
    setItems(null);
    getMovementItems(movement.id)
      .then(setItems)
      .catch(() => setItems([]));
  }, [movement]);

  const copySa = async () => {
    if (!movement?.sa_number) return;
    try {
      await navigator.clipboard.writeText(movement.sa_number);
      toast.success(`SA ${movement.sa_number} copiada.`);
    } catch {
      toast.error('Não foi possível copiar. Selecione o número e copie manualmente.');
    }
  };

  const submit = async () => {
    if (!movement || busy || !confirmed) return;
    setBusy(true);
    setServerError(null);
    try {
      await completeMovement(movement.id, doc, notes);
      toast.success(`Baixa no ERP confirmada. ${movement.me_number} concluída.`);
      onDone();
      onClose();
    } catch (err) {
      setServerError(errorMessage(err));
    } finally {
      setBusy(false);
    }
  };

  return (
    <Modal
      open={Boolean(movement)}
      onClose={onClose}
      busy={busy}
      size="lg"
      title="Confirmar baixa no ERP"
      description={movement ? `${movement.me_number} · ${movement.warehouse_name} · ${movement.requester_name} · ${fmtDateTime(movement.movement_at)}` : undefined}
      footer={
        <>
          <Button variant="secondary" onClick={onClose} disabled={busy}>
            Cancelar
          </Button>
          <Button variant="success" onClick={() => void submit()} loading={busy} disabled={!confirmed}>
            Confirmar baixa
          </Button>
        </>
      }
    >
      {movement && (
        <div className="space-y-4">
          <div className="flex flex-wrap items-center justify-between gap-3 rounded-lg bg-brand-50 p-3">
            <div>
              <p className="text-xs font-semibold uppercase text-brand-800">Número da SA para a baixa no ERP</p>
              <p className="select-all font-mono text-2xl font-bold text-brand-900">{movement.sa_number}</p>
            </div>
            <Button variant="secondary" icon={<Copy className="h-4 w-4" />} onClick={() => void copySa()}>
              Copiar SA
            </Button>
          </div>

          <div>
            <p className="mb-1 text-sm font-semibold text-slate-700">Itens a baixar</p>
            {items === null ? (
              <div className="flex justify-center py-4">
                <Spinner />
              </div>
            ) : (
              <div className="max-h-56 overflow-auto rounded-lg border border-slate-200">
                <table className="w-full text-sm">
                  <thead className="sticky top-0 bg-slate-50 text-left text-xs text-slate-500">
                    <tr>
                      <th className="px-2 py-1.5">Código</th>
                      <th className="px-2 py-1.5">Material</th>
                      <th className="px-2 py-1.5 text-right">Qtd.</th>
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-slate-100">
                    {items.map((i) => (
                      <tr key={i.id}>
                        <td className="whitespace-nowrap px-2 py-1.5 font-mono text-xs">{i.material_code}</td>
                        <td className="px-2 py-1.5">{i.material_name}</td>
                        <td className="whitespace-nowrap px-2 py-1.5 text-right font-semibold">
                          {fmtQty(i.quantity_delivered)} {i.unit}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </div>

          <div className="grid gap-3 sm:grid-cols-2">
            <Input
              label="Nº do documento de baixa no ERP (opcional)"
              value={doc}
              onChange={(e) => setDoc(e.target.value)}
              maxLength={60}
              autoComplete="off"
            />
            <Textarea label="Observação (opcional)" value={notes} onChange={(e) => setNotes(e.target.value)} maxLength={500} rows={2} />
          </div>

          <Checkbox
            label={`Confirmo que realizei a baixa no ERP com a SA ${movement.sa_number ?? ''}`}
            description="Após confirmar, a ME fica Concluída e só pode ser alterada por gestor ou administrador."
            checked={confirmed}
            onChange={setConfirmed}
          />
          {serverError && <Alert tone="error">{serverError}</Alert>}
        </div>
      )}
    </Modal>
  );
}
