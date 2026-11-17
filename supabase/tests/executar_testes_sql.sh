#!/usr/bin/env bash
# Apenas PostgreSQL local/descartável: nunca aponte este comando ao Supabase de produção.
set -euo pipefail
cd "$(dirname "$0")/.."
DB="baixas_teste_$$"
LOG=$(mktemp)
psql -X -v ON_ERROR_STOP=1 -q -c "create database $DB"
cleanup() {
  psql -X -v ON_ERROR_STOP=1 -q -c "drop database if exists $DB" >/dev/null
  rm -f "$LOG"
}
trap cleanup EXIT
run_sql() {
  local file="$1"
  if ! psql -X -v ON_ERROR_STOP=1 -q -d "$DB" -f "$file" >"$LOG" 2>&1; then
    cat "$LOG"
    echo "Falha ao executar $file" >&2
    return 1
  fi
  # Não basta imprimir FALHOU e encerrar com código zero.
  if grep -Eq 'FALHOU|ERROR:' "$LOG"; then
    cat "$LOG"
    return 1
  fi
  grep -E 'PASSARAM|PASSOU' "$LOG" || true
}
run_sql tests/00_stubs_supabase_local.sql
# Usa o mesmo instalador destinado a bancos novos, não uma segunda implementação.
run_sql instalar_completo.sql
run_sql sql/09_dados_ficticios.sql
for file in tests/[1-9]*.sql; do run_sql "$file"; done
PGURL="postgresql://${PGUSER:-postgres}@/$DB?host=${PGHOST:-/tmp}&port=${PGPORT:-5432}" \
  bash tests/20_teste_concorrencia.sh 40
psql -X -v ON_ERROR_STOP=1 -q -d "$DB" <<'SQL'
do $$
begin
  if not (public._audit_verify(null) ->> 'ok')::boolean then
    raise exception 'FALHOU: integridade da auditoria após testes e concorrência';
  end if;
end $$;
SQL
echo '>>> TODOS OS TESTES SQL E INTEGRIDADE PASSARAM'
