import { useEffect } from 'react';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { z } from 'zod';
import { useMutation, useQueryClient } from '@tanstack/react-query';
import { useNavigate } from 'react-router';
import { Modal } from '@/components/ui/Modal';
import { Button } from '@/components/ui/Button';
import { Field, Input, Select } from '@/components/ui/Input';
import { Alert } from '@/components/ui/Alert';
import { useToast } from '@/components/ui/Toast';
import { toUserMessage } from '@/lib/errors';
import { optText } from '@/features/master/schemas';
import { useLookups } from '@/features/master/lookups';
import { createReceipt, updateReceipt } from './api';
import { SOURCE_LABELS, type Receipt, type SourceType } from './model';

const todayJakarta = () => new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Jakarta' }).format(new Date());

const schema = z
  .object({
    receipt_date: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'Tanggal wajib diisi.'),
    source_type: z.enum(['pembelian', 'hibah', 'transfer', 'lainnya', 'saldo_awal']),
    warehouse_id: z.string().min(1, 'Pilih gudang.'),
    supplier_id: optText(),
    contract_no: optText(),
    contract_date: optText(),
    order_no: optText(),
    delivery_note_no: optText(),
    invoice_no: optText(),
    source_description: optText(),
    notes: optText(),
  })
  .refine((v) => v.receipt_date <= todayJakarta(), { message: 'Tanggal tidak boleh di masa depan.', path: ['receipt_date'] })
  .refine((v) => v.source_type !== 'pembelian' || Boolean(v.supplier_id), { message: 'Pilih penyedia.', path: ['supplier_id'] })
  .refine((v) => v.source_type !== 'pembelian' || Boolean(v.contract_no || v.order_no), {
    message: 'Isi nomor kontrak/SPK atau nomor pesanan.',
    path: ['contract_no'],
  })
  .refine((v) => !['hibah', 'transfer', 'lainnya'].includes(v.source_type) || Boolean(v.source_description), {
    message: 'Jelaskan asal perolehan.',
    path: ['source_description'],
  });
type FormIn = z.input<typeof schema>;
type FormOut = z.output<typeof schema>;

export function ReceiptHeaderModal({ open, receipt, onClose }: { open: boolean; receipt: Receipt | null; onClose: () => void }) {
  const toast = useToast();
  const qc = useQueryClient();
  const navigate = useNavigate();
  const lk = useLookups();
  const form = useForm<FormIn, unknown, FormOut>({ resolver: zodResolver(schema) });

  useEffect(() => {
    if (!open) return;
    form.reset({
      receipt_date: receipt?.receipt_date ?? todayJakarta(),
      source_type: receipt?.source_type ?? 'pembelian',
      warehouse_id: receipt?.warehouse_id ?? lk.warehouses.find((w) => w.is_active)?.id ?? '',
      supplier_id: receipt?.supplier_id ?? '',
      contract_no: receipt?.contract_no ?? '',
      contract_date: receipt?.contract_date ?? '',
      order_no: receipt?.order_no ?? '',
      delivery_note_no: receipt?.delivery_note_no ?? '',
      invoice_no: receipt?.invoice_no ?? '',
      source_description: receipt?.source_description ?? '',
      notes: receipt?.notes ?? '',
    });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open, receipt, form]);

  const source = form.watch('source_type') as SourceType;
  const mutation = useMutation({
    mutationFn: async (v: FormOut) => {
      const payload = {
        ...v,
        supplier_id: v.source_type === 'pembelian' ? v.supplier_id : null,
        source_description: ['hibah', 'transfer', 'lainnya'].includes(v.source_type) ? v.source_description : null,
      };
      if (receipt) {
        await updateReceipt(receipt.id, payload);
        return receipt.id;
      }
      return createReceipt(payload);
    },
    onSuccess: (id) => {
      toast.success(receipt ? 'Data penerimaan diperbarui.' : 'Draf penerimaan dibuat. Tambahkan barang yang diterima.');
      void qc.invalidateQueries({ queryKey: ['receipts'] });
      void qc.invalidateQueries({ queryKey: ['receipt', id] });
      onClose();
      if (!receipt) navigate(`/penerimaan/${id}`);
    },
    onError: (err) => toast.error(toUserMessage(err)),
  });

  const e = form.formState.errors;
  const reg = form.register;
  return (
    <Modal
      open={open}
      onClose={onClose}
      size="lg"
      title={receipt ? `Ubah ${receipt.receipt_no}` : 'Buat Penerimaan Barang'}
      footer={
        <>
          <Button variant="secondary" onClick={onClose}>Batal</Button>
          <Button onClick={form.handleSubmit((v) => mutation.mutate(v))} loading={mutation.isPending}>Simpan draf</Button>
        </>
      }
    >
      {source === 'saldo_awal' && (
        <Alert tone="info">
          Saldo awal dipakai sekali saat aplikasi mulai digunakan, berdasarkan hasil inventarisasi. Wajib melampirkan
          Berita Acara Saldo Awal; diperiksa dan disahkan Pejabat Pengawas.
        </Alert>
      )}
      <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
        <Field label="Sumber penerimaan" required error={e.source_type?.message} htmlFor="rh-src">
          <Select id="rh-src" {...reg('source_type')}>
            {(Object.keys(SOURCE_LABELS) as SourceType[]).map((s) => (
              <option key={s} value={s}>{SOURCE_LABELS[s]}</option>
            ))}
          </Select>
        </Field>
        <Field label="Tanggal penerimaan" required error={e.receipt_date?.message} htmlFor="rh-date">
          <Input id="rh-date" type="date" max={todayJakarta()} {...reg('receipt_date')} />
        </Field>
        <Field label="Gudang tujuan" required error={e.warehouse_id?.message} htmlFor="rh-wh">
          <Select id="rh-wh" {...reg('warehouse_id')}>
            <option value="">— Pilih —</option>
            {lk.warehouses.filter((w) => w.is_active).map((w) => (
              <option key={w.id} value={w.id}>{w.name} ({w.code})</option>
            ))}
          </Select>
        </Field>
        {source === 'pembelian' && (
          <>
            <Field label="Penyedia" required error={e.supplier_id?.message} htmlFor="rh-sup">
              <Select id="rh-sup" {...reg('supplier_id')}>
                <option value="">— Pilih —</option>
                {lk.suppliers.filter((s) => s.is_active).map((s) => (
                  <option key={s.id} value={s.id}>{s.name}</option>
                ))}
              </Select>
            </Field>
            <Field label="No. kontrak / SPK" error={e.contract_no?.message} htmlFor="rh-ctr">
              <Input id="rh-ctr" {...reg('contract_no')} />
            </Field>
            <Field label="Tanggal kontrak" htmlFor="rh-ctrd">
              <Input id="rh-ctrd" type="date" {...reg('contract_date')} />
            </Field>
            <Field label="No. pesanan" hint="Isi bila tidak ada kontrak/SPK" htmlFor="rh-ord">
              <Input id="rh-ord" {...reg('order_no')} />
            </Field>
            <Field label="No. surat jalan" htmlFor="rh-sj">
              <Input id="rh-sj" {...reg('delivery_note_no')} />
            </Field>
            <Field label="No. faktur" htmlFor="rh-fak">
              <Input id="rh-fak" {...reg('invoice_no')} />
            </Field>
          </>
        )}
        {['hibah', 'transfer', 'lainnya'].includes(source) && (
          <div className="sm:col-span-2">
            <Field label="Asal perolehan" required hint="Mis. nama pemberi hibah, satker asal transfer, dasar perolehan" error={e.source_description?.message} htmlFor="rh-desc">
              <Input id="rh-desc" {...reg('source_description')} />
            </Field>
          </div>
        )}
        <div className="sm:col-span-2">
          <Field label="Catatan" htmlFor="rh-notes">
            <textarea id="rh-notes" rows={2} className="block w-full rounded-lg border border-slate-300 px-3 py-2 text-sm focus:border-green-600 focus:outline-none focus:ring-2 focus:ring-green-600/40" {...reg('notes')} />
          </Field>
        </div>
      </div>
    </Modal>
  );
}
