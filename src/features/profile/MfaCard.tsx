import { useCallback, useEffect, useState } from 'react';
import { ShieldCheck, ShieldOff, Smartphone } from 'lucide-react';
import { Card } from '@/components/ui/Card';
import { Button } from '@/components/ui/Button';
import { Field, Input } from '@/components/ui/Input';
import { Alert } from '@/components/ui/Alert';
import { Badge } from '@/components/ui/Badge';
import { ConfirmDialog } from '@/components/ui/Modal';
import { useToast } from '@/components/ui/Toast';
import { useAuth } from '@/features/auth/AuthProvider';
import { listVerifiedTotp, removeFactor, startEnrollment, verifyCode, type Enrollment, type VerifiedFactor } from '@/lib/mfa';
import { toUserMessage } from '@/lib/errors';
import { formatDateTime } from '@/lib/format';

/** Pengaturan verifikasi dua langkah di menu Profil Saya. */
export function MfaCard() {
  const { context, aal, reloadSession } = useAuth();
  const toast = useToast();
  const [factors, setFactors] = useState<VerifiedFactor[] | null>(null);
  const [enrollment, setEnrollment] = useState<Enrollment | null>(null);
  const [code, setCode] = useState('');
  const [busy, setBusy] = useState(false);
  const [confirmRemove, setConfirmRemove] = useState(false);

  const load = useCallback(async () => {
    try {
      setFactors(await listVerifiedTotp());
    } catch (err) {
      toast.error(toUserMessage(err));
    }
  }, [toast]);

  useEffect(() => {
    void load();
  }, [load]);

  const begin = async () => {
    setBusy(true);
    try {
      setEnrollment(await startEnrollment());
      setCode('');
    } catch (err) {
      toast.error(toUserMessage(err));
    } finally {
      setBusy(false);
    }
  };

  const finish = async () => {
    if (!enrollment) return;
    setBusy(true);
    try {
      await verifyCode(enrollment.factorId, code);
      toast.success('Verifikasi dua langkah aktif. Mulai sekarang login memerlukan kode dari HP Anda.');
      setEnrollment(null);
      await load();
      await reloadSession();
    } catch (err) {
      toast.error(toUserMessage(err));
    } finally {
      setBusy(false);
    }
  };

  const remove = async () => {
    const f = factors?.[0];
    if (!f) return;
    setBusy(true);
    try {
      await removeFactor(f.id);
      toast.success('Verifikasi dua langkah dinonaktifkan.');
      setConfirmRemove(false);
      await load();
      await reloadSession();
    } catch (err) {
      toast.error(toUserMessage(err));
    } finally {
      setBusy(false);
    }
  };

  const active = (factors?.length ?? 0) > 0;
  const required = Boolean(context?.mfa_required);

  return (
    <Card
      title={
        <span className="inline-flex items-center gap-2">
          <Smartphone className="h-4 w-4" /> Verifikasi Dua Langkah
        </span>
      }
      className="lg:col-span-2"
    >
      {factors === null ? (
        <p className="text-sm text-slate-500">Memeriksa status…</p>
      ) : active ? (
        <div className="space-y-3">
          <div className="flex flex-wrap items-center gap-2">
            <Badge tone="success">Aktif</Badge>
            <span className="text-sm text-slate-600">Didaftarkan {formatDateTime(factors[0]!.created_at)}</span>
            {aal === 'aal2' && <Badge tone="process">Sesi ini sudah terverifikasi</Badge>}
          </div>
          <p className="text-sm text-slate-600">
            Setiap kali masuk, Anda diminta kode 6 digit dari aplikasi autentikator di HP.
          </p>
          {!required && (
            <Button variant="secondary" size="sm" icon={ShieldOff} onClick={() => setConfirmRemove(true)}>
              Nonaktifkan
            </Button>
          )}
          {required && (
            <p className="text-xs text-slate-500">Role Super Admin wajib memakai verifikasi dua langkah, sehingga tidak dapat dinonaktifkan.</p>
          )}
        </div>
      ) : enrollment ? (
        <div className="grid gap-4 sm:grid-cols-[auto,1fr]">
          <div className="flex flex-col items-center gap-2">
            <img src={enrollment.qrCode} alt="Kode QR verifikasi dua langkah" className="h-44 w-44 rounded-lg border border-slate-200 bg-white p-2" />
            <p className="max-w-[11rem] break-all text-center font-mono text-[11px] text-slate-500">{enrollment.secret}</p>
          </div>
          <div className="space-y-3 text-sm">
            <ol className="list-decimal space-y-1 pl-5 text-slate-700">
              <li>Pasang aplikasi <b>Google Authenticator</b> atau <b>Microsoft Authenticator</b> di HP.</li>
              <li>Di aplikasi, pilih tambah akun lalu <b>pindai kode QR</b> di samping. Bila tidak bisa memindai, ketik kode huruf di bawah gambar.</li>
              <li>Masukkan kode 6 digit yang muncul di aplikasi, lalu klik <b>Aktifkan</b>.</li>
            </ol>
            <Field label="Kode 6 digit" htmlFor="mfa-enroll-code">
              <Input
                id="mfa-enroll-code"
                inputMode="numeric"
                autoComplete="one-time-code"
                maxLength={7}
                value={code}
                onChange={(e) => setCode(e.target.value)}
                className="max-w-[12rem] text-center tracking-[0.3em]"
              />
            </Field>
            <div className="flex gap-2">
              <Button onClick={() => void finish()} loading={busy} icon={ShieldCheck} disabled={code.replace(/\s/g, '').length !== 6}>
                Aktifkan
              </Button>
              <Button variant="secondary" onClick={() => setEnrollment(null)} disabled={busy}>
                Batal
              </Button>
            </div>
          </div>
        </div>
      ) : (
        <div className="space-y-3">
          {required ? (
            <Alert tone="warning">
              Sebagai Super Admin, Anda <b>wajib</b> mengaktifkan verifikasi dua langkah. Sebelum aktif, Anda hanya dapat
              melihat data dan belum dapat mengubah pengguna, role, master data, atau pengaturan.
            </Alert>
          ) : (
            <p className="text-sm text-slate-600">
              Lindungi akun Anda dengan kode tambahan dari HP setiap kali masuk. Disarankan untuk semua pengguna.
            </p>
          )}
          <Button icon={ShieldCheck} onClick={() => void begin()} loading={busy}>
            Mulai aktifkan
          </Button>
        </div>
      )}

      <ConfirmDialog
        open={confirmRemove}
        title="Nonaktifkan verifikasi dua langkah?"
        message="Akun Anda hanya akan dilindungi password."
        tone="danger"
        confirmLabel="Nonaktifkan"
        loading={busy}
        onCancel={() => setConfirmRemove(false)}
        onConfirm={() => void remove()}
      />
    </Card>
  );
}
