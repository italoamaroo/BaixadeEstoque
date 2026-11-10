import { useState } from 'react';
import { ArrowLeft, ArrowRight } from 'lucide-react';
import { EmployeePicker } from '@/components/EmployeePicker';
import { Button } from '@/components/ui/Button';
import { Alert, Card } from '@/components/ui/Card';
import { Checkbox } from '@/components/ui/Field';
import type { StepProps } from './NewMovementPage';

export function StepRequester({ draft, update, next, back }: StepProps) {
  const [otherReceiver, setOtherReceiver] = useState(Boolean(draft.receiver));
  const [error, setError] = useState<string | null>(null);

  const clearSignatureIfNeeded = () =>
    draft.signature_data_url ? { signature_data_url: null, signature_signed_at: null, signature_path: null } : {};

  const proceed = () => {
    if (!draft.requester) return setError('Identifique o funcionário requisitante.');
    if (otherReceiver && !draft.receiver) return setError('Identifique o funcionário que recebeu o material ou desmarque a opção.');
    setError(null);
    next();
  };

  return (
    <div className="space-y-4">
      <Card>
        <h2 className="text-lg font-semibold text-slate-900">Requisitante</h2>
        <p className="mb-5 text-sm text-slate-500">Quem solicitou o material. Por padrão, é também quem recebe e assina.</p>
        <div className="space-y-5">
          <EmployeePicker
            label="Funcionário requisitante"
            value={draft.requester}
            onChange={(e) => {
              update({ requester: e, ...clearSignatureIfNeeded() });
              setError(null);
            }}
          />
          <Checkbox
            label="Outra pessoa vai receber o material"
            description="Marque se quem retira e assina não é o requisitante."
            checked={otherReceiver}
            onChange={(v) => {
              setOtherReceiver(v);
              if (!v) update({ receiver: null, ...clearSignatureIfNeeded() });
            }}
          />
          {otherReceiver && (
            <EmployeePicker
              label="Funcionário que recebeu"
              value={draft.receiver}
              onChange={(e) => {
                update({ receiver: e, ...clearSignatureIfNeeded() });
                setError(null);
              }}
            />
          )}
          {error && <Alert tone="error">{error}</Alert>}
        </div>
      </Card>
      <div className="sticky bottom-20 z-10 flex gap-3 lg:bottom-4">
        <Button variant="secondary" size="lg" icon={<ArrowLeft className="h-5 w-5" />} onClick={back}>
          Voltar
        </Button>
        <Button size="lg" block icon={<ArrowRight className="h-5 w-5" />} onClick={proceed}>
          Ir para assinatura
        </Button>
      </div>
    </div>
  );
}
