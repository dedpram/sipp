# Dokumentasi Database SIPP

Status: **Fase 3 (fondasi + master data)**. Tabel transaksi ditambahkan pada fase berikutnya sesuai `PROJECT_SPEC.md` Bagian 5.

## 1. Schema

| Schema | Isi | Diekspos ke API? |
|---|---|---|
| `public` | Tabel aplikasi & fungsi `rpc_*` | Ya (dilindungi RLS & GRANT) |
| `private` | Fungsi internal: helper RLS, audit, penomoran, bootstrap | **Tidak** |
| `auth` | Milik Supabase Auth (akun & password terenkripsi) | Tidak |

## 2. Migration

| File | Isi |
|---|---|
| `20261119000100_fondasi_skema.sql` | Schema `private`, ekstensi `pg_trgm`, trigger metadata baris (`created_by` dll. diisi dari sesi) |
| `20261119000200_identitas_organisasi.sql` | `roles` (11 role), `organizational_units`, `profiles`, `user_roles`, `app_settings`, `approval_settings`, `document_sequences`, `notifications`; profil otomatis saat akun Auth dibuat |
| `20261119000300_audit_trail.sql` | `audit_logs` append-only dengan rantai hash; trigger audit generik; verifikasi rantai |
| `20261119000400_rls_fondasi.sql` | Helper RLS, penjaga profil, aturan pemisahan fungsi, GRANT/REVOKE, seluruh policy |
| `20261119000500_rpc_fondasi.sql` | RPC: log login/logout, konteks pengguna, dashboard, verifikasi audit, audit layanan, penomoran dokumen, bootstrap SA |

Semua migration **idempotent** (aman dijalankan ulang) dan **tidak menghapus data**. Aturan: migration yang sudah
diterapkan tidak diedit; perubahan dibuat sebagai file migration baru.

## 3. Tabel fondasi

| Tabel | Fungsi | Catatan kontrol |
|---|---|---|
| `roles` | Daftar 11 role | Hanya baca dari aplikasi |
| `organizational_units` | Unit kerja bertingkat (`parent_id`) & atasan unit (`head_user_id`) | Ubah: SA |
| `profiles` | Profil pengguna (1:1 `auth.users`), tanpa password | Pengguna hanya boleh ubah telepon; email hanya dari Auth; SA tidak dapat menonaktifkan diri |
| `user_roles` | Penugasan role + lingkup unit + masa berlaku + dasar SK | Hanya SA; tidak dapat dihapus (dinonaktifkan); SOD-7/8/9 |
| `app_settings` | Konfigurasi (kode satker, ambang nilai, dll.) | Ubah: SA; tercatat CONFIG_CHANGE |
| `approval_settings` | Jenjang persetujuan per jenis transaksi | Ubah: SA |
| `document_sequences` | Penghitung nomor dokumen per prefix & bulan | Tidak dapat diakses langsung |
| `notifications` | Notifikasi per pengguna | Hanya milik sendiri; hanya kolom `is_read` yang dapat diubah |
| `audit_logs` | Jejak audit | Tidak dapat diubah/dihapus siapa pun lewat aplikasi; TRUNCATE/DELETE ditolak trigger |

## 4. Fungsi helper RLS (`private`)

| Fungsi | Hasil |
|---|---|
| `current_user_is_active()` | Profil pengguna aktif? |
| `my_role_codes()` | Role aktif & berlaku hari ini |
| `has_role(code)`, `has_any_role(codes[])` | Cek role |
| `unit_with_descendants(unit)` | Unit + seluruh sub-unit |
| `my_scope_unit_ids(code)` | Unit lingkup role (ATS juga dari `head_user_id`) |
| `is_system_context()` | Dipanggil sistem/RPC resmi (bukan edit langsung pengguna) |

## 5. RPC yang dipanggil aplikasi

| Fungsi | Pemanggil | Kegunaan |
|---|---|---|
| `rpc_log_auth_event(p_event)` — LOGIN / LOGOUT | Semua pengguna | Catat login/logout ke audit trail |
| `rpc_my_context()` | Semua pengguna aktif | Profil, role, lingkup unit |
| `rpc_dashboard_overview()` | Semua pengguna aktif | Ringkasan dashboard sesuai role |
| `rpc_verify_audit_chain()` | SA, KPA, PWS, AUD | Verifikasi integritas audit trail |
| `rpc_service_audit(...)` | **Hanya service role** (Edge Function) | Catat tindakan pengelolaan akun atas nama SA |

Fungsi administratif `private.bootstrap_super_admin(email)` dan `private.next_document_number(prefix)` tidak dapat
dipanggil dari aplikasi.

## 6. Audit trail & rantai hash

Setiap baris `audit_logs` menyimpan `prev_hash` (hash baris sebelumnya) dan `row_hash` = SHA-256 dari seluruh isi
baris + `prev_hash`. Bila seseorang dengan akses administrator database mengubah atau menghapus baris secara
langsung, `rpc_verify_audit_chain()` mengembalikan `is_valid = false` beserta ID baris pertama yang rusak.

Yang dicatat pada Fase 2: LOGIN, LOGOUT, INSERT/UPDATE pada unit & profil, ROLE_CHANGE, CONFIG_CHANGE,
USER_CREATE, USER_ACTIVATE, USER_DEACTIVATE, USER_PASSWORD_RESET (password tidak pernah dicatat).

## 7. Pengujian

`bash scripts/test-db.sh` membuat database uji kosong, meniru bagian Supabase yang diperlukan
(`supabase/tests/_supabase_shim.sql`), menerapkan migration **dua kali** (uji idempotent), lalu menjalankan
`supabase/tests/rls/*.sql`. Hasil Fase 2: **72 pemeriksaan lolos**, mencakup akses tiap role, lintas unit,
pengguna nonaktif, anon, pemisahan fungsi, imutabilitas & deteksi manipulasi audit, serta hak eksekusi fungsi.

## 8. Tambahan Fase 3

| Migration | Isi |
|---|---|
| `20261120000600_hak_service_role.sql` | Hak minimum `service_role` (baca profil/role, ubah status aktif) untuk Edge Function pada proyek Supabase baru |
| `20261121000700_master_data.sql` | `item_categories` (7 kategori awal), `item_units` (18 satuan awal), `items`, `warehouses`, `storage_locations`, `suppliers`; audit & normalisasi kode huruf besar |
| `20261121000800_rls_master_mfa.sql` | Helper MFA, policy master data, penjaga usulan barang, `rpc_suggest_item_code`, dashboard & konteks pengguna diperbarui |

| Tabel | Baca | Tambah/Ubah | Aktif/Nonaktif |
|---|---|---|---|
| `item_categories`, `item_units`, `organizational_units` | Semua pengguna aktif | SA (MFA) | SA (MFA) |
| `items` | Semua pengguna aktif | SA (MFA), PGB (sebagai usulan) | SA (MFA) |
| `warehouses`, `storage_locations` | SA, KPA, PWS, PPK, PPB, PGB, AKT, TSO, AUD | SA (MFA), PGB | SA (MFA), PGB |
| `suppliers` | SA, KPA, PWS, PPK, PPB, PGB, AKT, AUD | SA (MFA), PPK | SA (MFA), PPK |

Tidak ada hak DELETE pada tabel master; data dinonaktifkan. Kolom `items.activated_at/activated_by` diisi otomatis
saat SA pertama kali mengaktifkan barang dan tidak dapat diisi dari aplikasi.

**Verifikasi dua langkah.** `private.is_admin_verified()` = punya role SA aktif **dan** (MFA tidak diwajibkan
**atau** token sesi `aal = aal2`). Dipakai di semua policy tulis SA, penjaga profil, dan Edge Function `admin-users` (v4).
Pengaturan `mfa_required_roles` di `app_settings` (default `["SA"]`).

Hasil uji Fase 3: **126 pemeriksaan lolos** (Fase 2 + layanan + master data + MFA).
