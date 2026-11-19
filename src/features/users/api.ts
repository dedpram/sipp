/**
 * Akses data modul Pengguna dan Role.
 * - Membaca & menetapkan role: langsung ke tabel (dibatasi RLS: hanya SA yang boleh menulis).
 * - Membuat akun / nonaktifkan / reset password: melalui Edge Function `admin-users`
 *   karena memerlukan kunci service role yang TIDAK boleh ada di browser.
 */
import { supabase } from '@/lib/supabase';
import type { OrganizationalUnit, Profile, Role, UserRole } from '@/types/domain';

export interface UserRow extends Profile {
  unit_name: string | null;
  assignments: Array<UserRole & { role_code: Role['code']; role_name: string; unit_name: string | null }>;
}

export async function fetchUsersBundle(): Promise<{ users: UserRow[]; roles: Role[]; units: OrganizationalUnit[] }> {
  const [profilesRes, rolesRes, unitsRes, userRolesRes] = await Promise.all([
    supabase
      .from('profiles')
      .select('id, nip, full_name, email, position_title, primary_unit_id, phone, is_active, last_login_at, created_at')
      .order('full_name'),
    supabase.from('roles').select('id, code, name, description, sort_order').order('sort_order'),
    supabase.from('organizational_units').select('id, code, name, parent_id, head_user_id, is_active').order('name'),
    supabase.from('user_roles').select('id, user_id, role_id, unit_id, valid_from, valid_until, assignment_ref, is_active'),
  ]);
  for (const r of [profilesRes, rolesRes, unitsRes, userRolesRes]) if (r.error) throw r.error;

  const roles = (rolesRes.data ?? []) as Role[];
  const units = (unitsRes.data ?? []) as OrganizationalUnit[];
  const roleById = new Map(roles.map((r) => [r.id, r]));
  const unitById = new Map(units.map((u) => [u.id, u]));

  const assignmentsByUser = new Map<string, UserRow['assignments']>();
  for (const ur of (userRolesRes.data ?? []) as UserRole[]) {
    const role = roleById.get(ur.role_id);
    if (!role) continue;
    const list = assignmentsByUser.get(ur.user_id) ?? [];
    list.push({ ...ur, role_code: role.code, role_name: role.name, unit_name: ur.unit_id ? (unitById.get(ur.unit_id)?.name ?? null) : null });
    assignmentsByUser.set(ur.user_id, list);
  }

  const users = ((profilesRes.data ?? []) as Profile[]).map((p) => ({
    ...p,
    unit_name: p.primary_unit_id ? (unitById.get(p.primary_unit_id)?.name ?? null) : null,
    assignments: assignmentsByUser.get(p.id) ?? [],
  }));
  return { users, roles, units };
}

export interface AssignRoleInput {
  user_id: string;
  role_id: string;
  unit_id: string | null;
  valid_from: string;
  valid_until: string | null;
  assignment_ref: string | null;
}

export async function assignRole(input: AssignRoleInput): Promise<void> {
  // Bila penugasan yang sama pernah dinonaktifkan, aktifkan kembali (tidak menghapus riwayat).
  let existing = supabase
    .from('user_roles')
    .select('id')
    .eq('user_id', input.user_id)
    .eq('role_id', input.role_id);
  existing = input.unit_id ? existing.eq('unit_id', input.unit_id) : existing.is('unit_id', null);
  const { data: found, error: findErr } = await existing.maybeSingle();
  if (findErr) throw findErr;

  if (found) {
    const { error } = await supabase
      .from('user_roles')
      .update({
        is_active: true,
        valid_from: input.valid_from,
        valid_until: input.valid_until,
        assignment_ref: input.assignment_ref,
      })
      .eq('id', found.id);
    if (error) throw error;
    return;
  }
  const { error } = await supabase.from('user_roles').insert(input);
  if (error) throw error;
}

export async function setRoleAssignmentActive(id: string, active: boolean): Promise<void> {
  const { data, error } = await supabase.from('user_roles').update({ is_active: active }).eq('id', id).select('id');
  if (error) throw error;
  if (!data || data.length === 0) throw new Error('Anda tidak memiliki hak untuk melakukan tindakan ini.');
}

export interface UpdateProfileInput {
  id: string;
  full_name: string;
  nip: string | null;
  position_title: string | null;
  primary_unit_id: string | null;
  phone: string | null;
}

export async function updateProfile({ id, ...values }: UpdateProfileInput): Promise<void> {
  const { data, error } = await supabase.from('profiles').update(values).eq('id', id).select('id');
  if (error) throw error;
  if (!data || data.length === 0) throw new Error('Anda tidak memiliki hak untuk melakukan tindakan ini.');
}

// ------------------------- Edge Function -------------------------------
type AdminAction =
  | {
      action: 'create_user';
      email: string;
      password: string;
      full_name: string;
      nip?: string | null;
      position_title?: string | null;
      primary_unit_id?: string | null;
    }
  | { action: 'set_active'; user_id: string; active: boolean; reason: string }
  | { action: 'reset_password'; user_id: string; password: string };

async function callAdmin<T = unknown>(payload: AdminAction): Promise<T> {
  const { data, error } = await supabase.functions.invoke('admin-users', { body: payload });
  if (error) {
    // Ambil pesan dari badan respons fungsi bila ada.
    const ctx = (error as { context?: Response }).context;
    if (ctx && typeof ctx.json === 'function') {
      try {
        const body = (await ctx.json()) as { error?: string };
        if (body?.error) throw new Error(body.error);
      } catch (inner) {
        if (inner instanceof Error && inner.message) throw inner;
      }
    }
    throw error;
  }
  return data as T;
}

export const adminCreateUser = (input: Omit<Extract<AdminAction, { action: 'create_user' }>, 'action'>) =>
  callAdmin<{ user_id: string }>({ action: 'create_user', ...input });

export const adminSetActive = (user_id: string, active: boolean, reason: string) =>
  callAdmin({ action: 'set_active', user_id, active, reason });

export const adminResetPassword = (user_id: string, password: string) =>
  callAdmin({ action: 'reset_password', user_id, password });
