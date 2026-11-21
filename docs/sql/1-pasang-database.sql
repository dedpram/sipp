-- =====================================================================
-- SIPP — PEMASANGAN DATABASE FASE 2 (SEKALIGUS)
-- Cara pakai: Supabase Dashboard > SQL Editor > New query >
--             tempel SELURUH isi file ini > klik RUN.
-- Isi file ini = gabungan seluruh file di supabase/migrations/ (urutan sama).
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

-- >>>>> 20261121000900_transaksi_tabel.sql
-- =====================================================================
-- SIPP — Migration 0009: Tabel transaksi Fase 4A
-- Penerimaan, buku mutasi (ledger), batch FIFO/FEFO, saldo, perpindahan
-- lokasi, persetujuan, riwayat status, lampiran dokumen.
-- Saldo & mutasi TIDAK dapat ditulis langsung dari aplikasi: hanya
-- melalui fungsi RPC di migration 0010.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Penerimaan
-- ---------------------------------------------------------------------
create table if not exists public.receipts (
  id                     uuid primary key default gen_random_uuid(),
  receipt_no             text not null unique,
  receipt_date           date not null default ((now() at time zone 'Asia/Jakarta')::date),
  source_type            text not null check (source_type in ('pembelian','hibah','transfer','lainnya','saldo_awal')),
  supplier_id            uuid references public.suppliers(id),
  contract_no            text,
  contract_date          date,
  order_no               text,
  delivery_note_no       text,
  invoice_no             text,
  source_description     text,              -- asal hibah/transfer/perolehan lain
  warehouse_id           uuid not null references public.warehouses(id),
  status                 text not null default 'draft' check (status in (
                           'draft','menunggu_pemeriksaan','dalam_pemeriksaan','tidak_sesuai',
                           'menunggu_tindak_lanjut_penyedia','menunggu_pengesahan','disetujui',
                           'diterima_disimpan','selesai','dibatalkan')),
  notes                  text,
  inspector_id           uuid references public.profiles(id),
  inspected_at           timestamptz,
  inspection_notes       text,
  approved_by            uuid references public.profiles(id),
  approved_at            timestamptz,
  finalized_by           uuid references public.profiles(id),
  finalized_at           timestamptz,
  accounting_verified_by uuid references public.profiles(id),
  accounting_verified_at timestamptz,
  cancel_reason          text,
  total_value            numeric(18,2) not null default 0,
  created_at             timestamptz not null default now(),
  created_by             uuid references public.profiles(id),
  updated_at             timestamptz,
  updated_by             uuid references public.profiles(id)
);
create index if not exists idx_receipts_status on public.receipts(status);
create index if not exists idx_receipts_date   on public.receipts(receipt_date desc);
create index if not exists idx_receipts_supplier on public.receipts(supplier_id);

create table if not exists public.receipt_details (
  id                 uuid primary key default gen_random_uuid(),
  receipt_id         uuid not null references public.receipts(id),
  line_no            integer not null default 1,
  item_id            uuid not null references public.items(id),
  qty_ordered        numeric(14,3) check (qty_ordered is null or qty_ordered >= 0),
  qty_received       numeric(14,3) not null check (qty_received > 0),
  qty_accepted       numeric(14,3) not null default 0 check (qty_accepted >= 0),
  qty_rejected       numeric(14,3) not null default 0 check (qty_rejected >= 0),
  unit_cost          numeric(18,4) not null check (unit_cost >= 0),
  location_id        uuid references public.storage_locations(id),
  expiry_date        date,
  inspection_result  text check (inspection_result is null or inspection_result in
                       ('sesuai','tidak_sesuai_jumlah','tidak_sesuai_spesifikasi','rusak')),
  inspection_notes   text,
  created_at         timestamptz not null default now(),
  created_by         uuid references public.profiles(id),
  updated_at         timestamptz,
  updated_by         uuid references public.profiles(id),
  constraint receipt_details_qty check (qty_accepted + qty_rejected <= qty_received)
);
create index if not exists idx_receipt_details_receipt on public.receipt_details(receipt_id);
create index if not exists idx_receipt_details_item    on public.receipt_details(item_id);

-- ---------------------------------------------------------------------
-- Stok: batch (lapisan FIFO/FEFO), saldo, buku mutasi
-- ---------------------------------------------------------------------
create table if not exists public.stock_batches (
  id                        uuid primary key default gen_random_uuid(),
  item_id                   uuid not null references public.items(id),
  location_id               uuid not null references public.storage_locations(id),
  condition                 text not null default 'layak_pakai' check (condition in (
                              'layak_pakai','rusak_ringan','rusak_berat','usang','kedaluwarsa',
                              'dalam_pemeriksaan','menunggu_penyelesaian')),
  source_receipt_detail_id  uuid references public.receipt_details(id),
  parent_batch_id           uuid references public.stock_batches(id),
  acquired_at               date not null,
  expiry_date               date,
  unit_cost                 numeric(18,4) not null check (unit_cost >= 0),
  qty_initial               numeric(14,3) not null check (qty_initial > 0),
  qty_remaining             numeric(14,3) not null check (qty_remaining >= 0),
  created_at                timestamptz not null default now(),
  constraint stock_batches_remaining check (qty_remaining <= qty_initial)
);
create index if not exists idx_batches_fifo on public.stock_batches
  (item_id, location_id, condition, expiry_date nulls last, acquired_at, created_at) where qty_remaining > 0;

create table if not exists public.stock_balances (
  id                uuid primary key default gen_random_uuid(),
  item_id           uuid not null references public.items(id),
  location_id       uuid not null references public.storage_locations(id),
  condition         text not null default 'layak_pakai',
  quantity          numeric(14,3) not null default 0 check (quantity >= 0),
  reserved_qty      numeric(14,3) not null default 0 check (reserved_qty >= 0),
  total_value       numeric(18,2) not null default 0 check (total_value >= 0),
  last_movement_at  timestamptz,
  constraint stock_balances_unique unique (item_id, location_id, condition),
  constraint stock_balances_reserved check (reserved_qty <= quantity)
);
create index if not exists idx_balances_item on public.stock_balances(item_id);

create table if not exists public.stock_movements (
  id                   bigint generated always as identity primary key,
  movement_date        date not null,
  posted_at            timestamptz not null default clock_timestamp(),
  movement_type        text not null check (movement_type in (
                         'OPENING_BALANCE','RECEIPT_IN','ISSUE_OUT','TRANSFER_OUT','TRANSFER_IN',
                         'ADJ_IN','ADJ_OUT','RECLASS_OUT','RECLASS_IN','WRITE_OFF')),
  item_id              uuid not null references public.items(id),
  location_id          uuid not null references public.storage_locations(id),
  batch_id             uuid not null references public.stock_batches(id),
  condition            text not null,
  qty_in               numeric(14,3) not null default 0 check (qty_in >= 0),
  qty_out              numeric(14,3) not null default 0 check (qty_out >= 0),
  unit_cost            numeric(18,4) not null,
  value_in             numeric(18,2) not null default 0,
  value_out            numeric(18,2) not null default 0,
  ref_table            text not null,
  ref_id               uuid not null,
  ref_no               text not null,
  description          text not null,
  posted_by            uuid references public.profiles(id),
  constraint stock_movements_one_side check ((qty_in > 0 and qty_out = 0) or (qty_out > 0 and qty_in = 0))
);
create index if not exists idx_movements_item_time on public.stock_movements(item_id, movement_date, id);
create index if not exists idx_movements_ref       on public.stock_movements(ref_table, ref_id);

-- ---------------------------------------------------------------------
-- Perpindahan lokasi
-- ---------------------------------------------------------------------
create table if not exists public.stock_transfers (
  id             uuid primary key default gen_random_uuid(),
  transfer_no    text not null unique,
  transfer_date  date not null,
  reason         text not null check (length(trim(reason)) >= 5),
  status         text not null default 'selesai' check (status in ('selesai')),
  created_at     timestamptz not null default now(),
  created_by     uuid references public.profiles(id)
);

create table if not exists public.stock_transfer_details (
  id                uuid primary key default gen_random_uuid(),
  transfer_id       uuid not null references public.stock_transfers(id),
  item_id           uuid not null references public.items(id),
  from_location_id  uuid not null references public.storage_locations(id),
  to_location_id    uuid not null references public.storage_locations(id),
  condition         text not null default 'layak_pakai',
  quantity          numeric(14,3) not null check (quantity > 0),
  constraint stock_transfer_details_diff check (from_location_id <> to_location_id)
);
create index if not exists idx_transfer_details_transfer on public.stock_transfer_details(transfer_id);

-- ---------------------------------------------------------------------
-- Persetujuan, riwayat status, lampiran (dipakai lintas modul)
-- ---------------------------------------------------------------------
create table if not exists public.approvals (
  id                  uuid primary key default gen_random_uuid(),
  ref_table           text not null,
  ref_id              uuid not null,
  level               integer not null default 1,
  required_role_code  text not null references public.roles(code),
  approver_id         uuid not null references public.profiles(id),
  decision            text not null check (decision in ('approved','rejected','returned')),
  notes               text,
  decided_at          timestamptz not null default now()
);
create index if not exists idx_approvals_ref on public.approvals(ref_table, ref_id);

create table if not exists public.status_histories (
  id           bigint generated always as identity primary key,
  ref_table    text not null,
  ref_id       uuid not null,
  from_status  text,
  to_status    text not null,
  comment      text,
  actor_id     uuid references public.profiles(id),
  created_at   timestamptz not null default now()
);
create index if not exists idx_status_histories_ref on public.status_histories(ref_table, ref_id, id);

create table if not exists public.attachments (
  id            uuid primary key default gen_random_uuid(),
  ref_table     text not null check (ref_table in ('receipts','stock_transfers')),
  ref_id        uuid not null,
  doc_type      text not null check (doc_type in (
                  'surat_jalan','faktur','kontrak','ba_pemeriksaan','ba_penerimaan','ba_saldo_awal',
                  'foto','sk','lainnya')),
  storage_path  text not null unique,
  file_name     text not null,
  mime_type     text,
  size_bytes    bigint check (size_bytes is null or size_bytes <= 10485760),
  uploaded_by   uuid references public.profiles(id),
  uploaded_at   timestamptz not null default now()
);
create index if not exists idx_attachments_ref on public.attachments(ref_table, ref_id);

-- Penyetuju saldo awal = KPA (sama seperti perolehan non-pembelian).
update public.approval_settings
   set applies_when = '{"source_type":["hibah","transfer","lainnya","saldo_awal"]}'::jsonb
 where transaction_type = 'receipt' and approver_role_code = 'KPA'
   and not (applies_when -> 'source_type') ? 'saldo_awal';

-- ---------------------------------------------------------------------
-- Trigger umum
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['receipts','receipt_details'] loop
    execute format('drop trigger if exists trg_row_meta on public.%I', t);
    execute format('create trigger trg_row_meta before insert or update on public.%I
                    for each row execute function private.tg_set_row_meta()', t);
  end loop;
  foreach t in array array['receipts','receipt_details','stock_transfers','stock_transfer_details','attachments'] loop
    execute format('drop trigger if exists trg_audit on public.%I', t);
    execute format('create trigger trg_audit after insert or update or delete on public.%I
                    for each row execute function private.tg_audit_row()', t);
  end loop;
  -- Tabel jejak bersifat permanen.
  foreach t in array array['stock_movements','approvals','status_histories','attachments'] loop
    execute format('drop trigger if exists trg_block_update_delete on public.%I', t);
    execute format('create trigger trg_block_update_delete before update or delete on public.%I
                    for each row execute function private.tg_block_modification()', t);
  end loop;
end $$;

-- Nomor penerimaan otomatis.
create or replace function private.tg_receipt_number()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    new.receipt_no := private.next_document_number('PNR', new.receipt_date);
    new.status := 'draft';
  end if;
  return new;
end;
$$;
revoke all on function private.tg_receipt_number() from public;
drop trigger if exists trg_receipt_number on public.receipts;
create trigger trg_receipt_number before insert on public.receipts
  for each row execute function private.tg_receipt_number();

-- Penjaga penerimaan: di luar RPC, hanya draf yang boleh diubah, dan
-- kolom status/pemeriksaan/pengesahan tidak boleh diisi langsung.
create or replace function private.tg_receipts_guard()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if private.is_system_context() then
    return new;
  end if;
  if tg_op = 'INSERT' then
    if new.inspector_id is not null or new.approved_by is not null or new.finalized_by is not null then
      raise exception 'Kolom pemeriksaan/pengesahan diisi oleh sistem.' using errcode = '42501';
    end if;
    return new;
  end if;
  if old.status <> 'draft' then
    raise exception 'Penerimaan % sudah diajukan dan tidak dapat diubah langsung.', old.receipt_no using errcode = 'P0001';
  end if;
  if new.status is distinct from old.status
     or new.receipt_no is distinct from old.receipt_no
     or new.inspector_id is distinct from old.inspector_id
     or new.approved_by is distinct from old.approved_by
     or new.finalized_by is distinct from old.finalized_by
     or new.accounting_verified_by is distinct from old.accounting_verified_by
     or new.total_value is distinct from old.total_value then
    raise exception 'Status dan kolom pengesahan hanya dapat diubah melalui tombol proses.' using errcode = '42501';
  end if;
  return new;
end;
$$;
revoke all on function private.tg_receipts_guard() from public;
drop trigger if exists trg_receipts_guard on public.receipts;
create trigger trg_receipts_guard before insert or update on public.receipts
  for each row execute function private.tg_receipts_guard();

create or replace function private.tg_receipt_details_guard()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare v_status text;
begin
  if private.is_system_context() then
    return coalesce(new, old);
  end if;
  select status into v_status from public.receipts where id = coalesce(new.receipt_id, old.receipt_id);
  if v_status is distinct from 'draft' then
    raise exception 'Rincian hanya dapat diubah saat penerimaan masih draf.' using errcode = 'P0001';
  end if;
  if tg_op in ('INSERT','UPDATE') then
    -- Hasil pemeriksaan diisi Petugas Penerima melalui RPC.
    new.qty_accepted := 0;
    new.qty_rejected := 0;
    new.inspection_result := null;
    new.inspection_notes := null;
    if tg_op = 'UPDATE' and new.receipt_id <> old.receipt_id then
      raise exception 'Rincian tidak dapat dipindahkan ke penerimaan lain.' using errcode = '42501';
    end if;
  end if;
  return coalesce(new, old);
end;
$$;
revoke all on function private.tg_receipt_details_guard() from public;
drop trigger if exists trg_receipt_details_guard on public.receipt_details;
create trigger trg_receipt_details_guard before insert or update or delete on public.receipt_details
  for each row execute function private.tg_receipt_details_guard();

-- Riwayat status otomatis.
create or replace function private.tg_status_history()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if tg_op = 'INSERT' or new.status is distinct from old.status then
    insert into public.status_histories (ref_table, ref_id, from_status, to_status, comment, actor_id)
    values (tg_table_name, new.id, case when tg_op = 'UPDATE' then old.status end, new.status,
            nullif(current_setting('app.status_comment', true), ''), auth.uid());
  end if;
  return new;
end;
$$;
revoke all on function private.tg_status_history() from public;
drop trigger if exists trg_status_history on public.receipts;
create trigger trg_status_history after insert or update of status on public.receipts
  for each row execute function private.tg_status_history();

-- >>>>> 20261121001000_transaksi_rpc.sql
-- =====================================================================
-- SIPP — Migration 0010: Fungsi transaksi Fase 4A & aturan akses
-- Semua perubahan saldo terjadi di fungsi ini, dalam satu transaksi
-- database (atomic), dengan penguncian per barang agar tidak terjadi
-- saldo ganda atau stok negatif pada transaksi bersamaan.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Utilitas
-- ---------------------------------------------------------------------
create or replace function private.begin_rpc(p_comment text default null)
returns void language plpgsql set search_path = '' as $$
begin
  perform set_config('app.via_rpc', 'on', true);
  perform set_config('app.status_comment', coalesce(p_comment, ''), true);
end $$;

create or replace function private.end_rpc()
returns void language plpgsql set search_path = '' as $$
begin
  perform set_config('app.via_rpc', '', true);
  perform set_config('app.status_comment', '', true);
end $$;

create or replace function private.require_active_user()
returns uuid language plpgsql stable security definer set search_path = '' as $$
begin
  if auth.uid() is null or not private.current_user_is_active() then
    raise exception 'Sesi tidak valid atau akun nonaktif.' using errcode = '42501';
  end if;
  return auth.uid();
end $$;

create or replace function private.lock_item(p_item uuid)
returns void language sql set search_path = '' as $$
  select pg_advisory_xact_lock(hashtextextended('sipp-item:' || p_item::text, 0));
$$;

create or replace function private.stock_reader_roles()
returns text[] language sql immutable set search_path = '' as $$
  select array['PGB','KPA','PWS','PPK','PPB','AKT','TSO','AUD'];
$$;

create or replace function private.receipt_reader_roles()
returns text[] language sql immutable set search_path = '' as $$
  select array['PGB','PPB','PPK','KPA','PWS','AKT','AUD'];
$$;

-- Siapa boleh membaca dokumen/riwayat suatu transaksi.
create or replace function private.can_read_ref(p_table text, p_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select private.current_user_is_active() and case p_table
    when 'receipts'        then private.has_any_role(private.receipt_reader_roles())
    when 'stock_transfers' then private.has_any_role(private.stock_reader_roles())
    else false end;
$$;

-- Siapa boleh menambah lampiran pada suatu transaksi.
create or replace function private.can_attach(p_table text, p_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select private.current_user_is_active() and case p_table
    when 'receipts' then private.has_any_role(array['PGB','PPB','PPK'])
      and exists (select 1 from public.receipts r where r.id = p_id and r.status in
        ('draft','menunggu_pemeriksaan','dalam_pemeriksaan','tidak_sesuai',
         'menunggu_tindak_lanjut_penyedia','menunggu_pengesahan'))
    when 'stock_transfers' then private.has_role('PGB')
    else false end;
$$;

-- Versi untuk path Storage: '<tabel>/<uuid>/<nama file>'
create or replace function private.path_ref(p_name text, out ref_table text, out ref_id uuid)
language plpgsql immutable set search_path = '' as $$
declare parts text[] := string_to_array(p_name, '/');
begin
  ref_table := parts[1];
  begin
    ref_id := parts[2]::uuid;
  exception when others then
    ref_id := null;
  end;
end $$;

create or replace function private.can_attach_path(p_name text)
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce((select private.can_attach(p.ref_table, p.ref_id) from private.path_ref(p_name) p where p.ref_id is not null), false);
$$;

create or replace function private.can_read_path(p_name text)
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce((select private.can_read_ref(p.ref_table, p.ref_id) from private.path_ref(p_name) p where p.ref_id is not null), false);
$$;

-- ---------------------------------------------------------------------
-- Buku mutasi (ledger)
-- ---------------------------------------------------------------------
create or replace function private.refresh_balance(p_item uuid, p_location uuid, p_condition text)
returns void language sql security definer set search_path = '' as $$
  insert into public.stock_balances as b (item_id, location_id, condition, quantity, total_value, last_movement_at)
  select p_item, p_location, p_condition,
         coalesce(sum(s.qty_remaining), 0),
         coalesce(round(sum(s.qty_remaining * s.unit_cost), 2), 0),
         now()
    from public.stock_batches s
   where s.item_id = p_item and s.location_id = p_location and s.condition = p_condition
  on conflict (item_id, location_id, condition) do update
    set quantity = excluded.quantity, total_value = excluded.total_value, last_movement_at = excluded.last_movement_at;
$$;

create or replace function private.record_movement(
  p_type text, p_date date, p_item uuid, p_location uuid, p_batch uuid, p_condition text,
  p_qty_in numeric, p_qty_out numeric, p_unit_cost numeric,
  p_ref_table text, p_ref_id uuid, p_ref_no text, p_desc text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  insert into public.stock_movements
    (movement_date, movement_type, item_id, location_id, batch_id, condition, qty_in, qty_out, unit_cost,
     value_in, value_out, ref_table, ref_id, ref_no, description, posted_by)
  values
    (p_date, p_type, p_item, p_location, p_batch, p_condition, p_qty_in, p_qty_out, p_unit_cost,
     round(p_qty_in * p_unit_cost, 2), round(p_qty_out * p_unit_cost, 2),
     p_ref_table, p_ref_id, p_ref_no, p_desc, auth.uid());
end $$;

-- Barang keluar/pindah tidak boleh bertanggal sebelum mutasi terakhir barang
-- (mencegah saldo historis menjadi minus pada kartu stok).
create or replace function private.assert_not_backdated(p_item uuid, p_date date)
returns void language plpgsql stable security definer set search_path = '' as $$
declare v_last date; v_code text;
begin
  select max(movement_date) into v_last from public.stock_movements where item_id = p_item;
  if v_last is not null and p_date < v_last then
    select code into v_code from public.items where id = p_item;
    raise exception 'Tanggal % lebih awal dari mutasi terakhir barang % (%). Gunakan tanggal yang sama atau sesudahnya.',
      to_char(p_date, 'DD-MM-YYYY'), v_code, to_char(v_last, 'DD-MM-YYYY') using errcode = 'P0001';
  end if;
end $$;

-- Barang masuk: membentuk batch baru.
create or replace function private.stock_in(
  p_type text, p_date date, p_item uuid, p_location uuid, p_condition text, p_qty numeric,
  p_unit_cost numeric, p_acquired date, p_expiry date, p_source_detail uuid, p_parent_batch uuid,
  p_ref_table text, p_ref_id uuid, p_ref_no text, p_desc text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_batch uuid;
begin
  if p_qty <= 0 then
    raise exception 'Jumlah masuk harus lebih dari 0.' using errcode = '22023';
  end if;
  insert into public.stock_batches
    (item_id, location_id, condition, source_receipt_detail_id, parent_batch_id, acquired_at, expiry_date,
     unit_cost, qty_initial, qty_remaining)
  values (p_item, p_location, p_condition, p_source_detail, p_parent_batch, p_acquired, p_expiry,
          p_unit_cost, p_qty, p_qty)
  returning id into v_batch;
  perform private.refresh_balance(p_item, p_location, p_condition);
  perform private.record_movement(p_type, p_date, p_item, p_location, v_batch, p_condition,
                                  p_qty, 0, p_unit_cost, p_ref_table, p_ref_id, p_ref_no, p_desc);
  return v_batch;
end $$;

-- Barang keluar dengan urutan FEFO (barang ber-kedaluwarsa) lalu FIFO.
-- Mengembalikan potongan batch yang dipakai.
create or replace function private.consume_stock(
  p_type text, p_date date, p_item uuid, p_location uuid, p_condition text, p_qty numeric,
  p_ref_table text, p_ref_id uuid, p_ref_no text, p_desc text)
returns table (batch_id uuid, qty numeric, unit_cost numeric, acquired_at date, expiry_date date)
language plpgsql security definer set search_path = '' as $$
declare
  v_need   numeric := p_qty;
  v_avail  numeric;
  v_take   numeric;
  v_fefo   boolean;
  b        record;
  v_name   text;
begin
  if p_qty <= 0 then
    raise exception 'Jumlah keluar harus lebih dari 0.' using errcode = '22023';
  end if;
  perform private.assert_not_backdated(p_item, p_date);
  select has_expiry, name into v_fefo, v_name from public.items where id = p_item;

  select coalesce(quantity - reserved_qty, 0) into v_avail
    from public.stock_balances where item_id = p_item and location_id = p_location and condition = p_condition;
  if coalesce(v_avail, 0) < p_qty then
    raise exception 'Stok % tidak mencukupi di lokasi tersebut. Tersedia %, diminta %.',
      v_name, trim(to_char(coalesce(v_avail, 0), 'FM999G999G990D###')), trim(to_char(p_qty, 'FM999G999G990D###'))
      using errcode = 'P0001';
  end if;

  for b in
    select s.id, s.qty_remaining, s.unit_cost, s.acquired_at, s.expiry_date
      from public.stock_batches s
     where s.item_id = p_item and s.location_id = p_location and s.condition = p_condition and s.qty_remaining > 0
     order by case when v_fefo then s.expiry_date end nulls last, s.acquired_at, s.created_at, s.id
     for update
  loop
    exit when v_need <= 0;
    v_take := least(v_need, b.qty_remaining);
    update public.stock_batches set qty_remaining = qty_remaining - v_take where id = b.id;
    perform private.refresh_balance(p_item, p_location, p_condition);
    perform private.record_movement(p_type, p_date, p_item, p_location, b.id, p_condition,
                                    0, v_take, b.unit_cost, p_ref_table, p_ref_id, p_ref_no, p_desc);
    batch_id := b.id; qty := v_take; unit_cost := b.unit_cost; acquired_at := b.acquired_at; expiry_date := b.expiry_date;
    return next;
    v_need := v_need - v_take;
  end loop;

  if v_need > 0 then
    raise exception 'Stok tidak mencukupi (data batch tidak sesuai saldo). Hubungi Super Admin.' using errcode = 'P0001';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- PENERIMAAN
-- ---------------------------------------------------------------------
create or replace function private.receipt_for_update(p_id uuid)
returns public.receipts language plpgsql security definer set search_path = '' as $$
declare r public.receipts;
begin
  select * into r from public.receipts where id = p_id for update;
  if not found then
    raise exception 'Penerimaan tidak ditemukan.' using errcode = 'P0002';
  end if;
  return r;
end $$;

create or replace function private.receipt_status_label(p text)
returns text language sql immutable set search_path = '' as $$
  select case p
    when 'draft' then 'Draf' when 'menunggu_pemeriksaan' then 'Menunggu pemeriksaan'
    when 'dalam_pemeriksaan' then 'Dalam pemeriksaan' when 'tidak_sesuai' then 'Tidak sesuai'
    when 'menunggu_tindak_lanjut_penyedia' then 'Menunggu tindak lanjut penyedia'
    when 'menunggu_pengesahan' then 'Menunggu pengesahan' when 'disetujui' then 'Disetujui'
    when 'diterima_disimpan' then 'Diterima dan disimpan' when 'selesai' then 'Selesai'
    when 'dibatalkan' then 'Dibatalkan' else p end;
$$;

create or replace function private.receipt_expect(r public.receipts, p_statuses text[])
returns void language plpgsql set search_path = '' as $$
begin
  if not (r.status = any(p_statuses)) then
    raise exception 'Penerimaan % berstatus "%"; tindakan ini tidak dapat dilakukan.',
      r.receipt_no, private.receipt_status_label(r.status) using errcode = 'P0001';
  end if;
end $$;

-- 1. Ajukan untuk diperiksa (pembuat draf).
create or replace function public.rpc_receipt_submit(p_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  r public.receipts;
  v_uid uuid := private.require_active_user();
  v_lines integer;
  v_bad text;
begin
  r := private.receipt_for_update(p_id);
  perform private.receipt_expect(r, array['draft']);
  if r.created_by is distinct from v_uid then
    raise exception 'Hanya pembuat penerimaan yang dapat mengajukannya.' using errcode = '42501';
  end if;
  select count(*) into v_lines from public.receipt_details where receipt_id = p_id;
  if v_lines = 0 then
    raise exception 'Tambahkan minimal satu barang sebelum mengajukan.' using errcode = 'P0001';
  end if;
  if r.source_type = 'pembelian' and (r.supplier_id is null or coalesce(r.contract_no, r.order_no) is null) then
    raise exception 'Penerimaan dari pembelian wajib mencantumkan penyedia dan nomor kontrak/SPK/pesanan.' using errcode = 'P0001';
  end if;
  if r.source_type in ('hibah','transfer','lainnya') and nullif(trim(coalesce(r.source_description, '')), '') is null then
    raise exception 'Jelaskan asal perolehan (pemberi hibah/asal transfer).' using errcode = 'P0001';
  end if;
  select string_agg(i.code, ', ') into v_bad
    from public.receipt_details d join public.items i on i.id = d.item_id
   where d.receipt_id = p_id and not i.is_active;
  if v_bad is not null then
    raise exception 'Barang berikut belum aktif: %. Minta Super Admin mengaktifkannya.', v_bad using errcode = 'P0001';
  end if;

  perform private.begin_rpc('Diajukan untuk pemeriksaan');
  update public.receipts
     set status = 'menunggu_pemeriksaan',
         total_value = (select coalesce(round(sum(qty_received * unit_cost), 2), 0) from public.receipt_details where receipt_id = p_id)
   where id = p_id;
  perform private.end_rpc();
end $$;

-- 2. Mulai pemeriksaan (Petugas Penerima Barang, bukan pembuat).
create or replace function public.rpc_receipt_start_inspection(p_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare r public.receipts; v_uid uuid := private.require_active_user();
begin
  if not private.has_role('PPB') then
    raise exception 'Hanya Petugas Penerima Barang yang dapat memeriksa.' using errcode = '42501';
  end if;
  r := private.receipt_for_update(p_id);
  perform private.receipt_expect(r, array['menunggu_pemeriksaan','menunggu_tindak_lanjut_penyedia']);
  if r.created_by = v_uid then
    raise exception 'Pembuat penerimaan tidak boleh memeriksa penerimaannya sendiri (pemisahan fungsi).' using errcode = '42501';
  end if;
  perform private.begin_rpc('Pemeriksaan dimulai');
  update public.receipts set status = 'dalam_pemeriksaan', inspector_id = v_uid where id = p_id;
  perform private.end_rpc();
end $$;

-- 3. Catat hasil pemeriksaan.
-- p_lines: [{"detail_id","qty_received","qty_accepted","qty_rejected","result","notes","expiry_date"}]
-- p_decision: 'lanjut' (ajukan pengesahan atas jumlah yang diterima) | 'tindak_lanjut' (ketidaksesuaian)
create or replace function public.rpc_receipt_record_inspection(p_id uuid, p_lines jsonb, p_notes text, p_decision text)
returns void language plpgsql security definer set search_path = '' as $$
declare
  r public.receipts;
  v_uid uuid := private.require_active_user();
  l jsonb;
  d record;
  v_acc numeric; v_rej numeric; v_rec numeric; v_res text; v_exp date;
  v_issue boolean := false;
  v_total_acc numeric := 0;
  v_missing integer;
begin
  r := private.receipt_for_update(p_id);
  perform private.receipt_expect(r, array['dalam_pemeriksaan']);
  if r.inspector_id is distinct from v_uid then
    raise exception 'Hanya petugas yang memulai pemeriksaan yang dapat mencatat hasilnya.' using errcode = '42501';
  end if;
  if p_decision not in ('lanjut','tindak_lanjut') then
    raise exception 'Keputusan pemeriksaan tidak dikenal.' using errcode = '22023';
  end if;

  perform private.begin_rpc(case p_decision when 'lanjut' then 'Pemeriksaan selesai, diajukan pengesahan'
                                            else 'Ditemukan ketidaksesuaian' end);
  for l in select * from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) loop
    select d2.*, i.has_expiry, i.code into d
      from public.receipt_details d2 join public.items i on i.id = d2.item_id
     where d2.id = (l ->> 'detail_id')::uuid and d2.receipt_id = p_id;
    if not found then
      raise exception 'Rincian penerimaan tidak dikenal.' using errcode = 'P0002';
    end if;
    v_rec := coalesce((l ->> 'qty_received')::numeric, d.qty_received);
    v_acc := coalesce((l ->> 'qty_accepted')::numeric, 0);
    v_rej := coalesce((l ->> 'qty_rejected')::numeric, 0);
    v_res := l ->> 'result';
    v_exp := nullif(l ->> 'expiry_date', '')::date;
    if v_rec <= 0 or v_acc < 0 or v_rej < 0 or v_acc + v_rej <> v_rec then
      raise exception 'Barang %: jumlah diterima baik + ditolak harus sama dengan jumlah yang datang.', d.code using errcode = '22023';
    end if;
    if v_res is null or v_res not in ('sesuai','tidak_sesuai_jumlah','tidak_sesuai_spesifikasi','rusak') then
      raise exception 'Barang %: pilih hasil pemeriksaan.', d.code using errcode = '22023';
    end if;
    if v_res = 'sesuai' and v_rej > 0 then
      raise exception 'Barang %: hasil "sesuai" tidak boleh memiliki jumlah ditolak.', d.code using errcode = '22023';
    end if;
    if d.has_expiry and v_acc > 0 and v_exp is null then
      raise exception 'Barang % wajib diisi tanggal kedaluwarsa.', d.code using errcode = '22023';
    end if;
    if v_res <> 'sesuai' or v_rej > 0 or (d.qty_ordered is not null and v_rec <> d.qty_ordered) then
      v_issue := true;
    end if;
    update public.receipt_details
       set qty_received = v_rec, qty_accepted = v_acc, qty_rejected = v_rej,
           inspection_result = v_res, inspection_notes = nullif(trim(l ->> 'notes'), ''), expiry_date = v_exp
     where id = d.id;
  end loop;

  select count(*) into v_missing from public.receipt_details where receipt_id = p_id and inspection_result is null;
  if v_missing > 0 then
    raise exception 'Semua barang harus diperiksa (% belum).', v_missing using errcode = 'P0001';
  end if;
  select coalesce(sum(qty_accepted), 0) into v_total_acc from public.receipt_details where receipt_id = p_id;

  if p_decision = 'lanjut' and v_total_acc <= 0 then
    raise exception 'Tidak ada barang yang diterima baik; pilih tindak lanjut ketidaksesuaian.' using errcode = 'P0001';
  end if;
  if p_decision = 'tindak_lanjut' and not v_issue then
    raise exception 'Tidak ada ketidaksesuaian yang dicatat.' using errcode = 'P0001';
  end if;

  update public.receipts
     set status = case p_decision when 'lanjut' then 'menunggu_pengesahan' else 'tidak_sesuai' end,
         inspected_at = now(),
         inspection_notes = nullif(trim(coalesce(p_notes, '')), ''),
         total_value = (select coalesce(round(sum(qty_accepted * unit_cost), 2), 0) from public.receipt_details where receipt_id = p_id)
   where id = p_id;
  perform private.end_rpc();
end $$;

-- 3b. Ketidaksesuaian diteruskan ke penyedia (PPK / Pengurus Barang).
create or replace function public.rpc_receipt_vendor_followup(p_id uuid, p_comment text)
returns void language plpgsql security definer set search_path = '' as $$
declare r public.receipts;
begin
  perform private.require_active_user();
  if not private.has_any_role(array['PPK','PGB']) then
    raise exception 'Hanya PPK atau Pengurus Barang yang dapat meneruskan ke penyedia.' using errcode = '42501';
  end if;
  r := private.receipt_for_update(p_id);
  perform private.receipt_expect(r, array['tidak_sesuai']);
  if length(trim(coalesce(p_comment, ''))) < 5 then
    raise exception 'Tuliskan tindak lanjut yang diminta kepada penyedia (minimal 5 karakter).' using errcode = '22023';
  end if;
  perform private.begin_rpc(p_comment);
  update public.receipts set status = 'menunggu_tindak_lanjut_penyedia' where id = p_id;
  perform private.end_rpc();
end $$;

-- 4. Pengesahan / pengembalian ke pemeriksa.
create or replace function public.rpc_receipt_decide(p_id uuid, p_decision text, p_notes text)
returns void language plpgsql security definer set search_path = '' as $$
declare
  r public.receipts;
  v_uid uuid := private.require_active_user();
  v_role text;
  v_missing text[] := '{}';
begin
  r := private.receipt_for_update(p_id);
  perform private.receipt_expect(r, array['menunggu_pengesahan']);
  if p_decision not in ('approved','returned') then
    raise exception 'Keputusan tidak dikenal.' using errcode = '22023';
  end if;

  select a.approver_role_code into v_role
    from public.approval_settings a
   where a.transaction_type = 'receipt' and a.is_active
     and (a.applies_when = '{}'::jsonb or (a.applies_when -> 'source_type') ? r.source_type)
     and private.has_role(a.approver_role_code)
   order by a.level limit 1;
  if v_role is null then
    raise exception 'Anda tidak berwenang mengesahkan penerimaan jenis ini.' using errcode = '42501';
  end if;
  if v_uid = r.created_by or v_uid = r.inspector_id then
    raise exception 'Pembuat atau pemeriksa tidak boleh mengesahkan penerimaan yang sama (pemisahan fungsi).' using errcode = '42501';
  end if;

  if p_decision = 'returned' then
    if length(trim(coalesce(p_notes, ''))) < 5 then
      raise exception 'Alasan pengembalian wajib diisi (minimal 5 karakter).' using errcode = '22023';
    end if;
    perform private.begin_rpc('Dikembalikan ke pemeriksa: ' || p_notes);
    insert into public.approvals (ref_table, ref_id, level, required_role_code, approver_id, decision, notes)
    values ('receipts', p_id, 1, v_role, v_uid, 'returned', p_notes);
    update public.receipts set status = 'dalam_pemeriksaan' where id = p_id;
    perform private.end_rpc();
    return;
  end if;

  -- Dokumen wajib sebelum pengesahan.
  if r.source_type = 'saldo_awal' then
    if not exists (select 1 from public.attachments where ref_table = 'receipts' and ref_id = p_id and doc_type = 'ba_saldo_awal') then
      v_missing := v_missing || 'Berita Acara Saldo Awal';
    end if;
  else
    if not exists (select 1 from public.attachments where ref_table = 'receipts' and ref_id = p_id and doc_type = 'ba_pemeriksaan') then
      v_missing := v_missing || 'Berita Acara Pemeriksaan';
    end if;
    if r.source_type = 'pembelian' and not exists (
         select 1 from public.attachments where ref_table = 'receipts' and ref_id = p_id and doc_type in ('surat_jalan','faktur')) then
      v_missing := v_missing || 'Surat Jalan atau Faktur';
    end if;
  end if;
  if cardinality(v_missing) > 0 then
    raise exception 'Dokumen wajib belum diunggah: %.', array_to_string(v_missing, ', ') using errcode = 'P0001';
  end if;

  perform private.begin_rpc(coalesce(nullif(trim(p_notes), ''), 'Disahkan'));
  insert into public.approvals (ref_table, ref_id, level, required_role_code, approver_id, decision, notes)
  values ('receipts', p_id, 1, v_role, v_uid, 'approved', nullif(trim(p_notes), ''));
  update public.receipts set status = 'disetujui', approved_by = v_uid, approved_at = now() where id = p_id;
  perform private.end_rpc();
end $$;

-- 5. Simpan ke gudang: saldo bertambah (Pengurus Barang).
-- p_locations: {"<detail_id>": "<location_id>"} untuk melengkapi lokasi simpan.
create or replace function public.rpc_receipt_finalize(p_id uuid, p_locations jsonb default '{}'::jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare
  r public.receipts;
  v_uid uuid := private.require_active_user();
  d record;
  v_loc uuid;
  v_type text;
  v_desc text;
begin
  if not private.has_role('PGB') then
    raise exception 'Hanya Pengurus Barang yang dapat menyimpan barang ke gudang.' using errcode = '42501';
  end if;
  r := private.receipt_for_update(p_id);
  perform private.receipt_expect(r, array['disetujui']);

  v_type := case when r.source_type = 'saldo_awal' then 'OPENING_BALANCE' else 'RECEIPT_IN' end;
  v_desc := case r.source_type
    when 'saldo_awal' then 'Saldo awal'
    when 'pembelian' then 'Pembelian dari ' || coalesce((select name from public.suppliers where id = r.supplier_id), '-')
    when 'hibah' then 'Hibah: ' || coalesce(r.source_description, '-')
    when 'transfer' then 'Transfer masuk: ' || coalesce(r.source_description, '-')
    else 'Perolehan lain: ' || coalesce(r.source_description, '-') end;

  perform private.begin_rpc('Barang disimpan, saldo bertambah');
  for d in
    select * from public.receipt_details where receipt_id = p_id and qty_accepted > 0 order by item_id, line_no
  loop
    v_loc := coalesce(nullif(p_locations ->> d.id::text, '')::uuid, d.location_id);
    if v_loc is null then
      raise exception 'Pilih lokasi penyimpanan untuk semua barang yang diterima.' using errcode = 'P0001';
    end if;
    if not exists (select 1 from public.storage_locations where id = v_loc and is_active and warehouse_id = r.warehouse_id) then
      raise exception 'Lokasi penyimpanan harus aktif dan berada di gudang penerimaan.' using errcode = 'P0001';
    end if;
    update public.receipt_details set location_id = v_loc where id = d.id;
    perform private.lock_item(d.item_id);
    perform private.stock_in(v_type, r.receipt_date, d.item_id, v_loc, 'layak_pakai', d.qty_accepted, d.unit_cost,
                             r.receipt_date, d.expiry_date, d.id, null, 'receipts', r.id, r.receipt_no, v_desc);
  end loop;
  update public.receipts set status = 'diterima_disimpan', finalized_by = v_uid, finalized_at = now() where id = p_id;
  perform private.end_rpc();
end $$;

-- 6. Diperiksa fungsi akuntansi -> selesai.
create or replace function public.rpc_receipt_verify_accounting(p_id uuid, p_notes text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare r public.receipts; v_uid uuid := private.require_active_user();
begin
  if not private.has_role('AKT') then
    raise exception 'Hanya Petugas Akuntansi yang dapat memverifikasi pembukuan.' using errcode = '42501';
  end if;
  r := private.receipt_for_update(p_id);
  perform private.receipt_expect(r, array['diterima_disimpan']);
  perform private.begin_rpc(coalesce(nullif(trim(p_notes), ''), 'Diverifikasi fungsi akuntansi'));
  update public.receipts set status = 'selesai', accounting_verified_by = v_uid, accounting_verified_at = now() where id = p_id;
  perform private.end_rpc();
end $$;

-- 7. Pembatalan (sebelum disahkan).
create or replace function public.rpc_receipt_cancel(p_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare r public.receipts; v_uid uuid := private.require_active_user();
begin
  r := private.receipt_for_update(p_id);
  perform private.receipt_expect(r, array['draft','menunggu_pemeriksaan','tidak_sesuai','menunggu_tindak_lanjut_penyedia']);
  if not (r.created_by = v_uid or private.has_role('PGB')) then
    raise exception 'Hanya pembuat atau Pengurus Barang yang dapat membatalkan.' using errcode = '42501';
  end if;
  if length(trim(coalesce(p_reason, ''))) < 5 then
    raise exception 'Alasan pembatalan wajib diisi (minimal 5 karakter).' using errcode = '22023';
  end if;
  perform private.begin_rpc('Dibatalkan: ' || p_reason);
  update public.receipts set status = 'dibatalkan', cancel_reason = p_reason where id = p_id;
  perform private.end_rpc();
end $$;

-- ---------------------------------------------------------------------
-- PERPINDAHAN LOKASI (total saldo & nilai tidak berubah)
-- p_lines: [{"item_id","from_location_id","to_location_id","quantity"}]
-- ---------------------------------------------------------------------
create or replace function public.rpc_transfer_stock(p_date date, p_reason text, p_lines jsonb)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := private.require_active_user();
  v_id uuid;
  v_no text;
  l jsonb;
  v_item uuid; v_from uuid; v_to uuid; v_qty numeric;
  v_before numeric; v_before_val numeric; v_after numeric; v_after_val numeric;
  c record;
  v_wh_to text;
begin
  if not private.has_role('PGB') then
    raise exception 'Hanya Pengurus Barang yang dapat memindahkan lokasi penyimpanan.' using errcode = '42501';
  end if;
  if length(trim(coalesce(p_reason, ''))) < 5 then
    raise exception 'Alasan perpindahan wajib diisi (minimal 5 karakter).' using errcode = '22023';
  end if;
  if jsonb_array_length(coalesce(p_lines, '[]'::jsonb)) = 0 then
    raise exception 'Isi minimal satu barang yang dipindahkan.' using errcode = '22023';
  end if;
  if p_date > (now() at time zone 'Asia/Jakarta')::date then
    raise exception 'Tanggal perpindahan tidak boleh di masa depan.' using errcode = '22023';
  end if;

  perform private.begin_rpc('Perpindahan lokasi');
  v_no := private.next_document_number('PND', p_date);
  insert into public.stock_transfers (transfer_no, transfer_date, reason, created_by)
  values (v_no, p_date, trim(p_reason), v_uid) returning id into v_id;

  for l in select * from jsonb_array_elements(p_lines) loop
    v_item := (l ->> 'item_id')::uuid;
    v_from := (l ->> 'from_location_id')::uuid;
    v_to   := (l ->> 'to_location_id')::uuid;
    v_qty  := (l ->> 'quantity')::numeric;
    if v_from = v_to then
      raise exception 'Lokasi asal dan tujuan harus berbeda.' using errcode = '22023';
    end if;
    select w.name into v_wh_to from public.storage_locations s join public.warehouses w on w.id = s.warehouse_id
     where s.id = v_to and s.is_active;
    if v_wh_to is null then
      raise exception 'Lokasi tujuan tidak aktif atau tidak ditemukan.' using errcode = 'P0001';
    end if;

    perform private.lock_item(v_item);
    select coalesce(sum(quantity), 0), coalesce(sum(total_value), 0) into v_before, v_before_val
      from public.stock_balances where item_id = v_item;

    insert into public.stock_transfer_details (transfer_id, item_id, from_location_id, to_location_id, quantity)
    values (v_id, v_item, v_from, v_to, v_qty);

    for c in select * from private.consume_stock('TRANSFER_OUT', p_date, v_item, v_from, 'layak_pakai', v_qty,
                                                 'stock_transfers', v_id, v_no,
                                                 'Pindah ke ' || (select code from public.storage_locations where id = v_to) || ': ' || trim(p_reason))
    loop
      perform private.stock_in('TRANSFER_IN', p_date, v_item, v_to, 'layak_pakai', c.qty, c.unit_cost, c.acquired_at,
                               c.expiry_date, null, c.batch_id, 'stock_transfers', v_id, v_no,
                               'Pindah dari ' || (select code from public.storage_locations where id = v_from) || ': ' || trim(p_reason));
    end loop;

    select coalesce(sum(quantity), 0), coalesce(sum(total_value), 0) into v_after, v_after_val
      from public.stock_balances where item_id = v_item;
    if v_after <> v_before or v_after_val <> v_before_val then
      raise exception 'Perpindahan dibatalkan: total saldo berubah (% -> %).', v_before, v_after using errcode = 'P0001';
    end if;
  end loop;
  perform private.end_rpc();
  return v_id;
end $$;

-- ---------------------------------------------------------------------
-- KARTU STOK
-- ---------------------------------------------------------------------
create or replace function public.rpc_stock_card(p_item uuid, p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_open_qty numeric; v_open_val numeric;
  v_rows jsonb;
  v_in numeric; v_out numeric; v_vin numeric; v_vout numeric;
begin
  perform private.require_active_user();
  if not private.has_any_role(private.stock_reader_roles() || array['ATS']) then
    raise exception 'Anda tidak berwenang melihat kartu stok.' using errcode = '42501';
  end if;
  if p_from > p_to then
    raise exception 'Tanggal awal tidak boleh setelah tanggal akhir.' using errcode = '22023';
  end if;

  -- Saldo awal periode = seluruh mutasi sebelum tanggal awal.
  select coalesce(sum(m.qty_in - m.qty_out), 0), coalesce(sum(m.value_in - m.value_out), 0)
    into v_open_qty, v_open_val
    from public.stock_movements m where m.item_id = p_item and m.movement_date < p_from;

  -- Saldo berjalan dihitung menurut urutan TANGGAL (bukan urutan pencatatan).
  with r as (
    select m.*, s.code as location_code,
           v_open_qty + sum(m.qty_in - m.qty_out) over w as run_qty,
           v_open_val + sum(m.value_in - m.value_out) over w as run_val
      from public.stock_movements m join public.storage_locations s on s.id = m.location_id
     where m.item_id = p_item and m.movement_date between p_from and p_to
    window w as (order by m.movement_date, m.id rows between unbounded preceding and current row)
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'date', r.movement_date, 'ref_no', r.ref_no, 'ref_table', r.ref_table, 'ref_id', r.ref_id,
           'type', r.movement_type, 'description', r.description,
           'location', r.location_code, 'qty_in', r.qty_in, 'qty_out', r.qty_out, 'unit_cost', r.unit_cost,
           'value', r.value_in + r.value_out, 'balance_qty', r.run_qty, 'balance_value', r.run_val)
           order by r.movement_date, r.id), '[]'::jsonb),
         coalesce(sum(r.qty_in) filter (where r.movement_type <> 'TRANSFER_IN'), 0),
         coalesce(sum(r.qty_out) filter (where r.movement_type <> 'TRANSFER_OUT'), 0),
         coalesce(sum(r.value_in) filter (where r.movement_type <> 'TRANSFER_IN'), 0),
         coalesce(sum(r.value_out) filter (where r.movement_type <> 'TRANSFER_OUT'), 0)
    into v_rows, v_in, v_out, v_vin, v_vout
    from r;

  return jsonb_build_object(
    'opening_qty', v_open_qty, 'opening_value', v_open_val,
    'total_in', v_in, 'total_out', v_out, 'total_in_value', v_vin, 'total_out_value', v_vout,
    'closing_qty', v_open_qty + v_in - v_out, 'closing_value', v_open_val + v_vin - v_vout,
    'rows', v_rows);
end $$;

-- Pemeriksaan konsistensi: mutasi = batch = saldo untuk setiap barang.
create or replace function public.rpc_verify_stock()
returns table (item_id uuid, item_code text, movements_qty numeric, batches_qty numeric, balances_qty numeric)
language plpgsql stable security definer set search_path = '' as $$
begin
  perform private.require_active_user();
  if not private.has_any_role(array['PGB','KPA','PWS','AKT','AUD']) then
    raise exception 'Anda tidak berwenang.' using errcode = '42501';
  end if;
  return query
  with m as (select sm.item_id, sum(sm.qty_in - sm.qty_out) q from public.stock_movements sm group by sm.item_id),
       b as (select sb.item_id, sum(sb.qty_remaining) q from public.stock_batches sb group by sb.item_id),
       s as (select sl.item_id, sum(sl.quantity) q from public.stock_balances sl group by sl.item_id)
  select i.id, i.code, coalesce(m.q, 0), coalesce(b.q, 0), coalesce(s.q, 0)
    from public.items i left join m on m.item_id = i.id left join b on b.item_id = i.id left join s on s.item_id = i.id
   where coalesce(m.q, 0) <> coalesce(b.q, 0) or coalesce(b.q, 0) <> coalesce(s.q, 0);
end $$;

-- ---------------------------------------------------------------------
-- Ringkasan saldo per barang (untuk halaman Penyimpanan)
-- ---------------------------------------------------------------------
create or replace view public.v_stock_summary with (security_invoker = true) as
select i.id as item_id, i.code, i.name, i.category_id, i.unit_id, i.min_stock, i.safety_stock, i.max_stock,
       i.has_expiry, i.is_active,
       coalesce(sum(b.quantity) filter (where b.condition = 'layak_pakai'), 0) as qty_good,
       coalesce(sum(b.quantity) filter (where b.condition <> 'layak_pakai'), 0) as qty_other,
       coalesce(sum(b.reserved_qty), 0) as qty_reserved,
       coalesce(sum(b.total_value), 0) as total_value,
       max(b.last_movement_at) as last_movement_at
  from public.items i
  left join public.stock_balances b on b.item_id = i.id
 group by i.id;

-- ---------------------------------------------------------------------
-- RLS & hak akses
-- ---------------------------------------------------------------------
alter table public.receipts               enable row level security;
alter table public.receipt_details        enable row level security;
alter table public.stock_batches          enable row level security;
alter table public.stock_balances         enable row level security;
alter table public.stock_movements        enable row level security;
alter table public.stock_transfers        enable row level security;
alter table public.stock_transfer_details enable row level security;
alter table public.approvals              enable row level security;
alter table public.status_histories       enable row level security;
alter table public.attachments            enable row level security;

revoke all on public.receipts, public.receipt_details, public.stock_batches, public.stock_balances,
              public.stock_movements, public.stock_transfers, public.stock_transfer_details,
              public.approvals, public.status_histories, public.attachments, public.v_stock_summary
  from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;

grant select, insert, update         on public.receipts        to authenticated;
grant select, insert, update, delete on public.receipt_details to authenticated;
grant select on public.stock_batches, public.stock_balances, public.stock_movements,
                public.stock_transfers, public.stock_transfer_details,
                public.approvals, public.status_histories, public.v_stock_summary to authenticated;
grant select, insert on public.attachments to authenticated;

-- Penerimaan
drop policy if exists receipts_select on public.receipts;
create policy receipts_select on public.receipts for select to authenticated
  using ((select private.current_user_is_active()) and (select private.has_any_role(private.receipt_reader_roles())));
drop policy if exists receipts_insert on public.receipts;
create policy receipts_insert on public.receipts for insert to authenticated
  with check ((select private.has_any_role(array['PGB','PPB'])) and (select private.current_user_is_active()));
drop policy if exists receipts_update on public.receipts;
create policy receipts_update on public.receipts for update to authenticated
  using (created_by = (select auth.uid()) and status = 'draft')
  with check (created_by = (select auth.uid()));

drop policy if exists receipt_details_select on public.receipt_details;
create policy receipt_details_select on public.receipt_details for select to authenticated
  using ((select private.current_user_is_active()) and (select private.has_any_role(private.receipt_reader_roles())));
drop policy if exists receipt_details_insert on public.receipt_details;
create policy receipt_details_insert on public.receipt_details for insert to authenticated
  with check (exists (select 1 from public.receipts r where r.id = receipt_id and r.created_by = (select auth.uid()) and r.status = 'draft'));
drop policy if exists receipt_details_update on public.receipt_details;
create policy receipt_details_update on public.receipt_details for update to authenticated
  using (exists (select 1 from public.receipts r where r.id = receipt_id and r.created_by = (select auth.uid()) and r.status = 'draft'))
  with check (exists (select 1 from public.receipts r where r.id = receipt_id and r.created_by = (select auth.uid()) and r.status = 'draft'));
drop policy if exists receipt_details_delete on public.receipt_details;
create policy receipt_details_delete on public.receipt_details for delete to authenticated
  using (exists (select 1 from public.receipts r where r.id = receipt_id and r.created_by = (select auth.uid()) and r.status = 'draft'));

-- Stok (hanya baca)
do $$
declare t text;
begin
  foreach t in array array['stock_batches','stock_balances','stock_movements','stock_transfers','stock_transfer_details'] loop
    execute format('drop policy if exists %I on public.%I', t || '_select', t);
    execute format('create policy %I on public.%I for select to authenticated
                    using ((select private.current_user_is_active()) and (select private.has_any_role(private.stock_reader_roles())))',
                   t || '_select', t);
  end loop;
end $$;

-- Persetujuan, riwayat, lampiran
drop policy if exists approvals_select on public.approvals;
create policy approvals_select on public.approvals for select to authenticated
  using (private.can_read_ref(ref_table, ref_id));
drop policy if exists status_histories_select on public.status_histories;
create policy status_histories_select on public.status_histories for select to authenticated
  using (private.can_read_ref(ref_table, ref_id));
drop policy if exists attachments_select on public.attachments;
create policy attachments_select on public.attachments for select to authenticated
  using (private.can_read_ref(ref_table, ref_id));
drop policy if exists attachments_insert on public.attachments;
create policy attachments_insert on public.attachments for insert to authenticated
  with check (private.can_attach(ref_table, ref_id)
              and storage_path like ref_table || '/' || ref_id::text || '/%');

create or replace function private.tg_attachment_meta()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  new.uploaded_by := auth.uid();
  new.uploaded_at := now();
  return new;
end $$;
revoke all on function private.tg_attachment_meta() from public;
drop trigger if exists trg_attachment_meta on public.attachments;
create trigger trg_attachment_meta before insert on public.attachments
  for each row execute function private.tg_attachment_meta();

-- ---------------------------------------------------------------------
-- Penyimpanan dokumen (Supabase Storage, bucket privat)
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('documents', 'documents', false, 10485760,
        array['application/pdf','image/jpeg','image/png','image/webp'])
on conflict (id) do nothing;

drop policy if exists sipp_documents_insert on storage.objects;
create policy sipp_documents_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'documents' and private.can_attach_path(name));
drop policy if exists sipp_documents_select on storage.objects;
create policy sipp_documents_select on storage.objects for select to authenticated
  using (bucket_id = 'documents' and private.can_read_path(name));

-- ---------------------------------------------------------------------
-- Hak eksekusi
-- ---------------------------------------------------------------------
do $$
declare f text;
begin
  foreach f in array array[
    'private.begin_rpc(text)','private.end_rpc()','private.require_active_user()','private.lock_item(uuid)',
    'private.refresh_balance(uuid,uuid,text)','private.assert_not_backdated(uuid,date)',
    'private.record_movement(text,date,uuid,uuid,uuid,text,numeric,numeric,numeric,text,uuid,text,text)',
    'private.stock_in(text,date,uuid,uuid,text,numeric,numeric,date,date,uuid,uuid,text,uuid,text,text)',
    'private.consume_stock(text,date,uuid,uuid,text,numeric,text,uuid,text,text)',
    'private.receipt_for_update(uuid)','private.receipt_expect(public.receipts,text[])'] loop
    execute format('revoke all on function %s from public', f);
  end loop;
  foreach f in array array[
    'private.stock_reader_roles()','private.receipt_reader_roles()','private.can_read_ref(text,uuid)',
    'private.can_attach(text,uuid)','private.path_ref(text)','private.can_attach_path(text)',
    'private.can_read_path(text)','private.receipt_status_label(text)'] loop
    execute format('revoke all on function %s from public', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
  foreach f in array array[
    'public.rpc_receipt_submit(uuid)','public.rpc_receipt_start_inspection(uuid)',
    'public.rpc_receipt_record_inspection(uuid,jsonb,text,text)','public.rpc_receipt_vendor_followup(uuid,text)',
    'public.rpc_receipt_decide(uuid,text,text)','public.rpc_receipt_finalize(uuid,jsonb)',
    'public.rpc_receipt_verify_accounting(uuid,text)','public.rpc_receipt_cancel(uuid,text)',
    'public.rpc_transfer_stock(date,text,jsonb)','public.rpc_stock_card(uuid,date,date)','public.rpc_verify_stock()'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- Dashboard: indikator persediaan untuk fungsi yang berhak melihat saldo
-- ---------------------------------------------------------------------
create or replace function public.rpc_dashboard_overview()
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_roles   text[] := private.my_role_codes();
  v_result  jsonb;
  v_today   date := (now() at time zone 'Asia/Jakarta')::date;
begin
  if auth.uid() is null or not private.current_user_is_active() then
    raise exception 'Sesi tidak valid atau akun nonaktif.' using errcode = '42501';
  end if;

  v_result := jsonb_build_object(
    'roles', to_jsonb(v_roles),
    'unread_notifications',
      (select count(*) from public.notifications n where n.user_id = auth.uid() and not n.is_read),
    'active_units', (select count(*) from public.organizational_units where is_active),
    'active_items', (select count(*) from public.items where is_active),
    'mfa_required', private.role_requires_mfa('SA') and 'SA' = any(v_roles),
    'mfa_satisfied', private.mfa_satisfied(),
    'generated_at', now());

  if v_roles && array['SA','PGB','KPA','PWS'] then
    v_result := v_result || jsonb_build_object(
      'proposed_items', (select count(*) from public.items where not is_active and activated_at is null));
  end if;

  if v_roles && private.stock_reader_roles() then
    v_result := v_result || jsonb_build_object(
      'stock', jsonb_build_object(
        'total_value', (select coalesce(sum(total_value), 0) from public.stock_balances),
        'items_in_stock', (select count(distinct item_id) from public.stock_balances where quantity > 0),
        'below_min', (select count(*) from public.v_stock_summary s where s.is_active and s.qty_good <= s.min_stock),
        'above_max', (select count(*) from public.v_stock_summary s where s.max_stock is not null and s.qty_good > s.max_stock),
        'expiring', (select count(*) from public.stock_batches b where b.qty_remaining > 0 and b.expiry_date is not null
                       and b.expiry_date <= v_today + coalesce((select (value #>> '{}')::int from public.app_settings where key = 'expiry_warning_days'), 90)),
        'receipts_month', (select count(*) from public.receipts r where r.status in ('diterima_disimpan','selesai')
                             and date_trunc('month', r.receipt_date) = date_trunc('month', v_today)),
        'receipts_open', (select count(*) from public.receipts r where r.status not in ('selesai','dibatalkan'))));
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

-- >>>>> 20261121001100_alur_penerimaan_tanpa_kpa.sql
-- =====================================================================
-- SIPP — Migration 0011: Perubahan keputusan pengguna (21-11-2026)
-- 1. Role KPA DIHAPUS dari aplikasi: dinonaktifkan (riwayat tetap utuh),
--    tidak dapat ditetapkan lagi; tugas persetujuannya dialihkan ke
--    Pejabat Pengawas (PWS) dan tetap dapat diubah di Pengaturan.
-- 2. Alur penerimaan:
--    * pencatatan hanya oleh Petugas Penerima Barang (PPB);
--    * pemeriksaan SEKALIGUS pengesahan oleh PPK (pembelian) atau
--      Pejabat Pengawas (hibah, transfer, perolehan lain, saldo awal);
--    * penyimpanan ke gudang tetap oleh Pengurus Barang.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Role tidak aktif
-- ---------------------------------------------------------------------
alter table public.roles add column if not exists is_active boolean not null default true;
update public.roles set is_active = false where code = 'KPA';

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
     and r.is_active
     and p.is_active
     and current_date >= ur.valid_from
     and (ur.valid_until is null or current_date <= ur.valid_until);
$$;

-- Penetapan role: tolak role yang sudah tidak digunakan.
create or replace function private.tg_user_roles_guard()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_code        text;
  v_role_active boolean;
  v_other_codes text[];
  v_active_sa   integer;
  c_conflict_sa constant text[] := array['KPA','PWS','PGB','ATS','AKT'];
begin
  select code, is_active into v_code, v_role_active from public.roles where id = new.role_id;

  if auth.uid() is not null and new.user_id = auth.uid() then
    raise exception 'Anda tidak dapat mengubah role Anda sendiri.' using errcode = '42501';
  end if;

  if tg_op = 'UPDATE' and (new.user_id <> old.user_id or new.role_id <> old.role_id) then
    raise exception 'Pengguna dan role pada penugasan tidak dapat diganti; nonaktifkan lalu buat penugasan baru.'
      using errcode = '22023';
  end if;

  if new.is_active and not v_role_active then
    raise exception 'Role % sudah tidak digunakan dalam aplikasi.', v_code using errcode = '23514';
  end if;

  if v_code in ('ATS','PGW') and new.unit_id is null then
    raise exception 'Role % wajib memiliki unit kerja.', v_code using errcode = '23514';
  end if;
  if v_code not in ('ATS','PGW') and new.unit_id is not null then
    raise exception 'Role % berlaku untuk seluruh satuan kerja; unit kerja harus dikosongkan.', v_code
      using errcode = '23514';
  end if;

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
   where ur.user_id = new.user_id and ur.is_active and r.is_active and ur.id <> new.id;

  if (v_code = 'AUD' and cardinality(v_other_codes) > 0) or (v_code <> 'AUD' and 'AUD' = any(v_other_codes)) then
    raise exception 'Auditor/APIP tidak boleh merangkap role lain (pemisahan fungsi).' using errcode = '23514';
  end if;
  if (v_code = 'SA' and v_other_codes && c_conflict_sa)
     or (v_code = any(c_conflict_sa) and 'SA' = any(v_other_codes)) then
    raise exception 'Super Admin tidak boleh merangkap role PWS, PGB, ATS, atau AKT (pemisahan fungsi).'
      using errcode = '23514';
  end if;
  return new;
end;
$$;

-- Nonaktifkan seluruh penugasan KPA (konteks sistem; tercatat di audit trail).
update public.user_roles ur set is_active = false
  from public.roles r
 where r.id = ur.role_id and r.code = 'KPA' and ur.is_active;

-- Alihkan tugas persetujuan KPA ke Pejabat Pengawas.
update public.approval_settings a
   set approver_role_code = 'PWS',
       description = coalesce(a.description, '') || ' (dialihkan dari KPA)'
 where a.approver_role_code = 'KPA'
   and not exists (select 1 from public.approval_settings b
                    where b.transaction_type = a.transaction_type and b.level = a.level and b.approver_role_code = 'PWS');
update public.approval_settings set is_active = false where approver_role_code = 'KPA';

update public.approval_settings
   set description = 'Pemeriksaan & pengesahan penerimaan pembelian'
 where transaction_type = 'receipt' and approver_role_code = 'PPK';
update public.approval_settings
   set description = 'Pemeriksaan & pengesahan penerimaan hibah, transfer, perolehan lain, dan saldo awal'
 where transaction_type = 'receipt' and approver_role_code = 'PWS';

-- ---------------------------------------------------------------------
-- 2. Alur penerimaan baru
-- ---------------------------------------------------------------------
-- Role pemeriksa (sekaligus pengesah) yang dimiliki pengguna untuk sumber tertentu.
create or replace function private.receipt_inspector_role(p_source text)
returns text language sql stable security definer set search_path = '' as $$
  select a.approver_role_code
    from public.approval_settings a
   where a.transaction_type = 'receipt' and a.is_active
     and (a.applies_when = '{}'::jsonb or (a.applies_when -> 'source_type') ? p_source)
     and private.has_role(a.approver_role_code)
   order by a.level limit 1;
$$;
revoke all on function private.receipt_inspector_role(text) from public;
grant execute on function private.receipt_inspector_role(text) to authenticated;

-- Pencatatan hanya oleh Petugas Penerima Barang.
drop policy if exists receipts_insert on public.receipts;
create policy receipts_insert on public.receipts for insert to authenticated
  with check ((select private.has_role('PPB')) and (select private.current_user_is_active()));

-- Lampiran: pencatat & pemeriksa, sebelum pengesahan.
create or replace function private.can_attach(p_table text, p_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select private.current_user_is_active() and case p_table
    when 'receipts' then private.has_any_role(array['PPB','PPK','PWS'])
      and exists (select 1 from public.receipts r where r.id = p_id and r.status in
        ('draft','menunggu_pemeriksaan','dalam_pemeriksaan','tidak_sesuai','menunggu_tindak_lanjut_penyedia'))
    when 'stock_transfers' then private.has_role('PGB')
    else false end;
$$;

-- Pengesahan terpisah tidak dipakai lagi.
drop function if exists public.rpc_receipt_decide(uuid, text, text);

create or replace function public.rpc_receipt_start_inspection(p_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare r public.receipts; v_uid uuid := private.require_active_user();
begin
  r := private.receipt_for_update(p_id);
  if private.receipt_inspector_role(r.source_type) is null then
    raise exception 'Anda tidak berwenang memeriksa penerimaan ini (pembelian: PPK; sumber lain: Pejabat Pengawas).'
      using errcode = '42501';
  end if;
  perform private.receipt_expect(r, array['menunggu_pemeriksaan','menunggu_tindak_lanjut_penyedia']);
  if r.created_by = v_uid then
    raise exception 'Pencatat penerimaan tidak boleh memeriksa penerimaannya sendiri (pemisahan fungsi).' using errcode = '42501';
  end if;
  perform private.begin_rpc('Pemeriksaan dimulai');
  update public.receipts set status = 'dalam_pemeriksaan', inspector_id = v_uid where id = p_id;
  perform private.end_rpc();
end $$;

-- Pemeriksaan sekaligus pengesahan.
-- p_decision: 'lanjut' = sahkan barang yang diterima baik | 'tindak_lanjut' = ketidaksesuaian
create or replace function public.rpc_receipt_record_inspection(p_id uuid, p_lines jsonb, p_notes text, p_decision text)
returns void language plpgsql security definer set search_path = '' as $$
declare
  r public.receipts;
  v_uid uuid := private.require_active_user();
  v_role text;
  l jsonb;
  d record;
  v_acc numeric; v_rej numeric; v_rec numeric; v_res text; v_exp date;
  v_issue boolean := false;
  v_total_acc numeric := 0;
  v_missing integer;
  v_docs text[] := '{}';
begin
  r := private.receipt_for_update(p_id);
  perform private.receipt_expect(r, array['dalam_pemeriksaan']);
  if r.inspector_id is distinct from v_uid then
    raise exception 'Hanya pemeriksa yang memulai pemeriksaan yang dapat mencatat hasilnya.' using errcode = '42501';
  end if;
  v_role := private.receipt_inspector_role(r.source_type);
  if v_role is null then
    raise exception 'Anda tidak lagi berwenang memeriksa penerimaan ini.' using errcode = '42501';
  end if;
  if p_decision not in ('lanjut','tindak_lanjut') then
    raise exception 'Keputusan pemeriksaan tidak dikenal.' using errcode = '22023';
  end if;

  perform private.begin_rpc(case p_decision when 'lanjut' then 'Diperiksa dan disahkan'
                                            else 'Ditemukan ketidaksesuaian' end);
  for l in select * from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) loop
    select d2.*, i.has_expiry, i.code into d
      from public.receipt_details d2 join public.items i on i.id = d2.item_id
     where d2.id = (l ->> 'detail_id')::uuid and d2.receipt_id = p_id;
    if not found then
      raise exception 'Rincian penerimaan tidak dikenal.' using errcode = 'P0002';
    end if;
    v_rec := coalesce((l ->> 'qty_received')::numeric, d.qty_received);
    v_acc := coalesce((l ->> 'qty_accepted')::numeric, 0);
    v_rej := coalesce((l ->> 'qty_rejected')::numeric, 0);
    v_res := l ->> 'result';
    v_exp := nullif(l ->> 'expiry_date', '')::date;
    if v_rec <= 0 or v_acc < 0 or v_rej < 0 or v_acc + v_rej <> v_rec then
      raise exception 'Barang %: jumlah diterima baik + ditolak harus sama dengan jumlah yang datang.', d.code using errcode = '22023';
    end if;
    if v_res is null or v_res not in ('sesuai','tidak_sesuai_jumlah','tidak_sesuai_spesifikasi','rusak') then
      raise exception 'Barang %: pilih hasil pemeriksaan.', d.code using errcode = '22023';
    end if;
    if v_res = 'sesuai' and v_rej > 0 then
      raise exception 'Barang %: hasil "sesuai" tidak boleh memiliki jumlah ditolak.', d.code using errcode = '22023';
    end if;
    if d.has_expiry and v_acc > 0 and v_exp is null then
      raise exception 'Barang % wajib diisi tanggal kedaluwarsa.', d.code using errcode = '22023';
    end if;
    if v_res <> 'sesuai' or v_rej > 0 or (d.qty_ordered is not null and v_rec <> d.qty_ordered) then
      v_issue := true;
    end if;
    update public.receipt_details
       set qty_received = v_rec, qty_accepted = v_acc, qty_rejected = v_rej,
           inspection_result = v_res, inspection_notes = nullif(trim(l ->> 'notes'), ''), expiry_date = v_exp
     where id = d.id;
  end loop;

  select count(*) into v_missing from public.receipt_details where receipt_id = p_id and inspection_result is null;
  if v_missing > 0 then
    raise exception 'Semua barang harus diperiksa (% belum).', v_missing using errcode = 'P0001';
  end if;
  select coalesce(sum(qty_accepted), 0) into v_total_acc from public.receipt_details where receipt_id = p_id;

  if p_decision = 'tindak_lanjut' then
    if not v_issue then
      raise exception 'Tidak ada ketidaksesuaian yang dicatat.' using errcode = 'P0001';
    end if;
    update public.receipts
       set status = 'tidak_sesuai', inspected_at = now(), inspection_notes = nullif(trim(coalesce(p_notes, '')), '')
     where id = p_id;
    perform private.end_rpc();
    return;
  end if;

  if v_total_acc <= 0 then
    raise exception 'Tidak ada barang yang diterima baik; pilih catat ketidaksesuaian.' using errcode = 'P0001';
  end if;

  -- Dokumen wajib sebelum pengesahan.
  if r.source_type = 'saldo_awal' then
    if not exists (select 1 from public.attachments where ref_table = 'receipts' and ref_id = p_id and doc_type = 'ba_saldo_awal') then
      v_docs := v_docs || 'Berita Acara Saldo Awal';
    end if;
  else
    if not exists (select 1 from public.attachments where ref_table = 'receipts' and ref_id = p_id and doc_type = 'ba_pemeriksaan') then
      v_docs := v_docs || 'Berita Acara Pemeriksaan';
    end if;
    if r.source_type = 'pembelian' and not exists (
         select 1 from public.attachments where ref_table = 'receipts' and ref_id = p_id and doc_type in ('surat_jalan','faktur')) then
      v_docs := v_docs || 'Surat Jalan atau Faktur';
    end if;
  end if;
  if cardinality(v_docs) > 0 then
    raise exception 'Dokumen wajib belum diunggah: %.', array_to_string(v_docs, ', ') using errcode = 'P0001';
  end if;

  insert into public.approvals (ref_table, ref_id, level, required_role_code, approver_id, decision, notes)
  values ('receipts', p_id, 1, v_role, v_uid, 'approved', nullif(trim(coalesce(p_notes, '')), ''));
  update public.receipts
     set status = 'disetujui', inspected_at = now(), approved_by = v_uid, approved_at = now(),
         inspection_notes = nullif(trim(coalesce(p_notes, '')), ''),
         total_value = (select coalesce(round(sum(qty_accepted * unit_cost), 2), 0) from public.receipt_details where receipt_id = p_id)
   where id = p_id;
  perform private.end_rpc();
end $$;

create or replace function public.rpc_receipt_vendor_followup(p_id uuid, p_comment text)
returns void language plpgsql security definer set search_path = '' as $$
declare r public.receipts;
begin
  perform private.require_active_user();
  if not private.has_any_role(array['PPK','PWS','PPB']) then
    raise exception 'Hanya PPK, Pejabat Pengawas, atau Petugas Penerima Barang yang dapat meneruskan tindak lanjut.' using errcode = '42501';
  end if;
  r := private.receipt_for_update(p_id);
  perform private.receipt_expect(r, array['tidak_sesuai']);
  if length(trim(coalesce(p_comment, ''))) < 5 then
    raise exception 'Tuliskan tindak lanjut yang diminta (minimal 5 karakter).' using errcode = '22023';
  end if;
  perform private.begin_rpc(p_comment);
  update public.receipts set status = 'menunggu_tindak_lanjut_penyedia' where id = p_id;
  perform private.end_rpc();
end $$;

create or replace function public.rpc_receipt_cancel(p_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare r public.receipts; v_uid uuid := private.require_active_user();
begin
  r := private.receipt_for_update(p_id);
  perform private.receipt_expect(r, array['draft','menunggu_pemeriksaan','tidak_sesuai','menunggu_tindak_lanjut_penyedia']);
  if r.created_by is distinct from v_uid then
    raise exception 'Hanya pencatat penerimaan yang dapat membatalkannya.' using errcode = '42501';
  end if;
  if length(trim(coalesce(p_reason, ''))) < 5 then
    raise exception 'Alasan pembatalan wajib diisi (minimal 5 karakter).' using errcode = '22023';
  end if;
  perform private.begin_rpc('Dibatalkan: ' || p_reason);
  update public.receipts set status = 'dibatalkan', cancel_reason = p_reason where id = p_id;
  perform private.end_rpc();
end $$;

-- Penerimaan yang sedang diperiksa/menunggu pengesahan dengan aturan lama
-- dikembalikan ke antrean pemeriksaan agar diperiksa ulang oleh PPK/PWS.
do $$
begin
  perform private.begin_rpc('Dikembalikan ke antrean pemeriksaan karena perubahan alur (pemeriksa: PPK / Pejabat Pengawas)');
  -- Hanya yang diperiksa dengan aturan lama: status "menunggu pengesahan", atau
  -- sedang diperiksa oleh orang yang bukan PPK/Pejabat Pengawas. Aman dijalankan ulang.
  update public.receipts r
     set status = 'menunggu_pemeriksaan', inspector_id = null, inspected_at = null
   where r.status = 'menunggu_pengesahan'
      or (r.status = 'dalam_pemeriksaan' and not exists (
            select 1 from public.user_roles ur join public.roles ro on ro.id = ur.role_id
             where ur.user_id = r.inspector_id and ur.is_active and ro.code in ('PPK','PWS')));
  perform private.end_rpc();
end $$;

-- >>>>> 20261121001200_akuntansi_hanya_rekonsiliasi.sql
-- =====================================================================
-- SIPP — Migration 0012: Petugas Akuntansi hanya untuk Rekonsiliasi
-- Keputusan pemilik produk 21-11-2026.
-- * Role AKT tetap ada, tetapi hanya berperan menyusun Rekonsiliasi:
--   tidak terlibat penerimaan; tetap dapat membaca saldo & nilai
--   persediaan (bahan rekonsiliasi).
-- * Langkah "verifikasi akuntansi" pada penerimaan ditiadakan: penerimaan
--   SELESAI saat Pengurus Barang menyimpannya ke gudang.
-- Aman dijalankan ulang.
-- =====================================================================

-- Pastikan role AKT aktif (memulihkan bila versi sebelumnya sempat menonaktifkannya).
update public.roles set is_active = true, description = 'Menyusun rekonsiliasi persediaan' where code = 'AKT';

-- AKT tidak lagi membaca data penerimaan.
create or replace function private.receipt_reader_roles()
returns text[] language sql immutable set search_path = '' as $$
  select array['PGB','PPB','PPK','PWS','AUD'];
$$;

create or replace function public.rpc_receipt_finalize(p_id uuid, p_locations jsonb default '{}'::jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare
  r public.receipts;
  v_uid uuid := private.require_active_user();
  d record;
  v_loc uuid;
  v_type text;
  v_desc text;
begin
  if not private.has_role('PGB') then
    raise exception 'Hanya Pengurus Barang yang dapat menyimpan barang ke gudang.' using errcode = '42501';
  end if;
  r := private.receipt_for_update(p_id);
  perform private.receipt_expect(r, array['disetujui']);

  v_type := case when r.source_type = 'saldo_awal' then 'OPENING_BALANCE' else 'RECEIPT_IN' end;
  v_desc := case r.source_type
    when 'saldo_awal' then 'Saldo awal'
    when 'pembelian' then 'Pembelian dari ' || coalesce((select name from public.suppliers where id = r.supplier_id), '-')
    when 'hibah' then 'Hibah: ' || coalesce(r.source_description, '-')
    when 'transfer' then 'Transfer masuk: ' || coalesce(r.source_description, '-')
    else 'Perolehan lain: ' || coalesce(r.source_description, '-') end;

  perform private.begin_rpc('Barang disimpan ke gudang, saldo bertambah; penerimaan selesai');
  for d in
    select * from public.receipt_details where receipt_id = p_id and qty_accepted > 0 order by item_id, line_no
  loop
    v_loc := coalesce(nullif(p_locations ->> d.id::text, '')::uuid, d.location_id);
    if v_loc is null then
      raise exception 'Pilih lokasi penyimpanan untuk semua barang yang diterima.' using errcode = 'P0001';
    end if;
    if not exists (select 1 from public.storage_locations where id = v_loc and is_active and warehouse_id = r.warehouse_id) then
      raise exception 'Lokasi penyimpanan harus aktif dan berada di gudang penerimaan.' using errcode = 'P0001';
    end if;
    update public.receipt_details set location_id = v_loc where id = d.id;
    perform private.lock_item(d.item_id);
    perform private.stock_in(v_type, r.receipt_date, d.item_id, v_loc, 'layak_pakai', d.qty_accepted, d.unit_cost,
                             r.receipt_date, d.expiry_date, d.id, null, 'receipts', r.id, r.receipt_no, v_desc);
  end loop;
  update public.receipts set status = 'selesai', finalized_by = v_uid, finalized_at = now() where id = p_id;
  perform private.end_rpc();
end $$;

drop function if exists public.rpc_receipt_verify_accounting(uuid, text);

-- Penerimaan yang menunggu verifikasi akuntansi dengan aturan lama -> selesai.
do $$
begin
  perform private.begin_rpc('Selesai: langkah verifikasi akuntansi ditiadakan');
  update public.receipts set status = 'selesai' where status = 'diterima_disimpan';
  perform private.end_rpc();
end $$;

-- >>>>> 20261121001300_tanggal_wib_role.sql
-- =====================================================================
-- SIPP — Migration 0013: Masa berlaku role memakai tanggal WIB
-- Masalah: server database memakai zona UTC. Antara pukul 00.00–07.00 WIB
-- tanggal UTC masih "kemarin", sehingga role yang berlaku mulai hari ini
-- (tanggal WIB) dianggap belum berlaku dan pengguna tampil "Belum memiliki
-- role". Perbaikan: semua pemeriksaan masa berlaku memakai tanggal WIB.
-- Aman dijalankan ulang; tidak mengubah data.
-- =====================================================================

create or replace function private.today_jakarta()
returns date
language sql stable set search_path = ''
as $$
  select (now() at time zone 'Asia/Jakarta')::date;
$$;

alter table public.user_roles
  alter column valid_from set default ((now() at time zone 'Asia/Jakarta')::date);

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
     and r.is_active
     and p.is_active
     and private.today_jakarta() >= ur.valid_from
     and (ur.valid_until is null or private.today_jakarta() <= ur.valid_until);
$$;

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
       and private.today_jakarta() >= ur.valid_from
       and (ur.valid_until is null or private.today_jakarta() <= ur.valid_until)
       and private.current_user_is_active()
    union
    select private.unit_with_descendants(u.id)
      from public.organizational_units u
     where p_code = 'ATS' and u.head_user_id = auth.uid() and u.is_active
       and private.current_user_is_active()
  ) s;
$$;

revoke all on function private.today_jakarta() from public;
grant execute on function private.today_jakarta() to authenticated, service_role;
revoke all on function private.my_role_codes() from public;
grant execute on function private.my_role_codes() to authenticated, service_role;
revoke all on function private.my_scope_unit_ids(text) from public;
grant execute on function private.my_scope_unit_ids(text) to authenticated, service_role;

-- >>>>> 20261121001400_kedaluwarsa_oleh_penerima.sql
-- =====================================================================
-- SIPP — Migration 0014: Tanggal kedaluwarsa diisi Petugas Penerima Barang
-- Keputusan pemilik produk 21-11-2026: tanggal kedaluwarsa wajib diisi
-- Petugas Penerima Barang saat mencatat rincian barang. PPK / Pejabat
-- Pengawas hanya memeriksa dan mengesahkan tanggal tersebut (tidak dapat
-- mengubahnya). Bila tanggal salah, pemeriksa mencatat ketidaksesuaian dan
-- Petugas Penerima Barang memperbaikinya sebelum diperiksa ulang.
-- Aman dijalankan ulang; tidak menghapus data.
-- =====================================================================

-- 1. Pengajuan: barang ber-kedaluwarsa wajib sudah diisi tanggalnya.
create or replace function public.rpc_receipt_submit(p_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  r public.receipts;
  v_uid uuid := private.require_active_user();
  v_lines integer;
  v_bad text;
begin
  r := private.receipt_for_update(p_id);
  perform private.receipt_expect(r, array['draft']);
  if r.created_by is distinct from v_uid then
    raise exception 'Hanya pembuat penerimaan yang dapat mengajukannya.' using errcode = '42501';
  end if;
  select count(*) into v_lines from public.receipt_details where receipt_id = p_id;
  if v_lines = 0 then
    raise exception 'Tambahkan minimal satu barang sebelum mengajukan.' using errcode = 'P0001';
  end if;
  if r.source_type = 'pembelian' and (r.supplier_id is null or coalesce(r.contract_no, r.order_no) is null) then
    raise exception 'Penerimaan dari pembelian wajib mencantumkan penyedia dan nomor kontrak/SPK/pesanan.' using errcode = 'P0001';
  end if;
  if r.source_type in ('hibah','transfer','lainnya') and nullif(trim(coalesce(r.source_description, '')), '') is null then
    raise exception 'Jelaskan asal perolehan (pemberi hibah/asal transfer).' using errcode = 'P0001';
  end if;
  select string_agg(i.code, ', ') into v_bad
    from public.receipt_details d join public.items i on i.id = d.item_id
   where d.receipt_id = p_id and not i.is_active;
  if v_bad is not null then
    raise exception 'Barang berikut belum aktif: %. Minta Super Admin mengaktifkannya.', v_bad using errcode = 'P0001';
  end if;
  -- Tanggal kedaluwarsa diisi Petugas Penerima Barang (pencatat), bukan pemeriksa.
  select string_agg(i.code, ', ' order by d.line_no) into v_bad
    from public.receipt_details d join public.items i on i.id = d.item_id
   where d.receipt_id = p_id and i.has_expiry and d.expiry_date is null;
  if v_bad is not null then
    raise exception 'Barang % wajib diisi tanggal kedaluwarsa sebelum diajukan (ubah rincian barang).', v_bad using errcode = 'P0001';
  end if;

  perform private.begin_rpc('Diajukan untuk pemeriksaan');
  update public.receipts
     set status = 'menunggu_pemeriksaan',
         total_value = (select coalesce(round(sum(qty_received * unit_cost), 2), 0) from public.receipt_details where receipt_id = p_id)
   where id = p_id;
  perform private.end_rpc();
end $$;

-- 2. Pemeriksaan: tanggal kedaluwarsa tidak lagi diisi/diubah pemeriksa.
create or replace function public.rpc_receipt_record_inspection(p_id uuid, p_lines jsonb, p_notes text, p_decision text)
returns void language plpgsql security definer set search_path = '' as $$
declare
  r public.receipts;
  v_uid uuid := private.require_active_user();
  v_role text;
  l jsonb;
  d record;
  v_acc numeric; v_rej numeric; v_rec numeric; v_res text;
  v_issue boolean := false;
  v_total_acc numeric := 0;
  v_missing integer;
  v_docs text[] := '{}';
begin
  r := private.receipt_for_update(p_id);
  perform private.receipt_expect(r, array['dalam_pemeriksaan']);
  if r.inspector_id is distinct from v_uid then
    raise exception 'Hanya pemeriksa yang memulai pemeriksaan yang dapat mencatat hasilnya.' using errcode = '42501';
  end if;
  v_role := private.receipt_inspector_role(r.source_type);
  if v_role is null then
    raise exception 'Anda tidak lagi berwenang memeriksa penerimaan ini.' using errcode = '42501';
  end if;
  if p_decision not in ('lanjut','tindak_lanjut') then
    raise exception 'Keputusan pemeriksaan tidak dikenal.' using errcode = '22023';
  end if;

  perform private.begin_rpc(case p_decision when 'lanjut' then 'Diperiksa dan disahkan'
                                            else 'Ditemukan ketidaksesuaian' end);
  for l in select * from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) loop
    select d2.*, i.has_expiry, i.code into d
      from public.receipt_details d2 join public.items i on i.id = d2.item_id
     where d2.id = (l ->> 'detail_id')::uuid and d2.receipt_id = p_id;
    if not found then
      raise exception 'Rincian penerimaan tidak dikenal.' using errcode = 'P0002';
    end if;
    v_rec := coalesce((l ->> 'qty_received')::numeric, d.qty_received);
    v_acc := coalesce((l ->> 'qty_accepted')::numeric, 0);
    v_rej := coalesce((l ->> 'qty_rejected')::numeric, 0);
    v_res := l ->> 'result';
    if v_rec <= 0 or v_acc < 0 or v_rej < 0 or v_acc + v_rej <> v_rec then
      raise exception 'Barang %: jumlah diterima baik + ditolak harus sama dengan jumlah yang datang.', d.code using errcode = '22023';
    end if;
    if v_res is null or v_res not in ('sesuai','tidak_sesuai_jumlah','tidak_sesuai_spesifikasi','rusak') then
      raise exception 'Barang %: pilih hasil pemeriksaan.', d.code using errcode = '22023';
    end if;
    if v_res = 'sesuai' and v_rej > 0 then
      raise exception 'Barang %: hasil "sesuai" tidak boleh memiliki jumlah ditolak.', d.code using errcode = '22023';
    end if;
    -- Tanggal kedaluwarsa diisi Petugas Penerima Barang; pemeriksa hanya memeriksa
    -- dan mengesahkannya (tidak dapat mengubah). Bila salah: catat ketidaksesuaian.
    if d.has_expiry and v_acc > 0 and d.expiry_date is null then
      raise exception 'Barang % belum diisi tanggal kedaluwarsa oleh Petugas Penerima Barang. Pilih "Catat ketidaksesuaian" agar dilengkapi.', d.code using errcode = '22023';
    end if;
    if v_res <> 'sesuai' or v_rej > 0 or (d.qty_ordered is not null and v_rec <> d.qty_ordered) then
      v_issue := true;
    end if;
    update public.receipt_details
       set qty_received = v_rec, qty_accepted = v_acc, qty_rejected = v_rej,
           inspection_result = v_res, inspection_notes = nullif(trim(l ->> 'notes'), '')
     where id = d.id;
  end loop;

  select count(*) into v_missing from public.receipt_details where receipt_id = p_id and inspection_result is null;
  if v_missing > 0 then
    raise exception 'Semua barang harus diperiksa (% belum).', v_missing using errcode = 'P0001';
  end if;
  select coalesce(sum(qty_accepted), 0) into v_total_acc from public.receipt_details where receipt_id = p_id;

  if p_decision = 'tindak_lanjut' then
    if not v_issue then
      raise exception 'Tidak ada ketidaksesuaian yang dicatat.' using errcode = 'P0001';
    end if;
    update public.receipts
       set status = 'tidak_sesuai', inspected_at = now(), inspection_notes = nullif(trim(coalesce(p_notes, '')), '')
     where id = p_id;
    perform private.end_rpc();
    return;
  end if;

  if v_total_acc <= 0 then
    raise exception 'Tidak ada barang yang diterima baik; pilih catat ketidaksesuaian.' using errcode = 'P0001';
  end if;

  -- Dokumen wajib sebelum pengesahan.
  if r.source_type = 'saldo_awal' then
    if not exists (select 1 from public.attachments where ref_table = 'receipts' and ref_id = p_id and doc_type = 'ba_saldo_awal') then
      v_docs := v_docs || 'Berita Acara Saldo Awal';
    end if;
  else
    if not exists (select 1 from public.attachments where ref_table = 'receipts' and ref_id = p_id and doc_type = 'ba_pemeriksaan') then
      v_docs := v_docs || 'Berita Acara Pemeriksaan';
    end if;
    if r.source_type = 'pembelian' and not exists (
         select 1 from public.attachments where ref_table = 'receipts' and ref_id = p_id and doc_type in ('surat_jalan','faktur')) then
      v_docs := v_docs || 'Surat Jalan atau Faktur';
    end if;
  end if;
  if cardinality(v_docs) > 0 then
    raise exception 'Dokumen wajib belum diunggah: %.', array_to_string(v_docs, ', ') using errcode = 'P0001';
  end if;

  insert into public.approvals (ref_table, ref_id, level, required_role_code, approver_id, decision, notes)
  values ('receipts', p_id, 1, v_role, v_uid, 'approved', nullif(trim(coalesce(p_notes, '')), ''));
  update public.receipts
     set status = 'disetujui', inspected_at = now(), approved_by = v_uid, approved_at = now(),
         inspection_notes = nullif(trim(coalesce(p_notes, '')), ''),
         total_value = (select coalesce(round(sum(qty_accepted * unit_cost), 2), 0) from public.receipt_details where receipt_id = p_id)
   where id = p_id;
  perform private.end_rpc();
end $$;

-- 3. Perbaikan tanggal kedaluwarsa oleh Petugas Penerima Barang (pencatat)
--    selama penerimaan belum diperiksa atau setelah dicatat tidak sesuai.
create or replace function public.rpc_receipt_set_expiry(p_detail_id uuid, p_expiry date)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := private.require_active_user();
  d record;
  r public.receipts;
begin
  select d2.id, d2.receipt_id, i.code, i.has_expiry, d2.expiry_date into d
    from public.receipt_details d2 join public.items i on i.id = d2.item_id
   where d2.id = p_detail_id;
  if not found then
    raise exception 'Rincian penerimaan tidak dikenal.' using errcode = 'P0002';
  end if;
  r := private.receipt_for_update(d.receipt_id);
  if r.created_by is distinct from v_uid or not private.has_role('PPB') then
    raise exception 'Hanya Petugas Penerima Barang yang mencatat penerimaan ini yang dapat mengisi tanggal kedaluwarsa.' using errcode = '42501';
  end if;
  perform private.receipt_expect(r, array['draft','menunggu_pemeriksaan','tidak_sesuai','menunggu_tindak_lanjut_penyedia']);
  if not d.has_expiry then
    raise exception 'Barang % tidak memakai tanggal kedaluwarsa.', d.code using errcode = '22023';
  end if;
  if p_expiry is null then
    raise exception 'Tanggal kedaluwarsa wajib diisi.' using errcode = '22023';
  end if;
  if p_expiry is not distinct from d.expiry_date then
    return;
  end if;
  perform private.begin_rpc(format('Tanggal kedaluwarsa %s diubah: %s → %s', d.code,
                                   coalesce(to_char(d.expiry_date, 'DD-MM-YYYY'), 'kosong'), to_char(p_expiry, 'DD-MM-YYYY')));
  update public.receipt_details set expiry_date = p_expiry where id = p_detail_id;
  perform private.end_rpc();
end $$;

revoke all on function public.rpc_receipt_set_expiry(uuid, date) from public, anon;
grant execute on function public.rpc_receipt_set_expiry(uuid, date) to authenticated;
revoke all on function public.rpc_receipt_submit(uuid) from public, anon;
grant execute on function public.rpc_receipt_submit(uuid) to authenticated;
revoke all on function public.rpc_receipt_record_inspection(uuid, jsonb, text, text) from public, anon;
grant execute on function public.rpc_receipt_record_inspection(uuid, jsonb, text, text) to authenticated;

-- 4. Penerimaan yang sudah diajukan tanpa tanggal kedaluwarsa (aturan lama)
--    dikembalikan ke draf agar dilengkapi Petugas Penerima Barang. Aman diulang.
create or replace function private.reset_receipts_missing_expiry()
returns integer language plpgsql security definer set search_path = '' as $$
declare n integer;
begin
  perform private.begin_rpc('Dikembalikan ke draf: tanggal kedaluwarsa wajib diisi Petugas Penerima Barang');
  update public.receipts r
     set status = 'draft', inspector_id = null, inspected_at = null
   where r.status in ('menunggu_pemeriksaan','dalam_pemeriksaan')
     and exists (select 1 from public.receipt_details d join public.items i on i.id = d.item_id
                  where d.receipt_id = r.id and i.has_expiry and d.expiry_date is null);
  get diagnostics n = row_count;
  perform private.end_rpc();
  return n;
end $$;
revoke all on function private.reset_receipts_missing_expiry() from public;

select private.reset_receipts_missing_expiry();
