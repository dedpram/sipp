-- =====================================================================
-- SIPP — PEMBARUAN DATABASE FASE 3 (Master Data & Verifikasi Dua Langkah)
-- Cara pakai: Supabase Dashboard > SQL Editor > New query (tab KOSONG) >
--             tempel SELURUH isi file ini > klik RUN.
-- Bila muncul peringatan "destructive operation", klik "Run this query":
-- file ini hanya mengganti aturan akses, tidak menghapus data.
-- Aman dijalankan ulang.
-- =====================================================================

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
