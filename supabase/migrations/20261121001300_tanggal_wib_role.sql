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
