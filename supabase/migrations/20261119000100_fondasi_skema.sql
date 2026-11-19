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
