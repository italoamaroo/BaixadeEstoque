import { useEffect, useRef, useState } from 'react';
import { toast } from 'sonner';
import { Modal } from '@/components/ui/Modal';
import { Button } from '@/components/ui/Button';
import { Textarea } from '@/components/ui/Field';
import { Alert } from '@/components/ui/Card';
import { SignaturePad } from '@/components/SignaturePad';
import { EmployeePicker } from '@/components/EmployeePicker';
import { useAuth } from '@/contexts/AuthContext';
import { replaceSignature, uploadSignature, withRetry, type MovementDetail } from '@/lib/api';
import { errorMessage } from '@/lib/errors';
import { buildSignaturePath, dataUrlToBlob } from '@/lib/signature';
import { justificationSchema } from '@/lib/validation';
import type { Employee } from '@/types/db';

interface Props {
  open: boolean;
  detail: MovementDetail;
  onClose: () => void;
  onDone: () => void;
}

/** Nova assinatura (gestor/admin). A anterior permanece no histórico. */
export function ReplaceSignatureModal({ open, detail, onClose, onDone }: Props) {
  const { settings } = useAuth();
  const m = detail.movement;
  const exporter = useRef<() => string | null>(() => null);
  const [employee, setEmployee] = useState<Employee | null>(null);
  const [reason, setReason] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [uploadedPath, setUploadedPath] = useState<string | null>(null);

  useEffect(() => {
    if (open) {
      setEmployee(
        m.received_by_employee_id
          ? ({ id: m.received_by_employee_id, full_name: m.received_by_name ?? '', registration: m.received_by_registration ?? '', job_title: null, sector_id: null, active: true } as Employee)
          : null,
      );
      setReason('');
      setError(null);
      setUploadedPath(null);
    }
  }, [open, m]);

  const submit = async () => {
    if (busy) return;
    if (!employee) return setError('Identifique o funcionário que está assinando.');
    const r = justificationSchema.safeParse(reason);
    if (!r.success) return setError(r.error.issues[0].message);
    let path = uploadedPath;
    if (!path) {
      const dataUrl = exporter.current();
      if (!dataUrl) return setError('A assinatura está vazia.');
      path = buildSignaturePath(m.warehouse_code, m.id, settings?.timezone);
      setBusy(true);
      setError(null);
      try {
        await withRetry(() => uploadSignature(path as string, dataUrlToBlob(dataUrl)));
        setUploadedPath(path);
      } catch (err) {
        setBusy(false);
        return setError(errorMessage(err));
      }
    }
    setBusy(true);
    try {
      await replaceSignature(m.id, path, employee.id, reason.trim());
      toast.success('Nova assinatura registrada. A anterior foi mantida no histórico.');
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
      size="lg"
      title="Coletar nova assinatura"
      description={`${m.me_number} · ${m.warehouse_name}`}
      footer={
        <>
          <Button variant="secondary" onClick={onClose} disabled={busy}>
            Cancelar
          </Button>
          <Button onClick={() => void submit()} loading={busy}>
            Registrar nova assinatura
          </Button>
        </>
      }
    >
      <div className="space-y-4">
        <Alert tone="warning">A assinatura atual não será apagada: ela fica no histórico como substituída, com seu usuário, data, hora e justificativa.</Alert>
        <EmployeePicker label="Funcionário que assina" value={employee} onChange={setEmployee} />
        {uploadedPath ? (
          <Alert tone="info">Assinatura já enviada. Toque em “Registrar nova assinatura” para concluir.</Alert>
        ) : (
          open && (
            <SignaturePad
              onChange={() => setError(null)}
              registerExporter={(fn) => {
                exporter.current = fn;
              }}
            />
          )
        )}
        <Textarea label="Justificativa" required value={reason} onChange={(e) => setReason(e.target.value)} maxLength={500} />
        {error && <Alert tone="error">{error}</Alert>}
      </div>
    </Modal>
  );
}
