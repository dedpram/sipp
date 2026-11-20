#!/usr/bin/env bash
# ---------------------------------------------------------------------
# Menjalankan seluruh migration + uji RLS pada PostgreSQL biasa.
# Dipakai oleh GitHub Actions (job "database") dan dapat dijalankan lokal
# bila Anda memiliki PostgreSQL 15+.
#
# Variabel: PGHOST, PGPORT, PGUSER (superuser), PGPASSWORD
# Pemakaian: bash scripts/test-db.sh
# ---------------------------------------------------------------------
set -euo pipefail

DB_NAME="${TEST_DB_NAME:-sipp_test}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PSQL=(psql -X -q -t -v ON_ERROR_STOP=1)

echo "==> Menyiapkan database uji '$DB_NAME'"
"${PSQL[@]}" -d postgres -c "drop database if exists $DB_NAME" >/dev/null
"${PSQL[@]}" -d postgres -c "create database $DB_NAME" >/dev/null

run() { echo "    - $(basename "$1")"; PGOPTIONS="-c client_min_messages=warning" "${PSQL[@]}" -d "$DB_NAME" -f "$1"; }

echo "==> Shim Supabase"
run "$ROOT/supabase/tests/_supabase_shim.sql"

echo "==> Migration"
for f in "$ROOT"/supabase/migrations/*.sql; do run "$f"; done

echo "==> Migration diulang (harus aman/idempotent)"
for f in "$ROOT"/supabase/migrations/*.sql; do "${PSQL[@]}" -d "$DB_NAME" -f "$f" >/dev/null; done

echo "==> Helper & data uji"
run "$ROOT/supabase/tests/_helpers.sql"
"${PSQL[@]}" -d "$DB_NAME" -f "$ROOT/supabase/tests/_fixtures.sql" >/dev/null

echo "==> Pengujian"
total=0
for f in "$ROOT"/supabase/tests/rls/*.sql; do
  echo "--- $(basename "$f")"
  out=$("${PSQL[@]}" -d "$DB_NAME" -f "$f" 2>&1) || { echo "$out" | sed 's/^psql:[^ ]* //' ; echo "PENGUJIAN GAGAL"; exit 1; }
  echo "$out" | grep -o 'ok - .*' | sed 's/^/  /'
  n=$(echo "$out" | grep -c 'ok - ' || true)
  total=$((total + n))
done
echo "--- uji transaksi bersamaan"
bash "$ROOT/supabase/tests/concurrency/konkurensi.sh" "$DB_NAME" || { echo "PENGUJIAN GAGAL"; exit 1; }
total=$((total + 1))
echo "==> SEMUA LOLOS: $total pemeriksaan"
