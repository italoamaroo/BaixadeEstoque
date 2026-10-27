import { Warehouse as WarehouseIcon, ChevronRight } from 'lucide-react';
import clsx from 'clsx';
import { useWarehouse } from '@/contexts/WarehouseContext';
import { Alert, Card } from '@/components/ui/Card';
import type { StepProps } from './NewMovementPage';

export function StepWarehouse({ draft, update, goTo }: StepProps) {
  const { options, setCurrentId } = useWarehouse();

  if (options.length === 0) {
    return (
      <Alert tone="warning" title="Nenhum estoque autorizado">
        Seu usuário não está vinculado a nenhum estoque. Solicite ao administrador.
      </Alert>
    );
  }

  return (
    <Card>
      <h2 className="text-lg font-semibold text-slate-900">De qual estoque o material está saindo?</h2>
      <p className="mt-1 text-sm text-slate-500">A ME será numerada e registrada no estoque escolhido.</p>
      <div className="mt-5 grid gap-3 sm:grid-cols-2">
        {options.map((w) => {
          const selected = draft.warehouse_id === w.id;
          return (
            <button
              key={w.id}
              type="button"
              onClick={() => {
                setCurrentId(w.id);
                update({ warehouse_id: w.id, details: { ...draft.details, warehouse_id: w.id } });
                goTo(1);
              }}
              className={clsx(
                'flex items-center justify-between rounded-xl border-2 p-5 text-left transition-colors',
                selected ? 'border-brand-600 bg-brand-50' : 'border-slate-200 hover:border-brand-300 hover:bg-slate-50',
              )}
            >
              <span className="flex items-center gap-4">
                <span className="flex h-12 w-12 items-center justify-center rounded-xl bg-brand-700 text-white">
                  <WarehouseIcon className="h-6 w-6" />
                </span>
                <span>
                  <span className="block text-lg font-semibold text-slate-900">{w.name}</span>
                  <span className="text-sm text-slate-500">Código {w.code}</span>
                </span>
              </span>
              <ChevronRight className="h-6 w-6 text-slate-400" />
            </button>
          );
        })}
      </div>
    </Card>
  );
}
