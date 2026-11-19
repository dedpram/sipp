import type { ReactNode } from 'react';
import { Inbox, Loader2, ShieldAlert, ServerCrash, Hammer } from 'lucide-react';
import { Button } from '@/components/ui/Button';

export function LoadingState({ label = 'Memuat data…' }: { label?: string }) {
  return (
    <div className="flex items-center justify-center gap-2 py-12 text-sm text-slate-500" role="status">
      <Loader2 className="h-5 w-5 animate-spin" aria-hidden />
      {label}
    </div>
  );
}

export function FullPageLoading() {
  return (
    <div className="flex min-h-screen items-center justify-center">
      <LoadingState label="Menyiapkan aplikasi…" />
    </div>
  );
}

export function EmptyState({ title = 'Belum ada data', description, action }: { title?: string; description?: string; action?: ReactNode }) {
  return (
    <div className="flex flex-col items-center justify-center gap-2 py-12 text-center">
      <Inbox className="h-10 w-10 text-slate-300" aria-hidden />
      <p className="font-medium text-slate-700">{title}</p>
      {description && <p className="max-w-md text-sm text-slate-500">{description}</p>}
      {action}
    </div>
  );
}

export function ErrorState({ message, onRetry }: { message: string; onRetry?: () => void }) {
  return (
    <div className="flex flex-col items-center justify-center gap-2 py-12 text-center" role="alert">
      <ServerCrash className="h-10 w-10 text-red-300" aria-hidden />
      <p className="font-medium text-slate-700">Data gagal dimuat</p>
      <p className="max-w-md text-sm text-slate-500">{message}</p>
      {onRetry && (
        <Button variant="secondary" size="sm" onClick={onRetry}>
          Coba lagi
        </Button>
      )}
    </div>
  );
}

export function ForbiddenState() {
  return (
    <div className="flex flex-col items-center justify-center gap-2 py-16 text-center">
      <ShieldAlert className="h-10 w-10 text-amber-400" aria-hidden />
      <p className="font-medium text-slate-700">Akses tidak diizinkan</p>
      <p className="max-w-md text-sm text-slate-500">Role Anda tidak memiliki kewenangan untuk membuka halaman ini.</p>
    </div>
  );
}

export function ComingSoonState({ title, phase }: { title: string; phase: number }) {
  return (
    <div className="flex flex-col items-center justify-center gap-2 py-16 text-center">
      <Hammer className="h-10 w-10 text-green-300" aria-hidden />
      <p className="font-medium text-slate-700">Modul {title} sedang dibangun</p>
      <p className="max-w-md text-sm text-slate-500">Modul ini dijadwalkan pada Fase {phase} sesuai roadmap pengembangan.</p>
    </div>
  );
}
