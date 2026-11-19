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
