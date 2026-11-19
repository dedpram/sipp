# SIPP — Sistem Informasi Pengelolaan Persediaan

Aplikasi web pengelolaan persediaan satuan kerja pemerintah: penerimaan, penyimpanan, permintaan & pengeluaran,
kartu stok, stock opname, penanganan selisih, barang rusak/usang, rekonsiliasi, pelaporan, dan audit trail.

| Bagian | Teknologi |
|---|---|
| Tampilan | React + TypeScript + Vite + Tailwind CSS + Lucide React |
| Data, login, dokumen | Supabase (PostgreSQL + RLS, Auth, Storage, Edge Functions) |
| Hosting | GitHub Pages (deploy manual via GitHub Actions) |

## Status pengembangan

| Fase | Isi | Status |
|---|---|---|
| 1 | Analisis & perancangan (`docs/PROJECT_SPEC.md`) | ✅ Disetujui |
| 2 | Fondasi: login, role, RLS, audit trail, layout, dashboard awal, pengguna | ✅ Selesai — menunggu uji & persetujuan |
| 3 | Master data | ⏳ |
| 4 | Transaksi | ⏳ |
| 5 | Pengendalian | ⏳ |
| 6 | Pelaporan | ⏳ |
| 7 | Testing & deployment | ⏳ |

## Mulai dari sini

1. **Panduan langkah demi langkah:** [`docs/PANDUAN_SETUP.md`](docs/PANDUAN_SETUP.md)
2. Rancangan lengkap: [`docs/PROJECT_SPEC.md`](docs/PROJECT_SPEC.md)
3. Dokumentasi database: [`docs/DATABASE.md`](docs/DATABASE.md)
4. Laporan fase terakhir: [`docs/LAPORAN_FASE_2.md`](docs/LAPORAN_FASE_2.md)

## Perintah penting

```bash
npm install          # sekali, memasang dependensi
npm run dev          # menjalankan aplikasi di http://localhost:5173
npm run typecheck    # memeriksa kesalahan TypeScript
npm test             # unit test
npm run build        # build produksi ke folder dist/
npm run test:db      # migration + uji RLS (perlu PostgreSQL lokal; otomatis di GitHub Actions)
```

## Struktur folder

```
docs/                 Dokumentasi (spesifikasi, panduan, database, laporan fase)
supabase/migrations/  Migration SQL berurutan (jangan diedit setelah diterapkan)
supabase/functions/   Edge Function (satu-satunya tempat kunci service role dipakai)
supabase/tests/       Uji RLS & keamanan database
src/app/              Router & definisi menu per role
src/components/       Komponen UI bersama (tombol, tabel, modal, layout)
src/features/<modul>/ Halaman, akses data (api.ts), validasi (schema.ts) per modul
src/lib/              Klien Supabase, format tanggal/Rupiah, pesan error
```

## Keamanan — wajib dipatuhi

- File `.env` / `.env.local` **tidak boleh** di-commit (sudah diatur `.gitignore`).
- Frontend hanya memakai **URL** dan **publishable/anon key** Supabase. Kunci **service role/secret** tidak boleh
  berada di frontend, repository, maupun percakapan.
- Seluruh hak akses ditegakkan di database (RLS + fungsi), bukan hanya dengan menyembunyikan tombol.
