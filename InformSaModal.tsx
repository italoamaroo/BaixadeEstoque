import { useEffect, useState } from 'react';
import { toast } from 'sonner';
import { Modal } from './ui/Modal';
import { Button } from './ui/Button';
import { Input, Textarea } from './ui/Field';
import { Alert, KeyValue } from './ui/Card';
import { informSa } from '@/lib/api';
import { errorMessage } from '@/lib/errors';
import { saNumberError, justificationSchema } from '@/lib/validation';
import { useAuth } from '@/contexts/AuthContext';
import { fmtDateTime } from '@/lib/format';
import type { MovementRow } from '@/types/db';

interface Props {
  movement: Pick<MovementRow, 'id' | 'me_number' | 'status' | 'sa_number' | 'warehouse_name' | 'requester_name' | 'movement_at' | 'item_count'> | null;
  onClose: () => void;
  onDone: () => void;
}

/** Inclusão ou correção do número da SA lançado no ERP. */
export function InformSaModal({ movement, onClose, onDone }: Props) {
  const { settings, can } = useAuth();
  const [sa, setSa] = useState('');
  const [just, setJust] = useState('');
  const [errors, setErrors] = useState<{ sa?: string; just?: string }>({});
  const [busy, setBusy] = useState(false);
  const [serverError, setServerError] = useState<string | null>(null);

  const isCorrection = Boolean(movement && movement.status !== 'aguardando_sa');
  const blocked = Boolean(movement && movement.status === 'concluida' && !can('correctSaAfterCompletion'));

  useEffect(() => {
    if (movement) {
      setSa(movement.sa_number ?? '');
      setJust('');
      setErrors({});
      setServerError(null);
    }
  }, [movement]);

  const submit = async () => {
    if (!movement || busy) return;
    const e: typeof errors = {};
    const saErr = saNumberError(sa, settings?.sa_number_pattern ?? '^[A-Za-z0-9./-]{3,30}$');
    if (saErr) e.sa = saErr;
    if (isCorrection) {
      if (sa.trim().toUpperCase() === (movement.sa_number ?? '').toUpperCase()) e.sa = 'Informe um número diferente do atual.';
      const r = justificationSchema.safeParse(just);
      if (!r.success) e.just = r.error.issues[0].message;
    }
    setErrors(e);
    if (Object.keys(e).length) return;

    setBusy(true);
    setServerError(null);
    try {
      const res = await informSa(movement.id, sa.trim().toUpperCase(), isCorrection ? just.trim() : undefined);
      toast.success(isCorrection ? `SA da ${movement.me_number} corrigida para ${res.sa_number}.` : `SA ${res.sa_number} informada na ${movement.me_number}.`);
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
      title={isCorrection ? 'Corrigir número da SA' : 'Informar número da SA'}
      description={movement ? `${movement.me_number} · ${movement.warehouse_name}` : undefined}
      footer={
        <>
          <Button variant="secondary" onClick={onClose} disabled={busy}>
            Cancelar
          </Button>
          <Button onClick={() => void submit()} loading={busy} disabled={blocked}>
            {isCorrection ? 'Salvar correção' : 'Informar SA'}
          </Button>
        </>
      }
    >
      {movement && (
        <form
          className="space-y-4"
          onSubmit={(e) => {
            e.preventDefault();
            void submit();
          }}
        >
          <dl className="grid grid-cols-2 gap-3 rounded-lg bg-slate-50 p-3">
            <KeyValue label="Data" value={fmtDateTime(movement.movement_at)} />
            <KeyValue label="Requisitante" value={movement.requester_name} />
            <KeyValue label="Itens" value={movement.item_count} />
            <KeyValue label="SA atual" value={movement.sa_number} />
          </dl>
          {blocked && <Alert tone="warning">A ME está concluída. Somente gestor ou administrador pode corrigir a SA.</Alert>}
          <Input
            label="Número da SA"
            required
            value={sa}
            onChange={(e) => {
              setSa(e.target.value.toUpperCase());
              setErrors((x) => ({ ...x, sa: undefined }));
            }}
            error={errors.sa}
            placeholder="Ex.: SA-2026-012345"
            autoComplete="off"
            inputSize="lg"
            maxLength={30}
            data-autofocus
          />
          {isCorrection && (
            <Textarea
              label="Justificativa da correção"
              required
              value={just}
              onChange={(e) => {
                setJust(e.target.value);
                setErrors((x) => ({ ...x, just: undefined }));
              }}
              error={errors.just}
              maxLength={500}
            />
          )}
          {serverError && <Alert tone="error">{serverError}</Alert>}
          <button type="submit" className="hidden" />
        </form>
      )}
    </Modal>
  );
}
