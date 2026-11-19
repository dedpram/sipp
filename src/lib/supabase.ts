import { createClient } from '@supabase/supabase-js';

/**
 * Klien Supabase untuk browser.
 * HANYA memakai URL proyek dan anon/publishable key (aman untuk publik;
 * data tetap dilindungi login + RLS). JANGAN pernah memasukkan
 * service role / secret key ke variabel VITE_*.
 */
const url = import.meta.env.VITE_SUPABASE_URL as string | undefined;
const key = (import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY ?? import.meta.env.VITE_SUPABASE_ANON_KEY) as
  | string
  | undefined;

export const isSupabaseConfigured = Boolean(url && key);

if (key && /service_role|sb_secret_/i.test(key)) {
  throw new Error('Kunci rahasia (service role/secret) terdeteksi di konfigurasi frontend. Hentikan dan ganti kunci.');
}

export const supabase = createClient(url ?? 'http://localhost:54321', key ?? 'missing-key', {
  auth: {
    flowType: 'pkce',
    persistSession: true,
    autoRefreshToken: true,
    detectSessionInUrl: true,
    storageKey: 'sipp-auth',
  },
});
