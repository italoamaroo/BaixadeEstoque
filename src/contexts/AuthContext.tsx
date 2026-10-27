import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from 'react';
import type { Session } from '@supabase/supabase-js';
import { supabase, isSupabaseConfigured } from '@/lib/supabase';
import { getAccess } from '@/lib/api';
import { can, type Permission } from '@/lib/constants';
import { errorMessage } from '@/lib/errors';
import type { Access, AppRole, Settings, Warehouse } from '@/types/db';

interface AuthState {
  session: Session | null;
  access: Access | null;
  loading: boolean;
  accessError: string | null;
  recoveryMode: boolean;
  roles: AppRole[];
  warehouses: Warehouse[];
  settings: Settings | null;
  userId: string | null;
  displayName: string;
  hasRole: (r: AppRole) => boolean;
  can: (p: Permission) => boolean;
  refreshAccess: () => Promise<void>;
  signIn: (email: string, password: string) => Promise<void>;
  signOut: () => Promise<void>;
  clearRecovery: () => void;
}

const AuthContext = createContext<AuthState | null>(null);

export function AuthProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session | null>(null);
  const [access, setAccess] = useState<Access | null>(null);
  const [loading, setLoading] = useState(true);
  const [accessError, setAccessError] = useState<string | null>(null);
  const [recoveryMode, setRecoveryMode] = useState(false);
  const loadedFor = useRef<string | null>(null);

  const loadAccess = useCallback(async (userId: string | null) => {
    if (!userId) {
      loadedFor.current = null;
      setAccess(null);
      setLoading(false);
      return;
    }
    try {
      setAccessError(null);
      const a = await getAccess();
      loadedFor.current = userId;
      setAccess(a);
    } catch (err) {
      setAccessError(errorMessage(err, 'Não foi possível carregar suas permissões.'));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    if (!isSupabaseConfigured) {
      setLoading(false);
      return;
    }
    let mounted = true;
    supabase.auth.getSession().then(({ data }) => {
      if (!mounted) return;
      setSession(data.session);
      void loadAccess(data.session?.user.id ?? null);
    });

    const { data: sub } = supabase.auth.onAuthStateChange((event, newSession) => {
      setSession(newSession);
      if (event === 'PASSWORD_RECOVERY') setRecoveryMode(true);
      const uid = newSession?.user.id ?? null;
      // Evita chamadas ao Supabase dentro do callback (recomendação da biblioteca)
      if (event === 'SIGNED_OUT') {
        setTimeout(() => void loadAccess(null), 0);
      } else if (uid && uid !== loadedFor.current) {
        setLoading(true);
        setTimeout(() => void loadAccess(uid), 0);
      }
    });

    return () => {
      mounted = false;
      sub.subscription.unsubscribe();
    };
  }, [loadAccess]);

  const value = useMemo<AuthState>(() => {
    const roles = (access?.profile?.active ? access.roles : []) ?? [];
    return {
      session,
      access,
      loading,
      accessError,
      recoveryMode,
      roles,
      warehouses: access?.warehouses ?? [],
      settings: access?.settings ?? null,
      userId: session?.user.id ?? null,
      displayName: access?.profile?.full_name || session?.user.email || '',
      hasRole: (r) => roles.includes(r),
      can: (p) => can(roles, p),
      refreshAccess: () => loadAccess(session?.user.id ?? null),
      signIn: async (email, password) => {
        const { error } = await supabase.auth.signInWithPassword({ email: email.trim().toLowerCase(), password });
        if (error) throw error;
      },
      signOut: async () => {
        await supabase.auth.signOut();
        setAccess(null);
        loadedFor.current = null;
      },
      clearRecovery: () => setRecoveryMode(false),
    };
  }, [session, access, loading, accessError, recoveryMode, loadAccess]);

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}

export function useAuth(): AuthState {
  const ctx = useContext(AuthContext);
  if (!ctx) throw new Error('useAuth deve ser usado dentro de AuthProvider');
  return ctx;
}
