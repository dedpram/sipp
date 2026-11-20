import { useQuery } from '@tanstack/react-query';
import { Link } from 'react-router';
import {
  Activity,
  Bell,
  Building2,
  ClipboardList,
  Coins,
  PackageSearch,
  PackagePlus,
  Boxes,
  ShieldCheck,
  UserX,
  Users,
} from 'lucide-react';
import { supabase } from '@/lib/supabase';
import { toUserMessage } from '@/lib/errors';
import { formatDateTime, formatNumber, formatRupiah } from '@/lib/format';
import { ROLE_LABELS } from '@/lib/roles';
import type { DashboardOverview } from '@/types/domain';
import { PageHeader } from '@/components/layout/AppShell';
import { Card, StatCard } from '@/components/ui/Card';
import { Badge } from '@/components/ui/Badge';
import { Alert } from '@/components/ui/Alert';
import { EmptyState, ErrorState, LoadingState } from '@/components/feedback/States';
import { useAuth } from '@/features/auth/AuthProvider';

const ACTION_LABELS: Record<string, string> = {
  LOGIN: 'Masuk',
  LOGOUT: 'Keluar',
  INSERT: 'Menambah data',
  UPDATE: 'Mengubah data',
  DELETE: 'Menghapus data',
  ROLE_CHANGE: 'Perubahan role',
  CONFIG_CHANGE: 'Perubahan konfigurasi',
  USER_CREATE: 'Membuat akun',
  USER_ACTIVATE: 'Mengaktifkan akun',
  USER_DEACTIVATE: 'Menonaktifkan akun',
  USER_PASSWORD_RESET: 'Reset password',
};

async function fetchOverview(): Promise<DashboardOverview> {
  const { data, error } = await supabase.rpc('rpc_dashboard_overview');
  if (error) throw error;
  return data as DashboardOverview;
}

export default function DashboardPage() {
  const { context, roles } = useAuth();
  const query = useQuery({ queryKey: ['dashboard-overview'], queryFn: fetchOverview });

  return (
    <>
      <PageHeader
        title={`Selamat datang, ${context?.profile.full_name ?? ''}`}
        description={context?.profile.primary_unit_name ? `Unit kerja: ${context.profile.primary_unit_name}` : undefined}
      />

      {roles.length === 0 && (
        <Alert tone="warning" className="mb-4">
          Akun Anda belum memiliki role. Hubungi Super Admin agar diberikan role sesuai tugas Anda.
        </Alert>
      )}

      <div className="mb-4 flex flex-wrap gap-1.5">
        {roles.map((r) => (
          <Badge key={r} tone="success">
            {ROLE_LABELS[r]}
          </Badge>
        ))}
      </div>

      {query.isLoading ? (
        <LoadingState />
      ) : query.isError ? (
        <ErrorState message={toUserMessage(query.error)} onRetry={() => void query.refetch()} />
      ) : query.data ? (
        <div className="space-y-6">
          <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 xl:grid-cols-4">
            <StatCard label="Notifikasi belum dibaca" value={formatNumber(query.data.unread_notifications)} icon={Bell} tone="sky" />
            <StatCard label="Unit kerja aktif" value={formatNumber(query.data.active_units)} icon={Building2} />
            <StatCard label="Jenis barang aktif" value={formatNumber(query.data.active_items)} icon={Boxes} />
            {query.data.proposed_items !== undefined && (
              <Link to="/master-data?tab=barang" className="block">
                <StatCard
                  label="Usulan barang menunggu aktivasi"
                  value={formatNumber(query.data.proposed_items)}
                  icon={PackagePlus}
                  tone={query.data.proposed_items > 0 ? 'amber' : 'slate'}
                  hint="Diaktifkan oleh Super Admin"
                />
              </Link>
            )}
            {query.data.active_users !== undefined && (
              <StatCard label="Pengguna aktif" value={formatNumber(query.data.active_users)} icon={Users} />
            )}
            {query.data.users_without_role !== undefined && (
              <StatCard
                label="Pengguna tanpa role"
                value={formatNumber(query.data.users_without_role)}
                icon={UserX}
                tone={query.data.users_without_role > 0 ? 'amber' : 'slate'}
                hint="Perlu ditetapkan oleh Super Admin"
              />
            )}
            {query.data.audit_events_today !== undefined && (
              <StatCard label="Aktivitas tercatat hari ini" value={formatNumber(query.data.audit_events_today)} icon={ShieldCheck} tone="slate" />
            )}
          </div>

          {query.data.stock && (
            <Card title="Indikator persediaan">
              <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 xl:grid-cols-4">
                <StatCard label="Nilai persediaan" value={<span className="text-lg">{formatRupiah(query.data.stock.total_value)}</span>} icon={Coins} tone="sky" hint={`${formatNumber(query.data.stock.items_in_stock)} jenis barang tersimpan`} />
                <Link to="/penyimpanan" className="block">
                  <StatCard label="Di bawah stok minimum" value={formatNumber(query.data.stock.below_min)} icon={PackageSearch} tone={query.data.stock.below_min ? 'amber' : 'slate'} hint={`${formatNumber(query.data.stock.above_max)} melebihi maksimum`} />
                </Link>
                <Link to="/penyimpanan?tab=kedaluwarsa" className="block">
                  <StatCard label="Mendekati/lewat kedaluwarsa" value={formatNumber(query.data.stock.expiring)} icon={ClipboardList} tone={query.data.stock.expiring ? 'red' : 'slate'} />
                </Link>
                <Link to="/penerimaan" className="block">
                  <StatCard label="Penerimaan sedang diproses" value={formatNumber(query.data.stock.receipts_open)} icon={Boxes} tone={query.data.stock.receipts_open ? 'amber' : 'slate'} hint={`${formatNumber(query.data.stock.receipts_month)} selesai disimpan bulan ini`} />
                </Link>
              </div>
              <p className="mt-3 text-xs text-slate-500">Permintaan dan pengeluaran barang tersedia setelah Fase 4B. Grafik lengkap pada Fase 6.</p>
            </Card>
          )}

          {query.data.recent_activity && (
            <Card title={<span className="inline-flex items-center gap-2"><Activity className="h-4 w-4" /> Aktivitas terbaru</span>}>
              {query.data.recent_activity.length === 0 ? (
                <EmptyState title="Belum ada aktivitas" />
              ) : (
                <ul className="divide-y divide-slate-100">
                  {query.data.recent_activity.map((a, i) => (
                    <li key={i} className="flex flex-wrap items-center justify-between gap-2 py-2 text-sm">
                      <span>
                        <span className="font-medium text-slate-800">{a.user_name ?? 'Sistem'}</span>{' '}
                        <span className="text-slate-600">— {ACTION_LABELS[a.action] ?? a.action}</span>
                        {a.table_name && <span className="text-slate-400"> ({a.table_name})</span>}
                      </span>
                      <span className="text-xs text-slate-500">{formatDateTime(a.occurred_at)}</span>
                    </li>
                  ))}
                </ul>
              )}
            </Card>
          )}
        </div>
      ) : null}
    </>
  );
}
