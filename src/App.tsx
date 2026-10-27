import { lazy, Suspense } from 'react';
import { BrowserRouter, Navigate, Route, Routes } from 'react-router-dom';
import { Toaster } from 'sonner';
import { AuthProvider, useAuth } from '@/contexts/AuthContext';
import { WarehouseProvider } from '@/contexts/WarehouseContext';
import { isSupabaseConfigured } from '@/lib/supabase';
import { AppLayout } from '@/components/AppLayout';
import { ProtectedRoute, RequirePermission } from '@/components/RouteGuards';
import { PageLoader } from '@/components/ui/Spinner';
import { LoginPage } from '@/pages/LoginPage';
import { ForgotPasswordPage } from '@/pages/ForgotPasswordPage';
import { ResetPasswordPage } from '@/pages/ResetPasswordPage';
import { ConfigMissingPage } from '@/pages/ConfigMissingPage';
import { NotFoundPage } from '@/pages/NotFoundPage';

// Carregamento sob demanda: telas pesadas (gráficos, câmera, Excel) só baixam quando usadas
const DashboardPage = lazy(() => import('@/pages/DashboardPage').then((m) => ({ default: m.DashboardPage })));
const NewMovementPage = lazy(() => import('@/pages/movimentacao/NewMovementPage').then((m) => ({ default: m.NewMovementPage })));
const MovementsPage = lazy(() => import('@/pages/MovementsPage').then((m) => ({ default: m.MovementsPage })));
const MovementDetailPage = lazy(() => import('@/pages/detail/MovementDetailPage').then((m) => ({ default: m.MovementDetailPage })));
const SaPendingPage = lazy(() => import('@/pages/SaPendingPage').then((m) => ({ default: m.SaPendingPage })));
const ExportPage = lazy(() => import('@/pages/ExportPage').then((m) => ({ default: m.ExportPage })));
const MaterialsPage = lazy(() => import('@/pages/admin/MaterialsPage').then((m) => ({ default: m.MaterialsPage })));
const LabelsPage = lazy(() => import('@/pages/admin/LabelsPage').then((m) => ({ default: m.LabelsPage })));
const EmployeesPage = lazy(() => import('@/pages/admin/EmployeesPage').then((m) => ({ default: m.EmployeesPage })));
const WarehousesPage = lazy(() => import('@/pages/admin/WarehousesPage').then((m) => ({ default: m.WarehousesPage })));
const LookupsPage = lazy(() => import('@/pages/admin/LookupsPage').then((m) => ({ default: m.LookupsPage })));
const UsersPage = lazy(() => import('@/pages/admin/UsersPage').then((m) => ({ default: m.UsersPage })));
const RolesPage = lazy(() => import('@/pages/admin/RolesPage').then((m) => ({ default: m.RolesPage })));
const AuditPage = lazy(() => import('@/pages/admin/AuditPage').then((m) => ({ default: m.AuditPage })));
const SettingsPage = lazy(() => import('@/pages/admin/SettingsPage').then((m) => ({ default: m.SettingsPage })));

function RecoveryRedirect() {
  const { recoveryMode } = useAuth();
  return recoveryMode ? <Navigate to="/redefinir-senha" replace /> : null;
}

function AppRoutes() {
  return (
    <>
      <RecoveryRedirect />
      <Suspense fallback={<PageLoader />}>
        <Routes>
          <Route path="/login" element={<LoginPage />} />
          <Route path="/recuperar-senha" element={<ForgotPasswordPage />} />
          <Route path="/redefinir-senha" element={<ResetPasswordPage />} />

          <Route element={<ProtectedRoute />}>
            <Route element={<AppLayout />}>
              <Route index element={<DashboardPage />} />
              <Route path="nova-saida" element={<RequirePermission perm="createMovement"><NewMovementPage /></RequirePermission>} />
              <Route path="movimentacoes" element={<MovementsPage />} />
              <Route path="movimentacoes/:id" element={<MovementDetailPage />} />
              <Route path="pendencias-sa" element={<RequirePermission perm="informSa"><SaPendingPage /></RequirePermission>} />
              <Route path="exportar" element={<RequirePermission perm="exportExcel"><ExportPage /></RequirePermission>} />

              <Route path="cadastros/materiais" element={<RequirePermission perm="manageMasterData"><MaterialsPage /></RequirePermission>} />
              <Route path="cadastros/etiquetas" element={<RequirePermission perm="printLabels"><LabelsPage /></RequirePermission>} />
              <Route path="cadastros/funcionarios" element={<RequirePermission perm="manageMasterData"><EmployeesPage /></RequirePermission>} />
              <Route path="cadastros/estoques" element={<RequirePermission perm="manageMasterData"><WarehousesPage /></RequirePermission>} />
              <Route path="cadastros/auxiliares" element={<RequirePermission perm="manageMasterData"><LookupsPage /></RequirePermission>} />

              <Route path="admin/usuarios" element={<RequirePermission perm="manageUsers"><UsersPage /></RequirePermission>} />
              <Route path="admin/perfis" element={<RequirePermission perm="manageUsers"><RolesPage /></RequirePermission>} />
              <Route path="admin/auditoria" element={<RequirePermission perm="viewAudit"><AuditPage /></RequirePermission>} />
              <Route path="admin/configuracoes" element={<RequirePermission perm="manageSettings"><SettingsPage /></RequirePermission>} />
              <Route path="*" element={<NotFoundPage />} />
            </Route>
          </Route>
        </Routes>
      </Suspense>
    </>
  );
}

export default function App() {
  if (!isSupabaseConfigured) return <ConfigMissingPage />;
  return (
    <BrowserRouter future={{ v7_startTransition: true, v7_relativeSplatPath: true }}>
      <AuthProvider>
        <WarehouseProvider>
          <AppRoutes />
          <Toaster position="top-center" richColors closeButton duration={4000} />
        </WarehouseProvider>
      </AuthProvider>
    </BrowserRouter>
  );
}
