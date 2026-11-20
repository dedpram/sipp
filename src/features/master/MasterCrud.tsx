/**
 * Komponen umum daftar + tambah/ubah + aktif/nonaktif untuk master data.
 * Tidak ada tombol hapus: master data hanya dinonaktifkan (riwayat tetap utuh).
 * Hak akses sesungguhnya tetap ditegakkan RLS di database.
 */
import { useEffect, useMemo, useState, type ReactNode } from 'react';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import type { z } from 'zod';
import { Pencil, Plus, ToggleLeft, ToggleRight } from 'lucide-react';
import { supabase } from '@/lib/supabase';
import { toUserMessage, UserFacingError } from '@/lib/errors';
import { Button } from '@/components/ui/Button';
import { Field, Input, Select } from '@/components/ui/Input';
import { Badge, type BadgeTone } from '@/components/ui/Badge';
import { Alert } from '@/components/ui/Alert';
import { ConfirmDialog, Modal } from '@/components/ui/Modal';
import { useToast } from '@/components/ui/Toast';
import { DataTable, type Column } from '@/components/data-table/DataTable';

export type MasterTable =
  | 'items'
  | 'item_categories'
  | 'item_units'
  | 'warehouses'
  | 'storage_locations'
  | 'suppliers'
  | 'organizational_units';

export interface Option {
  value: string;
  label: string;
}

export interface FieldDef {
  name: string;
  label: string;
  type?: 'text' | 'textarea' | 'number' | 'select' | 'checkbox';
  required?: boolean;
  hint?: string;
  options?: Option[];
  placeholder?: string;
  maxLength?: number;
  inputMode?: 'numeric' | 'decimal' | 'email' | 'tel' | 'text';
  /** Lebar penuh (2 kolom) di form. */
  full?: boolean;
}

export interface BaseRow {
  id: string;
  is_active: boolean;
}

type FormValues = Record<string, unknown>;

export interface FormApi {
  getValues: (name: string) => unknown;
  setValue: (name: string, value: unknown) => void;
}

export interface MasterConfig<R extends BaseRow> {
  table: MasterTable;
  /** Kata benda untuk pesan, mis. "barang". */
  noun: string;
  select: string;
  orderBy: string;
  fields: FieldDef[];
  schema: z.ZodTypeAny;
  toForm: (row: R | null) => FormValues;
  /** Penyesuaian data sebelum disimpan (mis. membuat kode otomatis). */
  prepare?: (values: FormValues, row: R | null) => FormValues;
  columns: Column<R>[];
  canCreate: boolean;
  canEdit: boolean;
  canToggle: boolean;
  status?: (row: R) => { label: string; tone: BadgeTone };
  searchPlaceholder: string;
  emptyDescription?: string;
  /** Catatan di atas tabel (mis. alasan hanya baca). */
  note?: ReactNode;
  /** Elemen tambahan di dalam form (mis. tombol usulan kode). */
  formExtra?: (api: FormApi) => ReactNode;
  /** Pesan setelah data baru tersimpan. */
  createdMessage?: (saved: R) => string;
}

export function useMasterRows<R extends BaseRow>(table: MasterTable, select: string, orderBy: string, enabled = true) {
  return useQuery({
    queryKey: ['master', table],
    enabled,
    queryFn: async (): Promise<R[]> => {
      const { data, error } = await supabase.from(table).select(select).order(orderBy);
      if (error) throw error;
      return (data ?? []) as unknown as R[];
    },
  });
}

export function MasterCrud<R extends BaseRow>({ config }: { config: MasterConfig<R> }) {
  const toast = useToast();
  const qc = useQueryClient();
  const query = useMasterRows<R>(config.table, config.select, config.orderBy);
  const [statusFilter, setStatusFilter] = useState<'all' | 'active' | 'inactive'>('all');
  const [editing, setEditing] = useState<{ row: R | null } | null>(null);
  const [toggling, setToggling] = useState<R | null>(null);

  const rows = useMemo(
    () =>
      (query.data ?? []).filter((r) =>
        statusFilter === 'all' ? true : statusFilter === 'active' ? r.is_active : !r.is_active,
      ),
    [query.data, statusFilter],
  );

  const toggleMutation = useMutation({
    mutationFn: async (row: R) => {
      const { data, error } = await supabase.from(config.table).update({ is_active: !row.is_active }).eq('id', row.id).select('id');
      if (error) throw error;
      if (!data || data.length === 0) throw new UserFacingError('Anda tidak memiliki hak untuk melakukan tindakan ini.');
    },
    onSuccess: (_d, row) => {
      toast.success(row.is_active ? `Data ${config.noun} dinonaktifkan.` : `Data ${config.noun} diaktifkan.`);
      setToggling(null);
      void qc.invalidateQueries({ queryKey: ['master'] });
      void qc.invalidateQueries({ queryKey: ['dashboard-overview'] });
    },
    onError: (err) => toast.error(toUserMessage(err)),
  });

  const columns: Column<R>[] = [
    ...config.columns,
    {
      key: '__status',
      header: 'Status',
      sortValue: (r) => (r.is_active ? 1 : 0),
      render: (r) => {
        const s = config.status?.(r) ?? { label: r.is_active ? 'Aktif' : 'Nonaktif', tone: r.is_active ? 'success' : 'neutral' };
        return <Badge tone={s.tone}>{s.label}</Badge>;
      },
    },
  ];
  if (config.canEdit || config.canToggle) {
    columns.push({
      key: '__actions',
      header: 'Aksi',
      className: 'text-right whitespace-nowrap',
      render: (r) => (
        <div className="flex justify-end gap-1">
          {config.canEdit && (
            <Button size="sm" variant="ghost" icon={Pencil} onClick={() => setEditing({ row: r })} aria-label="Ubah" title="Ubah" />
          )}
          {config.canToggle && (
            <Button
              size="sm"
              variant="ghost"
              icon={r.is_active ? ToggleRight : ToggleLeft}
              onClick={() => setToggling(r)}
              aria-label={r.is_active ? 'Nonaktifkan' : 'Aktifkan'}
              title={r.is_active ? 'Nonaktifkan' : 'Aktifkan'}
            />
          )}
        </div>
      ),
    });
  }

  return (
    <div className="space-y-3">
      {config.note}
      <DataTable
        rows={rows}
        columns={columns}
        rowKey={(r) => r.id}
        loading={query.isLoading}
        error={query.isError ? toUserMessage(query.error) : null}
        onRetry={() => void query.refetch()}
        searchPlaceholder={config.searchPlaceholder}
        emptyTitle={`Belum ada data ${config.noun}`}
        emptyDescription={config.emptyDescription}
        toolbar={
          <>
            <Select
              value={statusFilter}
              onChange={(e) => setStatusFilter(e.target.value as typeof statusFilter)}
              aria-label="Filter status"
              className="w-40"
            >
              <option value="all">Semua status</option>
              <option value="active">Aktif</option>
              <option value="inactive">Nonaktif / usulan</option>
            </Select>
            {config.canCreate && (
              <Button icon={Plus} onClick={() => setEditing({ row: null })}>
                Tambah
              </Button>
            )}
          </>
        }
      />

      <MasterFormModal config={config} target={editing} onClose={() => setEditing(null)} />

      <ConfirmDialog
        open={Boolean(toggling)}
        title={toggling?.is_active ? `Nonaktifkan ${config.noun}?` : `Aktifkan ${config.noun}?`}
        message={
          toggling?.is_active
            ? `Data ini tidak dapat dipilih lagi pada transaksi baru. Riwayat yang sudah ada tetap utuh.`
            : `Data ini akan dapat dipilih kembali pada transaksi.`
        }
        tone={toggling?.is_active ? 'danger' : 'primary'}
        confirmLabel={toggling?.is_active ? 'Nonaktifkan' : 'Aktifkan'}
        loading={toggleMutation.isPending}
        onCancel={() => setToggling(null)}
        onConfirm={() => toggling && toggleMutation.mutate(toggling)}
      />
    </div>
  );
}

function MasterFormModal<R extends BaseRow>({
  config,
  target,
  onClose,
}: {
  config: MasterConfig<R>;
  target: { row: R | null } | null;
  onClose: () => void;
}) {
  const toast = useToast();
  const qc = useQueryClient();
  const form = useForm<FormValues, unknown, FormValues>({ resolver: zodResolver(config.schema) });
  const row = target?.row ?? null;

  // Hanya di-reset saat form dibuka untuk data tertentu, bukan setiap render
  // (agar isian yang sedang diketik tidak hilang).
  useEffect(() => {
    if (target) form.reset(config.toForm(target.row));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [target, form]);

  const mutation = useMutation({
    mutationFn: async (values: FormValues): Promise<R> => {
      const payload = config.prepare ? config.prepare(values, row) : values;
      if (row) {
        const { data, error } = await supabase.from(config.table).update(payload).eq('id', row.id).select('*');
        if (error) throw error;
        if (!data || data.length === 0) throw new UserFacingError('Anda tidak memiliki hak untuk mengubah data ini.');
        return data[0] as unknown as R;
      }
      const { data, error } = await supabase.from(config.table).insert({ ...payload, is_active: true }).select('*').single();
      if (error) throw error;
      return data as unknown as R;
    },
    onSuccess: (saved) => {
      toast.success(row ? `Data ${config.noun} diperbarui.` : (config.createdMessage?.(saved) ?? `Data ${config.noun} ditambahkan.`));
      void qc.invalidateQueries({ queryKey: ['master'] });
      void qc.invalidateQueries({ queryKey: ['dashboard-overview'] });
      onClose();
    },
    onError: (err) => toast.error(toUserMessage(err)),
  });

  const errors = form.formState.errors as unknown as Record<string, { message?: string } | undefined>;
  const api: FormApi = {
    getValues: (name) => form.getValues(name),
    setValue: (name, value) => form.setValue(name, value, { shouldValidate: true }),
  };

  return (
    <Modal
      open={Boolean(target)}
      onClose={onClose}
      size="lg"
      title={row ? `Ubah ${config.noun}` : `Tambah ${config.noun}`}
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
      {mutation.isError && <Alert tone="danger">{toUserMessage(mutation.error)}</Alert>}
      {config.formExtra?.(api)}
      <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
        {config.fields.map((f) => {
          const id = `mf-${config.table}-${f.name}`;
          const err = errors[f.name]?.message;
          const wrap = f.full || f.type === 'textarea' ? 'sm:col-span-2' : '';
          if (f.type === 'checkbox') {
            return (
              <label key={f.name} className={`flex items-start gap-2 text-sm text-slate-700 ${wrap}`}>
                <input type="checkbox" className="mt-0.5 h-4 w-4 accent-green-700" {...form.register(f.name)} />
                <span>
                  {f.label}
                  {f.hint && <span className="block text-xs text-slate-500">{f.hint}</span>}
                </span>
              </label>
            );
          }
          return (
            <div key={f.name} className={wrap}>
              <Field label={f.label} required={f.required} hint={f.hint} error={err} htmlFor={id}>
                {f.type === 'select' ? (
                  <Select id={id} invalid={Boolean(err)} {...form.register(f.name)}>
                    <option value="">— Pilih —</option>
                    {(f.options ?? []).map((o) => (
                      <option key={o.value} value={o.value}>
                        {o.label}
                      </option>
                    ))}
                  </Select>
                ) : f.type === 'textarea' ? (
                  <textarea
                    id={id}
                    rows={3}
                    maxLength={f.maxLength}
                    placeholder={f.placeholder}
                    className="block w-full rounded-lg border border-slate-300 px-3 py-2 text-sm focus:border-green-600 focus:outline-none focus:ring-2 focus:ring-green-600/40"
                    {...form.register(f.name)}
                  />
                ) : (
                  <Input
                    id={id}
                    invalid={Boolean(err)}
                    inputMode={f.inputMode ?? (f.type === 'number' ? 'decimal' : undefined)}
                    maxLength={f.maxLength}
                    placeholder={f.placeholder}
                    {...form.register(f.name)}
                  />
                )}
              </Field>
            </div>
          );
        })}
      </div>
    </Modal>
  );
}
