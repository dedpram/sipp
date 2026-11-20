# Laporan Fase 4A — Penerimaan, Penyimpanan, Kartu Stok

Tanggal: 21 November 2026 · Checkpoint Git: `fase-4a-penerimaan`

## 1. Ringkasan pekerjaan
- **Penerimaan barang** lengkap: dicatat Petugas Penerima Barang → diperiksa **sekaligus disahkan** oleh PPK
  (pembelian) atau Pejabat Pengawas (sumber lain) → (ketidaksesuaian & tindak lanjut) → disimpan Pengurus Barang →
  selesai. Penerimaan sebagian didukung; barang ditolak tidak menambah saldo.
- **Dokumen digital**: unggah surat jalan, faktur, kontrak, berita acara, foto (bucket privat, maks. 10 MB).
  Pengesahan ditolak bila dokumen wajib belum ada.
- **Saldo awal** melalui penerimaan bersumber "Saldo awal" (BA Saldo Awal, diperiksa & disahkan Pejabat Pengawas).
- **Role KPA dihapus** sesuai keputusan pemilik produk; tugas persetujuannya dialihkan ke Pejabat Pengawas.
- **Petugas Akuntansi hanya menyusun Rekonsiliasi**; langkah verifikasi akuntansi penerimaan ditiadakan.
- **Penyimpanan**: saldo per barang & per lokasi, pemantauan minimum/maksimum, kedaluwarsa, perpindahan lokasi
  (FIFO, total tidak berubah), pemeriksaan konsistensi.
- **Kartu stok** per barang & periode: saldo awal, masuk, keluar, saldo berjalan, harga satuan, nilai; dapat dicetak.
- **Dashboard**: nilai persediaan, stok minimum/maksimum, kedaluwarsa, penerimaan diproses.

## 2. Migration
`20261121000900_transaksi_tabel.sql`, `20261121001000_transaksi_rpc.sql`, `20261121001100_alur_penerimaan_tanpa_kpa.sql`, `20261121001200_akuntansi_hanya_rekonsiliasi.sql` → `docs/sql/6-pembaruan-fase-4a.sql` (versi 4).

## 3. Hasil pengujian
| Pengujian | Hasil |
|---|---|
| Uji database (alur penerimaan, pemisahan fungsi, dokumen, saldo, FIFO, perpindahan, kartu stok, akses per role, penghapusan KPA, pembatasan AKT) | ✅ 205/205 |
| Uji transaksi bersamaan (dua perpindahan atas stok yang sama) | ✅ satu berhasil, satu ditolak, saldo tidak minus |
| Pemeriksaan tipe TypeScript | ✅ |
| Build penuh & uji di Supabase sungguhan | ⏳ GitHub Actions & uji coba pengguna |

Temuan selama pengujian: saldo berjalan kartu stok semula mengikuti urutan pencatatan; diubah menjadi urutan
tanggal, dan barang keluar bertanggal mundur kini ditolak.

## 4. Risiko & catatan
| Risiko | Pengendalian |
|---|---|
| Salah input setelah disimpan ke gudang | Tidak dapat diedit; dikoreksi lewat transaksi koreksi (Fase 5) |
| Upload dokumen gagal karena bucket belum ada | Bucket dibuat otomatis oleh file SQL; cek Storage → documents |
| Pemilihan barang dari daftar panjang | Dapat ditingkatkan ke kotak pencarian bila jumlah barang besar |

## 5. Langkah berikutnya
Uji coba 4A → persetujuan → **Fase 4B**: permintaan, persetujuan berjenjang, pengeluaran FIFO/FEFO, konfirmasi.
