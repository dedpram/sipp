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
}

/** Hasil rpc_dashboard_overview */
export interface DashboardOverview {
  roles: RoleCode[];
  unread_notifications: number;
  active_units: number;
  generated_at: string;
  active_users?: number;
  inactive_users?: number;
  users_without_role?: number;
  audit_events_today?: number;
  recent_activity?: { occurred_at: string; user_name: string | null; action: string; table_name: string | null }[];
}
