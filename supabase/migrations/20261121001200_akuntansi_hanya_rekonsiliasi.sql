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
