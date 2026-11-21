import { useState } from 'react';
import { Link, useSearchParams } from 'react-router';
import { useQuery } from '@tanstack/react-query';
import { Printer } from 'lucide-react';
import { PageHeader } from '@/components/layout/AppShell';
import { Card } from '@/components/ui/Card';
import { Button } from '@/components/ui/Button';
import { Field, Input, Select } from '@/components/ui/Input';
import { EmptyState, ErrorState, LoadingState } from '@/components/feedback/States';
import { useLookups } from '@/features/master/lookups';
import { supabase } from '@/lib/supabase';
import { toUserMessage } from '@/lib/errors';
import { formatDate, formatDateTime, formatNumber, formatRupiah } from '@/lib/format';

interface CardRow {
  date: string;
  ref_no: string;
  ref_table: string;
  ref_id: string;
  type: string;
  description: string;
  location: string;
  qty_in: number;
  qty_out: number;
  unit_cost: number;
  value: number;
  balance_qty: number;
  balance_value: number;
}

interface StockCard {
  opening_qty: number;
  opening_value: number;
  total_in: number;
  total_out: number;
  total_in_value: number;
  total_out_value: number;
  closing_qty: number;
  closing_value: number;
  rows: CardRow[];
}

const TYPE_LABEL: Record<string, string> = {
  OPENING_BALANCE: 'Saldo awal',
  RECEIPT_IN: 'Penerimaan',
  ISSUE_OUT: 'Pengeluaran',
  TRANSFER_OUT: 'Pindah keluar',
  TRANSFER_IN: 'Pindah masuk',
  ADJ_IN: 'Koreksi tambah',
  ADJ_OUT: 'Koreksi kurang',
  RECLASS_OUT: 'Reklasifikasi keluar',
  RECLASS_IN: 'Reklasifikasi masuk',
  WRITE_OFF: 'Penghapusan',
};

const todayJakarta = () => new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Jakarta' }).format(new Date());

export default function StockCardPage() {
  const lk = useLookups();
  const [params, setParams] = useSearchParams();
  const [item, setItem] = useState(params.get('item') ?? '');
  const [from, setFrom] = useState(`${todayJakarta().slice(0, 4)}-01-01`);
  const [to, setTo] = useState(todayJakarta());

  const query = useQuery({
    queryKey: ['stock', 'card', item, from, to],
    enabled: Boolean(item && from && to),
    queryFn: async () => {
      const { data, error } = await supabase.rpc('rpc_stock_card', { p_item: item, p_from: from, p_to: to });
      if (error) throw error;
      return data as StockCard;
    },
  });

  const it = lk.itemMap.get(item);
  const unit = item ? lk.unitName(item) : '';
  const link = (r: CardRow) => (r.ref_table === 'receipts' ? `/penerimaan/${r.ref_id}` : r.ref_table === 'stock_transfers' ? '/penyimpanan?tab=perpindahan' : null);

  return (
    <>
      <PageHeader
        title="Kartu Stok"
        description="Riwayat mutasi per barang dengan saldo berjalan dan nilai (metode FIFO)."
        actions={query.data && <Button variant="secondary" icon={Printer} onClick={() => window.print()}>Cetak</Button>}
      />
      <Card className="no-print mb-4">
        <div className="grid grid-cols-1 gap-4 md:grid-cols-4">
          <div className="md:col-span-2">
            <Field label="Barang" htmlFor="sc-item">
              <Select
                id="sc-item"
                value={item}
                onChange={(e) => {
                  setItem(e.target.value);
                  setParams(e.target.value ? { item: e.target.value } : {}, { replace: true });
                }}
              >
                <option value="">— Pilih barang —</option>
                {lk.items.map((i) => (
                  <option key={i.id} value={i.id}>{i.code} — {i.name}{i.is_active ? '' : ' (nonaktif)'}</option>
                ))}
              </Select>
            </Field>
          </div>
          <Field label="Dari tanggal" htmlFor="sc-from">
            <Input id="sc-from" type="date" value={from} onChange={(e) => setFrom(e.target.value)} />
          </Field>
          <Field label="Sampai tanggal" htmlFor="sc-to">
            <Input id="sc-to" type="date" value={to} onChange={(e) => setTo(e.target.value)} />
          </Field>
        </div>
      </Card>

      {!item ? (
        <Card><EmptyState title="Pilih barang" description="Kartu stok ditampilkan per barang untuk periode yang dipilih." /></Card>
      ) : query.isLoading ? (
        <LoadingState />
      ) : query.isError ? (
        <ErrorState message={toUserMessage(query.error)} onRetry={() => void query.refetch()} />
      ) : query.data ? (
        <Card>
          <div className="mb-4">
            <h2 className="text-lg font-semibold">KARTU STOK — {it?.code} {it?.name}</h2>
            <p className="text-sm text-slate-600">Satuan: {unit} · Periode {formatDate(from)} s.d. {formatDate(to)}</p>
          </div>
          <div className="mb-4 grid grid-cols-2 gap-3 text-sm md:grid-cols-4">
            {[
              ['Saldo awal', query.data.opening_qty, query.data.opening_value],
              ['Total masuk', query.data.total_in, query.data.total_in_value],
              ['Total keluar', query.data.total_out, query.data.total_out_value],
              ['Saldo akhir', query.data.closing_qty, query.data.closing_value],
            ].map(([label, q, v]) => (
              <div key={label as string} className="rounded-lg border border-slate-200 p-3">
                <p className="text-xs text-slate-500">{label}</p>
                <p className="font-semibold tabular-nums">{formatNumber(q as number)} {unit}</p>
                <p className="text-xs tabular-nums text-slate-600">{formatRupiah(v as number)}</p>
              </div>
            ))}
          </div>
          <p className="mb-2 text-xs text-slate-500">Total masuk/keluar tidak termasuk perpindahan lokasi (perpindahan tidak mengubah saldo).</p>
          <div className="overflow-x-auto rounded-lg border border-slate-200">
            <table className="min-w-full divide-y divide-slate-200 text-sm">
              <thead className="bg-slate-50 text-left text-slate-600">
                <tr>
                  <th className="px-2 py-2">Tanggal</th>
                  <th className="px-2 py-2">No. transaksi</th>
                  <th className="px-2 py-2">Uraian</th>
                  <th className="px-2 py-2 text-right">Masuk</th>
                  <th className="px-2 py-2 text-right">Keluar</th>
                  <th className="px-2 py-2 text-right">Saldo</th>
                  <th className="px-2 py-2 text-right">Harga satuan</th>
                  <th className="px-2 py-2 text-right">Nilai transaksi</th>
                  <th className="px-2 py-2 text-right">Nilai saldo</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-100">
                <tr className="bg-slate-50/60 italic">
                  <td className="px-2 py-2">{formatDate(from)}</td>
                  <td className="px-2 py-2" />
                  <td className="px-2 py-2">Saldo awal periode</td>
                  <td colSpan={2} />
                  <td className="px-2 py-2 text-right tabular-nums">{formatNumber(query.data.opening_qty)}</td>
                  <td colSpan={2} />
                  <td className="px-2 py-2 text-right tabular-nums">{formatRupiah(query.data.opening_value)}</td>
                </tr>
                {query.data.rows.map((r, i) => {
                  const href = link(r);
                  return (
                    <tr key={i}>
                      <td className="whitespace-nowrap px-2 py-2">{formatDate(r.date)}</td>
                      <td className="whitespace-nowrap px-2 py-2 font-mono text-xs">
                        {href ? <Link to={href} className="text-green-800 hover:underline">{r.ref_no}</Link> : r.ref_no}
                      </td>
                      <td className="px-2 py-2">
                        <span className="text-xs font-medium text-slate-500">{TYPE_LABEL[r.type] ?? r.type} · {r.location}</span>
                        <span className="block">{r.description}</span>
                      </td>
                      <td className="px-2 py-2 text-right tabular-nums text-green-700">{Number(r.qty_in) ? formatNumber(r.qty_in) : ''}</td>
                      <td className="px-2 py-2 text-right tabular-nums text-red-600">{Number(r.qty_out) ? formatNumber(r.qty_out) : ''}</td>
                      <td className="px-2 py-2 text-right tabular-nums font-medium">{formatNumber(r.balance_qty)}</td>
                      <td className="px-2 py-2 text-right tabular-nums">{formatRupiah(r.unit_cost)}</td>
                      <td className="px-2 py-2 text-right tabular-nums">{formatRupiah(r.value)}</td>
                      <td className="px-2 py-2 text-right tabular-nums">{formatRupiah(r.balance_value)}</td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
          {query.data.rows.length === 0 && <p className="mt-3 text-center text-sm text-slate-500">Tidak ada mutasi pada periode ini.</p>}
          <p className="print-only mt-3 text-right text-xs text-slate-500">Dicetak {formatDateTime(new Date())}</p>
        </Card>
      ) : null}
    </>
  );
}
