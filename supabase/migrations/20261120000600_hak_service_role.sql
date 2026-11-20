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
