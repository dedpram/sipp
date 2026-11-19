# Laporan Fase 2 — Fondasi Aplikasi

Tanggal: 19 November 2026 · Checkpoint Git: `fase-2-fondasi`

## 1. Ringkasan pekerjaan

- Proyek React + TypeScript + Vite + Tailwind CSS + Lucide React disiapkan, dengan HashRouter agar aman di GitHub Pages.
- Koneksi Supabase (PKCE, publishable/anon key saja; aplikasi menolak berjalan bila terdeteksi kunci rahasia).
- Database fondasi: identitas, role, unit kerja bertingkat, konfigurasi, jenjang persetujuan, penomoran dokumen,
  notifikasi, audit trail append-only dengan rantai hash.
- RLS di seluruh tabel; pemisahan fungsi ditegakkan di database.
- Login, logout (tercatat di audit trail), penolakan akun nonaktif.
- Layout: sidebar hijau, header dengan profil, menu per role, drawer untuk tablet/HP.
- Dashboard awal sesuai role.
- Modul **Pengguna dan Role**: tambah akun, ubah profil, tetapkan/cabut role (unit & masa berlaku & dasar SK),
  aktif/nonaktif akun (wajib alasan), reset password.
- **Profil Saya**: ubah telepon & ganti password.
- Edge Function `admin-users` (satu-satunya pemakai service role key).
- CI GitHub Actions (frontend + database) dan workflow deploy **manual** dengan konfirmasi `DEPLOY`.

## 2. File dibuat

```
.github/workflows/ci.yml, deploy.yml
.env.example, .gitignore, README.md, index.html, package.json, tsconfig.json, vite.config.ts
docs/PROJECT_SPEC.md (v1.0), PANDUAN_SETUP.md, DATABASE.md, LAPORAN_FASE_2.md
public/favicon.svg
scripts/test-db.sh, check-bundle.mjs
supabase/config.toml, seed.sql
supabase/migrations/20261119000100 … 20261119000500 (5 file)
supabase/functions/admin-users/index.ts
supabase/tests/_supabase_shim.sql, _helpers.sql, _fixtures.sql, rls/01_fondasi.sql
src/main.tsx, index.css, vite-env.d.ts
src/app/navigation.ts, router.tsx (+ navigation.test.ts)
src/lib/supabase.ts, format.ts, errors.ts, roles.ts, cn.ts (+ format.test.ts)
src/types/domain.ts
src/components/layout/AppShell.tsx
src/components/ui/Button, Input, Alert, Badge, Card, Modal (+ConfirmDialog), Toast
src/components/feedback/States.tsx
src/components/data-table/DataTable.tsx
src/features/auth/AuthProvider.tsx, guards.tsx, LoginPage.tsx
src/features/dashboard/DashboardPage.tsx
src/features/users/api.ts, schema.ts, UserModals.tsx, UsersPage.tsx (+ schema.test.ts)
src/features/profile/ProfilePage.tsx
src/features/placeholder/ModulePlaceholderPage.tsx
```

## 3. Migration

| File | Status |
|---|---|
| `20261119000100_fondasi_skema.sql` | Diuji ✅ (belum diterapkan ke Supabase Anda) |
| `20261119000200_identitas_organisasi.sql` | Diuji ✅ |
| `20261119000300_audit_trail.sql` | Diuji ✅ |
| `20261119000400_rls_fondasi.sql` | Diuji ✅ |
| `20261119000500_rpc_fondasi.sql` | Diuji ✅ |

## 4. Hasil pengujian

| Pengujian | Lingkungan | Hasil |
|---|---|---|
| Migration (2× berturut-turut, uji idempotent) | PostgreSQL 16 | ✅ |
| Uji RLS & keamanan database | PostgreSQL 16 + shim Supabase | ✅ **72/72 lolos** |
| Unit test (format, menu per role, validasi, pesan error) | Node 22 | ✅ **23/23 lolos** |
| Pemeriksaan tipe TypeScript kode SIPP | TypeScript (modul eksternal disimulasikan) | ✅ tanpa error |
| Pemindai kunci rahasia pada bundle | Uji dengan token anon & service_role palsu | ✅ token service_role terdeteksi |
| `npm install` + `vite build` penuh | — | ⚠️ **Belum** — lingkungan pengembang tidak memiliki akses internet untuk mengunduh paket. Akan diverifikasi otomatis oleh GitHub Actions saat kode di-push, dan di komputer Anda pada Langkah 1 & 7 panduan. |
| Edge Function di Supabase sungguhan | — | ⚠️ Belum — diuji melalui skenario manual Langkah 9 panduan |

Temuan & perbaikan selama pengujian: rantai hash audit awalnya tidak mencakup kolom nama pengguna/role/IP; pengujian
manipulasi mendeteksinya, kemudian rumus hash diperluas ke seluruh kolom dan diuji ulang (termasuk penghapusan baris
di tengah rantai).

## 5. Fitur yang sudah berfungsi (setelah setup)

Login/logout · menu sesuai role · halaman terlarang ditolak · dashboard awal · tambah/ubah/nonaktifkan pengguna ·
tetapkan/cabut role dengan aturan pemisahan fungsi · reset & ganti password · audit trail terlindungi.

## 6. Potensi risiko & catatan

| No | Risiko | Tindak lanjut |
|---|---|---|
| 1 | Versi pustaka di `package.json` belum dikunci lockfile | Commit `package-lock.json` setelah `npm install` (Langkah 8) |
| 2 | Pendaftaran mandiri Supabase aktif secara default | Wajib dimatikan (Langkah 3) |
| 3 | MFA wajib untuk Super Admin (keputusan K21) belum diterapkan | Dijadwalkan Fase 3: pendaftaran TOTP + RLS mensyaratkan `aal2` untuk tindakan SA |
| 4 | Pemilik akun Supabase tetap dapat mengubah data langsung | Batasi pemegang akun + 2FA akun Supabase; manipulasi audit terdeteksi rantai hash |
| 5 | Paket gratis Supabase dapat dijeda bila tidak aktif ±7 hari | Gunakan rutin saat uji; pertimbangkan paket Pro untuk produksi |
| 6 | Tabel daftar pengguna memuat semua data di browser | Memadai untuk satu satker; tabel transaksi Fase 4 memakai pagination di server |

## 7. Langkah berikutnya

1. Anda menjalankan `docs/PANDUAN_SETUP.md` Langkah 0–9 di proyek **staging** dan melaporkan hasil skenario uji.
2. Setelah Fase 2 disetujui → **Fase 3 — Master Data**: barang, kategori (7 kategori awal), satuan, unit kerja,
   gudang & lokasi penyimpanan, penyedia, halaman Pengaturan & jenjang persetujuan, serta MFA Super Admin.
