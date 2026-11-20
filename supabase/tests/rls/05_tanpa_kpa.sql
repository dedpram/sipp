-- =====================================================================
-- Uji perubahan 21-11-2026: role KPA dihapus dari aplikasi
-- =====================================================================
begin;
select tests.ok((select not is_active from public.roles where code = 'KPA'), 'Role KPA berstatus tidak digunakan');
select tests.ok(not exists (select 1 from public.approval_settings where approver_role_code = 'KPA' and is_active),
  'Tidak ada lagi jenjang persetujuan aktif yang memakai KPA');
select tests.ok((select approver_role_code = 'PWS' from public.approval_settings where transaction_type = 'request' and level = 2 and is_active),
  'Persetujuan permintaan di atas ambang dialihkan ke Pejabat Pengawas');

select tests.login_as('sa@test.id');
select tests.throws(
  $q$insert into public.user_roles (user_id, role_id)
     select p.id, r.id from public.profiles p, public.roles r where p.email = 'kpa@test.id' and r.code = 'KPA'$q$,
  'sudah tidak digunakan', 'Role KPA tidak dapat ditetapkan lagi');

-- Penugasan KPA lama (bila ada) tidak memberi hak apa pun.
select tests.logout();
alter table public.user_roles disable trigger trg_user_roles_guard;
insert into public.user_roles (user_id, role_id)
select p.id, r.id from public.profiles p, public.roles r where p.email = 'kpa@test.id' and r.code = 'KPA';
alter table public.user_roles enable trigger trg_user_roles_guard;
select tests.login_as('kpa@test.id');
select tests.ok(cardinality(private.my_role_codes()) = 0, 'Penugasan KPA lama tidak dihitung sebagai role');
select tests.ok(tests.visible('select * from public.receipts') = 0, 'Pemegang role KPA lama tidak dapat melihat penerimaan');
select tests.ok(tests.visible('select * from public.audit_logs') = 0, 'Pemegang role KPA lama tidak dapat melihat audit trail');
select tests.logout();

-- Petugas Akuntansi: hanya rekonsiliasi
select tests.ok((select is_active from public.roles where code = 'AKT'), 'Role Petugas Akuntansi tetap aktif');
select tests.login_as('akt@test.id');
select tests.ok(tests.visible('select * from public.receipts') = 0, 'Petugas Akuntansi tidak melihat penerimaan');
select tests.throws($q$insert into public.receipts (source_type, source_description, warehouse_id) values ('hibah', 'x', gen_random_uuid())$q$,
  'row-level security', 'Petugas Akuntansi tidak mencatat penerimaan');
select tests.ok(has_table_privilege('authenticated', 'public.stock_balances', 'select')
                and private.has_any_role(private.stock_reader_roles()),
  'Petugas Akuntansi dapat membaca saldo & nilai persediaan untuk rekonsiliasi');
select tests.ok(public.rpc_dashboard_overview() ? 'stock', 'Dashboard Petugas Akuntansi memuat nilai persediaan');
select tests.ok(not exists (select 1 from pg_proc where proname = 'rpc_receipt_verify_accounting'),
  'Langkah verifikasi akuntansi penerimaan ditiadakan');
select tests.logout();
rollback;
