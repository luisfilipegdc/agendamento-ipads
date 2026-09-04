#!/usr/bin/env bash
# Aplica as migrations num Postgres limpo e roda a suíte.
#   ./supabase/tests/run.sh            (usa o socket em /tmp, porta 5433)
#   PGPORT=5432 PGHOST=localhost ./supabase/tests/run.sh
set -euo pipefail
cd "$(dirname "$0")/../.."

PGHOST=${PGHOST:-/tmp}; PGPORT=${PGPORT:-5433}; PGUSER=${PGUSER:-postgres}
DB=${DB:-agendamento_test}
psql_() { psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" "$@"; }

psql_ -q -c "drop database if exists $DB;" -c "create database $DB;" >/dev/null 2>&1

echo "→ shim + migrations"
psql_ -d "$DB" -q -v ON_ERROR_STOP=1 -f supabase/tests/00_shim_local.sql
for f in supabase/migrations/*.sql; do
  echo "  $(basename "$f")"
  psql_ -d "$DB" -q -v ON_ERROR_STOP=1 -f "$f"
done

falhas=0
for t in supabase/tests/regras_test.sql supabase/tests/rls_test.sql; do
  echo; echo "→ $(basename "$t")"
  out=$(psql_ -d "$DB" -v ON_ERROR_STOP=1 -f "$t" 2>&1) || falhas=1
  echo "$out" | sed 's/^psql:[^ ]* //' | grep -E "PASS|FALHOU|ERROR|===" || true
  # Um teste que reporta FALHOU sem levantar exceção ainda é uma falha: o psql
  # sai 0 porque a string veio de um SELECT. Sem isto, a suíte mente.
  if echo "$out" | grep -qE "FALHOU|^ERROR|ERROR:"; then falhas=1; fi
done

echo
if [ $falhas -eq 0 ]; then echo "✅ suíte completa passou"; else
  echo "❌ houve falhas"; exit 1; fi
