import { useMemo, useState, type ReactNode } from 'react';
import { ArrowDown, ArrowUp, ArrowUpDown, ChevronLeft, ChevronRight, Search } from 'lucide-react';
import { Input } from '@/components/ui/Input';
import { EmptyState, ErrorState, LoadingState } from '@/components/feedback/States';
import { cn } from '@/lib/cn';

export interface Column<T> {
  key: string;
  header: string;
  render: (row: T) => ReactNode;
  /** Nilai untuk pengurutan; bila kosong kolom tidak dapat diurutkan. */
  sortValue?: (row: T) => string | number | null;
  /** Teks yang diikutkan dalam pencarian. */
  searchValue?: (row: T) => string;
  className?: string;
}

interface DataTableProps<T> {
  rows: T[] | undefined;
  columns: Column<T>[];
  rowKey: (row: T) => string;
  loading?: boolean;
  error?: string | null;
  onRetry?: () => void;
  toolbar?: ReactNode;
  pageSize?: number;
  emptyTitle?: string;
  emptyDescription?: string;
  searchPlaceholder?: string;
}

/**
 * Tabel data dengan pencarian, pengurutan, dan pagination di sisi klien.
 * Untuk data besar (transaksi), versi server-side akan dipakai pada Fase 4.
 */
export function DataTable<T>({
  rows,
  columns,
  rowKey,
  loading,
  error,
  onRetry,
  toolbar,
  pageSize = 10,
  emptyTitle,
  emptyDescription,
  searchPlaceholder = 'Cari…',
}: DataTableProps<T>) {
  const [query, setQuery] = useState('');
  const [sort, setSort] = useState<{ key: string; dir: 'asc' | 'desc' } | null>(null);
  const [page, setPage] = useState(1);

  const processed = useMemo(() => {
    let list = rows ?? [];
    const q = query.trim().toLowerCase();
    if (q) {
      list = list.filter((row) =>
        columns.some((c) => c.searchValue && c.searchValue(row).toLowerCase().includes(q)),
      );
    }
    if (sort) {
      const col = columns.find((c) => c.key === sort.key);
      if (col?.sortValue) {
        const get = col.sortValue;
        list = [...list].sort((a, b) => {
          const va = get(a);
          const vb = get(b);
          if (va === vb) return 0;
          if (va === null) return 1;
          if (vb === null) return -1;
          const cmp = typeof va === 'number' && typeof vb === 'number' ? va - vb : String(va).localeCompare(String(vb), 'id');
          return sort.dir === 'asc' ? cmp : -cmp;
        });
      }
    }
    return list;
  }, [rows, columns, query, sort]);

  const totalPages = Math.max(1, Math.ceil(processed.length / pageSize));
  const current = Math.min(page, totalPages);
  const pageRows = processed.slice((current - 1) * pageSize, current * pageSize);

  const toggleSort = (key: string) => {
    setSort((s) => (s?.key !== key ? { key, dir: 'asc' } : s.dir === 'asc' ? { key, dir: 'desc' } : null));
  };

  return (
    <div className="space-y-3">
      <div className="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
        <div className="relative w-full sm:max-w-xs">
          <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-slate-400" aria-hidden />
          <Input
            value={query}
            onChange={(e) => {
              setQuery(e.target.value);
              setPage(1);
            }}
            placeholder={searchPlaceholder}
            className="pl-9"
            aria-label="Pencarian"
          />
        </div>
        {toolbar && <div className="flex flex-wrap gap-2">{toolbar}</div>}
      </div>

      {loading ? (
        <LoadingState />
      ) : error ? (
        <ErrorState message={error} onRetry={onRetry} />
      ) : processed.length === 0 ? (
        <EmptyState title={query ? 'Tidak ada data yang cocok' : emptyTitle} description={query ? 'Ubah kata kunci pencarian.' : emptyDescription} />
      ) : (
        <>
          <div className="overflow-x-auto rounded-lg border border-slate-200">
            <table className="min-w-full divide-y divide-slate-200 text-sm">
              <thead className="bg-slate-50">
                <tr>
                  {columns.map((c) => (
                    <th key={c.key} scope="col" className={cn('px-3 py-2 text-left font-semibold text-slate-600', c.className)}>
                      {c.sortValue ? (
                        <button className="inline-flex items-center gap-1 hover:text-slate-900" onClick={() => toggleSort(c.key)}>
                          {c.header}
                          {sort?.key === c.key ? (
                            sort.dir === 'asc' ? <ArrowUp className="h-3.5 w-3.5" /> : <ArrowDown className="h-3.5 w-3.5" />
                          ) : (
                            <ArrowUpDown className="h-3.5 w-3.5 text-slate-300" />
                          )}
                        </button>
                      ) : (
                        c.header
                      )}
                    </th>
                  ))}
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-100 bg-white">
                {pageRows.map((row) => (
                  <tr key={rowKey(row)} className="hover:bg-slate-50">
                    {columns.map((c) => (
                      <td key={c.key} className={cn('px-3 py-2 align-top text-slate-700', c.className)}>
                        {c.render(row)}
                      </td>
                    ))}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          <div className="flex items-center justify-between text-sm text-slate-600">
            <span>
              {(current - 1) * pageSize + 1}–{Math.min(current * pageSize, processed.length)} dari {processed.length} data
            </span>
            <div className="flex items-center gap-1">
              <button
                className="rounded-md p-1.5 hover:bg-slate-100 disabled:opacity-40"
                onClick={() => setPage(current - 1)}
                disabled={current <= 1}
                aria-label="Halaman sebelumnya"
              >
                <ChevronLeft className="h-4 w-4" />
              </button>
              <span className="tabular-nums">
                {current}/{totalPages}
              </span>
              <button
                className="rounded-md p-1.5 hover:bg-slate-100 disabled:opacity-40"
                onClick={() => setPage(current + 1)}
                disabled={current >= totalPages}
                aria-label="Halaman berikutnya"
              >
                <ChevronRight className="h-4 w-4" />
              </button>
            </div>
          </div>
        </>
      )}
    </div>
  );
}
