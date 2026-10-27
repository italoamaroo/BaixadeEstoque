// Remove do Storage os arquivos de assinatura das MEs fictícias (is_demo).
// Execute ANTES de supabase/sql/99_remover_dados_ficticios.sql.
// Uso: npm run demo:clean
import { createClient } from '@supabase/supabase-js';
import { loadEnv } from './_env.mjs';

const env = loadEnv();
const service = createClient(env.VITE_SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false } });

const { data: moves, error } = await service.from('stock_movements').select('id').eq('is_demo', true);
if (error) throw error;
const ids = moves.map((m) => m.id);
if (!ids.length) {
  console.log('Nenhuma ME fictícia encontrada.');
  process.exit(0);
}
const { data: sigs, error: e2 } = await service.from('signatures').select('bucket, storage_path').in('movement_id', ids);
if (e2) throw e2;
const paths = sigs.map((s) => s.storage_path);
for (let i = 0; i < paths.length; i += 100) {
  const { error: e3 } = await service.storage.from('assinaturas').remove(paths.slice(i, i + 100));
  if (e3) throw e3;
}
console.log(`${paths.length} arquivo(s) de assinatura fictícia removido(s). Agora execute 99_remover_dados_ficticios.sql.`);
