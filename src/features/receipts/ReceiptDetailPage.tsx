import { useEffect, useMemo, useState, type ReactNode } from 'react';
import { Link, useParams } from 'react-router';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { z } from 'zod';
import {
  ArrowLeft,
  Ban,
  Check,
  ClipboardCheck,
  Pencil,
  Plus,
  Send,
  Trash2,
  Warehouse as WarehouseIcon,
  Truck,
} from 'lucide-react';
import { PageHeader } from '@/components/layout/AppShell';
import { Card } from '@/components/ui/Card';
import { Badge } from '@/components/ui/Badge';
import { Button } from '@/components/ui/Button';
import { Alert } from '@/components/ui/Alert';
import { Field, Input, Select } from '@/components/ui/Input';
import { ConfirmDialog, Modal } from '@/components/ui/Modal';
import { useToast } from '@/components/ui/Toast';
import { ErrorState, LoadingState } from '@/components/feedback/States';
import { AttachmentsPanel } from '@/components/attachments/AttachmentsPanel';
import { StatusHistory } from '@/components/status/StatusHistory';
import { useAuth } from '@/features/auth/AuthProvider';
import { useLookups } from '@/features/master/lookups';
import { optQty, qty, reqSelect } from '@/features/master/schemas';
import { toUserMessage } from '@/lib/errors';
import { formatDate, formatDateTime, formatNumber, formatRupiah } from '@/lib/format';
import { cn } from '@/lib/cn';
import { isRoleCode } from '@/lib/roles';
import {
  cancelReceipt,
  deleteDetail,
  fetchReceipt,
  fetchReceiptApproverRoles,
  finalizeReceipt,
  recordInspection,
  saveDetail,
  startInspection,
  submitReceipt,
  vendorFollowup,
  type InspectionLine,
} from './api';
import { ReceiptHeaderModal } from './ReceiptHeaderModal';
import {
  ATTACHABLE,
  DOC_TYPES,
  inspectorLabel,
  RESULT_LABELS,
  requiredDocs,
  SOURCE_LABELS,
  STATUS_INFO,
  STEPS,
  stepIndex,
  type InspectionResult,
  type Receipt,
  type ReceiptDetail,
  type ReceiptStatus,
} from './model';

type Dialog =
  | { kind: 'submit' }
  | { kind: 'start' }
  | { kind: 'cancel' }
  | { kind: 'followup' };

export default function ReceiptDetailPage() {
  const { id = '' } = useParams();
  const { context, hasRole } = useAuth();
  const me = context?.profile.id;
  const lk = useLookups();
  const toast = useToast();
  const qc = useQueryClient();
  const query = useQuery({ queryKey: ['receipt', id], queryFn: () => fetchReceipt(id), enabled: Boolean(id) });
  const receipt = query.data?.receipt;
  const details = useMemo(() => query.data?.details ?? [], [query.data]);
  const approverRoles = useQuery({
    queryKey: ['receipt-approvers', receipt?.source_type],
    queryFn: () => fetchReceiptApproverRoles(receipt!.source_type),
    enabled: Boolean(receipt),
  });

  const [tab, setTab] = useState<'barang' | 'dokumen' | 'riwayat'>('barang');
  const [dialog, setDialog] = useState<Dialog | null>(null);
  const [editingHeader, setEditingHeader] = useState(false);
  const [line, setLine] = useState<{ detail: ReceiptDetail | null } | null>(null);

  const refresh = () => {
    void qc.invalidateQueries({ queryKey: ['receipt', id] });
    void qc.invalidateQueries({ queryKey: ['receipts'] });
    void qc.invalidateQueries({ queryKey: ['history', 'receipts', id] });
    void qc.invalidateQueries({ queryKey: ['stock'] });
  };

  const action = useMutation({
    mutationFn: async ({ d, text }: { d: Dialog; text?: string }) => {
      switch (d.kind) {
        case 'submit': return submitReceipt(id);
        case 'start': return startInspection(id);
        case 'cancel': return cancelReceipt(id, text ?? '');
        case 'followup': return vendorFollowup(id, text ?? '');
      }
    },
    onSuccess: () => {
      toast.success('Berhasil diproses.');
      setDialog(null);
      refresh();
    },
    onError: (err) => toast.error(toUserMessage(err)),
  });

  if (query.isLoading) return <LoadingState />;
  if (query.isError || !receipt) return <ErrorState message={toUserMessage(query.error)} onRetry={() => void query.refetch()} />;

  const s = receipt.status;
  const isCreator = receipt.created_by === me;
  const isInspector = receipt.inspector_id === me;
  const canEditDraft = s === 'draft' && isCreator;
  // Pemeriksa sekaligus pengesah: PPK (pembelian) / Pejabat Pengawas (sumber lain), bukan pencatat.
  const canInspect = !isCreator && hasRole(...(approverRoles.data ?? []).filter(isRoleCode));
  const canCancel = ['draft', 'menunggu_pemeriksaan', 'tidak_sesuai', 'menunggu_tindak_lanjut_penyedia'].includes(s) && isCreator;
  const canUpload = ATTACHABLE.includes(s) && hasRole('PPB', 'PPK', 'PWS');
  const currentStep = stepIndex(s);

  const dialogText: Record<Dialog['kind'], { title: string; message: string; confirm: string; reason?: string; tone?: 'danger' }> = {
    submit: { title: 'Ajukan untuk pemeriksaan?', message: 'Setelah diajukan, data dan rincian barang tidak dapat diubah lagi. Petugas Penerima Barang akan memeriksa.', confirm: 'Ajukan' },
    start: { title: 'Mulai pemeriksaan?', message: 'Anda akan tercatat sebagai pemeriksa sekaligus pengesah penerimaan ini.', confirm: 'Mulai' },
    cancel: { title: 'Batalkan penerimaan?', message: 'Penerimaan dibatalkan dan tidak dapat diproses lagi. Riwayat tetap tersimpan.', confirm: 'Batalkan penerimaan', reason: 'Alasan pembatalan', tone: 'danger' },
    followup: { title: 'Teruskan tindak lanjut?', message: 'Penyedia/pemberi diminta mengganti atau melengkapi barang. Setelah barang datang, pemeriksa memeriksa ulang.', confirm: 'Teruskan', reason: 'Tindak lanjut yang diminta' },
  };
  const dt = dialog ? dialogText[dialog.kind] : null;

  const actions = (
    <>
      {canEditDraft && <Button variant="secondary" icon={Pencil} onClick={() => setEditingHeader(true)}>Ubah data</Button>}
      {canEditDraft && <Button icon={Send} onClick={() => setDialog({ kind: 'submit' })} disabled={details.length === 0}>Ajukan pemeriksaan</Button>}
      {['menunggu_pemeriksaan', 'menunggu_tindak_lanjut_penyedia'].includes(s) && canInspect && (
        <Button icon={ClipboardCheck} onClick={() => setDialog({ kind: 'start' })}>Mulai pemeriksaan</Button>
      )}
      {s === 'tidak_sesuai' && hasRole('PPK', 'PWS', 'PPB') && <Button icon={Truck} onClick={() => setDialog({ kind: 'followup' })}>Teruskan tindak lanjut</Button>}
      {canCancel && <Button variant="ghost" icon={Ban} onClick={() => setDialog({ kind: 'cancel' })}>Batalkan</Button>}
    </>
  );

  const fact = (label: string, value: ReactNode) => (
    <div>
      <dt className="text-xs text-slate-500">{label}</dt>
      <dd className="text-sm text-slate-800">{value || '—'}</dd>
    </div>
  );

  return (
    <>
      <Link to="/penerimaan" className="mb-2 inline-flex items-center gap-1 text-sm text-slate-500 hover:text-slate-800">
        <ArrowLeft className="h-4 w-4" /> Kembali ke daftar
      </Link>
      <PageHeader title={receipt.receipt_no} description={`${SOURCE_LABELS[receipt.source_type]} · ${formatDate(receipt.receipt_date)}`} actions={actions} />

      <Card className="mb-4">
        <div className="mb-4 flex flex-wrap items-center gap-2">
          <Badge tone={STATUS_INFO[s].tone}>{STATUS_INFO[s].label}</Badge>
          {s === 'dibatalkan' && receipt.cancel_reason && <span className="text-sm text-slate-600">Alasan: {receipt.cancel_reason}</span>}
        </div>
        {s !== 'dibatalkan' && (
          <ol className="mb-4 grid grid-cols-2 gap-2 sm:grid-cols-4">
            {STEPS.map((st, i) => (
              <li key={st.key} className="flex flex-col items-center text-center">
                <span
                  className={cn(
                    'mb-1 flex h-7 w-7 items-center justify-center rounded-full text-xs font-semibold',
                    i < currentStep || s === 'selesai' ? 'bg-green-700 text-white' : i === currentStep ? 'bg-amber-400 text-white' : 'bg-slate-200 text-slate-500',
                  )}
                >
                  {i < currentStep || s === 'selesai' ? '✓' : i + 1}
                </span>
                <span className={cn('text-xs', i === currentStep ? 'font-semibold text-slate-800' : 'text-slate-500')}>{st.label}</span>
              </li>
            ))}
          </ol>
        )}
        <dl className="grid grid-cols-2 gap-x-4 gap-y-3 md:grid-cols-4">
          {fact('Gudang', lk.warehouseMap.get(receipt.warehouse_id)?.name)}
          {receipt.source_type === 'pembelian' ? fact('Penyedia', lk.supplierMap.get(receipt.supplier_id ?? '')?.name) : fact('Asal perolehan', receipt.source_description)}
          {receipt.source_type === 'pembelian' && fact('Kontrak / pesanan', [receipt.contract_no, receipt.order_no].filter(Boolean).join(' · '))}
          {receipt.source_type === 'pembelian' && fact('Surat jalan / faktur', [receipt.delivery_note_no, receipt.invoice_no].filter(Boolean).join(' · '))}
          {fact('Nilai', <span className="font-semibold tabular-nums">{formatRupiah(receipt.total_value)}</span>)}
          {fact('Dicatat oleh', lk.person(receipt.created_by))}
          {fact(`Pemeriksa & pengesah (${inspectorLabel(receipt.source_type)})`, receipt.inspector_id ? `${lk.person(receipt.inspector_id)}${receipt.approved_at ? ` · disahkan ${formatDateTime(receipt.approved_at)}` : ''}` : null)}
          {fact('Disimpan', receipt.finalized_by ? `${lk.person(receipt.finalized_by)} · ${formatDateTime(receipt.finalized_at)}` : null)}
        </dl>
        {receipt.inspection_notes && <p className="mt-3 text-sm text-slate-600"><b>Catatan pemeriksaan:</b> {receipt.inspection_notes}</p>}
        {receipt.notes && <p className="mt-1 text-sm text-slate-600"><b>Catatan:</b> {receipt.notes}</p>}
        {['menunggu_pemeriksaan', 'menunggu_tindak_lanjut_penyedia'].includes(s) && !canInspect && (
          <Alert tone="info" className="mt-3">Menunggu pemeriksaan oleh {inspectorLabel(receipt.source_type)}. Pencatat penerimaan tidak boleh memeriksa sendiri.</Alert>
        )}
      </Card>

      <div className="mb-3 flex gap-1 border-b border-slate-200" role="tablist">
        {(['barang', 'dokumen', 'riwayat'] as const).map((t) => (
          <button
            key={t}
            role="tab"
            aria-selected={tab === t}
            onClick={() => setTab(t)}
            className={cn('-mb-px border-b-2 px-3 py-2 text-sm font-medium', tab === t ? 'border-green-700 text-green-800' : 'border-transparent text-slate-500 hover:text-slate-800')}
          >
            {t === 'barang' ? `Barang (${details.length})` : t === 'dokumen' ? 'Dokumen' : 'Riwayat'}
          </button>
        ))}
      </div>

      <Card>
        {tab === 'barang' &&
          (s === 'dalam_pemeriksaan' && isInspector ? (
            <InspectionForm receiptId={id} details={details} onDone={refresh} source={receipt.source_type} />
          ) : s === 'disetujui' && hasRole('PGB') ? (
            <FinalizeForm receiptId={id} warehouseId={receipt.warehouse_id} details={details} onDone={refresh} />
          ) : (
            <DetailTable
              details={details}
              editable={canEditDraft}
              status={s}
              onAdd={() => setLine({ detail: null })}
              onEdit={(d) => setLine({ detail: d })}
              onDeleted={refresh}
            />
          ))}
        {tab === 'dokumen' && (
          <AttachmentsPanel
            refTable="receipts"
            refId={id}
            canUpload={canUpload}
            docTypes={DOC_TYPES.filter((d) => (receipt.source_type === 'saldo_awal' ? true : d.value !== 'ba_saldo_awal'))}
            required={requiredDocs(receipt.source_type)}
            personName={lk.person}
          />
        )}
        {tab === 'riwayat' && (
          <StatusHistory refTable="receipts" refId={id} statusLabel={(x) => STATUS_INFO[x as ReceiptStatus]?.label ?? x} personName={lk.person} />
        )}
      </Card>

      <ReceiptHeaderModal open={editingHeader} receipt={receipt} onClose={() => setEditingHeader(false)} />
      <LineModal target={line} receiptId={id} warehouseId={receipt.warehouse_id} nextLine={details.length + 1} onClose={() => setLine(null)} onSaved={refresh} />
      {dt && (
        <ConfirmDialog
          open
          title={dt.title}
          message={dt.message}
          confirmLabel={dt.confirm}
          tone={dt.tone ?? 'primary'}
          reasonLabel={dt.reason}
          loading={action.isPending}
          onCancel={() => setDialog(null)}
          onConfirm={(text) => dialog && action.mutate({ d: dialog, text })}
        />
      )}
    </>
  );
}

// ---------------------------------------------------------------------------
function DetailTable({
  details,
  editable,
  status,
  onAdd,
  onEdit,
  onDeleted,
}: {
  details: ReceiptDetail[];
  editable: boolean;
  status: ReceiptStatus;
  onAdd: () => void;
  onEdit: (d: ReceiptDetail) => void;
  onDeleted: () => void;
}) {
  const lk = useLookups();
  const toast = useToast();
  const inspected = details.some((d) => d.inspection_result);
  const remove = useMutation({
    mutationFn: deleteDetail,
    onSuccess: () => {
      toast.success('Barang dihapus dari draf.');
      onDeleted();
    },
    onError: (err) => toast.error(toUserMessage(err)),
  });
  const total = details.reduce((sum, d) => sum + (inspected ? d.qty_accepted : d.qty_received) * Number(d.unit_cost), 0);

  return (
    <div className="space-y-3">
      {editable && (
        <div className="flex justify-between">
          <p className="text-sm text-slate-600">Tambahkan semua barang yang datang sesuai surat jalan.</p>
          <Button icon={Plus} onClick={onAdd}>Tambah barang</Button>
        </div>
      )}
      {details.length === 0 ? (
        <p className="py-8 text-center text-sm text-slate-500">Belum ada barang.</p>
      ) : (
        <div className="overflow-x-auto rounded-lg border border-slate-200">
          <table className="min-w-full divide-y divide-slate-200 text-sm">
            <thead className="bg-slate-50 text-left text-slate-600">
              <tr>
                <th className="px-3 py-2">Barang</th>
                <th className="px-3 py-2 text-right">Dipesan</th>
                <th className="px-3 py-2 text-right">Datang</th>
                {inspected && <th className="px-3 py-2 text-right">Diterima</th>}
                {inspected && <th className="px-3 py-2 text-right">Ditolak</th>}
                <th className="px-3 py-2 text-right">Harga satuan</th>
                <th className="px-3 py-2 text-right">Nilai</th>
                <th className="px-3 py-2">Lokasi</th>
                {inspected && <th className="px-3 py-2">Hasil periksa</th>}
                {editable && <th className="px-3 py-2" />}
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100">
              {details.map((d) => {
                const item = lk.itemMap.get(d.item_id);
                return (
                  <tr key={d.id}>
                    <td className="px-3 py-2">
                      <p className="font-medium">{item?.name ?? '—'}</p>
                      <p className="font-mono text-xs text-slate-500">{item?.code}{d.expiry_date ? ` · kedaluwarsa ${formatDate(d.expiry_date)}` : ''}</p>
                    </td>
                    <td className="px-3 py-2 text-right tabular-nums">{d.qty_ordered != null ? formatNumber(d.qty_ordered) : '—'}</td>
                    <td className="px-3 py-2 text-right tabular-nums">{formatNumber(d.qty_received)} {lk.unitName(d.item_id)}</td>
                    {inspected && <td className="px-3 py-2 text-right tabular-nums text-green-700">{formatNumber(d.qty_accepted)}</td>}
                    {inspected && <td className="px-3 py-2 text-right tabular-nums text-red-600">{formatNumber(d.qty_rejected)}</td>}
                    <td className="px-3 py-2 text-right tabular-nums">{formatRupiah(d.unit_cost)}</td>
                    <td className="px-3 py-2 text-right tabular-nums">{formatRupiah((inspected ? d.qty_accepted : d.qty_received) * Number(d.unit_cost))}</td>
                    <td className="px-3 py-2 font-mono text-xs">{d.location_id ? lk.locationMap.get(d.location_id)?.code : '—'}</td>
                    {inspected && (
                      <td className="px-3 py-2 text-xs">
                        {d.inspection_result ? RESULT_LABELS[d.inspection_result] : '—'}
                        {d.inspection_notes && <span className="block text-slate-500">{d.inspection_notes}</span>}
                      </td>
                    )}
                    {editable && (
                      <td className="whitespace-nowrap px-3 py-2 text-right">
                        <Button size="sm" variant="ghost" icon={Pencil} onClick={() => onEdit(d)} aria-label="Ubah" />
                        <Button size="sm" variant="ghost" icon={Trash2} onClick={() => remove.mutate(d.id)} aria-label="Hapus" />
                      </td>
                    )}
                  </tr>
                );
              })}
            </tbody>
            <tfoot className="bg-slate-50 font-semibold">
              <tr>
                <td className="px-3 py-2" colSpan={inspected ? 6 : 4}>Total {inspected ? '(barang diterima baik)' : ''}</td>
                <td className="px-3 py-2 text-right tabular-nums">{formatRupiah(total)}</td>
                <td colSpan={inspected ? 2 : editable ? 2 : 1} />
              </tr>
            </tfoot>
          </table>
        </div>
      )}
      {status === 'menunggu_pemeriksaan' && <Alert tone="info">Menunggu Petugas Penerima Barang memulai pemeriksaan.</Alert>}
    </div>
  );
}

// ---------------------------------------------------------------------------
const lineSchema = z.object({
  item_id: reqSelect('barang'),
  qty_ordered: optQty('Jumlah dipesan'),
  qty_received: optQty('Jumlah datang').refine((v) => v !== null, 'Jumlah datang wajib diisi.'),
  unit_cost: qty('Harga satuan'),
  location_id: z.preprocess((v) => (v === '' ? null : v), z.string().nullable()),
});
type LineIn = z.input<typeof lineSchema>;
type LineOut = z.output<typeof lineSchema>;

function LineModal({
  target,
  receiptId,
  warehouseId,
  nextLine,
  onClose,
  onSaved,
}: {
  target: { detail: ReceiptDetail | null } | null;
  receiptId: string;
  warehouseId: string;
  nextLine: number;
  onClose: () => void;
  onSaved: () => void;
}) {
  const lk = useLookups();
  const toast = useToast();
  const form = useForm<LineIn, unknown, LineOut>({ resolver: zodResolver(lineSchema) });
  useEffect(() => {
    if (!target) return;
    const d = target.detail;
    form.reset({
      item_id: d?.item_id ?? '',
      qty_ordered: d?.qty_ordered != null ? String(d.qty_ordered) : '',
      qty_received: d ? String(d.qty_received) : '',
      unit_cost: d ? String(d.unit_cost) : '',
      location_id: d?.location_id ?? '',
    });
  }, [target, form]);

  const save = useMutation({
    mutationFn: (v: LineOut) =>
      saveDetail(receiptId, { item_id: v.item_id, qty_ordered: v.qty_ordered, qty_received: v.qty_received ?? 0, unit_cost: v.unit_cost, location_id: v.location_id }, target?.detail?.id, nextLine),
    onSuccess: () => {
      toast.success('Barang disimpan.');
      onSaved();
      onClose();
    },
    onError: (err) => toast.error(toUserMessage(err)),
  });

  const e = form.formState.errors;
  const activeItems = lk.items.filter((i) => i.is_active || i.id === target?.detail?.item_id);
  return (
    <Modal
      open={Boolean(target)}
      onClose={onClose}
      title={target?.detail ? 'Ubah barang' : 'Tambah barang'}
      footer={
        <>
          <Button variant="secondary" onClick={onClose}>Batal</Button>
          <Button onClick={form.handleSubmit((v) => save.mutate(v))} loading={save.isPending}>Simpan</Button>
        </>
      }
    >
      <Field label="Barang" required error={e.item_id?.message} hint="Hanya barang aktif. Barang baru diusulkan lewat Master Data." htmlFor="ln-item">
        <Select id="ln-item" {...form.register('item_id')}>
          <option value="">— Pilih barang —</option>
          {activeItems.map((i) => (
            <option key={i.id} value={i.id}>{i.code} — {i.name}</option>
          ))}
        </Select>
      </Field>
      <div className="grid grid-cols-2 gap-4">
        <Field label="Jumlah dipesan" error={e.qty_ordered?.message} htmlFor="ln-ord">
          <Input id="ln-ord" inputMode="decimal" {...form.register('qty_ordered')} />
        </Field>
        <Field label="Jumlah datang" required error={e.qty_received?.message} htmlFor="ln-rec">
          <Input id="ln-rec" inputMode="decimal" {...form.register('qty_received')} />
        </Field>
        <Field label="Harga satuan (Rp)" required error={e.unit_cost?.message} hint="Harga perolehan per satuan" htmlFor="ln-cost">
          <Input id="ln-cost" inputMode="decimal" {...form.register('unit_cost')} />
        </Field>
        <Field label="Rencana lokasi simpan" htmlFor="ln-loc" hint="Boleh diisi saat penyimpanan">
          <Select id="ln-loc" {...form.register('location_id')}>
            <option value="">— Nanti —</option>
            {lk.locations.filter((l) => l.is_active && l.warehouse_id === warehouseId).map((l) => (
              <option key={l.id} value={l.id}>{l.code}</option>
            ))}
          </Select>
        </Field>
      </div>
    </Modal>
  );
}

// ---------------------------------------------------------------------------
interface InspRow {
  qty_received: string;
  qty_accepted: string;
  qty_rejected: string;
  result: InspectionResult | '';
  notes: string;
  expiry_date: string;
}

function InspectionForm({ receiptId, details, onDone, source }: { receiptId: string; details: ReceiptDetail[]; onDone: () => void; source: Receipt['source_type'] }) {
  const lk = useLookups();
  const toast = useToast();
  const [rows, setRows] = useState<Record<string, InspRow>>({});
  const [notes, setNotes] = useState('');
  useEffect(() => {
    const init: Record<string, InspRow> = {};
    for (const d of details) {
      init[d.id] = {
        qty_received: String(d.qty_received),
        qty_accepted: String(d.inspection_result ? d.qty_accepted : d.qty_received),
        qty_rejected: String(d.inspection_result ? d.qty_rejected : 0),
        result: d.inspection_result ?? '',
        notes: d.inspection_notes ?? '',
        expiry_date: d.expiry_date ?? '',
      };
    }
    setRows(init);
  }, [details]);

  const set = (id: string, patch: Partial<InspRow>) => setRows((r) => ({ ...r, [id]: { ...r[id]!, ...patch } }));
  const num = (v: string) => Number(v.replace(',', '.'));

  const save = useMutation({
    mutationFn: (decision: 'lanjut' | 'tindak_lanjut') => {
      const lines: InspectionLine[] = details.map((d) => {
        const r = rows[d.id]!;
        return {
          detail_id: d.id,
          qty_received: num(r.qty_received),
          qty_accepted: num(r.qty_accepted),
          qty_rejected: num(r.qty_rejected),
          result: r.result,
          notes: r.notes || null,
          expiry_date: r.expiry_date || null,
        };
      });
      return recordInspection(receiptId, lines, notes || null, decision);
    },
    onSuccess: (_d, decision) => {
      toast.success(decision === 'lanjut' ? 'Penerimaan diperiksa dan disahkan. Pengurus Barang dapat menyimpannya ke gudang.' : 'Ketidaksesuaian dicatat.');
      onDone();
    },
    onError: (err) => toast.error(toUserMessage(err)),
  });

  return (
    <div className="space-y-4">
      <Alert tone="info">
        Isi jumlah yang <b>diterima baik</b> dan yang <b>ditolak</b> untuk setiap barang (jumlahnya harus sama dengan jumlah
        yang datang). Sebelum mengesahkan, unggah{' '}
        <b>{source === 'saldo_awal' ? 'Berita Acara Saldo Awal' : source === 'pembelian' ? 'Berita Acara Pemeriksaan dan Surat Jalan/Faktur' : 'Berita Acara Pemeriksaan'}</b>{' '}
        di tab Dokumen. Pemeriksaan Anda sekaligus menjadi pengesahan.
      </Alert>
      <div className="space-y-3">
        {details.map((d) => {
          const r = rows[d.id];
          const item = lk.itemMap.get(d.item_id);
          if (!r) return null;
          const mismatch = num(r.qty_accepted) + num(r.qty_rejected) !== num(r.qty_received);
          return (
            <div key={d.id} className="rounded-lg border border-slate-200 p-3">
              <p className="mb-2 font-medium">
                {item?.code} — {item?.name}{' '}
                <span className="text-xs font-normal text-slate-500">
                  (dipesan {d.qty_ordered != null ? formatNumber(d.qty_ordered) : '—'} {lk.unitName(d.item_id)})
                </span>
              </p>
              <div className="grid grid-cols-2 gap-3 md:grid-cols-6">
                <Field label="Datang"><Input inputMode="decimal" value={r.qty_received} onChange={(e) => set(d.id, { qty_received: e.target.value })} /></Field>
                <Field label="Diterima baik"><Input inputMode="decimal" value={r.qty_accepted} onChange={(e) => set(d.id, { qty_accepted: e.target.value })} invalid={mismatch} /></Field>
                <Field label="Ditolak"><Input inputMode="decimal" value={r.qty_rejected} onChange={(e) => set(d.id, { qty_rejected: e.target.value })} invalid={mismatch} /></Field>
                <Field label="Hasil">
                  <Select value={r.result} onChange={(e) => set(d.id, { result: e.target.value as InspectionResult })}>
                    <option value="">— Pilih —</option>
                    {(Object.keys(RESULT_LABELS) as InspectionResult[]).map((k) => (
                      <option key={k} value={k}>{RESULT_LABELS[k]}</option>
                    ))}
                  </Select>
                </Field>
                {item?.has_expiry ? (
                  <Field label="Kedaluwarsa"><Input type="date" value={r.expiry_date} onChange={(e) => set(d.id, { expiry_date: e.target.value })} /></Field>
                ) : (
                  <div />
                )}
                <Field label="Catatan"><Input value={r.notes} onChange={(e) => set(d.id, { notes: e.target.value })} /></Field>
              </div>
              {mismatch && <p className="mt-1 text-xs text-red-600">Diterima + ditolak harus sama dengan jumlah datang.</p>}
            </div>
          );
        })}
      </div>
      <Field label="Catatan pemeriksaan" htmlFor="insp-notes">
        <textarea id="insp-notes" rows={2} value={notes} onChange={(e) => setNotes(e.target.value)} className="block w-full rounded-lg border border-slate-300 px-3 py-2 text-sm focus:border-green-600 focus:outline-none focus:ring-2 focus:ring-green-600/40" />
      </Field>
      <div className="flex flex-wrap justify-end gap-2">
        <Button variant="danger" onClick={() => save.mutate('tindak_lanjut')} loading={save.isPending}>Catat ketidaksesuaian</Button>
        <Button icon={Check} onClick={() => save.mutate('lanjut')} loading={save.isPending}>Selesai periksa & sahkan</Button>
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------
function FinalizeForm({ receiptId, warehouseId, details, onDone }: { receiptId: string; warehouseId: string; details: ReceiptDetail[]; onDone: () => void }) {
  const lk = useLookups();
  const toast = useToast();
  const lines = details.filter((d) => d.qty_accepted > 0);
  const [locs, setLocs] = useState<Record<string, string>>({});
  const [confirm, setConfirm] = useState(false);
  useEffect(() => {
    setLocs(Object.fromEntries(lines.map((d) => [d.id, d.location_id ?? ''])));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [details]);
  const options = lk.locations.filter((l) => l.is_active && l.warehouse_id === warehouseId);
  const missing = lines.some((d) => !locs[d.id]);

  const run = useMutation({
    mutationFn: () => finalizeReceipt(receiptId, locs),
    onSuccess: () => {
      toast.success('Barang disimpan. Saldo persediaan bertambah dan penerimaan selesai.');
      setConfirm(false);
      onDone();
    },
    onError: (err) => toast.error(toUserMessage(err)),
  });

  return (
    <div className="space-y-4">
      <Alert tone="info">Pilih lokasi penyimpanan untuk setiap barang, lalu klik <b>Simpan ke gudang</b>. Saldo bertambah sejumlah barang yang diterima baik.</Alert>
      {options.length === 0 && <Alert tone="warning">Gudang ini belum memiliki lokasi penyimpanan. Tambahkan di Master Data → Lokasi Penyimpanan.</Alert>}
      <div className="overflow-x-auto rounded-lg border border-slate-200">
        <table className="min-w-full divide-y divide-slate-200 text-sm">
          <thead className="bg-slate-50 text-left text-slate-600">
            <tr>
              <th className="px-3 py-2">Barang</th>
              <th className="px-3 py-2 text-right">Diterima baik</th>
              <th className="px-3 py-2">Lokasi simpan</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-slate-100">
            {lines.map((d) => (
              <tr key={d.id}>
                <td className="px-3 py-2">{lk.itemMap.get(d.item_id)?.code} — {lk.itemMap.get(d.item_id)?.name}</td>
                <td className="px-3 py-2 text-right tabular-nums">{formatNumber(d.qty_accepted)} {lk.unitName(d.item_id)}</td>
                <td className="px-3 py-2">
                  <Select value={locs[d.id] ?? ''} onChange={(e) => setLocs((x) => ({ ...x, [d.id]: e.target.value }))} invalid={!locs[d.id]}>
                    <option value="">— Pilih lokasi —</option>
                    {options.map((l) => (
                      <option key={l.id} value={l.id}>{l.code} ({l.room})</option>
                    ))}
                  </Select>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <div className="flex justify-end">
        <Button icon={WarehouseIcon} disabled={missing} onClick={() => setConfirm(true)}>Simpan ke gudang</Button>
      </div>
      <ConfirmDialog
        open={confirm}
        title="Simpan barang ke gudang?"
        message="Saldo persediaan akan bertambah dan tercatat di kartu stok. Tindakan ini tidak dapat dibatalkan; kesalahan diperbaiki melalui transaksi koreksi."
        confirmLabel="Simpan ke gudang"
        loading={run.isPending}
        onCancel={() => setConfirm(false)}
        onConfirm={() => run.mutate()}
      />
    </div>
  );
}
