import { formatDate, formatDateTime, formatNumber, formatRupiah } from './format';

describe('format Indonesia', () => {
  it('menampilkan tanggal dengan nama bulan Indonesia', () => {
    expect(formatDate('2026-11-19')).toBe('19 November 2026');
  });

  it('mengonversi waktu UTC ke WIB (Asia/Jakarta)', () => {
    // 13:42 UTC = 20:42 WIB
    expect(formatDateTime('2026-11-19T13:42:00Z')).toMatch(/19 Nov 2026 20[.:]42 WIB/);
  });

  it('tanggal 31 Desember 17:30 UTC sudah 1 Januari di WIB', () => {
    expect(formatDate('2026-12-31T17:30:00Z')).toBe('1 Januari 2027');
  });

  it('memformat Rupiah dengan pemisah ribuan titik dan desimal koma', () => {
    expect(formatRupiah(1234567.5)).toBe('Rp1.234.567,50');
    expect(formatRupiah('550000')).toBe('Rp550.000,00');
  });

  it('memformat angka kuantitas', () => {
    expect(formatNumber(1234.5)).toBe('1.234,5');
  });

  it('mengembalikan tanda strip untuk nilai kosong', () => {
    expect(formatDate(null)).toBe('-');
    expect(formatRupiah(undefined)).toBe('-');
    expect(formatNumber('abc')).toBe('-');
  });
});
