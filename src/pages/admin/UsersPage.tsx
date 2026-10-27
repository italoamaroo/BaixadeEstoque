import { useEffect, useState } from 'react';
import { toast } from 'sonner';
import { KeyRound, Pencil, UserPlus } from 'lucide-react';
import { Button } from '@/components/ui/Button';
import { ActiveBadge, Badge } from '@/components/ui/Badge';
import { Alert, PageHeader } from '@/components/ui/Card';
import { Checkbox, Input, Select } from '@/components/ui/Field';
import { Modal } from '@/components/ui/Modal';
import { PageLoader } from '@/components/ui/Spinner';
import { useAuth } from '@/contexts/AuthContext';
import { adminCreateUser, adminListUsers, adminSetUserAccess, listWarehouses, sendPasswordReset } from '@/lib/api';
import { ROLE_DESCRIPTIONS, ROLE_LABELS } from '@/lib/constants';
import { errorMessage } from '@/lib/errors';
import { fmtDate } from '@/lib/format';
import { newUserSchema } from '@/lib/validation';
import type { AdminUser, AppRole, Warehouse } from '@/types/db';

const ALL_ROLES: AppRole[] = ['almoxarife', 'equipe_sa', 'gestor', 'admin'];

export function UsersPage() {
  const { userId, refreshAccess } = useAuth();
  const [users, setUsers] = useState<AdminUser[]>([]);
  const [warehouses, setWarehouses] = useState<Warehouse[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [editing, setEditing] = useState<AdminUser | null>(null);
  const [creating, setCreating] = useState(false);

  const load = async () => {
    try {
      const [u, w] = await Promise.all([adminListUsers(), listWarehouses(true)]);
      setUsers(u);
      setWarehouses(w);
      setError(null);
    } catch (err) {
      setError(errorMessage(err));
    } finally {
      setLoading(false);
    }
  };
  useEffect(() => {
    void load();
  }, []);

  if (loading) return <PageLoader />;
  const whName = (id: string) => warehouses.find((w) => w.id === id)?.name ?? '?';

  return (
    <div>
      <PageHeader
        title="Usuários"
        subtitle="Quem acessa o sistema, com quais perfis e em quais estoques."
        actions={
          <Button icon={<UserPlus className="h-4 w-4" />} onClick={() => setCreating(true)}>
            Novo usuário
          </Button>
        }
      />
      {error && <Alert tone="error">{error}</Alert>}
      <div className="overflow-x-auto rounded-xl border border-slate-200 bg-white shadow-card">
        <table className="min-w-full divide-y divide-slate-200 text-sm">
          <thead className="bg-slate-50 text-xs font-semibold uppercase tracking-wide text-slate-500">
            <tr>
              <th className="px-3 py-2.5 text-left">Usuário</th>
              <th className="px-3 py-2.5 text-left">Perfis</th>
              <th className="px-3 py-2.5 text-left">Estoques</th>
              <th className="px-3 py-2.5 text-left">Situação</th>
              <th className="px-3 py-2.5 text-left">Desde</th>
              <th className="px-3 py-2.5 text-right">Ações</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-slate-100">
            {users.map((u) => (
              <tr key={u.id} className={u.active ? '' : 'text-slate-500'}>
                <td className="px-3 py-2.5">
                  <span className="font-medium text-slate-900">{u.full_name}</span>
                  <span className="block text-xs text-slate-500">{u.email}</span>
                </td>
                <td className="px-3 py-2.5">
                  <div className="flex flex-wrap gap-1">
                    {u.roles.length === 0 ? (
                      <Badge className="bg-amber-50 text-amber-800 ring-amber-300">Sem perfil</Badge>
                    ) : (
                      u.roles.map((r) => (
                        <Badge key={r} className="bg-brand-50 text-brand-800 ring-brand-200">
                          {ROLE_LABELS[r]}
                        </Badge>
                      ))
                    )}
                  </div>
                </td>
                <td className="px-3 py-2.5 text-xs">{u.roles.includes('admin') ? 'Todos (admin)' : u.warehouses.map(whName).join(', ') || '—'}</td>
                <td className="px-3 py-2.5">
                  <ActiveBadge active={u.active} />
                </td>
                <td className="px-3 py-2.5 text-xs">{fmtDate(u.created_at)}</td>
                <td className="whitespace-nowrap px-3 py-2.5 text-right">
                  <Button
                    size="sm"
                    variant="ghost"
                    icon={<KeyRound className="h-4 w-4" />}
                    onClick={async () => {
                      try {
                        await sendPasswordReset(u.email);
                        toast.success(`Link de redefinição enviado para ${u.email}.`);
                      } catch (err) {
                        toast.error(errorMessage(err));
                      }
                    }}
                  >
                    Senha
                  </Button>
                  <Button size="sm" variant="ghost" icon={<Pencil className="h-4 w-4" />} onClick={() => setEditing(u)}>
                    Acesso
                  </Button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <AccessModal
        user={editing}
        warehouses={warehouses}
        onClose={() => setEditing(null)}
        onSaved={async () => {
          await load();
          if (editing?.id === userId) await refreshAccess();
        }}
      />
      <CreateUserModal
        open={creating}
        onClose={() => setCreating(false)}
        onCreated={async (id) => {
          await load();
          const list = await adminListUsers();
          setUsers(list);
          const u = list.find((x) => x.id === id);
          if (u) setEditing(u);
        }}
      />
    </div>
  );
}

function AccessModal({ user, warehouses, onClose, onSaved }: { user: AdminUser | null; warehouses: Warehouse[]; onClose: () => void; onSaved: () => Promise<void> }) {
  const [name, setName] = useState('');
  const [active, setActive] = useState(true);
  const [roles, setRoles] = useState<AppRole[]>([]);
  const [whs, setWhs] = useState<string[]>([]);
  const [def, setDef] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (user) {
      setName(user.full_name);
      setActive(user.active);
      setRoles(user.roles);
      setWhs(user.warehouses);
      setDef(user.default_warehouse_id ?? '');
      setError(null);
    }
  }, [user]);

  const toggle = <T,>(list: T[], v: T) => (list.includes(v) ? list.filter((x) => x !== v) : [...list, v]);

  const save = async () => {
    if (!user) return;
    if (name.trim().length < 3) return setError('Informe o nome completo.');
    const operational = roles.some((r) => r !== 'admin');
    if (operational && !roles.includes('admin') && whs.length === 0) return setError('Vincule pelo menos um estoque para este perfil.');
    setBusy(true);
    setError(null);
    try {
      await adminSetUserAccess(user.id, name.trim(), roles, whs, active, def && whs.includes(def) ? def : null);
      toast.success('Acesso atualizado.');
      await onSaved();
      onClose();
    } catch (err) {
      setError(errorMessage(err));
    } finally {
      setBusy(false);
    }
  };

  return (
    <Modal
      open={Boolean(user)}
      onClose={onClose}
      busy={busy}
      size="lg"
      title="Perfil e permissões"
      description={user?.email}
      footer={
        <>
          <Button variant="secondary" onClick={onClose}>
            Cancelar
          </Button>
          <Button onClick={() => void save()} loading={busy}>
            Salvar
          </Button>
        </>
      }
    >
      <div className="space-y-5">
        <Input label="Nome completo" value={name} onChange={(e) => setName(e.target.value)} required />
        <fieldset>
          <legend className="mb-2 text-sm font-semibold text-slate-800">Perfis</legend>
          <div className="space-y-3">
            {ALL_ROLES.map((r) => (
              <Checkbox key={r} label={ROLE_LABELS[r]} description={ROLE_DESCRIPTIONS[r]} checked={roles.includes(r)} onChange={() => setRoles((l) => toggle(l, r))} />
            ))}
          </div>
        </fieldset>
        <fieldset>
          <legend className="mb-2 text-sm font-semibold text-slate-800">Estoques autorizados</legend>
          {roles.includes('admin') && <p className="mb-2 text-xs text-slate-500">Administradores acessam todos os estoques.</p>}
          <div className="flex flex-wrap gap-4">
            {warehouses.map((w) => (
              <Checkbox key={w.id} label={`${w.name} (${w.code})`} checked={whs.includes(w.id)} onChange={() => setWhs((l) => toggle(l, w.id))} />
            ))}
          </div>
        </fieldset>
        <Select label="Estoque padrão ao entrar" value={def} onChange={(e) => setDef(e.target.value)}>
          <option value="">Nenhum</option>
          {warehouses
            .filter((w) => whs.includes(w.id))
            .map((w) => (
              <option key={w.id} value={w.id}>
                {w.name}
              </option>
            ))}
        </Select>
        <Checkbox label="Usuário ativo" description="Usuários inativos não conseguem operar, mesmo com sessão aberta." checked={active} onChange={setActive} />
        {error && <Alert tone="error">{error}</Alert>}
      </div>
    </Modal>
  );
}

function CreateUserModal({ open, onClose, onCreated }: { open: boolean; onClose: () => void; onCreated: (id: string) => Promise<void> }) {
  const [email, setEmail] = useState('');
  const [name, setName] = useState('');
  const [password, setPassword] = useState('');
  const [invite, setInvite] = useState(true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (open) {
      setEmail('');
      setName('');
      setPassword('');
      setInvite(true);
      setError(null);
    }
  }, [open]);

  const submit = async () => {
    const r = newUserSchema.safeParse({ email, full_name: name, password: invite ? '' : password });
    if (!r.success) return setError(r.error.issues[0].message);
    if (!invite && !password) return setError('Defina uma senha inicial ou envie convite por e-mail.');
    setBusy(true);
    setError(null);
    try {
      const u = await adminCreateUser({ email: r.data.email, full_name: r.data.full_name, password: invite ? undefined : password, invite });
      toast.success(invite ? `Convite enviado para ${u.email}.` : `Usuário ${u.email} criado.`);
      onClose();
      await onCreated(u.id);
    } catch (err) {
      setError(errorMessage(err));
    } finally {
      setBusy(false);
    }
  };

  return (
    <Modal
      open={open}
      onClose={onClose}
      busy={busy}
      title="Novo usuário"
      description="Depois de criar, defina perfis e estoques."
      footer={
        <>
          <Button variant="secondary" onClick={onClose}>
            Cancelar
          </Button>
          <Button onClick={() => void submit()} loading={busy}>
            Criar usuário
          </Button>
        </>
      }
    >
      <div className="space-y-4">
        <Input label="E-mail" type="email" required value={email} onChange={(e) => setEmail(e.target.value)} />
        <Input label="Nome completo" required value={name} onChange={(e) => setName(e.target.value)} />
        <Checkbox label="Enviar convite por e-mail" description="O usuário define a própria senha pelo link recebido." checked={invite} onChange={setInvite} />
        {!invite && <Input label="Senha inicial" type="password" value={password} onChange={(e) => setPassword(e.target.value)} hint="Mínimo 8 caracteres, com letras e números." autoComplete="new-password" />}
        {error && <Alert tone="error">{error}</Alert>}
        <p className="text-xs text-slate-500">A criação é feita pela função segura “admin-users” no Supabase; a chave administrativa nunca chega ao navegador.</p>
      </div>
    </Modal>
  );
}
