import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from 'react';
import type { Session } from '@supabase/supabase-js';
import { supabase } from '@/lib/supabase';
import { toUserMessage } from '@/lib/errors';
import { isRoleCode, type RoleCode } from '@/lib/roles';
import type { MyContext } from '@/types/domain';

/**
 * signed_in  : sudah masuk penuh
 * needs_mfa  : password benar, tetapi pengguna punya verifikasi dua langkah
 *              yang harus dimasukkan dulu (kode 6 digit)
 */
type AuthStatus = 'loading' | 'signed_out' | 'needs_mfa' | 'signed_in';
export type AssuranceLevel = 'aal1' | 'aal2';

interface AuthState {
  status: AuthStatus;
  session: Session | null;
  context: MyContext | null;
  roles: RoleCode[];
  /** Tingkat verifikasi sesi saat ini (aal2 = sudah verifikasi dua langkah). */
  aal: AssuranceLevel;
  /** Super Admin yang boleh mengubah data (sudah MFA bila diwajibkan). */
  adminReady: boolean;
  blockedReason: string | null;
  signIn: (email: string, password: string) => Promise<void>;
  signOut: () => Promise<void>;
  refreshContext: () => Promise<void>;
  /** Dipanggil setelah verifikasi dua langkah berhasil. */
  reloadSession: () => Promise<void>;
  hasRole: (...codes: RoleCode[]) => boolean;
}

const AuthContext = createContext<AuthState | null>(null);

async function loadContext(): Promise<MyContext> {
  const { data, error } = await supabase.rpc('rpc_my_context');
  if (error) throw error;
  const ctx = data as MyContext;
  return { ...ctx, roles: (ctx.roles ?? []).filter(isRoleCode), mfa_required: Boolean(ctx.mfa_required) };
}

async function loadAssurance(): Promise<{ current: AssuranceLevel; next: AssuranceLevel }> {
  const { data, error } = await supabase.auth.mfa.getAuthenticatorAssuranceLevel();
  if (error || !data) return { current: 'aal1', next: 'aal1' };
  return {
    current: data.currentLevel === 'aal2' ? 'aal2' : 'aal1',
    next: data.nextLevel === 'aal2' ? 'aal2' : 'aal1',
  };
}

export function AuthProvider({ children }: { children: ReactNode }) {
  const [status, setStatus] = useState<AuthStatus>('loading');
  const [session, setSession] = useState<Session | null>(null);
  const [context, setContext] = useState<MyContext | null>(null);
  const [aal, setAal] = useState<AssuranceLevel>('aal1');
  const [blockedReason, setBlockedReason] = useState<string | null>(null);

  const applySession = useCallback(async (next: Session | null) => {
    setSession(next);
    if (!next) {
      setContext(null);
      setAal('aal1');
      setStatus('signed_out');
      return;
    }
    try {
      const ctx = await loadContext();
      const level = await loadAssurance();
      setContext(ctx);
      setAal(level.current);
      setBlockedReason(null);
      // Punya faktor verifikasi tetapi sesi belum diverifikasi -> minta kode.
      setStatus(level.next === 'aal2' && level.current !== 'aal2' ? 'needs_mfa' : 'signed_in');
    } catch (err) {
      setBlockedReason(toUserMessage(err));
      setContext(null);
      await supabase.auth.signOut();
      setStatus('signed_out');
    }
  }, []);

  useEffect(() => {
    let active = true;
    supabase.auth.getSession().then(({ data }) => {
      if (active) void applySession(data.session);
    });
    const { data: sub } = supabase.auth.onAuthStateChange((event, next) => {
      if (!active) return;
      if (event === 'SIGNED_OUT') {
        setSession(null);
        setContext(null);
        setAal('aal1');
        setStatus('signed_out');
      } else if (event === 'TOKEN_REFRESHED') {
        setSession(next);
      }
    });
    return () => {
      active = false;
      sub.subscription.unsubscribe();
    };
  }, [applySession]);

  const signIn = useCallback(
    async (email: string, password: string) => {
      setBlockedReason(null);
      const { data, error } = await supabase.auth.signInWithPassword({ email: email.trim(), password });
      if (error) throw error;
      await supabase.rpc('rpc_log_auth_event', { p_event: 'LOGIN' });
      await applySession(data.session);
    },
    [applySession],
  );

  const signOut = useCallback(async () => {
    try {
      await supabase.rpc('rpc_log_auth_event', { p_event: 'LOGOUT' });
    } finally {
      await supabase.auth.signOut();
    }
  }, []);

  const refreshContext = useCallback(async () => {
    setContext(await loadContext());
  }, []);

  const reloadSession = useCallback(async () => {
    const { data } = await supabase.auth.getSession();
    await applySession(data.session);
  }, [applySession]);

  const value = useMemo<AuthState>(() => {
    const roles = context?.roles ?? [];
    const isSA = roles.includes('SA');
    return {
      status,
      session,
      context,
      roles,
      aal,
      adminReady: isSA && (!context?.mfa_required || aal === 'aal2'),
      blockedReason,
      signIn,
      signOut,
      refreshContext,
      reloadSession,
      hasRole: (...codes) => codes.some((c) => roles.includes(c)),
    };
  }, [status, session, context, aal, blockedReason, signIn, signOut, refreshContext, reloadSession]);

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}

export function useAuth(): AuthState {
  const ctx = useContext(AuthContext);
  if (!ctx) throw new Error('useAuth harus dipakai di dalam <AuthProvider>.');
  return ctx;
}
