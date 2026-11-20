import { buildLocationCode, categorySchema, itemSchema, supplierSchema, unitSchema } from './schemas';

const baseItem = {
  category_id: 'c1',
  code: ' atk-0001 ',
  name: 'Kertas HVS A4',
  unit_id: 'u1',
  specification: '',
  brand: '',
  min_stock: '10',
  safety_stock: '5',
  max_stock: '',
  has_expiry: false,
};

describe('validasi barang', () => {
  it('menormalkan kode menjadi huruf besar dan mengosongkan isian opsional', () => {
    const r = itemSchema.parse(baseItem);
    expect(r.code).toBe('ATK-0001');
    expect(r.max_stock).toBeNull();
    expect(r.brand).toBeNull();
    expect(r.min_stock).toBe(10);
  });

  it('menerima angka desimal dengan koma', () => {
    expect(itemSchema.parse({ ...baseItem, min_stock: '2,5' }).min_stock).toBe(2.5);
  });

  it('menolak stok minimum melebihi maksimum', () => {
    expect(itemSchema.safeParse({ ...baseItem, min_stock: '50', max_stock: '10' }).success).toBe(false);
  });

  it('menolak stok negatif dan bukan angka', () => {
    expect(itemSchema.safeParse({ ...baseItem, min_stock: '-1' }).success).toBe(false);
    expect(itemSchema.safeParse({ ...baseItem, safety_stock: 'abc' }).success).toBe(false);
  });

  it('menolak kode berisi spasi di tengah', () => {
    expect(itemSchema.safeParse({ ...baseItem, code: 'ATK 01' }).success).toBe(false);
  });

  it('mewajibkan kategori dan satuan', () => {
    expect(itemSchema.safeParse({ ...baseItem, category_id: '' }).success).toBe(false);
    expect(itemSchema.safeParse({ ...baseItem, unit_id: '' }).success).toBe(false);
  });
});

describe('validasi master lain', () => {
  it('kode kategori huruf besar tanpa spasi; kode akun angka & titik', () => {
    expect(categorySchema.parse({ code: 'atk', name: 'ATK', account_code: '117.111', description: '' }).code).toBe('ATK');
    expect(categorySchema.safeParse({ code: 'A T', name: 'X', account_code: '', description: '' }).success).toBe(false);
    expect(categorySchema.safeParse({ code: 'ATK', name: 'X', account_code: 'abc', description: '' }).success).toBe(false);
  });

  it('kode satuan hanya huruf', () => {
    expect(unitSchema.safeParse({ code: 'R1M', name: 'Rim' }).success).toBe(false);
    expect(unitSchema.parse({ code: 'rim', name: 'Rim' }).code).toBe('RIM');
  });

  it('NPWP boleh diketik dengan titik/tanda minus', () => {
    const r = supplierSchema.parse({ name: 'CV Maju', npwp: '01.234.567.8-901.234', contact_person: '', phone: '', email: '', address: '' });
    expect(r.npwp).toBe('012345678901234');
    expect(supplierSchema.safeParse({ name: 'CV Maju', npwp: '123', contact_person: '', phone: '', email: '', address: '' }).success).toBe(false);
  });

  it('membuat kode lokasi otomatis', () => {
    expect(buildLocationCode('GDG1', 'R. Persediaan', 'A', '01')).toBe('GDG1-A-01');
    expect(buildLocationCode('GDG1', 'R. Arsip', '-', '-')).toBe('GDG1-RARSIP');
  });
});
