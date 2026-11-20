/** Data acuan bersama untuk modul transaksi (barang, lokasi, penyedia, nama pengguna). */
import { useMemo } from 'react';
import { useQuery } from '@tanstack/react-query';
import { supabase } from '@/lib/supabase';
import type { Item, ItemUnit, StorageLocation, Supplier, Warehouse } from '@/types/domain';

async function fetchAll<T>(table: string, select: string, order: string): Promise<T[]> {
  const { data, error } = await supabase.from(table).select(select).order(order);
  if (error) throw error;
  return (data ?? []) as unknown as T[];
}

export function useLookups() {
  const items = useQuery({
    queryKey: ['master', 'items'],
    queryFn: () =>
      fetchAll<Item>(
        'items',
        'id, code, name, category_id, unit_id, specification, brand, min_stock, safety_stock, max_stock, has_expiry, is_active, activated_at',
        'code',
      ),
  });
  const units = useQuery({ queryKey: ['master', 'item_units'], queryFn: () => fetchAll<ItemUnit>('item_units', 'id, code, name, is_active', 'name') });
  const warehouses = useQuery({
    queryKey: ['master', 'warehouses'],
    queryFn: () => fetchAll<Warehouse>('warehouses', 'id, code, name, address, pic_user_id, is_active', 'code'),
  });
  const locations = useQuery({
    queryKey: ['master', 'storage_locations'],
    queryFn: () =>
      fetchAll<StorageLocation>('storage_locations', 'id, warehouse_id, room, rack, location_number, code, description, is_active', 'code'),
  });
  const suppliers = useQuery({
    queryKey: ['master', 'suppliers'],
    queryFn: () => fetchAll<Supplier>('suppliers', 'id, name, npwp, address, phone, email, contact_person, is_active', 'name'),
  });
  const people = useQuery({
    queryKey: ['master', 'people'],
    queryFn: () => fetchAll<{ id: string; full_name: string }>('profiles', 'id, full_name', 'full_name'),
  });

  return useMemo(() => {
    const map = <T extends { id: string }>(list?: T[]) => new Map((list ?? []).map((x) => [x.id, x]));
    const unitMap = map(units.data);
    const itemMap = map(items.data);
    const personMap = map(people.data);
    return {
      items: items.data ?? [],
      warehouses: warehouses.data ?? [],
      locations: locations.data ?? [],
      suppliers: suppliers.data ?? [],
      itemMap,
      unitMap,
      warehouseMap: map(warehouses.data),
      locationMap: map(locations.data),
      supplierMap: map(suppliers.data),
      personMap,
      unitName: (itemId: string) => unitMap.get(itemMap.get(itemId)?.unit_id ?? '')?.name ?? '',
      person: (id: string | null | undefined) => (id ? (personMap.get(id)?.full_name ?? '—') : '—'),
      loading: items.isLoading || warehouses.isLoading || locations.isLoading,
    };
  }, [items.data, units.data, warehouses.data, locations.data, suppliers.data, people.data, items.isLoading, warehouses.isLoading, locations.isLoading]);
}
