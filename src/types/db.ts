export type AppRole = 'almoxarife' | 'equipe_sa' | 'gestor' | 'admin';

export type MovementStatus =
  | 'rascunho'
  | 'aguardando_assinatura'
  | 'aguardando_aprovacao'
  | 'aguardando_sa'
  | 'sa_informada'
  | 'concluida'
  | 'cancelada';

export type EntryMethod = 'qr_code' | 'pesquisa_manual';

export interface Warehouse {
  id: string;
  code: string;
  name: string;
  active?: boolean;
}

export interface Settings {
  me_prefix: string;
  me_number_pattern: string;
  me_sequence_digits: number;
  require_approval: boolean;
  allow_delivered_above_requested: boolean;
  allow_duplicate_material_lines: boolean;
  sa_number_unique: boolean;
  sa_number_pattern: string;
  auto_complete_on_sa: boolean;
  timezone: string;
  company_name: string;
  updated_at?: string;
}

export interface Profile {
  id: string;
  email: string;
  full_name: string;
  active: boolean;
  default_warehouse_id: string | null;
}

export interface Access {
  profile: Profile | null;
  roles: AppRole[];
  warehouses: Warehouse[];
  settings: Settings | null;
}

export interface Lookup {
  id: string;
  code: string;
  name: string;
  active: boolean;
  kind?: 'frente' | 'equipamento';
  created_at?: string;
  updated_at?: string;
}

export interface Employee {
  id: string;
  registration: string;
  full_name: string;
  job_title: string | null;
  sector_id: string | null;
  active: boolean;
  created_at?: string;
  updated_at?: string;
}

export interface Material {
  id: string;
  code: string;
  reference: string | null;
  name: string;
  description: string | null;
  unit: string;
  location: string | null;
  account_id: string | null;
  account_code?: string | null;
  account_name?: string | null;
  category_id: string | null;
  category_name?: string | null;
  warehouse_id: string | null;
  warehouse_name?: string | null;
  qr_code: string;
  active: boolean;
  created_at?: string;
  updated_at?: string;
}

export interface CartItem {
  key: string;
  material: Material;
  quantity_requested: number;
  quantity_delivered: number;
  entry_method: EntryMethod;
  scanned_code: string | null;
  notes: string;
}

export interface MovementRow {
  id: string;
  me_number: string;
  movement_type: 'saida' | 'entrada';
  movement_at: string;
  warehouse_id: string;
  warehouse_code: string;
  warehouse_name: string;
  contract_id: string;
  contract_code: string;
  contract_name: string;
  sector_id: string;
  sector_name: string;
  service_front_id: string | null;
  service_front_name: string | null;
  service_order: string | null;
  fixed_asset: string | null;
  application_location_id: string | null;
  application_location: string | null;
  notes: string | null;
  status: MovementStatus;
  requester_employee_id: string;
  requester_name: string;
  requester_registration: string;
  requested_at: string;
  received_by_employee_id: string | null;
  received_by_name: string | null;
  received_by_registration: string | null;
  received_at: string | null;
  approved_by: string | null;
  approved_by_name: string | null;
  approved_at: string | null;
  storekeeper_id: string;
  storekeeper_name: string | null;
  sa_number: string | null;
  sa_informed_at: string | null;
  sa_informed_by: string | null;
  sa_informed_by_name: string | null;
  completed_at: string | null;
  completed_by: string | null;
  completed_by_name: string | null;
  cancelled_at: string | null;
  cancelled_by: string | null;
  cancelled_by_name: string | null;
  cancel_reason: string | null;
  item_count: number;
  total_requested: number;
  total_delivered: number;
  materials_summary: string | null;
  is_demo: boolean;
  created_at: string;
  created_by: string;
  updated_at: string;
  updated_by: string | null;
  updated_by_name: string | null;
}

export interface MovementItem {
  id: string;
  movement_id: string;
  line_number: number;
  material_id: string;
  material_code: string;
  material_reference: string | null;
  material_name: string;
  unit: string;
  location: string | null;
  account_code: string | null;
  account_name: string | null;
  quantity_requested: number;
  quantity_delivered: number;
  entry_method: EntryMethod;
  scanned_code: string | null;
  notes: string | null;
}

export interface SignatureRecord {
  id: string;
  movement_id: string;
  employee_id: string;
  signer_name: string;
  signer_registration: string;
  bucket: string;
  storage_path: string;
  mime_type: string;
  size_bytes: number | null;
  signed_at: string;
  uploaded_at: string;
  uploaded_by: string;
  is_current: boolean;
  replaced_at: string | null;
  replaced_by: string | null;
  replacement_reason: string | null;
}

export interface SaRecord {
  id: string;
  movement_id: string;
  me_number: string;
  sa_number: string;
  previous_sa_number: string | null;
  action: 'inclusao' | 'correcao';
  justification: string | null;
  informed_by: string;
  informed_at: string;
}

export interface StatusHistory {
  id: number;
  movement_id: string;
  from_status: MovementStatus | null;
  to_status: MovementStatus;
  changed_by: string | null;
  changed_at: string;
  reason: string | null;
}

export interface AuditLog {
  id: number;
  occurred_at: string;
  user_id: string | null;
  user_email: string | null;
  action: string;
  entity: string;
  entity_id: string | null;
  movement_id: string | null;
  warehouse_id: string | null;
  old_data: Record<string, unknown> | null;
  new_data: Record<string, unknown> | null;
  justification: string | null;
  source: string;
  ip_address: string | null;
  user_agent: string | null;
}

export interface AdminUser {
  id: string;
  email: string;
  full_name: string;
  active: boolean;
  default_warehouse_id: string | null;
  created_at: string;
  roles: AppRole[];
  warehouses: string[];
}

export interface DashboardData {
  cards: {
    total_mes: number;
    today_mes: number;
    item_lines: number;
    qty_delivered: number;
    aguardando_aprovacao: number;
    aguardando_sa: number;
    sa_informada: number;
    concluida: number;
    cancelada: number;
  };
  by_warehouse: { warehouse_id: string; warehouse: string; code: string; mes: number; pending_sa: number; item_lines: number }[];
  daily: { date: string; warehouse: string; mes: number }[];
  weekly: { week: string; warehouse: string; mes: number }[];
  monthly: { month: string; warehouse: string; mes: number }[];
  qty_by_unit: { unit: string; qty: number }[];
  top_materials_lines: { material: string; code: string; lines: number }[];
  top_materials_qty: { material: string; code: string; unit: string; qty: number }[];
  by_sector: { label: string; mes: number }[];
  by_service_front: { label: string; mes: number }[];
  by_user: { label: string; mes: number }[];
  pending_aging: { warehouse: string; bucket: string; mes: number }[];
}
