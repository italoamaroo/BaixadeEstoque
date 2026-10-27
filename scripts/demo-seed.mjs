// =====================================================================
// DADOS FICTÍCIOS: usuários de demonstração + MEs criadas pelo fluxo real
// (upload de assinatura no Storage + RPC create_movement + SA + conclusão +
// cancelamento). Ao final, as MEs são marcadas como is_demo e distribuídas
// nos últimos 45 dias para o painel ter histórico.
//
// Pré-requisitos: SQL 01..09 executados no Supabase e .env preenchido.
// Uso: npm run demo:seed        (use --force para criar mais MEs)
// NUNCA execute em produção com dados reais.
// =====================================================================
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';
import { loadEnv, demoSignaturePng } from './_env.mjs';

const env = loadEnv();
const PASSWORD = env.DEMO_PASSWORD || 'Demo@2026!';
const URL = env.VITE_SUPABASE_URL;
const service = createClient(URL, env.SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false, autoRefreshToken: false } });

const USERS = [
  { email: 'demo.almox.muribeca@example.com', name: 'Carlos Almoxarife (fictício)', roles: ['almoxarife'], whs: ['MUR'] },
  { email: 'demo.almox.doisirmaos@example.com', name: 'Rita Almoxarife (fictícia)', roles: ['almoxarife'], whs: ['DIR'] },
  { email: 'demo.equipe.sa@example.com', name: 'Equipe SA (fictícia)', roles: ['equipe_sa'], whs: ['MUR', 'DIR'] },
  { email: 'demo.gestor@example.com', name: 'Gestor de Almoxarifado (fictício)', roles: ['gestor'], whs: ['MUR', 'DIR'] },
];

const rnd = (n) => Math.floor(Math.random() * n);
const pick = (arr) => arr[rnd(arr.length)];

async function ensureUser(u) {
  const { data: list, error } = await service.auth.admin.listUsers({ page: 1, perPage: 1000 });
  if (error) throw error;
  let user = list.users.find((x) => x.email === u.email);
  if (!user) {
    const { data, error: e2 } = await service.auth.admin.createUser({
      email: u.email,
      password: PASSWORD,
      email_confirm: true,
      user_metadata: { full_name: u.name },
    });
    if (e2) throw e2;
    user = data.user;
    console.log(`  usuário criado: ${u.email}`);
  } else {
    console.log(`  usuário já existe: ${u.email}`);
  }
  const { error: e3 } = await service.rpc('demo_set_user_access', {
    p_email: u.email,
    p_full_name: u.name,
    p_roles: u.roles,
    p_warehouse_codes: u.whs,
  });
  if (e3) throw e3;
  return user;
}

async function clientFor(email) {
  const c = createClient(URL, env.VITE_SUPABASE_ANON_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
  const { error } = await c.auth.signInWithPassword({ email, password: PASSWORD });
  if (error) throw new Error(`Login de ${email} falhou: ${error.message}`);
  return c;
}

async function main() {
  console.log('1) Usuários fictícios');
  for (const u of USERS) await ensureUser(u);

  const { count } = await service.from('stock_movements').select('id', { count: 'exact', head: true }).eq('is_demo', true);
  if ((count ?? 0) > 0 && !process.argv.includes('--force')) {
    console.log(`Já existem ${count} MEs fictícias. Use "npm run demo:seed -- --force" para criar mais.`);
    return;
  }

  console.log('2) Cadastros de apoio');
  const [{ data: whs }, { data: contracts }, { data: sectors }, { data: fronts }, { data: orders }, { data: assets }, { data: locals }, { data: emps }, { data: mats }] =
    await Promise.all([
      service.from('warehouses').select('id, code, name'),
      service.from('contracts').select('id').like('code', 'DEMO-%'),
      service.from('sectors').select('id').like('code', 'DEMO-%'),
      service.from('service_fronts').select('id').like('code', 'DEMO-%'),
      service.from('service_orders').select('code').like('code', 'DEMO-%'),
      service.from('fixed_assets').select('code').like('code', 'DEMO-%'),
      service.from('application_locations').select('id').like('code', 'DEMO-%'),
      service.from('employees').select('id').like('registration', 'DEMO-%'),
      service.from('materials').select('id, qr_code, unit').like('code', 'DEMO-%').eq('active', true),
    ]);
  if (!contracts?.length || !mats?.length || !emps?.length) {
    throw new Error('Execute antes o script supabase/sql/09_dados_ficticios.sql.');
  }

  const almox = {
    MUR: await clientFor(USERS[0].email),
    DIR: await clientFor(USERS[1].email),
  };
  const sa = await clientFor(USERS[2].email);
  const gestor = await clientFor(USERS[3].email);

  console.log('3) MEs pelo fluxo real (assinatura no Storage + RPC)');
  const created = [];
  const TOTAL = 36;
  for (let i = 0; i < TOTAL; i++) {
    const code = i % 2 === 0 ? 'MUR' : 'DIR';
    const wh = whs.find((w) => w.code === code);
    const client = almox[code];
    const id = randomUUID();
    const year = Number(new Intl.DateTimeFormat('en-US', { timeZone: 'America/Recife', year: 'numeric' }).format(new Date()));
    const path = `${code}/${year}/${id}/assinatura_demo.png`;

    const { error: upErr } = await client.storage.from('assinaturas').upload(path, demoSignaturePng(i + 1), { contentType: 'image/png' });
    if (upErr) throw new Error(`Upload da assinatura: ${upErr.message}`);

    const used = new Set();
    const items = Array.from({ length: 1 + rnd(4) }, () => {
      let m = pick(mats);
      while (used.has(m.id)) m = pick(mats);
      used.add(m.id);
      const req = m.unit === 'L' || m.unit === 'KG' ? 1 + rnd(20) : 1 + rnd(6);
      const del = rnd(5) === 0 ? Math.max(1, req - 1) : req;
      return {
        material_id: m.id,
        quantity_requested: req,
        quantity_delivered: del,
        entry_method: rnd(4) === 0 ? 'pesquisa_manual' : 'qr_code',
        scanned_code: m.qr_code,
        notes: del < req ? 'Saldo insuficiente no momento da retirada (fictício)' : null,
      };
    });

    const { data, error } = await client.rpc('create_movement', {
      p_payload: {
        id,
        warehouse_id: wh.id,
        contract_id: pick(contracts).id,
        sector_id: pick(sectors).id,
        service_front_id: rnd(5) ? pick(fronts).id : null,
        service_order_text: rnd(2) ? pick(orders).code : null,
        fixed_asset_text: rnd(3) ? null : pick(assets).code,
        application_location_id: pick(locals).id,
        requester_employee_id: pick(emps).id,
        items,
        signature: { storage_path: path },
        notes: '[DADO FICTÍCIO]',
        source: 'dados_ficticios',
      },
    });
    if (error) throw new Error(`create_movement: ${error.message}`);
    created.push({ id, me: data.me_number, wh: code, daysAgo: Math.floor(((TOTAL - 1 - i) / TOTAL) * 45) });
    process.stdout.write(`  ${data.me_number}\n`);
  }

  console.log('4) SA, conclusão e cancelamentos');
  for (const [idx, m] of created.entries()) {
    if (m.daysAgo < 3 && idx % 3 !== 0) continue; // recentes ficam aguardando SA
    if (idx % 9 === 4) {
      const { error } = await gestor.rpc('cancel_movement', { p_id: m.id, p_reason: 'Material devolvido ao estoque (fictício)' });
      if (error) throw error;
      continue;
    }
    if (idx % 4 === 1) continue; // algumas pendências antigas, para o gráfico de idade
    const saNumber = `SA-DEMO-${String(100000 + idx)}`;
    const { error } = await sa.rpc('inform_sa', { p_id: m.id, p_sa_number: saNumber });
    if (error) throw error;
    if (idx % 2 === 0) {
      const { error: e2 } = await sa.rpc('complete_movement', { p_id: m.id });
      if (e2) throw e2;
    }
  }

  console.log('5) Datas retroativas e marcação "fictício"');
  for (const m of created) {
    const when = new Date(Date.now() - m.daysAgo * 86_400_000);
    when.setUTCHours(10 + rnd(9), rnd(60), 0, 0);
    const { error } = await service.rpc('demo_mark_movement', { p_id: m.id, p_movement_at: when.toISOString() });
    if (error) throw error;
  }

  console.log(`\nPronto: ${created.length} MEs fictícias.`);
  console.log(`Logins de demonstração (senha: ${env.DEMO_PASSWORD ? 'a definida em DEMO_PASSWORD' : PASSWORD}):`);
  for (const u of USERS) console.log(`  - ${u.email}  (${u.roles.join(', ')}: ${u.whs.join(', ')})`);
}

main().catch((err) => {
  console.error('\nERRO:', err.message ?? err);
  process.exit(1);
});
