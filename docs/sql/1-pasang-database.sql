-- =====================================================================
-- SIPP — PEMASANGAN DATABASE FASE 2 (SEKALIGUS)
-- Cara pakai: Supabase Dashboard > SQL Editor > New query >
--             tempel SELURUH isi file ini > klik RUN.
-- Isi file ini = gabungan 5 file di supabase/migrations/ (urutan sama).
-- Aman dijalankan ulang; tidak menghapus data.
-- =====================================================================


-- >>>>> 20261119000100_fondasi_skema.sql
-- =====================================================================
-- SIPP — Migration 0001: Skema dasar & ekstensi
-- Tujuan : menyiapkan schema `private` (fungsi internal, TIDAK terekspos
--          ke API Supabase) dan ekstensi yang dibutuhkan.
-- Aman dijalankan ulang (idempotent) dan tidak menghapus data.
-- =====================================================================

create schema if not exists extensions;
create extension if not exists pg_trgm with schema extensions;

create schema if not exists private;
revoke all on schema private from public;
-- `authenticated` perlu USAGE agar policy RLS dapat memanggil fungsi helper.
-- Schema ini tidak didaftarkan di "Exposed schemas" Supabase, sehingga
-- tidak dapat dipanggil langsung melalui REST API.
grant usage on schema private to authenticated, service_role;

-- Fungsi kecil: apakah sedang berjalan dalam konteks sistem/RPC resmi?
-- * auth.uid() NULL  -> dijalankan oleh sistem (trigger auth, service role,
--                       SQL editor admin), bukan oleh pengguna aplikasi.
-- * app.via_rpc = on -> diset oleh fungsi RPC resmi selama transaksi.
create or replace function private.is_system_context()
returns boolean
language sql
stable
set search_path = ''
as $$
  select auth.uid() is null
      or coalesce(current_setting('app.via_rpc', true), '') = 'on';
$$;

-- Mengisi created_at/created_by/updated_at/updated_by secara otomatis.
-- Nilai dari frontend diabaikan agar identitas tidak dapat dipalsukan.
create or replace function private.tg_set_row_meta()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    new.created_at := now();
    new.created_by := auth.uid();
    new.updated_at := null;
    new.updated_by := null;
  else
    new.created_at := old.created_at;
    new.created_by := old.created_by;
    new.updated_at := now();
    new.updated_by := auth.uid();
  end if;
  return new;
end;
$$;

revoke all on function private.is_system_context() from public;
revoke all on function private.tg_set_row_meta() from public;
grant execute on function private.is_system_context() to authenticated, service_role;

-- >>>>> 20261119000200_identitas_organisasi.sql
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

-- >>>>> 20261119000300_audit_trail.sql
-- =====================================================================
-- SIPP — Migration 0003: Audit trail
-- * Append-only: tidak dapat diubah/dihapus melalui aplikasi (termasuk SA).
-- * Rantai hash (prev_hash -> row_hash) untuk mendeteksi manipulasi
--   langsung di database oleh pemegang akses administrator Supabase.
-- =====================================================================

create table if not exists public.audit_logs (
  id           bigint generated always as identity primary key,
  occurred_at  timestamptz not null default now(),
  user_id      uuid,
  user_name    text,
  user_roles   text[],
  action       text not null check (action ~ '^[A-Z_]+$'),
  table_name   text,
  record_id    text,
  old_data     jsonb,
  new_data     jsonb,
  ip_address   text,
  user_agent   text,
  prev_hash    text,
  row_hash     text not null
);
create index if not exists idx_audit_logs_time   on public.audit_logs(occurred_at desc);
create index if not exists idx_audit_logs_user   on public.audit_logs(user_id, occurred_at desc);
create index if not exists idx_audit_logs_record on public.audit_logs(table_name, record_id);
create index if not exists idx_audit_logs_action on public.audit_logs(action);

-- Rumus hash dipakai bersama oleh penulis & pemverifikasi.
-- SELURUH kolom isi ikut di-hash sehingga perubahan kolom mana pun terdeteksi.
create or replace function private.audit_row_hash(
  p_prev_hash text, p_occurred_at timestamptz, p_user_id uuid, p_user_name text,
  p_user_roles text[], p_action text, p_table text, p_record text,
  p_old jsonb, p_new jsonb, p_ip text, p_user_agent text)
returns text
language sql
immutable
set search_path = ''
as $$
  select encode(sha256(convert_to(jsonb_build_array(
           coalesce(p_prev_hash, 'GENESIS'),
           extract(epoch from p_occurred_at)::text,
           p_user_id, p_user_name, to_jsonb(p_user_roles), p_action,
           p_table, p_record, p_old, p_new, p_ip, p_user_agent)::text, 'UTF8')), 'hex');
$$;

-- Penulis tunggal audit log. Identitas pelaku diambil dari JWT (auth.uid()),
-- kecuali dipanggil oleh Edge Function (service role) yang menyertakan p_actor.
create or replace function private.write_audit(
  p_action text, p_table text, p_record_id text, p_old jsonb, p_new jsonb,
  p_actor uuid default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor   uuid := coalesce(auth.uid(), p_actor);
  v_name    text;
  v_roles   text[];
  v_headers jsonb;
  v_prev    text;
  v_now     timestamptz := now();
  v_ip      text;
  v_ua      text;
begin
  -- Serialisasi agar rantai hash tidak bercabang pada transaksi bersamaan.
  perform pg_advisory_xact_lock(hashtext('sipp_audit_chain'));

  if v_actor is not null then
    select p.full_name into v_name from public.profiles p where p.id = v_actor;
    select coalesce(array_agg(r.code order by r.sort_order), '{}')
      into v_roles
      from public.user_roles ur join public.roles r on r.id = ur.role_id
     where ur.user_id = v_actor and ur.is_active;
  end if;

  begin
    v_headers := nullif(current_setting('request.headers', true), '')::jsonb;
  exception when others then
    v_headers := null;
  end;

  select a.row_hash into v_prev from public.audit_logs a order by a.id desc limit 1;

  v_ip := nullif(trim(split_part(coalesce(v_headers ->> 'x-forwarded-for', v_headers ->> 'x-real-ip', ''), ',', 1)), '');
  v_ua := left(v_headers ->> 'user-agent', 300);

  insert into public.audit_logs
    (occurred_at, user_id, user_name, user_roles, action, table_name, record_id,
     old_data, new_data, ip_address, user_agent, prev_hash, row_hash)
  values
    (v_now, v_actor, v_name, v_roles, p_action, p_table, p_record_id,
     p_old, p_new, v_ip, v_ua, v_prev,
     private.audit_row_hash(v_prev, v_now, v_actor, v_name, v_roles, p_action, p_table, p_record_id,
                            p_old, p_new, v_ip, v_ua));
end;
$$;

-- Trigger generik untuk tabel yang diaudit.
create or replace function private.tg_audit_row()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_action text;
  v_ignore text[] := array['updated_at','updated_by','last_login_at'];
begin
  if tg_op = 'UPDATE' and (to_jsonb(new) - v_ignore) = (to_jsonb(old) - v_ignore) then
    return new;  -- perubahan kosmetik (mis. last_login_at) tidak dicatat ganda
  end if;

  v_action := case
    when tg_table_name = 'user_roles' then 'ROLE_CHANGE'
    when tg_table_name in ('app_settings','approval_settings') then 'CONFIG_CHANGE'
    else tg_op
  end;

  perform private.write_audit(
    v_action,
    tg_table_name,
    coalesce(to_jsonb(new) ->> 'id', to_jsonb(old) ->> 'id', to_jsonb(new) ->> 'key', to_jsonb(old) ->> 'key'),
    case when tg_op = 'INSERT' then null else to_jsonb(old) end,
    case when tg_op = 'DELETE' then null else to_jsonb(new) end);

  return coalesce(new, old);
end;
$$;

-- Blokir UPDATE/DELETE/TRUNCATE pada audit_logs.
create or replace function private.tg_block_modification()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'Data pada tabel % bersifat permanen dan tidak dapat diubah atau dihapus.', tg_table_name
    using errcode = 'P0001';
end;
$$;

drop trigger if exists trg_block_update_delete on public.audit_logs;
create trigger trg_block_update_delete before update or delete on public.audit_logs
  for each row execute function private.tg_block_modification();
drop trigger if exists trg_block_truncate on public.audit_logs;
create trigger trg_block_truncate before truncate on public.audit_logs
  for each statement execute function private.tg_block_modification();

-- Pasang trigger audit pada tabel fondasi.
do $$
declare t text;
begin
  foreach t in array array['organizational_units','profiles','user_roles','app_settings','approval_settings'] loop
    execute format('drop trigger if exists trg_audit on public.%I', t);
    execute format('create trigger trg_audit after insert or update or delete on public.%I
                    for each row execute function private.tg_audit_row()', t);
  end loop;
end $$;

-- Verifikasi rantai hash. Mengembalikan baris pertama yang rusak (bila ada).
create or replace function private.verify_audit_chain()
returns table (is_valid boolean, checked_rows bigint, first_broken_id bigint)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  r        record;
  v_prev   text := null;
  v_count  bigint := 0;
begin
  for r in select * from public.audit_logs order by id loop
    v_count := v_count + 1;
    if r.prev_hash is distinct from v_prev
       or r.row_hash is distinct from private.audit_row_hash(
            r.prev_hash, r.occurred_at, r.user_id, r.user_name, r.user_roles, r.action,
            r.table_name, r.record_id, r.old_data, r.new_data, r.ip_address, r.user_agent) then
      return query select false, v_count, r.id;
      return;
    end if;
    v_prev := r.row_hash;
  end loop;
  return query select true, v_count, null::bigint;
end;
$$;

revoke all on function private.audit_row_hash(text, timestamptz, uuid, text, text[], text, text, text, jsonb, jsonb, text, text) from public;
revoke all on function private.write_audit(text, text, text, jsonb, jsonb, uuid) from public;
revoke all on function private.tg_audit_row() from public;
revoke all on function private.tg_block_modification() from public;
revoke all on function private.verify_audit_chain() from public;

-- >>>>> 20261119000400_rls_fondasi.sql
-- =====================================================================
-- SIPP — Migration 0004: Helper RLS, pemisahan fungsi, policy fondasi
-- Prinsip: identitas & role SELALU dibaca dari database berdasarkan
-- auth.uid(); tidak pernah dipercaya dari kiriman frontend.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Helper (SECURITY DEFINER agar dapat membaca user_roles tanpa rekursi RLS)
-- ---------------------------------------------------------------------
create or replace function private.current_user_is_active()
returns boolean
language sql stable security definer set search_path = ''
as $$
  select coalesce((select p.is_active from public.profiles p where p.id = auth.uid()), false);
$$;

create or replace function private.my_role_codes()
returns text[]
language sql stable security definer set search_path = ''
as $$
  select coalesce(array_agg(distinct r.code), '{}')
    from public.user_roles ur
    join public.roles r    on r.id = ur.role_id
    join public.profiles p on p.id = ur.user_id
   where ur.user_id = auth.uid()
     and ur.is_active
     and p.is_active
     and current_date >= ur.valid_from
     and (ur.valid_until is null or current_date <= ur.valid_until);
$$;

create or replace function private.has_role(p_code text)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select p_code = any(private.my_role_codes());
$$;

create or replace function private.has_any_role(p_codes text[])
returns boolean
language sql stable security definer set search_path = ''
as $$
  select private.my_role_codes() && p_codes;
$$;

-- Unit beserta seluruh sub-unitnya.
create or replace function private.unit_with_descendants(p_unit uuid)
returns setof uuid
language sql stable security definer set search_path = ''
as $$
  with recursive tree as (
    select u.id from public.organizational_units u where u.id = p_unit
    union
    select c.id from public.organizational_units c join tree t on c.parent_id = t.id
  )
  select id from tree;
$$;

-- Unit yang menjadi lingkup role tertentu milik pengguna saat ini
-- (termasuk sub-unit). Untuk ATS juga mencakup unit yang head_user_id-nya pengguna.
create or replace function private.my_scope_unit_ids(p_code text)
returns uuid[]
language sql stable security definer set search_path = ''
as $$
  select coalesce(array_agg(distinct d), '{}')
  from (
    select private.unit_with_descendants(ur.unit_id) as d
      from public.user_roles ur
      join public.roles r on r.id = ur.role_id
     where ur.user_id = auth.uid() and r.code = p_code and ur.is_active
       and ur.unit_id is not null
       and current_date >= ur.valid_from
       and (ur.valid_until is null or current_date <= ur.valid_until)
       and private.current_user_is_active()
    union
    select private.unit_with_descendants(u.id)
      from public.organizational_units u
     where p_code = 'ATS' and u.head_user_id = auth.uid() and u.is_active
       and private.current_user_is_active()
  ) s;
$$;

do $$
declare f text;
begin
  foreach f in array array[
    'private.current_user_is_active()',
    'private.my_role_codes()',
    'private.has_role(text)',
    'private.has_any_role(text[])',
    'private.unit_with_descendants(uuid)',
    'private.my_scope_unit_ids(text)'] loop
    execute format('revoke all on function %s from public', f);
    execute format('grant execute on function %s to authenticated, service_role', f);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- Penjaga profil: pengguna biasa hanya boleh mengubah nomor telepon;
-- SA tidak dapat menonaktifkan dirinya sendiri; email hanya dari Auth.
-- ---------------------------------------------------------------------
create or replace function private.tg_profiles_guard()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if private.is_system_context() then
    return new;
  end if;

  if new.email is distinct from old.email then
    raise exception 'Email hanya dapat diubah melalui pengelolaan akun.' using errcode = '42501';
  end if;
  if new.last_login_at is distinct from old.last_login_at then
    raise exception 'Kolom last_login_at dikelola oleh sistem.' using errcode = '42501';
  end if;

  if private.has_role('SA') then
    if new.id = auth.uid() and new.is_active is distinct from old.is_active then
      raise exception 'Anda tidak dapat mengubah status aktif akun Anda sendiri.' using errcode = '42501';
    end if;
    return new;
  end if;

  -- Bukan SA: hanya diri sendiri & hanya kolom phone.
  if new.id <> auth.uid()
     or new.full_name       is distinct from old.full_name
     or new.nip             is distinct from old.nip
     or new.position_title  is distinct from old.position_title
     or new.primary_unit_id is distinct from old.primary_unit_id
     or new.is_active       is distinct from old.is_active then
    raise exception 'Anda hanya dapat mengubah nomor telepon pada profil Anda.' using errcode = '42501';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_profiles_guard on public.profiles;
create trigger trg_profiles_guard before update on public.profiles
  for each row execute function private.tg_profiles_guard();

-- ---------------------------------------------------------------------
-- Pemisahan fungsi pada penetapan role (SOD-7, SOD-8, SOD-9)
-- ---------------------------------------------------------------------
create or replace function private.tg_user_roles_guard()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_code        text;
  v_other_codes text[];
  v_active_sa   integer;
  c_conflict_sa constant text[] := array['KPA','PWS','PGB','ATS','AKT'];
begin
  select code into v_code from public.roles where id = new.role_id;

  -- SOD-9: tidak boleh mengubah role sendiri
  if auth.uid() is not null and new.user_id = auth.uid() then
    raise exception 'Anda tidak dapat mengubah role Anda sendiri.' using errcode = '42501';
  end if;

  if tg_op = 'UPDATE' and (new.user_id <> old.user_id or new.role_id <> old.role_id) then
    raise exception 'Pengguna dan role pada penugasan tidak dapat diganti; nonaktifkan lalu buat penugasan baru.'
      using errcode = '22023';
  end if;

  -- Lingkup unit
  if v_code in ('ATS','PGW') and new.unit_id is null then
    raise exception 'Role % wajib memiliki unit kerja.', v_code using errcode = '23514';
  end if;
  if v_code not in ('ATS','PGW') and new.unit_id is not null then
    raise exception 'Role % berlaku untuk seluruh satuan kerja; unit kerja harus dikosongkan.', v_code
      using errcode = '23514';
  end if;

  -- Cegah menonaktifkan Super Admin aktif terakhir
  if tg_op = 'UPDATE' and v_code = 'SA' and old.is_active and not new.is_active then
    select count(*) into v_active_sa
      from public.user_roles ur join public.roles r on r.id = ur.role_id
     where r.code = 'SA' and ur.is_active and ur.id <> new.id;
    if v_active_sa = 0 then
      raise exception 'Minimal harus ada satu Super Admin aktif.' using errcode = '23514';
    end if;
  end if;

  if not new.is_active then
    return new;
  end if;

  select coalesce(array_agg(r.code), '{}') into v_other_codes
    from public.user_roles ur join public.roles r on r.id = ur.role_id
   where ur.user_id = new.user_id and ur.is_active and ur.id <> new.id;

  -- SOD-8: Auditor tidak merangkap
  if (v_code = 'AUD' and cardinality(v_other_codes) > 0) or (v_code <> 'AUD' and 'AUD' = any(v_other_codes)) then
    raise exception 'Auditor/APIP tidak boleh merangkap role lain (pemisahan fungsi).' using errcode = '23514';
  end if;

  -- SOD-7: Super Admin tidak merangkap role operasional/penyetuju
  if (v_code = 'SA' and v_other_codes && c_conflict_sa)
     or (v_code = any(c_conflict_sa) and 'SA' = any(v_other_codes)) then
    raise exception 'Super Admin tidak boleh merangkap role KPA, PWS, PGB, ATS, atau AKT (pemisahan fungsi).'
      using errcode = '23514';
  end if;

  return new;
end;
$$;

drop trigger if exists trg_user_roles_guard on public.user_roles;
create trigger trg_user_roles_guard before insert or update on public.user_roles
  for each row execute function private.tg_user_roles_guard();

revoke all on function private.tg_profiles_guard() from public;
revoke all on function private.tg_user_roles_guard() from public;

-- ---------------------------------------------------------------------
-- Aktifkan RLS & atur hak dasar
-- ---------------------------------------------------------------------
alter table public.roles                enable row level security;
alter table public.organizational_units enable row level security;
alter table public.profiles             enable row level security;
alter table public.user_roles           enable row level security;
alter table public.app_settings         enable row level security;
alter table public.approval_settings    enable row level security;
alter table public.document_sequences   enable row level security;
alter table public.notifications        enable row level security;
alter table public.audit_logs           enable row level security;

-- Pengguna yang belum login tidak mendapat akses apa pun.
revoke all on all tables in schema public from anon;
revoke all on all sequences in schema public from anon;

revoke all on public.roles, public.organizational_units, public.profiles, public.user_roles,
              public.app_settings, public.approval_settings, public.document_sequences,
              public.notifications, public.audit_logs
  from authenticated;

grant select                 on public.roles                to authenticated;
grant select, insert, update on public.organizational_units to authenticated;
grant select, update         on public.profiles             to authenticated;
grant select, insert, update on public.user_roles           to authenticated;
grant select, insert, update on public.app_settings         to authenticated;
grant select, insert, update on public.approval_settings    to authenticated;
grant select                 on public.notifications        to authenticated;
grant update (is_read)       on public.notifications        to authenticated;
grant select                 on public.audit_logs           to authenticated;
-- document_sequences: tidak ada akses langsung (hanya via fungsi).

-- ---------------------------------------------------------------------
-- Policy
-- ---------------------------------------------------------------------
-- roles
drop policy if exists roles_select on public.roles;
create policy roles_select on public.roles for select to authenticated
  using ((select private.current_user_is_active()));

-- organizational_units (master: dibaca semua pengguna aktif; diubah SA)
drop policy if exists org_units_select on public.organizational_units;
create policy org_units_select on public.organizational_units for select to authenticated
  using ((select private.current_user_is_active()));
drop policy if exists org_units_insert on public.organizational_units;
create policy org_units_insert on public.organizational_units for insert to authenticated
  with check ((select private.has_role('SA')));
drop policy if exists org_units_update on public.organizational_units;
create policy org_units_update on public.organizational_units for update to authenticated
  using ((select private.has_role('SA'))) with check ((select private.has_role('SA')));

-- profiles
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select to authenticated
  using (
    (select private.current_user_is_active())
    and (
      id = (select auth.uid())
      or (select private.has_any_role(array['SA','KPA','PWS','AUD','PGB','AKT']))
      or primary_unit_id = any(((select private.my_scope_unit_ids('ATS')))::uuid[])
    )
  );
drop policy if exists profiles_update on public.profiles;
create policy profiles_update on public.profiles for update to authenticated
  using ((select private.current_user_is_active()) and (id = (select auth.uid()) or (select private.has_role('SA'))))
  with check ((select private.current_user_is_active()) and (id = (select auth.uid()) or (select private.has_role('SA'))));

-- user_roles
drop policy if exists user_roles_select on public.user_roles;
create policy user_roles_select on public.user_roles for select to authenticated
  using (
    (select private.current_user_is_active())
    and (user_id = (select auth.uid()) or (select private.has_any_role(array['SA','KPA','AUD'])))
  );
drop policy if exists user_roles_insert on public.user_roles;
create policy user_roles_insert on public.user_roles for insert to authenticated
  with check ((select private.has_role('SA')));
drop policy if exists user_roles_update on public.user_roles;
create policy user_roles_update on public.user_roles for update to authenticated
  using ((select private.has_role('SA'))) with check ((select private.has_role('SA')));

-- app_settings & approval_settings
drop policy if exists app_settings_select on public.app_settings;
create policy app_settings_select on public.app_settings for select to authenticated
  using ((select private.current_user_is_active()));
drop policy if exists app_settings_insert on public.app_settings;
create policy app_settings_insert on public.app_settings for insert to authenticated
  with check ((select private.has_role('SA')));
drop policy if exists app_settings_update on public.app_settings;
create policy app_settings_update on public.app_settings for update to authenticated
  using ((select private.has_role('SA'))) with check ((select private.has_role('SA')));

drop policy if exists approval_settings_select on public.approval_settings;
create policy approval_settings_select on public.approval_settings for select to authenticated
  using ((select private.current_user_is_active()));
drop policy if exists approval_settings_insert on public.approval_settings;
create policy approval_settings_insert on public.approval_settings for insert to authenticated
  with check ((select private.has_role('SA')));
drop policy if exists approval_settings_update on public.approval_settings;
create policy approval_settings_update on public.approval_settings for update to authenticated
  using ((select private.has_role('SA'))) with check ((select private.has_role('SA')));

-- notifications (milik sendiri)
drop policy if exists notifications_select on public.notifications;
create policy notifications_select on public.notifications for select to authenticated
  using ((select private.current_user_is_active()) and user_id = (select auth.uid()));
drop policy if exists notifications_update on public.notifications;
create policy notifications_update on public.notifications for update to authenticated
  using ((select private.current_user_is_active()) and user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

-- audit_logs (baca saja: SA, KPA, PWS, AUD)
drop policy if exists audit_logs_select on public.audit_logs;
create policy audit_logs_select on public.audit_logs for select to authenticated
  using ((select private.has_any_role(array['SA','KPA','PWS','AUD'])));

-- document_sequences: RLS aktif tanpa policy = tertutup.

-- >>>>> 20261119000500_rpc_fondasi.sql
-- =====================================================================
-- SIPP — Migration 0005: Fungsi RPC fondasi
-- * rpc_log_auth_event       : catat LOGIN / LOGOUT
-- * rpc_my_context           : profil + role + unit lingkup pengguna aktif
-- * rpc_dashboard_overview   : ringkasan dashboard awal sesuai role
-- * rpc_verify_audit_chain   : verifikasi integritas audit trail
-- * rpc_service_audit        : khusus Edge Function (service role)
-- * private.next_document_number : penomoran dokumen anti-duplikat
-- * private.bootstrap_super_admin: menetapkan Super Admin pertama (SQL Editor)
-- =====================================================================

-- ---------------------------------------------------------------------
create or replace function public.rpc_log_auth_event(p_event text)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'Sesi tidak valid.' using errcode = '42501';
  end if;
  if p_event not in ('LOGIN','LOGOUT') then
    raise exception 'Jenis kejadian tidak dikenal.' using errcode = '22023';
  end if;

  if p_event = 'LOGIN' then
    perform set_config('app.via_rpc', 'on', true);
    update public.profiles set last_login_at = now() where id = auth.uid();
    perform set_config('app.via_rpc', '', true);
  end if;

  perform private.write_audit(p_event, 'auth', auth.uid()::text, null, null);
end;
$$;

-- ---------------------------------------------------------------------
create or replace function public.rpc_my_context()
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare v jsonb;
begin
  if auth.uid() is null then
    raise exception 'Sesi tidak valid.' using errcode = '42501';
  end if;

  select jsonb_build_object(
    'profile', jsonb_build_object(
        'id', p.id, 'full_name', p.full_name, 'email', p.email, 'nip', p.nip,
        'position_title', p.position_title, 'phone', p.phone, 'is_active', p.is_active,
        'primary_unit_id', p.primary_unit_id, 'primary_unit_name', u.name),
    'roles', to_jsonb(private.my_role_codes()),
    'scopes', jsonb_build_object(
        'ATS', to_jsonb(private.my_scope_unit_ids('ATS')),
        'PGW', to_jsonb(private.my_scope_unit_ids('PGW'))))
  into v
  from public.profiles p
  left join public.organizational_units u on u.id = p.primary_unit_id
  where p.id = auth.uid();

  if v is null then
    raise exception 'Profil pengguna belum tersedia. Hubungi Super Admin.' using errcode = 'P0002';
  end if;
  if not (v -> 'profile' ->> 'is_active')::boolean then
    raise exception 'Akun Anda nonaktif. Hubungi Super Admin.' using errcode = '42501';
  end if;
  return v;
end;
$$;

-- ---------------------------------------------------------------------
-- Dashboard awal. Indikator persediaan (nilai, stok minimum, dll.) akan
-- ditambahkan pada Fase 4–6 ketika tabel transaksi tersedia.
create or replace function public.rpc_dashboard_overview()
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_roles   text[] := private.my_role_codes();
  v_result  jsonb;
begin
  if auth.uid() is null or not private.current_user_is_active() then
    raise exception 'Sesi tidak valid atau akun nonaktif.' using errcode = '42501';
  end if;

  v_result := jsonb_build_object(
    'roles', to_jsonb(v_roles),
    'unread_notifications',
      (select count(*) from public.notifications n where n.user_id = auth.uid() and not n.is_read),
    'active_units',
      (select count(*) from public.organizational_units where is_active),
    'generated_at', now());

  if v_roles && array['SA','KPA','PWS','AUD'] then
    v_result := v_result || jsonb_build_object(
      'active_users',   (select count(*) from public.profiles where is_active),
      'inactive_users', (select count(*) from public.profiles where not is_active),
      'users_without_role',
        (select count(*) from public.profiles p
          where p.is_active and not exists
            (select 1 from public.user_roles ur where ur.user_id = p.id and ur.is_active)),
      'audit_events_today',
        (select count(*) from public.audit_logs
          where occurred_at >= (date_trunc('day', now() at time zone 'Asia/Jakarta') at time zone 'Asia/Jakarta')));
  end if;

  if v_roles && array['SA','KPA','PWS','AUD'] then
    v_result := v_result || jsonb_build_object('recent_activity',
      coalesce((select jsonb_agg(x order by x.occurred_at desc) from (
          select a.occurred_at, a.user_name, a.action, a.table_name
            from public.audit_logs a order by a.id desc limit 10) x), '[]'::jsonb));
  end if;

  return v_result;
end;
$$;

-- ---------------------------------------------------------------------
create or replace function public.rpc_verify_audit_chain()
returns table (is_valid boolean, checked_rows bigint, first_broken_id bigint)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not private.has_any_role(array['SA','KPA','PWS','AUD']) then
    raise exception 'Anda tidak berwenang memverifikasi audit trail.' using errcode = '42501';
  end if;
  return query select * from private.verify_audit_chain();
end;
$$;

-- ---------------------------------------------------------------------
-- Dipanggil Edge Function `admin-users` (service role) untuk mencatat
-- tindakan pengelolaan akun atas nama Super Admin yang memintanya.
create or replace function public.rpc_service_audit(
  p_actor uuid, p_action text, p_table text, p_record_id text, p_old jsonb, p_new jsonb)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if auth.uid() is not null then
    raise exception 'Fungsi ini hanya untuk layanan sistem.' using errcode = '42501';
  end if;
  perform private.write_audit(p_action, p_table, p_record_id, p_old, p_new, p_actor);
end;
$$;

-- ---------------------------------------------------------------------
-- Penomoran dokumen: {PREFIX}/{KODE_SATKER}/{YYYY}/{MM}/{00001}
create or replace function private.next_document_number(p_prefix text, p_date date default null)
returns text
language plpgsql security definer set search_path = ''
as $$
declare
  v_date   date := coalesce(p_date, (now() at time zone 'Asia/Jakarta')::date);
  v_period text := to_char(v_date, 'YYYYMM');
  v_satker text;
  v_no     integer;
begin
  if p_prefix !~ '^[A-Z]{3}$' then
    raise exception 'Prefix dokumen tidak valid: %', p_prefix using errcode = '22023';
  end if;

  insert into public.document_sequences as s (prefix, period, last_number)
  values (p_prefix, v_period, 1)
  on conflict (prefix, period) do update set last_number = s.last_number + 1
  returning s.last_number into v_no;

  select value #>> '{}' into v_satker from public.app_settings where key = 'satker_code';

  return format('%s/%s/%s/%s/%s', p_prefix, coalesce(v_satker, 'SATKER'),
                to_char(v_date, 'YYYY'), to_char(v_date, 'MM'), lpad(v_no::text, 5, '0'));
end;
$$;

-- ---------------------------------------------------------------------
-- Menetapkan Super Admin PERTAMA. Hanya dapat dijalankan dari SQL Editor
-- Supabase (bukan dari aplikasi) dan hanya bila belum ada SA aktif.
create or replace function private.bootstrap_super_admin(p_email text)
returns text
language plpgsql security definer set search_path = ''
as $$
declare
  v_user uuid;
  v_role uuid;
begin
  if auth.uid() is not null then
    raise exception 'Jalankan fungsi ini dari SQL Editor Supabase.' using errcode = '42501';
  end if;
  if exists (select 1 from public.user_roles ur join public.roles r on r.id = ur.role_id
              where r.code = 'SA' and ur.is_active) then
    raise exception 'Super Admin aktif sudah ada. Gunakan menu Pengguna dan Role.' using errcode = '23505';
  end if;

  select id into v_user from public.profiles where lower(email) = lower(trim(p_email));
  if v_user is null then
    raise exception 'Akun dengan email % belum ada. Buat dulu di Authentication > Users.', p_email
      using errcode = 'P0002';
  end if;

  select id into v_role from public.roles where code = 'SA';
  insert into public.user_roles (user_id, role_id, assignment_ref)
  values (v_user, v_role, 'Bootstrap awal aplikasi');

  perform private.write_audit('ROLE_CHANGE', 'bootstrap', v_user::text, null,
                              jsonb_build_object('role', 'SA', 'email', p_email));
  return 'Super Admin berhasil ditetapkan untuk ' || p_email;
end;
$$;

-- ---------------------------------------------------------------------
-- Hak eksekusi
-- ---------------------------------------------------------------------
revoke all on function public.rpc_log_auth_event(text)       from public, anon;
revoke all on function public.rpc_my_context()                from public, anon;
revoke all on function public.rpc_dashboard_overview()        from public, anon;
revoke all on function public.rpc_verify_audit_chain()        from public, anon;
revoke all on function public.rpc_service_audit(uuid, text, text, text, jsonb, jsonb) from public, anon, authenticated;
revoke all on function private.next_document_number(text, date) from public;
revoke all on function private.bootstrap_super_admin(text)    from public;

grant execute on function public.rpc_log_auth_event(text)     to authenticated;
grant execute on function public.rpc_my_context()             to authenticated;
grant execute on function public.rpc_dashboard_overview()     to authenticated;
grant execute on function public.rpc_verify_audit_chain()     to authenticated;
grant execute on function public.rpc_service_audit(uuid, text, text, text, jsonb, jsonb) to service_role;

-- >>>>> 20261120000600_hak_service_role.sql
-- =====================================================================
-- SIPP — Migration 0006: Hak minimum untuk kunci layanan (service role)
-- Proyek Supabase baru tidak lagi memberi hak otomatis kepada service_role
-- atas tabel yang dibuat lewat SQL. Edge Function `admin-users` memerlukan:
--   * membaca profil, role, dan penugasan role pemanggil (cek Super Admin)
--   * mengubah status aktif profil (aktif/nonaktif akun)
-- Hak diberikan seminimal mungkin (tidak ada DELETE, tidak ada akses audit).
-- =====================================================================
grant usage on schema public to service_role;
grant select on public.profiles, public.roles, public.user_roles to service_role;
grant update (is_active) on public.profiles to service_role;

-- >>>>> 20261121000700_master_data.sql
-- =====================================================================
-- SIPP — Migration 0007: Master data
-- Tabel: item_categories, item_units, items, warehouses,
--        storage_locations, suppliers
-- Prinsip: tidak ada DELETE (nonaktifkan saja); semua perubahan diaudit.
-- Barang baru yang diusulkan Pengurus Barang berstatus nonaktif sampai
-- diaktifkan Super Admin (pemisahan fungsi).
-- =====================================================================

-- ---------------------------------------------------------------------
-- Kategori barang
-- ---------------------------------------------------------------------
create table if not exists public.item_categories (
  id            uuid primary key default gen_random_uuid(),
  code          text not null unique check (code ~ '^[A-Z0-9]{2,10}$'),
  name          text not null unique check (length(trim(name)) > 0),
  account_code  text check (account_code is null or account_code ~ '^[0-9.]{3,20}$'),
  description   text,
  is_active     boolean not null default true,
  created_at    timestamptz not null default now(),
  created_by    uuid references public.profiles(id),
  updated_at    timestamptz,
  updated_by    uuid references public.profiles(id)
);

insert into public.item_categories (code, name, description) values
  ('ATK', 'Alat Tulis Kantor',             'Kertas, alat tulis, map, dan sejenisnya'),
  ('CTK', 'Barang Cetakan',                'Formulir, blanko, buku, dan barang cetakan lain'),
  ('KMP', 'Bahan Komputer',                'Tinta/toner, media penyimpanan, aksesori komputer habis pakai'),
  ('KBR', 'Perlengkapan Kebersihan',       'Bahan dan alat kebersihan'),
  ('RTG', 'Perlengkapan Rumah Tangga',     'Perlengkapan rumah tangga kantor'),
  ('PML', 'Bahan Pemeliharaan',            'Suku cadang dan bahan pemeliharaan'),
  ('BHP', 'Barang Habis Pakai Lainnya',    'Barang habis pakai yang tidak termasuk kategori lain')
on conflict (code) do nothing;

-- ---------------------------------------------------------------------
-- Satuan barang
-- ---------------------------------------------------------------------
create table if not exists public.item_units (
  id          uuid primary key default gen_random_uuid(),
  code        text not null unique check (code ~ '^[A-Z]{2,6}$'),
  name        text not null unique check (length(trim(name)) > 0),
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  created_by  uuid references public.profiles(id),
  updated_at  timestamptz,
  updated_by  uuid references public.profiles(id)
);

insert into public.item_units (code, name) values
  ('PCS', 'Buah'), ('RIM', 'Rim'), ('BOX', 'Kotak'), ('PAK', 'Pak'), ('LSN', 'Lusin'),
  ('LBR', 'Lembar'), ('BTL', 'Botol'), ('LTR', 'Liter'), ('KG', 'Kilogram'), ('ROL', 'Rol'),
  ('SET', 'Set'), ('UNIT', 'Unit'), ('DUS', 'Dus'), ('BKS', 'Bungkus'), ('TUBE', 'Tube'),
  ('GLN', 'Galon'), ('PSG', 'Pasang'), ('BUKU', 'Buku')
on conflict (code) do nothing;

-- ---------------------------------------------------------------------
-- Barang
-- ---------------------------------------------------------------------
create table if not exists public.items (
  id             uuid primary key default gen_random_uuid(),
  code           text not null unique check (code ~ '^[A-Z0-9][A-Z0-9.\-]{1,29}$'),
  name           text not null check (length(trim(name)) > 1),
  category_id    uuid not null references public.item_categories(id),
  unit_id        uuid not null references public.item_units(id),
  specification  text,
  brand          text,
  min_stock      numeric(14,3) not null default 0 check (min_stock >= 0),
  safety_stock   numeric(14,3) not null default 0 check (safety_stock >= 0),
  max_stock      numeric(14,3) check (max_stock is null or max_stock > 0),
  has_expiry     boolean not null default false,
  is_active      boolean not null default false,
  activated_at   timestamptz,          -- pertama kali diaktifkan Super Admin
  activated_by   uuid references public.profiles(id),
  created_at     timestamptz not null default now(),
  created_by     uuid references public.profiles(id),
  updated_at     timestamptz,
  updated_by     uuid references public.profiles(id),
  constraint items_stock_levels check (
    max_stock is null or (min_stock <= max_stock and safety_stock <= max_stock))
);
create index if not exists idx_items_category on public.items(category_id);
create index if not exists idx_items_unit     on public.items(unit_id);
create index if not exists idx_items_active   on public.items(is_active);
create index if not exists idx_items_name_trgm on public.items using gin (name extensions.gin_trgm_ops);
create index if not exists idx_items_code_trgm on public.items using gin (code extensions.gin_trgm_ops);

-- ---------------------------------------------------------------------
-- Gudang & lokasi penyimpanan
-- ---------------------------------------------------------------------
create table if not exists public.warehouses (
  id           uuid primary key default gen_random_uuid(),
  code         text not null unique check (code ~ '^[A-Z0-9\-]{2,10}$'),
  name         text not null check (length(trim(name)) > 0),
  address      text,
  pic_user_id  uuid references public.profiles(id),
  is_active    boolean not null default true,
  created_at   timestamptz not null default now(),
  created_by   uuid references public.profiles(id),
  updated_at   timestamptz,
  updated_by   uuid references public.profiles(id)
);

create table if not exists public.storage_locations (
  id               uuid primary key default gen_random_uuid(),
  warehouse_id     uuid not null references public.warehouses(id),
  room             text not null check (length(trim(room)) > 0),
  rack             text not null default '-',
  location_number  text not null default '-',
  code             text not null unique check (code ~ '^[A-Z0-9][A-Z0-9.\-]{1,39}$'),
  description      text,
  is_active        boolean not null default true,
  created_at       timestamptz not null default now(),
  created_by       uuid references public.profiles(id),
  updated_at       timestamptz,
  updated_by       uuid references public.profiles(id),
  constraint storage_locations_unique_position unique (warehouse_id, room, rack, location_number)
);
create index if not exists idx_storage_locations_wh on public.storage_locations(warehouse_id);

-- ---------------------------------------------------------------------
-- Penyedia
-- ---------------------------------------------------------------------
create table if not exists public.suppliers (
  id              uuid primary key default gen_random_uuid(),
  name            text not null check (length(trim(name)) > 1),
  npwp            text unique check (npwp is null or npwp ~ '^[0-9]{15,16}$'),
  address         text,
  phone           text,
  email           text check (email is null or email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  contact_person  text,
  is_active       boolean not null default true,
  created_at      timestamptz not null default now(),
  created_by      uuid references public.profiles(id),
  updated_at      timestamptz,
  updated_by      uuid references public.profiles(id)
);
create index if not exists idx_suppliers_name_trgm on public.suppliers using gin (name extensions.gin_trgm_ops);

-- ---------------------------------------------------------------------
-- Trigger metadata baris & audit
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['item_categories','item_units','items','warehouses','storage_locations','suppliers'] loop
    execute format('drop trigger if exists trg_row_meta on public.%I', t);
    execute format('create trigger trg_row_meta before insert or update on public.%I
                    for each row execute function private.tg_set_row_meta()', t);
    execute format('drop trigger if exists trg_audit on public.%I', t);
    execute format('create trigger trg_audit after insert or update or delete on public.%I
                    for each row execute function private.tg_audit_row()', t);
  end loop;
end $$;

-- Normalisasi kode menjadi huruf besar tanpa spasi tepi.
create or replace function private.tg_upper_code()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.code := upper(trim(new.code));
  return new;
end;
$$;
revoke all on function private.tg_upper_code() from public;

do $$
declare t text;
begin
  foreach t in array array['item_categories','item_units','items','warehouses','storage_locations'] loop
    execute format('drop trigger if exists trg_upper_code on public.%I', t);
    execute format('create trigger trg_upper_code before insert or update of code on public.%I
                    for each row execute function private.tg_upper_code()', t);
  end loop;
end $$;

-- >>>>> 20261121000800_rls_master_mfa.sql
-- =====================================================================
-- SIPP — Migration 0008: RLS master data & verifikasi dua langkah (MFA)
-- * Tindakan Super Admin (mengubah pengguna, role, pengaturan, master)
--   mewajibkan sesi terverifikasi dua langkah (aal2) bila role SA
--   tercantum di pengaturan `mfa_required_roles` (default: ya).
-- * Membaca data tetap boleh tanpa MFA, sehingga SA dapat masuk dan
--   mengaktifkan MFA di menu Profil Saya.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Helper MFA
-- ---------------------------------------------------------------------
create or replace function private.mfa_satisfied()
returns boolean
language sql stable set search_path = ''
as $$
  select coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'aal', 'aal1') = 'aal2';
$$;

create or replace function private.role_requires_mfa(p_code text)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.app_settings s,
           jsonb_array_elements_text(case when jsonb_typeof(s.value) = 'array' then s.value else '[]'::jsonb end) r
     where s.key = 'mfa_required_roles' and r = p_code);
$$;

-- Super Admin yang sah untuk melakukan perubahan.
create or replace function private.is_admin_verified()
returns boolean
language sql stable security definer set search_path = ''
as $$
  select private.has_role('SA') and (not private.role_requires_mfa('SA') or private.mfa_satisfied());
$$;

do $$
declare f text;
begin
  foreach f in array array['private.mfa_satisfied()','private.role_requires_mfa(text)','private.is_admin_verified()'] loop
    execute format('revoke all on function %s from public', f);
    execute format('grant execute on function %s to authenticated, service_role', f);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- Perketat policy Super Admin yang sudah ada (Fase 2)
-- ---------------------------------------------------------------------
drop policy if exists org_units_insert on public.organizational_units;
create policy org_units_insert on public.organizational_units for insert to authenticated
  with check ((select private.is_admin_verified()));
drop policy if exists org_units_update on public.organizational_units;
create policy org_units_update on public.organizational_units for update to authenticated
  using ((select private.is_admin_verified())) with check ((select private.is_admin_verified()));

drop policy if exists user_roles_insert on public.user_roles;
create policy user_roles_insert on public.user_roles for insert to authenticated
  with check ((select private.is_admin_verified()));
drop policy if exists user_roles_update on public.user_roles;
create policy user_roles_update on public.user_roles for update to authenticated
  using ((select private.is_admin_verified())) with check ((select private.is_admin_verified()));

drop policy if exists app_settings_insert on public.app_settings;
create policy app_settings_insert on public.app_settings for insert to authenticated
  with check ((select private.is_admin_verified()));
drop policy if exists app_settings_update on public.app_settings;
create policy app_settings_update on public.app_settings for update to authenticated
  using ((select private.is_admin_verified())) with check ((select private.is_admin_verified()));

drop policy if exists approval_settings_insert on public.approval_settings;
create policy approval_settings_insert on public.approval_settings for insert to authenticated
  with check ((select private.is_admin_verified()));
drop policy if exists approval_settings_update on public.approval_settings;
create policy approval_settings_update on public.approval_settings for update to authenticated
  using ((select private.is_admin_verified())) with check ((select private.is_admin_verified()));

-- Profil: Super Admin hanya berhak penuh bila terverifikasi dua langkah.
create or replace function private.tg_profiles_guard()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if private.is_system_context() then
    return new;
  end if;

  if new.email is distinct from old.email then
    raise exception 'Email hanya dapat diubah melalui pengelolaan akun.' using errcode = '42501';
  end if;
  if new.last_login_at is distinct from old.last_login_at then
    raise exception 'Kolom last_login_at dikelola oleh sistem.' using errcode = '42501';
  end if;

  if private.is_admin_verified() then
    if new.id = auth.uid() and new.is_active is distinct from old.is_active then
      raise exception 'Anda tidak dapat mengubah status aktif akun Anda sendiri.' using errcode = '42501';
    end if;
    return new;
  end if;

  if new.id <> auth.uid() and private.has_role('SA') then
    raise exception 'Aktifkan dan gunakan verifikasi dua langkah (menu Profil Saya) untuk mengubah data pengguna.'
      using errcode = '42501';
  end if;

  if new.id <> auth.uid()
     or new.full_name       is distinct from old.full_name
     or new.nip             is distinct from old.nip
     or new.position_title  is distinct from old.position_title
     or new.primary_unit_id is distinct from old.primary_unit_id
     or new.is_active       is distinct from old.is_active then
    raise exception 'Anda hanya dapat mengubah nomor telepon pada profil Anda.' using errcode = '42501';
  end if;
  return new;
end;
$$;

-- ---------------------------------------------------------------------
-- Penjaga barang: usulan Pengurus Barang selalu nonaktif;
-- hanya Super Admin (terverifikasi) yang mengaktifkan/menonaktifkan.
-- ---------------------------------------------------------------------
create or replace function private.tg_items_guard()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  -- Kolom aktivasi tidak dapat diisi langsung.
  if tg_op = 'INSERT' then
    new.activated_at := null;
    new.activated_by := null;
  else
    new.activated_at := old.activated_at;
    new.activated_by := old.activated_by;
  end if;

  if private.is_system_context() or private.is_admin_verified() then
    if new.is_active and new.activated_at is null then
      new.activated_at := now();
      new.activated_by := auth.uid();
    end if;
    return new;
  end if;

  if tg_op = 'INSERT' then
    new.is_active := false;   -- usulan Pengurus Barang
  elsif new.is_active is distinct from old.is_active then
    raise exception 'Hanya Super Admin yang dapat mengaktifkan atau menonaktifkan barang.' using errcode = '42501';
  end if;
  return new;
end;
$$;
revoke all on function private.tg_items_guard() from public;

drop trigger if exists trg_items_guard on public.items;
create trigger trg_items_guard before insert or update on public.items
  for each row execute function private.tg_items_guard();

-- ---------------------------------------------------------------------
-- RLS master data
-- ---------------------------------------------------------------------
alter table public.item_categories   enable row level security;
alter table public.item_units        enable row level security;
alter table public.items             enable row level security;
alter table public.warehouses        enable row level security;
alter table public.storage_locations enable row level security;
alter table public.suppliers         enable row level security;

revoke all on public.item_categories, public.item_units, public.items, public.warehouses,
              public.storage_locations, public.suppliers from anon, authenticated;
grant select, insert, update on public.item_categories, public.item_units, public.items, public.warehouses,
              public.storage_locations, public.suppliers to authenticated;

-- Kategori & satuan: semua pengguna aktif membaca; SA mengubah.
drop policy if exists item_categories_select on public.item_categories;
create policy item_categories_select on public.item_categories for select to authenticated
  using ((select private.current_user_is_active()));
drop policy if exists item_categories_insert on public.item_categories;
create policy item_categories_insert on public.item_categories for insert to authenticated
  with check ((select private.is_admin_verified()));
drop policy if exists item_categories_update on public.item_categories;
create policy item_categories_update on public.item_categories for update to authenticated
  using ((select private.is_admin_verified())) with check ((select private.is_admin_verified()));

drop policy if exists item_units_select on public.item_units;
create policy item_units_select on public.item_units for select to authenticated
  using ((select private.current_user_is_active()));
drop policy if exists item_units_insert on public.item_units;
create policy item_units_insert on public.item_units for insert to authenticated
  with check ((select private.is_admin_verified()));
drop policy if exists item_units_update on public.item_units;
create policy item_units_update on public.item_units for update to authenticated
  using ((select private.is_admin_verified())) with check ((select private.is_admin_verified()));

-- Barang: semua pengguna aktif membaca (pegawai perlu memilih barang);
-- SA dan Pengurus Barang menambah/mengubah.
drop policy if exists items_select on public.items;
create policy items_select on public.items for select to authenticated
  using ((select private.current_user_is_active()));
drop policy if exists items_insert on public.items;
create policy items_insert on public.items for insert to authenticated
  with check ((select private.is_admin_verified()) or (select private.has_role('PGB')));
drop policy if exists items_update on public.items;
create policy items_update on public.items for update to authenticated
  using ((select private.is_admin_verified()) or (select private.has_role('PGB')))
  with check ((select private.is_admin_verified()) or (select private.has_role('PGB')));

-- Gudang & lokasi: dibaca fungsi persediaan; diubah SA & Pengurus Barang.
drop policy if exists warehouses_select on public.warehouses;
create policy warehouses_select on public.warehouses for select to authenticated
  using ((select private.has_any_role(array['SA','KPA','PWS','PPK','PPB','PGB','AKT','TSO','AUD'])));
drop policy if exists warehouses_insert on public.warehouses;
create policy warehouses_insert on public.warehouses for insert to authenticated
  with check ((select private.is_admin_verified()) or (select private.has_role('PGB')));
drop policy if exists warehouses_update on public.warehouses;
create policy warehouses_update on public.warehouses for update to authenticated
  using ((select private.is_admin_verified()) or (select private.has_role('PGB')))
  with check ((select private.is_admin_verified()) or (select private.has_role('PGB')));

drop policy if exists storage_locations_select on public.storage_locations;
create policy storage_locations_select on public.storage_locations for select to authenticated
  using ((select private.has_any_role(array['SA','KPA','PWS','PPK','PPB','PGB','AKT','TSO','AUD'])));
drop policy if exists storage_locations_insert on public.storage_locations;
create policy storage_locations_insert on public.storage_locations for insert to authenticated
  with check ((select private.is_admin_verified()) or (select private.has_role('PGB')));
drop policy if exists storage_locations_update on public.storage_locations;
create policy storage_locations_update on public.storage_locations for update to authenticated
  using ((select private.is_admin_verified()) or (select private.has_role('PGB')))
  with check ((select private.is_admin_verified()) or (select private.has_role('PGB')));

-- Penyedia: dibaca fungsi pengadaan/persediaan/akuntansi; diubah SA & PPK.
drop policy if exists suppliers_select on public.suppliers;
create policy suppliers_select on public.suppliers for select to authenticated
  using ((select private.has_any_role(array['SA','KPA','PWS','PPK','PPB','PGB','AKT','AUD'])));
drop policy if exists suppliers_insert on public.suppliers;
create policy suppliers_insert on public.suppliers for insert to authenticated
  with check ((select private.is_admin_verified()) or (select private.has_role('PPK')));
drop policy if exists suppliers_update on public.suppliers;
create policy suppliers_update on public.suppliers for update to authenticated
  using ((select private.is_admin_verified()) or (select private.has_role('PPK')))
  with check ((select private.is_admin_verified()) or (select private.has_role('PPK')));

-- Edge Function membaca pengaturan MFA.
grant select on public.app_settings to service_role;

-- ---------------------------------------------------------------------
-- RPC: usulan kode barang berikutnya untuk sebuah kategori (mis. ATK-0007)
-- ---------------------------------------------------------------------
create or replace function public.rpc_suggest_item_code(p_category_id uuid)
returns text
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_prefix text;
  v_next   integer;
begin
  if not private.current_user_is_active() then
    raise exception 'Sesi tidak valid atau akun nonaktif.' using errcode = '42501';
  end if;
  select code into v_prefix from public.item_categories where id = p_category_id;
  if v_prefix is null then
    raise exception 'Kategori tidak ditemukan.' using errcode = 'P0002';
  end if;
  select coalesce(max((regexp_match(code, '^' || v_prefix || '-([0-9]+)$'))[1]::integer), 0) + 1
    into v_next
    from public.items
   where code ~ ('^' || v_prefix || '-[0-9]+$');
  return v_prefix || '-' || lpad(v_next::text, 4, '0');
end;
$$;
revoke all on function public.rpc_suggest_item_code(uuid) from public, anon;
grant execute on function public.rpc_suggest_item_code(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Dashboard: tambah jumlah jenis barang aktif & usulan barang
-- ---------------------------------------------------------------------
create or replace function public.rpc_dashboard_overview()
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_roles   text[] := private.my_role_codes();
  v_result  jsonb;
begin
  if auth.uid() is null or not private.current_user_is_active() then
    raise exception 'Sesi tidak valid atau akun nonaktif.' using errcode = '42501';
  end if;

  v_result := jsonb_build_object(
    'roles', to_jsonb(v_roles),
    'unread_notifications',
      (select count(*) from public.notifications n where n.user_id = auth.uid() and not n.is_read),
    'active_units',
      (select count(*) from public.organizational_units where is_active),
    'active_items',
      (select count(*) from public.items where is_active),
    'mfa_required', private.role_requires_mfa('SA') and 'SA' = any(v_roles),
    'mfa_satisfied', private.mfa_satisfied(),
    'generated_at', now());

  if v_roles && array['SA','PGB','KPA','PWS'] then
    v_result := v_result || jsonb_build_object(
      'proposed_items', (select count(*) from public.items where not is_active and activated_at is null));
  end if;

  if v_roles && array['SA','KPA','PWS','AUD'] then
    v_result := v_result || jsonb_build_object(
      'active_users',   (select count(*) from public.profiles where is_active),
      'inactive_users', (select count(*) from public.profiles where not is_active),
      'users_without_role',
        (select count(*) from public.profiles p
          where p.is_active and not exists
            (select 1 from public.user_roles ur where ur.user_id = p.id and ur.is_active)),
      'audit_events_today',
        (select count(*) from public.audit_logs
          where occurred_at >= (date_trunc('day', now() at time zone 'Asia/Jakarta') at time zone 'Asia/Jakarta')),
      'recent_activity',
        coalesce((select jsonb_agg(x order by x.occurred_at desc) from (
            select a.occurred_at, a.user_name, a.action, a.table_name
              from public.audit_logs a order by a.id desc limit 10) x), '[]'::jsonb));
  end if;

  return v_result;
end;
$$;

-- ---------------------------------------------------------------------
-- Konteks pengguna: tambahkan informasi kewajiban MFA
-- ---------------------------------------------------------------------
create or replace function public.rpc_my_context()
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare v jsonb;
begin
  if auth.uid() is null then
    raise exception 'Sesi tidak valid.' using errcode = '42501';
  end if;

  select jsonb_build_object(
    'profile', jsonb_build_object(
        'id', p.id, 'full_name', p.full_name, 'email', p.email, 'nip', p.nip,
        'position_title', p.position_title, 'phone', p.phone, 'is_active', p.is_active,
        'primary_unit_id', p.primary_unit_id, 'primary_unit_name', u.name),
    'roles', to_jsonb(private.my_role_codes()),
    'scopes', jsonb_build_object(
        'ATS', to_jsonb(private.my_scope_unit_ids('ATS')),
        'PGW', to_jsonb(private.my_scope_unit_ids('PGW'))),
    'mfa_required', 'SA' = any(private.my_role_codes()) and private.role_requires_mfa('SA'))
  into v
  from public.profiles p
  left join public.organizational_units u on u.id = p.primary_unit_id
  where p.id = auth.uid();

  if v is null then
    raise exception 'Profil pengguna belum tersedia. Hubungi Super Admin.' using errcode = 'P0002';
  end if;
  if not (v -> 'profile' ->> 'is_active')::boolean then
    raise exception 'Akun Anda nonaktif. Hubungi Super Admin.' using errcode = '42501';
  end if;
  return v;
end;
$$;

-- =====================================================================
-- Selesai. Bila muncul "Success. No rows returned", pemasangan berhasil.
-- =====================================================================
