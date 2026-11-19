/** Format tampilan Indonesia: tanggal, waktu WIB, Rupiah, angka. */
export const APP_TIMEZONE = 'Asia/Jakarta';

const dateFmt = new Intl.DateTimeFormat('id-ID', {
  timeZone: APP_TIMEZONE,
  day: 'numeric',
  month: 'long',
  year: 'numeric',
});

const dateTimeFmt = new Intl.DateTimeFormat('id-ID', {
  timeZone: APP_TIMEZONE,
  day: '2-digit',
  month: 'short',
  year: 'numeric',
  hour: '2-digit',
  minute: '2-digit',
  hour12: false,
});

const rupiahFmt = new Intl.NumberFormat('id-ID', {
  style: 'currency',
  currency: 'IDR',
  minimumFractionDigits: 2,
  maximumFractionDigits: 2,
});

const numberFmt = new Intl.NumberFormat('id-ID', { maximumFractionDigits: 3 });

function toDate(value: string | Date | null | undefined): Date | null {
  if (value === null || value === undefined || value === '') return null;
  // Tanggal murni 'YYYY-MM-DD' diperlakukan sebagai tanggal kalender (bukan UTC tengah malam).
  if (typeof value === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(value)) {
    const [y, m, d] = value.split('-').map(Number);
    return new Date(Date.UTC(y!, m! - 1, d!, 5)); // 12.00 WIB
  }
  const d = value instanceof Date ? value : new Date(value);
  return Number.isNaN(d.getTime()) ? null : d;
}

/** 19 November 2026 */
export function formatDate(value: string | Date | null | undefined): string {
  const d = toDate(value);
  return d ? dateFmt.format(d) : '-';
}

/** 19 Nov 2026 20.42 WIB */
export function formatDateTime(value: string | Date | null | undefined): string {
  const d = toDate(value);
  return d ? `${dateTimeFmt.format(d).replace(',', '')} WIB` : '-';
}

/** Rp1.234.567,00 */
export function formatRupiah(value: number | string | null | undefined): string {
  if (value === null || value === undefined || value === '') return '-';
  const n = typeof value === 'string' ? Number(value) : value;
  if (!Number.isFinite(n)) return '-';
  return rupiahFmt.format(n).replace(/ /g, '');
}

/** 1.234,5 */
export function formatNumber(value: number | string | null | undefined): string {
  if (value === null || value === undefined || value === '') return '-';
  const n = typeof value === 'string' ? Number(value) : value;
  return Number.isFinite(n) ? numberFmt.format(n) : '-';
}
