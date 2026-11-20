#!/usr/bin/env bash
# Uji transaksi bersamaan: dua sesi memindahkan 8 dari stok 10 pada saat yang sama.
# Harapan: satu berhasil, satu ditolak "tidak mencukupi"; saldo tidak minus.
set -uo pipefail
DB="$1"
PSQL=(psql -X -q -t -A -v ON_ERROR_STOP=1 -d "$DB")

"${PSQL[@]}" <<'SQL' >/dev/null
insert into public.items (code, name, category_id, unit_id, is_active)
select 'KONK-01', 'Barang Uji Konkurensi', c.id, u.id, true from public.item_categories c, public.item_units u
 where c.code = 'ATK' and u.code = 'PCS' on conflict (code) do nothing;
insert into public.warehouses (code, name) values ('GKONK', 'Gudang Konkurensi') on conflict (code) do nothing;
insert into public.storage_locations (warehouse_id, room, rack, location_number, code)
select id, 'R', 'A', '1', 'GKONK-A-1' from public.warehouses where code = 'GKONK' on conflict do nothing;
insert into public.storage_locations (warehouse_id, room, rack, location_number, code)
select id, 'R', 'B', '1', 'GKONK-B-1' from public.warehouses where code = 'GKONK' on conflict do nothing;
select private.stock_in('OPENING_BALANCE', date '2026-11-01', i.id, l.id, 'layak_pakai', 10, 1000, date '2026-11-01',
                        null, null, null, 'receipts', gen_random_uuid(), 'UJI-KONK', 'Saldo uji konkurensi')
  from public.items i, public.storage_locations l where i.code = 'KONK-01' and l.code = 'GKONK-A-1';
SQL

TRANSFER="select tests.login_as('pgb@test.id');
select public.rpc_transfer_stock(date '2026-11-20', 'Uji konkurensi', jsonb_build_array(jsonb_build_object(
  'item_id', (select id from public.items where code = 'KONK-01'),
  'from_location_id', (select id from public.storage_locations where code = 'GKONK-A-1'),
  'to_location_id', (select id from public.storage_locations where code = 'GKONK-B-1'), 'quantity', 8)));"

( "${PSQL[@]}" -c "begin; $TRANSFER select pg_sleep(2); commit;" > /tmp/konk_a.log 2>&1; echo $? > /tmp/konk_a.rc ) &
sleep 0.7
( "${PSQL[@]}" -c "begin; $TRANSFER commit;" > /tmp/konk_b.log 2>&1; echo $? > /tmp/konk_b.rc ) &
wait

rc_a=$(cat /tmp/konk_a.rc); rc_b=$(cat /tmp/konk_b.rc)
result=$("${PSQL[@]}" -c "select string_agg(l.code || '=' || b.quantity::int, ',' order by l.code)
  from public.stock_balances b join public.storage_locations l on l.id = b.location_id
  join public.items i on i.id = b.item_id where i.code = 'KONK-01'")
fail=0
[ "$rc_a" = "0" ] || { echo "  GAGAL: sesi pertama seharusnya berhasil"; cat /tmp/konk_a.log; fail=1; }
[ "$rc_b" != "0" ] && grep -q "tidak mencukupi" /tmp/konk_b.log || { echo "  GAGAL: sesi kedua seharusnya ditolak 'tidak mencukupi'"; cat /tmp/konk_b.log; fail=1; }
[ "$result" = "GKONK-A-1=2,GKONK-B-1=8" ] || { echo "  GAGAL: saldo akhir $result"; fail=1; }
if [ $fail = 0 ]; then
  echo "  ok - Dua perpindahan bersamaan: satu berhasil, satu ditolak; saldo akhir A=2, B=8 (tidak minus, tidak ganda)"
fi
exit $fail
