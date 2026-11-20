/** Kode role sesuai tabel `roles` di database. */
export const ROLE_CODES = [
  'SA',
  'PWS',
  'PPK',
  'PPB',
  'PGB',
  'PGW',
  'ATS',
  'AKT',
  'TSO',
  'AUD',
] as const;

export type RoleCode = (typeof ROLE_CODES)[number];

export const ROLE_LABELS: Record<RoleCode, string> = {
  SA: 'Super Admin',
  PWS: 'Pejabat Pengawas / Koordinator',
  PPK: 'Pejabat Pembuat Komitmen',
  PPB: 'Petugas Penerima Barang',
  PGB: 'Pengurus Barang Persediaan',
  PGW: 'Pegawai / Unit Pemohon',
  ATS: 'Atasan Unit',
  AKT: 'Petugas Akuntansi',
  TSO: 'Tim Stock Opname',
  AUD: 'Auditor / APIP',
};

/** Role yang wajib dikaitkan dengan unit kerja (sama dengan aturan database). */
export const UNIT_SCOPED_ROLES: readonly RoleCode[] = ['ATS', 'PGW'];

export function isRoleCode(value: unknown): value is RoleCode {
  return typeof value === 'string' && (ROLE_CODES as readonly string[]).includes(value);
}

export function hasAnyRole(userRoles: readonly RoleCode[], allowed: readonly RoleCode[] | 'all'): boolean {
  if (allowed === 'all') return userRoles.length > 0;
  return userRoles.some((r) => allowed.includes(r));
}
