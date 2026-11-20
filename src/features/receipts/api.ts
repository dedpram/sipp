/** Akses data modul Penerimaan. Perubahan status selalu melalui fungsi RPC database. */
import { supabase } from '@/lib/supabase';
import { UserFacingError } from '@/lib/errors';
import type { Receipt, ReceiptDetail, SourceType } from './model';

const RECEIPT_COLS =
  'id, receipt_no, receipt_date, source_type, supplier_id, contract_no, contract_date, order_no, delivery_note_no, invoice_no, ' +
  'source_description, warehouse_id, status, notes, inspector_id, inspected_at, inspection_notes, approved_by, approved_at, ' +
  'finalized_by, finalized_at, accounting_verified_by, accounting_verified_at, cancel_reason, total_value, created_by, created_at';

const DETAIL_COLS =
  'id, receipt_id, line_no, item_id, qty_ordered, qty_received, qty_accepted, qty_rejected, unit_cost, location_id, expiry_date, inspection_result, inspection_notes';

export async function fetchReceipts(): Promise<Receipt[]> {
  const { data, error } = await supabase.from('receipts').select(RECEIPT_COLS).order('receipt_date', { ascending: false }).order('receipt_no', { ascending: false }).limit(1000);
  if (error) throw error;
  return (data ?? []) as unknown as Receipt[];
}

export async function fetchReceipt(id: string): Promise<{ receipt: Receipt; details: ReceiptDetail[] }> {
  const [r, d] = await Promise.all([
    supabase.from('receipts').select(RECEIPT_COLS).eq('id', id).maybeSingle(),
    supabase.from('receipt_details').select(DETAIL_COLS).eq('receipt_id', id).order('line_no'),
  ]);
  if (r.error) throw r.error;
  if (d.error) throw d.error;
  if (!r.data) throw new UserFacingError('Penerimaan tidak ditemukan atau Anda tidak berwenang melihatnya.');
  return { receipt: r.data as unknown as Receipt, details: (d.data ?? []) as unknown as ReceiptDetail[] };
}

export interface ReceiptHeaderInput {
  receipt_date: string;
  source_type: SourceType;
  warehouse_id: string;
  supplier_id: string | null;
  contract_no: string | null;
  contract_date: string | null;
  order_no: string | null;
  delivery_note_no: string | null;
  invoice_no: string | null;
  source_description: string | null;
  notes: string | null;
}

export async function createReceipt(input: ReceiptHeaderInput): Promise<string> {
  const { data, error } = await supabase.from('receipts').insert(input).select('id').single();
  if (error) throw error;
  return (data as { id: string }).id;
}

export async function updateReceipt(id: string, input: ReceiptHeaderInput): Promise<void> {
  const { data, error } = await supabase.from('receipts').update(input).eq('id', id).select('id');
  if (error) throw error;
  if (!data?.length) throw new UserFacingError('Penerimaan tidak dapat diubah (bukan draf Anda).');
}

export interface DetailInput {
  item_id: string;
  qty_ordered: number | null;
  qty_received: number;
  unit_cost: number;
  location_id: string | null;
}

export async function saveDetail(receiptId: string, input: DetailInput, detailId?: string, lineNo?: number): Promise<void> {
  if (detailId) {
    const { data, error } = await supabase.from('receipt_details').update(input).eq('id', detailId).select('id');
    if (error) throw error;
    if (!data?.length) throw new UserFacingError('Rincian tidak dapat diubah.');
    return;
  }
  const { error } = await supabase.from('receipt_details').insert({ ...input, receipt_id: receiptId, line_no: lineNo ?? 1 });
  if (error) throw error;
}

export async function deleteDetail(detailId: string): Promise<void> {
  const { data, error } = await supabase.from('receipt_details').delete().eq('id', detailId).select('id');
  if (error) throw error;
  if (!data?.length) throw new UserFacingError('Rincian tidak dapat dihapus.');
}

async function rpc(name: string, args: Record<string, unknown>): Promise<void> {
  const { error } = await supabase.rpc(name, args);
  if (error) throw error;
}

export const submitReceipt = (id: string) => rpc('rpc_receipt_submit', { p_id: id });
export const startInspection = (id: string) => rpc('rpc_receipt_start_inspection', { p_id: id });

export interface InspectionLine {
  detail_id: string;
  qty_received: number;
  qty_accepted: number;
  qty_rejected: number;
  result: string;
  notes: string | null;
  expiry_date: string | null;
}
export const recordInspection = (id: string, lines: InspectionLine[], notes: string | null, decision: 'lanjut' | 'tindak_lanjut') =>
  rpc('rpc_receipt_record_inspection', { p_id: id, p_lines: lines, p_notes: notes, p_decision: decision });
export const vendorFollowup = (id: string, comment: string) => rpc('rpc_receipt_vendor_followup', { p_id: id, p_comment: comment });
export const finalizeReceipt = (id: string, locations: Record<string, string>) =>
  rpc('rpc_receipt_finalize', { p_id: id, p_locations: locations });
export const cancelReceipt = (id: string, reason: string) => rpc('rpc_receipt_cancel', { p_id: id, p_reason: reason });

/** Role pemeriksa sekaligus pengesah penerimaan menurut pengaturan jenjang persetujuan. */
export async function fetchReceiptApproverRoles(source: SourceType): Promise<string[]> {
  const { data, error } = await supabase
    .from('approval_settings')
    .select('approver_role_code, applies_when, is_active')
    .eq('transaction_type', 'receipt')
    .eq('is_active', true);
  if (error) throw error;
  return (data ?? [])
    .filter((a: { applies_when: { source_type?: string[] } }) => {
      const src = a.applies_when?.source_type;
      return !src || src.includes(source);
    })
    .map((a: { approver_role_code: string }) => a.approver_role_code);
}
