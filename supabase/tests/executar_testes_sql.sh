#!/usr/bin/env bash
# Executa todos os testes de banco em um PostgreSQL local (16+), num banco descartável.
# Uso: PGHOST=/tmp PGPORT=5432 PGUSER=postgres ./supabase/tests/executar_testes_sql.sh
set -euo pipefail
cd "$(dirname "$0")/.."
DB=baixas_teste_$$
psql -q -c "create database $DB" >/dev/null
trap 'psql -q -c "drop database if exists $DB" >/dev/null' EXIT
for f in tests/00_stubs_supabase_local.sql sql/0*.sql; do
  psql -q -d "$DB" -v ON_ERROR_STOP=1 -f "$f" >/dev/null 2>&1 || { echo "Falha ao executar $f"; psql -d "$DB" -v ON_ERROR_STOP=1 -f "$f" | tail -5; exit 1; }
done
psql -q -d "$DB" -t -f tests/10_testes_fluxo.sql 2>&1 | grep -E "FALHOU|ERROR|PASSARAM"
psql -q -d "$DB" -t -f tests/30_testes_admin.sql 2>&1 | grep -E "FALHOU|ERROR|PASSARAM"
PGURL="postgresql://${PGUSER:-postgres}@/$DB?host=${PGHOST:-/tmp}&port=${PGPORT:-5432}" ./tests/20_teste_concorrencia.sh 40 | tail -4
