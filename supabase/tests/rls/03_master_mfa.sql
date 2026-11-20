-- =====================================================================
-- Uji Fase 3: verifikasi dua langkah Super Admin & master data
-- =====================================================================
begin;

-- 1. Verifikasi dua langkah (MFA) untuk Super Admin --------------------
select tests.login_as('sa@test.id', 'aal1');
select tests.ok(tests.visible('select * from public.profiles') = 17, 'SA tanpa MFA tetap dapat membaca data');
select tests.throws($q$insert into public.organizational_units (code, name) values ('X1','Uji')$q$,
  'row-level security', 'SA tanpa MFA tidak dapat menambah unit kerja');
select tests.throws(
  $q$insert into public.user_roles (user_id, role_id)
     select p.id, r.id from public.profiles p, public.roles r where p.email = 'tanpa.role@test.id' and r.code = 'PGB'$q$,
  'row-level security', 'SA tanpa MFA tidak dapat menetapkan role');
select tests.throws($q$update public.profiles set position_title = 'X' where email = 'pgw.keu@test.id'$q$,
  'verifikasi dua langkah', 'SA tanpa MFA tidak dapat mengubah profil pengguna lain');
select tests.ok(
  tests.affected($q$update public.app_settings set value = '9' where key = 'request_confirm_days'$q$) = 0,
  'SA tanpa MFA tidak dapat mengubah pengaturan');
select tests.ok(
  tests.affected($q$update public.profiles set phone = '0812' where id = auth.uid()$q$) = 1,
  'SA tanpa MFA tetap dapat mengubah teleponnya sendiri');
select tests.ok((public.rpc_dashboard_overview() ->> 'mfa_required')::boolean
                and not (public.rpc_dashboard_overview() ->> 'mfa_satisfied')::boolean,
  'Dashboard memberi tahu SA bahwa MFA wajib dan belum dipenuhi');

select tests.ok((public.rpc_my_context() ->> 'mfa_required')::boolean, 'Konteks SA menandai MFA wajib');
select tests.login_as('pgw.umum@test.id', 'aal1');
select tests.ok(not (public.rpc_my_context() ->> 'mfa_required')::boolean, 'Pegawai tidak diwajibkan MFA');
select tests.login_as('sa@test.id', 'aal2');
select tests.ok(
  tests.affected($q$insert into public.item_categories (code, name) values ('UJI', 'Kategori Uji')$q$) = 1,
  'SA dengan MFA dapat menambah kategori');

select tests.logout();
update public.app_settings set value = '[]' where key = 'mfa_required_roles';
select tests.login_as('sa@test.id', 'aal1');
select tests.ok(
  tests.affected($q$insert into public.item_units (code, name) values ('UJI', 'Satuan Uji')$q$) = 1,
  'Bila MFA dimatikan di pengaturan, SA tanpa MFA dapat mengubah data');
select tests.logout();
update public.app_settings set value = '["SA"]' where key = 'mfa_required_roles';

-- 2. Data awal ----------------------------------------------------------
select tests.ok((select count(*) from public.item_categories where code in ('ATK','CTK','KMP','KBR','RTG','PML','BHP')) = 7,
  '7 kategori barang sesuai spesifikasi tersedia');
select tests.ok((select count(*) from public.item_units) >= 18, 'Satuan barang awal tersedia');

-- 3. Hak baca per role --------------------------------------------------
select tests.login_as('pgw.umum@test.id');
select tests.ok(tests.visible('select * from public.item_categories') >= 7, 'Pegawai dapat membaca kategori');
select tests.ok(tests.visible('select * from public.item_units') >= 18, 'Pegawai dapat membaca satuan');
select tests.ok(tests.visible('select * from public.warehouses') = 0, 'Pegawai tidak dapat membaca data gudang');
select tests.ok(tests.visible('select * from public.suppliers') = 0, 'Pegawai tidak dapat membaca data penyedia');
select tests.throws(
  $q$insert into public.items (code, name, category_id, unit_id)
     select 'ATK-9999', 'Barang Palsu', c.id, u.id from public.item_categories c, public.item_units u where c.code = 'ATK' and u.code = 'PCS'$q$,
  'row-level security', 'Pegawai tidak dapat menambah barang');
select tests.throws($q$insert into public.item_categories (code, name) values ('ZZ', 'Z')$q$,
  'row-level security', 'Pegawai tidak dapat menambah kategori');

-- 4. Usulan barang oleh Pengurus Barang ---------------------------------
select tests.login_as('pgb@test.id');
select tests.ok(public.rpc_suggest_item_code((select id from public.item_categories where code = 'ATK')) = 'ATK-0001',
  'Usulan kode barang pertama ATK-0001');
select tests.ok(
  tests.affected($q$insert into public.items (code, name, category_id, unit_id, min_stock, safety_stock, max_stock, is_active)
     select ' atk-0001 ', 'Kertas HVS A4 70 gsm', c.id, u.id, 10, 15, 100, true
       from public.item_categories c, public.item_units u where c.code = 'ATK' and u.code = 'RIM'$q$) = 1,
  'Pengurus Barang dapat mengusulkan barang');
select tests.ok(
  (select not is_active and activated_at is null and code = 'ATK-0001' from public.items where name = 'Kertas HVS A4 70 gsm'),
  'Usulan Pengurus Barang otomatis nonaktif dan kode dinormalkan menjadi huruf besar');
select tests.throws($q$update public.items set is_active = true where code = 'ATK-0001'$q$,
  'hanya super admin', 'Pengurus Barang tidak dapat mengaktifkan barang sendiri');
select tests.ok(
  tests.affected($q$update public.items set specification = 'Kertas ukuran A4' where code = 'ATK-0001'$q$) = 1,
  'Pengurus Barang dapat melengkapi spesifikasi');
select tests.ok(public.rpc_suggest_item_code((select id from public.item_categories where code = 'ATK')) = 'ATK-0002',
  'Usulan kode berikutnya ATK-0002');
select tests.throws(
  $q$insert into public.items (code, name, category_id, unit_id)
     select 'ATK-0001', 'Duplikat', c.id, u.id from public.item_categories c, public.item_units u where c.code = 'ATK' and u.code = 'PCS'$q$,
  'duplicate key', 'Kode barang tidak boleh ganda');
select tests.throws(
  $q$insert into public.items (code, name, category_id, unit_id, min_stock, max_stock)
     select 'ATK-0005', 'Stok Salah', c.id, u.id, 50, 10 from public.item_categories c, public.item_units u where c.code = 'ATK' and u.code = 'PCS'$q$,
  'items_stock_levels', 'Stok minimum tidak boleh melebihi stok maksimum');
select tests.affected($q$update public.items set activated_at = now() where code = 'ATK-0001'$q$);
select tests.ok((select activated_at is null from public.items where code = 'ATK-0001'),
  'Kolom aktivasi tidak dapat dipalsukan');
select tests.throws($q$delete from public.items where code = 'ATK-0001'$q$, 'permission denied', 'Barang tidak dapat dihapus');

select tests.login_as('sa@test.id', 'aal1');
select tests.ok(tests.affected($q$update public.items set is_active = true where code = 'ATK-0001'$q$) = 0,
  'SA tanpa MFA belum dapat mengaktifkan barang');
select tests.login_as('sa@test.id');
select tests.ok((public.rpc_dashboard_overview() ->> 'proposed_items')::int = 1, 'Dashboard SA menampilkan 1 usulan barang');
select tests.ok(
  tests.affected($q$update public.items set is_active = true where code = 'ATK-0001'$q$) = 1,
  'SA dengan MFA mengaktifkan barang');
select tests.ok(
  (select activated_at is not null and activated_by = auth.uid() from public.items where code = 'ATK-0001'),
  'Waktu & pelaku aktivasi tercatat otomatis');
select tests.ok((public.rpc_dashboard_overview() ->> 'active_items')::int = 1, 'Dashboard menghitung 1 jenis barang aktif');

-- 5. Gudang & lokasi ----------------------------------------------------
select tests.login_as('pgb@test.id');
select tests.ok(
  tests.affected($q$insert into public.warehouses (code, name) values ('GDG1', 'Gudang Utama')$q$) = 1,
  'Pengurus Barang dapat menambah gudang');
select tests.ok(
  tests.affected($q$insert into public.storage_locations (warehouse_id, room, rack, location_number, code)
     select id, 'R. Arsip', 'A', '01', 'gdg1-a-01' from public.warehouses where code = 'GDG1'$q$) = 1,
  'Pengurus Barang dapat menambah lokasi penyimpanan');
select tests.throws(
  $q$insert into public.storage_locations (warehouse_id, room, rack, location_number, code)
     select id, 'R. Arsip', 'A', '01', 'GDG1-A-01B' from public.warehouses where code = 'GDG1'$q$,
  'storage_locations_unique_position', 'Posisi rak yang sama tidak boleh didaftarkan dua kali');

select tests.login_as('kpa@test.id');
select tests.ok(tests.visible('select * from public.storage_locations') = 1, 'KPA dapat melihat lokasi');
select tests.throws(
  $q$insert into public.warehouses (code, name) values ('GDG2', 'Gudang Dua')$q$,
  'row-level security', 'KPA tidak dapat menambah gudang (bukan fungsinya)');

select tests.login_as('akt@test.id');
select tests.ok(tests.visible($q$select * from public.storage_locations where code = 'GDG1-A-01'$q$) = 1,
  'Petugas Akuntansi dapat melihat lokasi (kode tersimpan huruf besar)');

-- 6. Penyedia -----------------------------------------------------------
select tests.login_as('ppk@test.id');
select tests.ok(
  tests.affected($q$insert into public.suppliers (name, npwp, email) values ('CV Maju Jaya', '0123456789012345', 'admin@majujaya.co.id')$q$) = 1,
  'PPK dapat menambah penyedia');
select tests.throws($q$insert into public.suppliers (name, npwp) values ('CV Salah', '123')$q$,
  'suppliers_npwp_check', 'NPWP harus 15/16 digit');
select tests.login_as('pgb@test.id');
select tests.throws($q$insert into public.suppliers (name) values ('CV Lain')$q$,
  'row-level security', 'Pengurus Barang tidak dapat menambah penyedia');
select tests.login_as('aud@test.id');
select tests.ok(tests.visible('select * from public.suppliers') = 1, 'Auditor dapat melihat penyedia');
select tests.ok(tests.affected($q$update public.suppliers set name = 'X'$q$) = 0, 'Auditor tidak dapat mengubah penyedia');

-- 7. Audit --------------------------------------------------------------
select tests.ok(
  tests.visible($q$select * from public.audit_logs where table_name = 'items' and action = 'INSERT'$q$) = 1
  and tests.visible($q$select * from public.audit_logs where table_name = 'items' and action = 'UPDATE'
                       and (new_data ->> 'is_active')::boolean and 'SA' = any(user_roles)$q$) = 1,
  'Usulan dan aktivasi barang tercatat di audit trail');
select tests.ok((select is_valid from public.rpc_verify_audit_chain()), 'Rantai audit tetap valid');

select tests.logout();
rollback;
