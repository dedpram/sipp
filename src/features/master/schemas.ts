/** Validasi form master data (diulang di database dengan CHECK constraint). */
import { z } from 'zod';

/** Teks opsional: kosong -> null. */
export const optText = (inner: z.ZodString = z.string()) =>
  z.preprocess((v) => {
    if (v === undefined || v === null) return null;
    if (typeof v === 'string') {
      const t = v.trim();
      return t === '' ? null : t;
    }
    return v;
  }, inner.nullable());

export const reqText = (label: string, min = 1) =>
  z.preprocess((v) => (typeof v === 'string' ? v.trim() : v), z.string({ required_error: `${label} wajib diisi.` }).min(min, min > 1 ? `${label} minimal ${min} karakter.` : `${label} wajib diisi.`));

export const reqSelect = (label: string) =>
  z.string({ required_error: `Pilih ${label}.` }).min(1, `Pilih ${label}.`);

export const code = (re: RegExp, message: string) =>
  z.preprocess((v) => (typeof v === 'string' ? v.trim().toUpperCase() : v), z.string().regex(re, message));

export const qty = (label: string) =>
  z.preprocess(
    (v) => (v === '' || v === null || v === undefined ? 0 : Number(String(v).replace(',', '.'))),
    z.number({ invalid_type_error: `${label} harus berupa angka.` }).min(0, `${label} tidak boleh negatif.`),
  );

export const optQty = (label: string) =>
  z.preprocess(
    (v) => (v === '' || v === null || v === undefined ? null : Number(String(v).replace(',', '.'))),
    z.number({ invalid_type_error: `${label} harus berupa angka.` }).positive(`${label} harus lebih dari 0.`).nullable(),
  );

export const bool = z.preprocess((v) => v === true || v === 'true' || v === 'on', z.boolean());

// ------------------------------------------------------------------------
export const itemSchema = z
  .object({
    category_id: reqSelect('kategori'),
    code: code(/^[A-Z0-9][A-Z0-9.-]{1,29}$/, 'Kode 2–30 karakter: huruf besar, angka, titik, atau tanda minus.'),
    name: reqText('Nama barang', 2),
    unit_id: reqSelect('satuan'),
    specification: optText(),
    brand: optText(),
    min_stock: qty('Stok minimum'),
    safety_stock: qty('Stok pengaman'),
    max_stock: optQty('Stok maksimum'),
    has_expiry: bool,
  })
  .refine((v) => v.max_stock === null || v.min_stock <= v.max_stock, {
    message: 'Stok minimum tidak boleh melebihi stok maksimum.',
    path: ['min_stock'],
  })
  .refine((v) => v.max_stock === null || v.safety_stock <= v.max_stock, {
    message: 'Stok pengaman tidak boleh melebihi stok maksimum.',
    path: ['safety_stock'],
  });

export const categorySchema = z.object({
  code: code(/^[A-Z0-9]{2,10}$/, 'Kode 2–10 huruf besar/angka, tanpa spasi.'),
  name: reqText('Nama kategori'),
  account_code: optText(z.string().regex(/^[0-9.]{3,20}$/, 'Kode akun hanya angka dan titik, mis. 117111.')),
  description: optText(),
});

export const unitSchema = z.object({
  code: code(/^[A-Z]{2,6}$/, 'Kode 2–6 huruf besar, mis. RIM.'),
  name: reqText('Nama satuan'),
});

export const warehouseSchema = z.object({
  code: code(/^[A-Z0-9-]{2,10}$/, 'Kode 2–10 huruf besar/angka, mis. GDG1.'),
  name: reqText('Nama gudang'),
  address: optText(),
  pic_user_id: optText(),
});

export const locationSchema = z.object({
  warehouse_id: reqSelect('gudang'),
  room: reqText('Ruangan'),
  rack: optText(),
  location_number: optText(),
  code: optText(z.string().regex(/^[A-Z0-9][A-Z0-9.-]{1,39}$/i, 'Kode hanya huruf, angka, titik, atau tanda minus.')),
  description: optText(),
});

export const supplierSchema = z.object({
  name: reqText('Nama penyedia', 2),
  npwp: z.preprocess(
    (v) => {
      if (typeof v !== 'string') return null;
      const digits = v.replace(/\D/g, '');
      return digits === '' ? null : digits;
    },
    z.string().regex(/^\d{15,16}$/, 'NPWP harus 15 atau 16 digit angka.').nullable(),
  ),
  contact_person: optText(),
  phone: optText(),
  email: optText(z.string().email('Format email tidak valid.')),
  address: optText(),
});

export const orgUnitSchema = z.object({
  code: code(/^[A-Z0-9-]{1,15}$/, 'Kode 1–15 huruf besar/angka, mis. UMUM.'),
  name: reqText('Nama unit'),
  parent_id: optText(),
  head_user_id: optText(),
});

/** Membuat kode lokasi otomatis: GDG1-A-01 (spasi dibuang). */
export function buildLocationCode(warehouseCode: string, room: string, rack: string | null, number: string | null): string {
  const clean = (s: string) => s.toUpperCase().replace(/[^A-Z0-9]+/g, '');
  const parts = [warehouseCode, rack && rack !== '-' ? rack : room, number && number !== '-' ? number : null]
    .filter((p): p is string => Boolean(p))
    .map(clean)
    .filter(Boolean);
  return parts.join('-').slice(0, 40);
}
