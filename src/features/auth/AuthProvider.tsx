import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from 'react';
import type { Session } from '@supabase/supabase-js';
import { supabase } from '@/lib/supabase';
import { toUserMessage } from '@/lib/errors';
import { isRoleCode, type RoleCode } from '@/lib/roles';
import type { MyContext } from '@/types/domain';

type AuthStatus = 'loading' | 'signed_out' | 'signed_in';

interface AuthState {
  status: AuthStatus;
  session: Session | null;
  context: MyContext | null;
  roles: RoleCode[];
  /** Pesan ketika sesi ditolak (mis. akun nonaktif / belum punya profil). */
  blockedReason: string | null;
  signIn: (email: string, password: string) => Promise<void>;
  signOut: () => Promise<void>;
  refreshContext: () => Promise<void>;
  hasRole: (...codes: RoleCode[]) => boolean;
}

const AuthContext = createContext<AuthState | null>(null);

async function loadContext(): Promise<MyContext> {
  const { data, error } = await supabase.rpc('rpc_my_context');
  if (error) throw error;
  const ctx = data as MyContext;
  return { ...ctx, roles: (ctx.roles ?? []).filter(isRoleCode) };
}

export function AuthProvider({ children }: { children: ReactNode }) {
  const [status, setStatus] = useState<AuthStatus>('loading');
  const [session, setSession] = useState<Session | null>(null);
  const [context, setContext] = useState<MyContext | null>(null);
  const [blockedReason, setBlockedReason] = useState<string | null>(null);

  const applySession = useCallback(async (next: Session | null) => {
    setSession(next);
    if (!next) {
      setContext(null);
      setStatus('signed_out');
      return;
    }
    try {
      const ctx = await loadContext();
      setContext(ctx);
      setBlockedReason(null);
      setStatus('signed_in');
    } catch (err) {
      // Akun nonaktif / profil tidak ada: keluarkan dari sesi.
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
      // Catat login di audit trail (identitas diambil dari token di database).
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
    const ctx = await loadContext();
    setContext(ctx);
  }, []);

  const value = useMemo<AuthState>(() => {
    const roles = context?.roles ?? [];
    return {
      status,
      session,
      context,
      roles,
      blockedReason,
      signIn,
      signOut,
      refreshContext,
      hasRole: (...codes) => codes.some((c) => roles.includes(c)),
    };
  }, [status, session, context, blockedReason, signIn, signOut, refreshContext]);

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}

export function useAuth(): AuthState {
  const ctx = useContext(AuthContext);
  if (!ctx) throw new Error('useAuth harus dipakai di dalam <AuthProvider>.');
  return ctx;
}
