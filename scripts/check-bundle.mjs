// Memeriksa hasil build (folder dist) agar TIDAK mengandung kunci rahasia.
// Gagal (exit 1) bila ditemukan service role key / secret key.
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';

const root = 'dist';
const files = [];
(function walk(dir) {
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) walk(p);
    else if (/\.(js|html|css|json|map|txt)$/.test(name)) files.push(p);
  }
})(root);

const problems = [];
const jwtRe = /eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/g;

for (const file of files) {
  const text = readFileSync(file, 'utf8');
  if (/sb_secret_[A-Za-z0-9_-]+/.test(text)) problems.push(`${file}: mengandung Supabase secret key (sb_secret_...)`);
  for (const token of text.match(jwtRe) ?? []) {
    try {
      const payload = JSON.parse(Buffer.from(token.split('.')[1], 'base64url').toString('utf8'));
      if (payload.role && payload.role !== 'anon') problems.push(`${file}: JWT dengan role "${payload.role}" ditemukan`);
    } catch {
      /* bukan JWT valid */
    }
  }
  if (/SUPABASE_SERVICE_ROLE_KEY\s*[:=]\s*['"][^'"]+['"]/.test(text)) problems.push(`${file}: nilai SUPABASE_SERVICE_ROLE_KEY ditemukan`);
}

if (problems.length) {
  console.error('❌ Pemeriksaan keamanan bundle GAGAL:');
  for (const p of problems) console.error('  - ' + p);
  process.exit(1);
}
console.log(`✅ Tidak ada kunci rahasia pada ${files.length} file hasil build.`);
