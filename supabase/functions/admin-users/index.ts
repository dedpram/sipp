// =====================================================================
// SIPP — Edge Function `admin-users`
// Satu-satunya tempat kunci SERVICE ROLE dipakai. Kunci ini disediakan
// otomatis oleh Supabase sebagai variabel lingkungan fungsi dan TIDAK
// pernah dikirim ke browser.
//
// Aksi (hanya untuk pengguna dengan role SA aktif):
//   create_user     : membuat akun Auth + profil
//   set_active      : mengaktifkan/menonaktifkan akun (ban di Auth + profiles.is_active)
//   reset_password  : mengatur password baru
// Semua aksi dicatat di audit trail atas nama Super Admin peminta.
//
// Deploy:  npx supabase functions deploy admin-users
// =====================================================================
import { createClient } from 'npm:@supabase/supabase-js@2';

const ALLOWED_ORIGINS = (Deno.env.get('SIPP_ALLOWED_ORIGINS') ?? '')
  .split(',')
  .map((s) => s.trim())
  .filter(Boolean);

function corsHeaders(origin: string | null): Record<string, string> {
  const allow = origin && (ALLOWED_ORIGINS.length === 0 || ALLOWED_ORIGINS.includes(origin)) ? origin : (ALLOWED_ORIGINS[0] ?? '*');
  return {
    'Access-Control-Allow-Origin': allow,
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    Vary: 'Origin',
  };
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

function validPassword(pw: unknown): pw is string {
  return typeof pw === 'string' && pw.length >= 12 && /[A-Z]/.test(pw) && /[a-z]/.test(pw) && /\d/.test(pw);
}

class HttpError extends Error {
  constructor(public status: number, message: string) {
    super(message);
  }
}

Deno.serve(async (req) => {
  const origin = req.headers.get('Origin');
  const cors = corsHeaders(origin);
  const json = (status: number, body: unknown) =>
    new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json(405, { error: 'Metode tidak diizinkan.' });

  try {
    const url = Deno.env.get('SUPABASE_URL');
    const anonKey = Deno.env.get('SUPABASE_ANON_KEY');
    const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
    if (!url || !anonKey || !serviceKey) throw new HttpError(500, 'Konfigurasi fungsi belum lengkap.');

    const authHeader = req.headers.get('Authorization');
    if (!authHeader?.startsWith('Bearer ')) throw new HttpError(401, 'Sesi tidak valid. Silakan masuk kembali.');

    // 1) Verifikasi pemanggil memakai token pengguna itu sendiri (RLS berlaku).
    const asCaller = createClient(url, anonKey, {
      global: { headers: { Authorization: authHeader } },
      auth: { persistSession: false },
    });
    const { data: userData, error: userErr } = await asCaller.auth.getUser();
    if (userErr || !userData.user) throw new HttpError(401, 'Sesi tidak valid. Silakan masuk kembali.');
    const callerId = userData.user.id;

    const { data: ctx, error: ctxErr } = await asCaller.rpc('rpc_my_context');
    if (ctxErr) throw new HttpError(403, ctxErr.message);
    if (!Array.isArray(ctx?.roles) || !ctx.roles.includes('SA')) {
      throw new HttpError(403, 'Hanya Super Admin yang dapat mengelola akun pengguna.');
    }

    // 2) Klien service role untuk operasi administratif Auth.
    const admin = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
    const audit = (action: string, recordId: string, oldData: unknown, newData: unknown) =>
      admin.rpc('rpc_service_audit', {
        p_actor: callerId,
        p_action: action,
        p_table: 'auth.users',
        p_record_id: recordId,
        p_old: oldData,
        p_new: newData,
      });

    const body = await req.json().catch(() => null);
    if (!body || typeof body.action !== 'string') throw new HttpError(400, 'Permintaan tidak valid.');

    switch (body.action) {
      case 'create_user': {
        const email = String(body.email ?? '').trim().toLowerCase();
        const fullName = String(body.full_name ?? '').trim();
        const nip = body.nip ? String(body.nip).trim() : null;
        const position = body.position_title ? String(body.position_title).trim() : null;
        const unitId = body.primary_unit_id ? String(body.primary_unit_id) : null;

        if (!EMAIL_RE.test(email)) throw new HttpError(400, 'Format email tidak valid.');
        if (fullName.length < 3) throw new HttpError(400, 'Nama minimal 3 karakter.');
        if (nip && !/^\d{18}$/.test(nip)) throw new HttpError(400, 'NIP harus 18 digit angka.');
        if (unitId && !UUID_RE.test(unitId)) throw new HttpError(400, 'Unit kerja tidak valid.');
        if (!validPassword(body.password)) {
          throw new HttpError(400, 'Password minimal 12 karakter dan mengandung huruf besar, huruf kecil, serta angka.');
        }

        const { data, error } = await admin.auth.admin.createUser({
          email,
          password: body.password,
          email_confirm: true,
          user_metadata: { full_name: fullName, nip, position_title: position, primary_unit_id: unitId },
        });
        if (error) {
          const msg = /already|registered|exists/i.test(error.message)
            ? 'Email tersebut sudah terdaftar.'
            : `Gagal membuat akun: ${error.message}`;
          throw new HttpError(400, msg);
        }
        await audit('USER_CREATE', data.user.id, null, { email, full_name: fullName, nip, primary_unit_id: unitId });
        return json(200, { user_id: data.user.id });
      }

      case 'set_active': {
        const userId = String(body.user_id ?? '');
        const active = body.active === true;
        const reason = String(body.reason ?? '').trim();
        if (!UUID_RE.test(userId)) throw new HttpError(400, 'Pengguna tidak valid.');
        if (userId === callerId) throw new HttpError(400, 'Anda tidak dapat mengubah status akun Anda sendiri.');
        if (reason.length < 5) throw new HttpError(400, 'Alasan wajib diisi (minimal 5 karakter).');

        const { error: banErr } = await admin.auth.admin.updateUserById(userId, {
          ban_duration: active ? 'none' : '876000h', // ±100 tahun
        });
        if (banErr) throw new HttpError(400, `Gagal memperbarui akun: ${banErr.message}`);

        const { error: profErr } = await admin.from('profiles').update({ is_active: active }).eq('id', userId);
        if (profErr) throw new HttpError(400, `Gagal memperbarui profil: ${profErr.message}`);

        await audit(active ? 'USER_ACTIVATE' : 'USER_DEACTIVATE', userId, { is_active: !active }, { is_active: active, reason });
        return json(200, { ok: true });
      }

      case 'reset_password': {
        const userId = String(body.user_id ?? '');
        if (!UUID_RE.test(userId)) throw new HttpError(400, 'Pengguna tidak valid.');
        if (userId === callerId) throw new HttpError(400, 'Gunakan menu Profil Saya untuk mengganti password Anda.');
        if (!validPassword(body.password)) {
          throw new HttpError(400, 'Password minimal 12 karakter dan mengandung huruf besar, huruf kecil, serta angka.');
        }
        const { error } = await admin.auth.admin.updateUserById(userId, { password: body.password });
        if (error) throw new HttpError(400, `Gagal mengatur password: ${error.message}`);
        // Password TIDAK pernah dicatat.
        await audit('USER_PASSWORD_RESET', userId, null, null);
        return json(200, { ok: true });
      }

      default:
        throw new HttpError(400, 'Aksi tidak dikenal.');
    }
  } catch (err) {
    if (err instanceof HttpError) return json(err.status, { error: err.message });
    console.error(err);
    return json(500, { error: 'Terjadi kesalahan pada server.' });
  }
});
