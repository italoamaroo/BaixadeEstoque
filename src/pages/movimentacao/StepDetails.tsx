import { useState } from 'react';
import { ArrowLeft, ArrowRight } from 'lucide-react';
import { useLookups } from '@/hooks/useLookups';
import { Button } from '@/components/ui/Button';
import { Input, Select, Textarea } from '@/components/ui/Field';
import { Alert, Card } from '@/components/ui/Card';
import { PageLoader } from '@/components/ui/Spinner';
import { fieldErrors, movementDetailsSchema, type MovementDetails } from '@/lib/validation';
import type { StepProps } from './NewMovementPage';

export function StepDetails({ draft, update, next, back }: StepProps) {
  const { data, loading, error } = useLookups(['contracts', 'sectors', 'service_fronts', 'service_orders', 'fixed_assets', 'application_locations']);
  const [errors, setErrors] = useState<Record<string, string>>({});
  const d = draft.details;

  const set = <K extends keyof MovementDetails>(k: K, v: MovementDetails[K]) => {
    update({ details: { ...d, [k]: v } });
    setErrors((e) => ({ ...e, [k]: '' }));
  };

  const proceed = () => {
    const r = movementDetailsSchema.safeParse({ ...d, warehouse_id: draft.warehouse_id });
    const errs = fieldErrors(r);
    setErrors(errs);
    if (Object.keys(errs).length === 0) next();
  };

  if (loading && !data.contracts) return <PageLoader label="Carregando cadastros…" />;

  const fronts = data.service_fronts ?? [];
  return (
    <div className="space-y-4">
      <Card>
        <h2 className="text-lg font-semibold text-slate-900">Dados da movimentação</h2>
        <p className="mb-5 text-sm text-slate-500">Mesmos campos do formulário de Movimentação de Estoque.</p>
        {error && <Alert tone="error">{error}</Alert>}
        <div className="grid gap-4 sm:grid-cols-2">
          <Select label="Contrato" required value={d.contract_id} onChange={(e) => set('contract_id', e.target.value)} error={errors.contract_id} inputSize="lg">
            <option value="">Selecione…</option>
            {(data.contracts ?? []).map((c) => (
              <option key={c.id} value={c.id}>
                {c.code} – {c.name}
              </option>
            ))}
          </Select>
          <Select label="Setor" required value={d.sector_id} onChange={(e) => set('sector_id', e.target.value)} error={errors.sector_id} inputSize="lg">
            <option value="">Selecione…</option>
            {(data.sectors ?? []).map((c) => (
              <option key={c.id} value={c.id}>
                {c.name}
              </option>
            ))}
          </Select>
          <Select
            label="Frente de serviço / equipamento"
            value={d.service_front_id ?? ''}
            onChange={(e) => set('service_front_id', e.target.value)}
            inputSize="lg"
            wrapClassName="sm:col-span-2"
          >
            <option value="">Não informado</option>
            {['frente', 'equipamento'].map((kind) => (
              <optgroup key={kind} label={kind === 'frente' ? 'Frentes de serviço' : 'Equipamentos'}>
                {fronts
                  .filter((f) => (f.kind ?? 'frente') === kind)
                  .map((f) => (
                    <option key={f.id} value={f.id}>
                      {f.name}
                    </option>
                  ))}
              </optgroup>
            ))}
          </Select>
          <Input
            label="Ordem de serviço"
            value={d.service_order_text ?? ''}
            onChange={(e) => set('service_order_text', e.target.value.toUpperCase())}
            list="os-list"
            maxLength={40}
            error={errors.service_order_text}
            inputSize="lg"
            hint="Digite ou escolha uma OS cadastrada."
          />
          <datalist id="os-list">
            {(data.service_orders ?? []).map((o) => (
              <option key={o.id} value={o.code}>
                {o.name}
              </option>
            ))}
          </datalist>
          <Input
            label="Ativo fixo (AF)"
            value={d.fixed_asset_text ?? ''}
            onChange={(e) => set('fixed_asset_text', e.target.value.toUpperCase())}
            list="af-list"
            maxLength={40}
            error={errors.fixed_asset_text}
            inputSize="lg"
          />
          <datalist id="af-list">
            {(data.fixed_assets ?? []).map((o) => (
              <option key={o.id} value={o.code}>
                {o.name}
              </option>
            ))}
          </datalist>
          <Select
            label="Local de aplicação"
            value={d.application_location_id ?? ''}
            onChange={(e) => set('application_location_id', e.target.value)}
            inputSize="lg"
          >
            <option value="">Outro / não cadastrado</option>
            {(data.application_locations ?? []).map((c) => (
              <option key={c.id} value={c.id}>
                {c.name}
              </option>
            ))}
          </Select>
          {!d.application_location_id && (
            <Input
              label="Descreva o local de aplicação"
              value={d.application_location_text ?? ''}
              onChange={(e) => set('application_location_text', e.target.value)}
              maxLength={120}
              inputSize="lg"
            />
          )}
          <Textarea
            label="Observações"
            value={d.notes ?? ''}
            onChange={(e) => set('notes', e.target.value)}
            maxLength={2000}
            wrapClassName="sm:col-span-2"
            error={errors.notes}
          />
        </div>
      </Card>
      <div className="sticky bottom-20 z-10 flex gap-3 lg:bottom-4">
        <Button variant="secondary" size="lg" icon={<ArrowLeft className="h-5 w-5" />} onClick={back}>
          Voltar
        </Button>
        <Button size="lg" block icon={<ArrowRight className="h-5 w-5" />} onClick={proceed}>
          Continuar
        </Button>
      </div>
    </div>
  );
}
