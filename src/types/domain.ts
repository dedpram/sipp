import type { RoleCode } from '@/lib/roles';

export interface Profile {
  id: string;
  nip: string | null;
  full_name: string;
  email: string;
  position_title: string | null;
  primary_unit_id: string | null;
  phone: string | null;
  is_active: boolean;
  last_login_at: string | null;
  created_at: string;
}

export interface Role {
  id: string;
  code: RoleCode;
  name: string;
  description: string | null;
  sort_order: number;
}

export interface OrganizationalUnit {
  id: string;
  code: string;
  name: string;
  parent_id: string | null;
  head_user_id: string | null;
  is_active: boolean;
}

export interface UserRole {
  id: string;
  user_id: string;
  role_id: string;
  unit_id: string | null;
  valid_from: string;
  valid_until: string | null;
  assignment_ref: string | null;
  is_active: boolean;
}

/** Hasil rpc_my_context */
export interface MyContext {
  profile: {
    id: string;
    full_name: string;
    email: string;
    nip: string | null;
    position_title: string | null;
    phone: string | null;
    is_active: boolean;
    primary_unit_id: string | null;
    primary_unit_name: string | null;
  };
  roles: RoleCode[];
  scopes: { ATS: string[]; PGW: string[] };
  /** Pengguna ini wajib verifikasi dua langkah untuk tindakan Super Admin. */
  mfa_required: boolean;
}

/** Hasil rpc_dashboard_overview */
export interface DashboardOverview {
  roles: RoleCode[];
  unread_notifications: number;
  active_units: number;
  active_items: number;
  proposed_items?: number;
  mfa_required: boolean;
  mfa_satisfied: boolean;
  generated_at: string;
  active_users?: number;
  inactive_users?: number;
  users_without_role?: number;
  audit_events_today?: number;
  recent_activity?: { occurred_at: string; user_name: string | null; action: string; table_name: string | null }[];
}

// ------------------------------ Master data ------------------------------
export interface ItemCategory {
  id: string;
  code: string;
  name: string;
  account_code: string | null;
  description: string | null;
  is_active: boolean;
}

export interface ItemUnit {
  id: string;
  code: string;
  name: string;
  is_active: boolean;
}

export interface Item {
  id: string;
  code: string;
  name: string;
  category_id: string;
  unit_id: string;
  specification: string | null;
  brand: string | null;
  min_stock: number;
  safety_stock: number;
  max_stock: number | null;
  has_expiry: boolean;
  is_active: boolean;
  activated_at: string | null;
}

export interface Warehouse {
  id: string;
  code: string;
  name: string;
  address: string | null;
  pic_user_id: string | null;
  is_active: boolean;
}

export interface StorageLocation {
  id: string;
  warehouse_id: string;
  room: string;
  rack: string;
  location_number: string;
  code: string;
  description: string | null;
  is_active: boolean;
}

export interface Supplier {
  id: string;
  name: string;
  npwp: string | null;
  address: string | null;
  phone: string | null;
  email: string | null;
  contact_person: string | null;
  is_active: boolean;
}

export interface AppSetting {
  key: string;
  value: unknown;
  description: string | null;
}

export interface ApprovalSetting {
  id: string;
  transaction_type: string;
  level: number;
  approver_role_code: RoleCode;
  unit_scope: 'own_unit' | 'all';
  min_value: number | null;
  max_value: number | null;
  applies_when: Record<string, unknown>;
  is_required: boolean;
  is_active: boolean;
  description: string | null;
}
