-- Uji hak kunci layanan (dipakai Edge Function admin-users)
begin;
select tests.login_service();
select tests.ok(tests.visible('select * from public.profiles') = 17, 'Service role dapat membaca profil');
select tests.ok(
  tests.visible($q$select ur.* from public.user_roles ur join public.roles r on r.id = ur.role_id where r.code = 'SA'$q$) >= 1,
  'Service role dapat membaca penugasan role (cek Super Admin)');
select tests.ok(
  tests.affected($q$update public.profiles set is_active = false where email = 'pgw.keu@test.id'$q$) = 1,
  'Service role dapat menonaktifkan profil');
select tests.throws($q$update public.profiles set full_name = 'X' where email = 'pgw.keu@test.id'$q$,
  'permission denied', 'Service role tidak dapat mengubah kolom profil lain');
select tests.throws($q$delete from public.profiles where email = 'pgw.keu@test.id'$q$,
  'permission denied', 'Service role tidak dapat menghapus profil');
select tests.throws('select * from public.audit_logs', 'permission denied', 'Service role tidak dapat membaca audit trail langsung');
select public.rpc_service_audit((select id from public.profiles where email = 'sa@test.id'), 'USER_CREATE', 'auth.users', 'x', null, null);
select tests.ok(true, 'Service role dapat mencatat audit melalui rpc_service_audit');
select tests.logout();
rollback;
