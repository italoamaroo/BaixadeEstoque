import { createClient, type SupabaseClient } from '@supabase/supabase-js';

const url = import.meta.env.VITE_SUPABASE_URL as string | undefined;
const anonKey = import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined;

/** true quando as variáveis públicas do Supabase foram configuradas. */
export const isSupabaseConfigured = Boolean(url && anonKey && /^https?:\/\//.test(url));

/**
 * Cliente único do Supabase. Usa SOMENTE a chave pública (anon).
 * Toda autorização é feita no banco (RLS + funções RPC), nunca só na interface.
 */
export const supabase: SupabaseClient = createClient(
  isSupabaseConfigured ? (url as string) : 'http://localhost:54321',
  isSupabaseConfigured ? (anonKey as string) : 'chave-nao-configurada',
  {
    auth: {
      persistSession: true,
      autoRefreshToken: true,
      detectSessionInUrl: true,
      storageKey: 'baixas-estoque-auth',
    },
    realtime: { params: { eventsPerSecond: 5 } },
  },
);

export const SIGNATURE_BUCKET = 'assinaturas';
