import { Siren } from 'lucide-react';
import clsx from 'clsx';
import { Checkbox, Textarea } from './ui/Field';

/**
 * ME emergencial: retirada registrada só para controle.
 * Não vai para a equipe de SA nem para a baixa no ERP.
 */
export function EmergencyFields({
  emergency,
  reason,
  onEmergency,
  onReason,
  error,
  className,
}: {
  emergency: boolean;
  reason: string;
  onEmergency: (v: boolean) => void;
  onReason: (v: string) => void;
  error?: string | null;
  className?: string;
}) {
  return (
    <div className={clsx('rounded-xl p-4 ring-1 ring-inset', emergency ? 'bg-orange-50 ring-orange-300' : 'bg-slate-50 ring-slate-200', className)}>
      <div className="flex items-start gap-3">
        <Siren className={clsx('mt-0.5 h-5 w-5 shrink-0', emergency ? 'text-orange-600' : 'text-slate-400')} aria-hidden />
        <Checkbox
          label="Retirada emergencial (ME só para controle)"
          description="Não vai para a equipe de SA nem para a baixa no ERP. Fica concluída assim que for confirmada."
          checked={emergency}
          onChange={onEmergency}
        />
      </div>
      {emergency && (
        <Textarea
          label="Motivo da emergência"
          required
          value={reason}
          onChange={(e) => onReason(e.target.value)}
          maxLength={500}
          rows={2}
          error={error}
          wrapClassName="mt-3"
          placeholder="Ex.: equipamento parado fora do horário do almoxarifado"
        />
      )}
    </div>
  );
}
