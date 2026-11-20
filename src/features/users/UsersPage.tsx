import { useMemo, useState } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { KeyRound, Pencil, ShieldPlus, UserCheck, UserPlus, UserX, XCircle } from 'lucide-react';
import { PageHeader } from '@/components/layout/AppShell';
import { Card } from '@/components/ui/Card';
import { Badge } from '@/components/ui/Badge';
import { Button } from '@/components/ui/Button';
import { Select } from '@/components/ui/Input';
import { ConfirmDialog } from '@/components/ui/Modal';
import { useToast } from '@/components/ui/Toast';
import { DataTable, type Column } from '@/components/data-table/DataTable';
import { useAuth } from '@/features/auth/AuthProvider';
import { toUserMessage } from '@/lib/errors';
import { formatDate, formatDateTime } from '@/lib/format';
import { ROLE_LABELS } from '@/lib/roles';
import { adminSetActive, fetchUsersBundle, setRoleAssignmentActive, type UserRow } from './api';
import { AssignRoleModal, CreateUserModal, EditProfileModal, ResetPasswordModal } from './UserModals';

type Assignment = UserRow['assignments'][number];

export default function UsersPage() {
  const { context, adminReady } = useAuth();
  // Tombol pengelolaan hanya untuk Super Admin yang sudah verifikasi dua langkah.
  const isSA = adminReady;
  const toast = useToast();
  const qc = useQueryClient();
  const query = useQuery({ queryKey: ['users-bundle'], queryFn: fetchUsersBundle });

  const [statusFilter, setStatusFilter] = useState<'all' | 'active' | 'inactive'>('active');
  const [roleFilter, setRoleFilter] = useState('');
  const [creating, setCreating] = useState(false);
  const [editing, setEditing] = useState<UserRow | null>(null);
  const [assigning, setAssigning] = useState<UserRow | null>(null);
  const [resetting, setResetting] = useState<UserRow | null>(null);
  const [toggling, setToggling] = useState<UserRow | null>(null);
  const [revoking, setRevoking] = useState<Assignment | null>(null);

  const rows = useMemo(() => {
    const list = query.data?.users ?? [];
    return list.filter(
      (u) =>
        (statusFilter === 'all' || (statusFilter === 'active' ? u.is_active : !u.is_active)) &&
        (!roleFilter || u.assignments.some((a) => a.is_active && a.role_code === roleFilter)),
    );
  }, [query.data, statusFilter, roleFilter]);

  const toggleMutation = useMutation({
    mutationFn: ({ user, reason }: { user: UserRow; reason: string }) => adminSetActive(user.id, !user.is_active, reason),
    onSuccess: (_d, { user }) => {
      toast.success(user.is_active ? 'Akun dinonaktifkan.' : 'Akun diaktifkan kembali.');
      setToggling(null);
      void qc.invalidateQueries({ queryKey: ['users-bundle'] });
    },
    onError: (err) => toast.error(toUserMessage(err)),
  });

  const revokeMutation = useMutation({
    mutationFn: (a: Assignment) => setRoleAssignmentActive(a.id, false),
    onSuccess: () => {
      toast.success('Penugasan role dinonaktifkan.');
      setRevoking(null);
      void qc.invalidateQueries({ queryKey: ['users-bundle'] });
    },
    onError: (err) => toast.error(toUserMessage(err)),
  });

  const columns: Column<UserRow>[] = [
    {
      key: 'name',
      header: 'Nama / NIP',
      sortValue: (u) => u.full_name,
      searchValue: (u) => `${u.full_name} ${u.nip ?? ''} ${u.email}`,
      render: (u) => (
        <div>
          <p className="font-medium text-slate-900">{u.full_name}</p>
          <p className="text-xs text-slate-500">{u.nip ?? 'Tanpa NIP'} · {u.email}</p>
          {u.position_title && <p className="text-xs text-slate-500">{u.position_title}</p>}
        </div>
      ),
    },
    {
      key: 'unit',
      header: 'Unit',
      sortValue: (u) => u.unit_name,
      searchValue: (u) => u.unit_name ?? '',
      render: (u) => u.unit_name ?? <span className="text-slate-400">-</span>,
    },
    {
      key: 'roles',
      header: 'Role',
      searchValue: (u) => u.assignments.filter((a) => a.is_active).map((a) => ROLE_LABELS[a.role_code]).join(' '),
      render: (u) => {
        const active = u.assignments.filter((a) => a.is_active);
        if (active.length === 0) return <Badge tone="attention">Belum ada role</Badge>;
        return (
          <div className="flex flex-wrap gap-1">
            {active.map((a) => (
              <span key={a.id} className="inline-flex items-center gap-1">
                <Badge tone="success">
                  {ROLE_LABELS[a.role_code]}
                  {a.unit_name ? ` · ${a.unit_name}` : ''}
                  {a.valid_until ? ` (s.d. ${formatDate(a.valid_until)})` : ''}
                </Badge>
                {isSA && u.id !== context?.profile.id && (
                  <button onClick={() => setRevoking(a)} className="text-slate-400 hover:text-red-600" aria-label={`Cabut role ${ROLE_LABELS[a.role_code]}`}>
                    <XCircle className="h-3.5 w-3.5" />
                  </button>
                )}
              </span>
            ))}
          </div>
        );
      },
    },
    {
      key: 'status',
      header: 'Status',
      sortValue: (u) => (u.is_active ? 1 : 0),
      render: (u) => (
        <div className="space-y-0.5">
          <Badge tone={u.is_active ? 'success' : 'danger'}>{u.is_active ? 'Aktif' : 'Nonaktif'}</Badge>
          <p className="text-xs text-slate-500">Login: {formatDateTime(u.last_login_at)}</p>
        </div>
      ),
    },
  ];

  if (isSA) {
    columns.push({
      key: 'actions',
      header: 'Aksi',
      className: 'text-right',
      render: (u) => {
        const self = u.id === context?.profile.id;
        return (
          <div className="flex justify-end gap-1">
            <Button size="sm" variant="ghost" icon={Pencil} onClick={() => setEditing(u)} aria-label="Ubah profil" title="Ubah profil" />
            {!self && (
              <>
                <Button size="sm" variant="ghost" icon={ShieldPlus} onClick={() => setAssigning(u)} aria-label="Tetapkan role" title="Tetapkan role" />
                <Button size="sm" variant="ghost" icon={KeyRound} onClick={() => setResetting(u)} aria-label="Reset password" title="Reset password" />
                <Button
                  size="sm"
                  variant="ghost"
                  icon={u.is_active ? UserX : UserCheck}
                  onClick={() => setToggling(u)}
                  aria-label={u.is_active ? 'Nonaktifkan' : 'Aktifkan'}
                  title={u.is_active ? 'Nonaktifkan' : 'Aktifkan'}
                />
              </>
            )}
          </div>
        );
      },
    });
  }

  const units = query.data?.units ?? [];
  const roles = query.data?.roles ?? [];

  return (
    <>
      <PageHeader
        title="Pengguna dan Role"
        description={isSA ? 'Kelola akun, penugasan role, dan unit kerja pengguna.' : 'Daftar pengguna dan role (baca saja).'}
        actions={isSA && <Button icon={UserPlus} onClick={() => setCreating(true)}>Tambah Pengguna</Button>}
      />
      <Card>
        <DataTable
          rows={rows}
          columns={columns}
          rowKey={(u) => u.id}
          loading={query.isLoading}
          error={query.isError ? toUserMessage(query.error) : null}
          onRetry={() => void query.refetch()}
          searchPlaceholder="Cari nama, NIP, email, unit…"
          emptyTitle="Belum ada pengguna"
          toolbar={
            <>
              <Select value={statusFilter} onChange={(e) => setStatusFilter(e.target.value as typeof statusFilter)} aria-label="Filter status" className="w-36">
                <option value="active">Aktif</option>
                <option value="inactive">Nonaktif</option>
                <option value="all">Semua status</option>
              </Select>
              <Select value={roleFilter} onChange={(e) => setRoleFilter(e.target.value)} aria-label="Filter role" className="w-52">
                <option value="">Semua role</option>
                {roles.map((r) => (
                  <option key={r.id} value={r.code}>{ROLE_LABELS[r.code]}</option>
                ))}
              </Select>
            </>
          }
        />
      </Card>

      <CreateUserModal open={creating} onClose={() => setCreating(false)} units={units} />
      <EditProfileModal user={editing} onClose={() => setEditing(null)} units={units} />
      <AssignRoleModal user={assigning} onClose={() => setAssigning(null)} roles={roles} units={units} />
      <ResetPasswordModal user={resetting} onClose={() => setResetting(null)} />

      <ConfirmDialog
        open={Boolean(toggling)}
        title={toggling?.is_active ? 'Nonaktifkan akun?' : 'Aktifkan kembali akun?'}
        message={
          toggling?.is_active
            ? `${toggling.full_name} tidak akan dapat masuk ke aplikasi. Riwayat transaksinya tetap tersimpan.`
            : `${toggling?.full_name ?? ''} akan dapat masuk kembali sesuai role yang aktif.`
        }
        tone={toggling?.is_active ? 'danger' : 'primary'}
        confirmLabel={toggling?.is_active ? 'Nonaktifkan' : 'Aktifkan'}
        reasonLabel="Alasan"
        loading={toggleMutation.isPending}
        onCancel={() => setToggling(null)}
        onConfirm={(reason) => toggling && toggleMutation.mutate({ user: toggling, reason: reason ?? '' })}
      />
      <ConfirmDialog
        open={Boolean(revoking)}
        title="Cabut penugasan role?"
        message={revoking ? `Role ${ROLE_LABELS[revoking.role_code]}${revoking.unit_name ? ` (${revoking.unit_name})` : ''} akan dinonaktifkan. Riwayat penugasan tetap tersimpan di audit trail.` : ''}
        tone="danger"
        confirmLabel="Cabut role"
        loading={revokeMutation.isPending}
        onCancel={() => setRevoking(null)}
        onConfirm={() => revoking && revokeMutation.mutate(revoking)}
      />
    </>
  );
}
