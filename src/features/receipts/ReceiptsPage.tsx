import { useMemo, useState } from 'react';
import { Link } from 'react-router';
import { useQuery } from '@tanstack/react-query';
import { Plus } from 'lucide-react';
import { PageHeader } from '@/components/layout/AppShell';
import { Card } from '@/components/ui/Card';
import { Badge } from '@/components/ui/Badge';
import { Button } from '@/components/ui/Button';
import { Select } from '@/components/ui/Input';
import { DataTable, type Column } from '@/components/data-table/DataTable';
import { useAuth } from '@/features/auth/AuthProvider';
import { useLookups } from '@/features/master/lookups';
import { toUserMessage } from '@/lib/errors';
import { formatDate, formatRupiah } from '@/lib/format';
import { fetchReceipts } from './api';
import { ReceiptHeaderModal } from './ReceiptHeaderModal';
import { SOURCE_LABELS, STATUS_INFO, type Receipt, type ReceiptStatus } from './model';

const FILTERS: { value: string; label: string; statuses?: ReceiptStatus[] }[] = [
  { value: 'proses', label: 'Sedang diproses', statuses: ['draft', 'menunggu_pemeriksaan', 'dalam_pemeriksaan', 'tidak_sesuai', 'menunggu_tindak_lanjut_penyedia', 'menunggu_pengesahan', 'disetujui', 'diterima_disimpan'] },
  { value: 'selesai', label: 'Selesai', statuses: ['selesai'] },
  { value: 'batal', label: 'Dibatalkan', statuses: ['dibatalkan'] },
  { value: 'semua', label: 'Semua' },
];

export default function ReceiptsPage() {
  const { hasRole } = useAuth();
  const lk = useLookups();
  const query = useQuery({ queryKey: ['receipts'], queryFn: fetchReceipts });
  const [filter, setFilter] = useState('proses');
  const [creating, setCreating] = useState(false);

  const rows = useMemo(() => {
    const f = FILTERS.find((x) => x.value === filter);
    return (query.data ?? []).filter((r) => !f?.statuses || f.statuses.includes(r.status));
  }, [query.data, filter]);

  const columns: Column<Receipt>[] = [
    {
      key: 'no',
      header: 'Nomor / Tanggal',
      sortValue: (r) => r.receipt_date + r.receipt_no,
      searchValue: (r) => r.receipt_no,
      render: (r) => (
        <Link to={`/penerimaan/${r.id}`} className="block hover:underline">
          <span className="font-mono text-xs font-medium text-green-800">{r.receipt_no}</span>
          <span className="block text-xs text-slate-500">{formatDate(r.receipt_date)}</span>
        </Link>
      ),
    },
    {
      key: 'source',
      header: 'Sumber',
      searchValue: (r) => `${SOURCE_LABELS[r.source_type]} ${r.supplier_id ? (lk.supplierMap.get(r.supplier_id)?.name ?? '') : ''} ${r.contract_no ?? ''} ${r.source_description ?? ''}`,
      render: (r) => (
        <div>
          <p>{SOURCE_LABELS[r.source_type]}</p>
          <p className="text-xs text-slate-500">
            {r.supplier_id ? lk.supplierMap.get(r.supplier_id)?.name : r.source_description}
            {r.contract_no ? ` · ${r.contract_no}` : ''}
          </p>
        </div>
      ),
    },
    { key: 'wh', header: 'Gudang', render: (r) => lk.warehouseMap.get(r.warehouse_id)?.name ?? '-' },
    {
      key: 'value',
      header: 'Nilai',
      className: 'text-right tabular-nums whitespace-nowrap',
      sortValue: (r) => Number(r.total_value),
      render: (r) => formatRupiah(r.total_value),
    },
    {
      key: 'status',
      header: 'Status',
      sortValue: (r) => r.status,
      searchValue: (r) => STATUS_INFO[r.status].label,
      render: (r) => <Badge tone={STATUS_INFO[r.status].tone}>{STATUS_INFO[r.status].label}</Badge>,
    },
  ];

  return (
    <>
      <PageHeader
        title="Penerimaan Barang"
        description="Dicatat Petugas Penerima Barang, diperiksa & disahkan PPK (pembelian) atau Pejabat Pengawas (sumber lain), lalu disimpan ke gudang oleh Pengurus Barang."
        actions={hasRole('PPB') && <Button icon={Plus} onClick={() => setCreating(true)}>Buat Penerimaan</Button>}
      />
      <Card>
        <DataTable
          rows={rows}
          columns={columns}
          rowKey={(r) => r.id}
          loading={query.isLoading}
          error={query.isError ? toUserMessage(query.error) : null}
          onRetry={() => void query.refetch()}
          searchPlaceholder="Cari nomor, penyedia, kontrak…"
          emptyTitle="Belum ada penerimaan"
          toolbar={
            <Select value={filter} onChange={(e) => setFilter(e.target.value)} className="w-48" aria-label="Filter status">
              {FILTERS.map((f) => (
                <option key={f.value} value={f.value}>{f.label}</option>
              ))}
            </Select>
          }
        />
      </Card>
      <ReceiptHeaderModal open={creating} receipt={null} onClose={() => setCreating(false)} />
    </>
  );
}
