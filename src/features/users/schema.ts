import { z } from 'zod';

const optionalText = z
  .string()
  .trim()
  .transform((v) => (v === '' ? null : v))
  .nullable();

export const nipSchema = z
  .string()
  .trim()
  .refine((v) => v === '' || /^\d{18}$/.test(v), 'NIP harus 18 digit angka.')
  .transform((v) => (v === '' ? null : v));

/** Aturan password: min 12 karakter, huruf besar, huruf kecil, angka. */
export const passwordSchema = z
  .string()
  .min(12, 'Password minimal 12 karakter.')
  .regex(/[A-Z]/, 'Password harus mengandung huruf besar.')
  .regex(/[a-z]/, 'Password harus mengandung huruf kecil.')
  .regex(/\d/, 'Password harus mengandung angka.');

export const createUserSchema = z
  .object({
    full_name: z.string().trim().min(3, 'Nama minimal 3 karakter.'),
    email: z.string().trim().toLowerCase().email('Format email tidak valid.'),
    nip: nipSchema,
    position_title: optionalText,
    primary_unit_id: optionalText,
    password: passwordSchema,
    password_confirm: z.string(),
  })
  .refine((v) => v.password === v.password_confirm, {
    message: 'Konfirmasi password tidak sama.',
    path: ['password_confirm'],
  });

export type CreateUserForm = z.input<typeof createUserSchema>;
export type CreateUserValues = z.output<typeof createUserSchema>;

export const editProfileSchema = z.object({
  full_name: z.string().trim().min(3, 'Nama minimal 3 karakter.'),
  nip: nipSchema,
  position_title: optionalText,
  primary_unit_id: optionalText,
  phone: optionalText,
});
export type EditProfileForm = z.input<typeof editProfileSchema>;
export type EditProfileValues = z.output<typeof editProfileSchema>;

export const assignRoleSchema = z
  .object({
    role_id: z.string().min(1, 'Pilih role.'),
    role_code: z.string(),
    unit_id: optionalText,
    valid_from: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'Tanggal mulai wajib diisi.'),
    valid_until: optionalText,
    assignment_ref: optionalText,
  })
  .refine((v) => !['ATS', 'PGW'].includes(v.role_code) || Boolean(v.unit_id), {
    message: 'Role ini wajib memilih unit kerja.',
    path: ['unit_id'],
  })
  .refine((v) => !v.valid_until || v.valid_until >= v.valid_from, {
    message: 'Tanggal akhir tidak boleh sebelum tanggal mulai.',
    path: ['valid_until'],
  });
export type AssignRoleForm = z.input<typeof assignRoleSchema>;
export type AssignRoleValues = z.output<typeof assignRoleSchema>;
