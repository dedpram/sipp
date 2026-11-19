# Panduan Setup SIPP (Fase 2)

Panduan ini ditulis untuk pengguna yang **bukan programmer**. Ikuti berurutan. Setiap langkah menjelaskan
**apa** yang dilakukan dan **mengapa**.

> 🔒 **Aturan keamanan:** jangan pernah menempelkan password database, *service role key*, atau *secret key*
> ke chat, email, atau file yang di-commit ke GitHub. Simpan di password manager.

---

## Langkah 0 — Siapkan perangkat (sekali saja)

| Perangkat | Kegunaan | Unduh |
|---|---|---|
| Node.js versi LTS (20 atau 22) | Menjalankan & membangun aplikasi | https://nodejs.org |
| Git | Menyimpan riwayat perubahan & mengirim ke GitHub | https://git-scm.com |
| Akun GitHub | Menyimpan kode & hosting | https://github.com |
| Akun Supabase | Database, login, penyimpanan dokumen | https://supabase.com |

Cek instalasi dengan membuka **Terminal** (Mac/Linux) atau **PowerShell** (Windows):

```bash
node -v
git --version
```

Keduanya harus menampilkan nomor versi.

---

## Langkah 1 — Buka folder proyek

1. Ekstrak file `sipp-fase-2.zip` ke folder kerja, mis. `Documents/sipp`.
2. Buka terminal **di dalam folder tersebut**:

```bash
cd ~/Documents/sipp
```

3. Pasang dependensi (butuh internet, ±1–3 menit):

```bash
npm install
```

*Tujuan:* mengunduh pustaka React, Supabase, dll. ke folder `node_modules/`. Perintah ini juga membuat
`package-lock.json` yang mengunci versi pustaka — file ini **perlu di-commit** (lihat Langkah 8).

---

## Langkah 2 — Buat proyek Supabase

1. Masuk ke https://supabase.com/dashboard → **New project**.
2. Isi nama `sipp` (atau `sipp-staging` untuk uji coba), pilih region **Southeast Asia (Singapore)**.
3. Buat **Database Password** yang kuat dan **simpan di password manager**.
4. Tunggu hingga proyek siap (±2 menit).
5. Catat **Project Reference** (deretan huruf di URL dashboard: `https://supabase.com/dashboard/project/<REF>`).

> Disarankan membuat **dua proyek**: `sipp-staging` (uji coba) dan `sipp` (produksi). Lakukan semua uji di staging.

---

## Langkah 3 — Pengaturan Authentication (PENTING)

Di dashboard Supabase:

1. **Authentication → Sign In / Providers**
   - Pastikan **Email** aktif.
   - **Matikan "Allow new users to sign up"** — akun hanya boleh dibuat oleh Super Admin.
   - Pengaturan "Confirm email" boleh dibiarkan; akun yang dibuat Super Admin otomatis terkonfirmasi.
2. **Authentication → Policies / Password** (bila tersedia): set panjang minimum password **12**.
3. **Authentication → URL Configuration**
   - **Site URL:** `http://localhost:5173` (diganti alamat GitHub Pages saat deployment).
   - **Redirect URLs:** tambahkan `http://localhost:5173/**`.

*Tujuan:* mencegah orang luar mendaftar sendiri.

---

## Langkah 4 — Terapkan migration database

Migration adalah file SQL di `supabase/migrations/` yang membuat tabel, aturan keamanan (RLS), dan fungsi.
Pilih **salah satu** cara:

### Cara A (disarankan) — Supabase CLI

```bash
npx supabase login
npx supabase link --project-ref <REF>
npx supabase db push
```

- `login` membuka browser untuk masuk ke akun Supabase.
- `link` meminta **Database Password** dari Langkah 2 (ketik langsung di terminal, jangan di chat).
- `db push` menerapkan migration yang belum diterapkan; menampilkan daftar file lalu meminta konfirmasi `Y`.

### Cara B — SQL Editor (tanpa CLI)

Dashboard → **SQL Editor** → **New query**. Buka file berikut **berurutan**, salin seluruh isinya, tempel, klik **Run**:

1. `20261119000100_fondasi_skema.sql`
2. `20261119000200_identitas_organisasi.sql`
3. `20261119000300_audit_trail.sql`
4. `20261119000400_rls_fondasi.sql`
5. `20261119000500_rpc_fondasi.sql`

Setiap file harus berakhir dengan "Success". Bila ada error, **berhenti** dan kirimkan pesan errornya (tanpa data rahasia).

> ⚠️ **Jangan** menjalankan file di folder `supabase/tests/` pada proyek Supabase sungguhan. File itu hanya untuk
> database uji.

**Data contoh unit kerja (khusus staging):** jalankan `supabase/seed.sql` di SQL Editor agar ada unit
Sekretariat → Bagian Umum → Subbagian Rumah Tangga, dst. Menu Master Unit Kerja dibangun di Fase 3; sementara itu
unit dapat ditambahkan lewat **Table Editor → organizational_units**.

---

## Langkah 5 — Pasang Edge Function pengelolaan akun

Fungsi ini dipakai Super Admin untuk membuat akun, menonaktifkan akun, dan reset password. Kunci service role
otomatis tersedia di dalam fungsi dan **tidak pernah** dikirim ke browser.

```bash
npx supabase functions deploy admin-users
npx supabase secrets set SIPP_ALLOWED_ORIGINS=http://localhost:5173
```

`SIPP_ALLOWED_ORIGINS` membatasi situs yang boleh memanggil fungsi. Saat deployment GitHub Pages nanti,
tambahkan alamatnya, mis. `http://localhost:5173,https://<akun-github>.github.io`.

---

## Langkah 6 — Buat Super Admin pertama

1. Dashboard → **Authentication → Users → Add user → Create new user**.
   Isi email & password Super Admin, centang **Auto Confirm User**.
2. Dashboard → **SQL Editor**, jalankan (ganti email):

```sql
select private.bootstrap_super_admin('admin@instansi.go.id');
```

Hasil: `Super Admin berhasil ditetapkan untuk ...`. Fungsi ini **menolak** bila sudah ada Super Admin aktif,
sehingga tidak dapat disalahgunakan untuk membuat SA kedua.

> Disarankan menetapkan **dua** Super Admin (role SA kedua diberikan oleh SA pertama lewat aplikasi) agar
> pengelolaan akun tidak bergantung pada satu orang.

---

## Langkah 7 — Jalankan aplikasi di komputer Anda

1. Salin file konfigurasi:

```bash
cp .env.example .env.local
```

(Windows PowerShell: `Copy-Item .env.example .env.local`)

2. Buka `.env.local` dengan Notepad/VS Code, isi:
   - `VITE_SUPABASE_URL` → Dashboard → **Project Settings → Data API** (Project URL).
   - `VITE_SUPABASE_PUBLISHABLE_KEY` → Dashboard → **Project Settings → API Keys** → *Publishable key*
     (`sb_publishable_...`). Proyek lama: isi `VITE_SUPABASE_ANON_KEY` dengan *anon public key*.
   - ❌ Jangan isi *secret* / *service_role* key.

3. Jalankan:

```bash
npm run dev
```

4. Buka http://localhost:5173 dan masuk dengan akun Super Admin.

---

## Langkah 8 — Simpan ke GitHub (tanpa deployment)

1. Di GitHub: **New repository** → nama `sipp` → **Public** → *jangan* centang "Add a README" → **Create**.
2. Di terminal (folder proyek sudah berisi riwayat Git dengan checkpoint Fase 1 & 2):

```bash
git add package-lock.json
git commit -m "chore: kunci versi dependensi"
git remote add origin https://github.com/<akun-github>/sipp.git
git push -u origin main --tags
```

3. Buka tab **Actions** di GitHub. Workflow **CI** berjalan otomatis dan menguji:
   - pemeriksaan TypeScript, unit test, build, dan pemindaian kunci rahasia;
   - seluruh migration + **72 pemeriksaan keamanan RLS** pada PostgreSQL.
   Tanda ✅ hijau = lolos.

4. Persiapan deployment (belum dijalankan):
   - **Settings → Pages → Source: GitHub Actions**.
   - **Settings → Secrets and variables → Actions → tab Variables**: tambahkan `VITE_SUPABASE_URL` dan
     `VITE_SUPABASE_PUBLISHABLE_KEY`.
   - Workflow **Deploy ke GitHub Pages** hanya berjalan bila dijalankan manual dengan mengetik `DEPLOY`,
     dan **baru akan dilakukan setelah Anda menyetujuinya**.

---

## Langkah 9 — Uji Fase 2 secara manual

Gunakan proyek **staging**. Buat beberapa akun lewat menu **Pengguna dan Role → Tambah Pengguna**, lalu tetapkan role.

| No | Skenario | Hasil yang diharapkan |
|---|---|---|
| 1 | Masuk sebagai Super Admin | Menu: Dashboard, Master Data, Laporan, Pengguna dan Role, Pengaturan |
| 2 | Tambah pengguna "Pegawai A" unit Bagian Umum, beri role **Pegawai** (unit Bagian Umum) | Berhasil; muncul di daftar |
| 3 | Tambah "Atasan A", beri role **Atasan Unit** (unit Bagian Umum) | Berhasil |
| 4 | Beri role **Atasan Unit** tanpa memilih unit | Ditolak: "wajib memilih unit kerja" |
| 5 | Beri role **KPA** kepada akun yang sudah Super Admin | Ditolak (pemisahan fungsi) |
| 6 | Beri role apa pun kepada akun **Auditor** | Ditolak (Auditor tidak merangkap) |
| 7 | Super Admin mencoba menonaktifkan akunnya sendiri | Tombol tidak tersedia; database juga menolak |
| 8 | Masuk sebagai Pegawai A | Menu hanya Dashboard, Permintaan Barang, Laporan |
| 9 | Pegawai A membuka alamat `#/pengguna` secara manual | "Akses tidak diizinkan" |
| 10 | Pegawai A di **Profil Saya** mengganti telepon & password | Berhasil |
| 11 | Masuk sebagai Atasan A, buka Dashboard | Tidak ada statistik pengguna satker |
| 12 | Super Admin menonaktifkan Pegawai A (isi alasan), lalu Pegawai A mencoba masuk | Tidak dapat masuk |
| 13 | Super Admin melihat Dashboard → Aktivitas terbaru | Tercatat: login, pembuatan akun, perubahan role, penonaktifan |
| 14 | Refresh browser (F5) di halaman mana pun | Halaman tetap terbuka, sesi tetap aktif |

Laporkan nomor skenario yang tidak sesuai beserta pesan yang muncul.

---

## Pemecahan masalah

| Gejala | Penyebab & solusi |
|---|---|
| Halaman login menampilkan "Konfigurasi Supabase belum diisi" | `.env.local` belum dibuat/diisi. Ulangi Langkah 7, lalu hentikan (`Ctrl+C`) dan jalankan ulang `npm run dev`. |
| "Email atau password salah" | Periksa akun di Authentication → Users. |
| "Profil pengguna belum tersedia" | Migration belum diterapkan saat akun dibuat. Terapkan migration, lalu jalankan di SQL Editor: `insert into public.profiles (id, email, full_name) select id, email, email from auth.users on conflict do nothing;` |
| Tambah Pengguna gagal "Failed to send a request to the Edge Function" | Edge Function belum di-deploy (Langkah 5) atau `SIPP_ALLOWED_ORIGINS` tidak memuat alamat yang dipakai. |
| `npx supabase link` meminta password | Masukkan Database Password dari Langkah 2 (input disembunyikan, ketik lalu Enter). |
| Workflow CI merah | Klik workflow → lihat langkah yang gagal → kirim pesan errornya. |
