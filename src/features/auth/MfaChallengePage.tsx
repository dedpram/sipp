import { useEffect, useState } from 'react';
import { LogOut, ShieldCheck } from 'lucide-react';
import { Button } from '@/components/ui/Button';
import { Field, Input } from '@/components/ui/Input';
import { Alert } from '@/components/ui/Alert';
import { listVerifiedTotp, verifyCode } from '@/lib/mfa';
import { toUserMessage } from '@/lib/errors';
import { useAuth } from './AuthProvider';

/** Langkah kedua login: memasukkan kode 6 digit dari aplikasi autentikator. */
export default function MfaChallengePage() {
  const { reloadSession, signOut, context } = useAuth();
  const [factorId, setFactorId] = useState<string | null>(null);
  const [code, setCode] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    listVerifiedTotp()
      .then((f) => setFactorId(f[0]?.id ?? null))
      .catch((err) => setError(toUserMessage(err)));
  }, []);

  const submit = async (e: { preventDefault: () => void }) => {
    e.preventDefault();
    if (!factorId) return;
    setBusy(true);
    setError(null);
    try {
      await verifyCode(factorId, code);
      await reloadSession();
    } catch (err) {
      setError(toUserMessage(err));
      setCode('');
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="flex min-h-screen items-center justify-center bg-gradient-to-br from-green-50 via-white to-slate-50 px-4">
      <form onSubmit={submit} className="w-full max-w-sm space-y-4 rounded-2xl border border-slate-200 bg-white p-6 shadow-sm">
        <div className="flex flex-col items-center text-center">
          <div className="mb-2 flex h-12 w-12 items-center justify-center rounded-xl bg-green-700 text-white">
            <ShieldCheck className="h-7 w-7" aria-hidden />
          </div>
          <h1 className="text-lg font-semibold">Verifikasi dua langkah</h1>
          <p className="text-sm text-slate-600">
            {context?.profile.full_name ? `${context.profile.full_name}, b` : 'B'}uka aplikasi autentikator di HP Anda,
            lalu masukkan kode 6 digit untuk SIPP.
          </p>
        </div>
        {error && <Alert tone="danger">{error}</Alert>}
        <Field label="Kode verifikasi" htmlFor="mfa-code">
          <Input
            id="mfa-code"
            inputMode="numeric"
            autoComplete="one-time-code"
            maxLength={7}
            autoFocus
            value={code}
            onChange={(e) => setCode(e.target.value)}
            className="text-center text-lg tracking-[0.4em]"
            placeholder="000000"
          />
        </Field>
        <Button type="submit" className="w-full" loading={busy} disabled={!factorId || code.replace(/\s/g, '').length !== 6}>
          Verifikasi
        </Button>
        <Button variant="ghost" className="w-full" icon={LogOut} onClick={() => void signOut()}>
          Batal dan keluar
        </Button>
        <p className="text-center text-xs text-slate-500">
          HP hilang atau aplikasi autentikator terhapus? Hubungi Super Admin lain atau pengelola Supabase.
        </p>
      </form>
    </div>
  );
}
