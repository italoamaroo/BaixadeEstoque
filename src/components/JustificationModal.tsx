import { useEffect, useState, type ReactNode } from 'react';
import { Modal } from './ui/Modal';
import { Button } from './ui/Button';
import { Textarea } from './ui/Field';
import { justificationSchema } from '@/lib/validation';

interface Props {
  open: boolean;
  title: string;
  description?: ReactNode;
  confirmLabel: string;
  tone?: 'danger' | 'primary';
  busy?: boolean;
  /** quando false, a justificativa é opcional */
  required?: boolean;
  onClose: () => void;
  onConfirm: (justification: string) => void | Promise<void>;
  children?: ReactNode;
}

/** Confirmação com justificativa obrigatória (cancelamentos e correções). */
export function JustificationModal({ open, title, description, confirmLabel, tone = 'primary', busy, required = true, onClose, onConfirm, children }: Props) {
  const [text, setText] = useState('');
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (open) {
      setText('');
      setError(null);
    }
  }, [open]);

  const submit = () => {
    if (required) {
      const r = justificationSchema.safeParse(text);
      if (!r.success) {
        setError(r.error.issues[0].message);
        return;
      }
    }
    void onConfirm(text.trim());
  };

  return (
    <Modal
      open={open}
      onClose={onClose}
      title={title}
      description={description}
      busy={busy}
      footer={
        <>
          <Button variant="secondary" onClick={onClose} disabled={busy}>
            Voltar
          </Button>
          <Button variant={tone === 'danger' ? 'danger' : 'primary'} onClick={submit} loading={busy}>
            {confirmLabel}
          </Button>
        </>
      }
    >
      <div className="space-y-4">
        {children}
        <Textarea
          label={required ? 'Justificativa' : 'Observação (opcional)'}
          required={required}
          value={text}
          onChange={(e) => {
            setText(e.target.value);
            setError(null);
          }}
          error={error}
          maxLength={500}
          rows={4}
          hint="Fica registrada no histórico e na auditoria."
        />
      </div>
    </Modal>
  );
}
