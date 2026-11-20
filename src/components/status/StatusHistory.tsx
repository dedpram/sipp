import { useQuery } from '@tanstack/react-query';
import { supabase } from '@/lib/supabase';
import { formatDateTime } from '@/lib/format';
import { ROLE_LABELS, type RoleCode } from '@/lib/roles';
import { LoadingState } from '@/components/feedback/States';

interface HistoryRow {
  id: number;
  from_status: string | null;
  to_status: string;
  comment: string | null;
  actor_id: string | null;
  created_at: string;
}

interface ApprovalRow {
  id: string;
  required_role_code: RoleCode;
  approver_id: string;
  decision: 'approved' | 'rejected' | 'returned';
  notes: string | null;
  decided_at: string;
}

const DECISION: Record<ApprovalRow['decision'], string> = {
  approved: 'Menyetujui',
  rejected: 'Menolak',
  returned: 'Mengembalikan',
};

/** Riwayat status & persetujuan suatu transaksi (dari tabel permanen). */
export function StatusHistory({
  refTable,
  refId,
  statusLabel,
  personName,
}: {
  refTable: string;
  refId: string;
  statusLabel: (s: string) => string;
  personName: (id: string | null) => string;
}) {
  const query = useQuery({
    queryKey: ['history', refTable, refId],
    queryFn: async () => {
      const [h, a] = await Promise.all([
        supabase.from('status_histories').select('id, from_status, to_status, comment, actor_id, created_at').eq('ref_table', refTable).eq('ref_id', refId).order('id'),
        supabase.from('approvals').select('id, required_role_code, approver_id, decision, notes, decided_at').eq('ref_table', refTable).eq('ref_id', refId).order('decided_at'),
      ]);
      if (h.error) throw h.error;
      if (a.error) throw a.error;
      return { history: h.data as HistoryRow[], approvals: a.data as ApprovalRow[] };
    },
  });
  if (query.isLoading || !query.data) return <LoadingState />;

  return (
    <div className="grid gap-6 lg:grid-cols-2">
      <div>
        <h3 className="mb-2 text-sm font-semibold text-slate-700">Riwayat status</h3>
        <ol className="relative space-y-3 border-l border-slate-200 pl-4">
          {query.data.history.map((h) => (
            <li key={h.id} className="text-sm">
              <span className="absolute -left-1.5 mt-1.5 h-3 w-3 rounded-full border-2 border-white bg-green-600" />
              <p className="font-medium text-slate-800">{statusLabel(h.to_status)}</p>
              <p className="text-xs text-slate-500">
                {personName(h.actor_id)} · {formatDateTime(h.created_at)}
              </p>
              {h.comment && <p className="mt-0.5 text-xs text-slate-600">{h.comment}</p>}
            </li>
          ))}
        </ol>
      </div>
      <div>
        <h3 className="mb-2 text-sm font-semibold text-slate-700">Persetujuan</h3>
        {query.data.approvals.length === 0 ? (
          <p className="text-sm text-slate-500">Belum ada keputusan persetujuan.</p>
        ) : (
          <ul className="space-y-2">
            {query.data.approvals.map((a) => (
              <li key={a.id} className="rounded-lg border border-slate-200 p-2 text-sm">
                <p>
                  <b>{personName(a.approver_id)}</b> ({ROLE_LABELS[a.required_role_code] ?? a.required_role_code}) —{' '}
                  {DECISION[a.decision]}
                </p>
                <p className="text-xs text-slate-500">{formatDateTime(a.decided_at)}</p>
                {a.notes && <p className="mt-0.5 text-xs text-slate-600">{a.notes}</p>}
              </li>
            ))}
          </ul>
        )}
      </div>
    </div>
  );
}
