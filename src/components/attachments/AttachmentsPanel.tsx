import { useRef, useState } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { FileText, Paperclip, Upload } from 'lucide-react';
import { Button } from '@/components/ui/Button';
import { Select } from '@/components/ui/Input';
import { Badge } from '@/components/ui/Badge';
import { useToast } from '@/components/ui/Toast';
import { EmptyState, LoadingState } from '@/components/feedback/States';
import { listAttachments, openAttachment, uploadAttachment } from '@/lib/documents';
import { toUserMessage } from '@/lib/errors';
import { formatDateTime } from '@/lib/format';

interface Props {
  refTable: string;
  refId: string;
  canUpload: boolean;
  docTypes: { value: string; label: string }[];
  /** Kode jenis dokumen wajib; "a|b" berarti salah satu. */
  required?: string[];
  personName: (id: string | null) => string;
}

export function AttachmentsPanel({ refTable, refId, canUpload, docTypes, required = [], personName }: Props) {
  const toast = useToast();
  const qc = useQueryClient();
  const fileRef = useRef<HTMLInputElement>(null);
  const [docType, setDocType] = useState(docTypes[0]?.value ?? 'lainnya');
  const key = ['attachments', refTable, refId];
  const query = useQuery({ queryKey: key, queryFn: () => listAttachments(refTable, refId) });

  const upload = useMutation({
    mutationFn: (file: File) => uploadAttachment(refTable, refId, docType, file),
    onSuccess: () => {
      toast.success('Dokumen berhasil diunggah.');
      void qc.invalidateQueries({ queryKey: key });
    },
    onError: (err) => toast.error(toUserMessage(err)),
  });

  const label = (v: string) => docTypes.find((d) => d.value === v)?.label ?? v;
  const have = new Set((query.data ?? []).map((a) => a.doc_type));

  return (
    <div className="space-y-4">
      {required.length > 0 && (
        <div className="flex flex-wrap items-center gap-2 text-sm">
          <span className="text-slate-600">Dokumen wajib:</span>
          {required.map((r) => {
            const options = r.split('|');
            const ok = options.some((o) => have.has(o));
            return (
              <Badge key={r} tone={ok ? 'success' : 'attention'}>
                {options.map(label).join(' atau ')} {ok ? '✓' : '(belum)'}
              </Badge>
            );
          })}
        </div>
      )}

      {canUpload && (
        <div className="flex flex-col gap-2 rounded-lg border border-dashed border-slate-300 p-3 sm:flex-row sm:items-center">
          <Select value={docType} onChange={(e) => setDocType(e.target.value)} className="sm:w-64" aria-label="Jenis dokumen">
            {docTypes.map((d) => (
              <option key={d.value} value={d.value}>
                {d.label}
              </option>
            ))}
          </Select>
          <input
            ref={fileRef}
            type="file"
            accept="application/pdf,image/jpeg,image/png,image/webp"
            className="hidden"
            onChange={(e) => {
              const f = e.target.files?.[0];
              if (f) upload.mutate(f);
              e.target.value = '';
            }}
          />
          <Button icon={Upload} loading={upload.isPending} onClick={() => fileRef.current?.click()}>
            Pilih & unggah file
          </Button>
          <span className="text-xs text-slate-500">PDF/JPG/PNG, maks. 10 MB</span>
        </div>
      )}

      {query.isLoading ? (
        <LoadingState />
      ) : (query.data ?? []).length === 0 ? (
        <EmptyState title="Belum ada dokumen" />
      ) : (
        <ul className="divide-y divide-slate-100 rounded-lg border border-slate-200">
          {(query.data ?? []).map((a) => (
            <li key={a.id} className="flex flex-wrap items-center justify-between gap-2 p-3 text-sm">
              <span className="flex min-w-0 items-center gap-2">
                <FileText className="h-4 w-4 shrink-0 text-slate-400" />
                <span className="min-w-0">
                  <span className="block truncate font-medium">{a.file_name}</span>
                  <span className="text-xs text-slate-500">
                    {label(a.doc_type)} · {personName(a.uploaded_by)} · {formatDateTime(a.uploaded_at)}
                  </span>
                </span>
              </span>
              <Button
                size="sm"
                variant="secondary"
                icon={Paperclip}
                onClick={() => openAttachment(a.storage_path).catch((err) => toast.error(toUserMessage(err)))}
              >
                Buka
              </Button>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
