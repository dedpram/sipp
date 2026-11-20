-- =====================================================================
-- SIPP — PEMBARUAN DATABASE FASE 4A (Penerimaan, Penyimpanan, Kartu Stok)
-- Versi 4: alur pemeriksaan oleh PPK / Pejabat Pengawas; role KPA dihapus;
--          Petugas Akuntansi hanya untuk Rekonsiliasi.
-- Boleh dijalankan walaupun versi sebelumnya sudah pernah dijalankan.
-- Cara pakai: Supabase Dashboard > SQL Editor > New query (tab KOSONG) >
--             tempel SELURUH isi file ini > klik RUN.
-- Bila muncul peringatan "destructive operation", klik "Run this query".
-- Aman dijalankan ulang; tidak menghapus data.
-- =====================================================================

-- >>>>> 20261121000900_transaksi_tabel.sql
-- =====================================================================
-- SIPP — Migration 0009: Tabel transaksi Fase 4A
-- Penerimaan, buku mutasi (ledger), batch FIFO/FEFO, saldo, perpindahan
-- lokasi, persetujuan, riwayat status, lampiran dokumen.
-- Saldo & mutasi TIDAK dapat ditulis langsung dari aplikasi: hanya
-- melalui fungsi RPC di migration 0010.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Penerimaan
-- ---------------------------------------------------------------------
create table if not exists public.receipts (
  id                     uuid primary key default gen_random_uuid(),
  receipt_no             text not null unique,
  receipt_date           date not null default ((now() at time zone 'Asia/Jakarta')::date),
  source_type            text not null check (source_type in ('pembelian','hibah','transfer','lainnya','saldo_awal')),
  supplier_id            uuid references public.suppliers(id),
  contract_no            text,
  contract_date          date,
  order_no               text,
  delivery_note_no       text,
  invoice_no             text,
  source_description     text,              -- asal hibah/transfer/perolehan lain
  warehouse_id           uuid not null references public.warehouses(id),
  status                 text not null default 'draft' check (status in (
                           'draft','menunggu_pemeriksaan','dalam_pemeriksaan','tidak_sesuai',
                           'menunggu_tindak_lanjut_penyedia','menunggu_pengesahan','disetujui',
                           'diterima_disimpan','selesai','dibatalkan')),
  notes                  text,
  inspector_id           uuid references public.profiles(id),
  inspected_at           timestamptz,
  inspection_notes       text,
  approved_by            uuid references public.profiles(id),
  approved_at            timestamptz,
  finalized_by           uuid references public.profiles(id),
  finalized_at           timestamptz,
  accounting_verified_by uuid references public.profiles(id),
  accounting_verified_at timestamptz,
  cancel_reason          text,
  total_value            numeric(18,2) not null default 0,
  created_at             timestamptz not null default now(),
  created_by             uuid references public.profiles(id),
  updated_at             timestamptz,
  updated_by             uuid references public.profiles(id)
);
create index if not exists idx_receipts_status on public.receipts(status);
create index if not exists idx_receipts_date   on public.receipts(receipt_date desc);
create index if not exists idx_receipts_supplier on public.receipts(supplier_id);

create table if not exists public.receipt_details (
  id                 uuid primary key default gen_random_uuid(),
  receipt_id         uuid not null references public.receipts(id),
  line_no            integer not null default 1,
  item_id            uuid not null references public.items(id),
  qty_ordered        numeric(14,3) check (qty_ordered is null or qty_ordered >= 0),
  qty_received       numeric(14,3) not null check (qty_received > 0),
  qty_accepted       numeric(14,3) not null default 0 check (qty_accepted >= 0),
  qty_rejected       numeric(14,3) not null default 0 check (qty_rejected >= 0),
  unit_cost          numeric(18,4) not null check (unit_cost >= 0),
  location_id        uuid references public.storage_locations(id),
  expiry_date        date,
  inspection_result  text check (inspection_result is null or inspection_result in
                       ('sesuai','tidak_sesuai_jumlah','tidak_sesuai_spesifikasi','rusak')),
  inspection_notes   text,
  created_at         timestamptz not null default now(),
  created_by         uuid references public.profiles(id),
  updated_at         timestamptz,
  updated_by         uuid references public.profiles(id),
  constraint receipt_details_qty check (qty_accepted + qty_rejected <= qty_received)
);
create index if not exists idx_receipt_details_receipt on public.receipt_details(receipt_id);
create index if not exists idx_receipt_details_item    on public.receipt_details(item_id);

-- ---------------------------------------------------------------------
-- Stok: batch (lapisan FIFO/FEFO), saldo, buku mutasi
-- ---------------------------------------------------------------------
create table if not exists public.stock_batches (
  id                        uuid primary key default gen_random_uuid(),
  item_id                   uuid not null references public.items(id),
  location_id               uuid not null references public.storage_locations(id),
  condition                 text not null default 'layak_pakai' check (condition in (
                              'layak_pakai','rusak_ringan','rusak_berat','usang','kedaluwarsa',
                              'dalam_pemeriksaan','menunggu_penyelesaian')),
  source_receipt_detail_id  uuid references public.receipt_details(id),
  parent_batch_id           uuid references public.stock_batches(id),
  acquired_at               date not null,
  expiry_date               date,
  unit_cost                 numeric(18,4) not null check (unit_cost >= 0),
  qty_initial               numeric(14,3) not null check (qty_initial > 0),
  qty_remaining             numeric(14,3) not null check (qty_remaining >= 0),
  created_at                timestamptz not null default now(),
  constraint stock_batches_remaining check (qty_remaining <= qty_initial)
);
create index if not exists idx_batches_fifo on public.stock_batches
  (item_id, location_id, condition, expiry_date nulls last, acquired_at, created_at) where qty_remaining > 0;

create table if not exists public.stock_balances (
  id                uuid primary key default gen_random_uuid(),
  item_id           uuid not null references public.items(id),
  location_id       uuid not null references public.storage_locations(id),
  condition         text not null default 'layak_pakai',
  quantity          numeric(14,3) not null default 0 check (quantity >= 0),
  reserved_qty      numeric(14,3) not null default 0 check (reserved_qty >= 0),
  total_value       numeric(18,2) not null default 0 check (total_value >= 0),
  last_movement_at  timestamptz,
  constraint stock_balances_unique unique (item_id, location_id, condition),
  constraint stock_balances_reserved check (reserved_qty <= quantity)
);
create index if not exists idx_balances_item on public.stock_balances(item_id);

create table if not exists public.stock_movements (
  id                   bigint generated always as identity primary key,
  movement_date        date not null,
  posted_at            timestamptz not null default clock_timestamp(),
  movement_type        text not null check (movement_type in (
                         'OPENING_BALANCE','RECEIPT_IN','ISSUE_OUT','TRANSFER_OUT','TRANSFER_IN',
                         'ADJ_IN','ADJ_OUT','RECLASS_OUT','RECLASS_IN','WRITE_OFF')),
  item_id              uuid not null references public.items(id),
  location_id          uuid not null references public.storage_locations(id),
  batch_id             uuid not null references public.stock_batches(id),
  condition            text not null,
  qty_in               numeric(14,3) not null default 0 check (qty_in >= 0),
  qty_out              numeric(14,3) not null default 0 check (qty_out >= 0),
  unit_cost            numeric(18,4) not null,
  value_in             numeric(18,2) not null default 0,
  value_out            numeric(18,2) not null default 0,
  ref_table            text not null,
  ref_id               uuid not null,
  ref_no               text not null,
  description          text not null,
  posted_by            uuid references public.profiles(id),
  constraint stock_movements_one_side check ((qty_in > 0 and qty_out = 0) or (qty_out > 0 and qty_in = 0))
);
create index if not exists idx_movements_item_time on public.stock_movements(item_id, movement_date, id);
create index if not exists idx_movements_ref       on public.stock_movements(ref_table, ref_id);

-- ---------------------------------------------------------------------
-- Perpindahan lokasi
-- ---------------------------------------------------------------------
create table if not exists public.stock_transfers (
  id             uuid primary key default gen_random_uuid(),
  transfer_no    text not null unique,
  transfer_date  date not null,
  reason         text not null check (length(trim(reason)) >= 5),
  status         text not null default 'selesai' check (status in ('selesai')),
  created_at     timestamptz not null default now(),
  created_by     uuid references public.profiles(id)
);

create table if not exists public.stock_transfer_details (
  id                uuid primary key default gen_random_uuid(),
  transfer_id       uuid not null references public.stock_transfers(id),
  item_id           uuid not null references public.items(id),
  from_location_id  uuid not null references public.storage_locations(id),
  to_location_id    uuid not null references public.storage_locations(id),
  condition         text not null default 'layak_pakai',
  quantity          numeric(14,3) not null check (quantity > 0),
  constraint stock_transfer_details_diff check (from_location_id <> to_location_id)
);
create index if not exists idx_transfer_details_transfer on public.stock_transfer_details(transfer_id);

-- ---------------------------------------------------------------------
-- Persetujuan, riwayat status, lampiran (dipakai lintas modul)
-- ---------------------------------------------------------------------
create table if not exists public.approvals (
  id                  uuid primary key default gen_random_uuid(),
  ref_table           text not null,
  ref_id              uuid not null,
  level               integer not null default 1,
  required_role_code  text not null references public.roles(code),
  approver_id         uuid not null references public.profiles(id),
  decision            text not null check (decision in ('approved','rejected','returned')),
  notes               text,
  decided_at          timestamptz not null default now()
);
create index if not exists idx_approvals_ref on public.approvals(ref_table, ref_id);

create table if not exists public.status_histories (
  id           bigint generated always as identity primary key,
  ref_table    text not null,
  ref_id       uuid not null,
  from_status  text,
  to_status    text not null,
  comment      text,
  actor_id     uuid references public.profiles(id),
  created_at   timestamptz not null default now()
);
create index if not exists idx_status_histories_ref on public.status_histories(ref_table, ref_id, id);

create table if not exists public.attachments (
  id            uuid primary key default gen_random_uuid(),
  ref_table     text not null check (ref_table in ('receipts','stock_transfers')),
  ref_id        uuid not null,
  doc_type      text not null check (doc_type in (
                  'surat_jalan','faktur','kontrak','ba_pemeriksaan','ba_penerimaan','ba_saldo_awal',
                  'foto','sk','lainnya')),
  storage_path  text not null unique,
  file_name     text not null,
  mime_type     text,
  size_bytes    bigint check (size_bytes is null or size_bytes <= 10485760),
  uploaded_by   uuid references public.profiles(id),
  uploaded_at   timestamptz not null default now()
);
create index if not exists idx_attachments_ref on public.attachments(ref_table, ref_id);

-- Penyetuju saldo awal = KPA (sama seperti perolehan non-pembelian).
update public.approval_settings
   set applies_when = '{"source_type":["hibah","transfer","lainnya","saldo_awal"]}'::jsonb
 where transaction_type = 'receipt' and approver_role_code = 'KPA'
   and not (applies_when -> 'source_type') ? 'saldo_awal';

-- ---------------------------------------------------------------------
-- Trigger umum
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['receipts','receipt_details'] loop
    execute format('drop trigger if exists trg_row_meta on public.%I', t);
    execute format('create trigger trg_row_meta before insert or update on public.%I
                    for each row execute function private.tg_set_row_meta()', t);
  end loop;
  foreach t in array array['receipts','receipt_details','stock_transfers','stock_transfer_details','attachments'] loop
    execute format('drop trigger if exists trg_audit on public.%I', t);
    execute format('create trigger trg_audit after insert or update or delete on public.%I
                    for each row execute function private.tg_audit_row()', t);
  end loop;
  -- Tabel jejak bersifat permanen.
  foreach t in array array['stock_movements','approvals','status_histories','attachments'] loop
    execute format('drop trigger if exists trg_block_update_delete on public.%I', t);
    execute format('create trigger trg_block_update_delete before update or delete on public.%I
                    for each row execute function private.tg_block_modification()', t);
  end loop;
end $$;

-- Nomor penerimaan otomatis.
create or replace function private.tg_receipt_number()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    new.receipt_no := private.next_document_number('PNR', new.receipt_date);
    new.status := 'draft';
  end if;
  return new;
end;
$$;
revoke all on function private.tg_receipt_number() from public;
drop trigger if exists trg_receipt_number on public.receipts;
create trigger trg_receipt_number before insert on public.receipts
  for each row execute function private.tg_receipt_number();

-- Penjaga penerimaan: di luar RPC, hanya draf yang boleh diubah, dan
-- kolom status/pemeriksaan/pengesahan tidak boleh diisi langsung.
create or replace function private.tg_receipts_guard()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if private.is_system_context() then
    return new;
  end if;
  if tg_op = 'INSERT' then
    if new.inspector_id is not null or new.approved_by is not null or new.finalized_by is not null then
      raise exception 'Kolom pemeriksaan/pengesahan diisi oleh sistem.' using errcode = '42501';
    end if;
    return new;
  end if;
  if old.status <> 'draft' then
    raise exception 'Penerimaan % sudah diajukan dan tidak dapat diubah langsung.', old.receipt_no using errcode = 'P0001';
  end if;
  if new.status is distinct from old.status
     or new.receipt_no is distinct from old.receipt_no
     or new.inspector_id is distinct from old.inspector_id
     or new.approved_by is distinct from old.approved_by
     or new.finalized_by is distinct from old.finalized_by
     or new.accounting_verified_by is distinct from old.accounting_verified_by
     or new.total_value is distinct from old.total_value then
    raise exception 'Status dan kolom pengesahan hanya dapat diubah melalui tombol proses.' using errcode = '42501';
  end if;
  return new;
end;
$$;
revoke all on function private.tg_receipts_guard() from public;
drop trigger if exists trg_receipts_guard on public.receipts;
create trigger trg_receipts_guard before insert or update on public.receipts
  for each row execute function private.tg_receipts_guard();

create or replace function private.tg_receipt_details_guard()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare v_status text;
begin
  if private.is_system_context() then
    return coalesce(new, old);
  end if;
  select status into v_status from public.receipts where id = coalesce(new.receipt_id, old.receipt_id);
  if v_status is distinct from 'draft' then
    raise exception 'Rincian hanya dapat diubah saat penerimaan masih draf.' using errcode = 'P0001';
  end if;
  if tg_op in ('INSERT','UPDATE') then
    -- Hasil pemeriksaan diisi Petugas Penerima melalui RPC.
    new.qty_accepted := 0;
    new.qty_rejected := 0;
    new.inspection_result := null;
    new.inspection_notes := null;
    if tg_op = 'UPDATE' and new.receipt_id <> old.receipt_id then
      raise exception 'Rincian tidak dapat dipindahkan ke penerimaan lain.' using errcode = '42501';
    end if;
  end if;
  return coalesce(new, old);
end;
$$;
revoke all on function private.tg_receipt_details_guard() from public;
drop trigger if exists trg_receipt_details_guard on public.receipt_details;
create trigger trg_receipt_details_guard before insert or update or delete on public.receipt_details
  for each row execute function private.tg_receipt_details_guard();

-- Riwayat status otomatis.
create or replace function private.tg_status_history()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if tg_op = 'INSERT' or new.status is distinct from old.status then
    insert into public.status_histories (ref_table, ref_id, from_status, to_status, comment, actor_id)
    values (tg_table_name, new.id, case when tg_op = 'UPDATE' then old.status end, new.status,
            nullif(current_setting('app.status_comment', true), ''), auth.uid());
  end if;
  return new;
end;
$$;
revoke all on function private.tg_status_history() from public;
drop trigger if exists trg_status_history on public.receipts;
create trigger trg_status_history after insert or update of status on public.receipts
  for each row execute function private.tg_status_history();

-- >>>>> 20261121001000_transaksi_rpc.sql
-- =====================================================================
-- SIPP — Migration 0010: Fungsi transaksi Fase 4A & aturan akses
-- Semua perubahan saldo terjadi di fungsi ini, dalam satu transaksi
-- database (atomic), dengan penguncian per barang agar tidak terjadi
-- saldo ganda atau stok negatif pada transaksi bersamaan.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Utilitas
-- ---------------------------------------------------------------------
create or replace function private.begin_rpc(p_comment text default null)
returns void language plpgsql set search_path = '' as $$
begin
  perform set_config('app.via_rpc', 'on', true);
  perform set_config('app.status_comment', coalesce(p_comment, ''), true);
end $$;

create or replace function private.end_rpc()
returns void language plpgsql set search_path = '' as $$
begin
  perform set_config('app.via_rpc', '', true);
  perform set_config('app.status_comment', '', true);
end $$;

create or replace function private.require_active_user()
returns uuid language plpgsql stable security definer set search_path = '' as $$
begin
  if auth.uid() is null or not private.current_user_is_active() then
    raise exception 'Sesi tidak valid atau akun nonaktif.' using errcode = '42501';
  end if;
  return auth.uid();
end $$;

create or replace function private.lock_item(p_item uuid)
returns void language sql set search_path = '' as $$
  select pg_advisory_xact_lock(hashtextextended('sipp-item:' || p_item::text, 0));
$$;

create or replace function private.stock_reader_roles()
returns text[] language sql immutable set search_path = '' as $$
  select array['PGB','KPA','PWS','PPK','PPB','AKT','TSO','AUD'];
$$;

create or replace function private.receipt_reader_roles()
returns text[] language sql immutable set search_path = '' as $$
  select array['PGB','PPB','PPK','KPA','PWS','AKT','AUD'];
$$;

-- Siapa boleh membaca dokumen/riwayat suatu transaksi.
create or replace function private.can_read_ref(p_table text, p_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select private.current_user_is_active() and case p_table
    when 'receipts'        then private.has_any_role(private.receipt_reader_roles())
    when 'stock_transfers' then private.has_any_role(private.stock_reader_roles())
    else false end;
$$;

-- Siapa boleh menambah lampiran pada suatu transaksi.
create or replace function private.can_attach(p_table text, p_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select private.current_user_is_active() and case p_table
    when 'receipts' then private.has_any_role(array['PGB','PPB','PPK'])
      and exists (select 1 from public.receipts r where r.id = p_id and r.status in
        ('draft','menunggu_pemeriksaan','dalam_pemeriksaan','tidak_sesuai',
         'menunggu_tindak_lanjut_penyedia','menunggu_pengesahan'))
    when 'stock_transfers' then private.has_role('PGB')
    else false end;
$$;

-- Versi untuk path Storage: '<tabel>/<uuid>/<nama file>'
create or replace function private.path_ref(p_name text, out ref_table text, out ref_id uuid)
language plpgsql immutable set search_path = '' as $$
declare parts text[] := string_to_array(p_name, '/');
begin
  ref_table := parts[1];
  begin
    ref_id := parts[2]::uuid;
  exception when others then
    ref_id := null;
  end;
end $$;

create or replace function private.can_attach_path(p_name text)
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce((select private.can_attach(p.ref_table, p.ref_id) from private.path_ref(p_name) p where p.ref_id is not null), false);
$$;

create or replace function private.can_read_path(p_name text)
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce((select private.can_read_ref(p.ref_table, p.ref_id) from private.path_ref(p_name) p where p.ref_id is not null), false);
$$;

-- ---------------------------------------------------------------------
-- Buku mutasi (ledger)
-- ---------------------------------------------------------------------
create or replace function private.refresh_balance(p_item uuid, p_location uuid, p_condition text)
returns void language sql security definer set search_path = '' as $$
  insert into public.stock_balances as b (item_id, location_id, condition, quantity, total_value, last_movement_at)
  select p_item, p_location, p_condition,
         coalesce(sum(s.qty_remaining), 0),
         coalesce(round(sum(s.qty_remaining * s.unit_cost), 2), 0),
         now()
    from public.stock_batches s
   where s.item_id = p_item and s.location_id = p_location and s.condition = p_condition
  on conflict (item_id, location_id, condition) do update
    set quantity = excluded.quantity, total_value = excluded.total_value, last_movement_at = excluded.last_movement_at;
$$;

create or replace function private.record_movement(
  p_type text, p_date date, p_item uuid, p_location uuid, p_batch uuid, p_condition text,
  p_qty_in numeric, p_qty_out numeric, p_unit_cost numeric,
  p_ref_table text, p_ref_id uuid, p_ref_no text, p_desc text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  insert into public.stock_movements
    (movement_date, movement_type, item_id, location_id, batch_id, condition, qty_in, qty_out, unit_cost,
     value_in, value_out, ref_table, ref_id, ref_no, description, posted_by)
  values
    (p_date, p_type, p_item, p_location, p_batch, p_condition, p_qty_in, p_qty_out, p_unit_cost,
     round(p_qty_in * p_unit_cost, 2), round(p_qty_out * p_unit_cost, 2),
     p_ref_table, p_ref_id, p_ref_no, p_desc, auth.uid());
end $$;

-- Barang keluar/pindah tidak boleh bertanggal sebelum mutasi terakhir barang
-- (mencegah saldo historis menjadi minus pada kartu stok).
create or replace function private.assert_not_backdated(p_item uuid, p_date date)
returns void language plpgsql stable security definer set search_path = '' as $$
declare v_last date; v_code text;
begin
  select max(movement_date) into v_last from public.stock_movements where item_id = p_item;
  if v_last is not null and p_date < v_last then
    select code into v_code from public.items where id = p_item;
    raise exception 'Tanggal % lebih awal dari mutasi terakhir barang % (%). Gunakan tanggal yang sama atau sesudahnya.',
      to_char(p_date, 'DD-MM-YYYY'), v_code, to_char(v_last, 'DD-MM-YYYY') using errcode = 'P0001';
  end if;
end $$;

-- Barang masuk: membentuk batch baru.
create or replace function private.stock_in(
  p_type text, p_date date, p_item uuid, p_location uuid, p_condition text, p_qty numeric,
  p_unit_cost numeric, p_acquired date, p_expiry date, p_source_detail uuid, p_parent_batch uuid,
  p_ref_table text, p_ref_id uuid, p_ref_no text, p_desc text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_batch uuid;
begin
  if p_qty <= 0 then
    raise exception 'Jumlah masuk harus lebih dari 0.' using errcode = '22023';
  end if;
  insert into public.stock_batches
    (item_id, location_id, condition, source_receipt_detail_id, parent_batch_id, acquired_at, expiry_date,
     unit_cost, qty_initial, qty_remaining)
  values (p_item, p_location, p_condition, p_source_detail, p_parent_batch, p_acquired, p_expiry,
          p_unit_cost, p_qty, p_qty)
  returning id into v_batch;
  perform private.refresh_balance(p_item, p_location, p_condition);
  perform private.record_movement(p_type, p_date, p_item, p_location, v_batch, p_condition,
                                  p_qty, 0, p_unit_cost, p_ref_table, p_ref_id, p_ref_no, p_desc);
  return v_batch;
end $$;

-- Barang keluar dengan urutan FEFO (barang ber-kedaluwarsa) lalu FIFO.
-- Mengembalikan potongan batch yang dipakai.
create or replace function private.consume_stock(
  p_type text, p_date date, p_item uuid, p_location uuid, p_condition text, p_qty numeric,
  p_ref_table text, p_ref_id uuid, p_ref_no text, p_desc text)
returns table (batch_id uuid, qty numeric, unit_cost numeric, acquired_at date, expiry_date date)
language plpgsql security definer set search_path = '' as $$
declare
  v_need   numeric := p_qty;
  v_avail  numeric;
  v_take   numeric;
  v_fefo   boolean;
  b        record;
  v_name   text;
begin
  if p_qty <= 0 then
    raise exception 'Jumlah keluar harus lebih dari 0.' using errcode = '22023';
  end if;
  perform private.assert_not_backdated(p_item, p_date);
  select has_expiry, name into v_fefo, v_name from public.items where id = p_item;

  select coalesce(quantity - reserved_qty, 0) into v_avail
    from public.stock_balances where item_id = p_item and location_id = p_location and condition = p_condition;
  if coalesce(v_avail, 0) < p_qty then
    raise exception 'Stok % tidak mencukupi di lokasi tersebut. Tersedia %, diminta %.',
      v_name, trim(to_char(coalesce(v_avail, 0), 'FM999G999G990D###')), trim(to_char(p_qty, 'FM999G999G990D###'))
      using errcode = 'P0001';
  end if;

  for b in
    select s.id, s.qty_remaining, s.unit_cost, s.acquired_at, s.expiry_date
      from public.stock_batches s
     where s.item_id = p_item and s.location_id = p_location and s.condition = p_condition and s.qty_remaining > 0
     order by case when v_fefo then s.expiry_date end nulls last, s.acquired_at, s.created_at, s.id
     for update
  loop
    exit when v_need <= 0;
    v_take := least(v_need, b.qty_remaining);
    update public.stock_batches set qty_remaining = qty_remaining - v_take where id = b.id;
    perform private.refresh_balance(p_item, p_location, p_condition);
    perform private.record_movement(p_type, p_date, p_item, p_location, b.id, p_condition,
                                    0, v_take, b.unit_cost, p_ref_table, p_ref_id, p_ref_no, p_desc);
    batch_id := b.id; qty := v_take; unit_cost := b.unit_cost; acquired_at := b.acquired_at; expiry_date := b.expiry_date;
    return next;
    v_need := v_need - v_take;
  end loop;

  if v_need > 0 then
    raise exception 'Stok tidak mencukupi (data batch tidak sesuai saldo). Hubungi Super Admin.' using errcode = 'P0001';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- PENERIMAAN
-- ---------------------------------------------------------------------
create or replace function private.receipt_for_update(p_id uuid)
returns public.receipts language plpgsql security definer set search_path = '' as $$
declare r public.receipts;
begin
  select * into r from public.receipts where id = p_id for update;
  if not found then
    raise exception 'Penerimaan tidak ditemukan.' using errcode = 'P0002';
  end if;
  return r;
end $$;

create or replace function private.receipt_status_label(p text)
returns text language sql immutable set search_path = '' as $$
  select case p
    when 'draft' then 'Draf' when 'menunggu_pemeriksaan' then 'Menunggu pemeriksaan'
    when 'dalam_pemeriksaan' then 'Dalam pemeriksaan' when 'tidak_sesuai' then 'Tidak sesuai'
    when 'menunggu_tindak_lanjut_penyedia' then 'Menunggu tindak lanjut penyedia'
    when 'menunggu_pengesahan' then 'Menunggu pengesahan' when 'disetujui' then 'Disetujui'
    when 'diterima_disimpan' then 'Diterima dan disimpan' when 'selesai' then 'Selesai'
    when 'dibatalkan' then 'Dibatalkan' else p end;
$$;

create or replace function private.receipt_expect(r public.receipts, p_statuses text[])
returns void language plpgsql set search_path = '' as $$
begin
  if not (r.status = any(p_statuses)) then
    raise exception 'Penerimaan % berstatus "%"; tindakan ini tidak dapat dilakukan.',
      r.receipt_no, private.receipt_status_label(r.status) using errcode = 'P0001';
  end if;
end $$;

-- 1. Ajukan untuk diperiksa (pembuat draf).
create or replace function public.rpc_receipt_submit(p_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  r public.receipts;
  v_uid uuid := private.require_active_user();
  v_lines integer;
  v_bad text;
begin
  r := private.receipt_for_update(p_id);
  perform private.receipt_expect(r, array['draft']);
  if r.created_by is distinct from v_uid then
    raise exception 'Hanya pembuat penerimaan yang dapat mengajukannya.' using errcode = '42501';
  end if;
  select count(*) into v_lines from public.receipt_details where receipt_id = p_id;
  if v_lines = 0 then
    raise exception 'Tambahkan minimal satu barang sebelum mengajukan.' using errcode = 'P0001';
  end if;
  if r.source_type = 'pembelian' and (r.supplier_id is null or coalesce(r.contract_no, r.order_no) is null) then
    raise exception 'Penerimaan dari pembelian wajib mencantumkan penyedia dan nomor kontrak/SPK/pesanan.' using errcode = 'P0001';
  end if;
  if r.source_type in ('hibah','transfer','lainnya') and nullif(trim(coalesce(r.source_description, '')), '') is null then
    raise exception 'Jelaskan asal perolehan (pemberi hibah/asal transfer).' using errcode = 'P0001';
  end if;
  select string_agg(i.code, ', ') into v_bad
    from public.receipt_details d join public.items i on i.id = d.item_id
   where d.receipt_id = p_id and not i.is_active;
  if v_bad is not null then
    raise exception 'Barang berikut belum aktif: %. Minta Super Admin mengaktifkannya.', v_bad using errcode = 'P0001';
  end if;

  perform private.begin_rpc('Diajukan untuk pemeriksaan');
  update public.receipts
     set status = 'menunggu_pemeriksaan',
         total_value = (select coalesce(round(sum(qty_received * unit_cost), 2), 0) from public.receipt_details where receipt_id = p_id)
   where id = p_id;
  perform private.end_rpc();
end $$;

-- 2. Mulai pemeriksaan (Petugas Penerima Barang, bukan pembuat).
create or replace function public.rpc_receipt_start_inspection(p_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare r public.receipts; v_uid uuid := private.require_active_user();
begin
  if not private.has_role('PPB') then
    raise exception 'Hanya Petugas Penerima Barang yang dapat memeriksa.' using errcode = '42501';
  end if;
  r := private.receipt_for_update(p_id);
  perform private.receipt_expect(r, array['menunggu_pemeriksaan','menunggu_tindak_lanjut_penyedia']);
  if r.created_by = v_uid then
    raise exception 'Pembuat penerimaan tidak boleh memeriksa penerimaannya sendiri (pemisahan fungsi).' using errcode = '42501';
  end if;
  perform private.begin_rpc('Pemeriksaan dimulai');
  update public.receipts set status = 'dalam_pemeriksaan', inspector_id = v_uid where id = p_id;
  perform private.end_rpc();
end $$;

-- 3. Catat hasil pemeriksaan.
-- p_lines: [{"detail_id","qty_received","qty_accepted","qty_rejected","result","notes","expiry_date"}]
-- p_decision: 'lanjut' (ajukan pengesahan atas jumlah yang diterima) | 'tindak_lanjut' (ketidaksesuaian)
create or replace function public.rpc_receipt_record_inspection(p_id uuid, p_lines jsonb, p_notes text, p_decision text)
returns void language plpgsql security definer set search_path = '' as $$
declare
  r public.receipts;
  v_uid uuid := private.require_active_user();
  l jsonb;
  d record;
  v_acc numeric; v_rej numeric; v_rec numeric; v_res text; v_exp date;
  v_issue boolean := false;
  v_total_acc numeric := 0;
  v_missing integer;
begin
  r := private.receipt_for_update(p_id);
  perform private.receipt_expect(r, array['dalam_pemeriksaan']);
  if r.inspector_id is distinct from v_uid then
    raise exception 'Hanya petugas yang memulai pemeriksaan yang dapat mencatat hasilnya.' using errcode = '42501';
  end if;
  if p_decision not in ('lanjut','tindak_lanjut') then
    raise exception 'Keputusan pemeriksaan tidak dikenal.' using errcode = '22023';
  end if;

  perform private.begin_rpc(case p_decision when 'lanjut' then 'Pemeriksaan selesai, diajukan pengesahan'
                                            else 'Ditemukan ketidaksesuaian' end);
  for l in select * from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) loop
    select d2.*, i.has_expiry, i.code into d
      from public.receipt_details d2 join public.items i on i.id = d2.item_id
     where d2.id = (l ->> 'detail_id')::uuid and d2.receipt_id = p_id;
    if not found then
      raise exception 'Rincian penerimaan tidak dikenal.' using errcode = 'P0002';
    end if;
    v_rec := coalesce((l ->> 'qty_received')::numeric, d.qty_received);
    v_acc := coalesce((l ->> 'qty_accepted')::numeric, 0);
    v_rej := coalesce((l ->> 'qty_rejected')::numeric, 0);
    v_res := l ->> 'result';
    v_exp := nullif(l ->> 'expiry_date', '')::date;
    if v_rec <= 0 or v_acc < 0 or v_rej < 0 or v_acc + v_rej <> v_rec then
      raise exception 'Barang %: jumlah diterima baik + ditolak harus sama dengan jumlah yang datang.', d.code using errcode = '22023';
    end if;
    if v_res is null or v_res not in ('sesuai','tidak_sesuai_jumlah','tidak_sesuai_spesifikasi','rusak') then
      raise exception 'Barang %: pilih hasil pemeriksaan.', d.code using errcode = '22023';
    end if;
    if v_res = 'sesuai' and v_rej > 0 then
      raise exception 'Barang %: hasil "sesuai" tidak boleh memiliki jumlah ditolak.', d.code using errcode = '22023';
    end if;
    if d.has_expiry and v_acc > 0 and v_exp is null then
      raise exception 'Barang % wajib diisi tanggal kedaluwarsa.', d.code using errcode = '22023';
    end if;
    if v_res <> 'sesuai' or v_rej > 0 or (d.qty_ordered is not null and v_rec <> d.qty_ordered) then
      v_issue := true;
    end if;
    update public.receipt_details
       set qty_received = v_rec, qty_accepted = v_acc, qty_rejected = v_rej,
           inspection_result = v_res, inspection_notes = nullif(trim(l ->> 'notes'), ''), expiry_date = v_exp
     where id = d.id;
  end loop;

  select count(*) into v_missing from public.receipt_details where receipt_id = p_id and inspection_result is null;
  if v_missing > 0 then
    raise exception 'Semua barang harus diperiksa (% belum).', v_missing using errcode = 'P0001';
  end if;
  select coalesce(sum(qty_accepted), 0) into v_total_acc from public.receipt_details where receipt_id = p_id;

  if p_decision = 'lanjut' and v_total_acc <= 0 then
    raise exception 'Tidak ada barang yang diterima baik; pilih tindak lanjut ketidaksesuaian.' using errcode = 'P0001';
  end if;
  if p_decision = 'tindak_lanjut' and not v_issue then
    raise exception 'Tidak ada ketidaksesuaian yang dicatat.' using errcode = 'P0001';
  end if;

  update public.receipts
     set status = case p_decision when 'lanjut' then 'menunggu_pengesahan' else 'tidak_sesuai' end,
         inspected_at = now(),
         inspection_notes = nullif(trim(coalesce(p_notes, '')), ''),
         total_value = (select coalesce(round(sum(qty_accepted * unit_cost), 2), 0) from public.receipt_details where receipt_id = p_id)
   where id = p_id;
  perform private.end_rpc();
end $$;

-- 3b. Ketidaksesuaian diteruskan ke penyedia (PPK / Pengurus Barang).
create or replace function public.rpc_receipt_vendor_followup(p_id uuid, p_comment text)
returns void language plpgsql security definer set search_path = '' as $$
declare r public.receipts;
begin
  perform private.require_active_user();
  if not private.has_any_role(array['PPK','PGB']) then
    raise exception 'Hanya PPK atau Pengurus Barang yang dapat meneruskan ke penyedia.' using errcode = '42501';
  end if;
  r := private.receipt_for_update(p_id);
  perform private.receipt_expect(r, array['tidak_sesuai']);
  if length(trim(coalesce(p_comment, ''))) < 5 then
    raise exception 'Tuliskan tindak lanjut yang diminta kepada penyedia (minimal 5 karakter).' using errcode = '22023';
  end if;
  perform private.begin_rpc(p_comment);
  update public.receipts set status = 'menunggu_tindak_lanjut_penyedia' where id = p_id;
  perform private.end_rpc();
end $$;

-- 4. Pengesahan / pengembalian ke pemeriksa.
create or replace function public.rpc_receipt_decide(p_id uuid, p_decision text, p_notes text)
returns void language plpgsql security definer set search_path = '' as $$
declare
  r public.receipts;
  v_uid uuid := private.require_active_user();
  v_role text;
  v_missing text[] := '{}';
begin
  r := private.receipt_for_update(p_id);
  perform private.receipt_expect(r, array['menunggu_pengesahan']);
  if p_decision not in ('approved','returned') then
    raise exception 'Keputusan tidak dikenal.' using errcode = '22023';
  end if;

  select a.approver_role_code into v_role
    from public.approval_settings a
   where a.transaction_type = 'receipt' and a.is_active
     and (a.applies_when = '{}'::jsonb or (a.applies_when -> 'source_type') ? r.source_type)
     and private.has_role(a.approver_role_code)
   order by a.level limit 1;
  if v_role is null then
    raise exception 'Anda tidak berwenang mengesahkan penerimaan jenis ini.' using errcode = '42501';
  end if;
  if v_uid = r.created_by or v_uid = r.inspector_id then
    raise exception 'Pembuat atau pemeriksa tidak boleh mengesahkan penerimaan yang sama (pemisahan fungsi).' using errcode = '42501';
  end if;

  if p_decision = 'returned' then
    if length(trim(coalesce(p_notes, ''))) < 5 then
      raise exception 'Alasan pengembalian wajib diisi (minimal 5 karakter).' using errcode = '22023';
    end if;
    perform private.begin_rpc('Dikembalikan ke pemeriksa: ' || p_notes);
    insert into public.approvals (ref_table, ref_id, level, required_role_code, approver_id, decision, notes)
    values ('receipts', p_id, 1, v_role, v_uid, 'returned', p_notes);
    update public.receipts set status = 'dalam_pemeriksaan' where id = p_id;
    perform private.end_rpc();
    return;
  end if;

  -- Dokumen wajib sebelum pengesahan.
  if r.source_type = 'saldo_awal' then
    if not exists (select 1 from public.attachments where ref_table = 'receipts' and ref_id = p_id and doc_type = 'ba_saldo_awal') then
      v_missing := v_missing || 'Berita Acara Saldo Awal';
    end if;
  else
    if not exists (select 1 from public.attachments where ref_table = 'receipts' and ref_id = p_id and doc_type = 'ba_pemeriksaan') then
      v_missing := v_missing || 'Berita Acara Pemeriksaan';
    end if;
    if r.source_type = 'pembelian' and not exists (
         select 1 from public.attachments where ref_table = 'receipts' and ref_id = p_id and doc_type in ('surat_jalan','faktur')) then
      v_missing := v_missing || 'Surat Jalan atau Faktur';
    end if;
  end if;
  if cardinality(v_missing) > 0 then
    raise exception 'Dokumen wajib belum diunggah: %.', array_to_string(v_missing, ', ') using errcode = 'P0001';
  end if;

  perform private.begin_rpc(coalesce(nullif(trim(p_notes), ''), 'Disahkan'));
  insert into public.approvals (ref_table, ref_id, level, required_role_code, approver_id, decision, notes)
  values ('receipts', p_id, 1, v_role, v_uid, 'approved', nullif(trim(p_notes), ''));
  update public.receipts set status = 'disetujui', approved_by = v_uid, approved_at = now() where id = p_id;
  perform private.end_rpc();
end $$;

-- 5. Simpan ke gudang: saldo bertambah (Pengurus Barang).
-- p_locations: {"<detail_id>": "<location_id>"} untuk melengkapi lokasi simpan.
create or replace function public.rpc_receipt_finalize(p_id uuid, p_locations jsonb default '{}'::jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare
  r public.receipts;
  v_uid uuid := private.require_active_user();
  d record;
  v_loc uuid;
  v_type text;
  v_desc text;
begin
  if not private.has_role('PGB') then
    raise exception 'Hanya Pengurus Barang yang dapat menyimpan barang ke gudang.' using errcode = '42501';
  end if;
  r := private.receipt_for_update(p_id);
  perform private.receipt_expect(r, array['disetujui']);

  v_type := case when r.source_type = 'saldo_awal' then 'OPENING_BALANCE' else 'RECEIPT_IN' end;
  v_desc := case r.source_type
    when 'saldo_awal' then 'Saldo awal'
    when 'pembelian' then 'Pembelian dari ' || coalesce((select name from public.suppliers where id = r.supplier_id), '-')
    when 'hibah' then 'Hibah: ' || coalesce(r.source_description, '-')
    when 'transfer' then 'Transfer masuk: ' || coalesce(r.source_description, '-')
    else 'Perolehan lain: ' || coalesce(r.source_description, '-') end;

  perform private.begin_rpc('Barang disimpan, saldo bertambah');
  for d in
    select * from public.receipt_details where receipt_id = p_id and qty_accepted > 0 order by item_id, line_no
  loop
    v_loc := coalesce(nullif(p_locations ->> d.id::text, '')::uuid, d.location_id);
    if v_loc is null then
      raise exception 'Pilih lokasi penyimpanan untuk semua barang yang diterima.' using errcode = 'P0001';
    end if;
    if not exists (select 1 from public.storage_locations where id = v_loc and is_active and warehouse_id = r.warehouse_id) then
      raise exception 'Lokasi penyimpanan harus aktif dan berada di gudang penerimaan.' using errcode = 'P0001';
    end if;
    update public.receipt_details set location_id = v_loc where id = d.id;
    perform private.lock_item(d.item_id);
    perform private.stock_in(v_type, r.receipt_date, d.item_id, v_loc, 'layak_pakai', d.qty_accepted, d.unit_cost,
                             r.receipt_date, d.expiry_date, d.id, null, 'receipts', r.id, r.receipt_no, v_desc);
  end loop;
  update public.receipts set status = 'diterima_disimpan', finalized_by = v_uid, finalized_at = now() where id = p_id;
  perform private.end_rpc();
end $$;

-- 6. Diperiksa fungsi akuntansi -> selesai.
create or replace function public.rpc_receipt_verify_accounting(p_id uuid, p_notes text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare r public.receipts; v_uid uuid := private.require_active_user();
begin
  if not private.has_role('AKT') then
    raise exception 'Hanya Petugas Akuntansi yang dapat memverifikasi pembukuan.' using errcode = '42501';
  end if;
  r := private.receipt_for_update(p_id);
  perform private.receipt_expect(r, array['diterima_disimpan']);
  perform private.begin_rpc(coalesce(nullif(trim(p_notes), ''), 'Diverifikasi fungsi akuntansi'));
  update public.receipts set status = 'selesai', accounting_verified_by = v_uid, accounting_verified_at = now() where id = p_id;
  perform private.end_rpc();
end $$;

-- 7. Pembatalan (sebelum disahkan).
create or replace function public.rpc_receipt_cancel(p_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare r public.receipts; v_uid uuid := private.require_active_user();
begin
  r := private.receipt_for_update(p_id);
  perform private.receipt_expect(r, array['draft','menunggu_pemeriksaan','tidak_sesuai','menunggu_tindak_lanjut_penyedia']);
  if not (r.created_by = v_uid or private.has_role('PGB')) then
    raise exception 'Hanya pembuat atau Pengurus Barang yang dapat membatalkan.' using errcode = '42501';
  end if;
  if length(trim(coalesce(p_reason, ''))) < 5 then
    raise exception 'Alasan pembatalan wajib diisi (minimal 5 karakter).' using errcode = '22023';
  end if;
  perform private.begin_rpc('Dibatalkan: ' || p_reason);
  update public.receipts set status = 'dibatalkan', cancel_reason = p_reason where id = p_id;
  perform private.end_rpc();
end $$;

-- ---------------------------------------------------------------------
-- PERPINDAHAN LOKASI (total saldo & nilai tidak berubah)
-- p_lines: [{"item_id","from_location_id","to_location_id","quantity"}]
-- ---------------------------------------------------------------------
create or replace function public.rpc_transfer_stock(p_date date, p_reason text, p_lines jsonb)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := private.require_active_user();
  v_id uuid;
  v_no text;
  l jsonb;
  v_item uuid; v_from uuid; v_to uuid; v_qty numeric;
  v_before numeric; v_before_val numeric; v_after numeric; v_after_val numeric;
  c record;
  v_wh_to text;
begin
  if not private.has_role('PGB') then
    raise exception 'Hanya Pengurus Barang yang dapat memindahkan lokasi penyimpanan.' using errcode = '42501';
  end if;
  if length(trim(coalesce(p_reason, ''))) < 5 then
    raise exception 'Alasan perpindahan wajib diisi (minimal 5 karakter).' using errcode = '22023';
  end if;
  if jsonb_array_length(coalesce(p_lines, '[]'::jsonb)) = 0 then
    raise exception 'Isi minimal satu barang yang dipindahkan.' using errcode = '22023';
  end if;
  if p_date > (now() at time zone 'Asia/Jakarta')::date then
    raise exception 'Tanggal perpindahan tidak boleh di masa depan.' using errcode = '22023';
  end if;

  perform private.begin_rpc('Perpindahan lokasi');
  v_no := private.next_document_number('PND', p_date);
  insert into public.stock_transfers (transfer_no, transfer_date, reason, created_by)
  values (v_no, p_date, trim(p_reason), v_uid) returning id into v_id;

  for l in select * from jsonb_array_elements(p_lines) loop
    v_item := (l ->> 'item_id')::uuid;
    v_from := (l ->> 'from_location_id')::uuid;
    v_to   := (l ->> 'to_location_id')::uuid;
    v_qty  := (l ->> 'quantity')::numeric;
    if v_from = v_to then
      raise exception 'Lokasi asal dan tujuan harus berbeda.' using errcode = '22023';
    end if;
    select w.name into v_wh_to from public.storage_locations s join public.warehouses w on w.id = s.warehouse_id
     where s.id = v_to and s.is_active;
    if v_wh_to is null then
      raise exception 'Lokasi tujuan tidak aktif atau tidak ditemukan.' using errcode = 'P0001';
    end if;

    perform private.lock_item(v_item);
    select coalesce(sum(quantity), 0), coalesce(sum(total_value), 0) into v_before, v_before_val
      from public.stock_balances where item_id = v_item;

    insert into public.stock_transfer_details (transfer_id, item_id, from_location_id, to_location_id, quantity)
    values (v_id, v_item, v_from, v_to, v_qty);

    for c in select * from private.consume_stock('TRANSFER_OUT', p_date, v_item, v_from, 'layak_pakai', v_qty,
                                                 'stock_transfers', v_id, v_no,
                                                 'Pindah ke ' || (select code from public.storage_locations where id = v_to) || ': ' || trim(p_reason))
    loop
      perform private.stock_in('TRANSFER_IN', p_date, v_item, v_to, 'layak_pakai', c.qty, c.unit_cost, c.acquired_at,
                               c.expiry_date, null, c.batch_id, 'stock_transfers', v_id, v_no,
                               'Pindah dari ' || (select code from public.storage_locations where id = v_from) || ': ' || trim(p_reason));
    end loop;

    select coalesce(sum(quantity), 0), coalesce(sum(total_value), 0) into v_after, v_after_val
      from public.stock_balances where item_id = v_item;
    if v_after <> v_before or v_after_val <> v_before_val then
      raise exception 'Perpindahan dibatalkan: total saldo berubah (% -> %).', v_before, v_after using errcode = 'P0001';
    end if;
  end loop;
  perform private.end_rpc();
  return v_id;
end $$;

-- ---------------------------------------------------------------------
-- KARTU STOK
-- ---------------------------------------------------------------------
create or replace function public.rpc_stock_card(p_item uuid, p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_open_qty numeric; v_open_val numeric;
  v_rows jsonb;
  v_in numeric; v_out numeric; v_vin numeric; v_vout numeric;
begin
  perform private.require_active_user();
  if not private.has_any_role(private.stock_reader_roles() || array['ATS']) then
    raise exception 'Anda tidak berwenang melihat kartu stok.' using errcode = '42501';
  end if;
  if p_from > p_to then
    raise exception 'Tanggal awal tidak boleh setelah tanggal akhir.' using errcode = '22023';
  end if;

  -- Saldo awal periode = seluruh mutasi sebelum tanggal awal.
  select coalesce(sum(m.qty_in - m.qty_out), 0), coalesce(sum(m.value_in - m.value_out), 0)
    into v_open_qty, v_open_val
    from public.stock_movements m where m.item_id = p_item and m.movement_date < p_from;

  -- Saldo berjalan dihitung menurut urutan TANGGAL (bukan urutan pencatatan).
  with r as (
    select m.*, s.code as location_code,
           v_open_qty + sum(m.qty_in - m.qty_out) over w as run_qty,
           v_open_val + sum(m.value_in - m.value_out) over w as run_val
      from public.stock_movements m join public.storage_locations s on s.id = m.location_id
     where m.item_id = p_item and m.movement_date between p_from and p_to
    window w as (order by m.movement_date, m.id rows between unbounded preceding and current row)
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'date', r.movement_date, 'ref_no', r.ref_no, 'ref_table', r.ref_table, 'ref_id', r.ref_id,
           'type', r.movement_type, 'description', r.description,
           'location', r.location_code, 'qty_in', r.qty_in, 'qty_out', r.qty_out, 'unit_cost', r.unit_cost,
           'value', r.value_in + r.value_out, 'balance_qty', r.run_qty, 'balance_value', r.run_val)
           order by r.movement_date, r.id), '[]'::jsonb),
         coalesce(sum(r.qty_in) filter (where r.movement_type <> 'TRANSFER_IN'), 0),
         coalesce(sum(r.qty_out) filter (where r.movement_type <> 'TRANSFER_OUT'), 0),
         coalesce(sum(r.value_in) filter (where r.movement_type <> 'TRANSFER_IN'), 0),
         coalesce(sum(r.value_out) filter (where r.movement_type <> 'TRANSFER_OUT'), 0)
    into v_rows, v_in, v_out, v_vin, v_vout
    from r;

  return jsonb_build_object(
    'opening_qty', v_open_qty, 'opening_value', v_open_val,
    'total_in', v_in, 'total_out', v_out, 'total_in_value', v_vin, 'total_out_value', v_vout,
    'closing_qty', v_open_qty + v_in - v_out, 'closing_value', v_open_val + v_vin - v_vout,
    'rows', v_rows);
end $$;

-- Pemeriksaan konsistensi: mutasi = batch = saldo untuk setiap barang.
create or replace function public.rpc_verify_stock()
returns table (item_id uuid, item_code text, movements_qty numeric, batches_qty numeric, balances_qty numeric)
language plpgsql stable security definer set search_path = '' as $$
begin
  perform private.require_active_user();
  if not private.has_any_role(array['PGB','KPA','PWS','AKT','AUD']) then
    raise exception 'Anda tidak berwenang.' using errcode = '42501';
  end if;
  return query
  with m as (select sm.item_id, sum(sm.qty_in - sm.qty_out) q from public.stock_movements sm group by sm.item_id),
       b as (select sb.item_id, sum(sb.qty_remaining) q from public.stock_batches sb group by sb.item_id),
       s as (select sl.item_id, sum(sl.quantity) q from public.stock_balances sl group by sl.item_id)
  select i.id, i.code, coalesce(m.q, 0), coalesce(b.q, 0), coalesce(s.q, 0)
    from public.items i left join m on m.item_id = i.id left join b on b.item_id = i.id left join s on s.item_id = i.id
   where coalesce(m.q, 0) <> coalesce(b.q, 0) or coalesce(b.q, 0) <> coalesce(s.q, 0);
end $$;

-- ---------------------------------------------------------------------
-- Ringkasan saldo per barang (untuk halaman Penyimpanan)
-- ---------------------------------------------------------------------
create or replace view public.v_stock_summary with (security_invoker = true) as
select i.id as item_id, i.code, i.name, i.category_id, i.unit_id, i.min_stock, i.safety_stock, i.max_stock,
       i.has_expiry, i.is_active,
       coalesce(sum(b.quantity) filter (where b.condition = 'layak_pakai'), 0) as qty_good,
       coalesce(sum(b.quantity) filter (where b.condition <> 'layak_pakai'), 0) as qty_other,
       coalesce(sum(b.reserved_qty), 0) as qty_reserved,
       coalesce(sum(b.total_value), 0) as total_value,
       max(b.last_movement_at) as last_movement_at
  from public.items i
  left join public.stock_balances b on b.item_id = i.id
 group by i.id;

-- ---------------------------------------------------------------------
-- RLS & hak akses
-- ---------------------------------------------------------------------
alter table public.receipts               enable row level security;
alter table public.receipt_details        enable row level security;
alter table public.stock_batches          enable row level security;
alter table public.stock_balances         enable row level security;
alter table public.stock_movements        enable row level security;
alter table public.stock_transfers        enable row level security;
alter table public.stock_transfer_details enable row level security;
alter table public.approvals              enable row level security;
alter table public.status_histories       enable row level security;
alter table public.attachments            enable row level security;

revoke all on public.receipts, public.receipt_details, public.stock_batches, public.stock_balances,
              public.stock_movements, public.stock_transfers, public.stock_transfer_details,
              public.approvals, public.status_histories, public.attachments, public.v_stock_summary
  from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;

grant select, insert, update         on public.receipts        to authenticated;
grant select, insert, update, delete on public.receipt_details to authenticated;
grant select on public.stock_batches, public.stock_balances, public.stock_movements,
                public.stock_transfers, public.stock_transfer_details,
                public.approvals, public.status_histories, public.v_stock_summary to authenticated;
grant select, insert on public.attachments to authenticated;

-- Penerimaan
drop policy if exists receipts_select on public.receipts;
create policy receipts_select on public.receipts for select to authenticated
  using ((select private.current_user_is_active()) and (select private.has_any_role(private.receipt_reader_roles())));
drop policy if exists receipts_insert on public.receipts;
create policy receipts_insert on public.receipts for insert to authenticated
  with check ((select private.has_any_role(array['PGB','PPB'])) and (select private.current_user_is_active()));
drop policy if exists receipts_update on public.receipts;
create policy receipts_update on public.receipts for update to authenticated
  using (created_by = (select auth.uid()) and status = 'draft')
  with check (created_by = (select auth.uid()));

drop policy if exists receipt_details_select on public.receipt_details;
create policy receipt_details_select on public.receipt_details for select to authenticated
  using ((select private.current_user_is_active()) and (select private.has_any_role(private.receipt_reader_roles())));
drop policy if exists receipt_details_insert on public.receipt_details;
create policy receipt_details_insert on public.receipt_details for insert to authenticated
  with check (exists (select 1 from public.receipts r where r.id = receipt_id and r.created_by = (select auth.uid()) and r.status = 'draft'));
drop policy if exists receipt_details_update on public.receipt_details;
create policy receipt_details_update on public.receipt_details for update to authenticated
  using (exists (select 1 from public.receipts r where r.id = receipt_id and r.created_by = (select auth.uid()) and r.status = 'draft'))
  with check (exists (select 1 from public.receipts r where r.id = receipt_id and r.created_by = (select auth.uid()) and r.status = 'draft'));
drop policy if exists receipt_details_delete on public.receipt_details;
create policy receipt_details_delete on public.receipt_details for delete to authenticated
  using (exists (select 1 from public.receipts r where r.id = receipt_id and r.created_by = (select auth.uid()) and r.status = 'draft'));

-- Stok (hanya baca)
do $$
declare t text;
begin
  foreach t in array array['stock_batches','stock_balances','stock_movements','stock_transfers','stock_transfer_details'] loop
    execute format('drop policy if exists %I on public.%I', t || '_select', t);
    execute format('create policy %I on public.%I for select to authenticated
                    using ((select private.current_user_is_active()) and (select private.has_any_role(private.stock_reader_roles())))',
                   t || '_select', t);
  end loop;
end $$;

-- Persetujuan, riwayat, lampiran
drop policy if exists approvals_select on public.approvals;
create policy approvals_select on public.approvals for select to authenticated
  using (private.can_read_ref(ref_table, ref_id));
drop policy if exists status_histories_select on public.status_histories;
create policy status_histories_select on public.status_histories for select to authenticated
  using (private.can_read_ref(ref_table, ref_id));
drop policy if exists attachments_select on public.attachments;
create policy attachments_select on public.attachments for select to authenticated
  using (private.can_read_ref(ref_table, ref_id));
drop policy if exists attachments_insert on public.attachments;
create policy attachments_insert on public.attachments for insert to authenticated
  with check (private.can_attach(ref_table, ref_id)
              and storage_path like ref_table || '/' || ref_id::text || '/%');

create or replace function private.tg_attachment_meta()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  new.uploaded_by := auth.uid();
  new.uploaded_at := now();
  return new;
end $$;
revoke all on function private.tg_attachment_meta() from public;
drop trigger if exists trg_attachment_meta on public.attachments;
create trigger trg_attachment_meta before insert on public.attachments
  for each row execute function private.tg_attachment_meta();

-- ---------------------------------------------------------------------
-- Penyimpanan dokumen (Supabase Storage, bucket privat)
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('documents', 'documents', false, 10485760,
        array['application/pdf','image/jpeg','image/png','image/webp'])
on conflict (id) do nothing;

drop policy if exists sipp_documents_insert on storage.objects;
create policy sipp_documents_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'documents' and private.can_attach_path(name));
drop policy if exists sipp_documents_select on storage.objects;
create policy sipp_documents_select on storage.objects for select to authenticated
  using (bucket_id = 'documents' and private.can_read_path(name));

-- ---------------------------------------------------------------------
-- Hak eksekusi
-- ---------------------------------------------------------------------
do $$
declare f text;
begin
  foreach f in array array[
    'private.begin_rpc(text)','private.end_rpc()','private.require_active_user()','private.lock_item(uuid)',
    'private.refresh_balance(uuid,uuid,text)','private.assert_not_backdated(uuid,date)',
    'private.record_movement(text,date,uuid,uuid,uuid,text,numeric,numeric,numeric,text,uuid,text,text)',
    'private.stock_in(text,date,uuid,uuid,text,numeric,numeric,date,date,uuid,uuid,text,uuid,text,text)',
    'private.consume_stock(text,date,uuid,uuid,text,numeric,text,uuid,text,text)',
    'private.receipt_for_update(uuid)','private.receipt_expect(public.receipts,text[])'] loop
    execute format('revoke all on function %s from public', f);
  end loop;
  foreach f in array array[
    'private.stock_reader_roles()','private.receipt_reader_roles()','private.can_read_ref(text,uuid)',
    'private.can_attach(text,uuid)','private.path_ref(text)','private.can_attach_path(text)',
    'private.can_read_path(text)','private.receipt_status_label(text)'] loop
    execute format('revoke all on function %s from public', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
  foreach f in array array[
    'public.rpc_receipt_submit(uuid)','public.rpc_receipt_start_inspection(uuid)',
    'public.rpc_receipt_record_inspection(uuid,jsonb,text,text)','public.rpc_receipt_vendor_followup(uuid,text)',
    'public.rpc_receipt_decide(uuid,text,text)','public.rpc_receipt_finalize(uuid,jsonb)',
    'public.rpc_receipt_verify_accounting(uuid,text)','public.rpc_receipt_cancel(uuid,text)',
    'public.rpc_transfer_stock(date,text,jsonb)','public.rpc_stock_card(uuid,date,date)','public.rpc_verify_stock()'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- Dashboard: indikator persediaan untuk fungsi yang berhak melihat saldo
-- ---------------------------------------------------------------------
create or replace function public.rpc_dashboard_overview()
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_roles   text[] := private.my_role_codes();
  v_result  jsonb;
  v_today   date := (now() at time zone 'Asia/Jakarta')::date;
begin
  if auth.uid() is null or not private.current_user_is_active() then
    raise exception 'Sesi tidak valid atau akun nonaktif.' using errcode = '42501';
  end if;

  v_result := jsonb_build_object(
    'roles', to_jsonb(v_roles),
    'unread_notifications',
      (select count(*) from public.notifications n where n.user_id = auth.uid() and not n.is_read),
    'active_units', (select count(*) from public.organizational_units where is_active),
    'active_items', (select count(*) from public.items where is_active),
    'mfa_required', private.role_requires_mfa('SA') and 'SA' = any(v_roles),
    'mfa_satisfied', private.mfa_satisfied(),
    'generated_at', now());

  if v_roles && array['SA','PGB','KPA','PWS'] then
    v_result := v_result || jsonb_build_object(
      'proposed_items', (select count(*) from public.items where not is_active and activated_at is null));
  end if;

  if v_roles && private.stock_reader_roles() then
    v_result := v_result || jsonb_build_object(
      'stock', jsonb_build_object(
        'total_value', (select coalesce(sum(total_value), 0) from public.stock_balances),
        'items_in_stock', (select count(distinct item_id) from public.stock_balances where quantity > 0),
        'below_min', (select count(*) from public.v_stock_summary s where s.is_active and s.qty_good <= s.min_stock),
        'above_max', (select count(*) from public.v_stock_summary s where s.max_stock is not null and s.qty_good > s.max_stock),
        'expiring', (select count(*) from public.stock_batches b where b.qty_remaining > 0 and b.expiry_date is not null
                       and b.expiry_date <= v_today + coalesce((select (value #>> '{}')::int from public.app_settings where key = 'expiry_warning_days'), 90)),
        'receipts_month', (select count(*) from public.receipts r where r.status in ('diterima_disimpan','selesai')
                             and date_trunc('month', r.receipt_date) = date_trunc('month', v_today)),
        'receipts_open', (select count(*) from public.receipts r where r.status not in ('selesai','dibatalkan'))));
  end if;

  if v_roles && array['SA','KPA','PWS','AUD'] then
    v_result := v_result || jsonb_build_object(
      'active_users',   (select count(*) from public.profiles where is_active),
      'inactive_users', (select count(*) from public.profiles where not is_active),
      'users_without_role',
        (select count(*) from public.profiles p
          where p.is_active and not exists
            (select 1 from public.user_roles ur where ur.user_id = p.id and ur.is_active)),
      'audit_events_today',
        (select count(*) from public.audit_logs
          where occurred_at >= (date_trunc('day', now() at time zone 'Asia/Jakarta') at time zone 'Asia/Jakarta')),
      'recent_activity',
        coalesce((select jsonb_agg(x order by x.occurred_at desc) from (
            select a.occurred_at, a.user_name, a.action, a.table_name
              from public.audit_logs a order by a.id desc limit 10) x), '[]'::jsonb));
  end if;

  return v_result;
end;
$$;

-- >>>>> 20261121001100_alur_penerimaan_tanpa_kpa.sql
-- =====================================================================
-- SIPP — Migration 0011: Perubahan keputusan pengguna (21-11-2026)
-- 1. Role KPA DIHAPUS dari aplikasi: dinonaktifkan (riwayat tetap utuh),
--    tidak dapat ditetapkan lagi; tugas persetujuannya dialihkan ke
--    Pejabat Pengawas (PWS) dan tetap dapat diubah di Pengaturan.
-- 2. Alur penerimaan:
--    * pencatatan hanya oleh Petugas Penerima Barang (PPB);
--    * pemeriksaan SEKALIGUS pengesahan oleh PPK (pembelian) atau
--      Pejabat Pengawas (hibah, transfer, perolehan lain, saldo awal);
--    * penyimpanan ke gudang tetap oleh Pengurus Barang.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Role tidak aktif
-- ---------------------------------------------------------------------
alter table public.roles add column if not exists is_active boolean not null default true;
update public.roles set is_active = false where code = 'KPA';

create or replace function private.my_role_codes()
returns text[]
language sql stable security definer set search_path = ''
as $$
  select coalesce(array_agg(distinct r.code), '{}')
    from public.user_roles ur
    join public.roles r    on r.id = ur.role_id
    join public.profiles p on p.id = ur.user_id
   where ur.user_id = auth.uid()
     and ur.is_active
     and r.is_active
     and p.is_active
     and current_date >= ur.valid_from
     and (ur.valid_until is null or current_date <= ur.valid_until);
$$;

-- Penetapan role: tolak role yang sudah tidak digunakan.
create or replace function private.tg_user_roles_guard()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_code        text;
  v_role_active boolean;
  v_other_codes text[];
  v_active_sa   integer;
  c_conflict_sa constant text[] := array['KPA','PWS','PGB','ATS','AKT'];
begin
  select code, is_active into v_code, v_role_active from public.roles where id = new.role_id;

  if auth.uid() is not null and new.user_id = auth.uid() then
    raise exception 'Anda tidak dapat mengubah role Anda sendiri.' using errcode = '42501';
  end if;

  if tg_op = 'UPDATE' and (new.user_id <> old.user_id or new.role_id <> old.role_id) then
    raise exception 'Pengguna dan role pada penugasan tidak dapat diganti; nonaktifkan lalu buat penugasan baru.'
      using errcode = '22023';
  end if;

  if new.is_active and not v_role_active then
    raise exception 'Role % sudah tidak digunakan dalam aplikasi.', v_code using errcode = '23514';
  end if;

  if v_code in ('ATS','PGW') and new.unit_id is null then
    raise exception 'Role % wajib memiliki unit kerja.', v_code using errcode = '23514';
  end if;
  if v_code not in ('ATS','PGW') and new.unit_id is not null then
    raise exception 'Role % berlaku untuk seluruh satuan kerja; unit kerja harus dikosongkan.', v_code
      using errcode = '23514';
  end if;

  if tg_op = 'UPDATE' and v_code = 'SA' and old.is_active and not new.is_active then
    select count(*) into v_active_sa
      from public.user_roles ur join public.roles r on r.id = ur.role_id
     where r.code = 'SA' and ur.is_active and ur.id <> new.id;
    if v_active_sa = 0 then
      raise exception 'Minimal harus ada satu Super Admin aktif.' using errcode = '23514';
    end if;
  end if;

  if not new.is_active then
    return new;
  end if;

  select coalesce(array_agg(r.code), '{}') into v_other_codes
    from public.user_roles ur join public.roles r on r.id = ur.role_id
   where ur.user_id = new.user_id and ur.is_active and r.is_active and ur.id <> new.id;

  if (v_code = 'AUD' and cardinality(v_other_codes) > 0) or (v_code <> 'AUD' and 'AUD' = any(v_other_codes)) then
    raise exception 'Auditor/APIP tidak boleh merangkap role lain (pemisahan fungsi).' using errcode = '23514';
  end if;
  if (v_code = 'SA' and v_other_codes && c_conflict_sa)
     or (v_code = any(c_conflict_sa) and 'SA' = any(v_other_codes)) then
    raise exception 'Super Admin tidak boleh merangkap role PWS, PGB, ATS, atau AKT (pemisahan fungsi).'
      using errcode = '23514';
  end if;
  return new;
end;
$$;

-- Nonaktifkan seluruh penugasan KPA (konteks sistem; tercatat di audit trail).
update public.user_roles ur set is_active = false
  from public.roles r
 where r.id = ur.role_id and r.code = 'KPA' and ur.is_active;

-- Alihkan tugas persetujuan KPA ke Pejabat Pengawas.
update public.approval_settings a
   set approver_role_code = 'PWS',
       description = coalesce(a.description, '') || ' (dialihkan dari KPA)'
 where a.approver_role_code = 'KPA'
   and not exists (select 1 from public.approval_settings b
                    where b.transaction_type = a.transaction_type and b.level = a.level and b.approver_role_code = 'PWS');
update public.approval_settings set is_active = false where approver_role_code = 'KPA';

update public.approval_settings
   set description = 'Pemeriksaan & pengesahan penerimaan pembelian'
 where transaction_type = 'receipt' and approver_role_code = 'PPK';
update public.approval_settings
   set description = 'Pemeriksaan & pengesahan penerimaan hibah, transfer, perolehan lain, dan saldo awal'
 where transaction_type = 'receipt' and approver_role_code = 'PWS';

-- ---------------------------------------------------------------------
-- 2. Alur penerimaan baru
-- ---------------------------------------------------------------------
-- Role pemeriksa (sekaligus pengesah) yang dimiliki pengguna untuk sumber tertentu.
create or replace function private.receipt_inspector_role(p_source text)
returns text language sql stable security definer set search_path = '' as $$
  select a.approver_role_code
    from public.approval_settings a
   where a.transaction_type = 'receipt' and a.is_active
     and (a.applies_when = '{}'::jsonb or (a.applies_when -> 'source_type') ? p_source)
     and private.has_role(a.approver_role_code)
   order by a.level limit 1;
$$;
revoke all on function private.receipt_inspector_role(text) from public;
grant execute on function private.receipt_inspector_role(text) to authenticated;

-- Pencatatan hanya oleh Petugas Penerima Barang.
drop policy if exists receipts_insert on public.receipts;
create policy receipts_insert on public.receipts for insert to authenticated
  with check ((select private.has_role('PPB')) and (select private.current_user_is_active()));

-- Lampiran: pencatat & pemeriksa, sebelum pengesahan.
create or replace function private.can_attach(p_table text, p_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select private.current_user_is_active() and case p_table
    when 'receipts' then private.has_any_role(array['PPB','PPK','PWS'])
      and exists (select 1 from public.receipts r where r.id = p_id and r.status in
        ('draft','menunggu_pemeriksaan','dalam_pemeriksaan','tidak_sesuai','menunggu_tindak_lanjut_penyedia'))
    when 'stock_transfers' then private.has_role('PGB')
    else false end;
$$;

-- Pengesahan terpisah tidak dipakai lagi.
drop function if exists public.rpc_receipt_decide(uuid, text, text);

create or replace function public.rpc_receipt_start_inspection(p_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare r public.receipts; v_uid uuid := private.require_active_user();
begin
  r := private.receipt_for_update(p_id);
  if private.receipt_inspector_role(r.source_type) is null then
    raise exception 'Anda tidak berwenang memeriksa penerimaan ini (pembelian: PPK; sumber lain: Pejabat Pengawas).'
      using errcode = '42501';
  end if;
  perform private.receipt_expect(r, array['menunggu_pemeriksaan','menunggu_tindak_lanjut_penyedia']);
  if r.created_by = v_uid then
    raise exception 'Pencatat penerimaan tidak boleh memeriksa penerimaannya sendiri (pemisahan fungsi).' using errcode = '42501';
  end if;
  perform private.begin_rpc('Pemeriksaan dimulai');
  update public.receipts set status = 'dalam_pemeriksaan', inspector_id = v_uid where id = p_id;
  perform private.end_rpc();
end $$;

-- Pemeriksaan sekaligus pengesahan.
-- p_decision: 'lanjut' = sahkan barang yang diterima baik | 'tindak_lanjut' = ketidaksesuaian
create or replace function public.rpc_receipt_record_inspection(p_id uuid, p_lines jsonb, p_notes text, p_decision text)
returns void language plpgsql security definer set search_path = '' as $$
declare
  r public.receipts;
  v_uid uuid := private.require_active_user();
  v_role text;
  l jsonb;
  d record;
  v_acc numeric; v_rej numeric; v_rec numeric; v_res text; v_exp date;
  v_issue boolean := false;
  v_total_acc numeric := 0;
  v_missing integer;
  v_docs text[] := '{}';
begin
  r := private.receipt_for_update(p_id);
  perform private.receipt_expect(r, array['dalam_pemeriksaan']);
  if r.inspector_id is distinct from v_uid then
    raise exception 'Hanya pemeriksa yang memulai pemeriksaan yang dapat mencatat hasilnya.' using errcode = '42501';
  end if;
  v_role := private.receipt_inspector_role(r.source_type);
  if v_role is null then
    raise exception 'Anda tidak lagi berwenang memeriksa penerimaan ini.' using errcode = '42501';
  end if;
  if p_decision not in ('lanjut','tindak_lanjut') then
    raise exception 'Keputusan pemeriksaan tidak dikenal.' using errcode = '22023';
  end if;

  perform private.begin_rpc(case p_decision when 'lanjut' then 'Diperiksa dan disahkan'
                                            else 'Ditemukan ketidaksesuaian' end);
  for l in select * from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) loop
    select d2.*, i.has_expiry, i.code into d
      from public.receipt_details d2 join public.items i on i.id = d2.item_id
     where d2.id = (l ->> 'detail_id')::uuid and d2.receipt_id = p_id;
    if not found then
      raise exception 'Rincian penerimaan tidak dikenal.' using errcode = 'P0002';
    end if;
    v_rec := coalesce((l ->> 'qty_received')::numeric, d.qty_received);
    v_acc := coalesce((l ->> 'qty_accepted')::numeric, 0);
    v_rej := coalesce((l ->> 'qty_rejected')::numeric, 0);
    v_res := l ->> 'result';
    v_exp := nullif(l ->> 'expiry_date', '')::date;
    if v_rec <= 0 or v_acc < 0 or v_rej < 0 or v_acc + v_rej <> v_rec then
      raise exception 'Barang %: jumlah diterima baik + ditolak harus sama dengan jumlah yang datang.', d.code using errcode = '22023';
    end if;
    if v_res is null or v_res not in ('sesuai','tidak_sesuai_jumlah','tidak_sesuai_spesifikasi','rusak') then
      raise exception 'Barang %: pilih hasil pemeriksaan.', d.code using errcode = '22023';
    end if;
    if v_res = 'sesuai' and v_rej > 0 then
      raise exception 'Barang %: hasil "sesuai" tidak boleh memiliki jumlah ditolak.', d.code using errcode = '22023';
    end if;
    if d.has_expiry and v_acc > 0 and v_exp is null then
      raise exception 'Barang % wajib diisi tanggal kedaluwarsa.', d.code using errcode = '22023';
    end if;
    if v_res <> 'sesuai' or v_rej > 0 or (d.qty_ordered is not null and v_rec <> d.qty_ordered) then
      v_issue := true;
    end if;
    update public.receipt_details
       set qty_received = v_rec, qty_accepted = v_acc, qty_rejected = v_rej,
           inspection_result = v_res, inspection_notes = nullif(trim(l ->> 'notes'), ''), expiry_date = v_exp
     where id = d.id;
  end loop;

  select count(*) into v_missing from public.receipt_details where receipt_id = p_id and inspection_result is null;
  if v_missing > 0 then
    raise exception 'Semua barang harus diperiksa (% belum).', v_missing using errcode = 'P0001';
  end if;
  select coalesce(sum(qty_accepted), 0) into v_total_acc from public.receipt_details where receipt_id = p_id;

  if p_decision = 'tindak_lanjut' then
    if not v_issue then
      raise exception 'Tidak ada ketidaksesuaian yang dicatat.' using errcode = 'P0001';
    end if;
    update public.receipts
       set status = 'tidak_sesuai', inspected_at = now(), inspection_notes = nullif(trim(coalesce(p_notes, '')), '')
     where id = p_id;
    perform private.end_rpc();
    return;
  end if;

  if v_total_acc <= 0 then
    raise exception 'Tidak ada barang yang diterima baik; pilih catat ketidaksesuaian.' using errcode = 'P0001';
  end if;

  -- Dokumen wajib sebelum pengesahan.
  if r.source_type = 'saldo_awal' then
    if not exists (select 1 from public.attachments where ref_table = 'receipts' and ref_id = p_id and doc_type = 'ba_saldo_awal') then
      v_docs := v_docs || 'Berita Acara Saldo Awal';
    end if;
  else
    if not exists (select 1 from public.attachments where ref_table = 'receipts' and ref_id = p_id and doc_type = 'ba_pemeriksaan') then
      v_docs := v_docs || 'Berita Acara Pemeriksaan';
    end if;
    if r.source_type = 'pembelian' and not exists (
         select 1 from public.attachments where ref_table = 'receipts' and ref_id = p_id and doc_type in ('surat_jalan','faktur')) then
      v_docs := v_docs || 'Surat Jalan atau Faktur';
    end if;
  end if;
  if cardinality(v_docs) > 0 then
    raise exception 'Dokumen wajib belum diunggah: %.', array_to_string(v_docs, ', ') using errcode = 'P0001';
  end if;

  insert into public.approvals (ref_table, ref_id, level, required_role_code, approver_id, decision, notes)
  values ('receipts', p_id, 1, v_role, v_uid, 'approved', nullif(trim(coalesce(p_notes, '')), ''));
  update public.receipts
     set status = 'disetujui', inspected_at = now(), approved_by = v_uid, approved_at = now(),
         inspection_notes = nullif(trim(coalesce(p_notes, '')), ''),
         total_value = (select coalesce(round(sum(qty_accepted * unit_cost), 2), 0) from public.receipt_details where receipt_id = p_id)
   where id = p_id;
  perform private.end_rpc();
end $$;

create or replace function public.rpc_receipt_vendor_followup(p_id uuid, p_comment text)
returns void language plpgsql security definer set search_path = '' as $$
declare r public.receipts;
begin
  perform private.require_active_user();
  if not private.has_any_role(array['PPK','PWS','PPB']) then
    raise exception 'Hanya PPK, Pejabat Pengawas, atau Petugas Penerima Barang yang dapat meneruskan tindak lanjut.' using errcode = '42501';
  end if;
  r := private.receipt_for_update(p_id);
  perform private.receipt_expect(r, array['tidak_sesuai']);
  if length(trim(coalesce(p_comment, ''))) < 5 then
    raise exception 'Tuliskan tindak lanjut yang diminta (minimal 5 karakter).' using errcode = '22023';
  end if;
  perform private.begin_rpc(p_comment);
  update public.receipts set status = 'menunggu_tindak_lanjut_penyedia' where id = p_id;
  perform private.end_rpc();
end $$;

create or replace function public.rpc_receipt_cancel(p_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare r public.receipts; v_uid uuid := private.require_active_user();
begin
  r := private.receipt_for_update(p_id);
  perform private.receipt_expect(r, array['draft','menunggu_pemeriksaan','tidak_sesuai','menunggu_tindak_lanjut_penyedia']);
  if r.created_by is distinct from v_uid then
    raise exception 'Hanya pencatat penerimaan yang dapat membatalkannya.' using errcode = '42501';
  end if;
  if length(trim(coalesce(p_reason, ''))) < 5 then
    raise exception 'Alasan pembatalan wajib diisi (minimal 5 karakter).' using errcode = '22023';
  end if;
  perform private.begin_rpc('Dibatalkan: ' || p_reason);
  update public.receipts set status = 'dibatalkan', cancel_reason = p_reason where id = p_id;
  perform private.end_rpc();
end $$;

-- Penerimaan yang sedang diperiksa/menunggu pengesahan dengan aturan lama
-- dikembalikan ke antrean pemeriksaan agar diperiksa ulang oleh PPK/PWS.
do $$
begin
  perform private.begin_rpc('Dikembalikan ke antrean pemeriksaan karena perubahan alur (pemeriksa: PPK / Pejabat Pengawas)');
  -- Hanya yang diperiksa dengan aturan lama: status "menunggu pengesahan", atau
  -- sedang diperiksa oleh orang yang bukan PPK/Pejabat Pengawas. Aman dijalankan ulang.
  update public.receipts r
     set status = 'menunggu_pemeriksaan', inspector_id = null, inspected_at = null
   where r.status = 'menunggu_pengesahan'
      or (r.status = 'dalam_pemeriksaan' and not exists (
            select 1 from public.user_roles ur join public.roles ro on ro.id = ur.role_id
             where ur.user_id = r.inspector_id and ur.is_active and ro.code in ('PPK','PWS')));
  perform private.end_rpc();
end $$;

-- >>>>> 20261121001200_akuntansi_hanya_rekonsiliasi.sql
-- =====================================================================
-- SIPP — Migration 0012: Petugas Akuntansi hanya untuk Rekonsiliasi
-- Keputusan pemilik produk 21-11-2026.
-- * Role AKT tetap ada, tetapi hanya berperan menyusun Rekonsiliasi:
--   tidak terlibat penerimaan; tetap dapat membaca saldo & nilai
--   persediaan (bahan rekonsiliasi).
-- * Langkah "verifikasi akuntansi" pada penerimaan ditiadakan: penerimaan
--   SELESAI saat Pengurus Barang menyimpannya ke gudang.
-- Aman dijalankan ulang.
-- =====================================================================

-- Pastikan role AKT aktif (memulihkan bila versi sebelumnya sempat menonaktifkannya).
update public.roles set is_active = true, description = 'Menyusun rekonsiliasi persediaan' where code = 'AKT';

-- AKT tidak lagi membaca data penerimaan.
create or replace function private.receipt_reader_roles()
returns text[] language sql immutable set search_path = '' as $$
  select array['PGB','PPB','PPK','PWS','AUD'];
$$;

create or replace function public.rpc_receipt_finalize(p_id uuid, p_locations jsonb default '{}'::jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare
  r public.receipts;
  v_uid uuid := private.require_active_user();
  d record;
  v_loc uuid;
  v_type text;
  v_desc text;
begin
  if not private.has_role('PGB') then
    raise exception 'Hanya Pengurus Barang yang dapat menyimpan barang ke gudang.' using errcode = '42501';
  end if;
  r := private.receipt_for_update(p_id);
  perform private.receipt_expect(r, array['disetujui']);

  v_type := case when r.source_type = 'saldo_awal' then 'OPENING_BALANCE' else 'RECEIPT_IN' end;
  v_desc := case r.source_type
    when 'saldo_awal' then 'Saldo awal'
    when 'pembelian' then 'Pembelian dari ' || coalesce((select name from public.suppliers where id = r.supplier_id), '-')
    when 'hibah' then 'Hibah: ' || coalesce(r.source_description, '-')
    when 'transfer' then 'Transfer masuk: ' || coalesce(r.source_description, '-')
    else 'Perolehan lain: ' || coalesce(r.source_description, '-') end;

  perform private.begin_rpc('Barang disimpan ke gudang, saldo bertambah; penerimaan selesai');
  for d in
    select * from public.receipt_details where receipt_id = p_id and qty_accepted > 0 order by item_id, line_no
  loop
    v_loc := coalesce(nullif(p_locations ->> d.id::text, '')::uuid, d.location_id);
    if v_loc is null then
      raise exception 'Pilih lokasi penyimpanan untuk semua barang yang diterima.' using errcode = 'P0001';
    end if;
    if not exists (select 1 from public.storage_locations where id = v_loc and is_active and warehouse_id = r.warehouse_id) then
      raise exception 'Lokasi penyimpanan harus aktif dan berada di gudang penerimaan.' using errcode = 'P0001';
    end if;
    update public.receipt_details set location_id = v_loc where id = d.id;
    perform private.lock_item(d.item_id);
    perform private.stock_in(v_type, r.receipt_date, d.item_id, v_loc, 'layak_pakai', d.qty_accepted, d.unit_cost,
                             r.receipt_date, d.expiry_date, d.id, null, 'receipts', r.id, r.receipt_no, v_desc);
  end loop;
  update public.receipts set status = 'selesai', finalized_by = v_uid, finalized_at = now() where id = p_id;
  perform private.end_rpc();
end $$;

drop function if exists public.rpc_receipt_verify_accounting(uuid, text);

-- Penerimaan yang menunggu verifikasi akuntansi dengan aturan lama -> selesai.
do $$
begin
  perform private.begin_rpc('Selesai: langkah verifikasi akuntansi ditiadakan');
  update public.receipts set status = 'selesai' where status = 'diterima_disimpan';
  perform private.end_rpc();
end $$;

-- =====================================================================
-- Selesai. Bila muncul "Success. No rows returned", pemasangan berhasil.
-- =====================================================================
