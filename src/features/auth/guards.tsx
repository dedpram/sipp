import type { ReactNode } from 'react';
import { Navigate, useLocation } from 'react-router';
import { hasAnyRole, type RoleCode } from '@/lib/roles';
import { FullPageLoading, ForbiddenState } from '@/components/feedback/States';
import { useAuth } from './AuthProvider';
import MfaChallengePage from './MfaChallengePage';

/** Halaman hanya untuk pengguna yang sudah masuk. */
export function RequireAuth({ children }: { children: ReactNode }) {
  const { status } = useAuth();
  const location = useLocation();
  if (status === 'loading') return <FullPageLoading />;
  if (status === 'signed_out') return <Navigate to="/masuk" replace state={{ from: location.pathname }} />;
  if (status === 'needs_mfa') return <MfaChallengePage />;
  return <>{children}</>;
}

/**
 * Pembatas tampilan berdasarkan role. Ini hanya kenyamanan UI —
 * pembatasan sesungguhnya dilakukan RLS di database.
 */
export function RequireRole({ roles, children }: { roles: readonly RoleCode[] | 'all'; children: ReactNode }) {
  const { roles: mine } = useAuth();
  if (!hasAnyRole(mine, roles)) return <ForbiddenState />;
  return <>{children}</>;
}
