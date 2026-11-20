-- =====================================================================
-- Uji Fase 4A: penerimaan, saldo awal, saldo, perpindahan, kartu stok
-- =====================================================================
begin;

-- Data acuan (konteks sistem)
select tests.logout();
insert into public.items (code, name, category_id, unit_id, min_stock, safety_stock, max_stock, is_active)
select 'ATK-0101', 'Kertas HVS A4', c.id, u.id, 20, 10, 500, true
  from public.item_categories c, public.item_units u where c.code = 'ATK' and u.code = 'RIM';
insert into public.items (code, name, category_id, unit_id, has_expiry, is_active)
select 'KBR-0101', 'Cairan Pembersih Lantai', c.id, u.id, true, true
  from public.item_categories c, public.item_units u where c.code = 'KBR' and u.code = 'BTL';
insert into public.items (code, name, category_id, unit_id, is_active)
select 'ATK-0102', 'Pulpen Usulan', c.id, u.id, false
  from public.item_categories c, public.item_units u where c.code = 'ATK' and u.code = 'PCS';
insert into public.warehouses (code, name) values ('GDU', 'Gudang Uji'), ('GDL', 'Gudang Lain');
insert into public.storage_locations (warehouse_id, room, rack, location_number, code)
select id, 'R1', 'A', '01', 'GDU-A-01' from public.warehouses where code = 'GDU';
insert into public.storage_locations (warehouse_id, room, rack, location_number, code)
select id, 'R1', 'B', '01', 'GDU-B-01' from public.warehouses where code = 'GDU';
insert into public.storage_locations (warehouse_id, room, rack, location_number, code)
select id, 'R9', 'Z', '09', 'GDL-Z-09' from public.warehouses where code = 'GDL';
insert into public.suppliers (name) values ('CV Uji Sejahtera');

create temp table ids as
select (select id from public.items where code = 'ATK-0101') as item_a,
       (select id from public.items where code = 'KBR-0101') as item_b,
       (select id from public.items where code = 'ATK-0102') as item_inactive,
       (select id from public.warehouses where code = 'GDU') as wh,
       (select id from public.storage_locations where code = 'GDU-A-01') as loc1,
       (select id from public.storage_locations where code = 'GDU-B-01') as loc2,
       (select id from public.storage_locations where code = 'GDL-Z-09') as loc_other,
       (select id from public.suppliers where name = 'CV Uji Sejahtera') as sup,
       null::uuid as rcp, null::uuid as rcp_open, null::uuid as rcp3, null::uuid as det_a, null::uuid as det_b;
grant select, update on ids to authenticated;

-- 1. Draf penerimaan: hanya Petugas Penerima Barang -------------------
select tests.login_as('pgb@test.id');
select tests.throws($q$insert into public.receipts (source_type, supplier_id, contract_no, warehouse_id) select 'pembelian', sup, 'X', wh from ids$q$,
  'row-level security', 'Pengurus Barang tidak dapat mencatat penerimaan');

select tests.login_as('ppb@test.id');
insert into public.receipts (receipt_date, source_type, supplier_id, contract_no, warehouse_id, receipt_no, status)
select date '2026-11-10', 'pembelian', sup, 'SPK-001/2026', wh, 'NOMOR-PALSU', 'selesai' from ids;
update ids set rcp = (select id from public.receipts where contract_no = 'SPK-001/2026');
select tests.ok((select receipt_no like 'PNR/SATKER01/2026/11/%' and status = 'draft' from public.receipts where id = (select rcp from ids)),
  'Nomor penerimaan dibuat otomatis dan status selalu dimulai dari draf');

insert into public.receipt_details (receipt_id, line_no, item_id, qty_ordered, qty_received, unit_cost, location_id, qty_accepted)
select rcp, 1, item_a, 100, 100, 55000, loc1, 100 from ids;
insert into public.receipt_details (receipt_id, line_no, item_id, qty_ordered, qty_received, unit_cost)
select rcp, 2, item_b, 20, 20, 10000 from ids;
update ids set det_a = (select id from public.receipt_details where receipt_id = ids.rcp and line_no = 1),
               det_b = (select id from public.receipt_details where receipt_id = ids.rcp and line_no = 2);
select tests.ok((select qty_accepted = 0 from public.receipt_details where id = (select det_a from ids)),
  'Pencatat tidak dapat mengisi jumlah diterima (diisi pemeriksa)');

select tests.login_as('pgw.umum@test.id');
select tests.ok(tests.visible('select * from public.receipts') = 0, 'Pegawai tidak dapat melihat penerimaan');
select tests.throws($q$insert into public.receipts (source_type, warehouse_id) select 'hibah', wh from ids$q$,
  'row-level security', 'Pegawai tidak dapat membuat penerimaan');

select tests.login_as('ppk@test.id');
select tests.ok(tests.affected($q$update public.receipts set notes = 'x' where id = (select rcp from ids)$q$) = 0,
  'Pihak lain tidak dapat mengubah draf milik pencatat');

-- 2. Ajukan ----------------------------------------------------------------
select tests.login_as('ppb@test.id');
select public.rpc_receipt_submit((select rcp from ids));
select tests.ok((select status = 'menunggu_pemeriksaan' and total_value = 5700000 from public.receipts where id = (select rcp from ids)),
  'Penerimaan diajukan; nilai sementara Rp5.700.000 dihitung otomatis');
select tests.ok(tests.affected($q$update public.receipts set contract_no = 'UBAH' where id = (select rcp from ids)$q$) = 0,
  'Penerimaan yang sudah diajukan tidak dapat diubah');
select tests.throws($q$insert into public.receipt_details (receipt_id, item_id, qty_received, unit_cost) select rcp, item_a, 1, 1 from ids$q$,
  'masih draf', 'Rincian tidak dapat ditambah setelah diajukan');
select tests.throws($q$select public.rpc_receipt_start_inspection((select rcp from ids))$q$,
  'tidak berwenang memeriksa', 'Petugas Penerima Barang tidak dapat memeriksa');
select tests.login_as('pws@test.id');
select tests.throws($q$select public.rpc_receipt_start_inspection((select rcp from ids))$q$,
  'tidak berwenang memeriksa', 'Pejabat Pengawas tidak memeriksa penerimaan pembelian (kewenangan PPK)');

-- 3. Pemeriksaan sekaligus pengesahan oleh PPK -------------------------
select tests.login_as('ppk@test.id');
select public.rpc_receipt_start_inspection((select rcp from ids));
select tests.throws(
  $q$select public.rpc_receipt_record_inspection((select rcp from ids),
     jsonb_build_array(
       jsonb_build_object('detail_id', (select det_a from ids), 'qty_received', 100, 'qty_accepted', 95, 'qty_rejected', 5, 'result', 'tidak_sesuai_jumlah'),
       jsonb_build_object('detail_id', (select det_b from ids), 'qty_received', 20, 'qty_accepted', 20, 'qty_rejected', 0, 'result', 'sesuai')),
     'Pemeriksaan', 'lanjut')$q$,
  'tanggal kedaluwarsa', 'Barang ber-kedaluwarsa wajib diisi tanggal kedaluwarsa');
select tests.throws(
  $q$select public.rpc_receipt_record_inspection((select rcp from ids),
     jsonb_build_array(jsonb_build_object('detail_id', (select det_a from ids), 'qty_received', 100, 'qty_accepted', 90, 'qty_rejected', 5, 'result', 'tidak_sesuai_jumlah')),
     null, 'lanjut')$q$,
  'harus sama', 'Jumlah diterima + ditolak harus sama dengan jumlah datang');
select tests.throws(
  $q$select public.rpc_receipt_record_inspection((select rcp from ids),
     jsonb_build_array(
       jsonb_build_object('detail_id', (select det_a from ids), 'qty_received', 100, 'qty_accepted', 95, 'qty_rejected', 5, 'result', 'tidak_sesuai_jumlah'),
       jsonb_build_object('detail_id', (select det_b from ids), 'qty_received', 20, 'qty_accepted', 20, 'qty_rejected', 0, 'result', 'sesuai', 'expiry_date', '2027-06-30')),
     null, 'lanjut')$q$,
  'berita acara pemeriksaan', 'Pengesahan ditolak bila dokumen wajib belum ada');

select tests.login_as('pgw.umum@test.id');
select tests.throws($q$insert into public.attachments (ref_table, ref_id, doc_type, storage_path, file_name)
   select 'receipts', rcp, 'ba_pemeriksaan', 'receipts/' || rcp || '/x.pdf', 'x.pdf' from ids$q$,
  'row-level security', 'Pegawai tidak dapat menambah lampiran');
select tests.login_as('pgb@test.id');
select tests.throws($q$insert into public.attachments (ref_table, ref_id, doc_type, storage_path, file_name)
   select 'receipts', rcp, 'ba_pemeriksaan', 'receipts/' || rcp || '/x.pdf', 'x.pdf' from ids$q$,
  'row-level security', 'Pengurus Barang tidak menambah dokumen penerimaan');
select tests.login_as('ppk@test.id');
select tests.throws($q$insert into public.attachments (ref_table, ref_id, doc_type, storage_path, file_name)
   select 'receipts', rcp, 'ba_pemeriksaan', 'lain/' || rcp || '/x.pdf', 'x.pdf' from ids$q$,
  'row-level security', 'Lampiran harus disimpan di folder transaksinya');
insert into storage.objects (bucket_id, name) select 'documents', 'receipts/' || rcp || '/ba.pdf' from ids;
insert into public.attachments (ref_table, ref_id, doc_type, storage_path, file_name)
select 'receipts', rcp, 'ba_pemeriksaan', 'receipts/' || rcp || '/ba.pdf', 'ba.pdf' from ids;
select tests.login_as('ppb@test.id');
insert into public.attachments (ref_table, ref_id, doc_type, storage_path, file_name)
select 'receipts', rcp, 'surat_jalan', 'receipts/' || rcp || '/sj.pdf', 'sj.pdf' from ids;
select tests.ok((select uploaded_by = auth.uid() from public.attachments where file_name = 'sj.pdf'), 'Pengunggah lampiran tercatat otomatis');
select tests.throws($q$delete from public.attachments where file_name = 'ba.pdf'$q$, 'permission denied', 'Lampiran tidak dapat dihapus');
select tests.login_as('pgw.umum@test.id');
select tests.ok(tests.visible('select * from storage.objects') = 0, 'Pegawai tidak dapat melihat file dokumen penerimaan');

select tests.login_as('ppk@test.id');
select public.rpc_receipt_record_inspection((select rcp from ids),
  jsonb_build_array(
    jsonb_build_object('detail_id', (select det_a from ids), 'qty_received', 100, 'qty_accepted', 95, 'qty_rejected', 5, 'result', 'tidak_sesuai_jumlah', 'notes', '5 rim basah'),
    jsonb_build_object('detail_id', (select det_b from ids), 'qty_received', 20, 'qty_accepted', 20, 'qty_rejected', 0, 'result', 'sesuai', 'expiry_date', '2027-06-30')),
  'Diterima sebagian sesuai SPK', 'lanjut');
select tests.ok((select status = 'disetujui' and approved_by = auth.uid() and inspector_id = auth.uid() and total_value = 5425000
                   from public.receipts where id = (select rcp from ids)),
  'PPK memeriksa sekaligus mengesahkan; nilai Rp5.425.000 (hanya barang diterima baik)');
select tests.ok(tests.visible($q$select * from public.approvals where ref_id = (select rcp from ids) and decision = 'approved' and required_role_code = 'PPK'$q$) = 1,
  'Pengesahan tercatat beserta kewenangannya (PPK)');
select tests.login_as('ppb@test.id');
select tests.throws($q$insert into storage.objects (bucket_id, name) select 'documents', 'receipts/' || rcp || '/telat.pdf' from ids$q$,
  'row-level security', 'Dokumen tidak dapat ditambah setelah disahkan');

-- 4. Simpan ke gudang (saldo bertambah) ---------------------------------
select tests.login_as('ppb@test.id');
select tests.throws($q$select public.rpc_receipt_finalize((select rcp from ids))$q$,
  'hanya pengurus barang', 'Petugas Penerima Barang tidak menyimpan ke gudang');
select tests.login_as('pgb@test.id');
select tests.ok(tests.visible('select * from public.stock_balances') = 0, 'Belum ada saldo sebelum disimpan');
select tests.throws($q$select public.rpc_receipt_finalize((select rcp from ids))$q$,
  'pilih lokasi', 'Semua barang wajib memiliki lokasi simpan');
select tests.throws($q$select public.rpc_receipt_finalize((select rcp from ids), jsonb_build_object((select det_b from ids)::text, (select loc_other from ids)))$q$,
  'berada di gudang penerimaan', 'Lokasi harus di gudang penerimaan');
select public.rpc_receipt_finalize((select rcp from ids), jsonb_build_object((select det_b from ids)::text, (select loc2 from ids)));
select tests.ok((select status = 'selesai' and finalized_by = auth.uid() from public.receipts where id = (select rcp from ids)),
  'Setelah disimpan ke gudang, penerimaan langsung Selesai');
select tests.ok((select quantity = 95 and total_value = 5225000 from public.stock_balances where item_id = (select item_a from ids) and location_id = (select loc1 from ids)),
  'Saldo Kertas HVS bertambah 95 rim senilai Rp5.225.000 (5 rim ditolak tidak masuk)');
select tests.ok((select quantity = 20 and total_value = 200000 from public.stock_balances where item_id = (select item_b from ids)),
  'Saldo cairan pembersih bertambah 20 botol');
select tests.ok((select expiry_date = date '2027-06-30' from public.stock_batches where item_id = (select item_b from ids)),
  'Tanggal kedaluwarsa tersimpan pada batch');
select tests.throws($q$select public.rpc_receipt_finalize((select rcp from ids))$q$, 'berstatus', 'Penyimpanan ganda ditolak (saldo tidak bertambah dua kali)');
select tests.ok((select sum(quantity) = 115 from public.stock_balances), 'Total saldo tetap 115 setelah percobaan ganda');
select tests.throws($q$insert into public.stock_balances (item_id, location_id, quantity) select item_a, loc1, 999 from ids$q$,
  'permission denied', 'Saldo tidak dapat ditambah langsung');
select tests.throws($q$update public.stock_balances set quantity = 999$q$, 'permission denied', 'Saldo tidak dapat diubah langsung');
select tests.throws($q$update public.stock_movements set qty_in = 1$q$, 'permission denied', 'Buku mutasi tidak dapat diubah');

select tests.ok(tests.visible($q$select * from public.status_histories where ref_id = (select rcp from ids)$q$) >= 5,
  'Seluruh perubahan status tercatat di riwayat');

-- 5. Saldo awal: diperiksa & disahkan Pejabat Pengawas ------------------
select tests.login_as('ppb@test.id');
insert into public.receipts (receipt_date, source_type, warehouse_id, notes)
select date '2026-01-01', 'saldo_awal', wh, 'Saldo awal hasil inventarisasi' from ids;
update ids set rcp_open = (select id from public.receipts where source_type = 'saldo_awal');
insert into public.receipt_details (receipt_id, item_id, qty_received, unit_cost, location_id)
select rcp_open, item_a, 10, 50000, loc1 from ids;
select public.rpc_receipt_submit((select rcp_open from ids));
insert into public.attachments (ref_table, ref_id, doc_type, storage_path, file_name)
select 'receipts', rcp_open, 'ba_saldo_awal', 'receipts/' || rcp_open || '/ba-saldo.pdf', 'ba-saldo.pdf' from ids;
select tests.login_as('ppk@test.id');
select tests.throws($q$select public.rpc_receipt_start_inspection((select rcp_open from ids))$q$,
  'tidak berwenang memeriksa', 'PPK tidak memeriksa saldo awal (kewenangan Pejabat Pengawas)');
select tests.login_as('pws@test.id');
select public.rpc_receipt_start_inspection((select rcp_open from ids));
select public.rpc_receipt_record_inspection((select rcp_open from ids),
  jsonb_build_array(jsonb_build_object('detail_id', (select id from public.receipt_details where receipt_id = (select rcp_open from ids)),
                                       'qty_received', 10, 'qty_accepted', 10, 'qty_rejected', 0, 'result', 'sesuai')), null, 'lanjut');
select tests.ok(tests.visible($q$select * from public.approvals where ref_id = (select rcp_open from ids) and required_role_code = 'PWS'$q$) = 1,
  'Saldo awal disahkan Pejabat Pengawas');
select tests.login_as('pgb@test.id');
select public.rpc_receipt_finalize((select rcp_open from ids));
select tests.ok((select count(*) = 1 from public.stock_movements where movement_type = 'OPENING_BALANCE' and ref_id = (select rcp_open from ids)),
  'Saldo awal tercatat sebagai mutasi SALDO AWAL');
select tests.ok((select quantity = 105 and total_value = 5725000 from public.stock_balances where item_id = (select item_a from ids) and location_id = (select loc1 from ids)),
  'Saldo Kertas HVS di A-01 menjadi 105 rim senilai Rp5.725.000');

-- 6. Pemisahan fungsi, ketidaksesuaian & pembatalan ---------------------
select tests.logout();
insert into public.user_roles (user_id, role_id)
select p.id, r.id from public.profiles p, public.roles r where p.email = 'ppb@test.id' and r.code = 'PWS';
select tests.login_as('ppb@test.id');
insert into public.receipts (source_type, source_description, warehouse_id) select 'hibah', 'Hibah Pemda', wh from ids;
update ids set rcp3 = (select id from public.receipts where source_type = 'hibah');
insert into public.receipt_details (receipt_id, item_id, qty_received, unit_cost) select rcp3, item_inactive, 5, 1000 from ids;
select tests.throws($q$select public.rpc_receipt_submit((select rcp3 from ids))$q$, 'belum aktif', 'Barang usulan (belum aktif) tidak dapat diterima');
delete from public.receipt_details where receipt_id = (select rcp3 from ids);
insert into public.receipt_details (receipt_id, item_id, qty_ordered, qty_received, unit_cost) select rcp3, item_a, 5, 5, 0 from ids;
select public.rpc_receipt_submit((select rcp3 from ids));
select tests.throws($q$select public.rpc_receipt_start_inspection((select rcp3 from ids))$q$,
  'pemisahan fungsi', 'Pencatat yang juga Pejabat Pengawas tetap tidak dapat memeriksa penerimaannya sendiri');

select tests.login_as('pws@test.id');
select public.rpc_receipt_start_inspection((select rcp3 from ids));
select public.rpc_receipt_record_inspection((select rcp3 from ids),
  jsonb_build_array(jsonb_build_object('detail_id', (select id from public.receipt_details where receipt_id = (select rcp3 from ids)),
                                       'qty_received', 5, 'qty_accepted', 0, 'qty_rejected', 5, 'result', 'rusak')), 'Semua rusak', 'tindak_lanjut');
select tests.ok((select status = 'tidak_sesuai' from public.receipts where id = (select rcp3 from ids)), 'Ketidaksesuaian tercatat');
select tests.login_as('ppb@test.id');
select public.rpc_receipt_vendor_followup((select rcp3 from ids), 'Minta pemberi hibah mengganti barang');
select tests.ok((select status = 'menunggu_tindak_lanjut_penyedia' and inspector_id is not null from public.receipts where id = (select rcp3 from ids)),
  'Diteruskan ke pemberi untuk tindak lanjut');
select tests.login_as('pgb@test.id');
select tests.throws($q$select public.rpc_receipt_cancel((select rcp3 from ids), 'Batal saja')$q$, 'hanya pencatat', 'Hanya pencatat yang dapat membatalkan');
select tests.login_as('ppb@test.id');
select tests.throws($q$select public.rpc_receipt_cancel((select rcp3 from ids), 'ok')$q$, 'alasan', 'Pembatalan wajib beralasan');
select public.rpc_receipt_cancel((select rcp3 from ids), 'Hibah batal diserahkan');
select tests.ok((select status = 'dibatalkan' from public.receipts where id = (select rcp3 from ids)), 'Penerimaan dapat dibatalkan sebelum disahkan');
select tests.throws($q$select public.rpc_receipt_cancel((select rcp from ids), 'Tidak jadi sama sekali')$q$, 'berstatus',
  'Penerimaan yang sudah selesai tidak dapat dibatalkan');

-- 8. Perpindahan lokasi (FIFO, total tidak berubah) ---------------------
select tests.login_as('ppb@test.id');
select tests.throws($q$select public.rpc_transfer_stock(date '2026-11-15', 'Penataan rak', jsonb_build_array(jsonb_build_object('item_id', (select item_a from ids), 'from_location_id', (select loc1 from ids), 'to_location_id', (select loc2 from ids), 'quantity', 1)))$q$,
  'hanya pengurus barang', 'Petugas lain tidak dapat memindahkan lokasi');
select tests.login_as('pgb@test.id');
select tests.throws($q$select public.rpc_transfer_stock(date '2026-11-15', 'Penataan rak', jsonb_build_array(jsonb_build_object('item_id', (select item_a from ids), 'from_location_id', (select loc1 from ids), 'to_location_id', (select loc2 from ids), 'quantity', 200)))$q$,
  'tidak mencukupi', 'Perpindahan melebihi saldo ditolak');
select tests.throws($q$select public.rpc_transfer_stock(date '2026-11-05', 'Penataan rak', jsonb_build_array(jsonb_build_object('item_id', (select item_a from ids), 'from_location_id', (select loc1 from ids), 'to_location_id', (select loc2 from ids), 'quantity', 1)))$q$,
  'lebih awal dari mutasi terakhir', 'Perpindahan bertanggal mundur ditolak');
select public.rpc_transfer_stock(date '2026-11-15', 'Penataan rak', jsonb_build_array(jsonb_build_object(
  'item_id', (select item_a from ids), 'from_location_id', (select loc1 from ids), 'to_location_id', (select loc2 from ids), 'quantity', 12)));
select tests.ok((select quantity = 12 and total_value = 610000 from public.stock_balances where item_id = (select item_a from ids) and location_id = (select loc2 from ids)),
  'FIFO: 10 rim saldo awal (Rp50.000) + 2 rim pembelian (Rp55.000) dipindahkan = Rp610.000');
select tests.ok((select sum(quantity) = 105 and sum(total_value) = 5725000 from public.stock_balances where item_id = (select item_a from ids)),
  'Total saldo & nilai tidak berubah karena perpindahan');

-- 9. Kartu stok & konsistensi -------------------------------------------
select tests.login_as('pws@test.id');
select tests.ok(
  (select (c ->> 'opening_qty')::numeric = 0 and (c ->> 'total_in')::numeric = 105 and (c ->> 'total_out')::numeric = 0
          and (c ->> 'closing_qty')::numeric = 105 and (c ->> 'closing_value')::numeric = 5725000
          and jsonb_array_length(c -> 'rows') = 6
     from (select public.rpc_stock_card((select item_a from ids), date '2026-01-01', date '2026-12-31') c) x),
  'Kartu stok: saldo awal 0, masuk 105, keluar 0, akhir 105 senilai Rp5.725.000, 6 baris mutasi');
select tests.ok(
  (select (c ->> 'opening_qty')::numeric = 10 and (c ->> 'opening_value')::numeric = 500000
     from (select public.rpc_stock_card((select item_a from ids), date '2026-11-01', date '2026-11-30') c) x),
  'Kartu stok periode November: saldo awal 10 rim (dari saldo awal Januari)');
select tests.ok((select count(*) = 0 from public.rpc_verify_stock()), 'Mutasi, batch, dan saldo konsisten untuk semua barang');
select tests.ok(
  (select (d -> 'stock' ->> 'total_value')::numeric = 5925000 and (d -> 'stock' ->> 'items_in_stock')::int = 2
     from (select public.rpc_dashboard_overview() d) x),
  'Dashboard Pejabat Pengawas: nilai persediaan Rp5.925.000 dari 2 jenis barang');
select tests.login_as('pgw.umum@test.id');
select tests.ok(not (public.rpc_dashboard_overview() ? 'stock'), 'Dashboard pegawai tidak memuat nilai persediaan');
select tests.throws($q$select public.rpc_stock_card((select item_a from ids), date '2026-01-01', date '2026-12-31')$q$,
  'tidak berwenang', 'Pegawai tidak dapat melihat kartu stok');
select tests.ok(tests.visible('select * from public.stock_movements') = 0, 'Pegawai tidak dapat melihat buku mutasi');
select tests.ok((select qty_good = 0 from public.v_stock_summary where code = 'ATK-0101'),
  'Ringkasan stok untuk pegawai tidak memperlihatkan saldo (Fase 4B: ketersediaan tanpa nilai)');

select tests.login_as('aud@test.id');
select tests.ok(tests.visible('select * from public.stock_movements') = 7, 'Auditor dapat menelusuri seluruh buku mutasi (7 baris)');
select tests.ok((select is_valid from public.rpc_verify_audit_chain()), 'Rantai audit tetap valid setelah transaksi');
select tests.ok(
  (select (r ->> 'balance_qty')::numeric = 10 and r ->> 'type' = 'OPENING_BALANCE'
     from jsonb_array_elements((public.rpc_stock_card((select item_a from ids), date '2026-01-01', date '2026-12-31')) -> 'rows') r
    limit 1),
  'Baris pertama kartu stok = saldo awal 10 rim, walau dicatat belakangan');

select tests.logout();
rollback;
