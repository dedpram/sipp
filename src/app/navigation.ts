import {
  ArrowDownToLine,
  ArrowUpFromLine,
  BookOpenText,
  ClipboardCheck,
  ClipboardList,
  FileBarChart,
  LayoutDashboard,
  type LucideIcon,
  PackageX,
  Scale,
  SearchCheck,
  Settings,
  ShieldCheck,
  TriangleAlert,
  Users,
  Warehouse,
  Database,
} from 'lucide-react';
import { hasAnyRole, type RoleCode } from '@/lib/roles';

export interface NavItem {
  key: string;
  label: string;
  path: string;
  icon: LucideIcon;
  /** Role yang boleh melihat menu (hak sebenarnya tetap ditegakkan RLS). */
  roles: readonly RoleCode[] | 'all';
  /** Fase pengembangan saat modul tersedia. */
  phase: number;
}

const ALL_EXCEPT_NONE = 'all' as const;

export const NAV_ITEMS: readonly NavItem[] = [
  { key: 'dashboard', label: 'Dashboard', path: '/', icon: LayoutDashboard, roles: ALL_EXCEPT_NONE, phase: 2 },
  {
    key: 'master',
    label: 'Master Data',
    path: '/master-data',
    icon: Database,
    roles: ['SA', 'PWS', 'PPK', 'PPB', 'PGB', 'TSO', 'AUD'],
    phase: 3,
  },
  {
    key: 'receipts',
    label: 'Penerimaan',
    path: '/penerimaan',
    icon: ArrowDownToLine,
    roles: ['PGB', 'PPB', 'PPK', 'PWS', 'AUD'],
    phase: 4,
  },
  {
    key: 'storage',
    label: 'Penyimpanan',
    path: '/penyimpanan',
    icon: Warehouse,
    roles: ['PGB', 'PPB', 'PPK', 'PWS', 'TSO', 'AUD'],
    phase: 4,
  },
  {
    key: 'requests',
    label: 'Permintaan Barang',
    path: '/permintaan',
    icon: ClipboardList,
    roles: ['PGW', 'ATS', 'PGB', 'PWS', 'AUD'],
    phase: 4,
  },
  {
    key: 'issues',
    label: 'Pengeluaran',
    path: '/pengeluaran',
    icon: ArrowUpFromLine,
    roles: ['PGB', 'PWS', 'AUD'],
    phase: 4,
  },
  {
    key: 'stock-card',
    label: 'Kartu Stok',
    path: '/kartu-stok',
    icon: BookOpenText,
    roles: ['PGB', 'ATS', 'PWS', 'TSO', 'AUD'],
    phase: 4,
  },
  {
    key: 'opname',
    label: 'Stock Opname',
    path: '/stock-opname',
    icon: ClipboardCheck,
    roles: ['PWS', 'TSO', 'PGB', 'AUD'],
    phase: 5,
  },
  {
    key: 'discrepancies',
    label: 'Penanganan Selisih',
    path: '/selisih',
    icon: TriangleAlert,
    roles: ['PWS', 'PGB', 'TSO', 'AUD'],
    phase: 5,
  },
  {
    key: 'damaged',
    label: 'Barang Rusak/Usang',
    path: '/barang-rusak',
    icon: PackageX,
    roles: ['PGB', 'PWS', 'TSO', 'AUD'],
    phase: 5,
  },
  {
    key: 'reconciliation',
    label: 'Rekonsiliasi',
    path: '/rekonsiliasi',
    icon: Scale,
    // Petugas Akuntansi hanya berperan di modul ini (menyusun rekonsiliasi).
    roles: ['AKT', 'PGB', 'PWS', 'AUD'],
    phase: 5,
  },
  { key: 'reports', label: 'Laporan', path: '/laporan', icon: FileBarChart, roles: ALL_EXCEPT_NONE, phase: 6 },
  {
    key: 'supervision',
    label: 'Pengawasan',
    path: '/pengawasan',
    icon: SearchCheck,
    roles: ['PWS', 'AUD'],
    phase: 5,
  },
  {
    key: 'users',
    label: 'Pengguna dan Role',
    path: '/pengguna',
    icon: Users,
    roles: ['SA', 'AUD'],
    phase: 2,
  },
  {
    key: 'settings',
    label: 'Pengaturan',
    path: '/pengaturan',
    icon: Settings,
    roles: ['SA', 'PWS', 'AUD'],
    phase: 3,
  },
];

export const PROFILE_NAV = { label: 'Profil Saya', path: '/profil', icon: ShieldCheck };

export function visibleNavItems(roles: readonly RoleCode[]): NavItem[] {
  return NAV_ITEMS.filter((item) => hasAnyRole(roles, item.roles));
}

export function findNavItem(path: string): NavItem | undefined {
  return NAV_ITEMS.find((item) => item.path === path);
}
