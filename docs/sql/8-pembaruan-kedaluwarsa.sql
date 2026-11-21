-- =====================================================================
-- SIPP — PEMBARUAN: TANGGAL KEDALUWARSA DIISI PETUGAS PENERIMA BARANG
-- PPK / Pejabat Pengawas hanya memeriksa dan mengesahkan tanggal tersebut.
-- Penerimaan yang sudah diajukan tanpa tanggal kedaluwarsa otomatis kembali
-- ke Draf agar dilengkapi Petugas Penerima Barang.
-- Cara pakai: Supabase Dashboard > SQL Editor > New query (tab KOSONG) >
--             tempel SELURUH isi file ini > klik RUN.
-- Aman dijalankan ulang; tidak menghapus data.
-- =====================================================================

-- >>>>> 20261121001400_kedaluwarsa_oleh_penerima.sql
-- =====================================================================
-- SIPP — Migration 0014: Tanggal kedaluwarsa diisi Petugas Penerima Barang
-- Keputusan pemilik produk 21-11-2026: tanggal kedaluwarsa wajib diisi
-- Petugas Penerima Barang saat mencatat rincian barang. PPK / Pejabat
-- Pengawas hanya memeriksa dan mengesahkan tanggal tersebut (tidak dapat
-- mengubahnya). Bila tanggal salah, pemeriksa mencatat ketidaksesuaian dan
-- Petugas Penerima Barang memperbaikinya sebelum diperiksa ulang.
-- Aman dijalankan ulang; tidak menghapus data.
-- =====================================================================

-- 1. Pengajuan: barang ber-kedaluwarsa wajib sudah diisi tanggalnya.
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
  -- Tanggal kedaluwarsa diisi Petugas Penerima Barang (pencatat), bukan pemeriksa.
  select string_agg(i.code, ', ' order by d.line_no) into v_bad
    from public.receipt_details d join public.items i on i.id = d.item_id
   where d.receipt_id = p_id and i.has_expiry and d.expiry_date is null;
  if v_bad is not null then
    raise exception 'Barang % wajib diisi tanggal kedaluwarsa sebelum diajukan (ubah rincian barang).', v_bad using errcode = 'P0001';
  end if;

  perform private.begin_rpc('Diajukan untuk pemeriksaan');
  update public.receipts
     set status = 'menunggu_pemeriksaan',
         total_value = (select coalesce(round(sum(qty_received * unit_cost), 2), 0) from public.receipt_details where receipt_id = p_id)
   where id = p_id;
  perform private.end_rpc();
end $$;

-- 2. Pemeriksaan: tanggal kedaluwarsa tidak lagi diisi/diubah pemeriksa.
create or replace function public.rpc_receipt_record_inspection(p_id uuid, p_lines jsonb, p_notes text, p_decision text)
returns void language plpgsql security definer set search_path = '' as $$
declare
  r public.receipts;
  v_uid uuid := private.require_active_user();
  v_role text;
  l jsonb;
  d record;
  v_acc numeric; v_rej numeric; v_rec numeric; v_res text;
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
    if v_rec <= 0 or v_acc < 0 or v_rej < 0 or v_acc + v_rej <> v_rec then
      raise exception 'Barang %: jumlah diterima baik + ditolak harus sama dengan jumlah yang datang.', d.code using errcode = '22023';
    end if;
    if v_res is null or v_res not in ('sesuai','tidak_sesuai_jumlah','tidak_sesuai_spesifikasi','rusak') then
      raise exception 'Barang %: pilih hasil pemeriksaan.', d.code using errcode = '22023';
    end if;
    if v_res = 'sesuai' and v_rej > 0 then
      raise exception 'Barang %: hasil "sesuai" tidak boleh memiliki jumlah ditolak.', d.code using errcode = '22023';
    end if;
    -- Tanggal kedaluwarsa diisi Petugas Penerima Barang; pemeriksa hanya memeriksa
    -- dan mengesahkannya (tidak dapat mengubah). Bila salah: catat ketidaksesuaian.
    if d.has_expiry and v_acc > 0 and d.expiry_date is null then
      raise exception 'Barang % belum diisi tanggal kedaluwarsa oleh Petugas Penerima Barang. Pilih "Catat ketidaksesuaian" agar dilengkapi.', d.code using errcode = '22023';
    end if;
    if v_res <> 'sesuai' or v_rej > 0 or (d.qty_ordered is not null and v_rec <> d.qty_ordered) then
      v_issue := true;
    end if;
    update public.receipt_details
       set qty_received = v_rec, qty_accepted = v_acc, qty_rejected = v_rej,
           inspection_result = v_res, inspection_notes = nullif(trim(l ->> 'notes'), '')
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

-- 3. Perbaikan tanggal kedaluwarsa oleh Petugas Penerima Barang (pencatat)
--    selama penerimaan belum diperiksa atau setelah dicatat tidak sesuai.
create or replace function public.rpc_receipt_set_expiry(p_detail_id uuid, p_expiry date)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := private.require_active_user();
  d record;
  r public.receipts;
begin
  select d2.id, d2.receipt_id, i.code, i.has_expiry, d2.expiry_date into d
    from public.receipt_details d2 join public.items i on i.id = d2.item_id
   where d2.id = p_detail_id;
  if not found then
    raise exception 'Rincian penerimaan tidak dikenal.' using errcode = 'P0002';
  end if;
  r := private.receipt_for_update(d.receipt_id);
  if r.created_by is distinct from v_uid or not private.has_role('PPB') then
    raise exception 'Hanya Petugas Penerima Barang yang mencatat penerimaan ini yang dapat mengisi tanggal kedaluwarsa.' using errcode = '42501';
  end if;
  perform private.receipt_expect(r, array['draft','menunggu_pemeriksaan','tidak_sesuai','menunggu_tindak_lanjut_penyedia']);
  if not d.has_expiry then
    raise exception 'Barang % tidak memakai tanggal kedaluwarsa.', d.code using errcode = '22023';
  end if;
  if p_expiry is null then
    raise exception 'Tanggal kedaluwarsa wajib diisi.' using errcode = '22023';
  end if;
  if p_expiry is not distinct from d.expiry_date then
    return;
  end if;
  perform private.begin_rpc(format('Tanggal kedaluwarsa %s diubah: %s → %s', d.code,
                                   coalesce(to_char(d.expiry_date, 'DD-MM-YYYY'), 'kosong'), to_char(p_expiry, 'DD-MM-YYYY')));
  update public.receipt_details set expiry_date = p_expiry where id = p_detail_id;
  perform private.end_rpc();
end $$;

revoke all on function public.rpc_receipt_set_expiry(uuid, date) from public, anon;
grant execute on function public.rpc_receipt_set_expiry(uuid, date) to authenticated;
revoke all on function public.rpc_receipt_submit(uuid) from public, anon;
grant execute on function public.rpc_receipt_submit(uuid) to authenticated;
revoke all on function public.rpc_receipt_record_inspection(uuid, jsonb, text, text) from public, anon;
grant execute on function public.rpc_receipt_record_inspection(uuid, jsonb, text, text) to authenticated;

-- 4. Penerimaan yang sudah diajukan tanpa tanggal kedaluwarsa (aturan lama)
--    dikembalikan ke draf agar dilengkapi Petugas Penerima Barang. Aman diulang.
create or replace function private.reset_receipts_missing_expiry()
returns integer language plpgsql security definer set search_path = '' as $$
declare n integer;
begin
  perform private.begin_rpc('Dikembalikan ke draf: tanggal kedaluwarsa wajib diisi Petugas Penerima Barang');
  update public.receipts r
     set status = 'draft', inspector_id = null, inspected_at = null
   where r.status in ('menunggu_pemeriksaan','dalam_pemeriksaan')
     and exists (select 1 from public.receipt_details d join public.items i on i.id = d.item_id
                  where d.receipt_id = r.id and i.has_expiry and d.expiry_date is null);
  get diagnostics n = row_count;
  perform private.end_rpc();
  return n;
end $$;
revoke all on function private.reset_receipts_missing_expiry() from public;

select private.reset_receipts_missing_expiry();
