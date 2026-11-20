/**
 * Lampiran dokumen di Supabase Storage (bucket privat "documents").
 * Path: <tabel>/<id transaksi>/<uuid>-<nama file>. Hak unggah & unduh
 * dicek oleh aturan akses Storage di database.
 */
import { supabase } from '@/lib/supabase';
import { UserFacingError } from '@/lib/errors';

export interface Attachment {
  id: string;
  ref_table: string;
  ref_id: string;
  doc_type: string;
  storage_path: string;
  file_name: string;
  mime_type: string | null;
  size_bytes: number | null;
  uploaded_by: string | null;
  uploaded_at: string;
}

export const MAX_UPLOAD_BYTES = 10 * 1024 * 1024;
export const ALLOWED_MIME = ['application/pdf', 'image/jpeg', 'image/png', 'image/webp'];

export async function listAttachments(refTable: string, refId: string): Promise<Attachment[]> {
  const { data, error } = await supabase
    .from('attachments')
    .select('id, ref_table, ref_id, doc_type, storage_path, file_name, mime_type, size_bytes, uploaded_by, uploaded_at')
    .eq('ref_table', refTable)
    .eq('ref_id', refId)
    .order('uploaded_at');
  if (error) throw error;
  return (data ?? []) as Attachment[];
}

function safeName(name: string): string {
  return name
    .normalize('NFKD')
    .replace(/[^\w.-]+/g, '_')
    .replace(/_+/g, '_')
    .slice(-80);
}

export async function uploadAttachment(refTable: string, refId: string, docType: string, file: File): Promise<void> {
  if (!ALLOWED_MIME.includes(file.type)) {
    throw new UserFacingError('Jenis file tidak didukung. Gunakan PDF, JPG, PNG, atau WEBP.');
  }
  if (file.size > MAX_UPLOAD_BYTES) {
    throw new UserFacingError('Ukuran file maksimal 10 MB.');
  }
  const path = `${refTable}/${refId}/${crypto.randomUUID()}-${safeName(file.name)}`;
  const up = await supabase.storage.from('documents').upload(path, file, { contentType: file.type, upsert: false });
  if (up.error) {
    throw new UserFacingError(
      /row-level security|unauthorized|403/i.test(up.error.message)
        ? 'Dokumen tidak dapat diunggah pada tahap ini atau Anda tidak berwenang.'
        : `Unggah gagal: ${up.error.message}`,
    );
  }
  const { error } = await supabase.from('attachments').insert({
    ref_table: refTable,
    ref_id: refId,
    doc_type: docType,
    storage_path: path,
    file_name: file.name,
    mime_type: file.type,
    size_bytes: file.size,
  });
  if (error) throw error;
}

export async function openAttachment(path: string): Promise<void> {
  const { data, error } = await supabase.storage.from('documents').createSignedUrl(path, 60);
  if (error || !data) throw new UserFacingError('Dokumen tidak dapat dibuka. Anda mungkin tidak berwenang.');
  window.open(data.signedUrl, '_blank', 'noopener');
}
