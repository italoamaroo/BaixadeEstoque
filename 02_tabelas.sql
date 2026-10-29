-- =====================================================================
-- 02 - TABELAS, RELACIONAMENTOS, CONSTRAINTS E ÍNDICES
-- =====================================================================

-- ---------------------------------------------------------------------
-- Estoques (almoxarifados físicos)
-- ---------------------------------------------------------------------
create table if not exists public.warehouses (
  id          uuid primary key default gen_random_uuid(),
  code        text not null,
  name        text not null,
  active      boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  created_by  uuid,
  updated_by  uuid,
  constraint warehouses_code_uk unique (code),
  constraint warehouses_name_uk unique (name),
  constraint warehouses_code_fmt_ck check (code ~ '^[A-Z0-9]{2,6}$'),
  constraint warehouses_name_ck check (length(btrim(name)) between 2 and 80)
);

-- ---------------------------------------------------------------------
-- Perfis de usuários (1:1 com auth.users)
-- ---------------------------------------------------------------------
create table if not exists public.profiles (
  id                    uuid primary key references auth.users (id) on delete restrict,
  email                 text not null,
  full_name             text not null default '',
  active                boolean not null default true,
  default_warehouse_id  uuid references public.warehouses (id),
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  created_by            uuid,
  updated_by            uuid
);
create index if not exists profiles_email_idx on public.profiles (lower(email));

-- Agora que profiles existe, liga created_by/updated_by de warehouses
alter table public.warehouses
  drop constraint if exists warehouses_created_by_fk,
  add constraint warehouses_created_by_fk foreign key (created_by) references public.profiles (id),
  drop constraint if exists warehouses_updated_by_fk,
  add constraint warehouses_updated_by_fk foreign key (updated_by) references public.profiles (id);

create table if not exists public.user_roles (
  user_id     uuid not null references public.profiles (id) on delete cascade,
  role        public.app_role not null,
  created_at  timestamptz not null default now(),
  created_by  uuid references public.profiles (id),
  primary key (user_id, role)
);

create table if not exists public.user_warehouses (
  user_id       uuid not null references public.profiles (id) on delete cascade,
  warehouse_id  uuid not null references public.warehouses (id),
  created_at    timestamptz not null default now(),
  created_by    uuid references public.profiles (id),
  primary key (user_id, warehouse_id)
);
create index if not exists user_warehouses_wh_idx on public.user_warehouses (warehouse_id);

-- ---------------------------------------------------------------------
-- Parâmetros do sistema (linha única)
-- ---------------------------------------------------------------------
create table if not exists public.app_settings (
  id                                 smallint primary key default 1,
  me_prefix                          text not null default 'ME',
  me_number_pattern                  text not null default '{PREFIXO}-{ESTOQUE}-{ANO}-{SEQ}',
  me_sequence_digits                 smallint not null default 6,
  require_approval                   boolean not null default false,
  allow_delivered_above_requested    boolean not null default false,
  allow_duplicate_material_lines     boolean not null default false,
  sa_number_unique                   boolean not null default true,
  sa_number_pattern                  text not null default '^[A-Za-z0-9./-]{3,30}$',
  auto_complete_on_sa                boolean not null default false,
  timezone                           text not null default 'America/Recife',
  company_name                       text not null default 'Consórcio Recife Ambiental',
  updated_at                         timestamptz not null default now(),
  updated_by                         uuid references public.profiles (id),
  constraint app_settings_singleton_ck check (id = 1),
  constraint app_settings_digits_ck check (me_sequence_digits between 3 and 10),
  constraint app_settings_pattern_ck check (position('{SEQ}' in me_number_pattern) > 0),
  constraint app_settings_prefix_ck check (me_prefix ~ '^[A-Z0-9]{1,6}$')
);

-- ---------------------------------------------------------------------
-- Tabelas auxiliares (cadastros)
-- Todas seguem o mesmo padrão: código único, nome, ativo/inativo.
-- ---------------------------------------------------------------------
create table if not exists public.contracts (
  id uuid primary key default gen_random_uuid(),
  code text not null, name text not null, active boolean not null default true,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  created_by uuid references public.profiles (id), updated_by uuid references public.profiles (id),
  constraint contracts_code_uk unique (code),
  constraint contracts_code_ck check (length(btrim(code)) between 1 and 40),
  constraint contracts_name_ck check (length(btrim(name)) between 2 and 160)
);

create table if not exists public.sectors (
  id uuid primary key default gen_random_uuid(),
  code text not null, name text not null, active boolean not null default true,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  created_by uuid references public.profiles (id), updated_by uuid references public.profiles (id),
  constraint sectors_code_uk unique (code),
  constraint sectors_code_ck check (length(btrim(code)) between 1 and 40),
  constraint sectors_name_ck check (length(btrim(name)) between 2 and 160)
);

-- Frente de serviço / equipamento
create table if not exists public.service_fronts (
  id uuid primary key default gen_random_uuid(),
  code text not null, name text not null,
  kind text not null default 'frente',
  active boolean not null default true,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  created_by uuid references public.profiles (id), updated_by uuid references public.profiles (id),
  constraint service_fronts_code_uk unique (code),
  constraint service_fronts_kind_ck check (kind in ('frente', 'equipamento')),
  constraint service_fronts_code_ck check (length(btrim(code)) between 1 and 40),
  constraint service_fronts_name_ck check (length(btrim(name)) between 2 and 160)
);

create table if not exists public.service_orders (
  id uuid primary key default gen_random_uuid(),
  code text not null, name text not null, active boolean not null default true,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  created_by uuid references public.profiles (id), updated_by uuid references public.profiles (id),
  constraint service_orders_code_uk unique (code),
  constraint service_orders_code_ck check (length(btrim(code)) between 1 and 40),
  constraint service_orders_name_ck check (length(btrim(name)) between 2 and 160)
);

-- Ativo fixo (AF)
create table if not exists public.fixed_assets (
  id uuid primary key default gen_random_uuid(),
  code text not null, name text not null, active boolean not null default true,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  created_by uuid references public.profiles (id), updated_by uuid references public.profiles (id),
  constraint fixed_assets_code_uk unique (code),
  constraint fixed_assets_code_ck check (length(btrim(code)) between 1 and 40),
  constraint fixed_assets_name_ck check (length(btrim(name)) between 2 and 160)
);

create table if not exists public.application_locations (
  id uuid primary key default gen_random_uuid(),
  code text not null, name text not null, active boolean not null default true,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  created_by uuid references public.profiles (id), updated_by uuid references public.profiles (id),
  constraint application_locations_code_uk unique (code),
  constraint application_locations_code_ck check (length(btrim(code)) between 1 and 40),
  constraint application_locations_name_ck check (length(btrim(name)) between 2 and 160)
);

-- Conta contábil / centro de custo
create table if not exists public.accounts (
  id uuid primary key default gen_random_uuid(),
  code text not null, name text not null, active boolean not null default true,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  created_by uuid references public.profiles (id), updated_by uuid references public.profiles (id),
  constraint accounts_code_uk unique (code),
  constraint accounts_code_ck check (length(btrim(code)) between 1 and 40),
  constraint accounts_name_ck check (length(btrim(name)) between 2 and 160)
);

create table if not exists public.material_categories (
  id uuid primary key default gen_random_uuid(),
  code text not null, name text not null, active boolean not null default true,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  created_by uuid references public.profiles (id), updated_by uuid references public.profiles (id),
  constraint material_categories_code_uk unique (code),
  constraint material_categories_code_ck check (length(btrim(code)) between 1 and 40),
  constraint material_categories_name_ck check (length(btrim(name)) between 2 and 160)
);

-- ---------------------------------------------------------------------
-- Funcionários (requisitantes / recebedores)
-- ---------------------------------------------------------------------
create table if not exists public.employees (
  id            uuid primary key default gen_random_uuid(),
  registration  text not null,              -- matrícula
  full_name     text not null,
  job_title     text,
  sector_id     uuid references public.sectors (id),
  active        boolean not null default true,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  created_by    uuid references public.profiles (id),
  updated_by    uuid references public.profiles (id),
  constraint employees_registration_uk unique (registration),
  constraint employees_registration_ck check (length(btrim(registration)) between 1 and 30),
  constraint employees_name_ck check (length(btrim(full_name)) between 3 and 160)
);
create index if not exists employees_name_trgm_idx on public.employees using gin (full_name extensions.gin_trgm_ops);

-- ---------------------------------------------------------------------
-- Materiais (cadastro mestre)
-- ---------------------------------------------------------------------
create table if not exists public.materials (
  id            uuid primary key default gen_random_uuid(),
  code          text not null,               -- código do material
  reference     text,                        -- referência (fabricante/peça)
  name          text not null,
  description   text,
  unit          text not null,               -- UN, L, KG, PC, CX...
  location      text,                        -- localização física (ex.: A-01-03)
  account_id    uuid references public.accounts (id),
  category_id   uuid references public.material_categories (id),
  warehouse_id  uuid references public.warehouses (id),   -- estoque relacionado (opcional)
  qr_code       text not null,               -- identificador principal impresso no QR Code
  active        boolean not null default true,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  created_by    uuid references public.profiles (id),
  updated_by    uuid references public.profiles (id),
  constraint materials_code_uk unique (code),
  constraint materials_qr_code_uk unique (qr_code),
  constraint materials_code_ck check (code ~ '^[A-Za-z0-9._/-]{1,40}$'),
  constraint materials_qr_code_ck check (qr_code ~ '^[A-Za-z0-9._:-]{4,80}$'),
  constraint materials_name_ck check (length(btrim(name)) between 2 and 200),
  constraint materials_unit_ck check (unit ~ '^[A-Za-z0-9²³/]{1,10}$')
);
create index if not exists materials_reference_idx on public.materials (reference);
create index if not exists materials_name_trgm_idx on public.materials using gin (name extensions.gin_trgm_ops);
create index if not exists materials_active_idx on public.materials (active);

-- Histórico de QR Codes do material (permite reimpressão/troca sem perder rastreio)
create table if not exists public.material_qr_codes (
  id           uuid primary key default gen_random_uuid(),
  material_id  uuid not null references public.materials (id),
  code         text not null,
  active       boolean not null default true,
  printed_at   timestamptz,
  created_at   timestamptz not null default now(),
  created_by   uuid references public.profiles (id),
  constraint material_qr_codes_code_uk unique (code),
  constraint material_qr_codes_code_ck check (code ~ '^[A-Za-z0-9._:-]{4,80}$')
);
create index if not exists material_qr_codes_material_idx on public.material_qr_codes (material_id);

-- ---------------------------------------------------------------------
-- Sequência da numeração da ME (por estoque e ano)
-- ---------------------------------------------------------------------
create table if not exists public.movement_sequences (
  warehouse_id  uuid not null references public.warehouses (id),
  year          integer not null,
  last_value    integer not null default 0,
  updated_at    timestamptz not null default now(),
  primary key (warehouse_id, year),
  constraint movement_sequences_year_ck check (year between 2000 and 2999),
  constraint movement_sequences_value_ck check (last_value >= 0)
);

-- ---------------------------------------------------------------------
-- ME - Movimentação de Estoque (cabeçalho)
-- ---------------------------------------------------------------------
create table if not exists public.stock_movements (
  id                        uuid primary key,              -- gerado no cliente = chave de idempotência
  me_number                 text not null,
  movement_type             public.movement_type not null default 'saida',
  movement_at               timestamptz not null default now(),
  warehouse_id              uuid not null references public.warehouses (id),
  contract_id               uuid not null references public.contracts (id),
  sector_id                 uuid not null references public.sectors (id),
  service_front_id          uuid references public.service_fronts (id),
  service_order_id          uuid references public.service_orders (id),
  service_order_text        text,
  fixed_asset_id            uuid references public.fixed_assets (id),
  fixed_asset_text          text,
  application_location_id   uuid references public.application_locations (id),
  application_location_text text,
  notes                     text,
  status                    public.movement_status not null default 'aguardando_sa',

  -- Responsáveis
  requester_employee_id     uuid not null references public.employees (id),
  requester_name            text not null,          -- cópia no momento da saída
  requester_registration    text not null,          -- cópia no momento da saída
  requested_at              timestamptz not null default now(),
  received_by_employee_id   uuid references public.employees (id),
  received_by_name          text,
  received_by_registration  text,
  received_at               timestamptz,
  approved_by               uuid references public.profiles (id),
  approved_at               timestamptz,
  storekeeper_id            uuid not null references public.profiles (id),  -- almoxarife responsável pela baixa

  -- SA (ERP)
  sa_number                 text,
  sa_informed_at            timestamptz,
  sa_informed_by            uuid references public.profiles (id),
  completed_at              timestamptz,
  completed_by              uuid references public.profiles (id),

  -- Cancelamento lógico
  cancelled_at              timestamptz,
  cancelled_by              uuid references public.profiles (id),
  cancel_reason             text,

  -- Totais desnormalizados (mantidos por trigger)
  item_count                integer not null default 0,
  total_requested           numeric(14,3) not null default 0,
  total_delivered           numeric(14,3) not null default 0,

  is_demo                   boolean not null default false,
  created_at                timestamptz not null default now(),
  updated_at                timestamptz not null default now(),
  created_by                uuid not null references public.profiles (id),
  updated_by                uuid references public.profiles (id),

  constraint stock_movements_me_number_uk unique (me_number),
  constraint stock_movements_cancel_ck check (
    (status = 'cancelada' and cancelled_at is not null and cancelled_by is not null and length(btrim(coalesce(cancel_reason, ''))) >= 5)
    or (status <> 'cancelada')
  ),
  constraint stock_movements_sa_ck check (
    status not in ('sa_informada', 'concluida') or sa_number is not null
  ),
  constraint stock_movements_notes_ck check (notes is null or length(notes) <= 2000)
);
create index if not exists stock_movements_warehouse_idx on public.stock_movements (warehouse_id, movement_at desc);
create index if not exists stock_movements_status_idx on public.stock_movements (status, movement_at desc);
create index if not exists stock_movements_movement_at_idx on public.stock_movements (movement_at desc);
create index if not exists stock_movements_sa_number_idx on public.stock_movements (sa_number);
create index if not exists stock_movements_requester_idx on public.stock_movements (requester_employee_id);
create index if not exists stock_movements_storekeeper_idx on public.stock_movements (storekeeper_id);
create index if not exists stock_movements_sector_idx on public.stock_movements (sector_id);
create index if not exists stock_movements_front_idx on public.stock_movements (service_front_id);
create index if not exists stock_movements_me_trgm_idx on public.stock_movements using gin (me_number extensions.gin_trgm_ops);

-- ---------------------------------------------------------------------
-- Itens da ME (com cópia dos dados do material no momento da saída)
-- ---------------------------------------------------------------------
create table if not exists public.stock_movement_items (
  id                   uuid primary key default gen_random_uuid(),
  movement_id          uuid not null references public.stock_movements (id),
  line_number          integer not null,
  material_id          uuid not null references public.materials (id),
  material_code        text not null,
  material_reference   text,
  material_name        text not null,
  unit                 text not null,
  location             text,
  account_code         text,
  account_name         text,
  quantity_requested   numeric(14,3) not null,
  quantity_delivered   numeric(14,3) not null,
  entry_method         public.item_entry_method not null default 'qr_code',
  scanned_code         text,
  notes                text,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  created_by           uuid references public.profiles (id),
  updated_by           uuid references public.profiles (id),
  constraint stock_movement_items_line_uk unique (movement_id, line_number),
  constraint stock_movement_items_qty_req_ck check (quantity_requested > 0),
  constraint stock_movement_items_qty_del_ck check (quantity_delivered > 0),
  constraint stock_movement_items_line_ck check (line_number > 0),
  constraint stock_movement_items_notes_ck check (notes is null or length(notes) <= 500)
);
create index if not exists stock_movement_items_movement_idx on public.stock_movement_items (movement_id);
create index if not exists stock_movement_items_material_idx on public.stock_movement_items (material_id);
create index if not exists stock_movement_items_code_idx on public.stock_movement_items (material_code);
create index if not exists stock_movement_items_reference_idx on public.stock_movement_items (material_reference);
create index if not exists stock_movement_items_name_trgm_idx on public.stock_movement_items using gin (material_name extensions.gin_trgm_ops);

-- ---------------------------------------------------------------------
-- Assinaturas (arquivo no Storage; aqui só metadados)
-- ---------------------------------------------------------------------
create table if not exists public.signatures (
  id                    uuid primary key default gen_random_uuid(),
  movement_id           uuid not null references public.stock_movements (id),
  employee_id           uuid not null references public.employees (id),
  signer_name           text not null,
  signer_registration   text not null,
  bucket                text not null default 'assinaturas',
  storage_path          text not null,
  mime_type             text not null default 'image/png',
  size_bytes            integer,
  signed_at             timestamptz not null,
  uploaded_at           timestamptz not null default now(),
  uploaded_by           uuid not null references public.profiles (id),
  is_current            boolean not null default true,
  replaced_at           timestamptz,
  replaced_by           uuid references public.profiles (id),
  replacement_reason    text,
  constraint signatures_path_uk unique (bucket, storage_path),
  constraint signatures_mime_ck check (mime_type in ('image/png', 'image/jpeg', 'image/webp')),
  constraint signatures_size_ck check (size_bytes is null or size_bytes between 1 and 2000000)
);
create unique index if not exists signatures_one_current_uk on public.signatures (movement_id) where is_current;
create index if not exists signatures_movement_idx on public.signatures (movement_id);

-- ---------------------------------------------------------------------
-- Registros de SA (inclusão e correções)
-- ---------------------------------------------------------------------
create table if not exists public.erp_sa_records (
  id                  uuid primary key default gen_random_uuid(),
  movement_id         uuid not null references public.stock_movements (id),
  me_number           text not null,
  sa_number           text not null,
  previous_sa_number  text,
  action              public.sa_action not null,
  justification       text,
  informed_by         uuid not null references public.profiles (id),
  informed_at         timestamptz not null default now(),
  constraint erp_sa_records_just_ck check (action = 'inclusao' or length(btrim(coalesce(justification, ''))) >= 5)
);
create index if not exists erp_sa_records_movement_idx on public.erp_sa_records (movement_id);
create index if not exists erp_sa_records_sa_idx on public.erp_sa_records (sa_number);

-- ---------------------------------------------------------------------
-- Histórico de status
-- ---------------------------------------------------------------------
create table if not exists public.movement_status_history (
  id           bigint generated always as identity primary key,
  movement_id  uuid not null references public.stock_movements (id),
  from_status  public.movement_status,
  to_status    public.movement_status not null,
  changed_by   uuid references public.profiles (id),
  changed_at   timestamptz not null default now(),
  reason       text
);
create index if not exists movement_status_history_movement_idx on public.movement_status_history (movement_id, changed_at);

-- ---------------------------------------------------------------------
-- Auditoria (somente inserção via funções do banco)
-- ---------------------------------------------------------------------
create table if not exists public.audit_logs (
  id             bigint generated always as identity primary key,
  occurred_at    timestamptz not null default now(),
  user_id        uuid,
  user_email     text,
  action         text not null,
  entity         text not null,
  entity_id      text,
  movement_id    uuid,
  warehouse_id   uuid,
  old_data       jsonb,
  new_data       jsonb,
  justification  text,
  source         text not null default 'app',
  ip_address     text,
  user_agent     text
);
create index if not exists audit_logs_occurred_idx on public.audit_logs (occurred_at desc);
create index if not exists audit_logs_movement_idx on public.audit_logs (movement_id, occurred_at);
create index if not exists audit_logs_entity_idx on public.audit_logs (entity, entity_id);
create index if not exists audit_logs_user_idx on public.audit_logs (user_id, occurred_at desc);
create index if not exists audit_logs_action_idx on public.audit_logs (action);
