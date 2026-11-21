-- =====================================================================
-- Uji perubahan 21-11-2026: tanggal kedaluwarsa diisi Petugas Penerima
-- Barang; PPK / Pejabat Pengawas hanya memeriksa dan mengesahkan.
-- =====================================================================
begin;
select tests.logout();
insert into public.items (code, name, category_id, unit_id, has_expiry, is_active)
select 'KBR-0701', 'Sabun Cair Uji', c.id, u.id, true, true
  from public.item_categories c, public.item_units u where c.code = 'KBR' and u.code = 'BTL';
insert into public.warehouses (code, name) values ('GD7', 'Gudang Uji 7');
insert into public.storage_locations (warehouse_id, room, rack, location_number, code)
select id, 'R1', 'A', '01', 'GD7-A-01' from public.warehouses where code = 'GD7';
insert into public.suppliers (name) values ('CV Uji Tujuh');
create temp table k7 as
select (select id from public.items where code = 'KBR-0701') as item,
       (select id from public.warehouses where code = 'GD7') as wh,
       (select id from public.storage_locations where code = 'GD7-A-01') as loc,
       (select id from public.suppliers where name = 'CV Uji Tujuh') as sup,
       null::uuid as rcp, null::uuid as det, null::uuid as old_rcp;
grant all on k7 to authenticated;

select tests.login_as('ppb@test.id');
insert into public.receipts (source_type, supplier_id, contract_no, warehouse_id) select 'pembelian', sup, 'SPK-K7', wh from k7;
update k7 set rcp = (select id from public.receipts where contract_no = 'SPK-K7');
insert into public.receipt_details (receipt_id, item_id, qty_ordered, qty_received, unit_cost, expiry_date)
select rcp, item, 10, 10, 5000, date '2027-01-31' from k7;
update k7 set det = (select id from public.receipt_details where receipt_id = k7.rcp);
select tests.ok((select expiry_date = date '2027-01-31' from public.receipt_details where id = (select det from k7)),
  'Petugas Penerima mengisi tanggal kedaluwarsa saat mencatat rincian');
select public.rpc_receipt_submit((select rcp from k7));
insert into public.attachments (ref_table, ref_id, doc_type, storage_path, file_name)
select 'receipts', rcp, 'surat_jalan', 'receipts/' || rcp || '/sj.pdf', 'sj.pdf' from k7;

-- PPK menemukan tanggal tidak sesuai fisik barang -> catat ketidaksesuaian
select tests.login_as('ppk@test.id');
select tests.throws($q$select public.rpc_receipt_set_expiry((select det from k7), date '2027-12-31')$q$,
  'Hanya Petugas Penerima Barang', 'PPK tidak dapat mengubah tanggal kedaluwarsa');
select public.rpc_receipt_start_inspection((select rcp from k7));
select public.rpc_receipt_record_inspection((select rcp from k7),
  jsonb_build_array(jsonb_build_object('detail_id', (select det from k7), 'qty_received', 10, 'qty_accepted', 10, 'qty_rejected', 0,
                                       'result', 'tidak_sesuai_spesifikasi', 'notes', 'Tanggal di kemasan 31-12-2027')),
  'Tanggal kedaluwarsa tidak sesuai kemasan', 'tindak_lanjut');
select tests.ok((select status = 'tidak_sesuai' from public.receipts where id = (select rcp from k7)),
  'Tanggal kedaluwarsa yang salah dicatat sebagai ketidaksesuaian');

-- Petugas Penerima memperbaiki tanggal
select tests.login_as('ppb@test.id');
select tests.ok(tests.affected($q$update public.receipt_details set expiry_date = date '2027-12-31' where id = (select det from k7)$q$) = 0,
  'Rincian tidak dapat diubah langsung setelah diajukan');
select tests.throws($q$select public.rpc_receipt_set_expiry((select det from k7), null)$q$,
  'wajib diisi', 'Tanggal kedaluwarsa tidak boleh dikosongkan');
select public.rpc_receipt_set_expiry((select det from k7), date '2027-12-31');
select tests.ok((select expiry_date = date '2027-12-31' from public.receipt_details where id = (select det from k7)),
  'Petugas Penerima memperbaiki tanggal kedaluwarsa');
select public.rpc_receipt_vendor_followup((select rcp from k7), 'Tanggal kedaluwarsa sudah diperbaiki');

select tests.login_as('pgb@test.id');
select tests.throws($q$select public.rpc_receipt_set_expiry((select det from k7), date '2028-01-01')$q$,
  'Hanya Petugas Penerima Barang', 'Pengurus Barang tidak dapat mengubah tanggal kedaluwarsa');

-- PPK memeriksa ulang dan mengesahkan
select tests.login_as('ppk@test.id');
select public.rpc_receipt_start_inspection((select rcp from k7));
select tests.login_as('ppb@test.id');
select tests.throws($q$select public.rpc_receipt_set_expiry((select det from k7), date '2028-01-01')$q$,
  'status', 'Tanggal tidak dapat diubah selama pemeriksaan berlangsung');
select tests.login_as('ppk@test.id');
insert into public.attachments (ref_table, ref_id, doc_type, storage_path, file_name)
select 'receipts', rcp, 'ba_pemeriksaan', 'receipts/' || rcp || '/ba.pdf', 'ba.pdf' from k7;
select public.rpc_receipt_record_inspection((select rcp from k7),
  jsonb_build_array(jsonb_build_object('detail_id', (select det from k7), 'qty_received', 10, 'qty_accepted', 10, 'qty_rejected', 0, 'result', 'sesuai')),
  null, 'lanjut');
select tests.ok((select status = 'disetujui' from public.receipts where id = (select rcp from k7)),
  'PPK mengesahkan tanggal kedaluwarsa isian Petugas Penerima tanpa mengisinya sendiri');
select tests.login_as('pgb@test.id');
select public.rpc_receipt_finalize((select rcp from k7), jsonb_build_object((select det from k7)::text, (select loc from k7)));
select tests.ok((select expiry_date = date '2027-12-31' from public.stock_batches where item_id = (select item from k7)),
  'Batch stok memakai tanggal kedaluwarsa yang disahkan');
select tests.login_as('ppb@test.id');
select tests.throws($q$select public.rpc_receipt_set_expiry((select det from k7), date '2028-01-01')$q$,
  'status', 'Tanggal tidak dapat diubah setelah disahkan');

-- Penerimaan lama (diajukan tanpa tanggal) dikembalikan ke draf saat pembaruan
select tests.logout();
alter table public.receipt_details disable trigger trg_receipt_details_guard;
insert into public.receipts (source_type, supplier_id, contract_no, warehouse_id, created_by)
select 'pembelian', sup, 'SPK-K7-LAMA', wh, (select id from public.profiles where email = 'ppb@test.id') from k7;
update k7 set old_rcp = (select id from public.receipts where contract_no = 'SPK-K7-LAMA');
insert into public.receipt_details (receipt_id, item_id, qty_received, unit_cost) select old_rcp, item, 3, 1000 from k7;
alter table public.receipt_details enable trigger trg_receipt_details_guard;
update public.receipts set status = 'dalam_pemeriksaan', inspector_id = (select id from public.profiles where email = 'ppk@test.id')
 where id = (select old_rcp from k7);
select private.reset_receipts_missing_expiry();
select tests.ok((select status = 'draft' and inspector_id is null from public.receipts where id = (select old_rcp from k7)),
  'Penerimaan lama tanpa tanggal kedaluwarsa dikembalikan ke draf untuk dilengkapi');
select tests.ok((select status = 'disetujui' from public.receipts where id = (select rcp from k7)) is false
                and (select status = 'selesai' from public.receipts where id = (select rcp from k7)),
  'Penerimaan yang sudah lengkap tidak terpengaruh');
rollback;
