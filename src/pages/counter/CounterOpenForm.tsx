import { useState } from 'react';
import { ScanLine } from 'lucide-react';
import { useLookups } from '@/hooks/useLookups';
import { useWarehouse } from '@/contexts/WarehouseContext';
import { EmployeePicker } from '@/components/EmployeePicker';
import { Button } from '@/components/ui/Button';
import { Checkbox, Input, Select, Textarea } from '@/components/ui/Field';
import { Alert, Card } from '@/components/ui/Card';
import { PageLoader } from '@/components/ui/Spinner';
import { counterOpen } from '@/lib/api';
import { errorMessage } from '@/lib/errors';
import type { Employee } from '@/types/db';

const REUSE_KEY = 'baixas-estoque:balcao-reusar-tablet';

/** Abertura da separação no balcão: estoque, solicitante e dados da ME. */
export function CounterOpenForm({ onOpened }: { onOpened: (movementId: string) => void }) {
  const { current, options, setCurrentId } = useWarehouse();
  const { data, loading, error } = useLookups(['contracts', 'sectors', 'service_fronts', 'fixed_assets', 'application_locations']);
  const [requester, setRequester] = useState<Employee | null>(null);
  const [f, setF] = useState({
    contract_id: '',
    sector_id: '',
    service_front_id: '',
    service_order_text: '',
    fixed_asset_text: '',
    application_location_id: '',
    notes: '',
  });
  const [reuse, setReuse] = useState(() => {
    try {
      return localStorage.getItem(REUSE_KEY) !== 'nao';
    } catch {
      return true;
    }
  });
  const [errors, setErrors] = useState<Record<string, string>>({});
  const [busy, setBusy] = useState(false);
  const [serverError, setServerError] = useState<string | null>(null);
  const [movementId] = useState(() => crypto.randomUUID());

  const set = (k: keyof typeof f, v: string) => {
    setF((x) => ({ ...x, [k]: v }));
    setErrors((e) => ({ ...e, [k]: '' }));
  };

  const submit = async () => {
    const errs: Record<string, string> = {};
    if (!current) errs.warehouse = 'Selecione o estoque.';
    if (!requester) errs.requester = 'Identifique o solicitante.';
    if (!f.contract_id) errs.contract_id = 'Selecione o contrato.';
    if (!f.sector_id) errs.sector_id = 'Selecione o setor.';
    setErrors(errs);
    if (Object.keys(errs).length || !current || !requester || busy) return;
    setBusy(true);
    setServerError(null);
    try {
      try {
        localStorage.setItem(REUSE_KEY, reuse ? 'sim' : 'nao');
      } catch {
        /* ignore */
      }
      const r = await counterOpen({
        id: movementId,
        warehouse_id: current.id,
        contract_id: f.contract_id,
        sector_id: f.sector_id,
        service_front_id: f.service_front_id || null,
        service_order_text: f.service_order_text || null,
        fixed_asset_text: f.fixed_asset_text || null,
        application_location_id: f.application_location_id || null,
        notes: f.notes || null,
        requester_employee_id: requester.id,
        reuse_terminal: reuse,
      });
      onOpened(r.id);
    } catch (e) {
      setServerError(errorMessage(e));
    } finally {
      setBusy(false);
    }
  };

  if (loading && !data.contracts) return <PageLoader label="Carregando cadastros…" />;
  const fronts = data.service_fronts ?? [];

  return (
    <Card>
      <h2 className="text-lg font-semibold text-slate-900">Nova separação no balcão</h2>
      <p className="mb-5 text-sm text-slate-500">
        Identifique o solicitante e os dados da ME. Depois é só bipar os materiais com o leitor; o solicitante acompanha no tablet.
      </p>
      {error && <Alert tone="error">{error}</Alert>}
      <div className="grid gap-4 sm:grid-cols-2">
        <Select
          label="Estoque"
          required
          value={current?.id ?? ''}
          onChange={(e) => setCurrentId(e.target.value)}
          error={errors.warehouse}
          inputSize="lg"
        >
          <option value="">Selecione…</option>
          {options.map((w) => (
            <option key={w.id} value={w.id}>
              {w.name}
            </option>
          ))}
        </Select>
        <div className="sm:col-span-2">
          <EmployeePicker label="Solicitante (quem vai retirar)" value={requester} onChange={setRequester} />
          {errors.requester && <p className="mt-1 text-sm text-red-600">{errors.requester}</p>}
        </div>
        <Select label="Contrato" required value={f.contract_id} onChange={(e) => set('contract_id', e.target.value)} error={errors.contract_id} inputSize="lg">
          <option value="">Selecione…</option>
          {(data.contracts ?? []).map((c) => (
            <option key={c.id} value={c.id}>
              {c.code} – {c.name}
            </option>
          ))}
        </Select>
        <Select label="Setor" required value={f.sector_id} onChange={(e) => set('sector_id', e.target.value)} error={errors.sector_id} inputSize="lg">
          <option value="">Selecione…</option>
          {(data.sectors ?? []).map((c) => (
            <option key={c.id} value={c.id}>
              {c.name}
            </option>
          ))}
        </Select>
        <Select label="Frente de serviço / equipamento" value={f.service_front_id} onChange={(e) => set('service_front_id', e.target.value)} inputSize="lg">
          <option value="">Não informado</option>
          {['frente', 'equipamento'].map((kind) => (
            <optgroup key={kind} label={kind === 'frente' ? 'Frentes de serviço' : 'Equipamentos'}>
              {fronts
                .filter((x) => (x.kind ?? 'frente') === kind)
                .map((x) => (
                  <option key={x.id} value={x.id}>
                    {x.name}
                  </option>
                ))}
            </optgroup>
          ))}
        </Select>
        <Input label="Ordem de serviço" value={f.service_order_text} onChange={(e) => set('service_order_text', e.target.value.toUpperCase())} maxLength={40} inputSize="lg" />
        <Input
          label="Ativo fixo (AF)"
          value={f.fixed_asset_text}
          onChange={(e) => set('fixed_asset_text', e.target.value.toUpperCase())}
          list="balcao-af-list"
          maxLength={40}
          inputSize="lg"
          hint={
            f.fixed_asset_text.trim()
              ? 'Com ativo fixo: depois da confirmação, a ME vai para a equipe de SA.'
              : 'Sem ativo fixo: depois da confirmação, vai direto para a baixa no ERP.'
          }
        />
        <datalist id="balcao-af-list">
          {(data.fixed_assets ?? []).map((o) => (
            <option key={o.id} value={o.code}>
              {o.name}
            </option>
          ))}
        </datalist>
        <Select label="Local de aplicação" value={f.application_location_id} onChange={(e) => set('application_location_id', e.target.value)} inputSize="lg">
          <option value="">Não informado</option>
          {(data.application_locations ?? []).map((o) => (
            <option key={o.id} value={o.id}>
              {o.name}
            </option>
          ))}
        </Select>
        <Textarea label="Observações" value={f.notes} onChange={(e) => set('notes', e.target.value)} maxLength={2000} rows={2} wrapClassName="sm:col-span-2" />
        <div className="sm:col-span-2">
          <Checkbox
            label="Usar o mesmo tablet da separação anterior"
            description="Se o tablet estiver livre, ele passa a mostrar esta ME sem precisar digitar o código."
            checked={reuse}
            onChange={setReuse}
          />
        </div>
      </div>
      {serverError && (
        <div className="mt-4">
          <Alert tone="error">{serverError}</Alert>
        </div>
      )}
      <div className="mt-5">
        <Button size="lg" icon={<ScanLine className="h-5 w-5" />} onClick={() => void submit()} loading={busy}>
          Abrir separação
        </Button>
      </div>
    </Card>
  );
}
