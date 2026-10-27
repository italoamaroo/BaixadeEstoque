import { useEffect, useState, type ReactNode } from 'react';
import { NavLink, Outlet, useLocation, useNavigate } from 'react-router-dom';
import clsx from 'clsx';
import {
  BarChart3,
  Boxes,
  ClipboardList,
  Database,
  FileClock,
  FileSpreadsheet,
  Hourglass,
  LogOut,
  Menu,
  PackageMinus,
  QrCode,
  Settings,
  ShieldCheck,
  UserCog,
  Users,
  Warehouse as WarehouseIcon,
  X,
} from 'lucide-react';
import { useAuth } from '@/contexts/AuthContext';
import { useWarehouse } from '@/contexts/WarehouseContext';
import { ROLE_LABELS, type Permission } from '@/lib/constants';
import { ConnectionBanner, ConnectionDot } from './ConnectionIndicator';

interface NavItem {
  to: string;
  label: string;
  icon: ReactNode;
  perm?: Permission;
}

const OPERATION: NavItem[] = [
  { to: '/', label: 'Painel', icon: <BarChart3 className="h-5 w-5" /> },
  { to: '/nova-saida', label: 'Nova saída', icon: <PackageMinus className="h-5 w-5" />, perm: 'createMovement' },
  { to: '/movimentacoes', label: 'Movimentações', icon: <ClipboardList className="h-5 w-5" /> },
  { to: '/pendencias-sa', label: 'Pendências de SA', icon: <Hourglass className="h-5 w-5" />, perm: 'informSa' },
  { to: '/exportar', label: 'Exportar Excel', icon: <FileSpreadsheet className="h-5 w-5" />, perm: 'exportExcel' },
];

const REGISTRY: NavItem[] = [
  { to: '/cadastros/materiais', label: 'Materiais', icon: <Boxes className="h-5 w-5" />, perm: 'manageMasterData' },
  { to: '/cadastros/etiquetas', label: 'Etiquetas QR Code', icon: <QrCode className="h-5 w-5" />, perm: 'printLabels' },
  { to: '/cadastros/funcionarios', label: 'Funcionários', icon: <Users className="h-5 w-5" />, perm: 'manageMasterData' },
  { to: '/cadastros/estoques', label: 'Estoques', icon: <WarehouseIcon className="h-5 w-5" />, perm: 'manageMasterData' },
  { to: '/cadastros/auxiliares', label: 'Cadastros auxiliares', icon: <Database className="h-5 w-5" />, perm: 'manageMasterData' },
];

const ADMIN: NavItem[] = [
  { to: '/admin/usuarios', label: 'Usuários', icon: <UserCog className="h-5 w-5" />, perm: 'manageUsers' },
  { to: '/admin/perfis', label: 'Perfis e permissões', icon: <ShieldCheck className="h-5 w-5" />, perm: 'manageUsers' },
  { to: '/admin/auditoria', label: 'Auditoria', icon: <FileClock className="h-5 w-5" />, perm: 'viewAudit' },
  { to: '/admin/configuracoes', label: 'Configurações', icon: <Settings className="h-5 w-5" />, perm: 'manageSettings' },
];

function NavSection({ title, items, onNavigate }: { title?: string; items: NavItem[]; onNavigate?: () => void }) {
  const { can } = useAuth();
  const visible = items.filter((i) => !i.perm || can(i.perm));
  if (!visible.length) return null;
  return (
    <div>
      {title && <p className="mb-1 px-3 text-[11px] font-semibold uppercase tracking-wider text-brand-200/80">{title}</p>}
      <ul className="space-y-0.5">
        {visible.map((i) => (
          <li key={i.to}>
            <NavLink
              to={i.to}
              end={i.to === '/'}
              onClick={onNavigate}
              className={({ isActive }) =>
                clsx(
                  'flex items-center gap-3 rounded-lg px-3 py-2 text-sm font-medium transition-colors',
                  isActive ? 'bg-white/15 text-white' : 'text-brand-100 hover:bg-white/10 hover:text-white',
                )
              }
            >
              {i.icon}
              {i.label}
            </NavLink>
          </li>
        ))}
      </ul>
    </div>
  );
}

function Sidebar({ onNavigate }: { onNavigate?: () => void }) {
  const { settings } = useAuth();
  return (
    <div className="flex h-full flex-col bg-brand-900 px-3 py-4">
      <div className="mb-6 flex items-center gap-3 px-2">
        <div className="flex h-9 w-9 items-center justify-center rounded-lg bg-white/15">
          <PackageMinus className="h-5 w-5 text-white" />
        </div>
        <div className="leading-tight">
          <p className="text-sm font-bold text-white">Baixas de Estoque</p>
          <p className="text-xs text-brand-200">{settings?.company_name ?? 'Almoxarifado'}</p>
        </div>
      </div>
      <nav className="flex-1 space-y-6 overflow-y-auto">
        <NavSection items={OPERATION} onNavigate={onNavigate} />
        <NavSection title="Cadastros" items={REGISTRY} onNavigate={onNavigate} />
        <NavSection title="Administração" items={ADMIN} onNavigate={onNavigate} />
      </nav>
    </div>
  );
}

function WarehouseSwitcher() {
  const { current, options, setCurrentId } = useWarehouse();
  if (options.length === 0) return null;
  if (options.length === 1) {
    return (
      <span className="hidden items-center gap-1.5 rounded-lg bg-slate-100 px-3 py-1.5 text-sm font-medium text-slate-700 sm:inline-flex">
        <WarehouseIcon className="h-4 w-4" /> {options[0].name}
      </span>
    );
  }
  return (
    <label className="flex items-center gap-2 text-sm">
      <WarehouseIcon className="hidden h-4 w-4 text-slate-500 sm:block" />
      <span className="sr-only">Estoque em operação</span>
      <select
        className="h-9 rounded-lg border-0 py-0 pl-3 pr-8 text-sm font-medium ring-1 ring-inset ring-slate-300 focus:ring-2 focus:ring-brand-600"
        value={current?.id ?? ''}
        onChange={(e) => setCurrentId(e.target.value)}
        title="Estoque em que você está operando"
      >
        <option value="" disabled>
          Selecione o estoque
        </option>
        {options.map((w) => (
          <option key={w.id} value={w.id}>
            {w.name}
          </option>
        ))}
      </select>
    </label>
  );
}

function UserMenu() {
  const { displayName, roles, signOut } = useAuth();
  const navigate = useNavigate();
  const [open, setOpen] = useState(false);
  const initials = displayName
    .split(/\s+/)
    .filter(Boolean)
    .slice(0, 2)
    .map((p) => p[0]?.toUpperCase())
    .join('');
  return (
    <div className="relative">
      <button
        type="button"
        onClick={() => setOpen((o) => !o)}
        className="flex h-9 w-9 items-center justify-center rounded-full bg-brand-700 text-sm font-semibold text-white"
        aria-label="Menu do usuário"
        aria-expanded={open}
      >
        {initials || '?'}
      </button>
      {open && (
        <>
          <div className="fixed inset-0 z-30" onClick={() => setOpen(false)} aria-hidden="true" />
          <div className="absolute right-0 z-40 mt-2 w-64 rounded-xl border border-slate-200 bg-white p-3 shadow-lg">
            <p className="font-semibold text-slate-900">{displayName}</p>
            <p className="mt-0.5 text-xs text-slate-500">{roles.map((r) => ROLE_LABELS[r]).join(' · ') || 'Sem perfil'}</p>
            <button
              type="button"
              onClick={async () => {
                setOpen(false);
                await signOut();
                navigate('/login', { replace: true });
              }}
              className="mt-3 flex w-full items-center gap-2 rounded-lg px-2 py-2 text-sm font-medium text-red-700 hover:bg-red-50"
            >
              <LogOut className="h-4 w-4" /> Sair
            </button>
          </div>
        </>
      )}
    </div>
  );
}

function BottomNav() {
  const { can } = useAuth();
  const items = [
    { to: '/', label: 'Painel', icon: <BarChart3 className="h-5 w-5" /> },
    ...(can('createMovement') ? [{ to: '/nova-saida', label: 'Nova saída', icon: <PackageMinus className="h-6 w-6" />, primary: true }] : []),
    { to: '/movimentacoes', label: 'MEs', icon: <ClipboardList className="h-5 w-5" /> },
    ...(can('informSa') ? [{ to: '/pendencias-sa', label: 'SA', icon: <Hourglass className="h-5 w-5" /> }] : []),
  ];
  return (
    <nav className="fixed inset-x-0 bottom-0 z-30 border-t border-slate-200 bg-white pb-[env(safe-area-inset-bottom)] lg:hidden print:hidden">
      <ul className="flex">
        {items.map((i) => (
          <li key={i.to} className="flex-1">
            <NavLink
              to={i.to}
              end={i.to === '/'}
              className={({ isActive }) =>
                clsx(
                  'flex flex-col items-center gap-0.5 py-2 text-[11px] font-medium',
                  'primary' in i && i.primary ? 'text-brand-700' : isActive ? 'text-brand-700' : 'text-slate-500',
                )
              }
            >
              {'primary' in i && i.primary ? (
                <span className="-mt-5 flex h-12 w-12 items-center justify-center rounded-full bg-brand-700 text-white shadow-lg">{i.icon}</span>
              ) : (
                i.icon
              )}
              {i.label}
            </NavLink>
          </li>
        ))}
      </ul>
    </nav>
  );
}

export function AppLayout() {
  const [drawer, setDrawer] = useState(false);
  const location = useLocation();
  const { access } = useAuth();

  useEffect(() => setDrawer(false), [location.pathname]);

  return (
    <div className="min-h-screen">
      <ConnectionBanner />
      <aside className="fixed inset-y-0 left-0 hidden w-64 lg:block print:hidden">
        <Sidebar />
      </aside>

      {drawer && (
        <div className="fixed inset-0 z-50 lg:hidden print:hidden">
          <div className="absolute inset-0 bg-slate-900/50" onClick={() => setDrawer(false)} aria-hidden="true" />
          <div className="absolute inset-y-0 left-0 w-72">
            <Sidebar onNavigate={() => setDrawer(false)} />
            <button
              type="button"
              className="absolute right-3 top-4 rounded-lg p-1.5 text-white hover:bg-white/10"
              onClick={() => setDrawer(false)}
              aria-label="Fechar menu"
            >
              <X className="h-5 w-5" />
            </button>
          </div>
        </div>
      )}

      <div className="lg:pl-64 print:pl-0">
        <header className="sticky top-0 z-20 flex h-14 items-center gap-3 border-b border-slate-200 bg-white/95 px-4 backdrop-blur print:hidden sm:px-6">
          <button type="button" className="-ml-1 rounded-lg p-1.5 text-slate-600 hover:bg-slate-100 lg:hidden" onClick={() => setDrawer(true)} aria-label="Abrir menu">
            <Menu className="h-6 w-6" />
          </button>
          <span className="font-semibold text-slate-900 lg:hidden">Baixas</span>
          <div className="ml-auto flex items-center gap-3">
            <ConnectionDot />
            <WarehouseSwitcher />
            {access && <UserMenu />}
          </div>
        </header>
        <main className="mx-auto max-w-7xl px-4 pb-28 pt-5 sm:px-6 lg:pb-10 print:max-w-none print:p-0">
          <Outlet />
        </main>
      </div>
      <BottomNav />
    </div>
  );
}
