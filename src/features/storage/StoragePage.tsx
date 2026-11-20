import { useMemo, useState } from 'react';
import { Link, useSearchParams } from 'react-router';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { ArrowRightLeft, BookOpenText, ShieldCheck } from 'lucide-react';
import { PageHeader } from '@/components/layout/AppShell';
import { Card, StatCard } from '@/components/ui/Card';
import { Badge, type BadgeTone } from '@/components/ui/Badge';
import { Button } from '@/components/ui/Button';
import { Field, Input, Select } from '@/components/ui/Input';
import { Alert } from '@/components/ui/Alert';
import { Modal } from '@/components/ui/Modal';
import { useToast } from '@/components/ui/Toast';
import { DataTable, type Column } from '@/components/data-table/DataTable';
import { useAuth } from '@/features/auth/AuthProvider';
import { useLookups } from '@/features/master/lookups';
import { supabase } from '@/lib/supabase';
import { toUserMessage, UserFacingError } from '@/lib/errors';
import { formatDate, formatNumber, formatRupiah } from '@/lib/format';
import { cn } from '@/lib/cn';
import { Boxes, Coins, PackageMinus, PackagePlus } from 'lucide-react';

interface SummaryRow {
  item_id: string;
  code: string;
  name: string;
  min_stock: number;
  safety_stock: number;
  max_stock: number | null;
  has_expiry: boolean;
  is_active: boolean;
  qty_good: number;
  qty_other: number;
  qty_reserved: number;
  total_value: number;
  last_movement_at: string | null;
}

interface BalanceRow {
  id: string;
  item_id: string;
  location_id: string;
  condition: string;
  quantity: number;
  reserved_qty: number;
  total_value: number;
}

interface BatchRow {
  id: string;
  item_id: string;
  location_id: string;
  expiry_date: string | null;
  acquired_at: string;
  qty_remaining: number;
  unit_cost: number;
}

interface TransferRow {
  id: string;
  transfer_no: string;
  transfer_date: string;
  reason: string;
  created_by: string | null;
  stock_transfer_details: { item_id: string; from_location_id: string; to_location_id: string; quantity: number }[];
}

type Tab = 'barang' | 'lokasi' | 'kedaluwarsa' | 'perpindahan';

const todayJakarta = () => new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Jakarta' }).format(new Date());

function levelInfo(r: SummaryRow): { label: string; tone: BadgeTone } | null {
  if (r.qty_good <= 0) return { label: 'Kosong', tone: 'danger' };
  if (r.qty_good <= Number(r.min_stock)) return { label: 'Di bawah minimum', tone: 'attention' };
  if (r.max_stock != null && r.qty_good > Number(r.max_stock)) return { label: 'Melebihi maksimum', tone: 'waiting' };
  return null;
}

export default function StoragePage() {
  const { hasRole } = useAuth();
  const lk = useLookups();
  const toast = useToast();
  const [params, setParams] = useSearchParams();
  const tab = (params.get('tab') as Tab) || 'barang';
  const [levelFilter, setLevelFilter] = useState('semua');
  const [transferOpen, setTransferOpen] = useState(false);

  const summary = useQuery({
    queryKey: ['stock', 'summary'],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('v_stock_summary')
        .select('item_id, code, name, min_stock, safety_stock, max_stock, has_expiry, is_active, qty_good, qty_other, qty_reserved, total_value, last_movement_at')
        .order('code');
      if (error) throw error;
      return (data ?? []) as SummaryRow[];
    },
  });
  const balances = useQuery({
    queryKey: ['stock', 'balances'],
    queryFn: async () => {
      const { data, error } = await supabase.from('stock_balances').select('id, item_id, location_id, condition, quantity, reserved_qty, total_value').gt('quantity', 0);
      if (error) throw error;
      return (data ?? []) as BalanceRow[];
    },
  });
  const expiries = useQuery({
    queryKey: ['stock', 'expiry'],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('stock_batches')
        .select('id, item_id, location_id, expiry_date, acquired_at, qty_remaining, unit_cost')
        .gt('qty_remaining', 0)
        .not('expiry_date', 'is', null)
        .order('expiry_date');
      if (error) throw error;
      return (data ?? []) as BatchRow[];
    },
    enabled: tab === 'kedaluwarsa',
  });
  const transfers = useQuery({
    queryKey: ['stock', 'transfers'],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('stock_transfers')
        .select('id, transfer_no, transfer_date, reason, created_by, stock_transfer_details(item_id, from_location_id, to_location_id, quantity)')
        .order('transfer_date', { ascending: false })
        .limit(500);
      if (error) throw error;
      return (data ?? []) as unknown as TransferRow[];
    },
    enabled: tab === 'perpindahan',
  });

  const verify = useMutation({
    mutationFn: async () => {
      const { data, error } = await supabase.rpc('rpc_verify_stock');
      if (error) throw error;
      return (data ?? []) as { item_code: string }[];
    },
    onSuccess: (rows) =>
      rows.length === 0
        ? toast.success('Konsisten: buku mutasi, batch, dan saldo cocok untuk semua barang.')
        : toast.error(`Ditemukan ${rows.length} barang tidak konsisten: ${rows.map((r) => r.item_code).join(', ')}. Laporkan ke Super Admin.`),
    onError: (err) => toast.error(toUserMessage(err)),
  });

  const rows = summary.data ?? [];
  const stockRows = rows.filter((r) => r.qty_good + r.qty_other > 0 || r.is_active);
  const filtered = useMemo(
    () =>
      stockRows.filter((r) => {
        const lvl = levelInfo(r)?.label;
        if (levelFilter === 'minimum') return lvl === 'Di bawah minimum' || lvl === 'Kosong';
        if (levelFilter === 'maksimum') return lvl === 'Melebihi maksimum';
        if (levelFilter === 'ada') return r.qty_good > 0;
        return true;
      }),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [summary.data, levelFilter],
  );
  const totalValue = rows.reduce((s, r) => s + Number(r.total_value), 0);
  const belowMin = stockRows.filter((r) => r.is_active && r.qty_good <= Number(r.min_stock)).length;
  const aboveMax = stockRows.filter((r) => r.max_stock != null && r.qty_good > Number(r.max_stock)).length;

  const summaryCols: Column<SummaryRow>[] = [
    { key: 'code', header: 'Kode', sortValue: (r) => r.code, searchValue: (r) => r.code, render: (r) => <span className="font-mono text-xs">{r.code}</span> },
    { key: 'name', header: 'Barang', sortValue: (r) => r.name, searchValue: (r) => r.name, render: (r) => r.name },
    {
      key: 'qty',
      header: 'Saldo layak pakai',
      className: 'text-right tabular-nums whitespace-nowrap',
      sortValue: (r) => Number(r.qty_good),
      render: (r) => `${formatNumber(r.qty_good)} ${lk.unitName(r.item_id)}`,
    },
    { key: 'other', header: 'Kondisi lain', className: 'text-right tabular-nums', render: (r) => (Number(r.qty_other) ? formatNumber(r.qty_other) : '–') },
    {
      key: 'levels',
      header: 'Min / Maks',
      className: 'text-right tabular-nums whitespace-nowrap',
      render: (r) => `${formatNumber(r.min_stock)} / ${r.max_stock != null ? formatNumber(r.max_stock) : '–'}`,
    },
    { key: 'value', header: 'Nilai', className: 'text-right tabular-nums whitespace-nowrap', sortValue: (r) => Number(r.total_value), render: (r) => formatRupiah(r.total_value) },
    {
      key: 'flag',
      header: 'Pantauan',
      render: (r) => {
        const l = levelInfo(r);
        return l ? <Badge tone={l.tone}>{l.label}</Badge> : <Badge tone="success">Normal</Badge>;
      },
    },
    {
      key: 'card',
      header: '',
      render: (r) => (
        <Link to={`/kartu-stok?item=${r.item_id}`} className="inline-flex items-center gap-1 text-xs text-green-700 hover:underline">
          <BookOpenText className="h-3.5 w-3.5" /> Kartu stok
        </Link>
      ),
    },
  ];

  const locationCols: Column<BalanceRow>[] = [
    {
      key: 'loc',
      header: 'Lokasi',
      sortValue: (r) => lk.locationMap.get(r.location_id)?.code ?? '',
      searchValue: (r) => lk.locationMap.get(r.location_id)?.code ?? '',
      render: (r) => {
        const l = lk.locationMap.get(r.location_id);
        return (
          <div>
            <span className="font-mono text-xs">{l?.code}</span>
            <span className="block text-xs text-slate-500">{lk.warehouseMap.get(l?.warehouse_id ?? '')?.name} · {l?.room}</span>
          </div>
        );
      },
    },
    {
      key: 'item',
      header: 'Barang',
      sortValue: (r) => lk.itemMap.get(r.item_id)?.code ?? '',
      searchValue: (r) => `${lk.itemMap.get(r.item_id)?.code ?? ''} ${lk.itemMap.get(r.item_id)?.name ?? ''}`,
      render: (r) => `${lk.itemMap.get(r.item_id)?.code ?? ''} — ${lk.itemMap.get(r.item_id)?.name ?? ''}`,
    },
    { key: 'cond', header: 'Kondisi', render: (r) => <Badge tone={r.condition === 'layak_pakai' ? 'success' : 'attention'}>{r.condition.replace('_', ' ')}</Badge> },
    { key: 'qty', header: 'Jumlah', className: 'text-right tabular-nums', sortValue: (r) => Number(r.quantity), render: (r) => `${formatNumber(r.quantity)} ${lk.unitName(r.item_id)}` },
    { key: 'value', header: 'Nilai', className: 'text-right tabular-nums', sortValue: (r) => Number(r.total_value), render: (r) => formatRupiah(r.total_value) },
  ];

  const today = todayJakarta();
  const expiryCols: Column<BatchRow>[] = [
    {
      key: 'exp',
      header: 'Kedaluwarsa',
      sortValue: (r) => r.expiry_date ?? '',
      render: (r) => {
        const days = Math.round((Date.parse(r.expiry_date!) - Date.parse(today)) / 86400000);
        return (
          <span className="whitespace-nowrap">
            {formatDate(r.expiry_date)}{' '}
            <Badge tone={days < 0 ? 'danger' : days <= 90 ? 'attention' : 'neutral'}>{days < 0 ? 'Sudah lewat' : `${days} hari lagi`}</Badge>
          </span>
        );
      },
    },
    { key: 'item', header: 'Barang', searchValue: (r) => lk.itemMap.get(r.item_id)?.name ?? '', render: (r) => `${lk.itemMap.get(r.item_id)?.code} — ${lk.itemMap.get(r.item_id)?.name}` },
    { key: 'loc', header: 'Lokasi', render: (r) => <span className="font-mono text-xs">{lk.locationMap.get(r.location_id)?.code}</span> },
    { key: 'qty', header: 'Sisa', className: 'text-right tabular-nums', render: (r) => `${formatNumber(r.qty_remaining)} ${lk.unitName(r.item_id)}` },
  ];

  const transferCols: Column<TransferRow>[] = [
    {
      key: 'no',
      header: 'Nomor / Tanggal',
      sortValue: (r) => r.transfer_date + r.transfer_no,
      searchValue: (r) => r.transfer_no,
      render: (r) => (
        <div>
          <span className="font-mono text-xs">{r.transfer_no}</span>
          <span className="block text-xs text-slate-500">{formatDate(r.transfer_date)} · {lk.person(r.created_by)}</span>
        </div>
      ),
    },
    {
      key: 'lines',
      header: 'Barang & lokasi',
      searchValue: (r) => r.stock_transfer_details.map((d) => lk.itemMap.get(d.item_id)?.name ?? '').join(' '),
      render: (r) => (
        <ul className="text-xs">
          {r.stock_transfer_details.map((d, i) => (
            <li key={i}>
              {formatNumber(d.quantity)} {lk.unitName(d.item_id)} {lk.itemMap.get(d.item_id)?.name}: {lk.locationMap.get(d.from_location_id)?.code} → {lk.locationMap.get(d.to_location_id)?.code}
            </li>
          ))}
        </ul>
      ),
    },
    { key: 'reason', header: 'Alasan', searchValue: (r) => r.reason, render: (r) => <span className="text-xs">{r.reason}</span> },
  ];

  const TABS: { key: Tab; label: string }[] = [
    { key: 'barang', label: 'Saldo per barang' },
    { key: 'lokasi', label: 'Saldo per lokasi' },
    { key: 'kedaluwarsa', label: 'Kedaluwarsa' },
    { key: 'perpindahan', label: 'Perpindahan lokasi' },
  ];

  return (
    <>
      <PageHeader
        title="Penyimpanan"
        description="Saldo persediaan per barang dan lokasi, pemantauan stok, dan perpindahan lokasi."
        actions={
          <>
            {hasRole('PGB', 'PWS', 'AUD') && (
              <Button variant="secondary" icon={ShieldCheck} loading={verify.isPending} onClick={() => verify.mutate()}>Periksa konsistensi</Button>
            )}
            {hasRole('PGB') && <Button icon={ArrowRightLeft} onClick={() => setTransferOpen(true)}>Pindah lokasi</Button>}
          </>
        }
      />

      <div className="mb-4 grid grid-cols-2 gap-3 lg:grid-cols-4">
        <StatCard label="Jenis barang tersimpan" value={formatNumber(rows.filter((r) => r.qty_good + r.qty_other > 0).length)} icon={Boxes} />
        <StatCard label="Nilai persediaan" value={<span className="text-lg">{formatRupiah(totalValue)}</span>} icon={Coins} tone="sky" />
        <StatCard label="Di bawah minimum" value={formatNumber(belowMin)} icon={PackageMinus} tone={belowMin ? 'amber' : 'slate'} />
        <StatCard label="Melebihi maksimum" value={formatNumber(aboveMax)} icon={PackagePlus} tone={aboveMax ? 'amber' : 'slate'} />
      </div>

      <div className="mb-3 flex gap-1 overflow-x-auto border-b border-slate-200" role="tablist">
        {TABS.map((t) => (
          <button
            key={t.key}
            role="tab"
            aria-selected={tab === t.key}
            onClick={() => setParams({ tab: t.key }, { replace: true })}
            className={cn('-mb-px whitespace-nowrap border-b-2 px-3 py-2 text-sm font-medium', tab === t.key ? 'border-green-700 text-green-800' : 'border-transparent text-slate-500 hover:text-slate-800')}
          >
            {t.label}
          </button>
        ))}
      </div>

      <Card>
        {tab === 'barang' && (
          <DataTable
            rows={filtered}
            columns={summaryCols}
            rowKey={(r) => r.item_id}
            loading={summary.isLoading}
            error={summary.isError ? toUserMessage(summary.error) : null}
            searchPlaceholder="Cari kode atau nama barang…"
            emptyTitle="Belum ada saldo"
            emptyDescription="Saldo bertambah setelah penerimaan disimpan ke gudang."
            toolbar={
              <Select value={levelFilter} onChange={(e) => setLevelFilter(e.target.value)} className="w-52" aria-label="Filter pantauan">
                <option value="semua">Semua barang aktif</option>
                <option value="ada">Ada saldo</option>
                <option value="minimum">Di bawah minimum / kosong</option>
                <option value="maksimum">Melebihi maksimum</option>
              </Select>
            }
          />
        )}
        {tab === 'lokasi' && (
          <DataTable rows={balances.data} columns={locationCols} rowKey={(r) => r.id} loading={balances.isLoading} searchPlaceholder="Cari lokasi atau barang…" emptyTitle="Belum ada saldo" />
        )}
        {tab === 'kedaluwarsa' && (
          <DataTable rows={expiries.data} columns={expiryCols} rowKey={(r) => r.id} loading={expiries.isLoading} searchPlaceholder="Cari barang…" emptyTitle="Tidak ada barang ber-kedaluwarsa" />
        )}
        {tab === 'perpindahan' && (
          <DataTable rows={transfers.data} columns={transferCols} rowKey={(r) => r.id} loading={transfers.isLoading} searchPlaceholder="Cari nomor atau barang…" emptyTitle="Belum ada perpindahan" />
        )}
      </Card>

      <TransferModal open={transferOpen} onClose={() => setTransferOpen(false)} balances={balances.data ?? []} />
    </>
  );
}

function TransferModal({ open, onClose, balances }: { open: boolean; onClose: () => void; balances: BalanceRow[] }) {
  const lk = useLookups();
  const toast = useToast();
  const qc = useQueryClient();
  const [source, setSource] = useState('');
  const [toLoc, setToLoc] = useState('');
  const [qty, setQty] = useState('');
  const [date, setDate] = useState(todayJakarta());
  const [reason, setReason] = useState('');

  const sources = balances.filter((b) => b.condition === 'layak_pakai' && Number(b.quantity) - Number(b.reserved_qty) > 0);
  const src = sources.find((b) => b.id === source);
  const available = src ? Number(src.quantity) - Number(src.reserved_qty) : 0;

  const run = useMutation({
    mutationFn: async () => {
      const n = Number(qty.replace(',', '.'));
      if (!src) throw new UserFacingError('Pilih barang dan lokasi asal.');
      if (!toLoc) throw new UserFacingError('Pilih lokasi tujuan.');
      if (!(n > 0) || n > available) throw new UserFacingError(`Jumlah harus lebih dari 0 dan paling banyak ${formatNumber(available)}.`);
      if (reason.trim().length < 5) throw new UserFacingError('Alasan minimal 5 karakter.');
      const { error } = await supabase.rpc('rpc_transfer_stock', {
        p_date: date,
        p_reason: reason.trim(),
        p_lines: [{ item_id: src.item_id, from_location_id: src.location_id, to_location_id: toLoc, quantity: n }],
      });
      if (error) throw error;
    },
    onSuccess: () => {
      toast.success('Perpindahan lokasi tercatat. Total saldo tidak berubah.');
      void qc.invalidateQueries({ queryKey: ['stock'] });
      setSource('');
      setToLoc('');
      setQty('');
      setReason('');
      onClose();
    },
    onError: (err) => toast.error(toUserMessage(err)),
  });

  return (
    <Modal
      open={open}
      onClose={onClose}
      title="Pindah lokasi penyimpanan"
      footer={
        <>
          <Button variant="secondary" onClick={onClose}>Batal</Button>
          <Button onClick={() => run.mutate()} loading={run.isPending}>Pindahkan</Button>
        </>
      }
    >
      <Alert tone="info">Perpindahan tidak mengubah total saldo dan nilai persediaan. Urutan batch (FIFO) tetap terjaga.</Alert>
      <Field label="Barang & lokasi asal" required htmlFor="tr-src">
        <Select id="tr-src" value={source} onChange={(e) => setSource(e.target.value)}>
          <option value="">— Pilih —</option>
          {sources.map((b) => (
            <option key={b.id} value={b.id}>
              {lk.itemMap.get(b.item_id)?.code} {lk.itemMap.get(b.item_id)?.name} — {lk.locationMap.get(b.location_id)?.code} (tersedia {formatNumber(Number(b.quantity) - Number(b.reserved_qty))})
            </option>
          ))}
        </Select>
      </Field>
      <Field label="Lokasi tujuan" required htmlFor="tr-to">
        <Select id="tr-to" value={toLoc} onChange={(e) => setToLoc(e.target.value)}>
          <option value="">— Pilih —</option>
          {lk.locations.filter((l) => l.is_active && l.id !== src?.location_id).map((l) => (
            <option key={l.id} value={l.id}>{l.code} — {lk.warehouseMap.get(l.warehouse_id)?.name}</option>
          ))}
        </Select>
      </Field>
      <div className="grid grid-cols-2 gap-4">
        <Field label="Jumlah" required hint={src ? `Maksimal ${formatNumber(available)} ${lk.unitName(src.item_id)}` : undefined} htmlFor="tr-qty">
          <Input id="tr-qty" inputMode="decimal" value={qty} onChange={(e) => setQty(e.target.value)} />
        </Field>
        <Field label="Tanggal" required htmlFor="tr-date">
          <Input id="tr-date" type="date" max={todayJakarta()} value={date} onChange={(e) => setDate(e.target.value)} />
        </Field>
      </div>
      <Field label="Alasan" required htmlFor="tr-reason">
        <Input id="tr-reason" value={reason} onChange={(e) => setReason(e.target.value)} placeholder="Mis. penataan ulang rak" />
      </Field>
    </Modal>
  );
}
