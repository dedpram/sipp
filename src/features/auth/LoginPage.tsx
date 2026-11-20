import { useState } from 'react';
import { Navigate, useLocation, useNavigate } from 'react-router';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { z } from 'zod';
import { Eye, EyeOff, LogIn, PackageCheck } from 'lucide-react';
import { Button } from '@/components/ui/Button';
import { Field, Input } from '@/components/ui/Input';
import { Alert } from '@/components/ui/Alert';
import { isSupabaseConfigured } from '@/lib/supabase';
import { toUserMessage } from '@/lib/errors';
import { useAuth } from './AuthProvider';

const schema = z.object({
  email: z.string().trim().min(1, 'Email wajib diisi.').email('Format email tidak valid.'),
  password: z.string().min(1, 'Password wajib diisi.'),
});
type FormValues = z.infer<typeof schema>;

export default function LoginPage() {
  const { status, signIn, blockedReason } = useAuth();
  const navigate = useNavigate();
  const location = useLocation();
  const [error, setError] = useState<string | null>(null);
  const [showPassword, setShowPassword] = useState(false);

  const {
    register,
    handleSubmit,
    formState: { errors, isSubmitting },
  } = useForm<FormValues>({ resolver: zodResolver(schema) });

  if (status === 'signed_in' || status === 'needs_mfa') {
    const from = (location.state as { from?: string } | null)?.from ?? '/';
    return <Navigate to={from} replace />;
  }

  const onSubmit = handleSubmit(async (values) => {
    setError(null);
    try {
      await signIn(values.email, values.password);
      navigate('/', { replace: true });
    } catch (err) {
      setError(toUserMessage(err));
    }
  });

  return (
    <div className="flex min-h-screen items-center justify-center bg-gradient-to-br from-green-50 via-white to-slate-50 px-4">
      <div className="w-full max-w-md">
        <div className="mb-6 flex flex-col items-center text-center">
          <div className="mb-3 flex h-14 w-14 items-center justify-center rounded-2xl bg-green-700 text-white shadow-sm">
            <PackageCheck className="h-8 w-8" aria-hidden />
          </div>
          <h1 className="text-2xl font-bold text-slate-900">SIPP</h1>
          <p className="text-sm text-slate-600">Sistem Informasi Pengelolaan Persediaan</p>
        </div>

        <form onSubmit={onSubmit} className="space-y-4 rounded-2xl border border-slate-200 bg-white p-6 shadow-sm" noValidate>
          <h2 className="text-lg font-semibold">Masuk</h2>

          {!isSupabaseConfigured && (
            <Alert tone="warning">
              Konfigurasi Supabase belum diisi. Salin <code>.env.example</code> menjadi <code>.env.local</code> lalu isi
              URL dan kunci publik Supabase.
            </Alert>
          )}
          {(error ?? blockedReason) && <Alert tone="danger">{error ?? blockedReason}</Alert>}

          <Field label="Email" error={errors.email?.message} htmlFor="email">
            <Input id="email" type="email" autoComplete="username" placeholder="nama@instansi.go.id" {...register('email')} />
          </Field>

          <Field label="Password" error={errors.password?.message} htmlFor="password">
            <div className="relative">
              <Input
                id="password"
                type={showPassword ? 'text' : 'password'}
                autoComplete="current-password"
                className="pr-10"
                {...register('password')}
              />
              <button
                type="button"
                onClick={() => setShowPassword((v) => !v)}
                className="absolute inset-y-0 right-0 flex items-center px-3 text-slate-500 hover:text-slate-700"
                aria-label={showPassword ? 'Sembunyikan password' : 'Tampilkan password'}
              >
                {showPassword ? <EyeOff className="h-4 w-4" /> : <Eye className="h-4 w-4" />}
              </button>
            </div>
          </Field>

          <Button type="submit" className="w-full" loading={isSubmitting} icon={LogIn}>
            Masuk
          </Button>

          <p className="text-center text-xs text-slate-500">
            Lupa password? Hubungi Super Admin satuan kerja Anda.
          </p>
        </form>
      </div>
    </div>
  );
}
