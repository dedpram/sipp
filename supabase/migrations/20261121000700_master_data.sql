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
