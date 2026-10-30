import { useEffect, useState } from 'react';
import { toast } from 'sonner';
import { Save } from 'lucide-react';
import { Button } from '@/components/ui/Button';
import { Alert, Card, CardHeader, PageHeader } from '@/components/ui/Card';
import { Checkbox, Input } from '@/components/ui/Field';
import { PageLoader } from '@/components/ui/Spinner';
import { useAuth } from '@/contexts/AuthContext';
import { getSettings, updateSettings } from '@/lib/api';
import { errorMessage } from '@/lib/errors';
import type { Settings } from '@/types/db';

export function previewNumber(s: Pick<Settings, 'me_number_pattern' | 'me_prefix' | 'me_sequence_digits'>, code = 'MUR', year = new Date().getFullYear(), seq = 1) {
  return s.me_number_pattern
    .replace('{PREFIXO}', s.me_prefix)
    .replace('{ESTOQUE}', code)
    .replace('{ANO}', String(year))
    .replace('{SEQ}', String(seq).padStart(Number(s.me_sequence_digits) || 6, '0'));
}

export function SettingsPage() {
  const { refreshAccess, warehouses } = useAuth();
  const [s, setS] = useState<Settings | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    getSettings().then(setS).catch((e) => setError(errorMessage(e)));
  }, []);

  if (!s) return error ? <Alert tone="error">{error}</Alert> : <PageLoader />;
  const set = <K extends keyof Settings>(k: K, v: Settings[K]) => setS((x) => (x ? { ...x, [k]: v } : x));

  const save = async () => {
    if (!s.me_number_pattern.includes('{SEQ}')) return setError('O formato precisa conter {SEQ}.');
    if (!/^[A-Z0-9]{1,6}$/.test(s.me_prefix)) return setError('Prefixo: 1 a 6 letras maiúsculas ou números.');
    try {
      new RegExp(s.sa_number_pattern);
    } catch {
      return setError('Expressão da SA inválida.');
    }
    setBusy(true);
    setError(null);
    try {
      setS(await updateSettings(s));
      await refreshAccess();
      toast.success('Parâmetros salvos.');
    } catch (err) {
      setError(errorMessage(err));
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="max-w-3xl space-y-4">
      <PageHeader title="Configurações" subtitle="Parâmetros gerais. Toda alteração fica registrada na auditoria." />
      <Card>
        <CardHeader title="Numeração da ME" subtitle="Gerada no banco de dados, por estoque e por ano, sem duplicidade." />
        <div className="grid gap-4 sm:grid-cols-3">
          <Input label="Prefixo" value={s.me_prefix} onChange={(e) => set('me_prefix', e.target.value.toUpperCase())} maxLength={6} />
          <Input label="Formato" value={s.me_number_pattern} onChange={(e) => set('me_number_pattern', e.target.value)} wrapClassName="sm:col-span-2" hint="Use {PREFIXO}, {ESTOQUE}, {ANO} e {SEQ}." />
          <Input label="Dígitos da sequência" type="number" min={3} max={10} value={s.me_sequence_digits} onChange={(e) => set('me_sequence_digits', Number(e.target.value))} />
        </div>
        <p className="mt-3 text-sm text-slate-600">
          Exemplo:{' '}
          {(warehouses.length ? warehouses : [{ code: 'MUR' }]).map((w) => (
            <code key={w.code} className="mr-2 rounded bg-slate-100 px-2 py-0.5 font-mono">
              {previewNumber(s, w.code)}
            </code>
          ))}
        </p>
      </Card>
      <Card>
        <CardHeader title="Regras da operação" />
        <div className="space-y-4">
          <Checkbox label="Exigir aprovação do gestor" description="A ME fica “Aguardando aprovação” antes de seguir para a SA." checked={s.require_approval} onChange={(v) => set('require_approval', v)} />
          <Checkbox label="Permitir quantidade atendida maior que a solicitada" checked={s.allow_delivered_above_requested} onChange={(v) => set('allow_delivered_above_requested', v)} />
          <Checkbox label="Permitir o mesmo material em linhas separadas na ME" description="Se desligado, leituras repetidas somam na mesma linha." checked={s.allow_duplicate_material_lines} onChange={(v) => set('allow_duplicate_material_lines', v)} />
          <Checkbox label="Concluir a ME automaticamente ao informar a SA (dispensa a confirmação da baixa no ERP pelo almoxarife)" checked={s.auto_complete_on_sa} onChange={(v) => set('auto_complete_on_sa', v)} />
        </div>
      </Card>
      <Card>
        <CardHeader title="SA (ERP)" />
        <div className="space-y-4">
          <Checkbox label="Número da SA único" description="Impede vincular a mesma SA a duas MEs (exceto canceladas)." checked={s.sa_number_unique} onChange={(v) => set('sa_number_unique', v)} />
          <Input label="Formato aceito (expressão regular)" value={s.sa_number_pattern} onChange={(e) => set('sa_number_pattern', e.target.value)} hint="Padrão: ^[A-Za-z0-9./-]{3,30}$" />
        </div>
      </Card>
      <Card>
        <CardHeader title="Geral" />
        <div className="grid gap-4 sm:grid-cols-2">
          <Input label="Nome da empresa (cabeçalho e impressão)" value={s.company_name} onChange={(e) => set('company_name', e.target.value)} />
          <Input label="Fuso horário" value={s.timezone} onChange={(e) => set('timezone', e.target.value)} hint="Ex.: America/Recife" />
        </div>
      </Card>
      {error && <Alert tone="error">{error}</Alert>}
      <div className="flex justify-end">
        <Button size="lg" icon={<Save className="h-5 w-5" />} loading={busy} onClick={() => void save()}>
          Salvar parâmetros
        </Button>
      </div>
    </div>
  );
}
