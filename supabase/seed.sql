-- =====================================================================
-- DATA CONTOH — KHUSUS DEVELOPMENT / STAGING. JANGAN dijalankan di produksi.
-- Hanya membuat struktur unit kerja contoh. Akun pengguna dibuat melalui
-- Supabase Authentication atau menu Pengguna dan Role.
-- =====================================================================
insert into public.organizational_units (code, name) values ('SEK', 'Sekretariat')
on conflict (code) do nothing;

insert into public.organizational_units (code, name, parent_id)
select v.code, v.name, p.id
from (values ('UMUM', 'Bagian Umum'), ('KEU', 'Bagian Keuangan')) as v(code, name)
cross join (select id from public.organizational_units where code = 'SEK') p
on conflict (code) do nothing;

insert into public.organizational_units (code, name, parent_id)
select v.code, v.name, p.id
from (values ('RT', 'Subbagian Rumah Tangga'), ('TU', 'Subbagian Tata Usaha')) as v(code, name)
cross join (select id from public.organizational_units where code = 'UMUM') p
on conflict (code) do nothing;
