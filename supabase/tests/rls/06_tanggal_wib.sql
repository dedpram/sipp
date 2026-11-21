-- =====================================================================
-- Uji perbaikan 21-11-2026: masa berlaku role memakai tanggal WIB,
-- bukan tanggal UTC server.
-- =====================================================================
begin;
set local timezone = 'UTC';
select tests.ok(private.today_jakarta() = (now() at time zone 'Asia/Jakarta')::date,
  'Tanggal hari ini dihitung menurut WIB');
select tests.ok(
  (select bool_and(pg_get_functiondef(p.oid) not ilike '%current_date%')
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'private' and p.proname in ('my_role_codes', 'my_scope_unit_ids')),
  'Pemeriksaan masa berlaku role tidak lagi memakai tanggal UTC server');
select tests.ok(
  (select column_default ilike '%Asia/Jakarta%' from information_schema.columns
    where table_schema = 'public' and table_name = 'user_roles' and column_name = 'valid_from'),
  'Tanggal mulai role bawaan = tanggal WIB');

-- Role yang berlaku mulai "hari ini (WIB)" langsung aktif, walaupun
-- tanggal UTC masih kemarin (pukul 00.00–07.00 WIB).
select tests.logout();
alter table public.user_roles disable trigger trg_user_roles_guard;
update public.user_roles ur set valid_from = private.today_jakarta()
  from public.profiles p where p.id = ur.user_id and p.email = 'ppb@test.id';
alter table public.user_roles enable trigger trg_user_roles_guard;
select tests.login_as('ppb@test.id');
select tests.ok(private.has_role('PPB'), 'Role yang mulai berlaku hari ini (WIB) langsung dikenali');
select tests.ok((public.rpc_my_context() -> 'roles') @> '"PPB"'::jsonb, 'Konteks pengguna memuat role yang mulai berlaku hari ini');
select tests.logout();

-- Role yang baru berlaku besok (WIB) belum dikenali.
alter table public.user_roles disable trigger trg_user_roles_guard;
update public.user_roles ur set valid_from = private.today_jakarta() + 1
  from public.profiles p where p.id = ur.user_id and p.email = 'ppb@test.id';
alter table public.user_roles enable trigger trg_user_roles_guard;
select tests.login_as('ppb@test.id');
select tests.ok(not private.has_role('PPB'), 'Role yang baru berlaku besok belum dikenali');
select tests.logout();
rollback;
