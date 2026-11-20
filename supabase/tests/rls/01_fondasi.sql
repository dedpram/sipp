-- =====================================================================
-- Uji Fase 2: RLS, pemisahan fungsi, audit trail, RPC fondasi
-- Setiap baris "ok - ..." = satu pemeriksaan lolos.
-- =====================================================================
begin;

-- 1. Seluruh tabel di schema public wajib RLS --------------------------
select tests.ok(
  not exists (select 1 from pg_tables where schemaname = 'public' and not rowsecurity),
  'Semua tabel public mengaktifkan RLS');

select tests.ok(
  not exists (
    select 1 from information_schema.role_table_grants
     where table_schema = 'public' and grantee = 'anon'),
  'Role anon tidak memiliki hak apa pun atas tabel public');

-- 2. Pengunjung tanpa login ---------------------------------------------
select tests.login_anon();
select tests.throws('select * from public.profiles', 'permission denied', 'anon tidak dapat membaca profiles');
select tests.throws('select * from public.app_settings', 'permission denied', 'anon tidak dapat membaca app_settings');
select tests.throws('select public.rpc_my_context()', 'permission denied', 'anon tidak dapat memanggil rpc_my_context');
select tests.logout();

-- 3. Visibilitas profil per role ----------------------------------------
select tests.login_as('pgw.umum@test.id');
select tests.ok(tests.visible('select * from public.profiles') = 1, 'Pegawai hanya melihat profilnya sendiri');
select tests.ok(tests.visible('select * from public.user_roles') = 1, 'Pegawai hanya melihat role miliknya');
select tests.ok(tests.visible('select * from public.roles') = 11, 'Pegawai dapat membaca daftar role');
select tests.ok(tests.visible('select * from public.app_settings') > 0, 'Pegawai dapat membaca pengaturan');

select tests.login_as('ats.umum@test.id');
select tests.ok(
  tests.visible($q$select * from public.profiles where email in ('pgw.umum@test.id','pgw.rt@test.id','ats.umum@test.id')$q$) = 3,
  'Atasan Umum melihat pegawai unit Umum & sub-unit Rumah Tangga');
select tests.ok(
  tests.visible($q$select * from public.profiles where email = 'pgw.keu@test.id'$q$) = 0,
  'Atasan Umum TIDAK melihat pegawai Bagian Keuangan');

select tests.login_as('ats.keu@test.id');
select tests.ok(
  tests.visible($q$select * from public.profiles where email = 'pgw.rt@test.id'$q$) = 0,
  'Atasan Keuangan TIDAK melihat pegawai Rumah Tangga');

select tests.login_as('sa@test.id');
select tests.ok(tests.visible('select * from public.profiles') = 17, 'Super Admin melihat seluruh profil');

-- 4. Ubah profil -------------------------------------------------------
select tests.login_as('pgw.umum@test.id');
select tests.ok(
  tests.affected($q$update public.profiles set phone = '0811' where email = 'pgw.rt@test.id'$q$) = 0,
  'Pegawai tidak dapat mengubah profil orang lain (0 baris)');
select tests.throws(
  $q$update public.profiles set full_name = 'Nama Palsu' where id = auth.uid()$q$,
  'hanya dapat mengubah nomor telepon', 'Pegawai tidak dapat mengubah namanya sendiri');
select tests.throws(
  $q$update public.profiles set is_active = false where id = auth.uid()$q$,
  'hanya dapat mengubah nomor telepon', 'Pegawai tidak dapat mengubah status aktif');
select tests.throws(
  $q$update public.profiles set last_login_at = now() - interval '1 year' where id = auth.uid()$q$,
  'dikelola oleh sistem', 'Pegawai tidak dapat memalsukan waktu login');
select tests.ok(
  tests.affected($q$update public.profiles set phone = '081234567890' where id = auth.uid()$q$) = 1,
  'Pegawai dapat mengubah nomor teleponnya');

select tests.login_as('sa@test.id');
select tests.throws(
  $q$update public.profiles set is_active = false where id = auth.uid()$q$,
  'akun anda sendiri', 'Super Admin tidak dapat menonaktifkan dirinya sendiri');
select tests.ok(
  tests.affected($q$update public.profiles set position_title = 'Staf' where email = 'pgw.keu@test.id'$q$) = 1,
  'Super Admin dapat mengubah profil pengguna lain');
select tests.throws(
  $q$update public.profiles set email = 'x@y.id' where email = 'pgw.keu@test.id'$q$,
  'email hanya dapat diubah', 'Email tidak dapat diubah melalui tabel profil');

-- 5. Pengguna nonaktif --------------------------------------------------
select tests.login_as('nonaktif@test.id');
select tests.ok(tests.visible('select * from public.profiles') = 0, 'Pengguna nonaktif tidak melihat profil');
select tests.ok(tests.visible('select * from public.roles') = 0, 'Pengguna nonaktif tidak melihat data apa pun');
select tests.throws('select public.rpc_my_context()', 'nonaktif', 'rpc_my_context menolak pengguna nonaktif');
select tests.throws('select public.rpc_dashboard_overview()', 'nonaktif', 'Dashboard menolak pengguna nonaktif');

-- 6. Penetapan role & pemisahan fungsi ---------------------------------
select tests.login_as('pgw.umum@test.id');
select tests.throws(
  $q$insert into public.user_roles (user_id, role_id) select auth.uid(), id from public.roles where code = 'KPA'$q$,
  'role anda sendiri', 'Pegawai tidak dapat memberi dirinya role');

select tests.login_as('pws@test.id');
select tests.throws(
  $q$insert into public.user_roles (user_id, role_id)
     select p.id, r.id from public.profiles p, public.roles r where p.email = 'tanpa.role@test.id' and r.code = 'PGB'$q$,
  'row-level security', 'Pejabat Pengawas tidak dapat menetapkan role (hanya SA)');

select tests.login_as('sa@test.id');
select tests.throws(
  $q$insert into public.user_roles (user_id, role_id) select auth.uid(), id from public.roles where code = 'PGB'$q$,
  'role anda sendiri', 'SOD-9: Super Admin tidak dapat mengubah role sendiri');
select tests.throws(
  $q$insert into public.user_roles (user_id, role_id)
     select p.id, r.id from public.profiles p, public.roles r where p.email = 'sa2@test.id' and r.code = 'PWS'$q$,
  'super admin tidak boleh merangkap', 'SOD-7: Super Admin tidak dapat merangkap Pejabat Pengawas');
select tests.throws(
  $q$insert into public.user_roles (user_id, role_id)
     select p.id, r.id from public.profiles p, public.roles r where p.email = 'pgb@test.id' and r.code = 'SA'$q$,
  'super admin tidak boleh merangkap', 'SOD-7: Pengurus Barang tidak dapat diberi role SA');
select tests.throws(
  $q$insert into public.user_roles (user_id, role_id, unit_id)
     select p.id, r.id, u.id from public.profiles p, public.roles r, public.organizational_units u
      where p.email = 'aud@test.id' and r.code = 'PGW' and u.code = 'UMUM'$q$,
  'auditor/apip tidak boleh merangkap', 'SOD-8: Auditor tidak dapat merangkap role lain');
select tests.throws(
  $q$insert into public.user_roles (user_id, role_id)
     select p.id, r.id from public.profiles p, public.roles r where p.email = 'tanpa.role@test.id' and r.code = 'ATS'$q$,
  'wajib memiliki unit kerja', 'Role Atasan Unit wajib memiliki unit');
select tests.throws(
  $q$insert into public.user_roles (user_id, role_id, unit_id)
     select p.id, r.id, u.id from public.profiles p, public.roles r, public.organizational_units u
      where p.email = 'tanpa.role@test.id' and r.code = 'PGB' and u.code = 'UMUM'$q$,
  'seluruh satuan kerja', 'Role satker-wide tidak boleh diberi unit');
select tests.ok(
  tests.affected($q$insert into public.user_roles (user_id, role_id, unit_id)
     select p.id, r.id, u.id from public.profiles p, public.roles r, public.organizational_units u
      where p.email = 'tanpa.role@test.id' and r.code = 'PGW' and u.code = 'UMUM'$q$) = 1,
  'Super Admin dapat menetapkan role Pegawai kepada pengguna lain');
select tests.throws(
  $q$delete from public.user_roles where user_id = (select id from public.profiles where email = 'tanpa.role@test.id')$q$,
  'permission denied', 'Penugasan role tidak dapat dihapus (hanya dinonaktifkan)');

-- Super Admin terakhir tidak boleh dinonaktifkan (uji konteks sistem)
select tests.logout();
update public.user_roles set is_active = false
 where user_id = (select id from public.profiles where email = 'sa2@test.id');
select tests.throws(
  $q$update public.user_roles set is_active = false
      where user_id = (select id from public.profiles where email = 'sa@test.id')$q$,
  'minimal harus ada satu super admin', 'Super Admin aktif terakhir tidak dapat dinonaktifkan');

-- 7. Konteks pengguna & dashboard ---------------------------------------
select tests.login_as('ats.umum@test.id');
select tests.ok(
  (public.rpc_my_context() -> 'roles') ?& array['ATS','PGW'],
  'rpc_my_context mengembalikan role ATS & PGW untuk Atasan Umum');
select tests.ok(
  jsonb_array_length(public.rpc_my_context() -> 'scopes' -> 'ATS') = 2,
  'Lingkup Atasan Umum = unit Umum + sub-unit Rumah Tangga');
select tests.ok(
  not (public.rpc_dashboard_overview() ? 'active_users'),
  'Dashboard atasan tidak memuat statistik pengguna satker');

select tests.login_as('pws@test.id');
select tests.ok(
  public.rpc_dashboard_overview() ? 'active_users',
  'Dashboard Pejabat Pengawas memuat statistik pengguna');

-- 8. Pengaturan ---------------------------------------------------------
select tests.login_as('pgw.umum@test.id');
select tests.ok(
  tests.affected($q$update public.app_settings set value = '1' where key = 'request_confirm_days'$q$) = 0,
  'Pegawai tidak dapat mengubah pengaturan');
select tests.login_as('sa@test.id');
select tests.ok(
  tests.affected($q$update public.app_settings set value = '4' where key = 'request_confirm_days'$q$) = 1,
  'Super Admin dapat mengubah pengaturan');

-- 9. Audit trail --------------------------------------------------------
select tests.login_as('pgw.umum@test.id');
select public.rpc_log_auth_event('LOGIN');
select tests.ok(tests.visible('select * from public.audit_logs') = 0, 'Pegawai tidak dapat membaca audit trail');

select tests.login_as('aud@test.id');
select tests.ok(
  tests.visible($q$select * from public.audit_logs where action = 'LOGIN' and user_name = 'Pegawai Umum'$q$) = 1,
  'Login pegawai tercatat di audit trail');
select tests.ok(
  tests.visible($q$select * from public.audit_logs where action = 'CONFIG_CHANGE' and record_id = 'request_confirm_days'
                   and 'SA' = any(user_roles) and old_data is not null and new_data is not null$q$) = 1,
  'Perubahan konfigurasi tercatat lengkap (pelaku, role, data sebelum & sesudah)');
select tests.ok(
  tests.visible($q$select * from public.audit_logs where action = 'ROLE_CHANGE'$q$) >= 16,
  'Setiap penetapan role tercatat');
select tests.ok(
  tests.visible($q$select * from public.audit_logs where table_name = 'profiles' and action = 'UPDATE'
                   and new_data ->> 'phone' = '081234567890'$q$) = 1,
  'Perubahan profil tercatat');
select tests.ok(
  tests.visible($q$select * from public.audit_logs where table_name = 'profiles' and action = 'UPDATE'
                   and (old_data ->> 'last_login_at') is distinct from (new_data ->> 'last_login_at')
                   and (old_data - 'last_login_at' - 'updated_at' - 'updated_by') = (new_data - 'last_login_at' - 'updated_at' - 'updated_by')$q$) = 0,
  'Pembaruan last_login_at tidak menimbulkan catatan ganda');
select tests.throws('update public.audit_logs set action = $$X$$', 'permission denied', 'Auditor tidak dapat mengubah audit trail');

select tests.login_as('sa@test.id');
select tests.throws('delete from public.audit_logs', 'permission denied', 'Super Admin tidak dapat menghapus audit trail');
select tests.throws($q$update public.audit_logs set user_name = 'X'$q$, 'permission denied', 'Super Admin tidak dapat mengubah audit trail');
select tests.ok((select is_valid from public.rpc_verify_audit_chain()), 'Rantai hash audit trail valid');

select tests.logout();
select tests.throws('delete from public.audit_logs', 'bersifat permanen', 'Bahkan pemilik database ditolak trigger saat menghapus audit');
select tests.throws('truncate public.audit_logs', 'bersifat permanen', 'TRUNCATE audit trail ditolak');

-- Simulasi manipulasi oleh administrator database (trigger dimatikan)
savepoint tamper;
alter table public.audit_logs disable trigger trg_block_update_delete;
update public.audit_logs set user_name = 'Dimanipulasi' where id = (select min(id) + 2 from public.audit_logs);
alter table public.audit_logs enable trigger trg_block_update_delete;
select tests.ok(
  (select not is_valid and first_broken_id is not null from private.verify_audit_chain()),
  'Manipulasi langsung di database TERDETEKSI oleh verifikasi rantai hash');
rollback to savepoint tamper;

savepoint tamper2;
alter table public.audit_logs disable trigger trg_block_update_delete;
delete from public.audit_logs where id = (select min(id) + 3 from public.audit_logs);
alter table public.audit_logs enable trigger trg_block_update_delete;
select tests.ok(
  (select not is_valid from private.verify_audit_chain()),
  'Penghapusan satu baris di tengah audit trail TERDETEKSI');
rollback to savepoint tamper2;
select tests.ok((select is_valid from private.verify_audit_chain()), 'Rantai kembali valid setelah simulasi dibatalkan');

select tests.login_as('pgw.umum@test.id');
select tests.throws('select * from public.rpc_verify_audit_chain()', 'tidak berwenang', 'Pegawai tidak dapat memverifikasi audit');

-- 10. Fungsi internal & layanan -----------------------------------------
select tests.throws($q$select private.next_document_number('PNR')$q$, 'permission denied',
  'Pengguna aplikasi tidak dapat memanggil penomoran dokumen langsung');
select tests.throws($q$select private.bootstrap_super_admin('pgw.umum@test.id')$q$, 'permission denied',
  'Pengguna aplikasi tidak dapat memanggil bootstrap Super Admin');
select tests.throws($q$select public.rpc_service_audit(auth.uid(), 'LOGIN', 'x', 'x', null, null)$q$, 'permission denied',
  'Pengguna aplikasi tidak dapat memanggil fungsi audit layanan');
select tests.throws('select * from public.document_sequences', 'permission denied',
  'Tabel penomoran tidak dapat diakses langsung');

select tests.login_service();
select public.rpc_service_audit((select id from public.profiles where email = 'sa@test.id'),
                                'USER_CREATE', 'auth.users', 'contoh', null, '{"email":"baru@test.id"}');
select tests.logout();
select tests.ok(
  exists (select 1 from public.audit_logs where action = 'USER_CREATE' and user_name = 'Super Admin Uji'),
  'Tindakan Edge Function tercatat atas nama Super Admin peminta');

select tests.throws($q$select private.bootstrap_super_admin('pgb@test.id')$q$, 'sudah ada',
  'Bootstrap ditolak bila Super Admin aktif sudah ada');

select tests.ok(
  private.next_document_number('PNR', date '2026-11-19') = 'PNR/SATKER01/2026/11/00001'
  and private.next_document_number('PNR', date '2026-11-20') = 'PNR/SATKER01/2026/11/00002'
  and private.next_document_number('PNR', date '2026-12-01') = 'PNR/SATKER01/2026/12/00001'
  and private.next_document_number('PGL', date '2026-11-19') = 'PGL/SATKER01/2026/11/00001',
  'Penomoran dokumen berurutan per prefix & bulan');

-- 11. Notifikasi --------------------------------------------------------
insert into public.notifications (user_id, title, message)
select id, 'Uji', 'Pesan uji' from public.profiles where email in ('pgw.umum@test.id', 'pgw.rt@test.id');

select tests.login_as('pgw.umum@test.id');
select tests.ok(tests.visible('select * from public.notifications') = 1, 'Pengguna hanya melihat notifikasinya sendiri');
select tests.ok(tests.affected('update public.notifications set is_read = true') = 1, 'Pengguna dapat menandai notifikasi dibaca');
select tests.throws($q$update public.notifications set title = 'X'$q$, 'permission denied', 'Isi notifikasi tidak dapat diubah');
select tests.ok((public.rpc_dashboard_overview() ->> 'unread_notifications')::int = 0, 'Dashboard menghitung notifikasi belum dibaca');

-- 12. Master unit kerja --------------------------------------------------
select tests.throws($q$insert into public.organizational_units (code, name) values ('X','X')$q$,
  'row-level security', 'Pegawai tidak dapat menambah unit kerja');
select tests.login_as('sa@test.id');
select tests.ok(
  tests.affected($q$insert into public.organizational_units (code, name, created_by) values ('PRC','Bagian Pengadaan', gen_random_uuid())$q$) = 1,
  'Super Admin dapat menambah unit kerja');
select tests.ok(
  (select created_by = auth.uid() from public.organizational_units where code = 'PRC'),
  'created_by diisi dari sesi, nilai kiriman frontend diabaikan');

select tests.logout();
rollback;
