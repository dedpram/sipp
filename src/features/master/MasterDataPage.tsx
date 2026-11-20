import { useMemo, useState, type ReactNode } from 'react';
import { useSearchParams } from 'react-router';
import { useQuery } from '@tanstack/react-query';
import { Wand2 } from 'lucide-react';
import { PageHeader } from '@/components/layout/AppShell';
import { Card } from '@/components/ui/Card';
import { Alert } from '@/components/ui/Alert';
import { Button } from '@/components/ui/Button';
import { useToast } from '@/components/ui/Toast';
import { useAuth } from '@/features/auth/AuthProvider';
import { supabase } from '@/lib/supabase';
import { toUserMessage } from '@/lib/errors';
import { formatNumber } from '@/lib/format';
import { cn } from '@/lib/cn';
import type { RoleCode } from '@/lib/roles';
import type {
  Item,
  ItemCategory,
  ItemUnit,
  OrganizationalUnit,
  StorageLocation,
  Supplier,
  Warehouse,
} from '@/types/domain';
import { MasterCrud, useMasterRows, type FormApi, type MasterConfig, type Option } from './MasterCrud';
import {
  buildLocationCode,
  categorySchema,
  itemSchema,
  locationSchema,
  orgUnitSchema,
  supplierSchema,
  unitSchema,
  warehouseSchema,
} from './schemas';

type TabKey = 'barang' | 'kategori' | 'satuan' | 'gudang' | 'lokasi' | 'penyedia' | 'unit';

const TABS: { key: TabKey; label: string; roles: readonly RoleCode[] | 'all' }[] = [
  { key: 'barang', label: 'Barang', roles: 'all' },
  { key: 'kategori', label: 'Kategori', roles: 'all' },
  { key: 'satuan', label: 'Satuan', roles: 'all' },
  { key: 'gudang', label: 'Gudang', roles: 'all' },
  { key: 'lokasi', label: 'Lokasi Penyimpanan', roles: 'all' },
  { key: 'penyedia', label: 'Penyedia', roles: ['SA', 'KPA', 'PWS', 'PPK', 'PPB', 'PGB', 'AKT', 'AUD'] },
  { key: 'unit', label: 'Unit Kerja', roles: 'all' },
];

const text = (v: string | null | undefined) => v ?? '';
const opt = (rows: { id: string; code?: string; name: string; is_active?: boolean }[] | undefined, includeId?: string): Option[] =>
  (rows ?? [])
    .filter((r) => r.is_active !== false || r.id === includeId)
    .map((r) => ({ value: r.id, label: r.code ? `${r.name} (${r.code})` : r.name }));

function useProfilesLookup(enabled: boolean) {
  return useQuery({
    queryKey: ['master', 'profiles-lookup'],
    enabled,
    queryFn: async () => {
      const { data, error } = await supabase.from('profiles').select('id, full_name, is_active').order('full_name');
      if (error) throw error;
      return (data ?? []) as { id: string; full_name: string; is_active: boolean }[];
    },
  });
}

export default function MasterDataPage() {
  const { roles, hasRole, adminReady } = useAuth();
  const toast = useToast();
  const [params, setParams] = useSearchParams();
  const visibleTabs = TABS.filter((t) => t.roles === 'all' || t.roles.some((r) => roles.includes(r)));
  const active = (visibleTabs.find((t) => t.key === params.get('tab'))?.key ?? 'barang') as TabKey;

  const isPGB = hasRole('PGB');
  const isPPK = hasRole('PPK');
  const saNeedsMfa = hasRole('SA') && !adminReady;

  // Data acuan untuk pilihan di form & tampilan kolom.
  const categories = useMasterRows<ItemCategory>('item_categories', 'id, code, name, account_code, description, is_active', 'code');
  const units = useMasterRows<ItemUnit>('item_units', 'id, code, name, is_active', 'name');
  const warehouses = useMasterRows<Warehouse>('warehouses', 'id, code, name, address, pic_user_id, is_active', 'code');
  const orgUnits = useMasterRows<OrganizationalUnit>('organizational_units', 'id, code, name, parent_id, head_user_id, is_active', 'name');
  const profiles = useProfilesLookup(hasRole('SA', 'KPA', 'PWS', 'AUD', 'PGB', 'AKT'));

  const maps = useMemo(() => {
    const byId = <T extends { id: string }>(list: T[] | undefined) => new Map((list ?? []).map((x) => [x.id, x]));
    return {
      category: byId(categories.data),
      unit: byId(units.data),
      warehouse: byId(warehouses.data),
      orgUnit: byId(orgUnits.data),
      profile: byId(profiles.data),
    };
  }, [categories.data, units.data, warehouses.data, orgUnits.data, profiles.data]);

  const profileOptions: Option[] = (profiles.data ?? []).filter((p) => p.is_active).map((p) => ({ value: p.id, label: p.full_name }));
  const [suggesting, setSuggesting] = useState(false);

  const readOnlyNote = (who: string) =>
    saNeedsMfa ? (
      <Alert tone="warning">Aktifkan verifikasi dua langkah di menu Profil Saya untuk dapat mengubah data ini.</Alert>
    ) : (
      <p className="text-xs text-slate-500">Data ini hanya dapat diubah oleh {who}.</p>
    );

  // ---------------------------------------------------------------- Barang
  const itemConfig: MasterConfig<Item> = {
    table: 'items',
    noun: 'barang',
    select: 'id, code, name, category_id, unit_id, specification, brand, min_stock, safety_stock, max_stock, has_expiry, is_active, activated_at',
    orderBy: 'code',
    canCreate: adminReady || isPGB,
    canEdit: adminReady || isPGB,
    canToggle: adminReady,
    searchPlaceholder: 'Cari kode, nama, merek, spesifikasi…',
    emptyDescription: 'Tambahkan barang persediaan yang dikelola satuan kerja.',
    note: !(adminReady || isPGB) ? (
      readOnlyNote('Super Admin atau Pengurus Barang')
    ) : isPGB && !adminReady ? (
      <Alert tone="info">
        Barang yang Anda tambahkan tersimpan sebagai <b>usulan</b> dan baru dapat dipakai setelah diaktifkan Super Admin.
      </Alert>
    ) : undefined,
    status: (r) =>
      r.is_active
        ? { label: 'Aktif', tone: 'success' }
        : r.activated_at
          ? { label: 'Nonaktif', tone: 'neutral' }
          : { label: 'Usulan', tone: 'waiting' },
    fields: [
      { name: 'category_id', label: 'Kategori', type: 'select', required: true, options: opt(categories.data) },
      { name: 'code', label: 'Kode barang', required: true, placeholder: 'ATK-0001', hint: 'Klik "Usulkan kode" setelah memilih kategori', maxLength: 30 },
      { name: 'name', label: 'Nama barang', required: true, full: true, placeholder: 'Kertas HVS A4 70 gsm' },
      { name: 'unit_id', label: 'Satuan', type: 'select', required: true, options: opt(units.data) },
      { name: 'brand', label: 'Merek', hint: 'Opsional' },
      { name: 'specification', label: 'Spesifikasi', type: 'textarea' },
      { name: 'min_stock', label: 'Stok minimum', type: 'number', hint: 'Batas peringatan stok menipis' },
      { name: 'safety_stock', label: 'Stok pengaman', type: 'number', hint: 'Cadangan untuk kebutuhan mendesak' },
      { name: 'max_stock', label: 'Stok maksimum', type: 'number', hint: 'Kosongkan bila tidak dibatasi' },
      { name: 'has_expiry', label: 'Barang memiliki tanggal kedaluwarsa', type: 'checkbox', hint: 'Pengeluaran memakai urutan kedaluwarsa terdekat (FEFO)' },
    ],
    schema: itemSchema,
    toForm: (r) => ({
      category_id: r?.category_id ?? '',
      code: r?.code ?? '',
      name: r?.name ?? '',
      unit_id: r?.unit_id ?? '',
      brand: text(r?.brand),
      specification: text(r?.specification),
      min_stock: r ? String(r.min_stock) : '0',
      safety_stock: r ? String(r.safety_stock) : '0',
      max_stock: r?.max_stock != null ? String(r.max_stock) : '',
      has_expiry: r?.has_expiry ?? false,
    }),
    formExtra: (api: FormApi) => (
      <div className="flex justify-end">
        <Button
          size="sm"
          variant="secondary"
          icon={Wand2}
          loading={suggesting}
          onClick={async () => {
            const categoryId = api.getValues('category_id');
            if (!categoryId) {
              toast.error('Pilih kategori terlebih dahulu.');
              return;
            }
            setSuggesting(true);
            const { data, error } = await supabase.rpc('rpc_suggest_item_code', { p_category_id: categoryId });
            setSuggesting(false);
            if (error) toast.error(toUserMessage(error));
            else api.setValue('code', data as string);
          }}
        >
          Usulkan kode
        </Button>
      </div>
    ),
    createdMessage: (saved) =>
      saved.is_active ? 'Barang ditambahkan dan langsung aktif.' : 'Usulan barang tersimpan. Menunggu aktivasi Super Admin.',
    columns: [
      { key: 'code', header: 'Kode', sortValue: (r) => r.code, searchValue: (r) => r.code, render: (r) => <span className="font-mono text-xs">{r.code}</span> },
      {
        key: 'name',
        header: 'Nama / Spesifikasi',
        sortValue: (r) => r.name,
        searchValue: (r) => `${r.name} ${r.brand ?? ''} ${r.specification ?? ''}`,
        render: (r) => (
          <div>
            <p className="font-medium text-slate-900">{r.name}</p>
            {(r.brand || r.specification) && (
              <p className="line-clamp-2 text-xs text-slate-500">{[r.brand, r.specification].filter(Boolean).join(' · ')}</p>
            )}
          </div>
        ),
      },
      {
        key: 'category',
        header: 'Kategori',
        sortValue: (r) => maps.category.get(r.category_id)?.name ?? '',
        searchValue: (r) => maps.category.get(r.category_id)?.name ?? '',
        render: (r) => maps.category.get(r.category_id)?.name ?? '-',
      },
      { key: 'unit', header: 'Satuan', render: (r) => maps.unit.get(r.unit_id)?.name ?? '-' },
      {
        key: 'levels',
        header: 'Min / Pengaman / Maks',
        className: 'whitespace-nowrap tabular-nums',
        render: (r) => `${formatNumber(r.min_stock)} / ${formatNumber(r.safety_stock)} / ${r.max_stock != null ? formatNumber(r.max_stock) : '–'}`,
      },
    ],
  };

  // ------------------------------------------------------------- Kategori
  const categoryConfig: MasterConfig<ItemCategory> = {
    table: 'item_categories',
    noun: 'kategori',
    select: 'id, code, name, account_code, description, is_active',
    orderBy: 'code',
    canCreate: adminReady,
    canEdit: adminReady,
    canToggle: adminReady,
    note: !adminReady ? readOnlyNote('Super Admin') : undefined,
    searchPlaceholder: 'Cari kode atau nama kategori…',
    fields: [
      { name: 'code', label: 'Kode', required: true, placeholder: 'ATK', maxLength: 10, hint: 'Dipakai sebagai awalan kode barang' },
      { name: 'name', label: 'Nama kategori', required: true },
      { name: 'account_code', label: 'Kode akun persediaan', placeholder: '117111', hint: 'Dari bagian akuntansi; boleh diisi kemudian' },
      { name: 'description', label: 'Keterangan', type: 'textarea' },
    ],
    schema: categorySchema,
    toForm: (r) => ({ code: r?.code ?? '', name: r?.name ?? '', account_code: text(r?.account_code), description: text(r?.description) }),
    columns: [
      { key: 'code', header: 'Kode', sortValue: (r) => r.code, searchValue: (r) => r.code, render: (r) => <span className="font-mono text-xs">{r.code}</span> },
      { key: 'name', header: 'Nama', sortValue: (r) => r.name, searchValue: (r) => r.name, render: (r) => r.name },
      { key: 'account', header: 'Kode akun', render: (r) => r.account_code ?? <span className="text-slate-400">Belum diisi</span> },
      { key: 'desc', header: 'Keterangan', render: (r) => <span className="text-xs text-slate-600">{r.description ?? '-'}</span> },
    ],
  };

  // --------------------------------------------------------------- Satuan
  const unitConfig: MasterConfig<ItemUnit> = {
    table: 'item_units',
    noun: 'satuan',
    select: 'id, code, name, is_active',
    orderBy: 'name',
    canCreate: adminReady,
    canEdit: adminReady,
    canToggle: adminReady,
    note: !adminReady ? readOnlyNote('Super Admin') : undefined,
    searchPlaceholder: 'Cari satuan…',
    fields: [
      { name: 'code', label: 'Kode', required: true, placeholder: 'RIM', maxLength: 6 },
      { name: 'name', label: 'Nama satuan', required: true, placeholder: 'Rim' },
    ],
    schema: unitSchema,
    toForm: (r) => ({ code: r?.code ?? '', name: r?.name ?? '' }),
    columns: [
      { key: 'code', header: 'Kode', sortValue: (r) => r.code, searchValue: (r) => r.code, render: (r) => <span className="font-mono text-xs">{r.code}</span> },
      { key: 'name', header: 'Nama', sortValue: (r) => r.name, searchValue: (r) => r.name, render: (r) => r.name },
    ],
  };

  // --------------------------------------------------------------- Gudang
  const warehouseConfig: MasterConfig<Warehouse> = {
    table: 'warehouses',
    noun: 'gudang',
    select: 'id, code, name, address, pic_user_id, is_active',
    orderBy: 'code',
    canCreate: adminReady || isPGB,
    canEdit: adminReady || isPGB,
    canToggle: adminReady || isPGB,
    note: !(adminReady || isPGB) ? readOnlyNote('Super Admin atau Pengurus Barang') : undefined,
    searchPlaceholder: 'Cari gudang…',
    fields: [
      { name: 'code', label: 'Kode gudang', required: true, placeholder: 'GDG1', maxLength: 10 },
      { name: 'name', label: 'Nama gudang', required: true, placeholder: 'Gudang Utama' },
      { name: 'pic_user_id', label: 'Penanggung jawab', type: 'select', options: profileOptions },
      { name: 'address', label: 'Alamat / letak', type: 'textarea' },
    ],
    schema: warehouseSchema,
    toForm: (r) => ({ code: r?.code ?? '', name: r?.name ?? '', pic_user_id: r?.pic_user_id ?? '', address: text(r?.address) }),
    columns: [
      { key: 'code', header: 'Kode', sortValue: (r) => r.code, searchValue: (r) => r.code, render: (r) => <span className="font-mono text-xs">{r.code}</span> },
      { key: 'name', header: 'Nama', sortValue: (r) => r.name, searchValue: (r) => `${r.name} ${r.address ?? ''}`, render: (r) => r.name },
      { key: 'pic', header: 'Penanggung jawab', render: (r) => (r.pic_user_id ? (maps.profile.get(r.pic_user_id)?.full_name ?? '-') : '-') },
      { key: 'locations', header: 'Alamat', render: (r) => <span className="text-xs text-slate-600">{r.address ?? '-'}</span> },
    ],
  };

  // --------------------------------------------------------------- Lokasi
  const locationConfig: MasterConfig<StorageLocation> = {
    table: 'storage_locations',
    noun: 'lokasi penyimpanan',
    select: 'id, warehouse_id, room, rack, location_number, code, description, is_active',
    orderBy: 'code',
    canCreate: adminReady || isPGB,
    canEdit: adminReady || isPGB,
    canToggle: adminReady || isPGB,
    note: !(adminReady || isPGB) ? readOnlyNote('Super Admin atau Pengurus Barang') : undefined,
    searchPlaceholder: 'Cari kode, ruangan, rak…',
    emptyDescription: 'Tambahkan gudang terlebih dahulu, lalu lokasi di dalamnya.',
    fields: [
      { name: 'warehouse_id', label: 'Gudang', type: 'select', required: true, options: opt(warehouses.data) },
      { name: 'room', label: 'Ruangan', required: true, placeholder: 'R. Persediaan' },
      { name: 'rack', label: 'Rak', placeholder: 'A' },
      { name: 'location_number', label: 'Nomor lokasi', placeholder: '01' },
      { name: 'code', label: 'Kode lokasi', placeholder: 'Kosongkan untuk dibuat otomatis', hint: 'Contoh hasil otomatis: GDG1-A-01', full: true },
      { name: 'description', label: 'Keterangan', type: 'textarea' },
    ],
    schema: locationSchema,
    toForm: (r) => ({
      warehouse_id: r?.warehouse_id ?? '',
      room: r?.room ?? '',
      rack: r && r.rack !== '-' ? r.rack : '',
      location_number: r && r.location_number !== '-' ? r.location_number : '',
      code: r?.code ?? '',
      description: text(r?.description),
    }),
    prepare: (v) => {
      const wh = maps.warehouse.get(String(v.warehouse_id));
      const rack = (v.rack as string | null) ?? '-';
      const number = (v.location_number as string | null) ?? '-';
      const code = (v.code as string | null) ?? buildLocationCode(wh?.code ?? 'LOK', String(v.room), rack, number);
      return { ...v, rack, location_number: number, code: code.toUpperCase() };
    },
    columns: [
      { key: 'code', header: 'Kode', sortValue: (r) => r.code, searchValue: (r) => r.code, render: (r) => <span className="font-mono text-xs">{r.code}</span> },
      {
        key: 'wh',
        header: 'Gudang',
        sortValue: (r) => maps.warehouse.get(r.warehouse_id)?.name ?? '',
        searchValue: (r) => maps.warehouse.get(r.warehouse_id)?.name ?? '',
        render: (r) => maps.warehouse.get(r.warehouse_id)?.name ?? '-',
      },
      { key: 'room', header: 'Ruangan', searchValue: (r) => r.room, render: (r) => r.room },
      { key: 'rack', header: 'Rak / No.', searchValue: (r) => `${r.rack} ${r.location_number}`, render: (r) => `${r.rack} / ${r.location_number}` },
    ],
  };

  // ------------------------------------------------------------- Penyedia
  const supplierConfig: MasterConfig<Supplier> = {
    table: 'suppliers',
    noun: 'penyedia',
    select: 'id, name, npwp, address, phone, email, contact_person, is_active',
    orderBy: 'name',
    canCreate: adminReady || isPPK,
    canEdit: adminReady || isPPK,
    canToggle: adminReady || isPPK,
    note: !(adminReady || isPPK) ? readOnlyNote('Super Admin atau PPK') : undefined,
    searchPlaceholder: 'Cari nama, NPWP, kontak…',
    fields: [
      { name: 'name', label: 'Nama penyedia', required: true, full: true, placeholder: 'CV Maju Jaya' },
      { name: 'npwp', label: 'NPWP', inputMode: 'numeric', hint: '15/16 digit; titik dan tanda minus boleh' },
      { name: 'contact_person', label: 'Narahubung' },
      { name: 'phone', label: 'Telepon', inputMode: 'tel' },
      { name: 'email', label: 'Email', inputMode: 'email' },
      { name: 'address', label: 'Alamat', type: 'textarea' },
    ],
    schema: supplierSchema,
    toForm: (r) => ({
      name: r?.name ?? '',
      npwp: text(r?.npwp),
      contact_person: text(r?.contact_person),
      phone: text(r?.phone),
      email: text(r?.email),
      address: text(r?.address),
    }),
    columns: [
      { key: 'name', header: 'Nama', sortValue: (r) => r.name, searchValue: (r) => `${r.name} ${r.npwp ?? ''}`, render: (r) => <span className="font-medium">{r.name}</span> },
      { key: 'npwp', header: 'NPWP', render: (r) => <span className="font-mono text-xs">{r.npwp ?? '-'}</span> },
      {
        key: 'contact',
        header: 'Kontak',
        searchValue: (r) => `${r.contact_person ?? ''} ${r.phone ?? ''} ${r.email ?? ''}`,
        render: (r) => <span className="text-xs text-slate-600">{[r.contact_person, r.phone, r.email].filter(Boolean).join(' · ') || '-'}</span>,
      },
    ],
  };

  // ----------------------------------------------------------- Unit kerja
  const orgUnitConfig: MasterConfig<OrganizationalUnit> = {
    table: 'organizational_units',
    noun: 'unit kerja',
    select: 'id, code, name, parent_id, head_user_id, is_active',
    orderBy: 'name',
    canCreate: adminReady,
    canEdit: adminReady,
    canToggle: adminReady,
    note: !adminReady ? readOnlyNote('Super Admin') : undefined,
    searchPlaceholder: 'Cari unit kerja…',
    fields: [
      { name: 'code', label: 'Kode unit', required: true, placeholder: 'UMUM', maxLength: 15 },
      { name: 'name', label: 'Nama unit', required: true, placeholder: 'Bagian Umum' },
      { name: 'parent_id', label: 'Unit induk', type: 'select', options: opt(orgUnits.data), hint: 'Kosongkan bila unit tertinggi' },
      { name: 'head_user_id', label: 'Atasan unit', type: 'select', options: profileOptions, hint: 'Atasan dapat menyetujui permintaan unit ini & sub-unitnya' },
    ],
    schema: orgUnitSchema,
    toForm: (r) => ({ code: r?.code ?? '', name: r?.name ?? '', parent_id: r?.parent_id ?? '', head_user_id: r?.head_user_id ?? '' }),
    columns: [
      { key: 'code', header: 'Kode', sortValue: (r) => r.code, searchValue: (r) => r.code, render: (r) => <span className="font-mono text-xs">{r.code}</span> },
      { key: 'name', header: 'Nama', sortValue: (r) => r.name, searchValue: (r) => r.name, render: (r) => r.name },
      {
        key: 'parent',
        header: 'Unit induk',
        searchValue: (r) => (r.parent_id ? (maps.orgUnit.get(r.parent_id)?.name ?? '') : ''),
        render: (r) => (r.parent_id ? (maps.orgUnit.get(r.parent_id)?.name ?? '-') : <span className="text-slate-400">—</span>),
      },
      { key: 'head', header: 'Atasan', render: (r) => (r.head_user_id ? (maps.profile.get(r.head_user_id)?.full_name ?? '-') : '-') },
    ],
  };

  const content: Record<TabKey, ReactNode> = {
    barang: <MasterCrud config={itemConfig} />,
    kategori: <MasterCrud config={categoryConfig} />,
    satuan: <MasterCrud config={unitConfig} />,
    gudang: <MasterCrud config={warehouseConfig} />,
    lokasi: <MasterCrud config={locationConfig} />,
    penyedia: <MasterCrud config={supplierConfig} />,
    unit: <MasterCrud config={orgUnitConfig} />,
  };

  return (
    <>
      <PageHeader title="Master Data" description="Data acuan yang dipakai di seluruh transaksi persediaan. Data tidak dihapus, hanya dinonaktifkan." />
      <div className="mb-4 flex gap-1 overflow-x-auto border-b border-slate-200" role="tablist">
        {visibleTabs.map((t) => (
          <button
            key={t.key}
            role="tab"
            aria-selected={active === t.key}
            onClick={() => setParams({ tab: t.key }, { replace: true })}
            className={cn(
              '-mb-px whitespace-nowrap border-b-2 px-3 py-2 text-sm font-medium transition-colors',
              active === t.key ? 'border-green-700 text-green-800' : 'border-transparent text-slate-500 hover:text-slate-800',
            )}
          >
            {t.label}
          </button>
        ))}
      </div>
      <Card>{content[active]}</Card>
    </>
  );
}
