/**
 * Verifikasi dua langkah (TOTP) memakai aplikasi autentikator di HP,
 * seperti Google Authenticator atau Microsoft Authenticator.
 */
import { supabase } from '@/lib/supabase';
import { UserFacingError } from '@/lib/errors';

export interface VerifiedFactor {
  id: string;
  friendly_name?: string | null;
  created_at: string;
}

export async function listVerifiedTotp(): Promise<VerifiedFactor[]> {
  const { data, error } = await supabase.auth.mfa.listFactors();
  if (error) throw error;
  return (data?.totp ?? []) as VerifiedFactor[];
}

/** Hapus pendaftaran yang belum selesai agar pendaftaran baru tidak bentrok. */
async function removeUnverifiedFactors(): Promise<void> {
  const { data } = await supabase.auth.mfa.listFactors();
  const all = (data?.all ?? []) as Array<{ id: string; status: string; factor_type: string }>;
  for (const f of all) {
    if (f.factor_type === 'totp' && f.status !== 'verified') {
      await supabase.auth.mfa.unenroll({ factorId: f.id });
    }
  }
}

export interface Enrollment {
  factorId: string;
  qrCode: string; // gambar SVG (data URL)
  secret: string; // kode untuk diketik manual bila QR tidak bisa dipindai
}

export async function startEnrollment(): Promise<Enrollment> {
  await removeUnverifiedFactors();
  const { data, error } = await supabase.auth.mfa.enroll({
    factorType: 'totp',
    friendlyName: `SIPP ${new Date().toISOString().slice(0, 10)}`,
  });
  if (error || !data) throw error ?? new UserFacingError('Pendaftaran verifikasi dua langkah gagal dimulai.');
  return { factorId: data.id, qrCode: data.totp.qr_code, secret: data.totp.secret };
}

export async function verifyCode(factorId: string, code: string): Promise<void> {
  const clean = code.replace(/\s+/g, '');
  if (!/^\d{6}$/.test(clean)) throw new UserFacingError('Kode harus 6 digit angka.');
  const { error } = await supabase.auth.mfa.challengeAndVerify({ factorId, code: clean });
  if (error) {
    throw new UserFacingError(
      /invalid|expired/i.test(error.message)
        ? 'Kode salah atau sudah kedaluwarsa. Masukkan kode terbaru dari aplikasi autentikator.'
        : `Verifikasi gagal: ${error.message}`,
    );
  }
}

export async function removeFactor(factorId: string): Promise<void> {
  const { error } = await supabase.auth.mfa.unenroll({ factorId });
  if (error) throw new UserFacingError(`Verifikasi dua langkah tidak dapat dinonaktifkan: ${error.message}`);
}
