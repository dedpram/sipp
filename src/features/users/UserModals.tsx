import { useEffect } from 'react';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { useMutation, useQueryClient } from '@tanstack/react-query';
import { Modal } from '@/components/ui/Modal';
import { Button } from '@/components/ui/Button';
import { Field, Input, Select } from '@/components/ui/Input';
import { Alert } from '@/components/ui/Alert';
import { useToast } from '@/components/ui/Toast';
import { toUserMessage } from '@/lib/errors';
import { ROLE_LABELS, UNIT_SCOPED_ROLES, type RoleCode } from '@/lib/roles';
import type { OrganizationalUnit, Role } from '@/types/domain';
import { adminCreateUser, adminResetPassword, assignRole, updateProfile, type UserRow } from './api';
import {
  assignRoleSchema,
  createUserSchema,
  editProfileSchema,
  passwordSchema,
  type AssignRoleForm,
  type AssignRoleValues,
  type CreateUserForm,
  type CreateUserValues,
  type EditProfileForm,
  type EditProfileValues,
} from './schema';
import { z } from 'zod';

const todayJakarta = () => new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Jakarta' }).format(new Date());

function UnitOptions({ units }: { units: OrganizationalUnit[] }) {
  return (
    <>
      <option value="">— Pilih unit kerja —</option>
      {units
        .filter((u) => u.is_active)
        .map((u) => (
          <option key={u.id} value={u.id}>
            {u.name} ({u.code})
          </option>
        ))}
    </>
  );
}

// ---------------------------------------------------------------------
export function CreateUserModal({ open, onClose, units }: { open: boolean; onClose: () => void; units: OrganizationalUnit[] }) {
  const toast = useToast();
  const qc = useQueryClient();
  const form = useForm<CreateUserForm, unknown, CreateUserValues>({
    resolver: zodResolver(createUserSchema),
    defaultValues: { full_name: '', email: '', nip: '', position_title: '', primary_unit_id: '', password: '', password_confirm: '' },
  });
  useEffect(() => {
    if (open) form.reset();
  }, [open, form]);

  const mutation = useMutation({
    mutationFn: (v: CreateUserValues) =>
      adminCreateUser({
        email: v.email,
        password: v.password,
        full_name: v.full_name,
        nip: v.nip,
        position_title: v.position_title,
        primary_unit_id: v.primary_unit_id,
      }),
    onSuccess: () => {
      toast.success('Akun pengguna berhasil dibuat. Tetapkan role untuk pengguna tersebut.');
      void qc.invalidateQueries({ queryKey: ['users-bundle'] });
      onClose();
    },
    onError: (err) => toast.error(toUserMessage(err)),
  });

  const { register, formState: { errors } } = form;
  return (
    <Modal
      open={open}
      onClose={onClose}
      title="Tambah Pengguna"
      size="lg"
      footer={
        <>
          <Button variant="secondary" onClick={onClose}>Batal</Button>
          <Button onClick={form.handleSubmit((v) => mutation.mutate(v))} loading={mutation.isPending}>Simpan</Button>
        </>
      }
    >
      <Alert tone="info">
        Sampaikan password awal kepada pengguna secara langsung/terpisah, lalu minta pengguna menggantinya di menu Profil Saya.
      </Alert>
      <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
        <Field label="Nama lengkap" required error={errors.full_name?.message} htmlFor="cu-name">
          <Input id="cu-name" {...register('full_name')} />
        </Field>
        <Field label="Email" required error={errors.email?.message} htmlFor="cu-email">
          <Input id="cu-email" type="email" autoComplete="off" {...register('email')} />
        </Field>
        <Field label="NIP" hint="18 digit, boleh dikosongkan untuk non-ASN" error={errors.nip?.message} htmlFor="cu-nip">
          <Input id="cu-nip" inputMode="numeric" maxLength={18} {...register('nip')} />
        </Field>
        <Field label="Jabatan" error={errors.position_title?.message} htmlFor="cu-pos">
          <Input id="cu-pos" {...register('position_title')} />
        </Field>
        <Field label="Unit kerja utama" error={errors.primary_unit_id?.message} htmlFor="cu-unit">
          <Select id="cu-unit" {...register('primary_unit_id')}>
            <UnitOptions units={units} />
          </Select>
        </Field>
        <div />
        <Field label="Password awal" required hint="Min. 12 karakter, huruf besar, huruf kecil, angka" error={errors.password?.message} htmlFor="cu-pw">
          <Input id="cu-pw" type="password" autoComplete="new-password" {...register('password')} />
        </Field>
        <Field label="Ulangi password" required error={errors.password_confirm?.message} htmlFor="cu-pw2">
          <Input id="cu-pw2" type="password" autoComplete="new-password" {...register('password_confirm')} />
        </Field>
      </div>
    </Modal>
  );
}

// ---------------------------------------------------------------------
export function EditProfileModal({ user, onClose, units }: { user: UserRow | null; onClose: () => void; units: OrganizationalUnit[] }) {
  const toast = useToast();
  const qc = useQueryClient();
  const form = useForm<EditProfileForm, unknown, EditProfileValues>({ resolver: zodResolver(editProfileSchema) });
  useEffect(() => {
    if (user)
      form.reset({
        full_name: user.full_name,
        nip: user.nip ?? '',
        position_title: user.position_title ?? '',
        primary_unit_id: user.primary_unit_id ?? '',
        phone: user.phone ?? '',
      });
  }, [user, form]);

  const mutation = useMutation({
    mutationFn: (v: EditProfileValues) => updateProfile({ id: user!.id, ...v }),
    onSuccess: () => {
      toast.success('Profil pengguna berhasil diperbarui.');
      void qc.invalidateQueries({ queryKey: ['users-bundle'] });
      onClose();
    },
    onError: (err) => toast.error(toUserMessage(err)),
  });

  const { register, formState: { errors } } = form;
  return (
    <Modal
      open={Boolean(user)}
      onClose={onClose}
      title={`Ubah Profil — ${user?.email ?? ''}`}
      footer={
        <>
          <Button variant="secondary" onClick={onClose}>Batal</Button>
          <Button onClick={form.handleSubmit((v) => mutation.mutate(v))} loading={mutation.isPending}>Simpan</Button>
        </>
      }
    >
      <Field label="Nama lengkap" required error={errors.full_name?.message} htmlFor="ep-name">
        <Input id="ep-name" {...register('full_name')} />
      </Field>
      <Field label="NIP" error={errors.nip?.message} htmlFor="ep-nip">
        <Input id="ep-nip" inputMode="numeric" maxLength={18} {...register('nip')} />
      </Field>
      <Field label="Jabatan" error={errors.position_title?.message} htmlFor="ep-pos">
        <Input id="ep-pos" {...register('position_title')} />
      </Field>
      <Field label="Unit kerja utama" error={errors.primary_unit_id?.message} htmlFor="ep-unit">
        <Select id="ep-unit" {...register('primary_unit_id')}>
          <UnitOptions units={units} />
        </Select>
      </Field>
      <Field label="Telepon" error={errors.phone?.message} htmlFor="ep-phone">
        <Input id="ep-phone" {...register('phone')} />
      </Field>
    </Modal>
  );
}

// ---------------------------------------------------------------------
export function AssignRoleModal({
  user,
  onClose,
  roles,
  units,
}: {
  user: UserRow | null;
  onClose: () => void;
  roles: Role[];
  units: OrganizationalUnit[];
}) {
  const toast = useToast();
  const qc = useQueryClient();
  const form = useForm<AssignRoleForm, unknown, AssignRoleValues>({ resolver: zodResolver(assignRoleSchema) });
  useEffect(() => {
    if (user)
      form.reset({
        role_id: '',
        role_code: '',
        unit_id: user.primary_unit_id ?? '',
        valid_from: todayJakarta(),
        valid_until: '',
        assignment_ref: '',
      });
  }, [user, form]);

  const roleCode = form.watch('role_code') as RoleCode | '';
  const needsUnit = roleCode !== '' && UNIT_SCOPED_ROLES.includes(roleCode);

  const mutation = useMutation({
    mutationFn: (v: AssignRoleValues) =>
      assignRole({
        user_id: user!.id,
        role_id: v.role_id,
        unit_id: needsUnit ? v.unit_id : null,
        valid_from: v.valid_from,
        valid_until: v.valid_until,
        assignment_ref: v.assignment_ref,
      }),
    onSuccess: () => {
      toast.success('Role berhasil ditetapkan.');
      void qc.invalidateQueries({ queryKey: ['users-bundle'] });
      onClose();
    },
    onError: (err) => toast.error(toUserMessage(err)),
  });

  const { register, setValue, formState: { errors } } = form;
  return (
    <Modal
      open={Boolean(user)}
      onClose={onClose}
      title={`Tetapkan Role — ${user?.full_name ?? ''}`}
      footer={
        <>
          <Button variant="secondary" onClick={onClose}>Batal</Button>
          <Button onClick={form.handleSubmit((v) => mutation.mutate(v))} loading={mutation.isPending}>Tetapkan</Button>
        </>
      }
    >
      <Alert tone="info">
        Aturan pemisahan fungsi berlaku: Super Admin tidak merangkap PWS/PGB/ATS/AKT, Auditor tidak merangkap role
        apa pun, dan Anda tidak dapat mengubah role Anda sendiri.
      </Alert>
      <Field label="Role" required error={errors.role_id?.message} htmlFor="ar-role">
        <Select
          id="ar-role"
          {...register('role_id', {
            onChange: (e: { target: { value: string } }) => {
              const r = roles.find((x) => x.id === e.target.value);
              setValue('role_code', r?.code ?? '');
            },
          })}
        >
          <option value="">— Pilih role —</option>
          {roles.map((r) => (
            <option key={r.id} value={r.id}>
              {ROLE_LABELS[r.code] ?? r.name}
            </option>
          ))}
        </Select>
      </Field>
      {needsUnit && (
        <Field label="Unit kerja (lingkup role)" required hint="Termasuk seluruh sub-unit di bawahnya" error={errors.unit_id?.message} htmlFor="ar-unit">
          <Select id="ar-unit" {...register('unit_id')}>
            <UnitOptions units={units} />
          </Select>
        </Field>
      )}
      <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
        <Field label="Berlaku mulai" required error={errors.valid_from?.message} htmlFor="ar-from">
          <Input id="ar-from" type="date" {...register('valid_from')} />
        </Field>
        <Field label="Berlaku sampai" hint="Kosongkan bila tidak dibatasi" error={errors.valid_until?.message} htmlFor="ar-until">
          <Input id="ar-until" type="date" {...register('valid_until')} />
        </Field>
      </div>
      <Field label="Dasar penugasan (No. SK / Surat Tugas)" error={errors.assignment_ref?.message} htmlFor="ar-ref">
        <Input id="ar-ref" {...register('assignment_ref')} />
      </Field>
    </Modal>
  );
}

// ---------------------------------------------------------------------
const resetSchema = z
  .object({ password: passwordSchema, password_confirm: z.string() })
  .refine((v) => v.password === v.password_confirm, { message: 'Konfirmasi password tidak sama.', path: ['password_confirm'] });

export function ResetPasswordModal({ user, onClose }: { user: UserRow | null; onClose: () => void }) {
  const toast = useToast();
  const form = useForm<z.infer<typeof resetSchema>>({ resolver: zodResolver(resetSchema) });
  useEffect(() => {
    if (user) form.reset({ password: '', password_confirm: '' });
  }, [user, form]);
  const mutation = useMutation({
    mutationFn: (v: z.infer<typeof resetSchema>) => adminResetPassword(user!.id, v.password),
    onSuccess: () => {
      toast.success('Password berhasil diatur ulang. Sampaikan kepada pengguna secara terpisah.');
      onClose();
    },
    onError: (err) => toast.error(toUserMessage(err)),
  });
  const { register, formState: { errors } } = form;
  return (
    <Modal
      open={Boolean(user)}
      onClose={onClose}
      title={`Reset Password — ${user?.full_name ?? ''}`}
      footer={
        <>
          <Button variant="secondary" onClick={onClose}>Batal</Button>
          <Button onClick={form.handleSubmit((v) => mutation.mutate(v))} loading={mutation.isPending}>Simpan</Button>
        </>
      }
    >
      <Field label="Password baru" required hint="Min. 12 karakter, huruf besar, huruf kecil, angka" error={errors.password?.message} htmlFor="rp-pw">
        <Input id="rp-pw" type="password" autoComplete="new-password" {...register('password')} />
      </Field>
      <Field label="Ulangi password" required error={errors.password_confirm?.message} htmlFor="rp-pw2">
        <Input id="rp-pw2" type="password" autoComplete="new-password" {...register('password_confirm')} />
      </Field>
    </Modal>
  );
}
