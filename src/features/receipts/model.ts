/** Tipe, label status, dan aturan tampilan modul Penerimaan. */
import type { BadgeTone } from '@/components/ui/Badge';

export type ReceiptStatus =
  | 'draft'
  | 'menunggu_pemeriksaan'
  | 'dalam_pemeriksaan'
  | 'tidak_sesuai'
  | 'menunggu_tindak_lanjut_penyedia'
  | 'menunggu_pengesahan'
  | 'disetujui'
  | 'diterima_disimpan'
  | 'selesai'
  | 'dibatalkan';

export type SourceType = 'pembelian' | 'hibah' | 'transfer' | 'lainnya' | 'saldo_awal';
export type InspectionResult = 'sesuai' | 'tidak_sesuai_jumlah' | 'tidak_sesuai_spesifikasi' | 'rusak';

export interface Receipt {
  id: string;
  receipt_no: string;
  receipt_date: string;
  source_type: SourceType;
  supplier_id: string | null;
  contract_no: string | null;
  contract_date: string | null;
  order_no: string | null;
  delivery_note_no: string | null;
  invoice_no: string | null;
  source_description: string | null;
  warehouse_id: string;
  status: ReceiptStatus;
  notes: string | null;
  inspector_id: string | null;
  inspected_at: string | null;
  inspection_notes: string | null;
  approved_by: string | null;
  approved_at: string | null;
  finalized_by: string | null;
  finalized_at: string | null;
  accounting_verified_by: string | null;
  accounting_verified_at: string | null;
  cancel_reason: string | null;
  total_value: number;
  created_by: string | null;
  created_at: string;
}

export interface ReceiptDetail {
  id: string;
  receipt_id: string;
  line_no: number;
  item_id: string;
  qty_ordered: number | null;
  qty_received: number;
  qty_accepted: number;
  qty_rejected: number;
  unit_cost: number;
  location_id: string | null;
  expiry_date: string | null;
  inspection_result: InspectionResult | null;
  inspection_notes: string | null;
}

export const STATUS_INFO: Record<ReceiptStatus, { label: string; tone: BadgeTone }> = {
  draft: { label: 'Draf', tone: 'neutral' },
  menunggu_pemeriksaan: { label: 'Menunggu pemeriksaan', tone: 'waiting' },
  dalam_pemeriksaan: { label: 'Dalam pemeriksaan', tone: 'process' },
  tidak_sesuai: { label: 'Tidak sesuai', tone: 'danger' },
  menunggu_tindak_lanjut_penyedia: { label: 'Menunggu tindak lanjut penyedia', tone: 'attention' },
  menunggu_pengesahan: { label: 'Menunggu pengesahan', tone: 'waiting' },
  disetujui: { label: 'Disetujui', tone: 'process' },
  diterima_disimpan: { label: 'Diterima dan disimpan', tone: 'success' },
  selesai: { label: 'Selesai', tone: 'success' },
  dibatalkan: { label: 'Dibatalkan', tone: 'danger' },
};

export const SOURCE_LABELS: Record<SourceType, string> = {
  pembelian: 'Pembelian',
  hibah: 'Hibah',
  transfer: 'Transfer masuk',
  lainnya: 'Perolehan sah lainnya',
  saldo_awal: 'Saldo awal',
};

export const RESULT_LABELS: Record<InspectionResult, string> = {
  sesuai: 'Sesuai',
  tidak_sesuai_jumlah: 'Jumlah tidak sesuai',
  tidak_sesuai_spesifikasi: 'Spesifikasi tidak sesuai',
  rusak: 'Rusak',
};

/** Urutan langkah untuk tampilan stepper. */
export const STEPS: { key: string; label: string; statuses: ReceiptStatus[] }[] = [
  { key: 'draft', label: 'Draf', statuses: ['draft'] },
  {
    key: 'periksa',
    label: 'Pemeriksaan & pengesahan',
    statuses: ['menunggu_pemeriksaan', 'dalam_pemeriksaan', 'tidak_sesuai', 'menunggu_tindak_lanjut_penyedia', 'menunggu_pengesahan'],
  },
  { key: 'simpan', label: 'Simpan ke gudang', statuses: ['disetujui', 'diterima_disimpan'] },
  { key: 'selesai', label: 'Selesai', statuses: ['selesai'] },
];

export function stepIndex(status: ReceiptStatus): number {
  return STEPS.findIndex((s) => s.statuses.includes(status));
}

export const DOC_TYPES: { value: string; label: string }[] = [
  { value: 'ba_pemeriksaan', label: 'Berita Acara Pemeriksaan' },
  { value: 'ba_penerimaan', label: 'Berita Acara Penerimaan' },
  { value: 'surat_jalan', label: 'Surat Jalan' },
  { value: 'faktur', label: 'Faktur' },
  { value: 'kontrak', label: 'Kontrak / SPK / Pesanan' },
  { value: 'ba_saldo_awal', label: 'Berita Acara Saldo Awal' },
  { value: 'foto', label: 'Foto barang' },
  { value: 'lainnya', label: 'Dokumen lain' },
];

export function requiredDocs(source: SourceType): string[] {
  if (source === 'saldo_awal') return ['ba_saldo_awal'];
  if (source === 'pembelian') return ['ba_pemeriksaan', 'surat_jalan|faktur'];
  return ['ba_pemeriksaan'];
}

/** Status ketika lampiran masih boleh ditambahkan (sama dengan aturan database). */
export const ATTACHABLE: ReceiptStatus[] = [
  'draft',
  'menunggu_pemeriksaan',
  'dalam_pemeriksaan',
  'tidak_sesuai',
  'menunggu_tindak_lanjut_penyedia',
];

/** Siapa memeriksa sekaligus mengesahkan (sesuai pengaturan default). */
export function inspectorLabel(source: SourceType): string {
  return source === 'pembelian' ? 'PPK' : 'Pejabat Pengawas';
}
