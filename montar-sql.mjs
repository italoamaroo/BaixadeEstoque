// Junta os scripts 01..08 em um único arquivo para colar no SQL Editor do Supabase.
// Uso: npm run sql:montar  ->  supabase/instalar_completo.sql
import { readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const dir = join(process.cwd(), 'supabase', 'sql');
const files = readdirSync(dir).filter((f) => /^0[1-8]_.*\.sql$/.test(f)).sort();
const header = `-- =====================================================================
-- INSTALAÇÃO COMPLETA (gerado por scripts/montar-sql.mjs — não edite à mão)
-- Arquivos: ${files.join(', ')}
-- Dados fictícios NÃO incluídos: execute 09_dados_ficticios.sql à parte.
-- =====================================================================
set client_min_messages = warning;
`;
const body = files.map((f) => `\n-- >>>>>>>>>> ${f}\n${readFileSync(join(dir, f), 'utf8')}`).join('\n');
writeFileSync(join(process.cwd(), 'supabase', 'instalar_completo.sql'), header + body);
console.log(`supabase/instalar_completo.sql gerado com ${files.length} arquivos.`);
