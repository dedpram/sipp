import { useEffect, useState } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { z } from 'zod';
import { Pencil, Save } from 'lucide-react';
import { PageHeader } from '@/components/layout/AppShell';
import { Card } from '@/components/ui/Card';
import { Button } from '@/components/ui/Button';
import { Field, Input, Select } from '@/components/ui/Input';
import { Alert } from '@/components/ui/Alert';
import { Badge } from '@/components/ui/Badge';
import { Modal } from '@/components/ui/Modal';
import { useToast } from '@/components/ui/Toast';
import { LoadingState, ErrorState } from '@/components/feedback/States';
import { useAuth } from '@/features/auth/AuthProvider';
import { supabase } from '@/lib/supabase';
import { toUserMessage, UserFacingError } from '@/lib/errors';
import { formatRupiah } from '@/lib/format';
import { ROLE_CODES, ROLE_LABELS, type RoleCode } from '@/lib/roles';
import type { AppSetting, ApprovalSetting } from '@/types/domain';

export const TRANSACTION_LABELS: Record<string, string> = {
  request: 'Permintaan barang',
  receipt: 'Pemeriksaan & pengesahan penerimaan',
  adjustment: 'Koreksi saldo',
  damaged: 'Reklasifikasi barang rusak/usang',
  write_off: 'Penghapusan persediaan',
  opname: 'Berita acara stock opname',
  discrepancy: 'Tindak lanjut kasus selisih',
  reconciliation: 'Reviu rekonsiliasi',
};

const SOURCE_LABELS: Record<string, string> = {
  pembelian: 'pembelian',
  hibah: 'hibah',
  transfer: 'transfer',
  lainnya: 'perolehan lain',
};

function describeCondition(a: ApprovalSetting): string {
  const parts: string[] = [];
  const src = a.applies_when?.source_type;
  if (Array.isArray(src)) parts.push(`sumber ${src.map((s) => SOURCE_LABELS[String(s)] ?? s).join(', ')}`);
  if (a.min_value != null) parts.push(`nilai > ${formatRupiah(Number(a.min_value) - 0.01)}`);
  if (a.max_value != null) parts.push(`nilai ≤ ${formatRupiah(a.max_value)}`);
  return parts.length ? parts.join('; ') : 'Semua transaksi';
}

// ---------------------------------------------------------------- Data
async function fetchSettings() {
  const [s, a] = await Promise.all([
    supabase.from('app_settings').select('key, value, description'),
    supabase
      .from('approval_settings')
      .select('id, transaction_type, level, approver_role_code, unit_scope, min_value, max_value, applies_when, is_required, is_active, description')
      .order('transaction_type')
      .order('level'),
  ]);
  if (s.error) throw s.error;
  if (a.error) throw a.error;
  const map = new Map((s.data as AppSetting[]).map((x) => [x.key, x.value]));
  return { settings: map, approvals: a.data as ApprovalSetting[] };
}

const intField = (label: string, min: number, max: number) =>
  z.preprocess(
    (v) => (v === '' ? NaN : Number(v)),
    z.number({ invalid_type_error: `${label} harus angka.` }).int(`${label} harus bilangan bulat.`).min(min, `${label} minimal ${min}.`).max(max, `${label} maksimal ${max}.`),
  );

const generalSchema = z.object({
  satker_code: z.preprocess((v) => String(v ?? '').trim().toUpperCase(), z.string().regex(/^[A-Z0-9]{2,12}$/, 'Kode 2–12 huruf besar/angka.')),
  satker_name: z.string().trim().min(3, 'Nama satuan kerja minimal 3 karakter.'),
  request_confirm_days: intField('Batas konfirmasi', 1, 30),
  slow_moving_days: intField('Batas barang tidak bergerak', 30, 1095),
  expiry_warning_days: intField('Peringatan kedaluwarsa', 7, 365),
  opname_freeze_locations: z.boolean(),
  opname_blind_count_default: z.boolean(),
  mfa_sa: z.boolean(),
});
type GeneralForm = z.input<typeof generalSchema>;
type GeneralValues = z.output<typeof generalSchema>;

export default function SettingsPage() {
  const { adminReady, hasRole } = useAuth();
  const toast = useToast();
  const qc = useQueryClient();
  const query = useQuery({ queryKey: ['settings'], queryFn: fetchSettings });
  const [editingApproval, setEditingApproval] = useState<ApprovalSetting | null>(null);

  const form = useForm<GeneralForm, unknown, GeneralValues>({ resolver: zodResolver(generalSchema) });
  useEffect(() => {
    const m = query.data?.settings;
    if (!m) return;
    const roles = m.get('mfa_required_roles');
    form.reset({
      satker_code: String(m.get('satker_code') ?? ''),
      satker_name: String(m.get('satker_name') ?? ''),
      request_confirm_days: String(m.get('request_confirm_days') ?? 3),
      slow_moving_days: String(m.get('slow_moving_days') ?? 180),
      expiry_warning_days: String(m.get('expiry_warning_days') ?? 90),
      opname_freeze_locations: m.get('opname_freeze_locations') === true,
      opname_blind_count_default: m.get('opname_blind_count_default') === true,
      mfa_sa: Array.isArray(roles) && roles.includes('SA'),
    });
  }, [query.data, form]);

  const saveGeneral = useMutation({
    mutationFn: async (v: GeneralValues) => {
      const current = query.data!.settings;
      const desired: Record<string, unknown> = {
        satker_code: v.satker_code,
        satker_name: v.satker_name,
        request_confirm_days: v.request_confirm_days,
        slow_moving_days: v.slow_moving_days,
        expiry_warning_days: v.expiry_warning_days,
        opname_freeze_locations: v.opname_freeze_locations,
        opname_blind_count_default: v.opname_blind_count_default,
        mfa_required_roles: v.mfa_sa ? ['SA'] : [],
      };
      let changed = 0;
      for (const [key, value] of Object.entries(desired)) {
        if (JSON.stringify(current.get(key)) === JSON.stringify(value)) continue;
        const { data, error } = await supabase.from('app_settings').update({ value }).eq('key', key).select('key');
        if (error) throw error;
        if (!data || data.length === 0) throw new UserFacingError('Anda tidak memiliki hak untuk mengubah pengaturan.');
        changed++;
      }
      return changed;
    },
    onSuccess: (n) => {
      toast.success(n ? `${n} pengaturan disimpan.` : 'Tidak ada perubahan.');
      void qc.invalidateQueries({ queryKey: ['settings'] });
    },
    onError: (err) => toast.error(toUserMessage(err)),
  });

  if (query.isLoading) return <LoadingState />;
  if (query.isError) return <ErrorState message={toUserMessage(query.error)} onRetry={() => void query.refetch()} />;

  const canEdit = adminReady;
  const errors = form.formState.errors;

  return (
    <>
      <PageHeader title="Pengaturan" description="Identitas satuan kerja, parameter pengendalian, dan jenjang persetujuan." />

      {!canEdit && (
        <Alert tone={hasRole('SA') ? 'warning' : 'info'} className="mb-4">
          {hasRole('SA')
            ? 'Aktifkan verifikasi dua langkah di menu Profil Saya untuk dapat mengubah pengaturan.'
            : 'Halaman ini hanya dapat dibaca. Perubahan dilakukan oleh Super Admin.'}
        </Alert>
      )}

      <div className="space-y-6">
        <Card title="Umum">
          <form onSubmit={form.handleSubmit((v) => saveGeneral.mutate(v))} className="space-y-4">
            <fieldset disabled={!canEdit} className="grid grid-cols-1 gap-4 sm:grid-cols-2">
              <Field label="Kode satuan kerja" required hint="Dipakai dalam nomor dokumen, mis. PNR/KODE/2026/11/00001" error={errors.satker_code?.message} htmlFor="st-code">
                <Input id="st-code" maxLength={12} {...form.register('satker_code')} />
              </Field>
              <Field label="Nama satuan kerja" required hint="Tampil pada kop laporan" error={errors.satker_name?.message} htmlFor="st-name">
                <Input id="st-name" {...form.register('satker_name')} />
              </Field>
              <Field label="Batas konfirmasi penerimaan oleh pemohon (hari kerja)" error={errors.request_confirm_days?.message} htmlFor="st-confirm">
                <Input id="st-confirm" inputMode="numeric" {...form.register('request_confirm_days')} />
              </Field>
              <Field label="Barang dianggap tidak bergerak setelah (hari)" error={errors.slow_moving_days?.message} htmlFor="st-slow">
                <Input id="st-slow" inputMode="numeric" {...form.register('slow_moving_days')} />
              </Field>
              <Field label="Peringatan kedaluwarsa sebelum (hari)" error={errors.expiry_warning_days?.message} htmlFor="st-exp">
                <Input id="st-exp" inputMode="numeric" {...form.register('expiry_warning_days')} />
              </Field>
              <div className="space-y-2 text-sm text-slate-700 sm:col-span-2">
                <label className="flex items-start gap-2">
                  <input type="checkbox" className="mt-0.5 h-4 w-4 accent-green-700" {...form.register('opname_blind_count_default')} />
                  <span>Stock opname memakai <b>blind count</b> secara default (penghitung tidak melihat saldo aplikasi)</span>
                </label>
                <label className="flex items-start gap-2">
                  <input type="checkbox" className="mt-0.5 h-4 w-4 accent-green-700" {...form.register('opname_freeze_locations')} />
                  <span>Bekukan transaksi pada lokasi yang sedang di-stock opname</span>
                </label>
                <label className="flex items-start gap-2">
                  <input type="checkbox" className="mt-0.5 h-4 w-4 accent-green-700" {...form.register('mfa_sa')} />
                  <span>
                    Wajibkan <b>verifikasi dua langkah</b> untuk Super Admin <span className="text-xs text-slate-500">(sangat disarankan tetap aktif)</span>
                  </span>
                </label>
              </div>
            </fieldset>
            {canEdit && (
              <Button type="submit" icon={Save} loading={saveGeneral.isPending}>
                Simpan pengaturan
              </Button>
            )}
          </form>
        </Card>

        <Card title="Jenjang persetujuan">
          <p className="mb-3 text-sm text-slate-600">
            Menentukan siapa yang menyetujui setiap jenis transaksi. Pembuat transaksi tidak pernah dapat menyetujui
            transaksinya sendiri.
          </p>
          <div className="overflow-x-auto rounded-lg border border-slate-200">
            <table className="min-w-full divide-y divide-slate-200 text-sm">
              <thead className="bg-slate-50 text-left text-slate-600">
                <tr>
                  <th className="px-3 py-2 font-semibold">Jenis transaksi</th>
                  <th className="px-3 py-2 font-semibold">Tingkat</th>
                  <th className="px-3 py-2 font-semibold">Penyetuju</th>
                  <th className="px-3 py-2 font-semibold">Berlaku untuk</th>
                  <th className="px-3 py-2 font-semibold">Status</th>
                  {canEdit && <th className="px-3 py-2" />}
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-100 bg-white">
                {query.data!.approvals.map((a) => (
                  <tr key={a.id}>
                    <td className="px-3 py-2">{TRANSACTION_LABELS[a.transaction_type] ?? a.transaction_type}</td>
                    <td className="px-3 py-2 tabular-nums">{a.level}</td>
                    <td className="px-3 py-2">
                      {ROLE_LABELS[a.approver_role_code] ?? a.approver_role_code}
                      {a.unit_scope === 'own_unit' && <span className="text-xs text-slate-500"> (unit pemohon)</span>}
                    </td>
                    <td className="px-3 py-2 text-xs text-slate-600">{describeCondition(a)}</td>
                    <td className="px-3 py-2">
                      <Badge tone={a.is_active ? 'success' : 'neutral'}>{a.is_active ? 'Aktif' : 'Nonaktif'}</Badge>
                    </td>
                    {canEdit && (
                      <td className="px-3 py-2 text-right">
                        <Button size="sm" variant="ghost" icon={Pencil} onClick={() => setEditingApproval(a)} aria-label="Ubah" />
                      </td>
                    )}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </Card>
      </div>

      <ApprovalModal row={editingApproval} onClose={() => setEditingApproval(null)} />
    </>
  );
}

// ---------------------------------------------------------------------
const approvalSchema = z.object({
  approver_role_code: z.enum(ROLE_CODES),
  min_value: z.preprocess(
    (v) => (v === '' || v == null ? null : Number(String(v).replace(/\./g, '').replace(',', '.'))),
    z.number({ invalid_type_error: 'Nilai harus angka.' }).min(0, 'Nilai tidak boleh negatif.').nullable(),
  ),
  is_active: z.boolean(),
});
type ApprovalForm = z.input<typeof approvalSchema>;
type ApprovalValues = z.output<typeof approvalSchema>;

const APPROVER_CHOICES: RoleCode[] = ['ATS', 'PWS', 'PPK'];

function ApprovalModal({ row, onClose }: { row: ApprovalSetting | null; onClose: () => void }) {
  const toast = useToast();
  const qc = useQueryClient();
  const form = useForm<ApprovalForm, unknown, ApprovalValues>({ resolver: zodResolver(approvalSchema) });
  useEffect(() => {
    if (row)
      form.reset({
        approver_role_code: row.approver_role_code,
        min_value: row.min_value != null ? String(Math.ceil(Number(row.min_value) - 0.01)) : '',
        is_active: row.is_active,
      });
  }, [row, form]);

  const mutation = useMutation({
    mutationFn: async (v: ApprovalValues) => {
      const payload = {
        approver_role_code: v.approver_role_code,
        // "di atas Rp X" disimpan sebagai X + 0,01
        min_value: v.min_value == null ? null : v.min_value + 0.01,
        is_active: v.is_active,
      };
      const { data, error } = await supabase.from('approval_settings').update(payload).eq('id', row!.id).select('id');
      if (error) throw error;
      if (!data || data.length === 0) throw new UserFacingError('Anda tidak memiliki hak untuk mengubah pengaturan.');
    },
    onSuccess: () => {
      toast.success('Jenjang persetujuan diperbarui.');
      void qc.invalidateQueries({ queryKey: ['settings'] });
      onClose();
    },
    onError: (err) => toast.error(toUserMessage(err)),
  });

  const errors = form.formState.errors;
  return (
    <Modal
      open={Boolean(row)}
      onClose={onClose}
      title={row ? `Ubah persetujuan — ${TRANSACTION_LABELS[row.transaction_type] ?? row.transaction_type} (tingkat ${row.level})` : ''}
      footer={
        <>
          <Button variant="secondary" onClick={onClose}>
            Batal
          </Button>
          <Button onClick={form.handleSubmit((v) => mutation.mutate(v))} loading={mutation.isPending}>
            Simpan
          </Button>
        </>
      }
    >
      <Field label="Penyetuju" error={errors.approver_role_code?.message} htmlFor="ap-role">
        <Select id="ap-role" {...form.register('approver_role_code')}>
          {APPROVER_CHOICES.map((r) => (
            <option key={r} value={r}>
              {ROLE_LABELS[r]}
            </option>
          ))}
        </Select>
      </Field>
      <Field
        label="Hanya bila nilai transaksi di atas (Rp)"
        hint="Kosongkan agar berlaku untuk semua nilai. Contoh: 5000000"
        error={errors.min_value?.message}
        htmlFor="ap-min"
      >
        <Input id="ap-min" inputMode="numeric" {...form.register('min_value')} />
      </Field>
      <label className="flex items-center gap-2 text-sm text-slate-700">
        <input type="checkbox" className="h-4 w-4 accent-green-700" {...form.register('is_active')} />
        Tingkat persetujuan ini aktif
      </label>
    </Modal>
  );
}
