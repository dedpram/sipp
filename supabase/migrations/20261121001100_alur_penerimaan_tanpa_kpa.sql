-- =====================================================================
-- SIPP — Migration 0011: Perubahan keputusan pengguna (21-11-2026)
-- 1. Role KPA DIHAPUS dari aplikasi: dinonaktifkan (riwayat tetap utuh),
--    tidak dapat ditetapkan lagi; tugas persetujuannya dialihkan ke
--    Pejabat Pengawas (PWS) dan tetap dapat diubah di Pengaturan.
-- 2. Alur penerimaan:
--    * pencatatan hanya oleh Petugas Penerima Barang (PPB);
--    * pemeriksaan SEKALIGUS pengesahan oleh PPK (pembelian) atau
--      Pejabat Pengawas (hibah, transfer, perolehan lain, saldo awal);
--    * penyimpanan ke gudang tetap oleh Pengurus Barang.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Role tidak aktif
-- ---------------------------------------------------------------------
alter table public.roles add column if not exists is_active boolean not null default true;
update public.roles set is_active = false where code = 'KPA';

create or replace function private.my_role_codes()
returns text[]
language sql stable security definer set search_path = ''
as $$
  select coalesce(array_agg(distinct r.code), '{}')
    from public.user_roles ur
    join public.roles r    on r.id = ur.role_id
    join public.profiles p on p.id = ur.user_id
   where ur.user_id = auth.uid()
     and ur.is_active
     and r.is_active
     and p.is_active
     and current_date >= ur.valid_from
     and (ur.valid_until is null or current_date <= ur.valid_until);
$$;

-- Penetapan role: tolak role yang sudah tidak digunakan.
create or replace function private.tg_user_roles_guard()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_code        text;
  v_role_active boolean;
  v_other_codes text[];
  v_active_sa   integer;
  c_conflict_sa constant text[] := array['KPA','PWS','PGB','ATS','AKT'];
begin
  select code, is_active into v_code, v_role_active from public.roles where id = new.role_id;

  if auth.uid() is not null and new.user_id = auth.uid() then
    raise exception 'Anda tidak dapat mengubah role Anda sendiri.' using errcode = '42501';
  end if;

  if tg_op = 'UPDATE' and (new.user_id <> old.user_id or new.role_id <> old.role_id) then
    raise exception 'Pengguna dan role pada penugasan tidak dapat diganti; nonaktifkan lalu buat penugasan baru.'
      using errcode = '22023';
  end if;

  if new.is_active and not v_role_active then
    raise exception 'Role % sudah tidak digunakan dalam aplikasi.', v_code using errcode = '23514';
  end if;

  if v_code in ('ATS','PGW') and new.unit_id is null then
    raise exception 'Role % wajib memiliki unit kerja.', v_code using errcode = '23514';
  end if;
  if v_code not in ('ATS','PGW') and new.unit_id is not null then
    raise exception 'Role % berlaku untuk seluruh satuan kerja; unit kerja harus dikosongkan.', v_code
      using errcode = '23514';
  end if;

  if tg_op = 'UPDATE' and v_code = 'SA' and old.is_active and not new.is_active then
    select count(*) into v_active_sa
      from public.user_roles ur join public.roles r on r.id = ur.role_id
     where r.code = 'SA' and ur.is_active and ur.id <> new.id;
    if v_active_sa = 0 then
      raise exception 'Minimal harus ada satu Super Admin aktif.' using errcode = '23514';
    end if;
  end if;

  if not new.is_active then
    return new;
  end if;

  select coalesce(array_agg(r.code), '{}') into v_other_codes
    from public.user_roles ur join public.roles r on r.id = ur.role_id
   where ur.user_id = new.user_id and ur.is_active and r.is_active and ur.id <> new.id;

  if (v_code = 'AUD' and cardinality(v_other_codes) > 0) or (v_code <> 'AUD' and 'AUD' = any(v_other_codes)) then
    raise exception 'Auditor/APIP tidak boleh merangkap role lain (pemisahan fungsi).' using errcode = '23514';
  end if;
  if (v_code = 'SA' and v_other_codes && c_conflict_sa)
     or (v_code = any(c_conflict_sa) and 'SA' = any(v_other_codes)) then
    raise exception 'Super Admin tidak boleh merangkap role PWS, PGB, ATS, atau AKT (pemisahan fungsi).'
      using errcode = '23514';
  end if;
  return new;
end;
$$;

-- Nonaktifkan seluruh penugasan KPA (konteks sistem; tercatat di audit trail).
update public.user_roles ur set is_active = false
  from public.roles r
 where r.id = ur.role_id and r.code = 'KPA' and ur.is_active;

-- Alihkan tugas persetujuan KPA ke Pejabat Pengawas.
update public.approval_settings a
   set approver_role_code = 'PWS',
       description = coalesce(a.description, '') || ' (dialihkan dari KPA)'
 where a.approver_role_code = 'KPA'
   and not exists (select 1 from public.approval_settings b
                    where b.transaction_type = a.transaction_type and b.level = a.level and b.approver_role_code = 'PWS');
update public.approval_settings set is_active = false where approver_role_code = 'KPA';

update public.approval_settings
   set description = 'Pemeriksaan & pengesahan penerimaan pembelian'
 where transaction_type = 'receipt' and approver_role_code = 'PPK';
update public.approval_settings
   set description = 'Pemeriksaan & pengesahan penerimaan hibah, transfer, perolehan lain, dan saldo awal'
 where transaction_type = 'receipt' and approver_role_code = 'PWS';

-- ---------------------------------------------------------------------
-- 2. Alur penerimaan baru
-- ---------------------------------------------------------------------
-- Role pemeriksa (sekaligus pengesah) yang dimiliki pengguna untuk sumber tertentu.
create or replace function private.receipt_inspector_role(p_source text)
returns text language sql stable security definer set search_path = '' as $$
  select a.approver_role_code
    from public.approval_settings a
   where a.transaction_type = 'receipt' and a.is_active
     and (a.applies_when = '{}'::jsonb or (a.applies_when -> 'source_type') ? p_source)
     and private.has_role(a.approver_role_code)
   order by a.level limit 1;
$$;
revoke all on function private.receipt_inspector_role(text) from public;
grant execute on function private.receipt_inspector_role(text) to authenticated;

-- Pencatatan hanya oleh Petugas Penerima Barang.
drop policy if exists receipts_insert on public.receipts;
create policy receipts_insert on public.receipts for insert to authenticated
  with check ((select private.has_role('PPB')) and (select private.current_user_is_active()));

-- Lampiran: pencatat & pemeriksa, sebelum pengesahan.
create or replace function private.can_attach(p_table text, p_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select private.current_user_is_active() and case p_table
    when 'receipts' then private.has_any_role(array['PPB','PPK','PWS'])
      and exists (select 1 from public.receipts r where r.id = p_id and r.status in
        ('draft','menunggu_pemeriksaan','dalam_pemeriksaan','tidak_sesuai','menunggu_tindak_lanjut_penyedia'))
    when 'stock_transfers' then private.has_role('PGB')
    else false end;
$$;

-- Pengesahan terpisah tidak dipakai lagi.
drop function if exists public.rpc_receipt_decide(uuid, text, text);

create or replace function public.rpc_receipt_start_inspection(p_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare r public.receipts; v_uid uuid := private.require_active_user();
begin
  r := private.receipt_for_update(p_id);
  if private.receipt_inspector_role(r.source_type) is null then
    raise exception 'Anda tidak berwenang memeriksa penerimaan ini (pembelian: PPK; sumber lain: Pejabat Pengawas).'
      using errcode = '42501';
  end if;
  perform private.receipt_expect(r, array['menunggu_pemeriksaan','menunggu_tindak_lanjut_penyedia']);
  if r.created_by = v_uid then
    raise exception 'Pencatat penerimaan tidak boleh memeriksa penerimaannya sendiri (pemisahan fungsi).' using errcode = '42501';
  end if;
  perform private.begin_rpc('Pemeriksaan dimulai');
  update public.receipts set status = 'dalam_pemeriksaan', inspector_id = v_uid where id = p_id;
  perform private.end_rpc();
end $$;

-- Pemeriksaan sekaligus pengesahan.
-- p_decision: 'lanjut' = sahkan barang yang diterima baik | 'tindak_lanjut' = ketidaksesuaian
create or replace function public.rpc_receipt_record_inspection(p_id uuid, p_lines jsonb, p_notes text, p_decision text)
returns void language plpgsql security definer set search_path = '' as $$
declare
  r public.receipts;
  v_uid uuid := private.require_active_user();
  v_role text;
  l jsonb;
  d record;
  v_acc numeric; v_rej numeric; v_rec numeric; v_res text; v_exp date;
  v_issue boolean := false;
  v_total_acc numeric := 0;
  v_missing integer;
  v_docs text[] := '{}';
begin
  r := private.receipt_for_update(p_id);
  perform private.receipt_expect(r, array['dalam_pemeriksaan']);
  if r.inspector_id is distinct from v_uid then
    raise exception 'Hanya pemeriksa yang memulai pemeriksaan yang dapat mencatat hasilnya.' using errcode = '42501';
  end if;
  v_role := private.receipt_inspector_role(r.source_type);
  if v_role is null then
    raise exception 'Anda tidak lagi berwenang memeriksa penerimaan ini.' using errcode = '42501';
  end if;
  if p_decision not in ('lanjut','tindak_lanjut') then
    raise exception 'Keputusan pemeriksaan tidak dikenal.' using errcode = '22023';
  end if;

  perform private.begin_rpc(case p_decision when 'lanjut' then 'Diperiksa dan disahkan'
                                            else 'Ditemukan ketidaksesuaian' end);
  for l in select * from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) loop
    select d2.*, i.has_expiry, i.code into d
      from public.receipt_details d2 join public.items i on i.id = d2.item_id
     where d2.id = (l ->> 'detail_id')::uuid and d2.receipt_id = p_id;
    if not found then
      raise exception 'Rincian penerimaan tidak dikenal.' using errcode = 'P0002';
    end if;
    v_rec := coalesce((l ->> 'qty_received')::numeric, d.qty_received);
    v_acc := coalesce((l ->> 'qty_accepted')::numeric, 0);
    v_rej := coalesce((l ->> 'qty_rejected')::numeric, 0);
    v_res := l ->> 'result';
    v_exp := nullif(l ->> 'expiry_date', '')::date;
    if v_rec <= 0 or v_acc < 0 or v_rej < 0 or v_acc + v_rej <> v_rec then
      raise exception 'Barang %: jumlah diterima baik + ditolak harus sama dengan jumlah yang datang.', d.code using errcode = '22023';
    end if;
    if v_res is null or v_res not in ('sesuai','tidak_sesuai_jumlah','tidak_sesuai_spesifikasi','rusak') then
      raise exception 'Barang %: pilih hasil pemeriksaan.', d.code using errcode = '22023';
    end if;
    if v_res = 'sesuai' and v_rej > 0 then
      raise exception 'Barang %: hasil "sesuai" tidak boleh memiliki jumlah ditolak.', d.code using errcode = '22023';
    end if;
    if d.has_expiry and v_acc > 0 and v_exp is null then
      raise exception 'Barang % wajib diisi tanggal kedaluwarsa.', d.code using errcode = '22023';
    end if;
    if v_res <> 'sesuai' or v_rej > 0 or (d.qty_ordered is not null and v_rec <> d.qty_ordered) then
      v_issue := true;
    end if;
    update public.receipt_details
       set qty_received = v_rec, qty_accepted = v_acc, qty_rejected = v_rej,
           inspection_result = v_res, inspection_notes = nullif(trim(l ->> 'notes'), ''), expiry_date = v_exp
     where id = d.id;
  end loop;

  select count(*) into v_missing from public.receipt_details where receipt_id = p_id and inspection_result is null;
  if v_missing > 0 then
    raise exception 'Semua barang harus diperiksa (% belum).', v_missing using errcode = 'P0001';
  end if;
  select coalesce(sum(qty_accepted), 0) into v_total_acc from public.receipt_details where receipt_id = p_id;

  if p_decision = 'tindak_lanjut' then
    if not v_issue then
      raise exception 'Tidak ada ketidaksesuaian yang dicatat.' using errcode = 'P0001';
    end if;
    update public.receipts
       set status = 'tidak_sesuai', inspected_at = now(), inspection_notes = nullif(trim(coalesce(p_notes, '')), '')
     where id = p_id;
    perform private.end_rpc();
    return;
  end if;

  if v_total_acc <= 0 then
    raise exception 'Tidak ada barang yang diterima baik; pilih catat ketidaksesuaian.' using errcode = 'P0001';
  end if;

  -- Dokumen wajib sebelum pengesahan.
  if r.source_type = 'saldo_awal' then
    if not exists (select 1 from public.attachments where ref_table = 'receipts' and ref_id = p_id and doc_type = 'ba_saldo_awal') then
      v_docs := v_docs || 'Berita Acara Saldo Awal';
    end if;
  else
    if not exists (select 1 from public.attachments where ref_table = 'receipts' and ref_id = p_id and doc_type = 'ba_pemeriksaan') then
      v_docs := v_docs || 'Berita Acara Pemeriksaan';
    end if;
    if r.source_type = 'pembelian' and not exists (
         select 1 from public.attachments where ref_table = 'receipts' and ref_id = p_id and doc_type in ('surat_jalan','faktur')) then
      v_docs := v_docs || 'Surat Jalan atau Faktur';
    end if;
  end if;
  if cardinality(v_docs) > 0 then
    raise exception 'Dokumen wajib belum diunggah: %.', array_to_string(v_docs, ', ') using errcode = 'P0001';
  end if;

  insert into public.approvals (ref_table, ref_id, level, required_role_code, approver_id, decision, notes)
  values ('receipts', p_id, 1, v_role, v_uid, 'approved', nullif(trim(coalesce(p_notes, '')), ''));
  update public.receipts
     set status = 'disetujui', inspected_at = now(), approved_by = v_uid, approved_at = now(),
         inspection_notes = nullif(trim(coalesce(p_notes, '')), ''),
         total_value = (select coalesce(round(sum(qty_accepted * unit_cost), 2), 0) from public.receipt_details where receipt_id = p_id)
   where id = p_id;
  perform private.end_rpc();
end $$;

create or replace function public.rpc_receipt_vendor_followup(p_id uuid, p_comment text)
returns void language plpgsql security definer set search_path = '' as $$
declare r public.receipts;
begin
  perform private.require_active_user();
  if not private.has_any_role(array['PPK','PWS','PPB']) then
    raise exception 'Hanya PPK, Pejabat Pengawas, atau Petugas Penerima Barang yang dapat meneruskan tindak lanjut.' using errcode = '42501';
  end if;
  r := private.receipt_for_update(p_id);
  perform private.receipt_expect(r, array['tidak_sesuai']);
  if length(trim(coalesce(p_comment, ''))) < 5 then
    raise exception 'Tuliskan tindak lanjut yang diminta (minimal 5 karakter).' using errcode = '22023';
  end if;
  perform private.begin_rpc(p_comment);
  update public.receipts set status = 'menunggu_tindak_lanjut_penyedia' where id = p_id;
  perform private.end_rpc();
end $$;

create or replace function public.rpc_receipt_cancel(p_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare r public.receipts; v_uid uuid := private.require_active_user();
begin
  r := private.receipt_for_update(p_id);
  perform private.receipt_expect(r, array['draft','menunggu_pemeriksaan','tidak_sesuai','menunggu_tindak_lanjut_penyedia']);
  if r.created_by is distinct from v_uid then
    raise exception 'Hanya pencatat penerimaan yang dapat membatalkannya.' using errcode = '42501';
  end if;
  if length(trim(coalesce(p_reason, ''))) < 5 then
    raise exception 'Alasan pembatalan wajib diisi (minimal 5 karakter).' using errcode = '22023';
  end if;
  perform private.begin_rpc('Dibatalkan: ' || p_reason);
  update public.receipts set status = 'dibatalkan', cancel_reason = p_reason where id = p_id;
  perform private.end_rpc();
end $$;

-- Penerimaan yang sedang diperiksa/menunggu pengesahan dengan aturan lama
-- dikembalikan ke antrean pemeriksaan agar diperiksa ulang oleh PPK/PWS.
do $$
begin
  perform private.begin_rpc('Dikembalikan ke antrean pemeriksaan karena perubahan alur (pemeriksa: PPK / Pejabat Pengawas)');
  -- Hanya yang diperiksa dengan aturan lama: status "menunggu pengesahan", atau
  -- sedang diperiksa oleh orang yang bukan PPK/Pejabat Pengawas. Aman dijalankan ulang.
  update public.receipts r
     set status = 'menunggu_pemeriksaan', inspector_id = null, inspected_at = null
   where r.status = 'menunggu_pengesahan'
      or (r.status = 'dalam_pemeriksaan' and not exists (
            select 1 from public.user_roles ur join public.roles ro on ro.id = ur.role_id
             where ur.user_id = r.inspector_id and ur.is_active and ro.code in ('PPK','PWS')));
  perform private.end_rpc();
end $$;
