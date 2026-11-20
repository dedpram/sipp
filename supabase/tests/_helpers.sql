-- =====================================================================
-- Helper pengujian (schema `tests`). Hanya untuk database uji.
-- =====================================================================
create schema if not exists tests;
grant usage on schema tests to anon, authenticated, service_role;

-- Membuat akun uji (meniru Supabase Auth) dan mengembalikan id-nya.
create or replace function tests.create_user(p_email text, p_full_name text, p_unit_code text default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_id uuid; v_unit uuid;
begin
  select id into v_unit from public.organizational_units where code = p_unit_code;
  insert into auth.users (email, raw_user_meta_data)
  values (p_email, jsonb_build_object('full_name', p_full_name, 'primary_unit_id', v_unit))
  returning id into v_id;
  return v_id;
end $$;

-- Berpura-pura menjadi pengguna tertentu (seperti request dari Supabase API).
-- p_aal: 'aal2' = sudah verifikasi dua langkah (default), 'aal1' = hanya password.
create or replace function tests.login_as(p_email text, p_aal text default 'aal2')
returns void language plpgsql as $$
declare v_id uuid;
begin
  perform set_config('role', 'postgres', true);
  select id into v_id from auth.users where email = p_email;
  if v_id is null then raise exception 'Pengguna uji % tidak ada', p_email; end if;
  perform set_config('request.jwt.claims', json_build_object('sub', v_id, 'role', 'authenticated', 'aal', p_aal)::text, true);
  perform set_config('role', 'authenticated', true);
end $$;

create or replace function tests.login_anon()
returns void language plpgsql as $$
begin
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
  perform set_config('role', 'anon', true);
end $$;

create or replace function tests.login_service()
returns void language plpgsql as $$
begin
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);
  perform set_config('role', 'service_role', true);
end $$;

create or replace function tests.logout()
returns void language plpgsql as $$
begin
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
end $$;

create or replace function tests.ok(p_cond boolean, p_msg text)
returns void language plpgsql as $$
begin
  if p_cond is distinct from true then
    raise exception 'GAGAL: %', p_msg;
  end if;
  raise notice 'ok - %', p_msg;
end $$;

-- Menjalankan SQL dan memastikan GAGAL dengan pesan mengandung p_fragment.
create or replace function tests.throws(p_sql text, p_fragment text, p_msg text)
returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if position(lower(p_fragment) in lower(sqlerrm)) > 0 then
      raise notice 'ok - % (ditolak: %)', p_msg, sqlerrm;
      return;
    end if;
    raise exception 'GAGAL: % — error tak terduga: %', p_msg, sqlerrm;
  end;
  raise exception 'GAGAL: % — perintah seharusnya ditolak tetapi berhasil', p_msg;
end $$;

-- Jumlah baris yang terlihat oleh pengguna saat ini.
create or replace function tests.visible(p_sql text)
returns bigint language plpgsql as $$
declare v bigint;
begin
  execute format('select count(*) from (%s) x', p_sql) into v;
  return v;
end $$;

-- Jumlah baris yang benar-benar terpengaruh oleh UPDATE (RLS dapat membuat 0).
create or replace function tests.affected(p_sql text)
returns bigint language plpgsql as $$
declare v bigint;
begin
  execute p_sql;
  get diagnostics v = row_count;
  return v;
end $$;

grant execute on all functions in schema tests to anon, authenticated, service_role;
