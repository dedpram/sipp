import { NAV_ITEMS, visibleNavItems } from './navigation';

const keys = (roles: Parameters<typeof visibleNavItems>[0]) => visibleNavItems(roles).map((i) => i.key);

describe('menu sesuai role', () => {
  it('memiliki 15 menu utama sesuai spesifikasi', () => {
    expect(NAV_ITEMS).toHaveLength(15);
  });

  it('pengguna tanpa role tidak melihat menu apa pun', () => {
    expect(keys([])).toEqual([]);
  });

  it('Pegawai hanya melihat Dashboard, Permintaan, dan Laporan', () => {
    expect(keys(['PGW'])).toEqual(['dashboard', 'requests', 'reports']);
  });

  it('Super Admin melihat Pengguna dan Pengaturan tetapi tidak menu transaksi', () => {
    const k = keys(['SA']);
    expect(k).toContain('users');
    expect(k).toContain('settings');
    expect(k).not.toContain('issues');
    expect(k).not.toContain('receipts');
  });

  it('Auditor dapat melihat menu pengawasan dan pengguna (baca saja)', () => {
    const k = keys(['AUD']);
    expect(k).toContain('supervision');
    expect(k).toContain('users');
  });

  it('Petugas Akuntansi hanya melihat Dashboard, Rekonsiliasi, dan Laporan', () => {
    expect(keys(['AKT'])).toEqual(['dashboard', 'reconciliation', 'reports']);
  });

  it('gabungan role menghasilkan gabungan menu tanpa duplikasi', () => {
    const k = keys(['ATS', 'PGW']);
    expect(new Set(k).size).toBe(k.length);
    expect(k).toContain('stock-card');
  });
});
