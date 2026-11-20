import { useEffect, useRef, useState, type ReactNode } from 'react';
import { NavLink, Outlet, useLocation, useNavigate } from 'react-router';
import { ChevronDown, LogOut, Menu, PackageCheck, UserRound, X } from 'lucide-react';
import { PROFILE_NAV, visibleNavItems } from '@/app/navigation';
import { useAuth } from '@/features/auth/AuthProvider';
import { ROLE_LABELS } from '@/lib/roles';
import { useToast } from '@/components/ui/Toast';
import { toUserMessage } from '@/lib/errors';
import { cn } from '@/lib/cn';

function Sidebar({ onNavigate }: { onNavigate?: () => void }) {
  const { roles } = useAuth();
  const items = visibleNavItems(roles);
  return (
    <nav className="flex h-full flex-col" aria-label="Menu utama">
      <div className="flex h-16 items-center gap-2 border-b border-green-800/40 px-4">
        <PackageCheck className="h-7 w-7 text-white" aria-hidden />
        <div className="leading-tight">
          <p className="font-bold text-white">SIPP</p>
          <p className="text-[11px] text-green-100">Pengelolaan Persediaan</p>
        </div>
      </div>
      <ul className="flex-1 space-y-0.5 overflow-y-auto p-2">
        {items.map((item) => (
          <li key={item.key}>
            <NavLink
              to={item.path}
              end={item.path === '/'}
              onClick={onNavigate}
              className={({ isActive }) =>
                cn(
                  'flex items-center gap-3 rounded-lg px-3 py-2 text-sm transition-colors',
                  isActive ? 'bg-white text-green-800 font-semibold shadow-sm' : 'text-green-50 hover:bg-green-800',
                )
              }
            >
              <item.icon className="h-4 w-4 shrink-0" aria-hidden />
              <span className="truncate">{item.label}</span>
            </NavLink>
          </li>
        ))}
      </ul>
    </nav>
  );
}

function UserMenu() {
  const { context, roles, signOut } = useAuth();
  const toast = useToast();
  const navigate = useNavigate();
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const onClick = (e: MouseEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node)) setOpen(false);
    };
    document.addEventListener('mousedown', onClick);
    return () => document.removeEventListener('mousedown', onClick);
  }, []);

  const name = context?.profile.full_name ?? '';
  const initials = name
    .split(' ')
    .filter(Boolean)
    .slice(0, 2)
    .map((s) => s[0]?.toUpperCase())
    .join('');

  const handleLogout = async () => {
    try {
      await signOut();
      navigate('/masuk', { replace: true });
    } catch (err) {
      toast.error(toUserMessage(err));
    }
  };

  return (
    <div className="relative" ref={ref}>
      <button
        onClick={() => setOpen((v) => !v)}
        className="flex items-center gap-2 rounded-lg px-2 py-1.5 hover:bg-slate-100"
        aria-haspopup="menu"
        aria-expanded={open}
      >
        <span className="flex h-8 w-8 items-center justify-center rounded-full bg-green-700 text-xs font-semibold text-white">
          {initials || <UserRound className="h-4 w-4" />}
        </span>
        <span className="hidden text-left sm:block">
          <span className="block max-w-[180px] truncate text-sm font-medium text-slate-800">{name}</span>
          <span className="block max-w-[180px] truncate text-xs text-slate-500">
            {roles.map((r) => ROLE_LABELS[r]).join(', ') || 'Belum memiliki role'}
          </span>
        </span>
        <ChevronDown className="h-4 w-4 text-slate-500" aria-hidden />
      </button>
      {open && (
        <div role="menu" className="absolute right-0 z-40 mt-1 w-56 rounded-lg border border-slate-200 bg-white py-1 shadow-lg">
          <NavLink
            to={PROFILE_NAV.path}
            role="menuitem"
            onClick={() => setOpen(false)}
            className="flex items-center gap-2 px-3 py-2 text-sm text-slate-700 hover:bg-slate-50"
          >
            <PROFILE_NAV.icon className="h-4 w-4" /> {PROFILE_NAV.label}
          </NavLink>
          <button role="menuitem" onClick={handleLogout} className="flex w-full items-center gap-2 px-3 py-2 text-sm text-red-600 hover:bg-red-50">
            <LogOut className="h-4 w-4" /> Keluar
          </button>
        </div>
      )}
    </div>
  );
}

/** Pengingat bagi Super Admin yang belum memakai verifikasi dua langkah. */
function MfaBanner() {
  const { hasRole, adminReady } = useAuth();
  if (!hasRole('SA') || adminReady) return null;
  return (
    <div className="mb-4 flex flex-col gap-2 rounded-lg border border-amber-200 bg-amber-50 p-3 text-sm text-amber-900 sm:flex-row sm:items-center sm:justify-between">
      <span>
        <b>Verifikasi dua langkah belum aktif.</b> Super Admin hanya dapat melihat data sampai verifikasi dua langkah
        diaktifkan dan dipakai saat masuk.
      </span>
      <NavLink to={PROFILE_NAV.path} className="shrink-0 rounded-md bg-amber-600 px-3 py-1.5 text-center font-medium text-white hover:bg-amber-700">
        Aktifkan sekarang
      </NavLink>
    </div>
  );
}

export function AppShell() {
  const [drawer, setDrawer] = useState(false);
  const location = useLocation();
  useEffect(() => setDrawer(false), [location.pathname]);

  return (
    <div className="min-h-screen bg-slate-50">
      {/* Sidebar desktop */}
      <aside className="fixed inset-y-0 left-0 hidden w-64 bg-green-700 lg:block">
        <Sidebar />
      </aside>

      {/* Drawer tablet/HP */}
      {drawer && (
        <div className="fixed inset-0 z-40 lg:hidden">
          <div className="absolute inset-0 bg-slate-900/40" onClick={() => setDrawer(false)} aria-hidden />
          <aside className="absolute inset-y-0 left-0 w-72 bg-green-700 shadow-xl">
            <button className="absolute right-2 top-4 rounded p-1 text-white hover:bg-green-800" onClick={() => setDrawer(false)} aria-label="Tutup menu">
              <X className="h-5 w-5" />
            </button>
            <Sidebar onNavigate={() => setDrawer(false)} />
          </aside>
        </div>
      )}

      <div className="lg:pl-64">
        <header className="sticky top-0 z-30 flex h-16 items-center justify-between gap-2 border-b border-slate-200 bg-white/95 px-4 backdrop-blur">
          <div className="flex items-center gap-2">
            <button className="rounded-lg p-2 hover:bg-slate-100 lg:hidden" onClick={() => setDrawer(true)} aria-label="Buka menu">
              <Menu className="h-5 w-5" />
            </button>
            <p className="hidden font-semibold text-slate-800 sm:block">Sistem Informasi Pengelolaan Persediaan</p>
            <p className="font-semibold text-slate-800 sm:hidden">SIPP</p>
          </div>
          <UserMenu />
        </header>
        <main className="mx-auto max-w-7xl p-4 sm:p-6">
          <MfaBanner />
          <Outlet />
        </main>
      </div>
    </div>
  );
}

export function PageHeader({ title, description, actions }: { title: string; description?: string; actions?: ReactNode }) {
  return (
    <div className="mb-5 flex flex-col gap-3 sm:flex-row sm:items-end sm:justify-between">
      <div>
        <h1 className="text-xl font-bold text-slate-900 sm:text-2xl">{title}</h1>
        {description && <p className="mt-1 text-sm text-slate-500">{description}</p>}
      </div>
      {actions && <div className="flex flex-wrap gap-2">{actions}</div>}
    </div>
  );
}
