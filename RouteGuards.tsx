import type { ReactNode } from 'react';
import { Navigate, Outlet, useLocation } from 'react-router-dom';
import { ShieldAlert, UserX } from 'lucide-react';
import { useAuth } from '@/contexts/AuthContext';
import type { Permission } from '@/lib/constants';
import { PageLoader } from './ui/Spinner';
import { Button } from './ui/Button';
import { Alert, EmptyState } from './ui/Card';

/** Exige sessão válida e perfil ativo com pelo menos um papel. */
export function ProtectedRoute() {
  const { session, loading, access, accessError, roles, signOut, refreshAccess } = useAuth();
  const location = useLocation();

  if (loading) return <PageLoader label="Verificando sessão…" />;
  if (!session) return <Navigate to="/login" replace state={{ from: location.pathname + location.search }} />;

  if (accessError && !access) {
    return (
      <div className="mx-auto mt-16 max-w-md space-y-4 px-4">
        <Alert tone="error" title="Não foi possível carregar suas permissões">
          {accessError}
        </Alert>
        <div className="flex gap-2">
          <Button onClick={() => void refreshAccess()}>Tentar novamente</Button>
          <Button variant="secondary" onClick={() => void signOut()}>
            Sair
          </Button>
        </div>
      </div>
    );
  }

  if (!access?.profile?.active || roles.length === 0) {
    return (
      <div className="mx-auto mt-16 max-w-lg px-4">
        <EmptyState
          icon={<UserX className="h-12 w-12" />}
          title={access?.profile?.active === false ? 'Usuário inativo' : 'Seu usuário ainda não tem perfil de acesso'}
          description="Peça ao administrador do sistema para definir seu perfil (Almoxarife, Equipe SA, Gestor ou Administrador) e os estoques autorizados."
          action={
            <div className="flex gap-2">
              <Button variant="secondary" onClick={() => void refreshAccess()}>
                Verificar novamente
              </Button>
              <Button variant="ghost" onClick={() => void signOut()}>
                Sair
              </Button>
            </div>
          }
        />
      </div>
    );
  }

  return <Outlet />;
}

/** Bloqueia a tela para perfis sem permissão (o banco também bloqueia). */
export function RequirePermission({ perm, children }: { perm: Permission; children: ReactNode }) {
  const { can } = useAuth();
  if (!can(perm)) {
    return (
      <EmptyState
        icon={<ShieldAlert className="h-12 w-12" />}
        title="Acesso não permitido"
        description="Seu perfil não tem permissão para acessar esta tela. Se precisar, solicite ao administrador."
      />
    );
  }
  return <>{children}</>;
}
