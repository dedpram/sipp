-- =====================================================================
-- SIPP — Migration 0002: Identitas, role, unit kerja, konfigurasi
-- Tabel: roles, organizational_units, profiles, user_roles,
--        app_settings, approval_settings, document_sequences, notifications
-- Catatan: password TIDAK pernah disimpan di sini (dikelola Supabase Auth).
-- =====================================================================

-- ---------------------------------------------------------------------
-- roles
-- ---------------------------------------------------------------------
create table if not exists public.roles (
  id          uuid primary key default gen_random_uuid(),
  code        text not null unique check (code ~ '^[A-Z]{2,5}$'),
  name        text not null,
  description text,
  is_system   boolean not null default true,
  sort_order  integer not null default 0,
  created_at  timestamptz not null default now()
);

insert into public.roles (code, name, description, sort_order) values
  ('SA',  'Super Admin',                         'Mengelola konfigurasi, pengguna, role, dan master data', 1),
  ('KPA', 'Kepala Satuan Kerja / KPA',           'Pimpinan; persetujuan sesuai kewenangan',                2),
  ('PWS', 'Pejabat Pengawas / Koordinator',      'Pengawasan proses pengelolaan persediaan',               3),
  ('PPK', 'Pejabat Pembuat Komitmen',            'Data pengadaan, kontrak, pengesahan penerimaan pembelian',4),
  ('PPB', 'Petugas Penerima Barang',             'Pemeriksaan dan penerimaan barang',                       5),
  ('PGB', 'Pengurus Barang Persediaan',          'Pengelolaan barang masuk, simpan, keluar',                6),
  ('PGW', 'Pegawai / Unit Pemohon',              'Mengajukan permintaan barang',                            7),
  ('ATS', 'Atasan Unit',                         'Menyetujui permintaan unitnya',                           8),
  ('AKT', 'Petugas Akuntansi',                   'Nilai persediaan, rekonsiliasi, laporan akuntansi',       9),
  ('TSO', 'Tim Stock Opname',                    'Penghitungan fisik dan identifikasi selisih',             10),
  ('AUD', 'Auditor / APIP',                      'Akses baca sesuai penugasan',                             11)
on conflict (code) do nothing;

-- ---------------------------------------------------------------------
-- organizational_units (bertingkat: bagian -> subbagian)
-- ---------------------------------------------------------------------
create table if not exists public.organizational_units (
  id            uuid primary key default gen_random_uuid(),
  code          text not null unique check (length(trim(code)) > 0),
  name          text not null check (length(trim(name)) > 0),
  parent_id     uuid references public.organizational_units(id),
  head_user_id  uuid,               -- FK ke profiles ditambahkan di bawah
  is_active     boolean not null default true,
  created_at    timestamptz not null default now(),
  created_by    uuid,
  updated_at    timestamptz,
  updated_by    uuid,
  constraint organizational_units_not_self_parent check (parent_id is null or parent_id <> id)
);
create index if not exists idx_org_units_parent on public.organizational_units(parent_id);
create index if not exists idx_org_units_head   on public.organizational_units(head_user_id);

-- ---------------------------------------------------------------------
-- profiles (1:1 dengan auth.users)
-- ---------------------------------------------------------------------
create table if not exists public.profiles (
  id               uuid primary key references auth.users(id) on delete restrict,
  nip              varchar(18) unique check (nip is null or nip ~ '^[0-9]{18}$'),
  full_name        text not null check (length(trim(full_name)) > 0),
  email            text not null,
  position_title   text,
  primary_unit_id  uuid references public.organizational_units(id),
  phone            text,
  is_active        boolean not null default true,
  last_login_at    timestamptz,
  created_at       timestamptz not null default now(),
  created_by       uuid references public.profiles(id),
  updated_at       timestamptz,
  updated_by       uuid references public.profiles(id)
);
create index if not exists idx_profiles_unit on public.profiles(primary_unit_id);
create index if not exists idx_profiles_name_trgm on public.profiles using gin (full_name extensions.gin_trgm_ops);

alter table public.organizational_units
  drop constraint if exists organizational_units_head_fk,
  add  constraint organizational_units_head_fk       foreign key (head_user_id) references public.profiles(id),
  drop constraint if exists organizational_units_created_by_fk,
  add  constraint organizational_units_created_by_fk foreign key (created_by)   references public.profiles(id),
  drop constraint if exists organizational_units_updated_by_fk,
  add  constraint organizational_units_updated_by_fk foreign key (updated_by)   references public.profiles(id);

-- ---------------------------------------------------------------------
-- user_roles (penugasan role, dapat dibatasi unit & masa berlaku)
-- ---------------------------------------------------------------------
create table if not exists public.user_roles (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references public.profiles(id),
  role_id         uuid not null references public.roles(id),
  unit_id         uuid references public.organizational_units(id),
  valid_from      date not null default current_date,
  valid_until     date,
  assignment_ref  text,             -- nomor SK / surat tugas
  is_active       boolean not null default true,
  created_at      timestamptz not null default now(),
  created_by      uuid references public.profiles(id),
  updated_at      timestamptz,
  updated_by      uuid references public.profiles(id),
  constraint user_roles_valid_period check (valid_until is null or valid_until >= valid_from),
  constraint user_roles_unique unique nulls not distinct (user_id, role_id, unit_id)
);
create index if not exists idx_user_roles_user on public.user_roles(user_id) where is_active;
create index if not exists idx_user_roles_role on public.user_roles(role_id);
create index if not exists idx_user_roles_unit on public.user_roles(unit_id);

-- ---------------------------------------------------------------------
-- app_settings (konfigurasi aplikasi key-value)
-- ---------------------------------------------------------------------
create table if not exists public.app_settings (
  key          text primary key check (key ~ '^[a-z0-9_]+$'),
  value        jsonb not null,
  description  text,
  created_at   timestamptz not null default now(),
  created_by   uuid references public.profiles(id),
  updated_at   timestamptz,
  updated_by   uuid references public.profiles(id)
);

insert into public.app_settings (key, value, description) values
  ('satker_code',                '"SATKER01"'::jsonb,  'Kode satuan kerja (dipakai dalam nomor dokumen)'),
  ('satker_name',                '"Nama Satuan Kerja"'::jsonb, 'Nama satuan kerja untuk kop laporan'),
  ('timezone',                   '"Asia/Jakarta"'::jsonb, 'Zona waktu tampilan'),
  ('request_confirm_days',       '3'::jsonb,   'Batas hari kerja konfirmasi penerimaan oleh pemohon'),
  ('slow_moving_days',           '180'::jsonb, 'Barang dianggap tidak bergerak bila tidak ada mutasi keluar selama N hari'),
  ('expiry_warning_days',        '90'::jsonb,  'Peringatan kedaluwarsa N hari sebelum tanggal kedaluwarsa'),
  ('request_value_threshold',    '5000000'::jsonb, 'Permintaan dengan nilai di atas ambang ini memerlukan persetujuan pejabat (Rp)'),
  ('opname_freeze_locations',    'true'::jsonb, 'Bekukan transaksi pada lokasi yang sedang di-stock opname'),
  ('opname_blind_count_default', 'true'::jsonb, 'Blind count aktif secara default'),
  ('mfa_required_roles',         '["SA"]'::jsonb, 'Role yang wajib MFA')
on conflict (key) do nothing;

-- ---------------------------------------------------------------------
-- approval_settings (persetujuan berjenjang)
-- ---------------------------------------------------------------------
create table if not exists public.approval_settings (
  id                  uuid primary key default gen_random_uuid(),
  transaction_type    text not null check (transaction_type in
                        ('receipt','request','adjustment','damaged','write_off','opname','discrepancy','reconciliation')),
  level               integer not null check (level between 1 and 5),
  approver_role_code  text not null references public.roles(code),
  unit_scope          text not null default 'all' check (unit_scope in ('own_unit','all')),
  min_value           numeric(18,2),
  max_value           numeric(18,2),
  applies_when        jsonb not null default '{}'::jsonb,  -- mis. {"source_type":["pembelian"]}
  is_required         boolean not null default true,
  delegate_user_id    uuid references public.profiles(id),
  is_active           boolean not null default true,
  description         text,
  created_at          timestamptz not null default now(),
  created_by          uuid references public.profiles(id),
  updated_at          timestamptz,
  updated_by          uuid references public.profiles(id),
  constraint approval_settings_value_range check (min_value is null or max_value is null or min_value <= max_value),
  constraint approval_settings_unique unique (transaction_type, level, approver_role_code)
);

insert into public.approval_settings
  (transaction_type, level, approver_role_code, unit_scope, min_value, applies_when, description) values
  ('request',     1, 'ATS', 'own_unit', null,       '{}',                                         'Persetujuan atasan unit pemohon'),
  ('request',     2, 'KPA', 'all',      5000000.01, '{}',                                         'Persetujuan pejabat bila nilai permintaan di atas ambang'),
  ('receipt',     1, 'PPK', 'all',      null,       '{"source_type":["pembelian"]}',               'Pengesahan penerimaan dari pembelian'),
  ('receipt',     1, 'KPA', 'all',      null,       '{"source_type":["hibah","transfer","lainnya"]}','Pengesahan penerimaan non-pembelian'),
  ('adjustment',  1, 'KPA', 'all',      null,       '{}',                                         'Persetujuan koreksi saldo'),
  ('damaged',     1, 'KPA', 'all',      null,       '{}',                                         'Persetujuan reklasifikasi barang rusak/usang'),
  ('write_off',   1, 'KPA', 'all',      null,       '{}',                                         'Persetujuan penghapusan (wajib SK)'),
  ('opname',      1, 'KPA', 'all',      null,       '{}',                                         'Pengesahan berita acara stock opname'),
  ('discrepancy', 1, 'KPA', 'all',      null,       '{}',                                         'Penetapan tindak lanjut kasus selisih'),
  ('reconciliation', 1, 'PWS', 'all',   null,       '{}',                                         'Reviu rekonsiliasi')
on conflict (transaction_type, level, approver_role_code) do nothing;

-- ---------------------------------------------------------------------
-- document_sequences (penomoran dokumen anti-duplikat)
-- ---------------------------------------------------------------------
create table if not exists public.document_sequences (
  prefix       text not null check (prefix ~ '^[A-Z]{3}$'),
  period       text not null check (period ~ '^[0-9]{6}$'),  -- YYYYMM
  last_number  integer not null default 0 check (last_number >= 0),
  primary key (prefix, period)
);

-- ---------------------------------------------------------------------
-- notifications
-- ---------------------------------------------------------------------
create table if not exists public.notifications (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.profiles(id),
  title       text not null,
  message     text not null,
  ref_table   text,
  ref_id      uuid,
  is_read     boolean not null default false,
  created_at  timestamptz not null default now()
);
create index if not exists idx_notifications_user on public.notifications(user_id, is_read, created_at desc);

-- ---------------------------------------------------------------------
-- Trigger kolom metadata baris
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['organizational_units','profiles','user_roles','app_settings','approval_settings'] loop
    execute format('drop trigger if exists trg_row_meta on public.%I', t);
    execute format('create trigger trg_row_meta before insert or update on public.%I
                    for each row execute function private.tg_set_row_meta()', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- Profil otomatis saat akun Supabase Auth dibuat / email berubah
-- ---------------------------------------------------------------------
create or replace function private.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, email, full_name, nip, position_title, primary_unit_id)
  values (
    new.id,
    new.email,
    coalesce(nullif(trim(new.raw_user_meta_data ->> 'full_name'), ''), split_part(new.email, '@', 1)),
    nullif(trim(new.raw_user_meta_data ->> 'nip'), ''),
    nullif(trim(new.raw_user_meta_data ->> 'position_title'), ''),
    nullif(new.raw_user_meta_data ->> 'primary_unit_id', '')::uuid
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

create or replace function private.handle_auth_user_email_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.email is distinct from old.email then
    perform set_config('app.via_rpc', 'on', true);
    update public.profiles set email = new.email where id = new.id;
    perform set_config('app.via_rpc', '', true);
  end if;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function private.handle_new_auth_user();

drop trigger if exists on_auth_user_email_changed on auth.users;
create trigger on_auth_user_email_changed
  after update of email on auth.users
  for each row execute function private.handle_auth_user_email_change();

revoke all on function private.handle_new_auth_user() from public;
revoke all on function private.handle_auth_user_email_change() from public;
