import { useEffect, useState } from 'react';
import { Check, Minus } from 'lucide-react';
import { LinkButton } from '@/components/ui/Button';
import { Card, PageHeader } from '@/components/ui/Card';
import { adminListUsers } from '@/lib/api';
import { PERMISSIONS, ROLE_DESCRIPTIONS, ROLE_LABELS, type Permission } from '@/lib/constants';
import type { AppRole } from '@/types/db';

const ROLES: AppRole[] = ['almoxarife', 'equipe_sa', 'gestor', 'admin'];

const PERMISSION_LABELS: Record<Permission, string> = {
  createMovement: 'Registrar saída (ler QR, montar ME, coletar assinatura)',
  informSa: 'Informar e corrigir SA (antes da conclusão)',
  completeMovement: 'Concluir ME com SA informada',
  correctSaAfterCompletion: 'Corrigir SA de ME concluída',
  approveMovement: 'Aprovar ME (quando exigido)',
  cancelMovement: 'Cancelar ME (lógico, com justificativa)',
  correctMovement: 'Correção administrativa de ME',
  replaceSignature: 'Coletar nova assinatura (mantém a anterior)',
  exportExcel: 'Exportar para Excel',
  viewDashboard: 'Painel e consultas dos estoques autorizados',
  viewAudit: 'Consultar auditoria',
  printLabels: 'Imprimir etiquetas QR Code',
  manageMasterData: 'Cadastros (materiais, funcionários, estoques, auxiliares)',
  manageUsers: 'Usuários, perfis e vínculos com estoques',
  manageSettings: 'Parâmetros do sistema',
};

/** Matriz de permissões — espelha as regras aplicadas no banco (RLS e funções RPC). */
export function RolesPage() {
  const [counts, setCounts] = useState<Record<string, number>>({});
  useEffect(() => {
    adminListUsers()
      .then((us) => {
        const c: Record<string, number> = {};
        for (const u of us) if (u.active) for (const r of u.roles) c[r] = (c[r] ?? 0) + 1;
        setCounts(c);
      })
      .catch(() => undefined);
  }, []);

  return (
    <div className="space-y-4">
      <PageHeader
        title="Perfis e permissões"
        subtitle="Princípio do menor privilégio: cada usuário recebe apenas os perfis necessários. As regras também são aplicadas no banco de dados."
        actions={<LinkButton to="/admin/usuarios">Atribuir perfis</LinkButton>}
      />
      <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
        {ROLES.map((r) => (
          <Card key={r}>
            <p className="font-semibold text-slate-900">{ROLE_LABELS[r]}</p>
            <p className="mt-1 text-sm text-slate-500">{ROLE_DESCRIPTIONS[r]}</p>
            <p className="mt-3 text-xs font-medium text-brand-700">{counts[r] ?? 0} usuário(s) ativo(s)</p>
          </Card>
        ))}
      </div>
      <Card padded={false}>
        <div className="overflow-x-auto">
          <table className="min-w-full divide-y divide-slate-200 text-sm">
            <thead className="bg-slate-50 text-xs font-semibold uppercase tracking-wide text-slate-500">
              <tr>
                <th className="px-4 py-3 text-left">Permissão</th>
                {ROLES.map((r) => (
                  <th key={r} className="px-3 py-3 text-center">
                    {ROLE_LABELS[r]}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100">
              {(Object.keys(PERMISSIONS) as Permission[]).map((p) => (
                <tr key={p}>
                  <td className="px-4 py-2.5">{PERMISSION_LABELS[p]}</td>
                  {ROLES.map((r) => (
                    <td key={r} className="px-3 py-2.5 text-center">
                      {(PERMISSIONS[p] as readonly AppRole[]).includes(r) ? (
                        <Check className="mx-auto h-5 w-5 text-emerald-600" aria-label="Permitido" />
                      ) : (
                        <Minus className="mx-auto h-5 w-5 text-slate-300" aria-label="Não permitido" />
                      )}
                    </td>
                  ))}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </Card>
      <p className="text-xs text-slate-500">
        Acesso por estoque: almoxarife, equipe SA e gestor veem e operam somente nos estoques vinculados ao usuário. Administrador acessa todos.
      </p>
    </div>
  );
}
