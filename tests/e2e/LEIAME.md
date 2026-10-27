# Teste ponta a ponta (local)

Simula o Supabase localmente para exercitar a interface real contra o banco real (SQL 01..09):

- **PostgreSQL 16** com `supabase/tests/00_stubs_supabase_local.sql` + `supabase/sql/01..09` + `preparar_banco.sql`.
- **PostgREST 12** (binário oficial do GitHub) com `postgrest.conf`.
- **gateway.mjs** (porta 54321): repassa `/rest/v1` ao PostgREST e simula Auth (senha `teste123`) e Storage.
- **Vite** com `VITE_SUPABASE_URL=http://localhost:54321` e uma chave anon assinada com o segredo do `postgrest.conf`.
- **fluxo_completo.py** (Python + Playwright) percorre o fluxo do almoxarife, equipe SA, gestor e admin e salva capturas em `tests/e2e/capturas`.

Realtime não é simulado (avisos de WebSocket no console são esperados). Não use nada desta pasta em produção.
