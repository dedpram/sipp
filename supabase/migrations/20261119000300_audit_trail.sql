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
