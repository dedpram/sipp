/**
 * Menerjemahkan error teknis (PostgreSQL/Supabase/jaringan) menjadi pesan
 * bahasa Indonesia yang dapat dipahami pengguna.
 * Pesan yang sudah ditulis dalam bahasa Indonesia oleh fungsi database
 * (RAISE EXCEPTION) diteruskan apa adanya.
 */
interface ErrorLike {
  message?: string;
  code?: string;
  details?: string;
  status?: number;
}

const GENERIC = 'Terjadi kesalahan. Silakan coba lagi atau hubungi Super Admin.';

export function toUserMessage(error: unknown): string {
  if (!error) return GENERIC;
  if (typeof error === 'string') return error;

  const e = error as ErrorLike;
  const msg = e.message ?? '';
  const lower = msg.toLowerCase();

  if (lower.includes('failed to fetch') || lower.includes('networkerror') || lower.includes('load failed')) {
    return 'Tidak dapat terhubung ke server. Periksa koneksi internet Anda.';
  }
  if (lower.includes('invalid login credentials')) {
    return 'Email atau password salah.';
  }
  if (lower.includes('email not confirmed')) {
    return 'Email belum dikonfirmasi. Hubungi Super Admin.';
  }
  if (lower.includes('user is banned')) {
    return 'Akun Anda dinonaktifkan. Hubungi Super Admin.';
  }
  if (lower.includes('jwt expired') || e.code === 'PGRST301') {
    return 'Sesi Anda telah berakhir. Silakan masuk kembali.';
  }
  if (lower.includes('row-level security') || lower.startsWith('permission denied')) {
    return 'Anda tidak memiliki hak untuk melakukan tindakan ini.';
  }
  if (e.code === '23505') {
    return 'Data dengan kode/nomor yang sama sudah ada.';
  }
  if (e.code === '23503') {
    return 'Data masih terhubung dengan data lain sehingga tidak dapat diproses.';
  }
  if (e.code === '23502') {
    return 'Ada isian wajib yang belum diisi.';
  }
  if (e.code === '22P02') {
    return 'Format data tidak valid.';
  }
  // Pesan dari fungsi database SIPP sudah berbahasa Indonesia.
  if (e.code === 'P0001' || e.code === '42501' || e.code === '23514' || e.code === '22023' || e.code === 'P0002') {
    return msg || GENERIC;
  }
  return msg && /[a-z]/i.test(msg) && /\b(tidak|anda|wajib|harus|sudah|belum)\b/i.test(msg) ? msg : GENERIC;
}
