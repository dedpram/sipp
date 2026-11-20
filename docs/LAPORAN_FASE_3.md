# Laporan Fase 3 — Master Data

Tanggal: 21 November 2026 · Checkpoint Git: `fase-3-master-data`

## 1. Ringkasan pekerjaan

- **Master Data** (satu halaman bertab): Barang, Kategori, Satuan, Gudang, Lokasi Penyimpanan, Penyedia, Unit Kerja.
  Pencarian, filter status, pengurutan, tambah/ubah, aktif/nonaktif. Tidak ada hapus.
- **Barang:** kode diusulkan otomatis per kategori (ATK-0001, …); stok minimum/pengaman/maksimum divalidasi;
  penanda barang ber-kedaluwarsa (untuk FEFO di Fase 4). Barang dari Pengurus Barang berstatus **Usulan** sampai
  diaktifkan Super Admin.
- **Lokasi:** kode dibuat otomatis dari gudang–rak–nomor bila dikosongkan; posisi ganda ditolak.
- **Unit kerja:** unit induk (bertingkat) dan atasan unit dapat diatur dari aplikasi.
- **Pengaturan:** identitas satker, parameter pengendalian, dan tabel jenjang persetujuan (ubah penyetuju, ambang
  nilai, aktif/nonaktif).
- **Verifikasi dua langkah (MFA):** aktivasi di Profil Saya dengan aplikasi autentikator; kode diminta saat login.
  Wajib bagi Super Admin untuk semua tindakan perubahan, ditegakkan di database dan Edge Function.
- Dashboard: jumlah jenis barang aktif dan usulan barang yang menunggu aktivasi.

## 2. Migration

`20261120000600_hak_service_role.sql` (sudah Anda terapkan saat perbaikan), `20261121000700_master_data.sql`,
`20261121000800_rls_master_mfa.sql` — digabung dalam `docs/sql/5-pembaruan-fase-3.sql`.

## 3. Hasil pengujian

| Pengujian | Hasil |
|---|---|
| Uji database (RLS, pemisahan fungsi, MFA, master data, audit) | ✅ 126/126 |
| Pembaruan dari kondisi database Anda saat ini (Fase 2 + perbaikan), dijalankan 2× | ✅ |
| Unit test frontend | ✅ 34/34 |
| Pemeriksaan tipe TypeScript & Edge Function | ✅ |
| Build penuh & uji di Supabase sungguhan | ⏳ melalui GitHub Actions dan uji coba Anda |

## 4. Risiko & catatan

| Risiko | Pengendalian |
|---|---|
| SA kehilangan HP autentikator | Siapkan 2 Super Admin; pemegang akun Supabase dapat menghapus faktor MFA di Authentication → Users |
| Setelah pembaruan, SA belum bisa mengubah data sampai MFA aktif | Disengaja (K21); aplikasi menampilkan pengingat |
| Mengubah satuan barang setelah ada transaksi | Akan dikunci di Fase 4 saat tabel transaksi tersedia |

## 5. Langkah berikutnya

Uji coba Fase 3 oleh pengguna → persetujuan → **Fase 4 — Transaksi** (penerimaan, penyimpanan & perpindahan lokasi,
permintaan, persetujuan berjenjang, pengeluaran FIFO/FEFO, kartu stok).
