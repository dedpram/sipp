// =====================================================================
// SIPP — Edge Function `admin-users`  (versi 4)
// Satu-satunya tempat kunci SERVICE ROLE / SECRET dipakai. Kunci ini
// disediakan otomatis oleh Supabase sebagai variabel lingkungan fungsi
// dan TIDAK pernah dikirim ke browser.
//
// Aksi (hanya untuk pengguna dengan role SA aktif):
//   create_user     : membuat akun Auth + profil
//   set_active      : mengaktifkan/menonaktifkan akun
//   reset_password  : mengatur password baru
// Semua aksi dicatat di audit trail atas nama Super Admin peminta.
//
// Token login pemanggil diverifikasi DI DALAM fungsi ini (bukan oleh
// gateway), sehingga pengaturan "Verify JWT" pada fungsi boleh dimatikan.
// Ini diperlukan untuk proyek Supabase yang memakai kunci JWT baru.
// =====================================================================
import { createClient } from 'npm:@supabase/supabase-js@2';

const ALLOWED_ORIGINS = (Deno.env.get('SIPP_ALLOWED_ORIGINS') ?? '')
  .split(',')
  .map((s) => s.trim().replace(/\/+$/, '').toLowerCase())
  .filter(Boolean);

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const PASSWORD_MSG = 'Password harus minimal 12 karakter dan mengandung huruf besar, huruf kecil, serta angka.';

class HttpError extends Error {
  constructor(public status: number, message: string) {
    super(message);
  }
}

function validPassword(pw: unknown): pw is string {
  return typeof pw === 'string' && pw.length >= 12 && /[A-Z]/.test(pw) && /[a-z]/.test(pw) && /\d/.test(pw);
}

function serviceKey(): string | undefined {
  const legacy = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (legacy) return legacy;
  // Proyek dengan API key baru: SUPABASE_SECRET_KEYS = {"default":"sb_secret_..."}
  const raw = Deno.env.get('SUPABASE_SECRET_KEYS');
  if (raw) {
    try {
      const obj = JSON.parse(raw) as Record<string, string>;
      return obj.default ?? Object.values(obj)[0];
    } catch {
      return undefined;
    }
  }
  return undefined;
}

/** Membaca isi token yang SUDAH diverifikasi oleh auth.getUser(). */
function tokenClaim(token: string, claim: string): unknown {
  try {
    const part = token.split('.')[1] ?? '';
    const json = atob(part.replace(/-/g, '+').replace(/_/g, '/').padEnd(Math.ceil(part.length / 4) * 4, '='));
    return (JSON.parse(json) as Record<string, unknown>)[claim];
  } catch {
    return undefined;
  }
}

function todayJakarta(): string {
  return new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Jakarta' }).format(new Date());
}

Deno.serve(async (req) => {
  const origin = req.headers.get('Origin') ?? '';
  const originOk = ALLOWED_ORIGINS.length === 0 || ALLOWED_ORIGINS.includes(origin.toLowerCase());
  // Origin pemanggil dipantulkan agar browser dapat membaca pesan error;
  // permintaan dari origin yang tidak diizinkan tetap DITOLAK di bawah.
  // Header yang diminta browser dipantulkan kembali, karena versi baru
  // supabase-js dapat mengirim header tambahan (mis. x-retry-count, traceparent).
  const requestedHeaders = req.headers.get('Access-Control-Request-Headers');
  const cors = {
    'Access-Control-Allow-Origin': origin || '*',
    'Access-Control-Allow-Headers':
      requestedHeaders || 'authorization, x-client-info, apikey, content-type, x-retry-count, x-region, traceparent, tracestate, baggage',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Access-Control-Max-Age': '600',
    Vary: 'Origin, Access-Control-Request-Headers',
  };
  const json = (status: number, body: unknown) =>
    new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });

  try {
    if (req.method !== 'POST') throw new HttpError(405, 'Metode tidak diizinkan.');
    if (!originOk) {
      throw new HttpError(
        403,
        `Alamat aplikasi ${origin || '(tidak diketahui)'} tidak diizinkan. Periksa isi secret SIPP_ALLOWED_ORIGINS di Supabase.`,
      );
    }

    const url = Deno.env.get('SUPABASE_URL');
    const key = serviceKey();
    if (!url || !key) throw new HttpError(500, 'Konfigurasi fungsi belum lengkap (URL atau kunci layanan tidak tersedia).');

    const token = (req.headers.get('Authorization') ?? '').replace(/^Bearer\s+/i, '');
    if (!token) throw new HttpError(401, 'Sesi tidak valid. Silakan keluar lalu masuk kembali.');

    const admin = createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });

    // 1) Verifikasi token pemanggil.
    const { data: userData, error: userErr } = await admin.auth.getUser(token);
    if (userErr || !userData?.user) throw new HttpError(401, 'Sesi tidak valid. Silakan keluar lalu masuk kembali.');
    const callerId = userData.user.id;

    // 2) Pastikan pemanggil adalah Super Admin aktif (dibaca dari database, bukan dari kiriman browser).
    const { data: profile, error: profErr } = await admin.from('profiles').select('is_active').eq('id', callerId).maybeSingle();
    if (profErr) throw new HttpError(500, `Profil tidak dapat dibaca: ${profErr.message}`);
    if (!profile?.is_active) throw new HttpError(403, 'Akun Anda tidak aktif.');

    const today = todayJakarta();
    const { data: saRows, error: roleErr } = await admin
      .from('user_roles')
      .select('valid_from, valid_until, roles!inner(code)')
      .eq('user_id', callerId)
      .eq('is_active', true)
      .eq('roles.code', 'SA');
    if (roleErr) throw new HttpError(500, `Role tidak dapat dibaca: ${roleErr.message}`);
    const isSA = (saRows ?? []).some(
      (r: { valid_from: string; valid_until: string | null }) => r.valid_from <= today && (!r.valid_until || r.valid_until >= today),
    );
    if (!isSA) throw new HttpError(403, 'Anda tidak berwenang: hanya Super Admin yang dapat mengelola akun pengguna.');

    // 3) Verifikasi dua langkah wajib bila diatur (pengaturan mfa_required_roles).
    const { data: mfaRow } = await admin.from('app_settings').select('value').eq('key', 'mfa_required_roles').maybeSingle();
    const mfaRequired = Array.isArray(mfaRow?.value) && (mfaRow.value as unknown[]).includes('SA');
    if (mfaRequired && tokenClaim(token, 'aal') !== 'aal2') {
      throw new HttpError(
        403,
        'Aktifkan verifikasi dua langkah di menu Profil Saya, lalu keluar dan masuk kembali dengan kode verifikasi.',
      );
    }

    const audit = async (action: string, recordId: string, oldData: unknown, newData: unknown) => {
      const { error } = await admin.rpc('rpc_service_audit', {
        p_actor: callerId,
        p_action: action,
        p_table: 'auth.users',
        p_record_id: recordId,
        p_old: oldData,
        p_new: newData,
      });
      if (error) console.error('Audit gagal:', error.message);
    };

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
        if (fullName.length < 3) throw new HttpError(400, 'Nama harus minimal 3 karakter.');
        if (nip && !/^\d{18}$/.test(nip)) throw new HttpError(400, 'NIP harus 18 digit angka.');
        if (unitId && !UUID_RE.test(unitId)) throw new HttpError(400, 'Unit kerja tidak valid.');
        if (!validPassword(body.password)) throw new HttpError(400, PASSWORD_MSG);

        const { data, error } = await admin.auth.admin.createUser({
          email,
          password: body.password,
          email_confirm: true,
          user_metadata: { full_name: fullName, nip, position_title: position, primary_unit_id: unitId },
        });
        if (error) {
          const msg = /already|registered|exists/i.test(error.message)
            ? 'Email tersebut sudah terdaftar.'
            : /password/i.test(error.message)
              ? `Password tidak diterima Supabase: ${error.message}`
              : `Akun tidak dapat dibuat: ${error.message}`;
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
          ban_duration: active ? 'none' : '876000h',
        });
        if (banErr) throw new HttpError(400, `Akun tidak dapat diperbarui: ${banErr.message}`);

        const { error: updErr } = await admin.from('profiles').update({ is_active: active }).eq('id', userId);
        if (updErr) throw new HttpError(400, `Profil tidak dapat diperbarui: ${updErr.message}`);

        await audit(active ? 'USER_ACTIVATE' : 'USER_DEACTIVATE', userId, { is_active: !active }, { is_active: active, reason });
        return json(200, { ok: true });
      }

      case 'reset_password': {
        const userId = String(body.user_id ?? '');
        if (!UUID_RE.test(userId)) throw new HttpError(400, 'Pengguna tidak valid.');
        if (userId === callerId) throw new HttpError(400, 'Gunakan menu Profil Saya untuk mengganti password Anda.');
        if (!validPassword(body.password)) throw new HttpError(400, PASSWORD_MSG);
        const { error } = await admin.auth.admin.updateUserById(userId, { password: body.password });
        if (error) throw new HttpError(400, `Password tidak dapat diatur: ${error.message}`);
        await audit('USER_PASSWORD_RESET', userId, null, null); // password TIDAK dicatat
        return json(200, { ok: true });
      }

      default:
        throw new HttpError(400, 'Aksi tidak dikenal.');
    }
  } catch (err) {
    if (err instanceof HttpError) return json(err.status, { error: err.message });
    console.error(err);
    return json(500, { error: `Fungsi tidak berjalan normal: ${err instanceof Error ? err.message : String(err)}` });
  }
});
