import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from 'react';
import type { Session } from '@supabase/supabase-js';
import { supabase, isSupabaseConfigured } from '@/lib/supabase';
import { getAccess, logSession, reportLoginFailure } from '@/lib/api';
import { cachedAccess, clearOfflineCache, saveAccessCache } from '@/lib/offlineCache';
import { can, type Permission } from '@/lib/constants';
import { errorMessage, isNetworkError } from '@/lib/errors';
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
      void saveAccessCache(userId, a);
    } catch (err) {
      // Sem internet: usa as permissões guardadas no aparelho (modo offline)
      const cached = isNetworkError(err) ? await cachedAccess(userId) : undefined;
      if (cached) {
        loadedFor.current = userId;
        setAccess(cached);
      } else {
        setAccessError(errorMessage(err, 'Não foi possível carregar suas permissões.'));
      }
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
        const normalized = email.trim().toLowerCase();
        const { error } = await supabase.auth.signInWithPassword({ email: normalized, password });
        if (error) {
          // Só senha/e-mail errados contam como falha de login (não erros de rede)
          if (!isNetworkError(error) && /invalid login credentials/i.test(error.message)) reportLoginFailure(normalized);
          throw error;
        }
        void logSession('login');
      },
      signOut: async () => {
        await logSession('logout');
        await supabase.auth.signOut();
        // LGPD: a cópia local de cadastros sai junto (a fila de saídas não enviadas fica)
        await clearOfflineCache().catch(() => undefined);
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
