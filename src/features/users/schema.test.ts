import { assignRoleSchema, createUserSchema } from './schema';
import { toUserMessage } from '@/lib/errors';

const validUser = {
  full_name: 'Budi Santoso',
  email: 'Budi@Instansi.go.id ',
  nip: '198501012010011001',
  position_title: '',
  primary_unit_id: '',
  password: 'RahasiaKuat2026',
  password_confirm: 'RahasiaKuat2026',
};

describe('validasi pengguna', () => {
  it('menerima data valid dan menormalkan email', () => {
    const r = createUserSchema.parse(validUser);
    expect(r.email).toBe('budi@instansi.go.id');
    expect(r.position_title).toBeNull();
  });

  it('menolak NIP yang bukan 18 digit', () => {
    expect(createUserSchema.safeParse({ ...validUser, nip: '12345' }).success).toBe(false);
  });

  it('menerima NIP kosong untuk non-ASN', () => {
    expect(createUserSchema.parse({ ...validUser, nip: '' }).nip).toBeNull();
  });

  it('menolak password lemah', () => {
    const r = createUserSchema.safeParse({ ...validUser, password: 'pendek', password_confirm: 'pendek' });
    expect(r.success).toBe(false);
  });

  it('menolak konfirmasi password berbeda', () => {
    const r = createUserSchema.safeParse({ ...validUser, password_confirm: 'BedaSekali2026' });
    expect(r.success).toBe(false);
  });

  it('role Atasan Unit wajib memilih unit', () => {
    const base = { role_id: 'x', role_code: 'ATS', unit_id: '', valid_from: '2026-11-19', valid_until: '', assignment_ref: '' };
    expect(assignRoleSchema.safeParse(base).success).toBe(false);
    expect(assignRoleSchema.safeParse({ ...base, unit_id: 'u1' }).success).toBe(true);
  });

  it('tanggal akhir penugasan tidak boleh sebelum tanggal mulai', () => {
    const r = assignRoleSchema.safeParse({
      role_id: 'x', role_code: 'AUD', unit_id: '', valid_from: '2026-11-19', valid_until: '2026-11-01', assignment_ref: '',
    });
    expect(r.success).toBe(false);
  });
});

describe('pesan error', () => {
  it('menerjemahkan pelanggaran RLS', () => {
    expect(toUserMessage({ message: 'new row violates row-level security policy for table "x"', code: '42501' })).toBe(
      'Anda tidak memiliki hak untuk melakukan tindakan ini.',
    );
  });
  it('meneruskan pesan bahasa Indonesia dari database', () => {
    expect(toUserMessage({ message: 'Anda tidak dapat mengubah role Anda sendiri.', code: '42501' })).toBe(
      'Anda tidak dapat mengubah role Anda sendiri.',
    );
  });
  it('menerjemahkan kegagalan jaringan', () => {
    expect(toUserMessage(new TypeError('Failed to fetch'))).toMatch(/koneksi internet/);
  });
  it('tidak menampilkan pesan teknis berbahasa Inggris', () => {
    expect(toUserMessage({ message: 'syntax error at or near "x"', code: '42601' })).toMatch(/Terjadi kesalahan/);
  });
});
