-- =====================================================================
-- SIPP — Menetapkan Super Admin PERTAMA
-- 1. Buat dulu akunnya di Authentication > Users > Add user.
-- 2. Ganti email di bawah dengan email akun tersebut (tetap di dalam tanda kutip).
-- 3. Klik RUN. Hasil yang benar: "Super Admin berhasil ditetapkan untuk ..."
-- =====================================================================
select private.bootstrap_super_admin('GANTI-DENGAN-EMAIL@instansi.go.id');
