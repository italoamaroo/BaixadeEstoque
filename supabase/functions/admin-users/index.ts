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
// Obrigatório: origem HTTPS exata da aplicação publicada, sem caminho nem barra final.
const ALLOWED_ORIGIN = Deno.env.get('ALLOWED_ORIGIN') ?? '';
const APP_URL = Deno.env.get('APP_URL') ?? ALLOWED_ORIGIN;

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
  try {
    if (new URL(ALLOWED_ORIGIN).origin !== ALLOWED_ORIGIN || new URL(APP_URL).origin !== ALLOWED_ORIGIN || new URL(APP_URL).protocol !== 'https:') throw new Error('config');
  } catch { return json({ error: 'Configure ALLOWED_ORIGIN e APP_URL HTTPS da mesma origem no servidor.' }, 503); }
  if (req.headers.get('origin') !== ALLOWED_ORIGIN) return json({ error: 'Origem não permitida.' }, 403);
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
  const { data: aal2, error: aalError } = await asCaller.rpc('session_is_aal2');
  if (aalError || !aal2) return json({ error: 'Verifique o segundo fator da conta administrativa.' }, 403);
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

    const { error: auditError } = await admin.rpc('audit_admin_provisioning', { p_actor: who.user.id, p_target: email, p_stage: 'solicitada' });
    if (auditError) return json({ error: 'Não foi possível registrar a solicitação. Nenhum usuário foi criado.' }, 503);
    const recordResult = async (ok: boolean) => {
      const { error } = await admin.rpc('audit_admin_provisioning', { p_actor: who.user.id, p_target: email, p_stage: ok ? 'concluida' : 'falha' });
      return error ? 'A operação ocorreu, mas o registro do resultado precisa de conferência na auditoria.' : undefined;
    };

    if (body.invite !== false) {
      const { data, error } = await admin.auth.admin.inviteUserByEmail(email, {
        data: { full_name: fullName },
        redirectTo: `${APP_URL.replace(/\/$/, '')}/redefinir-senha`,
      });
      if (error) { await recordResult(false); return json({ error: translate(error.message) }, 400); }
      return json({ id: data.user?.id, email, warning: await recordResult(true) });
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
    if (error) { await recordResult(false); return json({ error: translate(error.message) }, 400); }
    return json({ id: data.user?.id, email, warning: await recordResult(true) });
  }

  return json({ error: 'Ação desconhecida.' }, 400);
});

function translate(msg: string): string {
  if (/already been registered|already registered|exists/i.test(msg)) return 'Já existe um usuário com este e-mail.';
  if (/rate limit/i.test(msg)) return 'Limite de envio de e-mails atingido. Tente mais tarde ou crie com senha inicial.';
  return msg;
}
