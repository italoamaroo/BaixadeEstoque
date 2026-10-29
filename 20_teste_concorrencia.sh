#!/usr/bin/env bash
# =====================================================================
# Teste de operações simultâneas: N saídas em paralelo em cada estoque.
# Verifica: nenhum número de ME duplicado e sequência sem buracos.
# Pré-requisito: banco local com 00_stubs + sql/0*.sql + 10_testes_fluxo.sql
# Uso: PGURL="postgresql://postgres@localhost:54329/baixas" ./20_teste_concorrencia.sh 40
# =====================================================================
set -euo pipefail
PGURL="${PGURL:?defina PGURL}"
N="${1:-40}"
ANO=$(psql "$PGURL" -Atc "select extract(year from now() at time zone 'America/Recife')::int")
CONTRATO=$(psql "$PGURL" -Atc "select id from contracts where code='DEMO-CT-002'")
SETOR=$(psql "$PGURL" -Atc "select id from sectors where code='DEMO-SET-OPE'")
FUNC=$(psql "$PGURL" -Atc "select id from employees where registration='DEMO-1003'")
MAT=$(psql "$PGURL" -Atc "select id from materials where code='DEMO-0008'")

cria() {
  local USER_ID="$1" WH_CODE="$2"
  local ID; ID=$(cat /proc/sys/kernel/random/uuid)
  local WH; WH=$(psql "$PGURL" -Atc "select id from warehouses where code='$WH_CODE'")
  psql "$PGURL" -v ON_ERROR_STOP=1 -Atq <<SQL
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '$USER_ID', true);
insert into storage.objects (bucket_id, name, owner, metadata)
values ('assinaturas', '$WH_CODE/$ANO/$ID/assinatura_1.png', '$USER_ID', '{"size":1000}');
select public.create_movement('{"id":"$ID","warehouse_id":"$WH","contract_id":"$CONTRATO","sector_id":"$SETOR","requester_employee_id":"$FUNC","items":[{"material_id":"$MAT","quantity_requested":1,"quantity_delivered":1}],"signature":{"storage_path":"$WH_CODE/$ANO/$ID/assinatura_1.png"}}') ->> 'me_number';
-- reenvio simultâneo do mesmo formulário (duplo clique)
commit;
SQL
}
export -f cria
export PGURL ANO CONTRATO SETOR FUNC MAT

ANTES=$(psql "$PGURL" -Atc "select count(*) from stock_movements")
seq 1 "$N" | xargs -P 20 -I{} bash -c 'cria 00000000-0000-0000-0000-0000000000a1 MUR >/dev/null' &
seq 1 "$N" | xargs -P 20 -I{} bash -c 'cria 00000000-0000-0000-0000-0000000000a2 DIR >/dev/null' &
wait

DEPOIS=$(psql "$PGURL" -Atc "select count(*) from stock_movements")
DUP=$(psql "$PGURL" -Atc "select count(*) from (select me_number from stock_movements group by 1 having count(*) > 1) d")
BURACOS=$(psql "$PGURL" -Atc "
  select count(*) from (
    select w.code, right(m.me_number, 6)::int as seq,
           row_number() over (partition by w.code order by right(m.me_number, 6)::int) as rn
      from stock_movements m join warehouses w on w.id = m.warehouse_id
  ) x where seq <> rn")

echo "MEs criadas: $((DEPOIS - ANTES)) (esperado $((2 * N)))"
echo "Números duplicados: $DUP"
echo "Buracos na sequência: $BURACOS"
[ "$((DEPOIS - ANTES))" -eq "$((2 * N))" ] && [ "$DUP" -eq 0 ] && [ "$BURACOS" -eq 0 ] \
  && echo ">>> TESTE DE CONCORRÊNCIA PASSOU" || { echo ">>> TESTE DE CONCORRÊNCIA FALHOU"; exit 1; }

# Duplo envio simultâneo do mesmo ID: apenas uma ME deve existir
ID=$(cat /proc/sys/kernel/random/uuid)
WH=$(psql "$PGURL" -Atc "select id from warehouses where code='MUR'")
psql "$PGURL" -Atqc "insert into storage.objects (bucket_id, name, metadata) values ('assinaturas', 'MUR/$ANO/$ID/assinatura_1.png', '{\"size\":1}')"
duplo() {
  psql "$PGURL" -Atq <<SQL
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000a1', true);
select public.create_movement('{"id":"$1","warehouse_id":"$2","contract_id":"$CONTRATO","sector_id":"$SETOR","requester_employee_id":"$FUNC","items":[{"material_id":"$MAT","quantity_requested":1,"quantity_delivered":1}],"signature":{"storage_path":"MUR/$ANO/$1/assinatura_1.png"}}') ->> 'created';
commit;
SQL
}
export -f duplo
R=$(seq 1 8 | xargs -P 8 -I{} bash -c "duplo $ID $WH" | grep -E "true|false" | sort | uniq -c | tr '\n' ' ')
QTD=$(psql "$PGURL" -Atc "select count(*) from stock_movements where id = '$ID'")
echo "Duplo envio (8 simultâneos): $R -> registros: $QTD"
[ "$QTD" -eq 1 ] && echo ">>> TESTE DE ENVIO DUPLICADO PASSOU" || { echo ">>> TESTE DE ENVIO DUPLICADO FALHOU"; exit 1; }
