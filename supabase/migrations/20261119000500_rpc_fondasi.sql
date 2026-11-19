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
