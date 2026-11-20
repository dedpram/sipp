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
