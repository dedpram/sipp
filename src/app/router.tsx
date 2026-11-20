import { lazy, Suspense, type ReactNode } from 'react';
import { createHashRouter, Navigate, RouterProvider } from 'react-router';
import { AppShell } from '@/components/layout/AppShell';
import { LoadingState } from '@/components/feedback/States';
import { RequireAuth, RequireRole } from '@/features/auth/guards';
import { NAV_ITEMS, type NavItem } from './navigation';

const LoginPage = lazy(() => import('@/features/auth/LoginPage'));
const DashboardPage = lazy(() => import('@/features/dashboard/DashboardPage'));
const UsersPage = lazy(() => import('@/features/users/UsersPage'));
const ProfilePage = lazy(() => import('@/features/profile/ProfilePage'));
const MasterDataPage = lazy(() => import('@/features/master/MasterDataPage'));
const SettingsPage = lazy(() => import('@/features/settings/SettingsPage'));
const ModulePlaceholderPage = lazy(() => import('@/features/placeholder/ModulePlaceholderPage'));

const lazyPage = (node: ReactNode) => <Suspense fallback={<LoadingState />}>{node}</Suspense>;

/** Halaman yang sudah selesai dibangun. Modul lain memakai placeholder sesuai fasenya. */
const IMPLEMENTED: Record<string, () => ReactNode> = {
  dashboard: () => <DashboardPage />,
  users: () => <UsersPage />,
  master: () => <MasterDataPage />,
  settings: () => <SettingsPage />,
};

function routeFor(item: NavItem) {
  const page = IMPLEMENTED[item.key]?.() ?? <ModulePlaceholderPage item={item} />;
  const element = lazyPage(<RequireRole roles={item.roles}>{page}</RequireRole>);
  return item.path === '/' ? { index: true, element } : { path: item.path.slice(1), element };
}

/**
 * HashRouter dipakai agar halaman tetap dapat dibuka setelah refresh di
 * GitHub Pages (URL berbentuk https://.../sipp/#/pengguna).
 */
export const router = createHashRouter([
  { path: '/masuk', element: lazyPage(<LoginPage />) },
  {
    path: '/',
    element: (
      <RequireAuth>
        <AppShell />
      </RequireAuth>
    ),
    children: [
      ...NAV_ITEMS.map(routeFor),
      { path: 'profil', element: lazyPage(<ProfilePage />) },
      { path: '*', element: <Navigate to="/" replace /> },
    ],
  },
]);

export function AppRouter() {
  return <RouterProvider router={router} />;
}
