import { useState } from 'react';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { z } from 'zod';
import { KeyRound, Save } from 'lucide-react';
import { PageHeader } from '@/components/layout/AppShell';
import { Card } from '@/components/ui/Card';
import { Button } from '@/components/ui/Button';
import { Field, Input } from '@/components/ui/Input';
import { Badge } from '@/components/ui/Badge';
import { useToast } from '@/components/ui/Toast';
import { useAuth } from '@/features/auth/AuthProvider';
import { passwordSchema } from '@/features/users/schema';
import { supabase } from '@/lib/supabase';
import { toUserMessage } from '@/lib/errors';
import { ROLE_LABELS } from '@/lib/roles';
import { MfaCard } from './MfaCard';

const phoneSchema = z.object({
  phone: z.string().trim().max(20, 'Maksimal 20 karakter.').regex(/^[0-9+\-\s]*$/, 'Hanya angka, spasi, + atau -.'),
});

const passwordFormSchema = z
  .object({ password: passwordSchema, password_confirm: z.string() })
  .refine((v) => v.password === v.password_confirm, { message: 'Konfirmasi password tidak sama.', path: ['password_confirm'] });

export default function ProfilePage() {
  const { context, roles, refreshContext } = useAuth();
  const toast = useToast();
  const [savingPhone, setSavingPhone] = useState(false);

  const phoneForm = useForm<z.infer<typeof phoneSchema>>({ resolver: zodResolver(phoneSchema), defaultValues: { phone: context?.profile.phone ?? '' } });
  const pwForm = useForm<z.infer<typeof passwordFormSchema>>({ resolver: zodResolver(passwordFormSchema) });

  const savePhone = phoneForm.handleSubmit(async ({ phone }) => {
    if (!context) return;
    setSavingPhone(true);
    const { error } = await supabase.from('profiles').update({ phone: phone || null }).eq('id', context.profile.id);
    setSavingPhone(false);
    if (error) toast.error(toUserMessage(error));
    else {
      toast.success('Nomor telepon disimpan.');
      void refreshContext();
    }
  });

  const savePassword = pwForm.handleSubmit(async ({ password }) => {
    const { error } = await supabase.auth.updateUser({ password });
    if (error) toast.error(toUserMessage(error));
    else {
      toast.success('Password berhasil diganti.');
      pwForm.reset({ password: '', password_confirm: '' });
    }
  });

  if (!context) return null;
  const p = context.profile;

  return (
    <>
      <PageHeader title="Profil Saya" description="Data identitas dikelola oleh Super Admin. Anda dapat mengubah nomor telepon dan password." />
      <div className="grid grid-cols-1 gap-4 lg:grid-cols-2">
        <Card title="Identitas">
          <dl className="grid grid-cols-3 gap-y-2 text-sm">
            <dt className="text-slate-500">Nama</dt>
            <dd className="col-span-2 font-medium">{p.full_name}</dd>
            <dt className="text-slate-500">NIP</dt>
            <dd className="col-span-2">{p.nip ?? '-'}</dd>
            <dt className="text-slate-500">Email</dt>
            <dd className="col-span-2">{p.email}</dd>
            <dt className="text-slate-500">Jabatan</dt>
            <dd className="col-span-2">{p.position_title ?? '-'}</dd>
            <dt className="text-slate-500">Unit kerja</dt>
            <dd className="col-span-2">{p.primary_unit_name ?? '-'}</dd>
            <dt className="text-slate-500">Role</dt>
            <dd className="col-span-2 flex flex-wrap gap-1">
              {roles.length ? roles.map((r) => <Badge key={r} tone="success">{ROLE_LABELS[r]}</Badge>) : '-'}
            </dd>
          </dl>
          <form onSubmit={savePhone} className="mt-4 flex items-end gap-2 border-t border-slate-100 pt-4">
            <div className="flex-1">
              <Field label="Nomor telepon" error={phoneForm.formState.errors.phone?.message} htmlFor="pf-phone">
                <Input id="pf-phone" inputMode="tel" {...phoneForm.register('phone')} />
              </Field>
            </div>
            <Button type="submit" icon={Save} loading={savingPhone}>Simpan</Button>
          </form>
        </Card>

        <Card title="Ganti Password">
          <form onSubmit={savePassword} className="space-y-4">
            <Field label="Password baru" required hint="Min. 12 karakter, huruf besar, huruf kecil, angka" error={pwForm.formState.errors.password?.message} htmlFor="pf-pw">
              <Input id="pf-pw" type="password" autoComplete="new-password" {...pwForm.register('password')} />
            </Field>
            <Field label="Ulangi password baru" required error={pwForm.formState.errors.password_confirm?.message} htmlFor="pf-pw2">
              <Input id="pf-pw2" type="password" autoComplete="new-password" {...pwForm.register('password_confirm')} />
            </Field>
            <Button type="submit" icon={KeyRound} loading={pwForm.formState.isSubmitting}>Ganti Password</Button>
          </form>
        </Card>

        <MfaCard />
      </div>
    </>
  );
}
