import { CheckCircle2, CloudOff, FileText, PackageMinus, Printer } from 'lucide-react';
import { Button, LinkButton } from '@/components/ui/Button';
import { Card } from '@/components/ui/Card';
import { StatusBadge } from '@/components/ui/Badge';
import type { MovementStatus } from '@/types/db';
import type { CreatedInfo } from './NewMovementPage';

export function StepSuccess({ created, onNew }: { created: CreatedInfo; onNew: () => void }) {
  if (created.offline) {
    return (
      <div className="mx-auto max-w-lg">
        <Card className="text-center">
          <div className="mx-auto mb-4 flex h-16 w-16 items-center justify-center rounded-full bg-amber-100">
            <CloudOff className="h-9 w-9 text-amber-700" />
          </div>
          <p className="text-lg font-bold text-slate-900">Saída guardada no aparelho</p>
          <p className="mt-1 font-mono text-sm text-slate-500">Identificador provisório {created.id.slice(0, 8).toUpperCase()}</p>
          <p className="mt-3 text-slate-600">
            Estoque {created.warehouse_name}. Ela será enviada sozinha quando a internet voltar e receberá o número oficial da ME nesse momento,
            com a data e a hora reais da retirada.
          </p>
          <p className="mt-2 text-sm font-medium text-amber-800">Não limpe os dados do navegador nem troque de aparelho antes do envio.</p>
          <div className="mt-6 grid gap-2">
            <Button size="xl" icon={<PackageMinus className="h-6 w-6" />} onClick={onNew}>
              Nova saída
            </Button>
            <LinkButton to="/saidas-offline" variant="secondary" size="lg" block icon={<CloudOff className="h-5 w-5" />}>
              Ver saídas guardadas
            </LinkButton>
          </div>
        </Card>
      </div>
    );
  }
  return (
    <div className="mx-auto max-w-lg">
      <Card className="text-center">
        <div className="mx-auto mb-4 flex h-16 w-16 items-center justify-center rounded-full bg-emerald-100">
          <CheckCircle2 className="h-10 w-10 text-emerald-600" />
        </div>
        <p className="text-sm font-medium text-slate-500">ME confirmada pelo servidor</p>
        <p className="mt-1 font-mono text-2xl font-bold tracking-tight text-slate-900 sm:text-3xl">{created.me_number}</p>
        <p className="mt-2 text-slate-600">Estoque {created.warehouse_name}</p>
        <div className="mt-3 flex justify-center">
          <StatusBadge status={created.status as MovementStatus} emergency={created.emergency} />
        </div>
        <p className="mt-4 text-sm text-slate-500">
          {created.emergency
            ? 'ME emergencial registrada só para controle: não vai para a equipe de SA nem para a baixa no ERP.'
            : created.status === 'sa_informada'
              ? 'A movimentação já aparece no painel. Sem ativo fixo, vai direto para o almoxarifado lançar no ERP.'
              : 'A movimentação já aparece no painel. A equipe de lançamento informará o número da SA após o registro no ERP.'}
        </p>
        <div className="mt-6 grid gap-2">
          <Button size="xl" icon={<PackageMinus className="h-6 w-6" />} onClick={onNew}>
            Nova saída
          </Button>
          <LinkButton to={`/movimentacoes/${created.id}`} variant="secondary" size="lg" block icon={<FileText className="h-5 w-5" />}>
            Ver ME
          </LinkButton>
          <LinkButton to={`/movimentacoes/${created.id}?imprimir=1`} variant="ghost" size="lg" block icon={<Printer className="h-5 w-5" />}>
            Imprimir comprovante
          </LinkButton>
        </div>
      </Card>
    </div>
  );
}
