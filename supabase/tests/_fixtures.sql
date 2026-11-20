-- =====================================================================
-- Data uji (HANYA database uji). Dijalankan sebagai superuser sehingga
-- dianggap konteks sistem (auth.uid() = NULL).
-- =====================================================================
insert into public.organizational_units (code, name) values ('SEK', 'Sekretariat');
insert into public.organizational_units (code, name, parent_id)
  select 'UMUM', 'Bagian Umum', id from public.organizational_units where code = 'SEK';
insert into public.organizational_units (code, name, parent_id)
  select 'RT', 'Subbagian Rumah Tangga', id from public.organizational_units where code = 'UMUM';
insert into public.organizational_units (code, name, parent_id)
  select 'KEU', 'Bagian Keuangan', id from public.organizational_units where code = 'SEK';

select tests.create_user('sa@test.id',       'Super Admin Uji');
select tests.create_user('sa2@test.id',      'Super Admin Kedua');
select tests.create_user('kpa@test.id',      'Kepala Satker Uji');
select tests.create_user('pws@test.id',      'Pengawas Uji');
select tests.create_user('ppk@test.id',      'PPK Uji');
select tests.create_user('ppb@test.id',      'Penerima Barang Uji');
select tests.create_user('pgb@test.id',      'Pengurus Barang Uji');
select tests.create_user('akt@test.id',      'Akuntansi Uji');
select tests.create_user('tso@test.id',      'Tim SO Uji');
select tests.create_user('aud@test.id',      'Auditor Uji');
select tests.create_user('ats.umum@test.id', 'Atasan Umum', 'UMUM');
select tests.create_user('ats.keu@test.id',  'Atasan Keuangan', 'KEU');
select tests.create_user('pgw.umum@test.id', 'Pegawai Umum', 'UMUM');
select tests.create_user('pgw.rt@test.id',   'Pegawai Rumah Tangga', 'RT');
select tests.create_user('pgw.keu@test.id',  'Pegawai Keuangan', 'KEU');
select tests.create_user('nonaktif@test.id', 'Pegawai Nonaktif', 'UMUM');
select tests.create_user('tanpa.role@test.id', 'Tanpa Role', 'UMUM');

-- Super Admin pertama melalui fungsi bootstrap resmi.
select private.bootstrap_super_admin('sa@test.id');

-- Penetapan role lain (konteks sistem).
insert into public.user_roles (user_id, role_id, unit_id)
select p.id, r.id, u.id
from (values
  ('sa2@test.id',      'SA',  null),
  ('pws@test.id',      'PWS', null),
  ('ppk@test.id',      'PPK', null),
  ('ppb@test.id',      'PPB', null),
  ('pgb@test.id',      'PGB', null),
  ('tso@test.id',      'TSO', null),
  ('akt@test.id',      'AKT', null),
  ('aud@test.id',      'AUD', null),
  ('ats.umum@test.id', 'ATS', 'UMUM'),
  ('ats.umum@test.id', 'PGW', 'UMUM'),
  ('ats.keu@test.id',  'ATS', 'KEU'),
  ('pgw.umum@test.id', 'PGW', 'UMUM'),
  ('pgw.rt@test.id',   'PGW', 'RT'),
  ('pgw.keu@test.id',  'PGW', 'KEU'),
  ('nonaktif@test.id', 'PGW', 'UMUM')
) as v(email, code, unit)
join public.profiles p on p.email = v.email
join public.roles r on r.code = v.code
left join public.organizational_units u on u.code = v.unit;

update public.profiles set is_active = false where email = 'nonaktif@test.id';
