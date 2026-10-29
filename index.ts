// =====================================================================
// Edge Function "admin-users" (Supabase / Deno)
// Cria usuários no Supabase Auth a pedido de um ADMINISTRADOR do sistema.
// A chave service_role fica SOMENTE aqui (variável fornecida pelo Supabase),
// nunca no navegador nem no Render.
//
// Publicação:  supabase functions deploy admin-users
// =====================================================================
import { createClient } from 'npm:@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY')!;
// Opcional: restrinja a origem ao domínio do Render (ex.: https://baixas.onrender.com)
const ALLOWED_ORIGIN = Deno.env.get('ALLOWED_ORIGIN') ?? '*';

const cors = {
  'Access-Control-Allow-Origin': ALLOWED_ORIGIN,
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });
}

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json({ error: 'Método não permitido.' }, 405);

  const authHeader = req.headers.get('Authorization') ?? '';
  if (!authHeader.startsWith('Bearer ')) return json({ error: 'Não autenticado.' }, 401);

  // 1) Identifica quem chamou usando o JWT do próprio usuário
  const asCaller = createClient(SUPABASE_URL, ANON_KEY, { global: { headers: { Authorization: authHeader } } });
  const { data: who, error: whoErr } = await asCaller.auth.getUser();
  if (whoErr || !who?.user) return json({ error: 'Sessão inválida.' }, 401);

  // 2) Confere no banco se é administrador ativo (mesma regra da RLS)
  const { data: isAdmin, error: roleErr } = await asCaller.rpc('is_admin');
  if (roleErr) return json({ error: 'Falha ao verificar permissões.' }, 500);
  if (!isAdmin) return json({ error: 'Somente administrador pode criar usuários.' }, 403);

  let body: { action?: string; email?: string; full_name?: string; password?: string; invite?: boolean };
  try {
    body = await req.json();
  } catch {
    return json({ error: 'Requisição inválida.' }, 400);
  }

  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { autoRefreshToken: false, persistSession: false } });

  if (body.action === 'create') {
    const email = String(body.email ?? '').trim().toLowerCase();
    const fullName = String(body.full_name ?? '').trim();
    if (!EMAIL_RE.test(email)) return json({ error: 'E-mail inválido.' }, 400);
    if (fullName.length < 3) return json({ error: 'Informe o nome completo.' }, 400);

    const origin = req.headers.get('origin') ?? undefined;

    if (body.invite !== false) {
      const { data, error } = await admin.auth.admin.inviteUserByEmail(email, {
        data: { full_name: fullName },
        redirectTo: origin ? `${origin}/redefinir-senha` : undefined,
      });
      if (error) return json({ error: translate(error.message) }, 400);
      return json({ id: data.user?.id, email });
    }

    const password = String(body.password ?? '');
    if (password.length < 8 || !/[A-Za-z]/.test(password) || !/\d/.test(password)) {
      return json({ error: 'A senha deve ter pelo menos 8 caracteres, com letras e números.' }, 400);
    }
    const { data, error } = await admin.auth.admin.createUser({
      email,
      password,
      email_confirm: true,
      user_metadata: { full_name: fullName },
    });
    if (error) return json({ error: translate(error.message) }, 400);
    return json({ id: data.user?.id, email });
  }

  return json({ error: 'Ação desconhecida.' }, 400);
});

function translate(msg: string): string {
  if (/already been registered|already registered|exists/i.test(msg)) return 'Já existe um usuário com este e-mail.';
  if (/rate limit/i.test(msg)) return 'Limite de envio de e-mails atingido. Tente mais tarde ou crie com senha inicial.';
  return msg;
}
