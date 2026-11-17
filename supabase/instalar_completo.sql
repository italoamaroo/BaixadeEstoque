-- =====================================================================
-- INSTALAÇÃO COMPLETA (gerado por scripts/montar-sql.mjs — não edite à mão)
-- Arquivos: 01_extensoes_e_tipos.sql, 02_tabelas.sql, 03_funcoes_e_triggers.sql, 04_rpc_movimentacoes.sql, 05_rpc_administracao.sql, 06_rls_e_permissoes.sql, 07_storage.sql, 07b_balcao.sql, 07c_retirada_repetida.sql, 07d_me_emergencial.sql, 07e_auditoria_base.sql, 07f_seguranca_alertas_retencao.sql, 07g_incidentes_lgpd.sql, 07h_pedidos_titulares.sql, 07i_reconhecimento_facial.sql, 08_dados_iniciais.sql
-- Dados fictícios NÃO incluídos: execute 09_dados_ficticios.sql à parte.
-- =====================================================================
set client_min_messages = warning;

-- >>>>>>>>>> 01_extensoes_e_tipos.sql
-- =====================================================================
-- 01 - EXTENSÕES E TIPOS
-- Sistema de Baixas de Estoque por QR Code - Consórcio Recife Ambiental
-- Executar no SQL Editor do Supabase, na ordem numérica dos arquivos.
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;
create extension if not exists pg_trgm with schema extensions;

-- Perfis de acesso
do $$ begin
  create type public.app_role as enum ('almoxarife', 'equipe_sa', 'gestor', 'admin', 'terminal');
exception when duplicate_object then null; end $$;

-- Status da ME (Movimentação de Estoque)
do $$ begin
  create type public.movement_status as enum (
    'rascunho',
    'aguardando_assinatura',
    'aguardando_aprovacao',
    'aguardando_sa',
    'sa_informada',
    'concluida',
    'cancelada'
  );
exception when duplicate_object then null; end $$;

-- Tipo de movimentação (o formulário em papel possui SAÍDA / ENTRADA)
do $$ begin
  create type public.movement_type as enum ('saida', 'entrada');
exception when duplicate_object then null; end $$;

-- Forma de inclusão do item na ME
do $$ begin
  create type public.item_entry_method as enum ('qr_code', 'pesquisa_manual');
exception when duplicate_object then null; end $$;

-- Ações registradas sobre a SA
do $$ begin
  create type public.sa_action as enum ('inclusao', 'correcao');
exception when duplicate_object then null; end $$;


-- >>>>>>>>>> 02_tabelas.sql
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
  requires_sa               boolean not null default true,
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
  -- ME sem ativo fixo não passa pela SA: vai direto para a baixa no ERP pelo almoxarife
  constraint stock_movements_sa_ck check (
    status not in ('sa_informada', 'concluida') or sa_number is not null or not requires_sa
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


-- >>>>>>>>>> 03_funcoes_e_triggers.sql
-- =====================================================================
-- 03 - FUNÇÕES AUXILIARES, TRIGGERS, updated_at, AUDITORIA E PROTEÇÕES
-- =====================================================================

-- ---------------------------------------------------------------------
-- Funções de autorização (SECURITY DEFINER para evitar recursão de RLS)
-- ---------------------------------------------------------------------
create or replace function public.is_active_user()
returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$
  select exists (select 1 from public.profiles p where p.id = auth.uid() and p.active);
$$;

create or replace function public.has_role(p_role public.app_role)
returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
      from public.user_roles ur
      join public.profiles p on p.id = ur.user_id
     where ur.user_id = auth.uid()
       and ur.role = p_role
       and p.active
  );
$$;

create or replace function public.has_any_role(p_roles public.app_role[])
returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
      from public.user_roles ur
      join public.profiles p on p.id = ur.user_id
     where ur.user_id = auth.uid()
       and ur.role = any (p_roles)
       and p.active
  );
$$;

create or replace function public.is_admin()
returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$
  select public.has_role('admin');
$$;

create or replace function public.can_manage_master_data()
returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$
  -- Cadastros de materiais, funcionários e tabelas auxiliares: administrador e almoxarife.
  select public.has_any_role(array['admin', 'almoxarife']::public.app_role[]);
$$;

-- Administrador acessa todos os estoques; demais perfis somente os vinculados.
create or replace function public.can_access_warehouse(p_warehouse_id uuid)
returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$
  select public.is_admin()
      or exists (
        select 1
          from public.user_warehouses uw
          join public.profiles p on p.id = uw.user_id
         where uw.user_id = auth.uid()
           and uw.warehouse_id = p_warehouse_id
           and p.active
           and exists (select 1 from public.user_roles ur where ur.user_id = p.id)
      );
$$;

create or replace function public.can_access_warehouse_code(p_code text)
returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.warehouses w
     where w.code = p_code and public.can_access_warehouse(w.id)
  );
$$;

create or replace function public.can_access_movement(p_movement_id uuid)
returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.stock_movements m
     where m.id = p_movement_id and public.can_access_warehouse(m.warehouse_id)
  );
$$;

create or replace function public.get_settings()
returns public.app_settings
language sql stable security definer
set search_path = public, pg_temp
as $$
  select s from public.app_settings s where s.id = 1;
$$;

-- ---------------------------------------------------------------------
-- Contexto de auditoria (justificativa, origem, IP e user-agent)
-- As funções RPC preenchem app.justification / app.source / app.audit_action
-- com set_config(..., true), que vale somente para a transação corrente.
-- ---------------------------------------------------------------------
create or replace function public.request_header(p_name text)
returns text
language plpgsql stable
set search_path = public, pg_temp
as $$
declare
  v_headers text := current_setting('request.headers', true);
begin
  if v_headers is null or v_headers = '' then
    return null;
  end if;
  return (v_headers::jsonb ->> p_name);
exception when others then
  return null;
end;
$$;

create or replace function public.write_audit(
  p_action        text,
  p_entity        text,
  p_entity_id     text,
  p_movement_id   uuid,
  p_warehouse_id  uuid,
  p_old           jsonb,
  p_new           jsonb,
  p_justification text default null
)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_uid   uuid := auth.uid();
  v_email text;
begin
  if v_uid is not null then
    select email into v_email from public.profiles where id = v_uid;
  end if;

  insert into public.audit_logs (
    user_id, user_email, action, entity, entity_id, movement_id, warehouse_id,
    old_data, new_data, justification, source, ip_address, user_agent
  ) values (
    v_uid, v_email, p_action, p_entity, p_entity_id, p_movement_id, p_warehouse_id,
    p_old, p_new,
    coalesce(p_justification, nullif(current_setting('app.justification', true), '')),
    coalesce(nullif(current_setting('app.source', true), ''), case when v_uid is null then 'sistema' else 'app' end),
    split_part(coalesce(public.request_header('x-forwarded-for'), public.request_header('x-real-ip'), ''), ',', 1),
    left(public.request_header('user-agent'), 300)
  );
end;
$$;

revoke all on function public.write_audit(text, text, text, uuid, uuid, jsonb, jsonb, text) from public, anon, authenticated;

-- Diferença entre dois registros JSON (somente chaves alteradas)
create or replace function public.jsonb_diff(p_old jsonb, p_new jsonb, out old_part jsonb, out new_part jsonb)
language plpgsql immutable
set search_path = public, pg_temp
as $$
declare
  k text;
begin
  old_part := '{}'::jsonb;
  new_part := '{}'::jsonb;
  for k in select jsonb_object_keys(p_new) loop
    if k in ('updated_at', 'updated_by') then
      continue;
    end if;
    if (p_old -> k) is distinct from (p_new -> k) then
      old_part := old_part || jsonb_build_object(k, p_old -> k);
      new_part := new_part || jsonb_build_object(k, p_new -> k);
    end if;
  end loop;
end;
$$;

-- ---------------------------------------------------------------------
-- Trigger genérico de auditoria
-- ---------------------------------------------------------------------
create or replace function public.tg_audit_row()
returns trigger
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_old        jsonb;
  v_new        jsonb;
  v_diff_old   jsonb;
  v_diff_new   jsonb;
  v_action     text;
  v_movement   uuid;
  v_warehouse  uuid;
  v_entity_id  text;
  v_custom     text := nullif(current_setting('app.audit_action', true), '');
begin
  -- Atualização interna dos totais da ME não gera evento próprio
  -- (cada item incluído/alterado já é auditado individualmente).
  if tg_op = 'UPDATE' and coalesce(current_setting('app.internal_totals', true), '') = 'on' then
    return null;
  end if;

  if tg_op in ('UPDATE', 'DELETE') then v_old := to_jsonb(old); end if;
  if tg_op in ('INSERT', 'UPDATE') then v_new := to_jsonb(new); end if;

  if tg_op = 'UPDATE' then
    select d.old_part, d.new_part into v_diff_old, v_diff_new from public.jsonb_diff(v_old, v_new) d;
    if v_diff_new = '{}'::jsonb then
      return null;  -- nada relevante mudou
    end if;
    v_old := v_diff_old;
    v_new := v_diff_new;
  end if;

  v_entity_id := coalesce(v_new ->> 'id', v_old ->> 'id',
                          coalesce(v_new, v_old) ->> 'user_id');

  if tg_table_name = 'stock_movements' then
    v_movement  := coalesce((v_new ->> 'id')::uuid, (v_old ->> 'id')::uuid, (to_jsonb(new) ->> 'id')::uuid);
    v_warehouse := coalesce((to_jsonb(new) ->> 'warehouse_id')::uuid, (to_jsonb(old) ->> 'warehouse_id')::uuid);
    v_action := case tg_op
                  when 'INSERT' then 'me.criada'
                  when 'UPDATE' then coalesce(v_custom, 'me.alterada')
                  else 'me.excluida' end;
    if v_entity_id is null then v_entity_id := v_movement::text; end if;
  elsif tg_table_name in ('stock_movement_items', 'signatures', 'erp_sa_records') then
    v_movement := coalesce((to_jsonb(new) ->> 'movement_id')::uuid, (to_jsonb(old) ->> 'movement_id')::uuid);
    select m.warehouse_id into v_warehouse from public.stock_movements m where m.id = v_movement;
    v_action := case
      when tg_table_name = 'stock_movement_items' then
        case tg_op when 'INSERT' then 'item.incluido' when 'UPDATE' then 'item.alterado' else 'item.excluido' end
      when tg_table_name = 'signatures' then
        case tg_op when 'INSERT' then 'assinatura.capturada' when 'UPDATE' then 'assinatura.substituida' else 'assinatura.excluida' end
      else
        case tg_op when 'INSERT' then 'sa.' || (to_jsonb(new) ->> 'action') else 'sa.registro_alterado' end
    end;
  else
    v_action := tg_table_name || '.' || case tg_op when 'INSERT' then 'criado' when 'UPDATE' then 'alterado' else 'excluido' end;
  end if;

  perform public.write_audit(v_action, tg_table_name, v_entity_id, v_movement, v_warehouse, v_old, v_new, null);
  return null;
end;
$$;

-- ---------------------------------------------------------------------
-- updated_at / updated_by / created_by automáticos
-- ---------------------------------------------------------------------
create or replace function public.tg_set_timestamps()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'INSERT' then
    new.created_at := coalesce(new.created_at, now());
    new.updated_at := now();
    if new.created_by is null then
      new.created_by := auth.uid();
    end if;
  else
    new.updated_at := now();
    if auth.uid() is not null then
      new.updated_by := auth.uid();
    end if;
    new.created_at := old.created_at;
    new.created_by := old.created_by;
  end if;
  return new;
end;
$$;

-- ---------------------------------------------------------------------
-- Cria o perfil automaticamente quando um usuário é criado no Supabase Auth
-- ---------------------------------------------------------------------
create or replace function public.handle_new_auth_user()
returns trigger
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  insert into public.profiles (id, email, full_name, active)
  values (
    new.id,
    coalesce(new.email, ''),
    coalesce(nullif(new.raw_user_meta_data ->> 'full_name', ''), split_part(coalesce(new.email, ''), '@', 1)),
    true
  )
  on conflict (id) do update set email = excluded.email;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_auth_user();

create or replace function public.handle_auth_user_email_change()
returns trigger
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  if new.email is distinct from old.email then
    update public.profiles set email = coalesce(new.email, '') where id = new.id;
  end if;
  return new;
end;
$$;

drop trigger if exists on_auth_user_email_changed on auth.users;
create trigger on_auth_user_email_changed
  after update of email on auth.users
  for each row execute function public.handle_auth_user_email_change();

-- ---------------------------------------------------------------------
-- Totais da ME (quantidade de itens e somas)
-- ---------------------------------------------------------------------
create or replace function public.tg_refresh_movement_totals()
returns trigger
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid := coalesce(new.movement_id, old.movement_id);
begin
  perform set_config('app.internal_totals', 'on', true);
  update public.stock_movements m
     set item_count      = t.cnt,
         total_requested = t.req,
         total_delivered = t.del
    from (
      select count(*)::int as cnt,
             coalesce(sum(quantity_requested), 0) as req,
             coalesce(sum(quantity_delivered), 0) as del
        from public.stock_movement_items
       where movement_id = v_id
    ) t
   where m.id = v_id
     and (m.item_count, m.total_requested, m.total_delivered) is distinct from (t.cnt, t.req, t.del);
  perform set_config('app.internal_totals', 'off', true);
  return null;
end;
$$;

-- ---------------------------------------------------------------------
-- Histórico de status
-- ---------------------------------------------------------------------
create or replace function public.tg_movement_status_history()
returns trigger
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'INSERT' then
    insert into public.movement_status_history (movement_id, from_status, to_status, changed_by, reason)
    values (new.id, null, new.status, auth.uid(), nullif(current_setting('app.justification', true), ''));
  elsif new.status is distinct from old.status then
    insert into public.movement_status_history (movement_id, from_status, to_status, changed_by, reason)
    values (new.id, old.status, new.status, auth.uid(), nullif(current_setting('app.justification', true), ''));
  end if;
  return null;
end;
$$;

-- ---------------------------------------------------------------------
-- Proteções de integridade da ME
-- ---------------------------------------------------------------------
create or replace function public.tg_guard_movement_update()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_correction boolean := coalesce(current_setting('app.correction', true), '') = 'on';
  v_internal   boolean := coalesce(current_setting('app.internal_totals', true), '') = 'on';
begin
  if new.id <> old.id or new.me_number <> old.me_number
     or new.created_by <> old.created_by or new.created_at <> old.created_at then
    raise exception 'Número, identificador e autoria da ME não podem ser alterados.'
      using errcode = 'P0001';
  end if;

  if v_internal then
    return new;
  end if;

  if old.status = 'cancelada' then
    raise exception 'ME cancelada é somente consulta.' using errcode = 'P0001';
  end if;

  if new.warehouse_id <> old.warehouse_id and not v_correction then
    raise exception 'O estoque de origem não pode ser alterado sem correção autorizada e justificada.'
      using errcode = 'P0001';
  end if;

  if old.status = 'concluida' and not v_correction then
    raise exception 'ME concluída é somente consulta. Utilize a correção autorizada com justificativa.'
      using errcode = 'P0001';
  end if;

  return new;
end;
$$;

create or replace function public.tg_guard_item_change()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_status   public.movement_status;
  v_allowed  boolean := coalesce(current_setting('app.correction', true), '') = 'on'
                     or coalesce(current_setting('app.creating', true), '') = 'on';
begin
  if coalesce(current_setting('app.purge_demo', true), '') = 'on' then
    return coalesce(new, old);
  end if;

  select status into v_status
    from public.stock_movements
   where id = coalesce(new.movement_id, old.movement_id);

  if v_status in ('rascunho', 'aguardando_assinatura') or v_allowed then
    if tg_op = 'DELETE' and v_status not in ('rascunho', 'aguardando_assinatura') then
      raise exception 'Itens de uma ME finalizada não podem ser excluídos.' using errcode = 'P0001';
    end if;
    return coalesce(new, old);
  end if;

  raise exception 'Os itens desta ME estão bloqueados (status: %).', v_status using errcode = 'P0001';
end;
$$;

-- Impede exclusão física de registros com valor de evidência
create or replace function public.tg_block_delete()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if coalesce(current_setting('app.purge_demo', true), '') = 'on' then
    return old;
  end if;
  raise exception 'Exclusão física não permitida em %. Utilize o cancelamento lógico ou a inativação.', tg_table_name
    using errcode = 'P0001';
end;
$$;

create or replace function public.tg_block_audit_change()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  raise exception 'Registros de auditoria não podem ser alterados ou excluídos.' using errcode = 'P0001';
end;
$$;

create or replace function public.tg_guard_signature_update()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  -- Manutenção interna (somente funções restritas ao service_role, ex.: dados fictícios)
  if coalesce(current_setting('app.internal_totals', true), '') = 'on' then
    return new;
  end if;
  if coalesce(current_setting('app.signature_replace', true), '') <> 'on' then
    raise exception 'A assinatura não pode ser alterada. Utilize a substituição autorizada com justificativa.'
      using errcode = 'P0001';
  end if;
  if new.storage_path <> old.storage_path or new.movement_id <> old.movement_id
     or new.signed_at <> old.signed_at or new.employee_id <> old.employee_id then
    raise exception 'Os dados da assinatura original são imutáveis.' using errcode = 'P0001';
  end if;
  return new;
end;
$$;

-- =====================================================================
-- TRIGGERS
-- =====================================================================

-- updated_at / created_by
do $$
declare
  t text;
begin
  foreach t in array array[
    'warehouses', 'profiles', 'contracts', 'sectors', 'service_fronts', 'service_orders',
    'fixed_assets', 'application_locations', 'accounts', 'material_categories',
    'employees', 'materials', 'stock_movements', 'stock_movement_items'
  ] loop
    execute format('drop trigger if exists set_timestamps on public.%I', t);
    execute format('create trigger set_timestamps before insert or update on public.%I
                    for each row execute function public.tg_set_timestamps()', t);
  end loop;
end $$;

-- app_settings: só updated_at/updated_by
create or replace function public.tg_settings_timestamps()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  new.updated_at := now();
  new.updated_by := coalesce(auth.uid(), new.updated_by);
  return new;
end;
$$;
drop trigger if exists set_timestamps on public.app_settings;
create trigger set_timestamps before update on public.app_settings
  for each row execute function public.tg_settings_timestamps();

-- Auditoria genérica
do $$
declare
  t text;
begin
  foreach t in array array[
    'warehouses', 'profiles', 'user_roles', 'user_warehouses', 'app_settings',
    'contracts', 'sectors', 'service_fronts', 'service_orders', 'fixed_assets',
    'application_locations', 'accounts', 'material_categories', 'employees',
    'materials', 'material_qr_codes',
    'stock_movements', 'stock_movement_items', 'signatures', 'erp_sa_records'
  ] loop
    execute format('drop trigger if exists audit_row on public.%I', t);
    execute format('create trigger audit_row after insert or update or delete on public.%I
                    for each row execute function public.tg_audit_row()', t);
  end loop;
end $$;

-- Totais da ME
drop trigger if exists refresh_totals on public.stock_movement_items;
create trigger refresh_totals
  after insert or update of quantity_requested, quantity_delivered or delete on public.stock_movement_items
  for each row execute function public.tg_refresh_movement_totals();

-- Histórico de status
drop trigger if exists status_history on public.stock_movements;
create trigger status_history
  after insert or update of status on public.stock_movements
  for each row execute function public.tg_movement_status_history();

-- Guardas
drop trigger if exists guard_update on public.stock_movements;
create trigger guard_update before update on public.stock_movements
  for each row execute function public.tg_guard_movement_update();

drop trigger if exists guard_item on public.stock_movement_items;
create trigger guard_item before insert or update or delete on public.stock_movement_items
  for each row execute function public.tg_guard_item_change();

drop trigger if exists guard_signature on public.signatures;
create trigger guard_signature before update on public.signatures
  for each row execute function public.tg_guard_signature_update();

do $$
declare
  t text;
begin
  foreach t in array array['stock_movements', 'signatures', 'erp_sa_records', 'movement_status_history', 'movement_sequences'] loop
    execute format('drop trigger if exists block_delete on public.%I', t);
    execute format('create trigger block_delete before delete on public.%I
                    for each row execute function public.tg_block_delete()', t);
  end loop;
end $$;

drop trigger if exists block_change on public.audit_logs;
create trigger block_change before update or delete on public.audit_logs
  for each row execute function public.tg_block_audit_change();


-- >>>>>>>>>> 04_rpc_movimentacoes.sql
-- =====================================================================
-- 04 - NUMERAÇÃO DA ME, VIEW DE CONSULTA E FUNÇÕES RPC DO FLUXO
-- Toda gravação na ME passa por estas funções (SECURITY DEFINER com
-- verificação explícita de perfil e estoque). Não há política de
-- INSERT/UPDATE/DELETE direto nas tabelas de movimentação.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Geração segura do número da ME
-- INSERT ... ON CONFLICT DO UPDATE bloqueia a linha (estoque, ano) até o
-- fim da transação: duas saídas simultâneas no mesmo estoque recebem
-- números diferentes, e se a transação falhar o número é devolvido
-- (rollback), sem buracos na sequência.
-- ---------------------------------------------------------------------
create or replace function public.next_me_number(p_warehouse_id uuid, p_at timestamptz default now())
returns text
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  s        public.app_settings := public.get_settings();
  v_code   text;
  v_year   int;
  v_seq    int;
  v_number text;
begin
  select code into v_code from public.warehouses where id = p_warehouse_id;
  if v_code is null then
    raise exception 'Estoque não encontrado.' using errcode = 'P0001';
  end if;

  v_year := extract(year from (p_at at time zone s.timezone))::int;

  insert into public.movement_sequences as ms (warehouse_id, year, last_value, updated_at)
  values (p_warehouse_id, v_year, 1, now())
  on conflict (warehouse_id, year)
  do update set last_value = ms.last_value + 1, updated_at = now()
  returning ms.last_value into v_seq;

  v_number := s.me_number_pattern;
  v_number := replace(v_number, '{PREFIXO}', s.me_prefix);
  v_number := replace(v_number, '{ESTOQUE}', v_code);
  v_number := replace(v_number, '{ANO}', v_year::text);
  v_number := replace(v_number, '{SEQ}', lpad(v_seq::text, s.me_sequence_digits, '0'));
  return v_number;
end;
$$;
revoke all on function public.next_me_number(uuid, timestamptz) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- View de consulta das MEs (respeita RLS de quem consulta)
-- ---------------------------------------------------------------------
create or replace view public.v_movements
with (security_invoker = true)
as
select
  m.id,
  m.me_number,
  m.movement_type,
  m.movement_at,
  m.warehouse_id,
  w.code  as warehouse_code,
  w.name  as warehouse_name,
  m.contract_id,
  c.code  as contract_code,
  c.name  as contract_name,
  m.sector_id,
  se.name as sector_name,
  m.service_front_id,
  sf.name as service_front_name,
  coalesce(so.code, m.service_order_text) as service_order,
  coalesce(fa.code, m.fixed_asset_text)   as fixed_asset,
  m.application_location_id,
  coalesce(al.name, m.application_location_text) as application_location,
  m.notes,
  m.status,
  m.requester_employee_id,
  m.requester_name,
  m.requester_registration,
  m.requested_at,
  m.received_by_employee_id,
  m.received_by_name,
  m.received_by_registration,
  m.received_at,
  m.approved_by,
  pa.full_name as approved_by_name,
  m.approved_at,
  m.storekeeper_id,
  pk.full_name as storekeeper_name,
  m.sa_number,
  m.sa_informed_at,
  m.sa_informed_by,
  ps.full_name as sa_informed_by_name,
  m.completed_at,
  m.completed_by,
  pc.full_name as completed_by_name,
  m.cancelled_at,
  m.cancelled_by,
  px.full_name as cancelled_by_name,
  m.cancel_reason,
  m.item_count,
  m.total_requested,
  m.total_delivered,
  (select string_agg(i.material_name, '; ' order by i.line_number)
     from (select material_name, line_number
             from public.stock_movement_items
            where movement_id = m.id
            order by line_number
            limit 3) i) as materials_summary,
  m.is_demo,
  m.created_at,
  m.created_by,
  m.updated_at,
  m.updated_by,
  pu.full_name as updated_by_name
from public.stock_movements m
join public.warehouses w on w.id = m.warehouse_id
join public.contracts c on c.id = m.contract_id
join public.sectors se on se.id = m.sector_id
left join public.service_fronts sf on sf.id = m.service_front_id
left join public.service_orders so on so.id = m.service_order_id
left join public.fixed_assets fa on fa.id = m.fixed_asset_id
left join public.application_locations al on al.id = m.application_location_id
left join public.profiles pa on pa.id = m.approved_by
left join public.profiles pk on pk.id = m.storekeeper_id
left join public.profiles ps on ps.id = m.sa_informed_by
left join public.profiles pc on pc.id = m.completed_by
left join public.profiles px on px.id = m.cancelled_by
left join public.profiles pu on pu.id = m.updated_by;

-- ---------------------------------------------------------------------
-- Predicado único de filtros (usado na lista, no dashboard e no Excel)
-- Chaves aceitas em p_f (todas opcionais):
--   date_from, date_to (AAAA-MM-DD, data local), warehouse_id, me_number,
--   sa_number, status (array), material, material_code, reference, unit,
--   sector_id, service_front_id, service_order, fixed_asset,
--   application_location_id, requester_employee_id, requester,
--   storekeeper_id, responsible_user_id, pending_sa (bool), q (pesquisa rápida)
-- ---------------------------------------------------------------------
create or replace function public.movement_matches(v public.v_movements, p_f jsonb, p_tz text)
returns boolean
language sql stable
set search_path = public, pg_temp
as $$
  select
        (nullif(p_f ->> 'date_from', '') is null or (v.movement_at at time zone p_tz)::date >= (p_f ->> 'date_from')::date)
    and (nullif(p_f ->> 'date_to', '')   is null or (v.movement_at at time zone p_tz)::date <= (p_f ->> 'date_to')::date)
    and (nullif(p_f ->> 'warehouse_id', '') is null or v.warehouse_id = (p_f ->> 'warehouse_id')::uuid)
    and (nullif(p_f ->> 'me_number', '') is null or v.me_number ilike '%' || btrim(p_f ->> 'me_number') || '%')
    and (nullif(p_f ->> 'sa_number', '') is null or v.sa_number ilike '%' || btrim(p_f ->> 'sa_number') || '%')
    and (jsonb_typeof(p_f -> 'status') is distinct from 'array'
         or jsonb_array_length(p_f -> 'status') = 0
         or v.status::text in (select jsonb_array_elements_text(p_f -> 'status')))
    and (coalesce((p_f ->> 'pending_sa')::boolean, false) = false or v.status = 'aguardando_sa')
    and (nullif(p_f ->> 'sector_id', '') is null or v.sector_id = (p_f ->> 'sector_id')::uuid)
    and (nullif(p_f ->> 'service_front_id', '') is null or v.service_front_id = (p_f ->> 'service_front_id')::uuid)
    and (nullif(p_f ->> 'application_location_id', '') is null or v.application_location_id = (p_f ->> 'application_location_id')::uuid)
    and (nullif(p_f ->> 'service_order', '') is null or v.service_order ilike '%' || btrim(p_f ->> 'service_order') || '%')
    and (nullif(p_f ->> 'fixed_asset', '') is null or v.fixed_asset ilike '%' || btrim(p_f ->> 'fixed_asset') || '%')
    and (nullif(p_f ->> 'requester_employee_id', '') is null or v.requester_employee_id = (p_f ->> 'requester_employee_id')::uuid)
    and (nullif(p_f ->> 'requester', '') is null
         or v.requester_name ilike '%' || btrim(p_f ->> 'requester') || '%'
         or v.requester_registration ilike '%' || btrim(p_f ->> 'requester') || '%')
    and (nullif(p_f ->> 'storekeeper_id', '') is null or v.storekeeper_id = (p_f ->> 'storekeeper_id')::uuid)
    and (nullif(p_f ->> 'responsible_user_id', '') is null
         or (p_f ->> 'responsible_user_id')::uuid in (v.created_by, v.updated_by, v.sa_informed_by, v.approved_by, v.cancelled_by, v.completed_by))
    and (
      (nullif(p_f ->> 'material', '') is null and nullif(p_f ->> 'material_code', '') is null
       and nullif(p_f ->> 'reference', '') is null and nullif(p_f ->> 'unit', '') is null)
      or exists (
        select 1 from public.stock_movement_items i
         where i.movement_id = v.id
           and (nullif(p_f ->> 'material', '') is null
                or i.material_name ilike '%' || btrim(p_f ->> 'material') || '%'
                or i.material_code ilike '%' || btrim(p_f ->> 'material') || '%'
                or i.material_reference ilike '%' || btrim(p_f ->> 'material') || '%')
           and (nullif(p_f ->> 'material_code', '') is null or i.material_code ilike '%' || btrim(p_f ->> 'material_code') || '%')
           and (nullif(p_f ->> 'reference', '') is null or i.material_reference ilike '%' || btrim(p_f ->> 'reference') || '%')
           and (nullif(p_f ->> 'unit', '') is null or upper(i.unit) = upper(btrim(p_f ->> 'unit')))
      )
    )
    and (nullif(p_f ->> 'q', '') is null
         or v.me_number ilike '%' || btrim(p_f ->> 'q') || '%'
         or v.sa_number ilike '%' || btrim(p_f ->> 'q') || '%'
         or v.requester_name ilike '%' || btrim(p_f ->> 'q') || '%'
         or v.requester_registration ilike '%' || btrim(p_f ->> 'q') || '%'
         or exists (select 1 from public.stock_movement_items i
                     where i.movement_id = v.id
                       and (i.material_name ilike '%' || btrim(p_f ->> 'q') || '%'
                            or i.material_code ilike '%' || btrim(p_f ->> 'q') || '%')));
$$;

-- ---------------------------------------------------------------------
-- Lista paginada no servidor
-- ---------------------------------------------------------------------
create or replace function public.search_movements(
  p_filters   jsonb default '{}'::jsonb,
  p_page      int default 1,
  p_page_size int default 25,
  p_sort      text default 'movement_at',
  p_dir       text default 'desc'
)
returns jsonb
language plpgsql stable security invoker
set search_path = public, pg_temp
as $$
declare
  v_tz     text := (public.get_settings()).timezone;
  v_size   int := least(greatest(coalesce(p_page_size, 25), 1), 200);
  v_page   int := greatest(coalesce(p_page, 1), 1);
  v_sort   text := case when p_sort in ('movement_at', 'me_number', 'warehouse_name', 'status', 'sa_number',
                                         'requester_name', 'item_count', 'updated_at', 'sector_name')
                        then p_sort else 'movement_at' end;
  v_asc    boolean := lower(coalesce(p_dir, 'desc')) = 'asc';
  v_total  bigint;
  v_rows   jsonb;
begin
  if not public.is_active_user() then
    raise exception 'Sessão inválida ou usuário inativo.' using errcode = '42501';
  end if;

  with f as (
    select v.* from public.v_movements v
     where public.movement_matches(v, coalesce(p_filters, '{}'::jsonb), v_tz)
  ),
  counted as (select count(*) as total from f),
  page as (
    select * from f
     order by
       case when v_asc then
         case v_sort
           when 'me_number' then me_number
           when 'warehouse_name' then warehouse_name
           when 'status' then status::text
           when 'sa_number' then sa_number
           when 'requester_name' then requester_name
           when 'sector_name' then sector_name
         end end asc nulls last,
       case when not v_asc then
         case v_sort
           when 'me_number' then me_number
           when 'warehouse_name' then warehouse_name
           when 'status' then status::text
           when 'sa_number' then sa_number
           when 'requester_name' then requester_name
           when 'sector_name' then sector_name
         end end desc nulls last,
       case when v_asc and v_sort = 'item_count' then item_count end asc,
       case when not v_asc and v_sort = 'item_count' then item_count end desc,
       case when v_asc and v_sort = 'updated_at' then updated_at end asc,
       case when not v_asc and v_sort = 'updated_at' then updated_at end desc,
       case when v_asc then movement_at end asc,
       case when not v_asc then movement_at end desc,
       me_number desc
     limit v_size offset (v_page - 1) * v_size
  )
  select (select total from counted),
         coalesce((select jsonb_agg(to_jsonb(page)) from page), '[]'::jsonb)
    into v_total, v_rows;

  return jsonb_build_object('total', v_total, 'page', v_page, 'page_size', v_size, 'rows', v_rows);
end;
$$;

-- ---------------------------------------------------------------------
-- Material: busca por QR Code / código e pesquisa manual
-- ---------------------------------------------------------------------
create or replace function public.find_material_by_code(p_code text)
returns jsonb
language plpgsql stable security invoker
set search_path = public, pg_temp
as $$
declare
  v_code text := btrim(coalesce(p_code, ''));
  v_row  jsonb;
begin
  if not public.is_active_user() then
    raise exception 'Sessão inválida ou usuário inativo.' using errcode = '42501';
  end if;

  -- Aceita também URLs/conteúdos com prefixo: usa o último segmento.
  if position('/' in v_code) > 0 then
    v_code := regexp_replace(v_code, '^.*/', '');
  end if;

  if v_code !~ '^[A-Za-z0-9._:/-]{1,80}$' then
    return jsonb_build_object('found', false, 'reason', 'invalido');
  end if;

  select to_jsonb(x) into v_row from (
    select m.id, m.code, m.reference, m.name, m.description, m.unit, m.location,
           m.account_id, a.code as account_code, a.name as account_name,
           m.category_id, mc.name as category_name,
           m.warehouse_id, w.name as warehouse_name,
           m.qr_code, m.active
      from public.materials m
      left join public.accounts a on a.id = m.account_id
      left join public.material_categories mc on mc.id = m.category_id
      left join public.warehouses w on w.id = m.warehouse_id
     where m.qr_code = v_code
        or m.id in (select q.material_id from public.material_qr_codes q where q.code = v_code and q.active)
        or upper(m.code) = upper(v_code)
     order by (m.qr_code = v_code) desc
     limit 1
  ) x;

  if v_row is null then
    return jsonb_build_object('found', false, 'reason', 'nao_cadastrado', 'code', v_code);
  end if;

  return jsonb_build_object('found', true, 'material', v_row);
end;
$$;

create or replace function public.search_materials(
  p_term        text,
  p_only_active boolean default true,
  p_limit       int default 30
)
returns jsonb
language plpgsql stable security invoker
set search_path = public, pg_temp
as $$
declare
  v_term text := btrim(coalesce(p_term, ''));
begin
  if not public.is_active_user() then
    raise exception 'Sessão inválida ou usuário inativo.' using errcode = '42501';
  end if;

  return coalesce((
    select jsonb_agg(to_jsonb(x)) from (
      select m.id, m.code, m.reference, m.name, m.description, m.unit, m.location,
             m.account_id, a.code as account_code, a.name as account_name,
             m.category_id, mc.name as category_name,
             m.warehouse_id, w.name as warehouse_name,
             m.qr_code, m.active
        from public.materials m
        left join public.accounts a on a.id = m.account_id
        left join public.material_categories mc on mc.id = m.category_id
        left join public.warehouses w on w.id = m.warehouse_id
       where (not coalesce(p_only_active, true) or m.active)
         and (v_term = ''
              or m.code ilike '%' || v_term || '%'
              or m.reference ilike '%' || v_term || '%'
              or m.name ilike '%' || v_term || '%'
              or m.description ilike '%' || v_term || '%')
       order by (upper(m.code) = upper(v_term)) desc, m.name
       limit least(greatest(coalesce(p_limit, 30), 1), 100)
    ) x
  ), '[]'::jsonb);
end;
$$;

-- ---------------------------------------------------------------------
-- CRIAÇÃO DA ME (transação única e idempotente)
-- Pré-requisito: a imagem da assinatura já enviada ao bucket
-- 'assinaturas' no caminho {COD_ESTOQUE}/{ANO}/{ID_DA_ME}/arquivo.png
-- ---------------------------------------------------------------------
create or replace function public.create_movement(p_payload jsonb)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  s              public.app_settings := public.get_settings();
  v_uid          uuid := auth.uid();
  v_id           uuid;
  v_wh           public.warehouses;
  v_existing     public.stock_movements;
  v_requester    public.employees;
  v_receiver     public.employees;
  v_contract_id  uuid;
  v_sector_id    uuid;
  v_front_id     uuid;
  v_appl_id      uuid;
  v_so_text      text;
  v_so_id        uuid;
  v_fa_text      text;
  v_fa_id        uuid;
  v_number       text;
  v_status       public.movement_status;
  v_items        jsonb := p_payload -> 'items';
  v_item         jsonb;
  v_mat          record;
  v_line         int := 0;
  v_req          numeric;
  v_del          numeric;
  v_seen         uuid[] := '{}';
  v_sig          jsonb := p_payload -> 'signature';
  v_sig_path     text;
  v_sig_obj      record;
  v_year         int;
  v_now          timestamptz := now();
  v_signed_at    timestamptz;
  v_at           timestamptz;             -- data/hora real da retirada
  v_offline      boolean := false;
begin
  -- Saída registrada sem internet: usa a data/hora real da retirada (até 7 dias atrás)
  if nullif(p_payload ->> 'offline_at', '') is not null then
    begin
      v_at := (p_payload ->> 'offline_at')::timestamptz;
    exception when others then
      raise exception 'Data/hora da saída offline inválida.' using errcode = '22023';
    end;
    if v_at > v_now + interval '5 minutes' or v_at < v_now - interval '7 days' then
      raise exception 'Saída offline com data fora do prazo (até 7 dias). Registre pela contingência em papel.' using errcode = '22023';
    end if;
    v_offline := true;
  else
    v_at := v_now;
  end if;

  -- 1) Autenticação e perfil
  if v_uid is null or not public.is_active_user() then
    raise exception 'Sessão inválida ou usuário inativo.' using errcode = '42501';
  end if;
  if not public.has_any_role(array['almoxarife', 'gestor', 'admin']::public.app_role[]) then
    raise exception 'Seu perfil não permite registrar saídas de material.' using errcode = '42501';
  end if;

  -- 2) Identificador (chave de idempotência gerada no cliente)
  begin
    v_id := (p_payload ->> 'id')::uuid;
  exception when others then
    raise exception 'Identificador da movimentação inválido.' using errcode = '22023';
  end;
  if v_id is null then
    raise exception 'Identificador da movimentação é obrigatório.' using errcode = '22023';
  end if;

  -- Serializa reenvios com o mesmo identificador (duplo clique / nova tentativa)
  perform pg_advisory_xact_lock(hashtextextended(v_id::text, 0));

  select * into v_existing from public.stock_movements where id = v_id;
  if found then
    if v_existing.created_by <> v_uid then
      raise exception 'Identificador de movimentação já utilizado.' using errcode = '23505';
    end if;
    return jsonb_build_object('id', v_existing.id, 'me_number', v_existing.me_number,
                              'status', v_existing.status, 'created', false);
  end if;

  -- 3) Estoque
  select * into v_wh from public.warehouses where id = nullif(p_payload ->> 'warehouse_id', '')::uuid;
  if v_wh.id is null then
    raise exception 'Selecione o estoque de origem.' using errcode = '22023';
  end if;
  if not v_wh.active then
    raise exception 'O estoque % está inativo.', v_wh.name using errcode = '22023';
  end if;
  if not public.can_access_warehouse(v_wh.id) then
    raise exception 'Você não tem permissão para operar no estoque %.', v_wh.name using errcode = '42501';
  end if;

  -- 4) Dados operacionais
  select id into v_contract_id from public.contracts
   where id = nullif(p_payload ->> 'contract_id', '')::uuid and active;
  if v_contract_id is null then
    raise exception 'Informe um contrato ativo.' using errcode = '22023';
  end if;

  select id into v_sector_id from public.sectors
   where id = nullif(p_payload ->> 'sector_id', '')::uuid and active;
  if v_sector_id is null then
    raise exception 'Informe um setor ativo.' using errcode = '22023';
  end if;

  if nullif(p_payload ->> 'service_front_id', '') is not null then
    select id into v_front_id from public.service_fronts
     where id = (p_payload ->> 'service_front_id')::uuid and active;
    if v_front_id is null then
      raise exception 'Frente de serviço/equipamento inválida ou inativa.' using errcode = '22023';
    end if;
  end if;

  if nullif(p_payload ->> 'application_location_id', '') is not null then
    select id into v_appl_id from public.application_locations
     where id = (p_payload ->> 'application_location_id')::uuid and active;
    if v_appl_id is null then
      raise exception 'Local de aplicação inválido ou inativo.' using errcode = '22023';
    end if;
  end if;

  v_so_text := nullif(btrim(coalesce(p_payload ->> 'service_order_text', '')), '');
  if v_so_text is not null then
    if length(v_so_text) > 40 then
      raise exception 'Ordem de serviço deve ter no máximo 40 caracteres.' using errcode = '22023';
    end if;
    select id into v_so_id from public.service_orders where upper(code) = upper(v_so_text) and active;
  end if;

  v_fa_text := nullif(btrim(coalesce(p_payload ->> 'fixed_asset_text', '')), '');
  if v_fa_text is not null then
    if length(v_fa_text) > 40 then
      raise exception 'Ativo fixo deve ter no máximo 40 caracteres.' using errcode = '22023';
    end if;
    select id into v_fa_id from public.fixed_assets where upper(code) = upper(v_fa_text) and active;
  end if;

  -- 5) Requisitante e recebedor
  select * into v_requester from public.employees
   where id = nullif(p_payload ->> 'requester_employee_id', '')::uuid;
  if v_requester.id is null then
    raise exception 'Identifique o funcionário requisitante.' using errcode = '22023';
  end if;
  if not v_requester.active then
    raise exception 'O funcionário % está inativo.', v_requester.full_name using errcode = '22023';
  end if;

  select * into v_receiver from public.employees
   where id = coalesce(nullif(p_payload ->> 'received_by_employee_id', '')::uuid, v_requester.id);
  if v_receiver.id is null or not v_receiver.active then
    raise exception 'Funcionário que recebeu o material inválido ou inativo.' using errcode = '22023';
  end if;

  -- 6) Itens
  if v_items is null or jsonb_typeof(v_items) <> 'array' or jsonb_array_length(v_items) = 0 then
    raise exception 'A ME precisa ter pelo menos um material.' using errcode = '22023';
  end if;
  if jsonb_array_length(v_items) > 200 then
    raise exception 'Limite de 200 itens por ME.' using errcode = '22023';
  end if;

  -- 7) Assinatura (obrigatória)
  v_year := extract(year from (v_at at time zone s.timezone))::int;
  v_sig_path := nullif(btrim(coalesce(v_sig ->> 'storage_path', '')), '');
  if v_sig_path is null then
    raise exception 'A assinatura do funcionário é obrigatória para finalizar a ME.' using errcode = '22023';
  end if;
  if v_sig_path not like v_wh.code || '/' || v_year::text || '/' || v_id::text || '/%' then
    raise exception 'Caminho da assinatura inválido para esta ME.' using errcode = '22023';
  end if;

  select o.name,
         nullif(o.metadata ->> 'size', '')::int as size_bytes,
         coalesce(o.metadata ->> 'mimetype', 'image/png') as mime_type
    into v_sig_obj
    from storage.objects o
   where o.bucket_id = 'assinaturas' and o.name = v_sig_path;
  if v_sig_obj.name is null then
    raise exception 'Arquivo da assinatura não encontrado no armazenamento. Tente enviar a assinatura novamente.'
      using errcode = '22023';
  end if;

  begin
    v_signed_at := coalesce(nullif(v_sig ->> 'signed_at', '')::timestamptz, v_at);
  exception when others then
    v_signed_at := v_at;
  end;
  if v_signed_at > v_now + interval '5 minutes' or v_signed_at < v_at - interval '1 day' then
    v_signed_at := v_at;
  end if;

  -- 8) Gravação
  perform set_config('app.creating', 'on', true);
  perform set_config('app.source', case when v_offline then 'offline' else coalesce(nullif(p_payload ->> 'source', ''), 'app') end, true);

  v_number := public.next_me_number(v_wh.id, v_at);
  -- Sem ativo fixo: não precisa de SA, vai direto para a baixa no ERP (status sa_informada sem número de SA)
  v_status := case when s.require_approval then 'aguardando_aprovacao'
                   when v_fa_text is null then 'sa_informada'
                   else 'aguardando_sa' end;

  insert into public.stock_movements (
    id, me_number, movement_type, movement_at, warehouse_id, contract_id, sector_id,
    service_front_id, service_order_id, service_order_text, fixed_asset_id, fixed_asset_text, requires_sa,
    application_location_id, application_location_text, notes, status, entry_channel,
    requester_employee_id, requester_name, requester_registration, requested_at,
    received_by_employee_id, received_by_name, received_by_registration, received_at,
    storekeeper_id, created_by, updated_by, created_at
  ) values (
    v_id, v_number, 'saida', v_at, v_wh.id, v_contract_id, v_sector_id,
    v_front_id, v_so_id, v_so_text, v_fa_id, v_fa_text, v_fa_text is not null,
    v_appl_id, nullif(btrim(coalesce(p_payload ->> 'application_location_text', '')), ''),
    nullif(btrim(coalesce(p_payload ->> 'notes', '')), ''), v_status, case when v_offline then 'offline' else 'assistente' end,
    v_requester.id, v_requester.full_name, v_requester.registration, v_at,
    v_receiver.id, v_receiver.full_name, v_receiver.registration, v_signed_at,
    v_uid, v_uid, v_uid, v_now
  );

  for v_item in select * from jsonb_array_elements(v_items) loop
    v_line := v_line + 1;

    select m.*, a.code as account_code, a.name as account_name
      into v_mat
      from public.materials m
      left join public.accounts a on a.id = m.account_id
     where m.id = nullif(v_item ->> 'material_id', '')::uuid;

    if v_mat.id is null then
      raise exception 'Item %: material não encontrado.', v_line using errcode = '22023';
    end if;
    if not v_mat.active then
      raise exception 'Item % (%): material inativo não pode ser baixado.', v_line, v_mat.name using errcode = '22023';
    end if;
    if v_mat.id = any (v_seen) and not s.allow_duplicate_material_lines then
      raise exception 'O material % aparece mais de uma vez. Some as quantidades em uma única linha.', v_mat.name
        using errcode = '22023';
    end if;
    v_seen := v_seen || v_mat.id;

    begin
      v_req := (v_item ->> 'quantity_requested')::numeric;
      v_del := (v_item ->> 'quantity_delivered')::numeric;
    exception when others then
      raise exception 'Item % (%): quantidade inválida.', v_line, v_mat.name using errcode = '22023';
    end;
    if v_req is null or v_req <= 0 then
      raise exception 'Item % (%): a quantidade solicitada deve ser maior que zero.', v_line, v_mat.name using errcode = '22023';
    end if;
    if v_del is null or v_del <= 0 then
      raise exception 'Item % (%): a quantidade atendida deve ser maior que zero.', v_line, v_mat.name using errcode = '22023';
    end if;
    if v_del > v_req and not s.allow_delivered_above_requested then
      raise exception 'Item % (%): a quantidade atendida não pode ser maior que a solicitada.', v_line, v_mat.name
        using errcode = '22023';
    end if;
    if v_req > 999999 or v_del > 999999 then
      raise exception 'Item % (%): quantidade acima do limite permitido.', v_line, v_mat.name using errcode = '22023';
    end if;

    insert into public.stock_movement_items (
      movement_id, line_number, material_id, material_code, material_reference, material_name,
      unit, location, account_code, account_name, quantity_requested, quantity_delivered,
      entry_method, scanned_code, notes, created_by, updated_by
    ) values (
      v_id, v_line, v_mat.id, v_mat.code, v_mat.reference, v_mat.name,
      v_mat.unit, v_mat.location, v_mat.account_code, v_mat.account_name, v_req, v_del,
      case when v_item ->> 'entry_method' = 'pesquisa_manual' then 'pesquisa_manual' else 'qr_code' end::public.item_entry_method,
      left(nullif(v_item ->> 'scanned_code', ''), 80),
      left(nullif(btrim(coalesce(v_item ->> 'notes', '')), ''), 500),
      v_uid, v_uid
    );
  end loop;

  insert into public.signatures (
    movement_id, employee_id, signer_name, signer_registration, bucket, storage_path,
    mime_type, size_bytes, signed_at, uploaded_by, is_current
  ) values (
    v_id, v_receiver.id, v_receiver.full_name, v_receiver.registration, 'assinaturas', v_sig_path,
    case when v_sig_obj.mime_type in ('image/png', 'image/jpeg', 'image/webp') then v_sig_obj.mime_type else 'image/png' end,
    v_sig_obj.size_bytes, v_signed_at, v_uid, true
  );

  perform public.write_audit(
    'me.finalizada', 'stock_movements', v_id::text, v_id, v_wh.id, null,
    jsonb_build_object('me_number', v_number, 'status', v_status, 'itens', v_line,
                       'requisitante', v_requester.full_name, 'estoque', v_wh.name),
    null
  );

  perform set_config('app.creating', 'off', true);

  return jsonb_build_object('id', v_id, 'me_number', v_number, 'status', v_status, 'created', true);
end;
$$;

-- ---------------------------------------------------------------------
-- Aprovação (quando o parâmetro require_approval estiver ativo)
-- ---------------------------------------------------------------------
create or replace function public.approve_movement(p_id uuid, p_notes text default null)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_m public.stock_movements;
begin
  if not public.has_any_role(array['gestor', 'admin']::public.app_role[]) then
    raise exception 'Somente gestor ou administrador pode aprovar a ME.' using errcode = '42501';
  end if;

  select * into v_m from public.stock_movements where id = p_id for update;
  if v_m.id is null or not public.can_access_warehouse(v_m.warehouse_id) then
    raise exception 'ME não encontrada.' using errcode = 'P0002';
  end if;
  if v_m.status <> 'aguardando_aprovacao' then
    raise exception 'A ME % não está aguardando aprovação (status atual: %).', v_m.me_number, v_m.status using errcode = 'P0001';
  end if;

  perform set_config('app.audit_action', 'me.aprovada', true);
  perform set_config('app.justification', coalesce(p_notes, ''), true);

  -- Com ativo fixo vai para a SA; sem ativo vai direto para a baixa no ERP
  update public.stock_movements
     set status = case when v_m.requires_sa then 'aguardando_sa'::public.movement_status else 'sa_informada'::public.movement_status end,
         approved_by = auth.uid(), approved_at = now()
   where id = p_id;

  return jsonb_build_object('id', p_id, 'status', case when v_m.requires_sa then 'aguardando_sa' else 'sa_informada' end);
end;
$$;

-- ---------------------------------------------------------------------
-- Informar / corrigir número da SA
-- ---------------------------------------------------------------------
create or replace function public.inform_sa(p_id uuid, p_sa_number text, p_justification text default null)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  s          public.app_settings := public.get_settings();
  v_m        public.stock_movements;
  v_sa       text := upper(btrim(coalesce(p_sa_number, '')));
  v_just     text := nullif(btrim(coalesce(p_justification, '')), '');
  v_action   public.sa_action;
  v_status   public.movement_status;
  v_dup      text;
begin
  if not public.has_any_role(array['equipe_sa', 'gestor', 'admin']::public.app_role[]) then
    raise exception 'Seu perfil não permite informar o número da SA.' using errcode = '42501';
  end if;

  if v_sa = '' then
    raise exception 'Informe o número da SA.' using errcode = '22023';
  end if;
  if v_sa !~ s.sa_number_pattern then
    raise exception 'Número da SA "%" em formato inválido. Use somente letras, números, ponto, barra ou hífen (3 a 30 caracteres).', v_sa
      using errcode = '22023';
  end if;

  select * into v_m from public.stock_movements where id = p_id for update;
  if v_m.id is null or not public.can_access_warehouse(v_m.warehouse_id) then
    raise exception 'ME não encontrada.' using errcode = 'P0002';
  end if;
  if not v_m.requires_sa then
    raise exception 'A ME % não tem ativo fixo e não precisa de SA: a baixa é feita direto no ERP pelo almoxarife.', v_m.me_number
      using errcode = 'P0001';
  end if;

  if v_m.status = 'aguardando_sa' then
    v_action := 'inclusao';
    v_status := case when s.auto_complete_on_sa then 'concluida' else 'sa_informada' end;
  elsif v_m.status = 'sa_informada' then
    v_action := 'correcao';
    v_status := v_m.status;
  elsif v_m.status = 'concluida' then
    if not public.has_any_role(array['gestor', 'admin']::public.app_role[]) then
      raise exception 'A ME % está concluída. Somente gestor ou administrador pode corrigir a SA.', v_m.me_number
        using errcode = '42501';
    end if;
    v_action := 'correcao';
    v_status := v_m.status;
    perform set_config('app.correction', 'on', true);
  else
    raise exception 'Não é possível informar SA para uma ME com status "%".', v_m.status using errcode = 'P0001';
  end if;

  if v_action = 'correcao' then
    if v_m.sa_number = v_sa then
      raise exception 'A ME % já possui a SA %.', v_m.me_number, v_sa using errcode = 'P0001';
    end if;
    if v_just is null or length(v_just) < 5 then
      raise exception 'Para corrigir a SA informe uma justificativa (mínimo 5 caracteres).' using errcode = '22023';
    end if;
  end if;

  if s.sa_number_unique then
    select me_number into v_dup from public.stock_movements
     where upper(sa_number) = v_sa and id <> p_id and status <> 'cancelada'
     limit 1;
    if v_dup is not null then
      raise exception 'A SA % já está vinculada à ME %.', v_sa, v_dup using errcode = '23505';
    end if;
  end if;

  perform set_config('app.audit_action', case v_action when 'inclusao' then 'sa.informada' else 'sa.corrigida' end, true);
  perform set_config('app.justification', coalesce(v_just, ''), true);

  update public.stock_movements
     set sa_number      = v_sa,
         sa_informed_at = now(),
         sa_informed_by = auth.uid(),
         status         = v_status,
         completed_at   = case when v_status = 'concluida' and v_m.status <> 'concluida' then now() else completed_at end,
         completed_by   = case when v_status = 'concluida' and v_m.status <> 'concluida' then auth.uid() else completed_by end
   where id = p_id;

  insert into public.erp_sa_records (movement_id, me_number, sa_number, previous_sa_number, action, justification, informed_by)
  values (p_id, v_m.me_number, v_sa, v_m.sa_number, v_action, v_just, auth.uid());

  return jsonb_build_object('id', p_id, 'me_number', v_m.me_number, 'sa_number', v_sa,
                            'status', v_status, 'action', v_action);
end;
$$;

-- ---------------------------------------------------------------------
-- Concluir: almoxarife confirma a baixa no ERP com a SA informada
-- ---------------------------------------------------------------------
create or replace function public.complete_movement(
  p_id           uuid,
  p_erp_document text default null,
  p_notes        text default null
)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_m     public.stock_movements;
  v_doc   text := nullif(btrim(coalesce(p_erp_document, '')), '');
  v_notes text := nullif(btrim(coalesce(p_notes, '')), '');
  v_text  text;
begin
  if not public.has_any_role(array['almoxarife', 'gestor', 'admin']::public.app_role[]) then
    raise exception 'Seu perfil não permite confirmar a baixa no ERP.' using errcode = '42501';
  end if;
  if v_doc is not null and length(v_doc) > 60 then
    raise exception 'O documento do ERP deve ter no máximo 60 caracteres.' using errcode = '22023';
  end if;
  if v_notes is not null and length(v_notes) > 500 then
    raise exception 'A observação deve ter no máximo 500 caracteres.' using errcode = '22023';
  end if;

  select * into v_m from public.stock_movements where id = p_id for update;
  if v_m.id is null or not public.can_access_warehouse(v_m.warehouse_id) then
    raise exception 'ME não encontrada.' using errcode = 'P0002';
  end if;
  if v_m.status <> 'sa_informada' then
    raise exception 'Somente MEs aguardando baixa no ERP podem ser confirmadas (status atual: %).', v_m.status
      using errcode = 'P0001';
  end if;

  v_text := case when v_m.sa_number is null then 'Baixa realizada no ERP sem SA (ME sem ativo fixo)'
                 else 'Baixa realizada no ERP com a SA ' || v_m.sa_number end
         || coalesce('. Documento ERP: ' || v_doc, '')
         || coalesce('. Obs.: ' || v_notes, '');

  perform set_config('app.audit_action', 'me.concluida', true);
  perform set_config('app.justification', v_text, true);
  update public.stock_movements
     set status = 'concluida', completed_at = now(), completed_by = auth.uid()
   where id = p_id;

  return jsonb_build_object('id', p_id, 'status', 'concluida', 'sa_number', v_m.sa_number);
end;
$$;

-- ---------------------------------------------------------------------
-- Cancelamento lógico
-- ---------------------------------------------------------------------
create or replace function public.cancel_movement(p_id uuid, p_reason text)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_m       public.stock_movements;
  v_reason  text := nullif(btrim(coalesce(p_reason, '')), '');
  v_manager boolean := public.has_any_role(array['gestor', 'admin']::public.app_role[]);
  v_storekeeper boolean := public.has_role('almoxarife');
begin
  -- Gestor/admin: cancelam em qualquer status.
  -- Almoxarife: somente devolução/erro ANTES do lançamento no ERP
  -- (Em separação/Aguardando confirmação no balcão, Aguardando SA, Aguardando aprovação ou,
  --  em ME sem ativo, Aguardando baixa no ERP),
  -- no estoque autorizado.
  if not v_manager and not v_storekeeper then
    raise exception 'Seu perfil não permite cancelar uma ME.' using errcode = '42501';
  end if;
  if v_reason is null or length(v_reason) < 5 then
    raise exception 'Informe a justificativa do cancelamento (mínimo 5 caracteres).' using errcode = '22023';
  end if;

  select * into v_m from public.stock_movements where id = p_id for update;
  if v_m.id is null or not public.can_access_warehouse(v_m.warehouse_id) then
    raise exception 'ME não encontrada.' using errcode = 'P0002';
  end if;
  if v_m.status = 'cancelada' then
    raise exception 'A ME % já está cancelada.', v_m.me_number using errcode = 'P0001';
  end if;
  if not v_manager
     and v_m.status not in ('rascunho', 'aguardando_assinatura', 'aguardando_sa', 'aguardando_aprovacao')
     and not (v_m.status = 'sa_informada' and not v_m.requires_sa) then
    raise exception 'A ME % já tem SA lançada no ERP. Somente gestor ou administrador pode cancelá-la.', v_m.me_number
      using errcode = '42501';
  end if;

  perform set_config('app.audit_action', 'me.cancelada', true);
  perform set_config('app.justification', v_reason, true);
  if v_m.status = 'concluida' then
    perform set_config('app.correction', 'on', true);
  end if;

  update public.stock_movements
     set status = 'cancelada', cancelled_at = now(), cancelled_by = auth.uid(), cancel_reason = v_reason
   where id = p_id;

  return jsonb_build_object('id', p_id, 'status', 'cancelada');
end;
$$;

-- ---------------------------------------------------------------------
-- Correção administrativa (gestor/admin, com justificativa)
-- p_changes: chaves de cabeçalho e/ou "items": [{id, quantity_requested, quantity_delivered, notes}]
-- ---------------------------------------------------------------------
create or replace function public.correct_movement(p_id uuid, p_changes jsonb, p_justification text)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  s         public.app_settings := public.get_settings();
  v_m       public.stock_movements;
  v_just    text := nullif(btrim(coalesce(p_justification, '')), '');
  v_item    jsonb;
  v_req     numeric;
  v_del     numeric;
  v_new_wh  uuid;
  v_cnt     int;
begin
  if not public.has_any_role(array['gestor', 'admin']::public.app_role[]) then
    raise exception 'Somente gestor ou administrador pode corrigir uma ME.' using errcode = '42501';
  end if;
  if v_just is null or length(v_just) < 5 then
    raise exception 'Informe a justificativa da correção (mínimo 5 caracteres).' using errcode = '22023';
  end if;

  select * into v_m from public.stock_movements where id = p_id for update;
  if v_m.id is null or not public.can_access_warehouse(v_m.warehouse_id) then
    raise exception 'ME não encontrada.' using errcode = 'P0002';
  end if;
  if v_m.status = 'cancelada' then
    raise exception 'ME cancelada é somente consulta.' using errcode = 'P0001';
  end if;

  perform set_config('app.correction', 'on', true);
  perform set_config('app.audit_action', 'me.corrigida', true);
  perform set_config('app.justification', v_just, true);

  if p_changes ? 'warehouse_id' then
    v_new_wh := (p_changes ->> 'warehouse_id')::uuid;
    if not exists (select 1 from public.warehouses where id = v_new_wh and active)
       or not public.can_access_warehouse(v_new_wh) then
      raise exception 'Estoque de destino inválido ou sem permissão.' using errcode = '42501';
    end if;
  end if;

  if p_changes ? 'contract_id' and not exists (select 1 from public.contracts where id = (p_changes ->> 'contract_id')::uuid and active) then
    raise exception 'Contrato inválido ou inativo.' using errcode = '22023';
  end if;
  if p_changes ? 'sector_id' and not exists (select 1 from public.sectors where id = (p_changes ->> 'sector_id')::uuid and active) then
    raise exception 'Setor inválido ou inativo.' using errcode = '22023';
  end if;

  update public.stock_movements m set
    warehouse_id = coalesce(v_new_wh, m.warehouse_id),
    contract_id = case when p_changes ? 'contract_id' then (p_changes ->> 'contract_id')::uuid else m.contract_id end,
    sector_id = case when p_changes ? 'sector_id' then (p_changes ->> 'sector_id')::uuid else m.sector_id end,
    service_front_id = case when p_changes ? 'service_front_id' then nullif(p_changes ->> 'service_front_id', '')::uuid else m.service_front_id end,
    service_order_text = case when p_changes ? 'service_order_text' then nullif(btrim(p_changes ->> 'service_order_text'), '') else m.service_order_text end,
    service_order_id = case when p_changes ? 'service_order_text'
                            then (select id from public.service_orders where upper(code) = upper(btrim(p_changes ->> 'service_order_text')) limit 1)
                            else m.service_order_id end,
    fixed_asset_text = case when p_changes ? 'fixed_asset_text' then nullif(btrim(p_changes ->> 'fixed_asset_text'), '') else m.fixed_asset_text end,
    fixed_asset_id = case when p_changes ? 'fixed_asset_text'
                          then (select id from public.fixed_assets where upper(code) = upper(btrim(p_changes ->> 'fixed_asset_text')) limit 1)
                          else m.fixed_asset_id end,
    application_location_id = case when p_changes ? 'application_location_id' then nullif(p_changes ->> 'application_location_id', '')::uuid else m.application_location_id end,
    application_location_text = case when p_changes ? 'application_location_text' then nullif(btrim(p_changes ->> 'application_location_text'), '') else m.application_location_text end,
    notes = case when p_changes ? 'notes' then nullif(btrim(p_changes ->> 'notes'), '') else m.notes end
  where m.id = p_id;

  if jsonb_typeof(p_changes -> 'items') = 'array' then
    for v_item in select * from jsonb_array_elements(p_changes -> 'items') loop
      v_req := (v_item ->> 'quantity_requested')::numeric;
      v_del := (v_item ->> 'quantity_delivered')::numeric;
      if v_req is null or v_req <= 0 or v_del is null or v_del <= 0 then
        raise exception 'As quantidades devem ser maiores que zero.' using errcode = '22023';
      end if;
      if v_del > v_req and not s.allow_delivered_above_requested then
        raise exception 'A quantidade atendida não pode ser maior que a solicitada.' using errcode = '22023';
      end if;
      update public.stock_movement_items
         set quantity_requested = v_req,
             quantity_delivered = v_del,
             notes = case when v_item ? 'notes' then left(nullif(btrim(v_item ->> 'notes'), ''), 500) else notes end
       where id = (v_item ->> 'id')::uuid and movement_id = p_id;
      get diagnostics v_cnt = row_count;
      if v_cnt = 0 then
        raise exception 'Item informado não pertence a esta ME.' using errcode = '22023';
      end if;
    end loop;
  end if;

  return jsonb_build_object('id', p_id, 'status', v_m.status);
end;
$$;

-- ---------------------------------------------------------------------
-- Substituição de assinatura (mantém a anterior no histórico)
-- ---------------------------------------------------------------------
create or replace function public.replace_signature(
  p_id           uuid,
  p_storage_path text,
  p_employee_id  uuid,
  p_reason       text
)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_m       public.stock_movements;
  v_wh      public.warehouses;
  v_emp     public.employees;
  v_obj     record;
  v_reason  text := nullif(btrim(coalesce(p_reason, '')), '');
  v_new_id  uuid;
begin
  if not public.has_any_role(array['gestor', 'admin']::public.app_role[]) then
    raise exception 'Somente gestor ou administrador pode substituir uma assinatura.' using errcode = '42501';
  end if;
  if v_reason is null or length(v_reason) < 5 then
    raise exception 'Informe a justificativa da nova assinatura (mínimo 5 caracteres).' using errcode = '22023';
  end if;

  select * into v_m from public.stock_movements where id = p_id for update;
  if v_m.id is null or not public.can_access_warehouse(v_m.warehouse_id) then
    raise exception 'ME não encontrada.' using errcode = 'P0002';
  end if;
  if v_m.status = 'cancelada' then
    raise exception 'ME cancelada é somente consulta.' using errcode = 'P0001';
  end if;

  select * into v_wh from public.warehouses where id = v_m.warehouse_id;
  if p_storage_path not like v_wh.code || '/%/' || p_id::text || '/%' then
    raise exception 'Caminho da assinatura inválido para esta ME.' using errcode = '22023';
  end if;

  select * into v_emp from public.employees where id = p_employee_id and active;
  if v_emp.id is null then
    raise exception 'Funcionário inválido ou inativo.' using errcode = '22023';
  end if;

  select o.name, nullif(o.metadata ->> 'size', '')::int as size_bytes
    into v_obj
    from storage.objects o
   where o.bucket_id = 'assinaturas' and o.name = p_storage_path;
  if v_obj.name is null then
    raise exception 'Arquivo da nova assinatura não encontrado no armazenamento.' using errcode = '22023';
  end if;

  perform set_config('app.signature_replace', 'on', true);
  perform set_config('app.justification', v_reason, true);

  update public.signatures
     set is_current = false, replaced_at = now(), replaced_by = auth.uid(), replacement_reason = v_reason
   where movement_id = p_id and is_current;

  insert into public.signatures (movement_id, employee_id, signer_name, signer_registration, bucket,
                                 storage_path, mime_type, size_bytes, signed_at, uploaded_by, is_current)
  values (p_id, v_emp.id, v_emp.full_name, v_emp.registration, 'assinaturas',
          p_storage_path, 'image/png', v_obj.size_bytes, now(), auth.uid(), true)
  returning id into v_new_id;

  perform set_config('app.correction', 'on', true);
  perform set_config('app.audit_action', 'me.recebedor_alterado', true);
  update public.stock_movements
     set received_by_employee_id = v_emp.id,
         received_by_name = v_emp.full_name,
         received_by_registration = v_emp.registration,
         received_at = now()
   where id = p_id;

  return jsonb_build_object('id', p_id, 'signature_id', v_new_id);
end;
$$;

-- ---------------------------------------------------------------------
-- Eventos de interface relevantes (impressão, PDF, exportação)
-- ---------------------------------------------------------------------
create or replace function public.log_event(
  p_action      text,
  p_movement_id uuid default null,
  p_details     jsonb default null
)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_wh uuid;
begin
  if not public.is_active_user() then
    raise exception 'Sessão inválida ou usuário inativo.' using errcode = '42501';
  end if;
  if p_action not in ('me.impressa', 'me.pdf_gerado', 'me.assinatura_consultada', 'me.foto_consultada',
                      'exportacao.excel', 'etiquetas.impressas', 'qr.leitura_nao_encontrada') then
    raise exception 'Evento não permitido.' using errcode = '22023';
  end if;
  if p_movement_id is not null then
    select warehouse_id into v_wh from public.stock_movements where id = p_movement_id;
    if v_wh is null or not public.can_access_warehouse(v_wh) then
      raise exception 'ME não encontrada.' using errcode = 'P0002';
    end if;
  end if;
  if p_details is not null and length(p_details::text) > 4000 then
    p_details := jsonb_build_object('aviso', 'detalhes truncados');
  end if;

  perform public.write_audit(p_action, case when p_movement_id is null then 'interface' else 'stock_movements' end,
                             p_movement_id::text, p_movement_id, v_wh, null, p_details, null);
end;
$$;

-- ---------------------------------------------------------------------
-- Exportação (dados reais, mesmos filtros da lista)
-- ---------------------------------------------------------------------
create or replace function public.export_movements(p_filters jsonb default '{}'::jsonb, p_kind text default 'resumo')
returns jsonb
language plpgsql stable security invoker
set search_path = public, pg_temp
as $$
declare
  v_tz  text := (public.get_settings()).timezone;
  v_out jsonb;
begin
  if not public.has_any_role(array['gestor', 'admin', 'equipe_sa']::public.app_role[]) then
    raise exception 'Seu perfil não permite exportar dados.' using errcode = '42501';
  end if;

  if p_kind = 'itens' then
    select coalesce(jsonb_agg(to_jsonb(x) order by x.movement_at desc, x.me_number, x.line_number), '[]'::jsonb)
      into v_out
      from (
        select v.me_number, v.movement_at, v.warehouse_name, i.line_number, i.material_code,
               i.material_reference, i.material_name, i.unit, i.quantity_requested, i.quantity_delivered,
               i.location, coalesce(i.account_code || ' - ' || i.account_name, i.account_code) as account,
               v.contract_code || ' - ' || v.contract_name as contract, v.sector_name,
               v.service_front_name, v.service_order, v.fixed_asset, v.application_location,
               v.requester_name, v.requester_registration, v.sa_number, v.status, v.storekeeper_name,
               i.notes as item_notes
          from public.v_movements v
          join public.stock_movement_items i on i.movement_id = v.id
         where public.movement_matches(v, coalesce(p_filters, '{}'::jsonb), v_tz)
         order by v.movement_at desc
         limit 50000
      ) x;
  else
    select coalesce(jsonb_agg(to_jsonb(x) order by x.movement_at desc), '[]'::jsonb)
      into v_out
      from (
        select v.me_number, v.movement_at, v.warehouse_name,
               v.contract_code || ' - ' || v.contract_name as contract, v.sector_name,
               v.service_front_name, v.service_order, v.fixed_asset, v.application_location,
               v.requester_name, v.requester_registration, v.item_count, v.total_delivered,
               v.sa_number, v.status, v.storekeeper_name, v.sa_informed_at, v.sa_informed_by_name,
               v.cancel_reason, v.notes
          from public.v_movements v
         where public.movement_matches(v, coalesce(p_filters, '{}'::jsonb), v_tz)
         order by v.movement_at desc
         limit 20000
      ) x;
  end if;

  return v_out;
end;
$$;

-- ---------------------------------------------------------------------
-- Dashboard (indicadores separados por unidade de medida)
--   *_mes      = quantidade de MEs
--   *_lines    = quantidade de linhas de itens
--   *_qty      = soma das quantidades atendidas (somente dentro do mesmo material/unidade)
-- Itens e quantidades desconsideram MEs canceladas.
-- ---------------------------------------------------------------------
create or replace function public.dashboard_stats(p_filters jsonb default '{}'::jsonb)
returns jsonb
language plpgsql stable security invoker
set search_path = public, pg_temp
as $$
declare
  v_tz     text := (public.get_settings()).timezone;
  v_today  date := (now() at time zone v_tz)::date;
  v_result jsonb;
begin
  if not public.is_active_user() then
    raise exception 'Sessão inválida ou usuário inativo.' using errcode = '42501';
  end if;

  with _dash_mv as (
    select v.id, v.warehouse_id, v.warehouse_name, v.status, v.movement_at,
           (v.movement_at at time zone v_tz)::date as local_date,
           v.sector_name, v.service_front_name, v.storekeeper_name, v.item_count, v.total_delivered
      from public.v_movements v
     where public.movement_matches(v, coalesce(p_filters, '{}'::jsonb), v_tz)
  )
  select jsonb_build_object(
    'cards', (
      select jsonb_build_object(
        'total_mes',             count(*),
        'today_mes',             count(*) filter (where local_date = v_today),
        'item_lines',            coalesce(sum(item_count) filter (where status <> 'cancelada'), 0),
        'qty_delivered',         coalesce(sum(total_delivered) filter (where status <> 'cancelada'), 0),
        'aguardando_aprovacao',  count(*) filter (where status = 'aguardando_aprovacao'),
        'aguardando_sa',         count(*) filter (where status = 'aguardando_sa'),
        'sa_informada',          count(*) filter (where status = 'sa_informada'),
        'concluida',             count(*) filter (where status = 'concluida'),
        'cancelada',             count(*) filter (where status = 'cancelada')
      ) from _dash_mv
    ),
    'by_warehouse', coalesce((
      select jsonb_agg(jsonb_build_object('warehouse_id', w.id, 'warehouse', w.name, 'code', w.code,
                                          'mes', coalesce(x.mes, 0), 'pending_sa', coalesce(x.pending, 0),
                                          'item_lines', coalesce(x.lines, 0)) order by w.name)
        from public.warehouses w
        left join (
          select warehouse_id, count(*) as mes,
                 count(*) filter (where status = 'aguardando_sa') as pending,
                 sum(item_count) filter (where status <> 'cancelada') as lines
            from _dash_mv group by warehouse_id
        ) x on x.warehouse_id = w.id
       where w.active and public.can_access_warehouse(w.id)
    ), '[]'::jsonb),
    'daily', coalesce((
      select jsonb_agg(jsonb_build_object('date', d, 'warehouse', wn, 'mes', c) order by d, wn)
        from (select local_date as d, warehouse_name as wn, count(*) as c
                from _dash_mv
               where local_date >= coalesce(nullif(p_filters ->> 'date_from', '')::date, v_today - 29)
               group by 1, 2) t
    ), '[]'::jsonb),
    'weekly', coalesce((
      select jsonb_agg(jsonb_build_object('week', wk, 'warehouse', wn, 'mes', c) order by wk, wn)
        from (select date_trunc('week', local_date)::date as wk, warehouse_name as wn, count(*) as c
                from _dash_mv
               where local_date >= coalesce(nullif(p_filters ->> 'date_from', '')::date, v_today - 83)
               group by 1, 2) t
    ), '[]'::jsonb),
    'monthly', coalesce((
      select jsonb_agg(jsonb_build_object('month', mo, 'warehouse', wn, 'mes', c) order by mo, wn)
        from (select to_char(local_date, 'YYYY-MM') as mo, warehouse_name as wn, count(*) as c
                from _dash_mv
               where local_date >= coalesce(nullif(p_filters ->> 'date_from', '')::date, (date_trunc('month', v_today) - interval '11 months')::date)
               group by 1, 2) t
    ), '[]'::jsonb),
    'qty_by_unit', coalesce((
      select jsonb_agg(jsonb_build_object('unit', unit, 'qty', qty) order by qty desc)
        from (select i.unit, sum(i.quantity_delivered) as qty
                from public.stock_movement_items i
                join _dash_mv d on d.id = i.movement_id and d.status <> 'cancelada'
               group by 1) t
    ), '[]'::jsonb),
    'top_materials_lines', coalesce((
      select jsonb_agg(jsonb_build_object('material', name, 'code', code, 'lines', lines) order by lines desc, name)
        from (select i.material_name as name, i.material_code as code, count(*) as lines
                from public.stock_movement_items i
                join _dash_mv d on d.id = i.movement_id and d.status <> 'cancelada'
               group by 1, 2 order by 3 desc, 1 limit 10) t
    ), '[]'::jsonb),
    'top_materials_qty', coalesce((
      select jsonb_agg(jsonb_build_object('material', name, 'code', code, 'unit', unit, 'qty', qty) order by qty desc, name)
        from (select i.material_name as name, i.material_code as code, i.unit, sum(i.quantity_delivered) as qty
                from public.stock_movement_items i
                join _dash_mv d on d.id = i.movement_id and d.status <> 'cancelada'
               group by 1, 2, 3 order by 4 desc, 1 limit 10) t
    ), '[]'::jsonb),
    'by_sector', coalesce((
      select jsonb_agg(jsonb_build_object('label', sector_name, 'mes', c) order by c desc)
        from (select sector_name, count(*) as c from _dash_mv where status <> 'cancelada'
               group by 1 order by 2 desc limit 12) t
    ), '[]'::jsonb),
    'by_service_front', coalesce((
      select jsonb_agg(jsonb_build_object('label', coalesce(service_front_name, 'Não informado'), 'mes', c) order by c desc)
        from (select service_front_name, count(*) as c from _dash_mv where status <> 'cancelada'
               group by 1 order by 2 desc limit 12) t
    ), '[]'::jsonb),
    'by_user', coalesce((
      select jsonb_agg(jsonb_build_object('label', coalesce(storekeeper_name, '—'), 'mes', c) order by c desc)
        from (select storekeeper_name, count(*) as c from _dash_mv where status <> 'cancelada'
               group by 1 order by 2 desc limit 12) t
    ), '[]'::jsonb),
    'pending_aging', coalesce((
      select jsonb_agg(jsonb_build_object('warehouse', warehouse_name, 'bucket', bucket, 'mes', c) order by warehouse_name, ord)
        from (
          select warehouse_name,
                 case when age_days <= 1 then 'Até 1 dia' when age_days <= 3 then '2 a 3 dias'
                      when age_days <= 7 then '4 a 7 dias' else 'Mais de 7 dias' end as bucket,
                 case when age_days <= 1 then 1 when age_days <= 3 then 2 when age_days <= 7 then 3 else 4 end as ord,
                 count(*) as c
            from (select warehouse_name, (v_today - local_date) as age_days from _dash_mv where status = 'aguardando_sa') a
           group by 1, 2, 3
        ) t
    ), '[]'::jsonb)
  ) into v_result;

  return v_result;
end;
$$;


-- >>>>>>>>>> 05_rpc_administracao.sql
-- =====================================================================
-- 05 - FUNÇÕES DE ADMINISTRAÇÃO, MATERIAIS/QR CODE E SESSÃO
-- =====================================================================

-- ---------------------------------------------------------------------
-- QR Code do material: gerado automaticamente quando não informado.
-- O QR Code contém somente este identificador (nunca os dados do produto).
-- ---------------------------------------------------------------------
create or replace function public.generate_qr_value()
returns text
language sql volatile
set search_path = public, pg_temp
as $$
  select 'MAT-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 12));
$$;

create or replace function public.tg_material_defaults()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  new.code := upper(btrim(new.code));
  new.unit := upper(btrim(new.unit));
  new.name := btrim(new.name);
  if new.qr_code is null or btrim(new.qr_code) = '' then
    new.qr_code := public.generate_qr_value();
  end if;
  return new;
end;
$$;

drop trigger if exists material_defaults on public.materials;
create trigger material_defaults before insert or update on public.materials
  for each row execute function public.tg_material_defaults();

-- Mantém o histórico de QR Codes sincronizado com o código principal
create or replace function public.tg_material_qr_history()
returns trigger
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'INSERT' or new.qr_code is distinct from old.qr_code then
    update public.material_qr_codes set active = false
     where material_id = new.id and code <> new.qr_code and active;
    insert into public.material_qr_codes (material_id, code, active, created_by)
    values (new.id, new.qr_code, true, auth.uid())
    on conflict (code) do update set active = true;
  end if;
  return null;
end;
$$;

drop trigger if exists material_qr_history on public.materials;
create trigger material_qr_history after insert or update of qr_code on public.materials
  for each row execute function public.tg_material_qr_history();

create or replace function public.regenerate_material_qr(p_material_id uuid)
returns text
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_qr text := public.generate_qr_value();
begin
  if not public.can_manage_master_data() then
    raise exception 'Somente administrador ou almoxarife pode gerar um novo QR Code.' using errcode = '42501';
  end if;
  update public.materials set qr_code = v_qr where id = p_material_id;
  if not found then
    raise exception 'Material não encontrado.' using errcode = 'P0002';
  end if;
  return v_qr;
end;
$$;

create or replace function public.mark_labels_printed(p_material_ids uuid[])
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  if not public.has_any_role(array['admin', 'gestor', 'almoxarife']::public.app_role[]) then
    raise exception 'Sem permissão.' using errcode = '42501';
  end if;
  update public.material_qr_codes q set printed_at = now()
    from public.materials m
   where m.id = q.material_id and q.code = m.qr_code and m.id = any (p_material_ids);
  perform public.write_audit('etiquetas.impressas', 'materials', null, null, null, null,
                             jsonb_build_object('materiais', to_jsonb(p_material_ids)), null);
end;
$$;

-- ---------------------------------------------------------------------
-- Importação de materiais (upsert pelo código). Retorna resumo e erros por linha.
-- Cada linha: {code, reference, name, description, unit, location,
--              account_code, category_code, warehouse_code, active}
-- ---------------------------------------------------------------------
create or replace function public.import_materials(p_rows jsonb)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_row       jsonb;
  v_idx       int := 0;
  v_inserted  int := 0;
  v_updated   int := 0;
  v_errors    jsonb := '[]'::jsonb;
  v_account   uuid;
  v_category  uuid;
  v_wh        uuid;
  v_code      text;
  v_exists    boolean;
begin
  if not public.can_manage_master_data() then
    raise exception 'Somente administrador ou almoxarife pode importar materiais.' using errcode = '42501';
  end if;
  if jsonb_typeof(p_rows) <> 'array' then
    raise exception 'Formato de importação inválido.' using errcode = '22023';
  end if;
  if jsonb_array_length(p_rows) > 5000 then
    raise exception 'Importe no máximo 5.000 materiais por vez.' using errcode = '22023';
  end if;

  perform set_config('app.source', 'importacao', true);

  for v_row in select * from jsonb_array_elements(p_rows) loop
    v_idx := v_idx + 1;
    begin
      v_code := upper(btrim(coalesce(v_row ->> 'code', '')));
      if v_code = '' then raise exception 'código vazio'; end if;
      if coalesce(btrim(v_row ->> 'name'), '') = '' then raise exception 'nome vazio'; end if;
      if coalesce(btrim(v_row ->> 'unit'), '') = '' then raise exception 'unidade vazia'; end if;

      v_account := null; v_category := null; v_wh := null;
      if nullif(btrim(v_row ->> 'account_code'), '') is not null then
        select id into v_account from public.accounts where upper(code) = upper(btrim(v_row ->> 'account_code'));
        if v_account is null then raise exception 'conta % não cadastrada', v_row ->> 'account_code'; end if;
      end if;
      if nullif(btrim(v_row ->> 'category_code'), '') is not null then
        select id into v_category from public.material_categories where upper(code) = upper(btrim(v_row ->> 'category_code'));
        if v_category is null then raise exception 'categoria % não cadastrada', v_row ->> 'category_code'; end if;
      end if;
      if nullif(btrim(v_row ->> 'warehouse_code'), '') is not null then
        select id into v_wh from public.warehouses where upper(code) = upper(btrim(v_row ->> 'warehouse_code'));
        if v_wh is null then raise exception 'estoque % não cadastrado', v_row ->> 'warehouse_code'; end if;
      end if;

      select exists (select 1 from public.materials where code = v_code) into v_exists;

      insert into public.materials (code, reference, name, description, unit, location,
                                    account_id, category_id, warehouse_id, active)
      values (v_code, nullif(btrim(v_row ->> 'reference'), ''), btrim(v_row ->> 'name'),
              nullif(btrim(v_row ->> 'description'), ''), btrim(v_row ->> 'unit'),
              nullif(btrim(v_row ->> 'location'), ''), v_account, v_category, v_wh,
              coalesce((v_row ->> 'active')::boolean, true))
      -- Atualização: só sobrescreve com valores preenchidos na planilha.
      -- Células vazias (ou colunas ausentes) mantêm o que já está cadastrado.
      on conflict (code) do update set
        reference    = coalesce(excluded.reference, materials.reference),
        name         = excluded.name,
        description  = coalesce(excluded.description, materials.description),
        unit         = excluded.unit,
        location     = coalesce(excluded.location, materials.location),
        account_id   = coalesce(excluded.account_id, materials.account_id),
        category_id  = coalesce(excluded.category_id, materials.category_id),
        warehouse_id = coalesce(excluded.warehouse_id, materials.warehouse_id),
        active       = case when v_row ? 'active' then excluded.active else materials.active end;

      if v_exists then v_updated := v_updated + 1; else v_inserted := v_inserted + 1; end if;
    exception when others then
      v_errors := v_errors || jsonb_build_object('linha', v_idx, 'codigo', v_row ->> 'code', 'erro', sqlerrm);
    end;
  end loop;

  return jsonb_build_object('inseridos', v_inserted, 'atualizados', v_updated, 'erros', v_errors);
end;
$$;

-- ---------------------------------------------------------------------
-- Dados da sessão: perfil, papéis e estoques do usuário logado
-- ---------------------------------------------------------------------
create or replace function public.my_access()
returns jsonb
language sql stable security definer
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'profile', (select to_jsonb(p) from (select id, email, full_name, active, default_warehouse_id
                                          from public.profiles where id = auth.uid()) p),
    'roles', coalesce((select jsonb_agg(role order by role) from public.user_roles where user_id = auth.uid()), '[]'::jsonb),
    'warehouses', coalesce((
      select jsonb_agg(jsonb_build_object('id', w.id, 'code', w.code, 'name', w.name) order by w.name)
        from public.warehouses w
       where w.active and public.can_access_warehouse(w.id)
    ), '[]'::jsonb),
    'settings', (select to_jsonb(s) - 'updated_by' from public.app_settings s where s.id = 1)
  );
$$;

-- ---------------------------------------------------------------------
-- Usuários (administrador)
-- ---------------------------------------------------------------------
create or replace function public.admin_list_users()
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
begin
  if not public.is_admin() then
    raise exception 'Somente administrador.' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', p.id, 'email', p.email, 'full_name', p.full_name, 'active', p.active,
      'default_warehouse_id', p.default_warehouse_id, 'created_at', p.created_at,
      'roles', coalesce((select jsonb_agg(ur.role order by ur.role) from public.user_roles ur where ur.user_id = p.id), '[]'::jsonb),
      'warehouses', coalesce((select jsonb_agg(uw.warehouse_id) from public.user_warehouses uw where uw.user_id = p.id), '[]'::jsonb)
    ) order by p.full_name)
    from public.profiles p
  ), '[]'::jsonb);
end;
$$;

create or replace function public.admin_set_user_access(
  p_user_id              uuid,
  p_full_name            text,
  p_roles                public.app_role[],
  p_warehouse_ids        uuid[],
  p_active               boolean,
  p_default_warehouse_id uuid default null
)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_admins int;
begin
  if not public.is_admin() then
    raise exception 'Somente administrador pode alterar perfis e permissões.' using errcode = '42501';
  end if;
  if not exists (select 1 from public.profiles where id = p_user_id) then
    raise exception 'Usuário não encontrado.' using errcode = 'P0002';
  end if;
  if length(btrim(coalesce(p_full_name, ''))) < 3 then
    raise exception 'Informe o nome completo do usuário.' using errcode = '22023';
  end if;

  -- Impede remover o último administrador ativo
  if p_user_id = auth.uid() and (not p_active or not ('admin' = any (coalesce(p_roles, '{}')))) then
    select count(*) into v_admins
      from public.user_roles ur join public.profiles p on p.id = ur.user_id
     where ur.role = 'admin' and p.active and p.id <> p_user_id;
    if v_admins = 0 then
      raise exception 'Você é o único administrador ativo. Cadastre outro administrador antes de remover seu acesso.'
        using errcode = 'P0001';
    end if;
  end if;

  if p_default_warehouse_id is not null and not (p_default_warehouse_id = any (coalesce(p_warehouse_ids, '{}'))) then
    raise exception 'O estoque padrão precisa estar entre os estoques autorizados.' using errcode = '22023';
  end if;

  perform set_config('app.source', 'administracao', true);

  update public.profiles
     set full_name = btrim(p_full_name), active = coalesce(p_active, true),
         default_warehouse_id = p_default_warehouse_id
   where id = p_user_id;

  delete from public.user_roles where user_id = p_user_id and not (role = any (coalesce(p_roles, '{}')));
  insert into public.user_roles (user_id, role, created_by)
  select p_user_id, r, auth.uid() from unnest(coalesce(p_roles, '{}')) r
  on conflict do nothing;

  delete from public.user_warehouses where user_id = p_user_id and not (warehouse_id = any (coalesce(p_warehouse_ids, '{}')));
  insert into public.user_warehouses (user_id, warehouse_id, created_by)
  select p_user_id, w, auth.uid() from unnest(coalesce(p_warehouse_ids, '{}')) w
  on conflict do nothing;

  return jsonb_build_object('id', p_user_id);
end;
$$;

-- Atualização do próprio nome (o usuário não altera papéis nem estoques)
create or replace function public.update_my_profile(p_full_name text, p_default_warehouse_id uuid default null)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  if not public.is_active_user() then
    raise exception 'Sessão inválida.' using errcode = '42501';
  end if;
  if length(btrim(coalesce(p_full_name, ''))) < 3 then
    raise exception 'Informe o nome completo.' using errcode = '22023';
  end if;
  if p_default_warehouse_id is not null and not public.can_access_warehouse(p_default_warehouse_id) then
    raise exception 'Estoque não autorizado.' using errcode = '42501';
  end if;
  update public.profiles set full_name = btrim(p_full_name), default_warehouse_id = p_default_warehouse_id
   where id = auth.uid();
end;
$$;

-- ---------------------------------------------------------------------
-- Parâmetros (administrador)
-- ---------------------------------------------------------------------
create or replace function public.update_settings(p jsonb)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  if not public.is_admin() then
    raise exception 'Somente administrador pode alterar os parâmetros.' using errcode = '42501';
  end if;

  if p ? 'sa_number_pattern' then
    begin
      perform 'TESTE' ~ (p ->> 'sa_number_pattern');
    exception when others then
      raise exception 'Expressão regular da SA inválida.' using errcode = '22023';
    end;
  end if;
  if p ? 'timezone' and not exists (select 1 from pg_timezone_names where name = p ->> 'timezone') then
    raise exception 'Fuso horário inválido.' using errcode = '22023';
  end if;

  perform set_config('app.source', 'administracao', true);

  update public.app_settings s set
    me_prefix = coalesce(upper(p ->> 'me_prefix'), s.me_prefix),
    me_number_pattern = coalesce(p ->> 'me_number_pattern', s.me_number_pattern),
    me_sequence_digits = coalesce((p ->> 'me_sequence_digits')::smallint, s.me_sequence_digits),
    require_approval = coalesce((p ->> 'require_approval')::boolean, s.require_approval),
    allow_delivered_above_requested = coalesce((p ->> 'allow_delivered_above_requested')::boolean, s.allow_delivered_above_requested),
    allow_duplicate_material_lines = coalesce((p ->> 'allow_duplicate_material_lines')::boolean, s.allow_duplicate_material_lines),
    sa_number_unique = coalesce((p ->> 'sa_number_unique')::boolean, s.sa_number_unique),
    sa_number_pattern = coalesce(p ->> 'sa_number_pattern', s.sa_number_pattern),
    auto_complete_on_sa = coalesce((p ->> 'auto_complete_on_sa')::boolean, s.auto_complete_on_sa),
    timezone = coalesce(p ->> 'timezone', s.timezone),
    company_name = coalesce(nullif(btrim(p ->> 'company_name'), ''), s.company_name)
  where s.id = 1;

  return (select to_jsonb(s) from public.app_settings s where s.id = 1);
end;
$$;

-- ---------------------------------------------------------------------
-- Primeiro administrador (executar no SQL Editor, como postgres)
--   select public.bootstrap_admin('seu.email@empresa.com.br', 'Seu Nome');
-- Funciona apenas enquanto não houver nenhum administrador.
-- ---------------------------------------------------------------------
create or replace function public.bootstrap_admin(p_email text, p_full_name text default null)
returns text
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid;
begin
  if exists (select 1 from public.user_roles where role = 'admin') then
    raise exception 'Já existe administrador cadastrado. Use a tela de Usuários.' using errcode = 'P0001';
  end if;

  select id into v_id from auth.users where lower(email) = lower(btrim(p_email));
  if v_id is null then
    raise exception 'Usuário % não existe no Supabase Auth. Crie-o em Authentication > Users primeiro.', p_email
      using errcode = 'P0002';
  end if;

  insert into public.profiles (id, email, full_name, active)
  values (v_id, lower(btrim(p_email)), coalesce(nullif(btrim(p_full_name), ''), split_part(p_email, '@', 1)), true)
  on conflict (id) do update set active = true,
    full_name = coalesce(nullif(btrim(p_full_name), ''), public.profiles.full_name);

  insert into public.user_roles (user_id, role) values (v_id, 'admin') on conflict do nothing;
  insert into public.user_warehouses (user_id, warehouse_id)
  select v_id, id from public.warehouses where active
  on conflict do nothing;

  return 'Administrador configurado: ' || p_email;
end;
$$;
revoke all on function public.bootstrap_admin(text, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Apoio aos DADOS FICTÍCIOS (somente service_role / postgres)
-- ---------------------------------------------------------------------
create or replace function public.demo_mark_movement(p_id uuid, p_movement_at timestamptz)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  perform set_config('app.internal_totals', 'on', true);  -- evita auditoria e guarda de status
  update public.stock_movements
     set is_demo = true,
         movement_at = p_movement_at,
         requested_at = p_movement_at,
         received_at = p_movement_at + interval '2 minutes',
         sa_informed_at = case when sa_informed_at is not null then p_movement_at + interval '1 day 2 hours' end,
         completed_at = case when completed_at is not null then p_movement_at + interval '1 day 3 hours' end,
         cancelled_at = case when cancelled_at is not null then p_movement_at + interval '5 hours' end,
         notes = btrim(coalesce(notes, '') || case when coalesce(notes, '') like '%[DADO FICTÍCIO]%' then '' else ' [DADO FICTÍCIO]' end)
   where id = p_id;
  update public.movement_status_history set changed_at = p_movement_at
   where movement_id = p_id and from_status is null;
  update public.movement_status_history set changed_at = p_movement_at + interval '1 day 2 hours'
   where movement_id = p_id and to_status = 'sa_informada';
  update public.movement_status_history set changed_at = p_movement_at + interval '1 day 3 hours'
   where movement_id = p_id and to_status = 'concluida';
  update public.movement_status_history set changed_at = p_movement_at + interval '5 hours'
   where movement_id = p_id and to_status = 'cancelada';
  update public.erp_sa_records set informed_at = p_movement_at + interval '1 day 2 hours'
   where movement_id = p_id;
  update public.signatures set signed_at = p_movement_at + interval '2 minutes', uploaded_at = p_movement_at + interval '2 minutes'
   where movement_id = p_id;
  perform set_config('app.internal_totals', 'off', true);
end;
$$;
revoke all on function public.demo_mark_movement(uuid, timestamptz) from public, anon, authenticated;

create or replace function public.demo_set_user_access(p_email text, p_full_name text, p_roles public.app_role[], p_warehouse_codes text[])
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid;
begin
  select id into v_id from public.profiles where lower(email) = lower(p_email);
  if v_id is null then
    raise exception 'Perfil % não encontrado', p_email;
  end if;
  update public.profiles set full_name = p_full_name, active = true where id = v_id;
  insert into public.user_roles (user_id, role) select v_id, r from unnest(p_roles) r on conflict do nothing;
  insert into public.user_warehouses (user_id, warehouse_id)
  select v_id, w.id from public.warehouses w where w.code = any (p_warehouse_codes)
  on conflict do nothing;
end;
$$;
revoke all on function public.demo_set_user_access(text, text, public.app_role[], text[]) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Importação de funcionários por planilha (ver 11_importacao_funcionarios.sql)
-- ---------------------------------------------------------------------
create or replace function public.import_employees(p_rows jsonb)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_row       jsonb;
  v_idx       int := 0;
  v_inserted  int := 0;
  v_updated   int := 0;
  v_errors    jsonb := '[]'::jsonb;
  v_reg       text;
  v_name      text;
  v_sector    text;
  v_sector_id uuid;
  v_exists    boolean;
begin
  if not public.can_manage_master_data() then
    raise exception 'Somente administrador ou almoxarife pode importar funcionários.' using errcode = '42501';
  end if;
  if jsonb_typeof(p_rows) <> 'array' then
    raise exception 'Formato de importação inválido.' using errcode = '22023';
  end if;
  if jsonb_array_length(p_rows) > 5000 then
    raise exception 'Importe no máximo 5.000 funcionários por vez.' using errcode = '22023';
  end if;

  perform set_config('app.source', 'importacao', true);

  for v_row in select * from jsonb_array_elements(p_rows) loop
    v_idx := v_idx + 1;
    begin
      v_reg  := btrim(coalesce(v_row ->> 'registration', ''));
      v_name := regexp_replace(btrim(coalesce(v_row ->> 'full_name', '')), '\s+', ' ', 'g');
      if v_reg = '' then raise exception 'matrícula vazia'; end if;
      if length(v_reg) > 30 then raise exception 'matrícula com mais de 30 caracteres'; end if;
      if length(v_name) < 3 then raise exception 'nome vazio ou muito curto'; end if;

      v_sector_id := null;
      v_sector := nullif(btrim(coalesce(v_row ->> 'sector', '')), '');
      if v_sector is not null then
        select id into v_sector_id from public.sectors
         where upper(code) = upper(v_sector) or lower(name) = lower(v_sector)
         order by (upper(code) = upper(v_sector)) desc
         limit 1;
        if v_sector_id is null then
          insert into public.sectors (code, name)
          values (left(upper(regexp_replace(v_sector, '\s+', '-', 'g')), 40), left(v_sector, 160))
          on conflict (code) do nothing;
          select id into v_sector_id from public.sectors
           where upper(code) = left(upper(regexp_replace(v_sector, '\s+', '-', 'g')), 40);
        end if;
      end if;

      select exists (select 1 from public.employees where registration = v_reg) into v_exists;

      insert into public.employees (registration, full_name, job_title, sector_id, active)
      values (v_reg, left(v_name, 160), left(nullif(btrim(coalesce(v_row ->> 'job_title', '')), ''), 80), v_sector_id,
              coalesce((v_row ->> 'active')::boolean, true))
      on conflict (registration) do update set
        full_name = excluded.full_name,
        job_title = coalesce(excluded.job_title, employees.job_title),
        sector_id = coalesce(excluded.sector_id, employees.sector_id),
        active    = case when v_row ? 'active' then excluded.active else employees.active end;

      if v_exists then v_updated := v_updated + 1; else v_inserted := v_inserted + 1; end if;
    exception when others then
      v_errors := v_errors || jsonb_build_object('linha', v_idx, 'codigo', v_row ->> 'registration', 'erro', sqlerrm);
    end;
  end loop;

  return jsonb_build_object('inseridos', v_inserted, 'atualizados', v_updated, 'erros', v_errors);
end;
$$;

revoke execute on function public.import_employees(jsonb) from public, anon;
grant execute on function public.import_employees(jsonb) to authenticated;

-- ---------------------------------------------------------------------
-- Importação de tabelas auxiliares (ativos fixos, locais de aplicação,
-- contratos, setores, frentes, OS, contas, categorias) por planilha.
-- Atualiza pelo código: se já existe, atualiza o nome (e "ativo", se vier).
-- p_rows: [{code, name, active?, kind?}]
-- ---------------------------------------------------------------------
create or replace function public.import_lookups(p_table text, p_rows jsonb)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_row      jsonb;
  v_idx      int := 0;
  v_inserted int := 0;
  v_updated  int := 0;
  v_errors   jsonb := '[]'::jsonb;
  v_code     text;
  v_name     text;
  v_kind     text;
  v_active   boolean;
  v_exists   boolean;
begin
  if not public.can_manage_master_data() then
    raise exception 'Somente administrador ou almoxarife pode importar cadastros.' using errcode = '42501';
  end if;
  if p_table not in ('contracts', 'sectors', 'service_fronts', 'service_orders', 'fixed_assets',
                     'application_locations', 'accounts', 'material_categories') then
    raise exception 'Tabela de cadastro inválida.' using errcode = '22023';
  end if;
  if jsonb_typeof(p_rows) <> 'array' then
    raise exception 'Formato de importação inválido.' using errcode = '22023';
  end if;
  if jsonb_array_length(p_rows) > 5000 then
    raise exception 'Importe no máximo 5.000 linhas por vez.' using errcode = '22023';
  end if;

  perform set_config('app.source', 'importacao', true);

  for v_row in select * from jsonb_array_elements(p_rows) loop
    v_idx := v_idx + 1;
    begin
      v_code := upper(btrim(coalesce(v_row ->> 'code', '')));
      v_name := regexp_replace(btrim(coalesce(v_row ->> 'name', '')), '\s+', ' ', 'g');
      if v_code = '' then raise exception 'código vazio'; end if;
      if length(v_code) > 40 then raise exception 'código com mais de 40 caracteres'; end if;
      if length(v_name) < 2 then raise exception 'nome vazio ou muito curto'; end if;
      v_name := left(v_name, 160);
      v_active := case when v_row ? 'active' then (v_row ->> 'active')::boolean else null end;

      execute format('select exists (select 1 from public.%I where upper(code) = $1)', p_table) into v_exists using v_code;

      if p_table = 'service_fronts' then
        v_kind := lower(btrim(coalesce(v_row ->> 'kind', '')));
        v_kind := case when v_kind like 'equip%' then 'equipamento' when v_kind = '' then null else 'frente' end;
        if v_exists then
          update public.service_fronts
             set name = v_name, kind = coalesce(v_kind, kind), active = coalesce(v_active, active)
           where upper(code) = v_code;
        else
          insert into public.service_fronts (code, name, kind, active)
          values (v_code, v_name, coalesce(v_kind, 'frente'), coalesce(v_active, true));
        end if;
      elsif v_exists then
        execute format('update public.%I set name = $1, active = coalesce($2, active) where upper(code) = $3', p_table)
          using v_name, v_active, v_code;
      else
        execute format('insert into public.%I (code, name, active) values ($1, $2, coalesce($3, true))', p_table)
          using v_code, v_name, v_active;
      end if;

      if v_exists then v_updated := v_updated + 1; else v_inserted := v_inserted + 1; end if;
    exception when others then
      v_errors := v_errors || jsonb_build_object('linha', v_idx, 'codigo', v_row ->> 'code', 'erro', sqlerrm);
    end;
  end loop;

  return jsonb_build_object('inseridos', v_inserted, 'atualizados', v_updated, 'erros', v_errors);
end;
$$;

revoke all on function public.import_lookups(text, jsonb) from public;
grant execute on function public.import_lookups(text, jsonb) to authenticated;


-- >>>>>>>>>> 06_rls_e_permissoes.sql
-- =====================================================================
-- 06 - ROW LEVEL SECURITY, POLICIES E PERMISSÕES DE EXECUÇÃO
-- Princípio: leitura conforme perfil/estoque; gravação de movimentações
-- SOMENTE pelas funções RPC (não existe policy de escrita direta).
-- =====================================================================

-- Habilita RLS em todas as tabelas do sistema
do $$
declare
  t text;
begin
  foreach t in array array[
    'warehouses', 'profiles', 'user_roles', 'user_warehouses', 'app_settings',
    'contracts', 'sectors', 'service_fronts', 'service_orders', 'fixed_assets',
    'application_locations', 'accounts', 'material_categories', 'employees',
    'materials', 'material_qr_codes', 'movement_sequences',
    'stock_movements', 'stock_movement_items', 'signatures', 'erp_sa_records',
    'movement_status_history', 'audit_logs'
  ] loop
    execute format('alter table public.%I enable row level security', t);
  end loop;
end $$;

-- Remove policies anteriores (permite reexecutar o script)
do $$
declare
  r record;
begin
  for r in select policyname, tablename from pg_policies where schemaname = 'public' loop
    execute format('drop policy if exists %I on public.%I', r.policyname, r.tablename);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- Estoques
-- ---------------------------------------------------------------------
create policy warehouses_select on public.warehouses
  for select to authenticated using (public.is_active_user());
create policy warehouses_insert on public.warehouses
  for insert to authenticated with check (public.is_admin());
create policy warehouses_update on public.warehouses
  for update to authenticated using (public.is_admin()) with check (public.is_admin());

-- ---------------------------------------------------------------------
-- Perfis, papéis e vínculos
-- Nomes de usuários são visíveis aos usuários ativos (exibição de
-- "responsável pela baixa", "SA informada por" etc.). Alterações somente
-- pelas funções admin_set_user_access / update_my_profile.
-- ---------------------------------------------------------------------
create policy profiles_select on public.profiles
  for select to authenticated using (public.is_active_user() or id = auth.uid());

create policy user_roles_select on public.user_roles
  for select to authenticated using (user_id = auth.uid() or public.is_admin());

create policy user_warehouses_select on public.user_warehouses
  for select to authenticated using (user_id = auth.uid() or public.is_admin());

-- ---------------------------------------------------------------------
-- Parâmetros: leitura para todos os ativos; alteração por update_settings()
-- ---------------------------------------------------------------------
create policy app_settings_select on public.app_settings
  for select to authenticated using (public.is_active_user());

-- ---------------------------------------------------------------------
-- Cadastros auxiliares, funcionários e materiais
-- Leitura: usuários ativos. Inclusão/alteração: administrador e almoxarife.
-- Não há DELETE: utilize o campo "active" (inativação).
-- ---------------------------------------------------------------------
do $$
declare
  t text;
begin
  foreach t in array array[
    'contracts', 'sectors', 'service_fronts', 'service_orders', 'fixed_assets',
    'application_locations', 'accounts', 'material_categories', 'employees', 'materials'
  ] loop
    execute format('create policy %I on public.%I for select to authenticated using (public.is_active_user())',
                   t || '_select', t);
    execute format('create policy %I on public.%I for insert to authenticated with check (public.can_manage_master_data())',
                   t || '_insert', t);
    execute format('create policy %I on public.%I for update to authenticated using (public.can_manage_master_data()) with check (public.can_manage_master_data())',
                   t || '_update', t);
  end loop;
end $$;

create policy material_qr_codes_select on public.material_qr_codes
  for select to authenticated using (public.is_active_user());

-- ---------------------------------------------------------------------
-- Movimentações: somente leitura, restrita aos estoques autorizados
-- ---------------------------------------------------------------------
create policy stock_movements_select on public.stock_movements
  for select to authenticated using (public.can_access_warehouse(warehouse_id));

create policy stock_movement_items_select on public.stock_movement_items
  for select to authenticated using (public.can_access_movement(movement_id));

-- Assinaturas: almoxarife, gestor, equipe SA e admin dos estoques autorizados
create policy signatures_select on public.signatures
  for select to authenticated using (public.can_access_movement(movement_id));

create policy erp_sa_records_select on public.erp_sa_records
  for select to authenticated using (public.can_access_movement(movement_id));

create policy movement_status_history_select on public.movement_status_history
  for select to authenticated using (public.can_access_movement(movement_id));

-- movement_sequences: nenhuma policy (acesso apenas pela função next_me_number)

-- ---------------------------------------------------------------------
-- Auditoria: administrador vê tudo; gestor vê eventos das MEs dos seus estoques
-- ---------------------------------------------------------------------
create policy audit_logs_select on public.audit_logs
  for select to authenticated using (
    public.is_admin()
    or (public.has_role('gestor') and warehouse_id is not null and public.can_access_warehouse(warehouse_id))
  );

-- ---------------------------------------------------------------------
-- Privilégios de tabela (defesa em profundidade, além da RLS)
-- ---------------------------------------------------------------------
revoke all on all tables in schema public from anon;
revoke insert, update, delete, truncate on
  public.profiles, public.user_roles, public.user_warehouses, public.app_settings,
  public.material_qr_codes, public.movement_sequences, public.stock_movements,
  public.stock_movement_items, public.signatures, public.erp_sa_records,
  public.movement_status_history, public.audit_logs
from authenticated;
revoke delete, truncate on
  public.warehouses, public.contracts, public.sectors, public.service_fronts, public.service_orders,
  public.fixed_assets, public.application_locations, public.accounts, public.material_categories,
  public.employees, public.materials
from authenticated;

grant select on all tables in schema public to authenticated;
grant insert, update on
  public.warehouses, public.contracts, public.sectors, public.service_fronts, public.service_orders,
  public.fixed_assets, public.application_locations, public.accounts, public.material_categories,
  public.employees, public.materials
to authenticated;
revoke select on public.movement_sequences from authenticated;

-- ---------------------------------------------------------------------
-- Execução de funções
-- ---------------------------------------------------------------------
revoke execute on all functions in schema public from public, anon;

grant execute on function
  public.is_active_user(), public.has_role(public.app_role), public.has_any_role(public.app_role[]),
  public.is_admin(), public.can_manage_master_data(), public.can_access_warehouse(uuid), public.can_access_warehouse_code(text),
  public.can_access_movement(uuid), public.get_settings(), public.request_header(text),
  public.jsonb_diff(jsonb, jsonb),
  public.movement_matches(public.v_movements, jsonb, text),
  public.search_movements(jsonb, int, int, text, text),
  public.find_material_by_code(text), public.search_materials(text, boolean, int),
  public.create_movement(jsonb), public.approve_movement(uuid, text),
  public.inform_sa(uuid, text, text), public.complete_movement(uuid, text, text),
  public.cancel_movement(uuid, text), public.correct_movement(uuid, jsonb, text),
  public.replace_signature(uuid, text, uuid, text), public.log_event(text, uuid, jsonb),
  public.export_movements(jsonb, text), public.dashboard_stats(jsonb),
  public.generate_qr_value(), public.regenerate_material_qr(uuid), public.mark_labels_printed(uuid[]),
  public.import_materials(jsonb), public.my_access(), public.admin_list_users(),
  public.admin_set_user_access(uuid, text, public.app_role[], uuid[], boolean, uuid),
  public.update_my_profile(text, uuid), public.update_settings(jsonb)
to authenticated;

-- Funções internas / restritas
revoke execute on function public.next_me_number(uuid, timestamptz) from authenticated;
revoke execute on function public.write_audit(text, text, text, uuid, uuid, jsonb, jsonb, text) from authenticated;
revoke execute on function public.bootstrap_admin(text, text) from authenticated;
revoke execute on function public.demo_mark_movement(uuid, timestamptz) from authenticated;
revoke execute on function public.demo_set_user_access(text, text, public.app_role[], text[]) from authenticated;
grant execute on function public.demo_mark_movement(uuid, timestamptz) to service_role;
grant execute on function public.demo_set_user_access(text, text, public.app_role[], text[]) to service_role;

-- Funções de trigger não precisam ser chamadas diretamente
revoke execute on function
  public.tg_audit_row(), public.tg_set_timestamps(), public.handle_new_auth_user(),
  public.handle_auth_user_email_change(), public.tg_refresh_movement_totals(),
  public.tg_movement_status_history(), public.tg_guard_movement_update(),
  public.tg_guard_item_change(), public.tg_block_delete(), public.tg_block_audit_change(),
  public.tg_guard_signature_update(), public.tg_settings_timestamps(),
  public.tg_material_defaults(), public.tg_material_qr_history()
from authenticated;

-- ---------------------------------------------------------------------
-- Realtime: painel e pendências atualizam sozinhos quando uma ME muda
-- (o Realtime respeita a RLS acima)
-- ---------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    if not exists (
      select 1 from pg_publication_tables
       where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'stock_movements'
    ) then
      execute 'alter publication supabase_realtime add table public.stock_movements';
    end if;
  end if;
end $$;


-- >>>>>>>>>> 07_storage.sql
-- =====================================================================
-- 07 - SUPABASE STORAGE: BUCKETS PRIVADOS E POLICIES
-- Estrutura dos arquivos:
--   assinaturas/{COD_ESTOQUE}/{ANO}/{ID_DA_ME}/assinatura_{timestamp}.png
--   documentos/{COD_ESTOQUE}/{ANO}/{ID_DA_ME}/{arquivo}   (PDFs e anexos futuros)
-- Nenhum bucket é público: a leitura usa URL assinada de curta duração.
-- Não há policy de UPDATE/DELETE: arquivos são imutáveis (evidência).
-- =====================================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  ('assinaturas', 'assinaturas', false, 1048576, array['image/png', 'image/jpeg', 'image/webp']),
  ('documentos',  'documentos',  false, 10485760, array['application/pdf', 'image/png', 'image/jpeg'])
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "assinaturas: leitura por estoque autorizado" on storage.objects;
drop policy if exists "assinaturas: envio por almoxarife/gestor/admin" on storage.objects;
drop policy if exists "documentos: leitura por estoque autorizado" on storage.objects;
drop policy if exists "documentos: envio por gestor/admin/almoxarife" on storage.objects;

-- Leitura: qualquer perfil ativo com acesso ao estoque da pasta
create policy "assinaturas: leitura por estoque autorizado"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'assinaturas'
    and public.can_access_warehouse_code((storage.foldername(name))[1])
  );

-- Envio: somente perfis que registram saídas, no estoque autorizado,
-- em pasta {ESTOQUE}/{ANO}/{UUID}/ e arquivo .png/.jpg/.webp
create policy "assinaturas: envio por almoxarife/gestor/admin"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'assinaturas'
    and public.has_any_role(array['almoxarife', 'gestor', 'admin']::public.app_role[])
    and public.can_access_warehouse_code((storage.foldername(name))[1])
    and (storage.foldername(name))[2] ~ '^[0-9]{4}$'
    and (storage.foldername(name))[3] ~ '^[0-9a-f-]{36}$'
    and name ~* '\.(png|jpe?g|webp)$'
  );

create policy "documentos: leitura por estoque autorizado"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'documentos'
    and public.can_access_warehouse_code((storage.foldername(name))[1])
  );

create policy "documentos: envio por gestor/admin/almoxarife"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'documentos'
    and public.has_any_role(array['almoxarife', 'gestor', 'admin']::public.app_role[])
    and public.can_access_warehouse_code((storage.foldername(name))[1])
  );


-- >>>>>>>>>> 07b_balcao.sql
-- =====================================================================
-- BALCÃO DE SEPARAÇÃO (leitor QR sem fio + tela do solicitante)
-- Fluxo: almoxarife abre a ME no balcão (status rascunho = "Em separação")
--   -> bipa os materiais (cada leitura é gravada na hora)
--   -> FINALIZAR SEPARAÇÃO (aguardando_assinatura = "Aguardando confirmação")
--   -> solicitante confere no tablet e CONFIRMA (assinatura agora; facial plugável)
--   -> ME confirmada segue o fluxo normal (SA / baixa no ERP).
-- O tablet do solicitante usa um usuário com perfil "terminal", pareado à ME
-- por um código de 6 dígitos. O perfil terminal NÃO enxerga as MEs do estoque:
-- só a ME com que está pareado, pelas funções deste arquivo.
-- Pré-requisito: o valor 'terminal' no tipo app_role (arquivo 16a).
-- Pode ser reexecutado.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) Perfil terminal não enxerga MEs pelo vínculo de estoque
-- ---------------------------------------------------------------------
create or replace function public.can_access_warehouse(p_warehouse_id uuid)
returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$
  select public.is_admin()
      or exists (
        select 1
          from public.user_warehouses uw
          join public.profiles p on p.id = uw.user_id
         where uw.user_id = auth.uid()
           and uw.warehouse_id = p_warehouse_id
           and p.active
           and exists (select 1 from public.user_roles ur where ur.user_id = p.id and ur.role <> 'terminal')
      );
$$;

-- Terminal vinculado ao estoque (usado só no pareamento)
create or replace function public.is_terminal_of_warehouse(p_warehouse_id uuid)
returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
      from public.user_warehouses uw
      join public.profiles p on p.id = uw.user_id
      join public.user_roles ur on ur.user_id = p.id and ur.role = 'terminal'
     where uw.user_id = auth.uid() and uw.warehouse_id = p_warehouse_id and p.active
  );
$$;

-- ---------------------------------------------------------------------
-- 2) Campos novos na ME
-- ---------------------------------------------------------------------
alter table public.stock_movements add column if not exists entry_channel text not null default 'assistente';
alter table public.stock_movements add column if not exists separation_finished_at timestamptz;
alter table public.stock_movements add column if not exists confirmed_at timestamptz;
alter table public.stock_movements add column if not exists confirmation_method text;
alter table public.stock_movements drop constraint if exists stock_movements_entry_channel_ck;
alter table public.stock_movements add constraint stock_movements_entry_channel_ck
  check (entry_channel in ('assistente', 'balcao', 'offline'));

-- ---------------------------------------------------------------------
-- 3) Sessões do balcão (vínculo ME <-> almoxarife <-> tablet)
-- ---------------------------------------------------------------------
create table if not exists public.counter_sessions (
  id                  uuid primary key default gen_random_uuid(),
  movement_id         uuid not null unique references public.stock_movements (id),
  warehouse_id        uuid not null references public.warehouses (id),
  opened_by           uuid not null references public.profiles (id),
  pairing_code        text not null,
  pairing_expires_at  timestamptz not null,
  terminal_user_id    uuid references public.profiles (id),
  paired_at           timestamptz,
  status              text not null default 'em_separacao',
  version             integer not null default 1,
  last_event          text,
  last_event_at       timestamptz not null default now(),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  constraint counter_sessions_status_ck
    check (status in ('em_separacao', 'aguardando_confirmacao', 'confirmada', 'cancelada')),
  constraint counter_sessions_code_ck check (pairing_code ~ '^[0-9]{6}$')
);
create unique index if not exists counter_sessions_active_code_uk
  on public.counter_sessions (pairing_code) where status in ('em_separacao', 'aguardando_confirmacao');
create index if not exists counter_sessions_terminal_idx on public.counter_sessions (terminal_user_id, status);
create index if not exists counter_sessions_opened_idx on public.counter_sessions (opened_by, status);

-- Log de cada leitura (inclusive QR não encontrado e leituras repetidas)
create table if not exists public.scan_events (
  id            bigserial primary key,
  movement_id   uuid not null references public.stock_movements (id),
  scan_id       uuid not null unique,
  scanned_code  text,
  material_id   uuid references public.materials (id),
  item_id       uuid,
  quantity      numeric(14,3),
  result        text not null,
  response      jsonb,
  user_id       uuid references public.profiles (id) default auth.uid(),
  created_at    timestamptz not null default now(),
  constraint scan_events_result_ck check (result in (
    'incluido', 'somado', 'ja_incluido', 'nao_encontrado', 'invalido', 'inativo', 'quantidade_invalida'
  ))
);
create index if not exists scan_events_movement_idx on public.scan_events (movement_id, created_at);

-- Tentativas de confirmação pelo solicitante (assinatura agora; facial depois)
create table if not exists public.confirmation_attempts (
  id            uuid primary key default gen_random_uuid(),
  movement_id   uuid not null references public.stock_movements (id),
  employee_id   uuid references public.employees (id),
  method        text not null,
  provider      text,
  result        text not null,
  score         numeric,
  liveness      boolean,
  detail        jsonb,
  consumed_at   timestamptz,
  created_by    uuid references public.profiles (id) default auth.uid(),
  created_at    timestamptz not null default now(),
  constraint confirmation_attempts_method_ck check (method in ('assinatura', 'facial')),
  constraint confirmation_attempts_result_ck check (result in ('sucesso', 'falha', 'cancelada', 'erro'))
);
create index if not exists confirmation_attempts_movement_idx on public.confirmation_attempts (movement_id, created_at);

alter table public.counter_sessions enable row level security;
alter table public.scan_events enable row level security;
alter table public.confirmation_attempts enable row level security;

drop policy if exists counter_sessions_select on public.counter_sessions;
create policy counter_sessions_select on public.counter_sessions
  for select to authenticated using (
    opened_by = auth.uid()
    or terminal_user_id = auth.uid()
    or (public.has_any_role(array['gestor', 'admin']::public.app_role[]) and public.can_access_warehouse(warehouse_id))
  );
drop policy if exists scan_events_select on public.scan_events;
create policy scan_events_select on public.scan_events
  for select to authenticated using (public.can_access_movement(movement_id));
drop policy if exists confirmation_attempts_select on public.confirmation_attempts;
create policy confirmation_attempts_select on public.confirmation_attempts
  for select to authenticated using (public.can_access_movement(movement_id));

grant select on public.counter_sessions, public.scan_events, public.confirmation_attempts to authenticated;
revoke insert, update, delete on public.counter_sessions, public.scan_events, public.confirmation_attempts from authenticated, anon;

do $$
declare t text;
begin
  foreach t in array array['counter_sessions', 'scan_events', 'confirmation_attempts'] loop
    execute format('drop trigger if exists block_delete on public.%I', t);
    execute format('create trigger block_delete before delete on public.%I for each row execute function public.tg_block_delete()', t);
  end loop;
end $$;

create or replace function public.tg_counter_updated_at()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;
drop trigger if exists set_timestamps on public.counter_sessions;
create trigger set_timestamps before update on public.counter_sessions
  for each row execute function public.tg_counter_updated_at();

-- Realtime: as duas telas escutam a sessão (cada mudança incrementa "version")
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables
                      where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'counter_sessions') then
    execute 'alter publication supabase_realtime add table public.counter_sessions';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 4) Funções internas
-- ---------------------------------------------------------------------
create or replace function public._counter_touch(p_movement_id uuid, p_event text, p_status text default null)
returns void
language sql security definer
set search_path = public, pg_temp
as $$
  update public.counter_sessions
     set version = version + 1, last_event = p_event, last_event_at = now(),
         status = coalesce(p_status, status)
   where movement_id = p_movement_id;
$$;

-- Trava a ME do balcão para alteração pelo almoxarife que abriu a separação
create or replace function public._counter_lock_for_owner(p_movement_id uuid)
returns public.stock_movements
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_m public.stock_movements;
begin
  if auth.uid() is null or not public.is_active_user() then
    raise exception 'Sessão inválida ou usuário inativo.' using errcode = '42501';
  end if;
  select * into v_m from public.stock_movements where id = p_movement_id for update;
  if v_m.id is null or not public.can_access_warehouse(v_m.warehouse_id) then
    raise exception 'ME não encontrada.' using errcode = 'P0002';
  end if;
  if v_m.entry_channel <> 'balcao' then
    raise exception 'Esta ME não foi aberta no balcão.' using errcode = 'P0001';
  end if;
  if v_m.storekeeper_id <> auth.uid() then
    raise exception 'Somente o almoxarife que abriu a separação (%) pode alterá-la.',
      (select coalesce(full_name, email) from public.profiles where id = v_m.storekeeper_id) using errcode = '42501';
  end if;
  return v_m;
end;
$$;

create or replace function public._counter_new_code()
returns text
language plpgsql volatile
set search_path = public, pg_temp
as $$
declare
  v_code text;
begin
  loop
    v_code := lpad((floor(random() * 1000000))::int::text, 6, '0');
    exit when not exists (select 1 from public.counter_sessions
                           where pairing_code = v_code and status in ('em_separacao', 'aguardando_confirmacao'));
  end loop;
  return v_code;
end;
$$;

revoke all on function public._counter_touch(uuid, text, text) from public, anon, authenticated;
revoke all on function public._counter_lock_for_owner(uuid) from public, anon, authenticated;
revoke all on function public._counter_new_code() from public, anon, authenticated;

-- Confere se o usuário é um tablet (perfil terminal) ativo do estoque e se está livre
create or replace function public._counter_check_terminal(p_terminal uuid, p_warehouse_id uuid, p_except_movement uuid)
returns void
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare
  v_name text;
begin
  select coalesce(p.full_name, p.email) into v_name
    from public.profiles p
    join public.user_roles ur on ur.user_id = p.id and ur.role = 'terminal'
    join public.user_warehouses uw on uw.user_id = p.id and uw.warehouse_id = p_warehouse_id
   where p.id = p_terminal and p.active;
  if v_name is null then
    raise exception 'Tablet inválido para este estoque.' using errcode = '22023';
  end if;
  if exists (select 1 from public.counter_sessions s
              where s.terminal_user_id = p_terminal
                and s.status in ('em_separacao', 'aguardando_confirmacao')
                and s.movement_id is distinct from p_except_movement) then
    raise exception 'O tablet % está ocupado com outra separação. Escolha outro ou aguarde a confirmação.', v_name
      using errcode = 'P0001';
  end if;
end;
$$;
revoke all on function public._counter_check_terminal(uuid, uuid, uuid) from public, anon, authenticated;

-- Cancelamento (por qualquer caminho) encerra a sessão do balcão
create or replace function public.tg_counter_sync_status()
returns trigger
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  if new.status = 'cancelada' and old.status <> 'cancelada' then
    perform public._counter_touch(new.id, 'me_cancelada', 'cancelada');
  end if;
  return null;
end;
$$;
drop trigger if exists counter_sync_status on public.stock_movements;
create trigger counter_sync_status after update of status on public.stock_movements
  for each row execute function public.tg_counter_sync_status();

-- ---------------------------------------------------------------------
-- 5) Abrir separação no balcão
-- payload: id, warehouse_id, contract_id, sector_id, service_front_id, service_order_text,
--          fixed_asset_text, application_location_id, notes, requester_employee_id,
--          terminal_user_id (tablet escolhido) ou reuse_terminal
-- ---------------------------------------------------------------------
create or replace function public.counter_open(p_payload jsonb)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_uid          uuid := auth.uid();
  v_id           uuid;
  v_existing     public.stock_movements;
  v_wh           public.warehouses;
  v_requester    public.employees;
  v_contract_id  uuid;
  v_sector_id    uuid;
  v_front_id     uuid;
  v_appl_id      uuid;
  v_so_text      text;
  v_so_id        uuid;
  v_fa_text      text;
  v_fa_id        uuid;
  v_number       text;
  v_now          timestamptz := now();
  v_code         text;
  v_terminal     uuid;
  v_session      public.counter_sessions;
begin
  if v_uid is null or not public.is_active_user() then
    raise exception 'Sessão inválida ou usuário inativo.' using errcode = '42501';
  end if;
  if not public.has_any_role(array['almoxarife', 'gestor', 'admin']::public.app_role[]) then
    raise exception 'Seu perfil não permite registrar saídas de material.' using errcode = '42501';
  end if;

  begin
    v_id := (p_payload ->> 'id')::uuid;
  exception when others then
    raise exception 'Identificador da movimentação inválido.' using errcode = '22023';
  end;
  if v_id is null then
    raise exception 'Identificador da movimentação é obrigatório.' using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(v_id::text, 0));

  select * into v_existing from public.stock_movements where id = v_id;
  if found then
    if v_existing.created_by <> v_uid then
      raise exception 'Identificador de movimentação já utilizado.' using errcode = '23505';
    end if;
    select * into v_session from public.counter_sessions where movement_id = v_id;
    return jsonb_build_object('id', v_id, 'me_number', v_existing.me_number, 'session_id', v_session.id,
                              'pairing_code', v_session.pairing_code, 'terminal_paired', v_session.terminal_user_id is not null,
                              'created', false);
  end if;

  select * into v_wh from public.warehouses where id = nullif(p_payload ->> 'warehouse_id', '')::uuid;
  if v_wh.id is null then
    raise exception 'Selecione o estoque de origem.' using errcode = '22023';
  end if;
  if not v_wh.active then
    raise exception 'O estoque % está inativo.', v_wh.name using errcode = '22023';
  end if;
  if not public.can_access_warehouse(v_wh.id) then
    raise exception 'Você não tem permissão para operar no estoque %.', v_wh.name using errcode = '42501';
  end if;

  select id into v_contract_id from public.contracts where id = nullif(p_payload ->> 'contract_id', '')::uuid and active;
  if v_contract_id is null then
    raise exception 'Informe um contrato ativo.' using errcode = '22023';
  end if;
  select id into v_sector_id from public.sectors where id = nullif(p_payload ->> 'sector_id', '')::uuid and active;
  if v_sector_id is null then
    raise exception 'Informe um setor ativo.' using errcode = '22023';
  end if;
  if nullif(p_payload ->> 'service_front_id', '') is not null then
    select id into v_front_id from public.service_fronts where id = (p_payload ->> 'service_front_id')::uuid and active;
    if v_front_id is null then
      raise exception 'Frente de serviço/equipamento inválida ou inativa.' using errcode = '22023';
    end if;
  end if;
  if nullif(p_payload ->> 'application_location_id', '') is not null then
    select id into v_appl_id from public.application_locations where id = (p_payload ->> 'application_location_id')::uuid and active;
    if v_appl_id is null then
      raise exception 'Local de aplicação inválido ou inativo.' using errcode = '22023';
    end if;
  end if;
  v_so_text := nullif(btrim(coalesce(p_payload ->> 'service_order_text', '')), '');
  if v_so_text is not null then
    if length(v_so_text) > 40 then
      raise exception 'Ordem de serviço deve ter no máximo 40 caracteres.' using errcode = '22023';
    end if;
    select id into v_so_id from public.service_orders where upper(code) = upper(v_so_text) and active;
  end if;
  v_fa_text := nullif(btrim(coalesce(p_payload ->> 'fixed_asset_text', '')), '');
  if v_fa_text is not null then
    if length(v_fa_text) > 40 then
      raise exception 'Ativo fixo deve ter no máximo 40 caracteres.' using errcode = '22023';
    end if;
    select id into v_fa_id from public.fixed_assets where upper(code) = upper(v_fa_text) and active;
  end if;

  select * into v_requester from public.employees where id = nullif(p_payload ->> 'requester_employee_id', '')::uuid;
  if v_requester.id is null then
    raise exception 'Identifique o funcionário solicitante.' using errcode = '22023';
  end if;
  if not v_requester.active then
    raise exception 'O funcionário % está inativo.', v_requester.full_name using errcode = '22023';
  end if;

  perform set_config('app.source', 'balcao', true);
  perform set_config('app.audit_action', 'me.balcao_aberta', true);
  v_number := public.next_me_number(v_wh.id, v_now);

  insert into public.stock_movements (
    id, me_number, movement_type, movement_at, warehouse_id, contract_id, sector_id,
    service_front_id, service_order_id, service_order_text, fixed_asset_id, fixed_asset_text, requires_sa,
    application_location_id, application_location_text, notes, status, entry_channel,
    requester_employee_id, requester_name, requester_registration, requested_at,
    received_by_employee_id, received_by_name, received_by_registration,
    storekeeper_id, created_by, updated_by, created_at
  ) values (
    v_id, v_number, 'saida', v_now, v_wh.id, v_contract_id, v_sector_id,
    v_front_id, v_so_id, v_so_text, v_fa_id, v_fa_text, v_fa_text is not null,
    v_appl_id, nullif(btrim(coalesce(p_payload ->> 'application_location_text', '')), ''),
    nullif(btrim(coalesce(p_payload ->> 'notes', '')), ''), 'rascunho', 'balcao',
    v_requester.id, v_requester.full_name, v_requester.registration, v_now,
    v_requester.id, v_requester.full_name, v_requester.registration,
    v_uid, v_uid, v_uid, v_now
  );

  -- Tablet escolhido pelo almoxarife (terminal_user_id) ou, se não informado e
  -- reuse_terminal = true, o tablet da separação anterior deste almoxarife (se livre)
  if nullif(p_payload ->> 'terminal_user_id', '') is not null then
    v_terminal := (p_payload ->> 'terminal_user_id')::uuid;
    perform public._counter_check_terminal(v_terminal, v_wh.id, null);
  elsif coalesce((p_payload ->> 'reuse_terminal')::boolean, false) then
    select s.terminal_user_id into v_terminal
      from public.counter_sessions s
     where s.opened_by = v_uid and s.warehouse_id = v_wh.id and s.terminal_user_id is not null
     order by s.created_at desc limit 1;
    if v_terminal is not null and exists (
         select 1 from public.counter_sessions s
          where s.terminal_user_id = v_terminal and s.status in ('em_separacao', 'aguardando_confirmacao')) then
      v_terminal := null; -- tablet ocupado em outra separação
    end if;
  end if;

  v_code := public._counter_new_code();
  insert into public.counter_sessions (movement_id, warehouse_id, opened_by, pairing_code, pairing_expires_at,
                                       terminal_user_id, paired_at, last_event)
  values (v_id, v_wh.id, v_uid, v_code, v_now + interval '30 minutes',
          v_terminal, case when v_terminal is not null then v_now end, 'me_aberta')
  returning * into v_session;

  perform public.write_audit('me.balcao_aberta', 'stock_movements', v_id::text, v_id, v_wh.id, null,
    jsonb_build_object('me_number', v_number, 'solicitante', v_requester.full_name, 'estoque', v_wh.name,
                       'tablet_reaproveitado', v_terminal is not null), null);

  return jsonb_build_object('id', v_id, 'me_number', v_number, 'session_id', v_session.id,
                            'pairing_code', v_code, 'terminal_paired', v_terminal is not null, 'created', true);
end;
$$;

-- ---------------------------------------------------------------------
-- 6) Leitura / inclusão de material
-- payload: movement_id, scan_id (uuid único por leitura), code OU material_id,
--          quantity (padrão 1), on_duplicate ('avisar' | 'somar' | 'nova_linha')
-- Resultado: incluido | somado | ja_incluido | nao_encontrado | invalido | inativo | quantidade_invalida
-- ---------------------------------------------------------------------
create or replace function public.counter_add(p_payload jsonb)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  s           public.app_settings := public.get_settings();
  v_mid       uuid;
  v_scan      uuid;
  v_prev      jsonb;
  v_m         public.stock_movements;
  v_code      text := nullif(btrim(coalesce(p_payload ->> 'code', '')), '');
  v_mat_id    uuid;
  v_mat       record;
  v_qty       numeric;
  v_mode      text := coalesce(nullif(p_payload ->> 'on_duplicate', ''), 'avisar');
  v_item      public.stock_movement_items;
  v_resp      jsonb;
  v_result    text;
  v_line      int;
  v_manual    boolean := v_code is null;
begin
  begin
    v_mid := (p_payload ->> 'movement_id')::uuid;
    v_scan := (p_payload ->> 'scan_id')::uuid;
    v_mat_id := nullif(p_payload ->> 'material_id', '')::uuid;
  exception when others then
    raise exception 'Leitura inválida.' using errcode = '22023';
  end;
  if v_mid is null or v_scan is null then
    raise exception 'ME e identificador da leitura são obrigatórios.' using errcode = '22023';
  end if;
  if v_mode not in ('avisar', 'somar', 'nova_linha') then
    raise exception 'Opção de leitura repetida inválida.' using errcode = '22023';
  end if;

  v_m := public._counter_lock_for_owner(v_mid);
  -- inicializa o registro do material (fica nulo quando o código não é encontrado)
  select m.*, null::text as account_code, null::text as account_name into v_mat from public.materials m where false;

  -- Mesma leitura reenviada (rede instável): devolve a resposta original
  select response into v_prev from public.scan_events where scan_id = v_scan;
  if v_prev is not null then
    return v_prev || jsonb_build_object('repetida', true);
  end if;

  if v_m.status <> 'rascunho' then
    raise exception 'Separação finalizada: novas leituras estão bloqueadas nesta ME.' using errcode = 'P0001';
  end if;

  begin
    v_qty := coalesce(nullif(p_payload ->> 'quantity', '')::numeric, 1);
  exception when others then
    v_qty := null;
  end;

  -- Localiza o material (mesmas regras da leitura por câmera)
  if v_code is not null then
    if position('/' in v_code) > 0 then
      v_code := regexp_replace(v_code, '^.*/', '');
    end if;
    if v_code !~ '^[A-Za-z0-9._:/-]{1,80}$' then
      v_result := 'invalido';
    else
      select m.id into v_mat_id
        from public.materials m
       where m.qr_code = v_code
          or m.id in (select q.material_id from public.material_qr_codes q where q.code = v_code and q.active)
          or upper(m.code) = upper(v_code)
       order by (m.qr_code = v_code) desc
       limit 1;
      if v_mat_id is null then
        v_result := 'nao_encontrado';
      end if;
    end if;
  end if;

  if v_result is null then
    select m.*, a.code as account_code, a.name as account_name into v_mat
      from public.materials m left join public.accounts a on a.id = m.account_id
     where m.id = v_mat_id;
    if v_mat.id is null then
      v_result := 'nao_encontrado';
    elsif not v_mat.active then
      v_result := 'inativo';
    elsif v_qty is null or v_qty <= 0 or v_qty > 999999 then
      v_result := 'quantidade_invalida';
    end if;
  end if;

  if v_result is null then
    select * into v_item from public.stock_movement_items
     where movement_id = v_mid and material_id = v_mat.id order by line_number limit 1;

    if v_item.id is not null and (v_mode = 'avisar' or (v_mode = 'nova_linha' and not s.allow_duplicate_material_lines)) then
      v_result := 'ja_incluido';
    elsif v_item.id is not null and v_mode = 'somar' then
      update public.stock_movement_items
         set quantity_requested = quantity_requested + v_qty,
             quantity_delivered = quantity_delivered + v_qty,
             updated_by = auth.uid()
       where id = v_item.id
      returning * into v_item;
      v_result := 'somado';
    else
      if (select count(*) from public.stock_movement_items where movement_id = v_mid) >= 200 then
        raise exception 'Limite de 200 itens por ME.' using errcode = '22023';
      end if;
      select coalesce(max(line_number), 0) + 1 into v_line from public.stock_movement_items where movement_id = v_mid;
      insert into public.stock_movement_items (
        movement_id, line_number, material_id, material_code, material_reference, material_name,
        unit, location, account_code, account_name, quantity_requested, quantity_delivered,
        entry_method, scanned_code, created_by, updated_by
      ) values (
        v_mid, v_line, v_mat.id, v_mat.code, v_mat.reference, v_mat.name,
        v_mat.unit, v_mat.location, v_mat.account_code, v_mat.account_name, v_qty, v_qty,
        case when v_manual then 'pesquisa_manual' else 'qr_code' end::public.item_entry_method,
        left(v_code, 80), auth.uid(), auth.uid()
      ) returning * into v_item;
      v_result := 'incluido';
    end if;
  end if;

  v_resp := jsonb_build_object(
    'result', v_result,
    'code', v_code,
    'item_id', v_item.id,
    'material_id', coalesce(v_mat.id, v_mat_id),
    'material_code', coalesce(v_item.material_code, v_mat.code),
    'material_name', coalesce(v_item.material_name, v_mat.name),
    'unit', coalesce(v_item.unit, v_mat.unit),
    'quantity_requested', v_item.quantity_requested,
    'quantity_delivered', v_item.quantity_delivered
  );

  insert into public.scan_events (movement_id, scan_id, scanned_code, material_id, item_id, quantity, result, response)
  values (v_mid, v_scan, left(coalesce(v_code, p_payload ->> 'code'), 120), v_mat.id, v_item.id, v_qty, v_result, v_resp);

  if v_result in ('incluido', 'somado') then
    perform public._counter_touch(v_mid, case when v_result = 'incluido' then 'item_incluido' else 'quantidade_alterada' end);
  end if;
  return v_resp;
end;
$$;

-- Altera quantidades de um item durante a separação
create or replace function public.counter_set_quantity(p_item_id uuid, p_requested numeric, p_delivered numeric)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  s       public.app_settings := public.get_settings();
  v_item  public.stock_movement_items;
  v_m     public.stock_movements;
begin
  select * into v_item from public.stock_movement_items where id = p_item_id;
  if v_item.id is null then
    raise exception 'Item não encontrado.' using errcode = 'P0002';
  end if;
  v_m := public._counter_lock_for_owner(v_item.movement_id);
  if v_m.status <> 'rascunho' then
    raise exception 'Separação finalizada: os itens estão bloqueados.' using errcode = 'P0001';
  end if;
  if p_requested is null or p_requested <= 0 or p_delivered is null or p_delivered <= 0 then
    raise exception 'Quantidade inválida: informe valores maiores que zero.' using errcode = '22023';
  end if;
  if p_requested > 999999 or p_delivered > 999999 then
    raise exception 'Quantidade acima do limite permitido.' using errcode = '22023';
  end if;
  if p_delivered > p_requested and not s.allow_delivered_above_requested then
    raise exception 'A quantidade atendida não pode ser maior que a solicitada.' using errcode = '22023';
  end if;
  update public.stock_movement_items
     set quantity_requested = p_requested, quantity_delivered = p_delivered, updated_by = auth.uid()
   where id = p_item_id
  returning * into v_item;
  perform public._counter_touch(v_item.movement_id, 'quantidade_alterada');
  return jsonb_build_object('item_id', v_item.id, 'quantity_requested', v_item.quantity_requested,
                            'quantity_delivered', v_item.quantity_delivered);
end;
$$;

-- Remove um item durante a separação
create or replace function public.counter_remove_item(p_item_id uuid)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_item  public.stock_movement_items;
  v_m     public.stock_movements;
begin
  select * into v_item from public.stock_movement_items where id = p_item_id;
  if v_item.id is null then
    raise exception 'Item não encontrado.' using errcode = 'P0002';
  end if;
  v_m := public._counter_lock_for_owner(v_item.movement_id);
  if v_m.status <> 'rascunho' then
    raise exception 'Separação finalizada: os itens estão bloqueados.' using errcode = 'P0001';
  end if;
  delete from public.stock_movement_items where id = p_item_id;
  perform public._counter_touch(v_item.movement_id, 'item_removido');
  return jsonb_build_object('item_id', p_item_id, 'material_name', v_item.material_name);
end;
$$;

-- FINALIZAR SEPARAÇÃO: bloqueia leituras e libera a confirmação no tablet
create or replace function public.counter_finish(p_movement_id uuid)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_m public.stock_movements;
begin
  v_m := public._counter_lock_for_owner(p_movement_id);
  if v_m.status <> 'rascunho' then
    raise exception 'Esta separação já foi finalizada (status: %).', v_m.status using errcode = 'P0001';
  end if;
  if not exists (select 1 from public.stock_movement_items where movement_id = p_movement_id) then
    raise exception 'Inclua pelo menos um material antes de finalizar a separação.' using errcode = '22023';
  end if;
  perform set_config('app.audit_action', 'me.separacao_finalizada', true);
  update public.stock_movements
     set status = 'aguardando_assinatura', separation_finished_at = now(), updated_by = auth.uid()
   where id = p_movement_id;
  perform public._counter_touch(p_movement_id, 'separacao_finalizada', 'aguardando_confirmacao');
  return jsonb_build_object('id', p_movement_id, 'status', 'aguardando_assinatura');
end;
$$;

-- Reabre a separação (antes da confirmação), por exemplo se o solicitante apontar divergência
create or replace function public.counter_reopen(p_movement_id uuid, p_reason text default null)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_m public.stock_movements;
begin
  v_m := public._counter_lock_for_owner(p_movement_id);
  if v_m.status <> 'aguardando_assinatura' then
    raise exception 'Somente separações aguardando confirmação podem ser reabertas (status: %).', v_m.status
      using errcode = 'P0001';
  end if;
  perform set_config('app.audit_action', 'me.separacao_reaberta', true);
  perform set_config('app.justification', coalesce(nullif(btrim(coalesce(p_reason, '')), ''), 'Separação reaberta no balcão'), true);
  update public.stock_movements
     set status = 'rascunho', separation_finished_at = null, updated_by = auth.uid()
   where id = p_movement_id;
  perform public._counter_touch(p_movement_id, 'separacao_reaberta', 'em_separacao');
  return jsonb_build_object('id', p_movement_id, 'status', 'rascunho');
end;
$$;

-- Novo código de pareamento (o anterior expirou)
create or replace function public.counter_new_pairing_code(p_movement_id uuid)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_m    public.stock_movements;
  v_code text;
begin
  v_m := public._counter_lock_for_owner(p_movement_id);
  if v_m.status not in ('rascunho', 'aguardando_assinatura') then
    raise exception 'A separação já foi encerrada.' using errcode = 'P0001';
  end if;
  v_code := public._counter_new_code();
  update public.counter_sessions
     set pairing_code = v_code, pairing_expires_at = now() + interval '30 minutes'
   where movement_id = p_movement_id;
  perform public._counter_touch(p_movement_id, 'codigo_renovado');
  return jsonb_build_object('pairing_code', v_code);
end;
$$;

-- ---------------------------------------------------------------------
-- 7) Tablet do solicitante (perfil terminal)
-- ---------------------------------------------------------------------
create or replace function public.counter_pair(p_code text)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_s public.counter_sessions;
begin
  if auth.uid() is null or not public.is_active_user() or not public.has_role('terminal') then
    raise exception 'Somente o tablet do solicitante (perfil Terminal) pode ser pareado.' using errcode = '42501';
  end if;
  select * into v_s from public.counter_sessions
   where pairing_code = btrim(coalesce(p_code, '')) and status in ('em_separacao', 'aguardando_confirmacao')
   for update;
  if v_s.id is null or v_s.pairing_expires_at < now() then
    raise exception 'Código inválido ou expirado. Peça ao almoxarife um código novo.' using errcode = 'P0002';
  end if;
  if not public.is_terminal_of_warehouse(v_s.warehouse_id) then
    raise exception 'Este tablet não está liberado para o estoque desta ME.' using errcode = '42501';
  end if;
  if v_s.terminal_user_id is not null and v_s.terminal_user_id <> auth.uid() then
    raise exception 'Esta ME já está pareada com outro tablet.' using errcode = 'P0001';
  end if;

  -- Um tablet acompanha uma ME por vez
  update public.counter_sessions
     set terminal_user_id = null, paired_at = null, version = version + 1, last_event = 'terminal_desconectado', last_event_at = now()
   where terminal_user_id = auth.uid() and id <> v_s.id and status in ('em_separacao', 'aguardando_confirmacao');

  update public.counter_sessions
     set terminal_user_id = auth.uid(), paired_at = now(), version = version + 1, last_event = 'terminal_pareado', last_event_at = now()
   where id = v_s.id;

  perform public.write_audit('balcao.terminal_pareado', 'counter_sessions', v_s.id::text, v_s.movement_id, v_s.warehouse_id,
                             null, jsonb_build_object('terminal', auth.uid()), null);
  return jsonb_build_object('session_id', v_s.id, 'movement_id', v_s.movement_id);
end;
$$;

-- Fotografia da sessão para as duas telas (almoxarife dono, tablet pareado, gestor/admin)
create or replace function public.counter_snapshot(p_movement_id uuid default null)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare
  v_s public.counter_sessions;
  v_m public.stock_movements;
begin
  if auth.uid() is null or not public.is_active_user() then
    raise exception 'Sessão inválida ou usuário inativo.' using errcode = '42501';
  end if;

  if p_movement_id is null then
    -- tablet: ME ativa pareada (ou a última confirmada/cancelada nos últimos 2 minutos)
    select * into v_s from public.counter_sessions
     where terminal_user_id = auth.uid()
       and (status in ('em_separacao', 'aguardando_confirmacao') or last_event_at > now() - interval '2 minutes')
     order by (status in ('em_separacao', 'aguardando_confirmacao')) desc, last_event_at desc
     limit 1;
    if v_s.id is null then
      return null;
    end if;
  else
    select * into v_s from public.counter_sessions where movement_id = p_movement_id;
    if v_s.id is null then
      raise exception 'Separação não encontrada.' using errcode = 'P0002';
    end if;
    if not (v_s.opened_by = auth.uid() or v_s.terminal_user_id = auth.uid()
            or (public.has_any_role(array['gestor', 'admin']::public.app_role[]) and public.can_access_warehouse(v_s.warehouse_id))) then
      raise exception 'Separação não encontrada.' using errcode = 'P0002';
    end if;
  end if;

  select * into v_m from public.stock_movements where id = v_s.movement_id;

  return jsonb_build_object(
    'session', jsonb_build_object(
      'id', v_s.id, 'status', v_s.status, 'version', v_s.version, 'last_event', v_s.last_event,
      'last_event_at', v_s.last_event_at, 'terminal_paired', v_s.terminal_user_id is not null,
      'paired_at', v_s.paired_at,
      -- o código só é mostrado ao almoxarife/gestor
      'pairing_code', case when v_s.terminal_user_id = auth.uid() then null else v_s.pairing_code end,
      'pairing_expires_at', v_s.pairing_expires_at,
      'terminal_name', (select coalesce(full_name, email) from public.profiles where id = v_s.terminal_user_id)
    ),
    'movement', jsonb_build_object(
      'id', v_m.id, 'me_number', v_m.me_number, 'status', v_m.status,
      'warehouse_name', (select name from public.warehouses where id = v_m.warehouse_id),
      'warehouse_code', (select code from public.warehouses where id = v_m.warehouse_id),
      'requester_name', v_m.requester_name, 'requester_registration', v_m.requester_registration,
      'storekeeper_name', (select coalesce(full_name, email) from public.profiles where id = v_m.storekeeper_id),
      'movement_at', v_m.movement_at, 'separation_finished_at', v_m.separation_finished_at,
      'confirmed_at', v_m.confirmed_at, 'cancel_reason', v_m.cancel_reason,
      'item_count', v_m.item_count, 'total_delivered', v_m.total_delivered,
      'fixed_asset', v_m.fixed_asset_text
    ),
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', i.id, 'line_number', i.line_number, 'material_code', i.material_code,
               'material_name', i.material_name, 'unit', i.unit,
               'quantity_requested', i.quantity_requested, 'quantity_delivered', i.quantity_delivered,
               'created_at', i.created_at, 'updated_at', i.updated_at) order by i.line_number)
        from public.stock_movement_items i where i.movement_id = v_m.id), '[]'::jsonb)
  );
end;
$$;

-- Registra tentativa de confirmação que não deu certo (cancelada, falha, erro)
create or replace function public.counter_register_attempt(p_movement_id uuid, p_method text, p_result text, p_detail jsonb default null)
returns uuid
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_s  public.counter_sessions;
  v_id uuid;
begin
  select * into v_s from public.counter_sessions where movement_id = p_movement_id;
  if v_s.id is null or v_s.terminal_user_id is distinct from auth.uid() then
    raise exception 'Tablet não pareado com esta ME.' using errcode = '42501';
  end if;
  if p_method not in ('assinatura', 'facial') or p_result not in ('falha', 'cancelada', 'erro') then
    -- "sucesso" nunca vem do navegador: a assinatura é validada em counter_confirm
    -- e o facial será registrado pelo servidor (Edge Function) com a chave de serviço.
    raise exception 'Tentativa inválida.' using errcode = '22023';
  end if;
  insert into public.confirmation_attempts (movement_id, employee_id, method, result, detail)
  values (p_movement_id, (select requester_employee_id from public.stock_movements where id = p_movement_id),
          p_method, p_result, p_detail)
  returning id into v_id;
  perform public._counter_touch(p_movement_id, 'confirmacao_' || p_result);
  return v_id;
end;
$$;

-- CONFIRMAR ME (tablet pareado). method = 'assinatura' (signature_path) ou 'facial' (verification_id)
create or replace function public.counter_confirm(p_movement_id uuid, p_payload jsonb)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  s          public.app_settings := public.get_settings();
  v_m        public.stock_movements;
  v_s        public.counter_sessions;
  v_wh       public.warehouses;
  v_method   text := coalesce(p_payload ->> 'method', '');
  v_path     text;
  v_obj      record;
  v_att      public.confirmation_attempts;
  v_year     int;
  v_status   public.movement_status;
  v_now      timestamptz := now();
  v_photo    text := nullif(btrim(coalesce(p_payload ->> 'photo_path', '')), '');
  v_no_photo text := nullif(btrim(coalesce(p_payload ->> 'photo_skipped_reason', '')), '');
  v_pobj     record;
begin
  if auth.uid() is null or not public.is_active_user() then
    raise exception 'Sessão inválida ou usuário inativo.' using errcode = '42501';
  end if;

  select * into v_m from public.stock_movements where id = p_movement_id for update;
  select * into v_s from public.counter_sessions where movement_id = p_movement_id for update;
  if v_m.id is null or v_s.id is null or v_s.terminal_user_id is distinct from auth.uid() then
    raise exception 'Tablet não pareado com esta ME.' using errcode = '42501';
  end if;
  if v_m.confirmed_at is not null or v_s.status = 'confirmada' then
    raise exception 'A ME % já foi confirmada.', v_m.me_number using errcode = 'P0001';
  end if;
  if v_m.status = 'rascunho' then
    raise exception 'A separação ainda não foi finalizada pelo almoxarife.' using errcode = 'P0001';
  end if;
  if v_m.status <> 'aguardando_assinatura' then
    raise exception 'A ME % não pode ser confirmada (status: %).', v_m.me_number, v_m.status using errcode = 'P0001';
  end if;

  select * into v_wh from public.warehouses where id = v_m.warehouse_id;
  v_year := extract(year from (v_m.movement_at at time zone s.timezone))::int;

  -- Foto do solicitante (evidência da retirada; visível só para gestor/admin)
  if v_photo is not null then
    if v_photo not like v_wh.code || '/' || v_year::text || '/' || v_m.id::text || '/%' then
      raise exception 'Foto inválida para esta ME.' using errcode = '22023';
    end if;
    select o.name, nullif(o.metadata ->> 'size', '')::int as size_bytes,
           coalesce(o.metadata ->> 'mimetype', 'image/jpeg') as mime_type
      into v_pobj from storage.objects o where o.bucket_id = 'fotos-retirada' and o.name = v_photo;
    if v_pobj.name is null then
      raise exception 'Foto do solicitante não encontrada. Tire a foto novamente.' using errcode = '22023';
    end if;
  elsif v_no_photo is null and v_method = 'assinatura' then
    raise exception 'Tire a foto do solicitante antes de confirmar.' using errcode = '22023';
  end if;

  if v_method = 'assinatura' then
    v_path := nullif(btrim(coalesce(p_payload ->> 'signature_path', '')), '');
    if v_path is null or v_path not like v_wh.code || '/' || v_year::text || '/' || v_m.id::text || '/%' then
      raise exception 'Assinatura inválida para esta ME.' using errcode = '22023';
    end if;
    select o.name, nullif(o.metadata ->> 'size', '')::int as size_bytes,
           coalesce(o.metadata ->> 'mimetype', 'image/png') as mime_type
      into v_obj from storage.objects o where o.bucket_id = 'assinaturas' and o.name = v_path;
    if v_obj.name is null then
      raise exception 'Arquivo da assinatura não encontrado. Tente assinar novamente.' using errcode = '22023';
    end if;
    insert into public.confirmation_attempts (movement_id, employee_id, method, provider, result, consumed_at, detail)
    values (v_m.id, v_m.requester_employee_id, 'assinatura', 'assinatura_digital', 'sucesso', v_now,
            jsonb_build_object('storage_path', v_path, 'foto', v_photo, 'sem_foto_motivo', v_no_photo))
    returning * into v_att;
    insert into public.signatures (movement_id, employee_id, signer_name, signer_registration, bucket, storage_path,
                                   mime_type, size_bytes, signed_at, uploaded_by, is_current)
    values (v_m.id, v_m.requester_employee_id, v_m.requester_name, v_m.requester_registration, 'assinaturas', v_path,
            case when v_obj.mime_type in ('image/png', 'image/jpeg', 'image/webp') then v_obj.mime_type else 'image/png' end,
            v_obj.size_bytes, v_now, auth.uid(), true);
  elsif v_method = 'facial' then
    -- A verificação facial é gravada pelo servidor (Edge Function); aqui só é consumida, uma única vez.
    select * into v_att from public.confirmation_attempts
     where id = nullif(p_payload ->> 'verification_id', '')::uuid
       and movement_id = v_m.id and method = 'facial' and result = 'sucesso'
       and consumed_at is null and created_at > v_now - interval '5 minutes'
     for update;
    if v_att.id is null then
      raise exception 'Validação facial não encontrada, expirada ou já utilizada. Faça a validação novamente.' using errcode = '22023';
    end if;
    update public.confirmation_attempts set consumed_at = v_now where id = v_att.id;
  else
    raise exception 'Método de confirmação inválido.' using errcode = '22023';
  end if;

  if v_photo is not null then
    insert into public.movement_photos (movement_id, employee_id, bucket, storage_path, kind, mime_type, size_bytes, taken_at, uploaded_by)
    values (v_m.id, v_m.requester_employee_id, 'fotos-retirada', v_photo, 'confirmacao_balcao',
            case when v_pobj.mime_type in ('image/jpeg', 'image/webp', 'image/png') then v_pobj.mime_type else 'image/jpeg' end,
            v_pobj.size_bytes, v_now, auth.uid())
    on conflict (storage_path) do nothing;
  end if;

  v_status := case when s.require_approval then 'aguardando_aprovacao'
                   when v_m.requires_sa then 'aguardando_sa'
                   else 'sa_informada' end;

  perform set_config('app.audit_action', 'me.confirmada', true);
  perform set_config('app.source', 'balcao', true);
  perform set_config('app.justification', 'Confirmada pelo solicitante (' || v_method || ')', true);
  update public.stock_movements
     set status = v_status, confirmed_at = v_now, confirmation_method = v_method, received_at = v_now,
         updated_by = auth.uid()
   where id = v_m.id;
  perform public._counter_touch(v_m.id, 'me_confirmada', 'confirmada');

  perform public.write_audit('me.confirmada', 'stock_movements', v_m.id::text, v_m.id, v_m.warehouse_id, null,
    jsonb_build_object('me_number', v_m.me_number, 'solicitante', v_m.requester_name, 'metodo', v_method,
                       'tentativa', v_att.id, 'itens', v_m.item_count, 'total_atendido', v_m.total_delivered,
                       'almoxarife', v_m.storekeeper_id, 'status', v_status,
                       'foto', v_photo is not null, 'sem_foto_motivo', v_no_photo), null);

  return jsonb_build_object('id', v_m.id, 'me_number', v_m.me_number, 'status', v_status);
end;
$$;

-- Separações em andamento do usuário (para retomar)
create or replace function public.counter_my_open()
returns jsonb
language sql stable security definer
set search_path = public, pg_temp
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'movement_id', m.id, 'me_number', m.me_number, 'status', m.status, 'requester_name', m.requester_name,
           'item_count', m.item_count, 'created_at', m.created_at, 'terminal_paired', s.terminal_user_id is not null,
           'warehouse_name', w.name) order by m.created_at desc), '[]'::jsonb)
    from public.counter_sessions s
    join public.stock_movements m on m.id = s.movement_id
    join public.warehouses w on w.id = m.warehouse_id
   where s.opened_by = auth.uid() and s.status in ('em_separacao', 'aguardando_confirmacao');
$$;

-- ---------------------------------------------------------------------
-- 7b) Tablets do estoque (escolha do tablet sem digitar código)
-- ---------------------------------------------------------------------
create or replace function public.counter_list_terminals(p_warehouse_id uuid)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null or not public.is_active_user()
     or not public.has_any_role(array['almoxarife', 'gestor', 'admin']::public.app_role[])
     or not public.can_access_warehouse(p_warehouse_id) then
    raise exception 'Sem permissão para este estoque.' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'user_id', p.id,
             'name', coalesce(p.full_name, p.email),
             'busy_me_number', (select m.me_number from public.counter_sessions s join public.stock_movements m on m.id = s.movement_id
                                 where s.terminal_user_id = p.id and s.status in ('em_separacao', 'aguardando_confirmacao')
                                 order by s.created_at desc limit 1),
             'last_used_by_me', (select max(s.created_at) from public.counter_sessions s
                                  where s.terminal_user_id = p.id and s.opened_by = auth.uid())
           ) order by coalesce(p.full_name, p.email))
      from public.profiles p
      join public.user_roles ur on ur.user_id = p.id and ur.role = 'terminal'
      join public.user_warehouses uw on uw.user_id = p.id and uw.warehouse_id = p_warehouse_id
     where p.active), '[]'::jsonb);
end;
$$;

-- Liga (ou troca) o tablet de uma separação em andamento
create or replace function public.counter_set_terminal(p_movement_id uuid, p_terminal_user_id uuid)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_m public.stock_movements;
begin
  v_m := public._counter_lock_for_owner(p_movement_id);
  if v_m.status not in ('rascunho', 'aguardando_assinatura') then
    raise exception 'A separação já foi encerrada.' using errcode = 'P0001';
  end if;
  if p_terminal_user_id is not null then
    perform public._counter_check_terminal(p_terminal_user_id, v_m.warehouse_id, p_movement_id);
  end if;
  update public.counter_sessions
     set terminal_user_id = p_terminal_user_id,
         paired_at = case when p_terminal_user_id is null then null else now() end,
         version = version + 1,
         last_event = case when p_terminal_user_id is null then 'terminal_desconectado' else 'terminal_pareado' end,
         last_event_at = now()
   where movement_id = p_movement_id;
  perform public.write_audit('balcao.terminal_pareado', 'counter_sessions', p_movement_id::text, p_movement_id, v_m.warehouse_id,
                             null, jsonb_build_object('terminal', p_terminal_user_id, 'escolhido_pelo_almoxarife', true), null);
  return jsonb_build_object('movement_id', p_movement_id, 'terminal_user_id', p_terminal_user_id);
end;
$$;

-- ---------------------------------------------------------------------
-- 8) Assinatura enviada pelo tablet pareado (somente na pasta da ME pareada)
-- ---------------------------------------------------------------------
create or replace function public.counter_terminal_can_upload(p_name text)
returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
      from public.counter_sessions s
      join public.warehouses w on w.id = s.warehouse_id
     where s.terminal_user_id = auth.uid()
       and s.status = 'aguardando_confirmacao'
       and w.code = split_part(p_name, '/', 1)
       and s.movement_id::text = split_part(p_name, '/', 3)
  );
$$;
grant execute on function public.counter_terminal_can_upload(text) to authenticated;

drop policy if exists "assinaturas: envio pelo tablet do balcão" on storage.objects;
create policy "assinaturas: envio pelo tablet do balcão"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'assinaturas'
    and name ~* '\.(png|jpe?g|webp)$'
    and public.counter_terminal_can_upload(name)
  );


-- ---------------------------------------------------------------------
-- 8c) Foto do solicitante na confirmação (evidência; só gestor/admin veem)
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('fotos-retirada', 'fotos-retirada', false, 2097152, array['image/jpeg', 'image/webp', 'image/png'])
on conflict (id) do nothing;

create table if not exists public.movement_photos (
  id            uuid primary key default gen_random_uuid(),
  movement_id   uuid not null references public.stock_movements (id),
  employee_id   uuid references public.employees (id),
  bucket        text not null default 'fotos-retirada',
  storage_path  text not null unique,
  kind          text not null default 'confirmacao_balcao',
  mime_type     text,
  size_bytes    integer,
  taken_at      timestamptz not null default now(),
  uploaded_by   uuid references public.profiles (id) default auth.uid(),
  created_at    timestamptz not null default now()
);
create index if not exists movement_photos_movement_idx on public.movement_photos (movement_id);
alter table public.movement_photos enable row level security;
drop policy if exists movement_photos_select on public.movement_photos;
create policy movement_photos_select on public.movement_photos
  for select to authenticated using (
    public.has_any_role(array['gestor', 'admin']::public.app_role[]) and public.can_access_movement(movement_id)
  );
grant select on public.movement_photos to authenticated;
revoke insert, update, delete on public.movement_photos from authenticated, anon;
drop trigger if exists block_delete on public.movement_photos;
create trigger block_delete before delete on public.movement_photos for each row execute function public.tg_block_delete();

drop policy if exists "fotos-retirada: leitura por gestor/admin" on storage.objects;
create policy "fotos-retirada: leitura por gestor/admin"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'fotos-retirada'
    and public.has_any_role(array['gestor', 'admin']::public.app_role[])
    and public.can_access_warehouse_code((storage.foldername(name))[1])
  );
drop policy if exists "fotos-retirada: envio pelo tablet do balcão" on storage.objects;
create policy "fotos-retirada: envio pelo tablet do balcão"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'fotos-retirada'
    and name ~* '\.(jpe?g|webp|png)$'
    and public.counter_terminal_can_upload(name)
  );

-- ---------------------------------------------------------------------
-- 8b) Almoxarife pode cancelar uma separação em andamento (com justificativa)
-- ---------------------------------------------------------------------
create or replace function public.cancel_movement(p_id uuid, p_reason text)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_m       public.stock_movements;
  v_reason  text := nullif(btrim(coalesce(p_reason, '')), '');
  v_manager boolean := public.has_any_role(array['gestor', 'admin']::public.app_role[]);
  v_storekeeper boolean := public.has_role('almoxarife');
begin
  -- Gestor/admin: cancelam em qualquer status.
  -- Almoxarife: somente devolução/erro ANTES do lançamento no ERP
  -- (Em separação/Aguardando confirmação no balcão, Aguardando SA, Aguardando aprovação ou,
  --  em ME sem ativo, Aguardando baixa no ERP),
  -- no estoque autorizado.
  if not v_manager and not v_storekeeper then
    raise exception 'Seu perfil não permite cancelar uma ME.' using errcode = '42501';
  end if;
  if v_reason is null or length(v_reason) < 5 then
    raise exception 'Informe a justificativa do cancelamento (mínimo 5 caracteres).' using errcode = '22023';
  end if;

  select * into v_m from public.stock_movements where id = p_id for update;
  if v_m.id is null or not public.can_access_warehouse(v_m.warehouse_id) then
    raise exception 'ME não encontrada.' using errcode = 'P0002';
  end if;
  if v_m.status = 'cancelada' then
    raise exception 'A ME % já está cancelada.', v_m.me_number using errcode = 'P0001';
  end if;
  if not v_manager
     and v_m.status not in ('rascunho', 'aguardando_assinatura', 'aguardando_sa', 'aguardando_aprovacao')
     and not (v_m.status = 'sa_informada' and not v_m.requires_sa) then
    raise exception 'A ME % já tem SA lançada no ERP. Somente gestor ou administrador pode cancelá-la.', v_m.me_number
      using errcode = '42501';
  end if;

  perform set_config('app.audit_action', 'me.cancelada', true);
  perform set_config('app.justification', v_reason, true);
  if v_m.status = 'concluida' then
    perform set_config('app.correction', 'on', true);
  end if;

  update public.stock_movements
     set status = 'cancelada', cancelled_at = now(), cancelled_by = auth.uid(), cancel_reason = v_reason
   where id = p_id;

  return jsonb_build_object('id', p_id, 'status', 'cancelada');
end;
$$;

-- ---------------------------------------------------------------------
-- 9) Permissões
-- ---------------------------------------------------------------------
revoke all on function public.counter_open(jsonb) from public, anon;
revoke all on function public.counter_add(jsonb) from public, anon;
revoke all on function public.counter_set_quantity(uuid, numeric, numeric) from public, anon;
revoke all on function public.counter_remove_item(uuid) from public, anon;
revoke all on function public.counter_finish(uuid) from public, anon;
revoke all on function public.counter_reopen(uuid, text) from public, anon;
revoke all on function public.counter_new_pairing_code(uuid) from public, anon;
revoke all on function public.counter_pair(text) from public, anon;
revoke all on function public.counter_snapshot(uuid) from public, anon;
revoke all on function public.counter_register_attempt(uuid, text, text, jsonb) from public, anon;
revoke all on function public.counter_confirm(uuid, jsonb) from public, anon;
revoke all on function public.counter_my_open() from public, anon;
grant execute on function public.counter_open(jsonb) to authenticated;
grant execute on function public.counter_add(jsonb) to authenticated;
grant execute on function public.counter_set_quantity(uuid, numeric, numeric) to authenticated;
grant execute on function public.counter_remove_item(uuid) to authenticated;
grant execute on function public.counter_finish(uuid) to authenticated;
grant execute on function public.counter_reopen(uuid, text) to authenticated;
grant execute on function public.counter_new_pairing_code(uuid) to authenticated;
grant execute on function public.counter_pair(text) to authenticated;
grant execute on function public.counter_snapshot(uuid) to authenticated;
grant execute on function public.counter_register_attempt(uuid, text, text, jsonb) to authenticated;
grant execute on function public.counter_confirm(uuid, jsonb) to authenticated;
grant execute on function public.counter_my_open() to authenticated;
grant execute on function public.is_terminal_of_warehouse(uuid) to authenticated;
revoke all on function public.counter_list_terminals(uuid) from public, anon;
revoke all on function public.counter_set_terminal(uuid, uuid) from public, anon;
grant execute on function public.counter_list_terminals(uuid) to authenticated;
grant execute on function public.counter_set_terminal(uuid, uuid) to authenticated;


-- >>>>>>>>>> 07c_retirada_repetida.sql
-- Alerta de retirada repetida por ativo fixo (mesmo conteúdo do 18_retirada_repetida_ativo.sql)
create or replace function public.repeat_asset_withdrawals(p_filters jsonb default '{}'::jsonb, p_days int default 7)
returns jsonb
language plpgsql stable security invoker
set search_path = public, pg_temp
as $$
declare
  v_tz     text := (public.get_settings()).timezone;
  v_result jsonb;
begin
  if not public.is_active_user() then
    raise exception 'Sessão inválida ou usuário inativo.' using errcode = '42501';
  end if;
  -- informação gerencial: somente gestor e administrador
  if not public.has_any_role(array['gestor', 'admin']::public.app_role[]) then
    raise exception 'Somente gestor ou administrador pode consultar as retiradas repetidas.' using errcode = '42501';
  end if;
  if p_days is null or p_days < 1 or p_days > 90 then
    raise exception 'A janela deve ser de 1 a 90 dias.' using errcode = '22023';
  end if;

  with base as (
    select upper(btrim(v.fixed_asset)) as asset,
           v.id as movement_id, v.me_number, v.movement_at, v.warehouse_name, v.requester_name, v.status,
           i.material_id, i.material_code, i.material_name, i.unit, i.quantity_delivered
      from public.v_movements v
      join public.stock_movement_items i on i.movement_id = v.id
     where nullif(btrim(coalesce(v.fixed_asset, '')), '') is not null
       and v.status not in ('cancelada', 'rascunho', 'aguardando_assinatura')
  ),
  recent as (
    select b.*
      from base b
      join public.v_movements v on v.id = b.movement_id
     where public.movement_matches(v, coalesce(p_filters, '{}'::jsonb), v_tz)
  ),
  pairs as (
    select r.asset, r.material_id, r.movement_id as later_id, p.movement_id as prev_id,
           extract(epoch from (r.movement_at - p.movement_at)) / 86400.0 as gap_days
      from recent r
      join base p
        on p.asset = r.asset
       and p.material_id = r.material_id
       and p.movement_id <> r.movement_id
       and (p.movement_at < r.movement_at or (p.movement_at = r.movement_at and p.me_number < r.me_number))
       and p.movement_at >= r.movement_at - make_interval(days => p_days)
  ),
  groups as (
    select asset, material_id,
           array_agg(distinct later_id) || array_agg(distinct prev_id) as ids,
           min(gap_days) as min_gap
      from pairs
     group by asset, material_id
  ),
  detailed as (
    select g.asset, g.material_id, g.min_gap,
           (select fa.name from public.fixed_assets fa where upper(fa.code) = g.asset limit 1) as asset_name,
           max(b.material_code) as material_code, max(b.material_name) as material_name, max(b.unit) as unit,
           count(distinct b.movement_id) as times,
           sum(b.quantity_delivered) as total_qty,
           max(b.movement_at) as last_at,
           jsonb_agg(jsonb_build_object(
             'movement_id', b.movement_id, 'me_number', b.me_number, 'movement_at', b.movement_at,
             'warehouse', b.warehouse_name, 'requester', b.requester_name, 'quantity', b.quantity_delivered,
             'status', b.status) order by b.movement_at) as occurrences
      from groups g
      join base b on b.asset = g.asset and b.material_id = g.material_id and b.movement_id = any (g.ids)
     group by g.asset, g.material_id, g.min_gap
  )
  select jsonb_build_object(
           'days', p_days,
           'total', (select count(*) from detailed),
           'items', coalesce((
             select jsonb_agg(jsonb_build_object(
                      'asset', d.asset, 'asset_name', d.asset_name,
                      'material_id', d.material_id, 'material_code', d.material_code, 'material_name', d.material_name,
                      'unit', d.unit, 'times', d.times, 'total_qty', d.total_qty,
                      'min_gap_days', round(d.min_gap::numeric, 1), 'last_at', d.last_at,
                      'occurrences', d.occurrences) order by d.last_at desc)
               from (select * from detailed order by last_at desc limit 100) d), '[]'::jsonb)
         )
    into v_result;
  return v_result;
end;
$$;

revoke all on function public.repeat_asset_withdrawals(jsonb, int) from public, anon;
grant execute on function public.repeat_asset_withdrawals(jsonb, int) to authenticated;


-- >>>>>>>>>> 07d_me_emergencial.sql
-- =====================================================================
-- 07d (= migração 21) - CONTRATO FIXO, LOCAL DE APLICAÇÃO FIXO ( - ) E ME EMERGENCIAL
-- * Parâmetros ganham "contrato padrão": a tela já vem com o contrato fixo
--   e o servidor usa esse contrato quando nenhum é enviado.
-- * Local de aplicação: sem local cadastrado, a ME grava "-".
-- * ME emergencial: retirada só para controle. Exige motivo, não vai para a
--   equipe de SA nem para a baixa no ERP; fica "Concluída" ao ser registrada
--   (assistente) ou confirmada pelo solicitante (balcão).
-- Pré-requisito: 14 a 20. Pode ser reexecutado.
-- =====================================================================

alter table public.app_settings
  add column if not exists default_contract_id uuid references public.contracts (id) on delete set null;

-- Se houver um único contrato ativo, ele vira o contrato padrão
update public.app_settings s
   set default_contract_id = (select id from public.contracts where active limit 1)
 where s.id = 1 and s.default_contract_id is null
   and (select count(*) from public.contracts where active) = 1;

alter table public.stock_movements add column if not exists is_emergency boolean not null default false;
alter table public.stock_movements add column if not exists emergency_reason text;
alter table public.stock_movements drop constraint if exists stock_movements_emergency_ck;
alter table public.stock_movements add constraint stock_movements_emergency_ck check (
  not is_emergency or length(btrim(coalesce(emergency_reason, ''))) between 5 and 500
);
create index if not exists stock_movements_emergency_idx on public.stock_movements (is_emergency) where is_emergency;

-- ---------------------------------------------------------------------
-- Visão das MEs (novas colunas no final)
-- ---------------------------------------------------------------------
create or replace view public.v_movements
with (security_invoker = true)
as
select
  m.id,
  m.me_number,
  m.movement_type,
  m.movement_at,
  m.warehouse_id,
  w.code  as warehouse_code,
  w.name  as warehouse_name,
  m.contract_id,
  c.code  as contract_code,
  c.name  as contract_name,
  m.sector_id,
  se.name as sector_name,
  m.service_front_id,
  sf.name as service_front_name,
  coalesce(so.code, m.service_order_text) as service_order,
  coalesce(fa.code, m.fixed_asset_text)   as fixed_asset,
  m.application_location_id,
  coalesce(al.name, m.application_location_text) as application_location,
  m.notes,
  m.status,
  m.requester_employee_id,
  m.requester_name,
  m.requester_registration,
  m.requested_at,
  m.received_by_employee_id,
  m.received_by_name,
  m.received_by_registration,
  m.received_at,
  m.approved_by,
  pa.full_name as approved_by_name,
  m.approved_at,
  m.storekeeper_id,
  pk.full_name as storekeeper_name,
  m.sa_number,
  m.sa_informed_at,
  m.sa_informed_by,
  ps.full_name as sa_informed_by_name,
  m.completed_at,
  m.completed_by,
  pc.full_name as completed_by_name,
  m.cancelled_at,
  m.cancelled_by,
  px.full_name as cancelled_by_name,
  m.cancel_reason,
  m.item_count,
  m.total_requested,
  m.total_delivered,
  (select string_agg(i.material_name, '; ' order by i.line_number)
     from (select material_name, line_number
             from public.stock_movement_items
            where movement_id = m.id
            order by line_number
            limit 3) i) as materials_summary,
  m.is_demo,
  m.created_at,
  m.created_by,
  m.updated_at,
  m.updated_by,
  pu.full_name as updated_by_name,
  m.is_emergency,
  m.emergency_reason
from public.stock_movements m
join public.warehouses w on w.id = m.warehouse_id
join public.contracts c on c.id = m.contract_id
join public.sectors se on se.id = m.sector_id
left join public.service_fronts sf on sf.id = m.service_front_id
left join public.service_orders so on so.id = m.service_order_id
left join public.fixed_assets fa on fa.id = m.fixed_asset_id
left join public.application_locations al on al.id = m.application_location_id
left join public.profiles pa on pa.id = m.approved_by
left join public.profiles pk on pk.id = m.storekeeper_id
left join public.profiles ps on ps.id = m.sa_informed_by
left join public.profiles pc on pc.id = m.completed_by
left join public.profiles px on px.id = m.cancelled_by
left join public.profiles pu on pu.id = m.updated_by;

create or replace function public.movement_matches(v public.v_movements, p_f jsonb, p_tz text)
returns boolean
language sql stable
set search_path = public, pg_temp
as $$
  select
        (nullif(p_f ->> 'date_from', '') is null or (v.movement_at at time zone p_tz)::date >= (p_f ->> 'date_from')::date)
    and (nullif(p_f ->> 'date_to', '')   is null or (v.movement_at at time zone p_tz)::date <= (p_f ->> 'date_to')::date)
    and (nullif(p_f ->> 'warehouse_id', '') is null or v.warehouse_id = (p_f ->> 'warehouse_id')::uuid)
    and (nullif(p_f ->> 'me_number', '') is null or v.me_number ilike '%' || btrim(p_f ->> 'me_number') || '%')
    and (nullif(p_f ->> 'sa_number', '') is null or v.sa_number ilike '%' || btrim(p_f ->> 'sa_number') || '%')
    and (jsonb_typeof(p_f -> 'status') is distinct from 'array'
         or jsonb_array_length(p_f -> 'status') = 0
         or v.status::text in (select jsonb_array_elements_text(p_f -> 'status')))
    and (coalesce((p_f ->> 'pending_sa')::boolean, false) = false or v.status = 'aguardando_sa')
    and (nullif(p_f ->> 'emergency', '') is null
         or (p_f ->> 'emergency' = 'sim' and v.is_emergency)
         or (p_f ->> 'emergency' = 'nao' and not v.is_emergency))
    and (nullif(p_f ->> 'sector_id', '') is null or v.sector_id = (p_f ->> 'sector_id')::uuid)
    and (nullif(p_f ->> 'service_front_id', '') is null or v.service_front_id = (p_f ->> 'service_front_id')::uuid)
    and (nullif(p_f ->> 'application_location_id', '') is null or v.application_location_id = (p_f ->> 'application_location_id')::uuid)
    and (nullif(p_f ->> 'service_order', '') is null or v.service_order ilike '%' || btrim(p_f ->> 'service_order') || '%')
    and (nullif(p_f ->> 'fixed_asset', '') is null or v.fixed_asset ilike '%' || btrim(p_f ->> 'fixed_asset') || '%')
    and (nullif(p_f ->> 'requester_employee_id', '') is null or v.requester_employee_id = (p_f ->> 'requester_employee_id')::uuid)
    and (nullif(p_f ->> 'requester', '') is null
         or v.requester_name ilike '%' || btrim(p_f ->> 'requester') || '%'
         or v.requester_registration ilike '%' || btrim(p_f ->> 'requester') || '%')
    and (nullif(p_f ->> 'storekeeper_id', '') is null or v.storekeeper_id = (p_f ->> 'storekeeper_id')::uuid)
    and (nullif(p_f ->> 'responsible_user_id', '') is null
         or (p_f ->> 'responsible_user_id')::uuid in (v.created_by, v.updated_by, v.sa_informed_by, v.approved_by, v.cancelled_by, v.completed_by))
    and (
      (nullif(p_f ->> 'material', '') is null and nullif(p_f ->> 'material_code', '') is null
       and nullif(p_f ->> 'reference', '') is null and nullif(p_f ->> 'unit', '') is null)
      or exists (
        select 1 from public.stock_movement_items i
         where i.movement_id = v.id
           and (nullif(p_f ->> 'material', '') is null
                or i.material_name ilike '%' || btrim(p_f ->> 'material') || '%'
                or i.material_code ilike '%' || btrim(p_f ->> 'material') || '%'
                or i.material_reference ilike '%' || btrim(p_f ->> 'material') || '%')
           and (nullif(p_f ->> 'material_code', '') is null or i.material_code ilike '%' || btrim(p_f ->> 'material_code') || '%')
           and (nullif(p_f ->> 'reference', '') is null or i.material_reference ilike '%' || btrim(p_f ->> 'reference') || '%')
           and (nullif(p_f ->> 'unit', '') is null or upper(i.unit) = upper(btrim(p_f ->> 'unit')))
      )
    )
    and (nullif(p_f ->> 'q', '') is null
         or v.me_number ilike '%' || btrim(p_f ->> 'q') || '%'
         or v.sa_number ilike '%' || btrim(p_f ->> 'q') || '%'
         or v.requester_name ilike '%' || btrim(p_f ->> 'q') || '%'
         or v.requester_registration ilike '%' || btrim(p_f ->> 'q') || '%'
         or exists (select 1 from public.stock_movement_items i
                     where i.movement_id = v.id
                       and (i.material_name ilike '%' || btrim(p_f ->> 'q') || '%'
                            or i.material_code ilike '%' || btrim(p_f ->> 'q') || '%')));
$$;

create or replace function public.export_movements(p_filters jsonb default '{}'::jsonb, p_kind text default 'resumo')
returns jsonb
language plpgsql stable security invoker
set search_path = public, pg_temp
as $$
declare
  v_tz  text := (public.get_settings()).timezone;
  v_out jsonb;
begin
  if not public.has_any_role(array['gestor', 'admin', 'equipe_sa']::public.app_role[]) then
    raise exception 'Seu perfil não permite exportar dados.' using errcode = '42501';
  end if;

  if p_kind = 'itens' then
    select coalesce(jsonb_agg(to_jsonb(x) order by x.movement_at desc, x.me_number, x.line_number), '[]'::jsonb)
      into v_out
      from (
        select v.me_number, v.movement_at, v.warehouse_name, i.line_number, i.material_code,
               i.material_reference, i.material_name, i.unit, i.quantity_requested, i.quantity_delivered,
               i.location, coalesce(i.account_code || ' - ' || i.account_name, i.account_code) as account,
               v.contract_code || ' - ' || v.contract_name as contract, v.sector_name,
               v.service_front_name, v.service_order, v.fixed_asset, v.application_location,
               v.requester_name, v.requester_registration, v.sa_number, v.status, v.storekeeper_name,
               i.notes as item_notes, v.is_emergency, v.emergency_reason
          from public.v_movements v
          join public.stock_movement_items i on i.movement_id = v.id
         where public.movement_matches(v, coalesce(p_filters, '{}'::jsonb), v_tz)
         order by v.movement_at desc
         limit 50000
      ) x;
  else
    select coalesce(jsonb_agg(to_jsonb(x) order by x.movement_at desc), '[]'::jsonb)
      into v_out
      from (
        select v.me_number, v.movement_at, v.warehouse_name,
               v.contract_code || ' - ' || v.contract_name as contract, v.sector_name,
               v.service_front_name, v.service_order, v.fixed_asset, v.application_location,
               v.requester_name, v.requester_registration, v.item_count, v.total_delivered,
               v.sa_number, v.status, v.storekeeper_name, v.sa_informed_at, v.sa_informed_by_name,
               v.cancel_reason, v.notes, v.is_emergency, v.emergency_reason
          from public.v_movements v
         where public.movement_matches(v, coalesce(p_filters, '{}'::jsonb), v_tz)
         order by v.movement_at desc
         limit 20000
      ) x;
  end if;

  return v_out;
end;
$$;

-- ---------------------------------------------------------------------
-- Parâmetros: contrato padrão
-- ---------------------------------------------------------------------
create or replace function public.update_settings(p jsonb)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  if not public.is_admin() then
    raise exception 'Somente administrador pode alterar os parâmetros.' using errcode = '42501';
  end if;

  if p ? 'sa_number_pattern' then
    begin
      perform 'TESTE' ~ (p ->> 'sa_number_pattern');
    exception when others then
      raise exception 'Expressão regular da SA inválida.' using errcode = '22023';
    end;
  end if;
  if p ? 'timezone' and not exists (select 1 from pg_timezone_names where name = p ->> 'timezone') then
    raise exception 'Fuso horário inválido.' using errcode = '22023';
  end if;

  if nullif(p ->> 'default_contract_id', '') is not null
     and not exists (select 1 from public.contracts where id = (p ->> 'default_contract_id')::uuid and active) then
    raise exception 'Contrato padrão inválido ou inativo.' using errcode = '22023';
  end if;

  perform set_config('app.source', 'administracao', true);

  update public.app_settings s set
    me_prefix = coalesce(upper(p ->> 'me_prefix'), s.me_prefix),
    me_number_pattern = coalesce(p ->> 'me_number_pattern', s.me_number_pattern),
    me_sequence_digits = coalesce((p ->> 'me_sequence_digits')::smallint, s.me_sequence_digits),
    require_approval = coalesce((p ->> 'require_approval')::boolean, s.require_approval),
    allow_delivered_above_requested = coalesce((p ->> 'allow_delivered_above_requested')::boolean, s.allow_delivered_above_requested),
    allow_duplicate_material_lines = coalesce((p ->> 'allow_duplicate_material_lines')::boolean, s.allow_duplicate_material_lines),
    sa_number_unique = coalesce((p ->> 'sa_number_unique')::boolean, s.sa_number_unique),
    sa_number_pattern = coalesce(p ->> 'sa_number_pattern', s.sa_number_pattern),
    auto_complete_on_sa = coalesce((p ->> 'auto_complete_on_sa')::boolean, s.auto_complete_on_sa),
    timezone = coalesce(p ->> 'timezone', s.timezone),
    company_name = coalesce(nullif(btrim(p ->> 'company_name'), ''), s.company_name),
    default_contract_id = case when p ? 'default_contract_id' then nullif(p ->> 'default_contract_id', '')::uuid
                               else s.default_contract_id end
  where s.id = 1;

  return (select to_jsonb(s) from public.app_settings s where s.id = 1);
end;
$$;

-- ---------------------------------------------------------------------
-- Saída pelo assistente (inclui saída offline)
-- ---------------------------------------------------------------------
create or replace function public.create_movement(p_payload jsonb)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  s              public.app_settings := public.get_settings();
  v_uid          uuid := auth.uid();
  v_id           uuid;
  v_wh           public.warehouses;
  v_existing     public.stock_movements;
  v_requester    public.employees;
  v_receiver     public.employees;
  v_contract_id  uuid;
  v_sector_id    uuid;
  v_front_id     uuid;
  v_appl_id      uuid;
  v_so_text      text;
  v_so_id        uuid;
  v_fa_text      text;
  v_fa_id        uuid;
  v_number       text;
  v_status       public.movement_status;
  v_items        jsonb := p_payload -> 'items';
  v_item         jsonb;
  v_mat          record;
  v_line         int := 0;
  v_req          numeric;
  v_del          numeric;
  v_seen         uuid[] := '{}';
  v_sig          jsonb := p_payload -> 'signature';
  v_sig_path     text;
  v_sig_obj      record;
  v_year         int;
  v_now          timestamptz := now();
  v_signed_at    timestamptz;
  v_at           timestamptz;             -- data/hora real da retirada
  v_offline      boolean := false;
  v_emergency    boolean := false;
  v_emerg_reason text := nullif(btrim(coalesce(p_payload ->> 'emergency_reason', '')), '');
begin
  -- Saída registrada sem internet: usa a data/hora real da retirada (até 7 dias atrás)
  if nullif(p_payload ->> 'offline_at', '') is not null then
    begin
      v_at := (p_payload ->> 'offline_at')::timestamptz;
    exception when others then
      raise exception 'Data/hora da saída offline inválida.' using errcode = '22023';
    end;
    if v_at > v_now + interval '5 minutes' or v_at < v_now - interval '7 days' then
      raise exception 'Saída offline com data fora do prazo (até 7 dias). Registre pela contingência em papel.' using errcode = '22023';
    end if;
    v_offline := true;
  else
    v_at := v_now;
  end if;

  -- 1) Autenticação e perfil
  if v_uid is null or not public.is_active_user() then
    raise exception 'Sessão inválida ou usuário inativo.' using errcode = '42501';
  end if;
  if not public.has_any_role(array['almoxarife', 'gestor', 'admin']::public.app_role[]) then
    raise exception 'Seu perfil não permite registrar saídas de material.' using errcode = '42501';
  end if;

  -- 2) Identificador (chave de idempotência gerada no cliente)
  begin
    v_id := (p_payload ->> 'id')::uuid;
  exception when others then
    raise exception 'Identificador da movimentação inválido.' using errcode = '22023';
  end;
  if v_id is null then
    raise exception 'Identificador da movimentação é obrigatório.' using errcode = '22023';
  end if;

  -- Serializa reenvios com o mesmo identificador (duplo clique / nova tentativa)
  perform pg_advisory_xact_lock(hashtextextended(v_id::text, 0));

  select * into v_existing from public.stock_movements where id = v_id;
  if found then
    if v_existing.created_by <> v_uid then
      raise exception 'Identificador de movimentação já utilizado.' using errcode = '23505';
    end if;
    return jsonb_build_object('id', v_existing.id, 'me_number', v_existing.me_number,
                              'status', v_existing.status, 'created', false);
  end if;

  -- 3) Estoque
  select * into v_wh from public.warehouses where id = nullif(p_payload ->> 'warehouse_id', '')::uuid;
  if v_wh.id is null then
    raise exception 'Selecione o estoque de origem.' using errcode = '22023';
  end if;
  if not v_wh.active then
    raise exception 'O estoque % está inativo.', v_wh.name using errcode = '22023';
  end if;
  if not public.can_access_warehouse(v_wh.id) then
    raise exception 'Você não tem permissão para operar no estoque %.', v_wh.name using errcode = '42501';
  end if;

  -- 4) Dados operacionais
  -- Contrato fixo: sem contrato no envio, usa o contrato padrão dos parâmetros
  select id into v_contract_id from public.contracts
   where id = coalesce(nullif(p_payload ->> 'contract_id', '')::uuid, s.default_contract_id) and active;
  if v_contract_id is null then
    raise exception 'Informe um contrato ativo.' using errcode = '22023';
  end if;

  select id into v_sector_id from public.sectors
   where id = nullif(p_payload ->> 'sector_id', '')::uuid and active;
  if v_sector_id is null then
    raise exception 'Informe um setor ativo.' using errcode = '22023';
  end if;

  if nullif(p_payload ->> 'service_front_id', '') is not null then
    select id into v_front_id from public.service_fronts
     where id = (p_payload ->> 'service_front_id')::uuid and active;
    if v_front_id is null then
      raise exception 'Frente de serviço/equipamento inválida ou inativa.' using errcode = '22023';
    end if;
  end if;

  if nullif(p_payload ->> 'application_location_id', '') is not null then
    select id into v_appl_id from public.application_locations
     where id = (p_payload ->> 'application_location_id')::uuid and active;
    if v_appl_id is null then
      raise exception 'Local de aplicação inválido ou inativo.' using errcode = '22023';
    end if;
  end if;

  v_so_text := nullif(btrim(coalesce(p_payload ->> 'service_order_text', '')), '');
  if v_so_text is not null then
    if length(v_so_text) > 40 then
      raise exception 'Ordem de serviço deve ter no máximo 40 caracteres.' using errcode = '22023';
    end if;
    select id into v_so_id from public.service_orders where upper(code) = upper(v_so_text) and active;
  end if;

  v_fa_text := nullif(btrim(coalesce(p_payload ->> 'fixed_asset_text', '')), '');
  if v_fa_text is not null then
    if length(v_fa_text) > 40 then
      raise exception 'Ativo fixo deve ter no máximo 40 caracteres.' using errcode = '22023';
    end if;
    select id into v_fa_id from public.fixed_assets where upper(code) = upper(v_fa_text) and active;
  end if;

  -- ME emergencial: somente controle (não vai para a SA nem para a baixa no ERP)
  begin
    v_emergency := coalesce(nullif(p_payload ->> 'emergency', '')::boolean, false);
  exception when others then
    raise exception 'Indicador de ME emergencial inválido.' using errcode = '22023';
  end;
  if v_emergency then
    if v_emerg_reason is null or length(v_emerg_reason) < 5 then
      raise exception 'Informe o motivo da retirada emergencial (mínimo de 5 caracteres).' using errcode = '22023';
    end if;
    if length(v_emerg_reason) > 500 then
      raise exception 'O motivo da emergência deve ter no máximo 500 caracteres.' using errcode = '22023';
    end if;
  else
    v_emerg_reason := null;
  end if;

  -- 5) Requisitante e recebedor
  select * into v_requester from public.employees
   where id = nullif(p_payload ->> 'requester_employee_id', '')::uuid;
  if v_requester.id is null then
    raise exception 'Identifique o funcionário requisitante.' using errcode = '22023';
  end if;
  if not v_requester.active then
    raise exception 'O funcionário % está inativo.', v_requester.full_name using errcode = '22023';
  end if;

  select * into v_receiver from public.employees
   where id = coalesce(nullif(p_payload ->> 'received_by_employee_id', '')::uuid, v_requester.id);
  if v_receiver.id is null or not v_receiver.active then
    raise exception 'Funcionário que recebeu o material inválido ou inativo.' using errcode = '22023';
  end if;

  -- 6) Itens
  if v_items is null or jsonb_typeof(v_items) <> 'array' or jsonb_array_length(v_items) = 0 then
    raise exception 'A ME precisa ter pelo menos um material.' using errcode = '22023';
  end if;
  if jsonb_array_length(v_items) > 200 then
    raise exception 'Limite de 200 itens por ME.' using errcode = '22023';
  end if;

  -- 7) Assinatura (obrigatória)
  v_year := extract(year from (v_at at time zone s.timezone))::int;
  v_sig_path := nullif(btrim(coalesce(v_sig ->> 'storage_path', '')), '');
  if v_sig_path is null then
    raise exception 'A assinatura do funcionário é obrigatória para finalizar a ME.' using errcode = '22023';
  end if;
  if v_sig_path not like v_wh.code || '/' || v_year::text || '/' || v_id::text || '/%' then
    raise exception 'Caminho da assinatura inválido para esta ME.' using errcode = '22023';
  end if;

  select o.name,
         nullif(o.metadata ->> 'size', '')::int as size_bytes,
         coalesce(o.metadata ->> 'mimetype', 'image/png') as mime_type
    into v_sig_obj
    from storage.objects o
   where o.bucket_id = 'assinaturas' and o.name = v_sig_path;
  if v_sig_obj.name is null then
    raise exception 'Arquivo da assinatura não encontrado no armazenamento. Tente enviar a assinatura novamente.'
      using errcode = '22023';
  end if;

  begin
    v_signed_at := coalesce(nullif(v_sig ->> 'signed_at', '')::timestamptz, v_at);
  exception when others then
    v_signed_at := v_at;
  end;
  if v_signed_at > v_now + interval '5 minutes' or v_signed_at < v_at - interval '1 day' then
    v_signed_at := v_at;
  end if;

  -- 8) Gravação
  perform set_config('app.creating', 'on', true);
  perform set_config('app.source', case when v_offline then 'offline' else coalesce(nullif(p_payload ->> 'source', ''), 'app') end, true);

  v_number := public.next_me_number(v_wh.id, v_at);
  -- Sem ativo fixo: não precisa de SA, vai direto para a baixa no ERP (status sa_informada sem número de SA)
  -- Emergencial: já nasce concluída, apenas para controle
  v_status := case when v_emergency then 'concluida'
                   when s.require_approval then 'aguardando_aprovacao'
                   when v_fa_text is null then 'sa_informada'
                   else 'aguardando_sa' end;

  insert into public.stock_movements (
    id, me_number, movement_type, movement_at, warehouse_id, contract_id, sector_id,
    service_front_id, service_order_id, service_order_text, fixed_asset_id, fixed_asset_text, requires_sa,
    application_location_id, application_location_text, notes, status, entry_channel,
    requester_employee_id, requester_name, requester_registration, requested_at,
    received_by_employee_id, received_by_name, received_by_registration, received_at,
    storekeeper_id, created_by, updated_by, created_at,
    is_emergency, emergency_reason, completed_at, completed_by
  ) values (
    v_id, v_number, 'saida', v_at, v_wh.id, v_contract_id, v_sector_id,
    v_front_id, v_so_id, v_so_text, v_fa_id, v_fa_text, v_fa_text is not null and not v_emergency,
    v_appl_id, coalesce(nullif(btrim(coalesce(p_payload ->> 'application_location_text', '')), ''),
                        case when v_appl_id is null then '-' end),
    nullif(btrim(coalesce(p_payload ->> 'notes', '')), ''), v_status, case when v_offline then 'offline' else 'assistente' end,
    v_requester.id, v_requester.full_name, v_requester.registration, v_at,
    v_receiver.id, v_receiver.full_name, v_receiver.registration, v_signed_at,
    v_uid, v_uid, v_uid, v_now,
    v_emergency, v_emerg_reason, case when v_emergency then v_now end, case when v_emergency then v_uid end
  );

  for v_item in select * from jsonb_array_elements(v_items) loop
    v_line := v_line + 1;

    select m.*, a.code as account_code, a.name as account_name
      into v_mat
      from public.materials m
      left join public.accounts a on a.id = m.account_id
     where m.id = nullif(v_item ->> 'material_id', '')::uuid;

    if v_mat.id is null then
      raise exception 'Item %: material não encontrado.', v_line using errcode = '22023';
    end if;
    if not v_mat.active then
      raise exception 'Item % (%): material inativo não pode ser baixado.', v_line, v_mat.name using errcode = '22023';
    end if;
    if v_mat.id = any (v_seen) and not s.allow_duplicate_material_lines then
      raise exception 'O material % aparece mais de uma vez. Some as quantidades em uma única linha.', v_mat.name
        using errcode = '22023';
    end if;
    v_seen := v_seen || v_mat.id;

    begin
      v_req := (v_item ->> 'quantity_requested')::numeric;
      v_del := (v_item ->> 'quantity_delivered')::numeric;
    exception when others then
      raise exception 'Item % (%): quantidade inválida.', v_line, v_mat.name using errcode = '22023';
    end;
    if v_req is null or v_req <= 0 then
      raise exception 'Item % (%): a quantidade solicitada deve ser maior que zero.', v_line, v_mat.name using errcode = '22023';
    end if;
    if v_del is null or v_del <= 0 then
      raise exception 'Item % (%): a quantidade atendida deve ser maior que zero.', v_line, v_mat.name using errcode = '22023';
    end if;
    if v_del > v_req and not s.allow_delivered_above_requested then
      raise exception 'Item % (%): a quantidade atendida não pode ser maior que a solicitada.', v_line, v_mat.name
        using errcode = '22023';
    end if;
    if v_req > 999999 or v_del > 999999 then
      raise exception 'Item % (%): quantidade acima do limite permitido.', v_line, v_mat.name using errcode = '22023';
    end if;

    insert into public.stock_movement_items (
      movement_id, line_number, material_id, material_code, material_reference, material_name,
      unit, location, account_code, account_name, quantity_requested, quantity_delivered,
      entry_method, scanned_code, notes, created_by, updated_by
    ) values (
      v_id, v_line, v_mat.id, v_mat.code, v_mat.reference, v_mat.name,
      v_mat.unit, v_mat.location, v_mat.account_code, v_mat.account_name, v_req, v_del,
      case when v_item ->> 'entry_method' = 'pesquisa_manual' then 'pesquisa_manual' else 'qr_code' end::public.item_entry_method,
      left(nullif(v_item ->> 'scanned_code', ''), 80),
      left(nullif(btrim(coalesce(v_item ->> 'notes', '')), ''), 500),
      v_uid, v_uid
    );
  end loop;

  insert into public.signatures (
    movement_id, employee_id, signer_name, signer_registration, bucket, storage_path,
    mime_type, size_bytes, signed_at, uploaded_by, is_current
  ) values (
    v_id, v_receiver.id, v_receiver.full_name, v_receiver.registration, 'assinaturas', v_sig_path,
    case when v_sig_obj.mime_type in ('image/png', 'image/jpeg', 'image/webp') then v_sig_obj.mime_type else 'image/png' end,
    v_sig_obj.size_bytes, v_signed_at, v_uid, true
  );

  perform public.write_audit(
    'me.finalizada', 'stock_movements', v_id::text, v_id, v_wh.id, null,
    jsonb_build_object('me_number', v_number, 'status', v_status, 'itens', v_line,
                       'requisitante', v_requester.full_name, 'estoque', v_wh.name,
                       'emergencial', v_emergency, 'motivo_emergencia', v_emerg_reason),
    null
  );

  perform set_config('app.creating', 'off', true);

  return jsonb_build_object('id', v_id, 'me_number', v_number, 'status', v_status, 'emergency', v_emergency, 'created', true);
end;
$$;

-- ---------------------------------------------------------------------
-- Balcão: abertura e confirmação
-- ---------------------------------------------------------------------
create or replace function public.counter_open(p_payload jsonb)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_uid          uuid := auth.uid();
  v_id           uuid;
  v_existing     public.stock_movements;
  v_wh           public.warehouses;
  v_requester    public.employees;
  v_contract_id  uuid;
  v_sector_id    uuid;
  v_front_id     uuid;
  v_appl_id      uuid;
  v_so_text      text;
  v_so_id        uuid;
  v_fa_text      text;
  v_fa_id        uuid;
  v_number       text;
  v_now          timestamptz := now();
  v_code         text;
  v_terminal     uuid;
  v_session      public.counter_sessions;
  v_emergency    boolean := false;
  v_emerg_reason text := nullif(btrim(coalesce(p_payload ->> 'emergency_reason', '')), '');
begin
  if v_uid is null or not public.is_active_user() then
    raise exception 'Sessão inválida ou usuário inativo.' using errcode = '42501';
  end if;
  if not public.has_any_role(array['almoxarife', 'gestor', 'admin']::public.app_role[]) then
    raise exception 'Seu perfil não permite registrar saídas de material.' using errcode = '42501';
  end if;

  begin
    v_id := (p_payload ->> 'id')::uuid;
  exception when others then
    raise exception 'Identificador da movimentação inválido.' using errcode = '22023';
  end;
  if v_id is null then
    raise exception 'Identificador da movimentação é obrigatório.' using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(v_id::text, 0));

  select * into v_existing from public.stock_movements where id = v_id;
  if found then
    if v_existing.created_by <> v_uid then
      raise exception 'Identificador de movimentação já utilizado.' using errcode = '23505';
    end if;
    select * into v_session from public.counter_sessions where movement_id = v_id;
    return jsonb_build_object('id', v_id, 'me_number', v_existing.me_number, 'session_id', v_session.id,
                              'pairing_code', v_session.pairing_code, 'terminal_paired', v_session.terminal_user_id is not null,
                              'created', false);
  end if;

  select * into v_wh from public.warehouses where id = nullif(p_payload ->> 'warehouse_id', '')::uuid;
  if v_wh.id is null then
    raise exception 'Selecione o estoque de origem.' using errcode = '22023';
  end if;
  if not v_wh.active then
    raise exception 'O estoque % está inativo.', v_wh.name using errcode = '22023';
  end if;
  if not public.can_access_warehouse(v_wh.id) then
    raise exception 'Você não tem permissão para operar no estoque %.', v_wh.name using errcode = '42501';
  end if;

  -- Contrato fixo: sem contrato no envio, usa o contrato padrão dos parâmetros
  select id into v_contract_id from public.contracts
   where id = coalesce(nullif(p_payload ->> 'contract_id', '')::uuid, (public.get_settings()).default_contract_id) and active;
  if v_contract_id is null then
    raise exception 'Informe um contrato ativo.' using errcode = '22023';
  end if;
  select id into v_sector_id from public.sectors where id = nullif(p_payload ->> 'sector_id', '')::uuid and active;
  if v_sector_id is null then
    raise exception 'Informe um setor ativo.' using errcode = '22023';
  end if;
  if nullif(p_payload ->> 'service_front_id', '') is not null then
    select id into v_front_id from public.service_fronts where id = (p_payload ->> 'service_front_id')::uuid and active;
    if v_front_id is null then
      raise exception 'Frente de serviço/equipamento inválida ou inativa.' using errcode = '22023';
    end if;
  end if;
  if nullif(p_payload ->> 'application_location_id', '') is not null then
    select id into v_appl_id from public.application_locations where id = (p_payload ->> 'application_location_id')::uuid and active;
    if v_appl_id is null then
      raise exception 'Local de aplicação inválido ou inativo.' using errcode = '22023';
    end if;
  end if;
  v_so_text := nullif(btrim(coalesce(p_payload ->> 'service_order_text', '')), '');
  if v_so_text is not null then
    if length(v_so_text) > 40 then
      raise exception 'Ordem de serviço deve ter no máximo 40 caracteres.' using errcode = '22023';
    end if;
    select id into v_so_id from public.service_orders where upper(code) = upper(v_so_text) and active;
  end if;
  v_fa_text := nullif(btrim(coalesce(p_payload ->> 'fixed_asset_text', '')), '');
  if v_fa_text is not null then
    if length(v_fa_text) > 40 then
      raise exception 'Ativo fixo deve ter no máximo 40 caracteres.' using errcode = '22023';
    end if;
    select id into v_fa_id from public.fixed_assets where upper(code) = upper(v_fa_text) and active;
  end if;

  -- ME emergencial: somente controle (não vai para a SA nem para a baixa no ERP)
  begin
    v_emergency := coalesce(nullif(p_payload ->> 'emergency', '')::boolean, false);
  exception when others then
    raise exception 'Indicador de ME emergencial inválido.' using errcode = '22023';
  end;
  if v_emergency then
    if v_emerg_reason is null or length(v_emerg_reason) < 5 then
      raise exception 'Informe o motivo da retirada emergencial (mínimo de 5 caracteres).' using errcode = '22023';
    end if;
    if length(v_emerg_reason) > 500 then
      raise exception 'O motivo da emergência deve ter no máximo 500 caracteres.' using errcode = '22023';
    end if;
  else
    v_emerg_reason := null;
  end if;

  select * into v_requester from public.employees where id = nullif(p_payload ->> 'requester_employee_id', '')::uuid;
  if v_requester.id is null then
    raise exception 'Identifique o funcionário solicitante.' using errcode = '22023';
  end if;
  if not v_requester.active then
    raise exception 'O funcionário % está inativo.', v_requester.full_name using errcode = '22023';
  end if;

  perform set_config('app.source', 'balcao', true);
  perform set_config('app.audit_action', 'me.balcao_aberta', true);
  v_number := public.next_me_number(v_wh.id, v_now);

  insert into public.stock_movements (
    id, me_number, movement_type, movement_at, warehouse_id, contract_id, sector_id,
    service_front_id, service_order_id, service_order_text, fixed_asset_id, fixed_asset_text, requires_sa,
    application_location_id, application_location_text, notes, status, entry_channel,
    requester_employee_id, requester_name, requester_registration, requested_at,
    received_by_employee_id, received_by_name, received_by_registration,
    storekeeper_id, created_by, updated_by, created_at,
    is_emergency, emergency_reason
  ) values (
    v_id, v_number, 'saida', v_now, v_wh.id, v_contract_id, v_sector_id,
    v_front_id, v_so_id, v_so_text, v_fa_id, v_fa_text, v_fa_text is not null and not v_emergency,
    v_appl_id, coalesce(nullif(btrim(coalesce(p_payload ->> 'application_location_text', '')), ''),
                        case when v_appl_id is null then '-' end),
    nullif(btrim(coalesce(p_payload ->> 'notes', '')), ''), 'rascunho', 'balcao',
    v_requester.id, v_requester.full_name, v_requester.registration, v_now,
    v_requester.id, v_requester.full_name, v_requester.registration,
    v_uid, v_uid, v_uid, v_now,
    v_emergency, v_emerg_reason
  );

  -- Tablet escolhido pelo almoxarife (terminal_user_id) ou, se não informado e
  -- reuse_terminal = true, o tablet da separação anterior deste almoxarife (se livre)
  if nullif(p_payload ->> 'terminal_user_id', '') is not null then
    v_terminal := (p_payload ->> 'terminal_user_id')::uuid;
    perform public._counter_check_terminal(v_terminal, v_wh.id, null);
  elsif coalesce((p_payload ->> 'reuse_terminal')::boolean, false) then
    select s.terminal_user_id into v_terminal
      from public.counter_sessions s
     where s.opened_by = v_uid and s.warehouse_id = v_wh.id and s.terminal_user_id is not null
     order by s.created_at desc limit 1;
    if v_terminal is not null and exists (
         select 1 from public.counter_sessions s
          where s.terminal_user_id = v_terminal and s.status in ('em_separacao', 'aguardando_confirmacao')) then
      v_terminal := null; -- tablet ocupado em outra separação
    end if;
  end if;

  v_code := public._counter_new_code();
  insert into public.counter_sessions (movement_id, warehouse_id, opened_by, pairing_code, pairing_expires_at,
                                       terminal_user_id, paired_at, last_event)
  values (v_id, v_wh.id, v_uid, v_code, v_now + interval '30 minutes',
          v_terminal, case when v_terminal is not null then v_now end, 'me_aberta')
  returning * into v_session;

  perform public.write_audit('me.balcao_aberta', 'stock_movements', v_id::text, v_id, v_wh.id, null,
    jsonb_build_object('me_number', v_number, 'solicitante', v_requester.full_name, 'estoque', v_wh.name,
                       'tablet_reaproveitado', v_terminal is not null,
                       'emergencial', v_emergency, 'motivo_emergencia', v_emerg_reason), null);

  return jsonb_build_object('id', v_id, 'me_number', v_number, 'session_id', v_session.id,
                            'pairing_code', v_code, 'terminal_paired', v_terminal is not null, 'created', true);
end;
$$;

create or replace function public.counter_confirm(p_movement_id uuid, p_payload jsonb)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  s          public.app_settings := public.get_settings();
  v_m        public.stock_movements;
  v_s        public.counter_sessions;
  v_wh       public.warehouses;
  v_method   text := coalesce(p_payload ->> 'method', '');
  v_path     text;
  v_obj      record;
  v_att      public.confirmation_attempts;
  v_year     int;
  v_status   public.movement_status;
  v_now      timestamptz := now();
  v_photo    text := nullif(btrim(coalesce(p_payload ->> 'photo_path', '')), '');
  v_no_photo text := nullif(btrim(coalesce(p_payload ->> 'photo_skipped_reason', '')), '');
  v_pobj     record;
begin
  if auth.uid() is null or not public.is_active_user() then
    raise exception 'Sessão inválida ou usuário inativo.' using errcode = '42501';
  end if;

  select * into v_m from public.stock_movements where id = p_movement_id for update;
  select * into v_s from public.counter_sessions where movement_id = p_movement_id for update;
  if v_m.id is null or v_s.id is null or v_s.terminal_user_id is distinct from auth.uid() then
    raise exception 'Tablet não pareado com esta ME.' using errcode = '42501';
  end if;
  if v_m.confirmed_at is not null or v_s.status = 'confirmada' then
    raise exception 'A ME % já foi confirmada.', v_m.me_number using errcode = 'P0001';
  end if;
  if v_m.status = 'rascunho' then
    raise exception 'A separação ainda não foi finalizada pelo almoxarife.' using errcode = 'P0001';
  end if;
  if v_m.status <> 'aguardando_assinatura' then
    raise exception 'A ME % não pode ser confirmada (status: %).', v_m.me_number, v_m.status using errcode = 'P0001';
  end if;

  select * into v_wh from public.warehouses where id = v_m.warehouse_id;
  v_year := extract(year from (v_m.movement_at at time zone s.timezone))::int;

  -- Foto do solicitante (evidência da retirada; visível só para gestor/admin)
  if v_photo is not null then
    if v_photo not like v_wh.code || '/' || v_year::text || '/' || v_m.id::text || '/%' then
      raise exception 'Foto inválida para esta ME.' using errcode = '22023';
    end if;
    select o.name, nullif(o.metadata ->> 'size', '')::int as size_bytes,
           coalesce(o.metadata ->> 'mimetype', 'image/jpeg') as mime_type
      into v_pobj from storage.objects o where o.bucket_id = 'fotos-retirada' and o.name = v_photo;
    if v_pobj.name is null then
      raise exception 'Foto do solicitante não encontrada. Tire a foto novamente.' using errcode = '22023';
    end if;
  elsif v_no_photo is null and v_method = 'assinatura' then
    raise exception 'Tire a foto do solicitante antes de confirmar.' using errcode = '22023';
  end if;

  if v_method = 'assinatura' then
    v_path := nullif(btrim(coalesce(p_payload ->> 'signature_path', '')), '');
    if v_path is null or v_path not like v_wh.code || '/' || v_year::text || '/' || v_m.id::text || '/%' then
      raise exception 'Assinatura inválida para esta ME.' using errcode = '22023';
    end if;
    select o.name, nullif(o.metadata ->> 'size', '')::int as size_bytes,
           coalesce(o.metadata ->> 'mimetype', 'image/png') as mime_type
      into v_obj from storage.objects o where o.bucket_id = 'assinaturas' and o.name = v_path;
    if v_obj.name is null then
      raise exception 'Arquivo da assinatura não encontrado. Tente assinar novamente.' using errcode = '22023';
    end if;
    insert into public.confirmation_attempts (movement_id, employee_id, method, provider, result, consumed_at, detail)
    values (v_m.id, v_m.requester_employee_id, 'assinatura', 'assinatura_digital', 'sucesso', v_now,
            jsonb_build_object('storage_path', v_path, 'foto', v_photo, 'sem_foto_motivo', v_no_photo))
    returning * into v_att;
    insert into public.signatures (movement_id, employee_id, signer_name, signer_registration, bucket, storage_path,
                                   mime_type, size_bytes, signed_at, uploaded_by, is_current)
    values (v_m.id, v_m.requester_employee_id, v_m.requester_name, v_m.requester_registration, 'assinaturas', v_path,
            case when v_obj.mime_type in ('image/png', 'image/jpeg', 'image/webp') then v_obj.mime_type else 'image/png' end,
            v_obj.size_bytes, v_now, auth.uid(), true);
  elsif v_method = 'facial' then
    -- A verificação facial é gravada pelo servidor (Edge Function); aqui só é consumida, uma única vez.
    select * into v_att from public.confirmation_attempts
     where id = nullif(p_payload ->> 'verification_id', '')::uuid
       and movement_id = v_m.id and method = 'facial' and result = 'sucesso'
       and consumed_at is null and created_at > v_now - interval '5 minutes'
     for update;
    if v_att.id is null then
      raise exception 'Validação facial não encontrada, expirada ou já utilizada. Faça a validação novamente.' using errcode = '22023';
    end if;
    update public.confirmation_attempts set consumed_at = v_now where id = v_att.id;
  else
    raise exception 'Método de confirmação inválido.' using errcode = '22023';
  end if;

  if v_photo is not null then
    insert into public.movement_photos (movement_id, employee_id, bucket, storage_path, kind, mime_type, size_bytes, taken_at, uploaded_by)
    values (v_m.id, v_m.requester_employee_id, 'fotos-retirada', v_photo, 'confirmacao_balcao',
            case when v_pobj.mime_type in ('image/jpeg', 'image/webp', 'image/png') then v_pobj.mime_type else 'image/jpeg' end,
            v_pobj.size_bytes, v_now, auth.uid())
    on conflict (storage_path) do nothing;
  end if;

  -- Emergencial: concluída na confirmação, apenas para controle (sem SA e sem baixa no ERP)
  v_status := case when v_m.is_emergency then 'concluida'
                   when s.require_approval then 'aguardando_aprovacao'
                   when v_m.requires_sa then 'aguardando_sa'
                   else 'sa_informada' end;

  perform set_config('app.audit_action', 'me.confirmada', true);
  perform set_config('app.source', 'balcao', true);
  perform set_config('app.justification', 'Confirmada pelo solicitante (' || v_method || ')', true);
  update public.stock_movements
     set status = v_status, confirmed_at = v_now, confirmation_method = v_method, received_at = v_now,
         completed_at = case when v_m.is_emergency then v_now else completed_at end,
         completed_by = case when v_m.is_emergency then v_m.storekeeper_id else completed_by end,
         updated_by = auth.uid()
   where id = v_m.id;
  perform public._counter_touch(v_m.id, 'me_confirmada', 'confirmada');

  perform public.write_audit('me.confirmada', 'stock_movements', v_m.id::text, v_m.id, v_m.warehouse_id, null,
    jsonb_build_object('me_number', v_m.me_number, 'solicitante', v_m.requester_name, 'metodo', v_method,
                       'tentativa', v_att.id, 'itens', v_m.item_count, 'total_atendido', v_m.total_delivered,
                       'almoxarife', v_m.storekeeper_id, 'status', v_status,
                       'foto', v_photo is not null, 'sem_foto_motivo', v_no_photo,
                       'emergencial', v_m.is_emergency), null);

  return jsonb_build_object('id', v_m.id, 'me_number', v_m.me_number, 'status', v_status);
end;
$$;

create or replace function public.counter_snapshot(p_movement_id uuid default null)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare
  v_s public.counter_sessions;
  v_m public.stock_movements;
begin
  if auth.uid() is null or not public.is_active_user() then
    raise exception 'Sessão inválida ou usuário inativo.' using errcode = '42501';
  end if;

  if p_movement_id is null then
    -- tablet: ME ativa pareada (ou a última confirmada/cancelada nos últimos 2 minutos)
    select * into v_s from public.counter_sessions
     where terminal_user_id = auth.uid()
       and (status in ('em_separacao', 'aguardando_confirmacao') or last_event_at > now() - interval '2 minutes')
     order by (status in ('em_separacao', 'aguardando_confirmacao')) desc, last_event_at desc
     limit 1;
    if v_s.id is null then
      return null;
    end if;
  else
    select * into v_s from public.counter_sessions where movement_id = p_movement_id;
    if v_s.id is null then
      raise exception 'Separação não encontrada.' using errcode = 'P0002';
    end if;
    if not (v_s.opened_by = auth.uid() or v_s.terminal_user_id = auth.uid()
            or (public.has_any_role(array['gestor', 'admin']::public.app_role[]) and public.can_access_warehouse(v_s.warehouse_id))) then
      raise exception 'Separação não encontrada.' using errcode = 'P0002';
    end if;
  end if;

  select * into v_m from public.stock_movements where id = v_s.movement_id;

  return jsonb_build_object(
    'session', jsonb_build_object(
      'id', v_s.id, 'status', v_s.status, 'version', v_s.version, 'last_event', v_s.last_event,
      'last_event_at', v_s.last_event_at, 'terminal_paired', v_s.terminal_user_id is not null,
      'paired_at', v_s.paired_at,
      -- o código só é mostrado ao almoxarife/gestor
      'pairing_code', case when v_s.terminal_user_id = auth.uid() then null else v_s.pairing_code end,
      'pairing_expires_at', v_s.pairing_expires_at,
      'terminal_name', (select coalesce(full_name, email) from public.profiles where id = v_s.terminal_user_id)
    ),
    'movement', jsonb_build_object(
      'id', v_m.id, 'me_number', v_m.me_number, 'status', v_m.status,
      'warehouse_name', (select name from public.warehouses where id = v_m.warehouse_id),
      'warehouse_code', (select code from public.warehouses where id = v_m.warehouse_id),
      'requester_name', v_m.requester_name, 'requester_registration', v_m.requester_registration,
      'storekeeper_name', (select coalesce(full_name, email) from public.profiles where id = v_m.storekeeper_id),
      'movement_at', v_m.movement_at, 'separation_finished_at', v_m.separation_finished_at,
      'confirmed_at', v_m.confirmed_at, 'cancel_reason', v_m.cancel_reason,
      'item_count', v_m.item_count, 'total_delivered', v_m.total_delivered,
      'fixed_asset', v_m.fixed_asset_text,
      'is_emergency', v_m.is_emergency
    ),
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', i.id, 'line_number', i.line_number, 'material_code', i.material_code,
               'material_name', i.material_name, 'unit', i.unit,
               'quantity_requested', i.quantity_requested, 'quantity_delivered', i.quantity_delivered,
               'created_at', i.created_at, 'updated_at', i.updated_at) order by i.line_number)
        from public.stock_movement_items i where i.movement_id = v_m.id), '[]'::jsonb)
  );
end;
$$;

grant select on public.v_movements to authenticated;
grant execute on function public.movement_matches(public.v_movements, jsonb, text) to authenticated;
grant execute on function public.export_movements(jsonb, text) to authenticated;
grant execute on function public.update_settings(jsonb) to authenticated;
grant execute on function public.create_movement(jsonb) to authenticated;
grant execute on function public.counter_open(jsonb) to authenticated;
grant execute on function public.counter_confirm(uuid, jsonb) to authenticated;
grant execute on function public.counter_snapshot(uuid) to authenticated;


-- >>>>>>>>>> 07e_auditoria_base.sql
-- =====================================================================
-- 07e (= migração 22) - AUDITORIA: BASE SEGURA (fase 1 do plano de auditoria e LGPD)
--
-- * audit_event: interface única de registro (write_audit vira apelido).
--   Mascara dados pessoais, remove segredos, limpa caracteres de controle,
--   classifica (categoria, criticidade, tipo de ator) e grava na MESMA
--   transação da operação (se a auditoria falhar, a operação falha junto).
-- * Encadeamento de hash SHA-256 (chain_seq + prev_hash + row_hash),
--   verificação de integridade e âncora para guardar FORA do Supabase.
-- * Consulta da auditoria somente por função do servidor (search_audit,
--   movement_audit, export_audit), com limites e evento próprio.
--   Gestor não vê IP, navegador nem e-mail.
-- * Exportação de MEs registrada no servidor (exportacao.dados).
-- * IP e navegador só são guardados em eventos de autenticação/autorização.
--
-- Os registros antigos NÃO são alterados no conteúdo: só recebem o hash
-- (para entrar no encadeamento). Pré-requisito: 01 a 21. Pode ser reexecutado.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) Novas colunas (aditivas)
-- ---------------------------------------------------------------------
alter table public.audit_logs add column if not exists event_id       uuid not null default gen_random_uuid();
alter table public.audit_logs add column if not exists schema_version smallint not null default 1;
alter table public.audit_logs add column if not exists category       text;
alter table public.audit_logs add column if not exists actor_type     text;
alter table public.audit_logs add column if not exists result         text not null default 'sucesso';
alter table public.audit_logs add column if not exists reason_code    text;
alter table public.audit_logs add column if not exists severity       text;
alter table public.audit_logs add column if not exists correlation_id uuid;
alter table public.audit_logs add column if not exists chain_seq      bigint;
alter table public.audit_logs add column if not exists prev_hash      text;
alter table public.audit_logs add column if not exists row_hash       text;

alter table public.audit_logs alter column schema_version set default 2;

alter table public.audit_logs drop constraint if exists audit_logs_result_ck;
alter table public.audit_logs add constraint audit_logs_result_ck check (result in ('sucesso', 'falha', 'negado'));
alter table public.audit_logs drop constraint if exists audit_logs_severity_ck;
alter table public.audit_logs add constraint audit_logs_severity_ck check (severity is null or severity in ('info', 'aviso', 'critico'));

create unique index if not exists audit_logs_event_uk on public.audit_logs (event_id);
create unique index if not exists audit_logs_chain_uk on public.audit_logs (chain_seq);
create index if not exists audit_logs_category_idx on public.audit_logs (category, occurred_at desc);
create index if not exists audit_logs_correlation_idx on public.audit_logs (correlation_id) where correlation_id is not null;

-- Âncoras (histórico; a cópia que vale como prova fica FORA do Supabase)
create table if not exists public.audit_anchors (
  id          bigint generated always as identity primary key,
  created_at  timestamptz not null default now(),
  created_by  uuid references public.profiles (id),
  chain_seq   bigint not null,
  row_hash    text not null,
  checked     bigint not null
);
alter table public.audit_anchors enable row level security;
revoke all on public.audit_anchors from anon, authenticated;

-- ---------------------------------------------------------------------
-- 2) Funções auxiliares: limpeza, máscara, classificação, hash
-- ---------------------------------------------------------------------

-- Remove caracteres de controle (proteção contra injeção em logs) e limita o tamanho
create or replace function public.audit_clean_text(p text, p_max int default 2000)
returns text
language sql immutable
set search_path = public, pg_temp
as $$
  select case when p is null then null
              else left(regexp_replace(p, '[[:cntrl:]]', ' ', 'g'), p_max) end;
$$;

create or replace function public.audit_mask_registration(p text)
returns text
language sql immutable
set search_path = public, pg_temp
as $$
  select case when p is null or btrim(p) = '' then p
              when length(btrim(p)) <= 2 then '**'
              else repeat('*', 4) || right(btrim(p), 2) end;
$$;

create or replace function public.audit_mask_email(p text)
returns text
language sql immutable
set search_path = public, pg_temp
as $$
  select case when p is null or position('@' in p) = 0 then p
              else left(p, 1) || '***@' || split_part(p, '@', 2) end;
$$;

-- Minimização: segredos nunca; nomes e matrículas mascarados (o id continua no evento)
create or replace function public.audit_mask(p_entity text, p_data jsonb)
returns jsonb
language plpgsql immutable
set search_path = public, pg_temp
as $$
declare
  v    jsonb := p_data;
  k    text;
begin
  if v is null or jsonb_typeof(v) <> 'object' then
    return v;
  end if;

  -- segredos e credenciais: removidos em qualquer entidade
  for k in select key from jsonb_object_keys(v) as t(key) loop
    if lower(k) ~ '(password|senha|token|secret|authorization|api_?key|service_role|cookie|jwt)' then
      v := jsonb_set(v, array[k], to_jsonb('[removido]'::text));
    end if;
  end loop;

  -- nomes de pessoas: omitidos (o id da pessoa continua no evento)
  foreach k in array array['full_name', 'requester_name', 'received_by_name', 'signer_name'] loop
    if v ? k and jsonb_typeof(v -> k) = 'string' then
      v := jsonb_set(v, array[k], to_jsonb('[omitido]'::text));
    end if;
  end loop;

  -- matrículas: mascaradas
  foreach k in array array['registration', 'requester_registration', 'received_by_registration', 'signer_registration'] loop
    if v ? k and jsonb_typeof(v -> k) = 'string' then
      v := jsonb_set(v, array[k], to_jsonb(public.audit_mask_registration(v ->> k)));
    end if;
  end loop;

  -- e-mail de usuário
  if v ? 'email' and jsonb_typeof(v -> 'email') = 'string' then
    v := jsonb_set(v, array['email'], to_jsonb(public.audit_mask_email(v ->> 'email')));
  end if;

  return v;
end;
$$;

-- Categoria e criticidade de cada evento
create or replace function public.audit_classify(p_action text, p_entity text, out category text, out severity text)
language plpgsql immutable
set search_path = public, pg_temp
as $$
begin
  if p_action like 'auth.%' then
    category := 'autenticacao'; severity := 'aviso';
  elsif p_action like 'acesso.%' then
    category := 'autorizacao'; severity := 'aviso';
  elsif p_entity in ('user_roles', 'user_warehouses', 'profiles') or p_action like 'usuario.%' then
    category := 'permissao'; severity := 'critico';
  elsif p_entity in ('app_settings', 'warehouses') then
    category := 'configuracao'; severity := 'critico';
  elsif p_action like 'auditoria.%' then
    category := 'auditoria';
    severity := case when p_action in ('auditoria.exportada', 'auditoria.integridade_verificada', 'auditoria.ancora_conferida') then 'critico' else 'aviso' end;
  elsif p_action in ('me.assinatura_consultada', 'me.foto_consultada') then
    category := 'privacidade'; severity := 'aviso';
  elsif p_action like 'exportacao.%' or p_action in ('me.impressa', 'me.pdf_gerado', 'etiquetas.impressas') then
    category := 'exportacao'; severity := 'aviso';
  elsif p_entity in ('employees', 'materials', 'material_qr_codes', 'contracts', 'sectors', 'service_fronts',
                     'service_orders', 'fixed_assets', 'application_locations', 'accounts', 'material_categories') then
    category := 'cadastro'; severity := 'info';
  else
    category := 'dados'; severity := 'info';
  end if;
end;
$$;

-- Hash de uma linha: SHA-256 do hash anterior + conteúdo canônico (jsonb ordena as chaves)
create or replace function public.audit_row_hash(p_prev text, r public.audit_logs)
returns text
language sql immutable
set search_path = public, pg_temp
as $$
  select encode(sha256(convert_to(coalesce(p_prev, '') || '|' || jsonb_build_object(
    'seq', r.chain_seq, 'id', r.id, 'event_id', r.event_id,
    'at', to_char(r.occurred_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
    'user_id', r.user_id, 'user_email', r.user_email, 'action', r.action, 'entity', r.entity,
    'entity_id', r.entity_id, 'movement_id', r.movement_id, 'warehouse_id', r.warehouse_id,
    'old', r.old_data, 'new', r.new_data, 'justification', r.justification, 'source', r.source,
    'ip', r.ip_address, 'ua', r.user_agent, 'v', r.schema_version, 'category', r.category,
    'actor', r.actor_type, 'result', r.result, 'reason', r.reason_code, 'severity', r.severity,
    'correlation', r.correlation_id
  )::text, 'UTF8')), 'hex');
$$;

-- Encadeamento: cada evento novo aponta para o hash do anterior (ordem garantida por trava)
create or replace function public.tg_audit_chain()
returns trigger
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_prev public.audit_logs;
begin
  perform pg_advisory_xact_lock(704200122);
  select * into v_prev from public.audit_logs where chain_seq is not null order by chain_seq desc limit 1;
  new.chain_seq := coalesce(v_prev.chain_seq, 0) + 1;
  new.prev_hash := coalesce(v_prev.row_hash, repeat('0', 64));
  new.row_hash  := public.audit_row_hash(new.prev_hash, new);
  return new;
end;
$$;

-- ---------------------------------------------------------------------
-- 3) Registros antigos: entram no encadeamento (conteúdo preservado)
-- ---------------------------------------------------------------------
do $$
declare
  r      public.audit_logs;
  v_prev text;
  v_seq  bigint;
begin
  if exists (select 1 from public.audit_logs where chain_seq is null) then
    alter table public.audit_logs disable trigger block_change;
    select chain_seq, row_hash into v_seq, v_prev from public.audit_logs
     where chain_seq is not null order by chain_seq desc limit 1;
    v_seq := coalesce(v_seq, 0);
    v_prev := coalesce(v_prev, repeat('0', 64));
    for r in select * from public.audit_logs where chain_seq is null order by id loop
      v_seq := v_seq + 1;
      r.chain_seq := v_seq;
      r.prev_hash := v_prev;
      r.row_hash := public.audit_row_hash(v_prev, r);
      update public.audit_logs set chain_seq = r.chain_seq, prev_hash = r.prev_hash, row_hash = r.row_hash where id = r.id;
      v_prev := r.row_hash;
    end loop;
    alter table public.audit_logs enable trigger block_change;
  end if;
end $$;

drop trigger if exists audit_chain on public.audit_logs;
create trigger audit_chain before insert on public.audit_logs
  for each row execute function public.tg_audit_chain();

-- ---------------------------------------------------------------------
-- 4) Interface única de registro
-- ---------------------------------------------------------------------
create or replace function public.audit_event(
  p_action        text,
  p_entity        text,
  p_entity_id     text,
  p_movement_id   uuid,
  p_warehouse_id  uuid,
  p_old           jsonb,
  p_new           jsonb,
  p_justification text default null,
  p_result        text default 'sucesso',
  p_reason_code   text default null
)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_uid    uuid := auth.uid();
  v_cls    record;
  v_actor  text;
  v_corr   uuid;
  v_hdr    text := public.request_header('x-correlation-id');
  v_net    boolean;
begin
  select * into v_cls from public.audit_classify(p_action, p_entity);
  v_actor := case
    when v_uid is null then 'sistema'
    when public.is_admin() then 'administrador'
    when public.has_role('terminal') and not public.has_any_role(array['almoxarife', 'equipe_sa', 'gestor']::public.app_role[]) then 'terminal'
    else 'usuario' end;
  -- Correlação: todos os eventos da mesma operação (transação) recebem o mesmo id.
  -- Um cabeçalho x-correlation-id válido, quando enviado por integração, tem prioridade.
  if v_hdr ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    v_corr := v_hdr::uuid;
  else
    v_corr := nullif(current_setting('app.correlation_id', true), '')::uuid;
    if v_corr is null then
      v_corr := gen_random_uuid();
      perform set_config('app.correlation_id', v_corr::text, true);
    end if;
  end if;
  -- IP e navegador só onde há finalidade de segurança
  v_net := v_cls.category in ('autenticacao', 'autorizacao') or coalesce(p_result, 'sucesso') <> 'sucesso';

  insert into public.audit_logs (
    user_id, user_email, action, entity, entity_id, movement_id, warehouse_id,
    old_data, new_data, justification, source, ip_address, user_agent,
    schema_version, category, actor_type, result, reason_code, severity, correlation_id
  ) values (
    v_uid, null, public.audit_clean_text(p_action, 80), public.audit_clean_text(p_entity, 80),
    public.audit_clean_text(p_entity_id, 200), p_movement_id, p_warehouse_id,
    public.audit_mask(p_entity, p_old), public.audit_mask(p_entity, p_new),
    public.audit_clean_text(coalesce(p_justification, nullif(current_setting('app.justification', true), '')), 2000),
    coalesce(nullif(current_setting('app.source', true), ''), case when v_uid is null then 'sistema' else 'app' end),
    case when v_net then nullif(split_part(coalesce(public.request_header('x-forwarded-for'), public.request_header('x-real-ip'), ''), ',', 1), '') end,
    case when v_net then public.audit_clean_text(public.request_header('user-agent'), 300) end,
    2, v_cls.category, v_actor, coalesce(p_result, 'sucesso'), public.audit_clean_text(p_reason_code, 80),
    case when coalesce(p_result, 'sucesso') <> 'sucesso' and v_cls.severity = 'info' then 'aviso' else v_cls.severity end,
    v_corr
  );
end;
$$;

-- Compatibilidade: todos os pontos que já chamam write_audit passam pela interface única
create or replace function public.write_audit(
  p_action        text,
  p_entity        text,
  p_entity_id     text,
  p_movement_id   uuid,
  p_warehouse_id  uuid,
  p_old           jsonb,
  p_new           jsonb,
  p_justification text default null
)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  perform public.audit_event(p_action, p_entity, p_entity_id, p_movement_id, p_warehouse_id, p_old, p_new, p_justification);
end;
$$;

revoke all on function public.audit_event(text, text, text, uuid, uuid, jsonb, jsonb, text, text, text) from public, anon, authenticated;
revoke all on function public.write_audit(text, text, text, uuid, uuid, jsonb, jsonb, text) from public, anon, authenticated;
revoke all on function public.audit_row_hash(text, public.audit_logs) from public, anon, authenticated;
revoke all on function public.tg_audit_chain() from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 5) Integridade: verificação e âncora
-- ---------------------------------------------------------------------
create or replace function public._audit_verify(p_upto bigint default null)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare
  r        public.audit_logs;
  v_prev   text := repeat('0', 64);
  v_seq    bigint := 0;
  v_n      bigint := 0;
  v_issue  text;
  v_bad    bigint;
begin
  for r in select * from public.audit_logs
            where p_upto is null or chain_seq <= p_upto
            order by chain_seq loop
    v_n := v_n + 1;
    if r.chain_seq is null then
      v_issue := 'sem_hash'; v_bad := r.id; exit;
    elsif r.chain_seq <> v_seq + 1 then
      v_issue := 'evento_removido'; v_bad := v_seq + 1; exit;
    elsif r.prev_hash is distinct from v_prev then
      v_issue := 'encadeamento_quebrado'; v_bad := r.chain_seq; exit;
    elsif r.row_hash is distinct from public.audit_row_hash(r.prev_hash, r) then
      v_issue := 'conteudo_alterado'; v_bad := r.chain_seq; exit;
    end if;
    v_seq := r.chain_seq;
    v_prev := r.row_hash;
  end loop;
  return jsonb_build_object('ok', v_issue is null, 'checked', v_n, 'last_seq', v_seq, 'last_hash', v_prev,
                            'problem', v_issue, 'problem_seq', v_bad);
end;
$$;
revoke all on function public._audit_verify(bigint) from public, anon, authenticated;

create or replace function public.audit_verify_chain()
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v jsonb;
begin
  if not public.is_admin() then
    raise exception 'Somente o administrador verifica a integridade da auditoria.' using errcode = '42501';
  end if;
  v := public._audit_verify(null);
  perform public.audit_event('auditoria.integridade_verificada', 'audit_logs', null, null, null, null,
    jsonb_build_object('verificados', v -> 'checked', 'ultimo', v -> 'last_seq', 'problema', v -> 'problem', 'em', v -> 'problem_seq'),
    null, case when (v ->> 'ok')::boolean then 'sucesso' else 'falha' end, v ->> 'problem');
  return v;
end;
$$;

create or replace function public.audit_create_anchor()
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v jsonb;
begin
  if not public.is_admin() then
    raise exception 'Somente o administrador gera a âncora da auditoria.' using errcode = '42501';
  end if;
  v := public._audit_verify(null);
  if not (v ->> 'ok')::boolean then
    perform public.audit_event('auditoria.ancora_gerada', 'audit_logs', null, null, null, null, v, null, 'falha', v ->> 'problem');
    return v;
  end if;
  insert into public.audit_anchors (created_by, chain_seq, row_hash, checked)
  values (auth.uid(), (v ->> 'last_seq')::bigint, v ->> 'last_hash', (v ->> 'checked')::bigint);
  perform public.audit_event('auditoria.ancora_gerada', 'audit_logs', v ->> 'last_seq', null, null, null,
    jsonb_build_object('sequencia', v -> 'last_seq', 'hash', v -> 'last_hash'));
  return v || jsonb_build_object('generated_at', now());
end;
$$;

-- Confere uma âncora guardada fora do Supabase: o evento daquela sequência ainda tem o mesmo hash
-- e o encadeamento até ele está íntegro.
create or replace function public.audit_check_anchor(p_seq bigint, p_hash text)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v       jsonb;
  v_ok    boolean;
  v_issue text;
begin
  if not public.is_admin() then
    raise exception 'Somente o administrador confere a âncora da auditoria.' using errcode = '42501';
  end if;
  if p_seq is null or p_seq < 1 or p_hash !~ '^[0-9a-f]{64}$' then
    raise exception 'Âncora inválida: informe a sequência e o hash de 64 caracteres.' using errcode = '22023';
  end if;
  v := public._audit_verify(p_seq);
  if not (v ->> 'ok')::boolean then
    v_ok := false; v_issue := v ->> 'problem';
  elsif (v ->> 'last_seq')::bigint <> p_seq then
    v_ok := false; v_issue := 'evento_removido';
  elsif v ->> 'last_hash' <> lower(p_hash) then
    v_ok := false; v_issue := 'hash_diferente_da_ancora';
  else
    v_ok := true;
  end if;
  perform public.audit_event('auditoria.ancora_conferida', 'audit_logs', p_seq::text, null, null, null,
    jsonb_build_object('sequencia', p_seq, 'confere', v_ok, 'problema', v_issue), null,
    case when v_ok then 'sucesso' else 'falha' end, v_issue);
  return jsonb_build_object('ok', v_ok, 'problem', v_issue, 'checked', v -> 'checked', 'problem_seq', v -> 'problem_seq');
end;
$$;

-- ---------------------------------------------------------------------
-- 6) Consulta e exportação da auditoria (somente por função)
-- ---------------------------------------------------------------------
create or replace function public._audit_rows(p_filters jsonb, p_admin boolean)
returns setof public.audit_logs
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare
  f      jsonb := coalesce(p_filters, '{}'::jsonb);
  v_tz   text := (public.get_settings()).timezone;
  v_from date;
  v_to   date;
  v_q    text;
begin
  begin
    v_to := coalesce(nullif(f ->> 'date_to', '')::date, (now() at time zone v_tz)::date);
    v_from := coalesce(nullif(f ->> 'date_from', '')::date, v_to - 30);
  exception when others then
    raise exception 'Período inválido.' using errcode = '22023';
  end;
  if v_from > v_to then
    raise exception 'A data inicial é maior que a final.' using errcode = '22023';
  end if;
  if v_to - v_from > 366 then
    raise exception 'Consulte no máximo 366 dias por vez.' using errcode = '22023';
  end if;
  v_q := nullif(btrim(coalesce(f ->> 'q', '')), '');
  if v_q is not null then
    v_q := '%' || replace(replace(replace(left(v_q, 100), '\', '\\'), '%', '\%'), '_', '\_') || '%';
  end if;

  return query
    select a.* from public.audit_logs a
     where a.occurred_at >= (v_from::timestamp at time zone v_tz)
       and a.occurred_at <  ((v_to + 1)::timestamp at time zone v_tz)
       and (p_admin or (a.warehouse_id is not null and public.can_access_warehouse(a.warehouse_id)))
       and (nullif(f ->> 'action', '') is null or a.action like replace(replace(f ->> 'action', '%', ''), '_', '\_') || '%')
       and (nullif(f ->> 'entity', '') is null or a.entity = f ->> 'entity')
       and (nullif(f ->> 'category', '') is null or a.category = f ->> 'category')
       and (nullif(f ->> 'result', '') is null or a.result = f ->> 'result')
       and (nullif(f ->> 'severity', '') is null or a.severity = f ->> 'severity')
       and (nullif(f ->> 'user_id', '') is null or a.user_id::text = f ->> 'user_id')
       and (nullif(f ->> 'movement_id', '') is null or a.movement_id::text = f ->> 'movement_id')
       and (nullif(f ->> 'correlation_id', '') is null or a.correlation_id::text = f ->> 'correlation_id')
       and (v_q is null or a.entity_id ilike v_q or a.justification ilike v_q or a.action ilike v_q);
end;
$$;
revoke all on function public._audit_rows(jsonb, boolean) from public, anon, authenticated;

-- Linha para a tela: gestor não recebe IP, navegador nem e-mail
create or replace function public._audit_public(a public.audit_logs, p_admin boolean)
returns jsonb
language sql stable security definer
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'id', a.id, 'event_id', a.event_id, 'occurred_at', a.occurred_at, 'user_id', a.user_id,
    'user_name', (select p.full_name from public.profiles p where p.id = a.user_id),
    'user_email', case when p_admin then a.user_email end,
    'action', a.action, 'entity', a.entity, 'entity_id', a.entity_id, 'movement_id', a.movement_id,
    'warehouse_id', a.warehouse_id, 'old_data', a.old_data, 'new_data', a.new_data,
    'justification', a.justification, 'source', a.source,
    'ip_address', case when p_admin then a.ip_address end,
    'user_agent', case when p_admin then a.user_agent end,
    'category', a.category, 'actor_type', a.actor_type, 'result', a.result, 'reason_code', a.reason_code,
    'severity', a.severity, 'correlation_id', a.correlation_id, 'chain_seq', a.chain_seq);
$$;
revoke all on function public._audit_public(public.audit_logs, boolean) from public, anon, authenticated;

create or replace function public.search_audit(p_filters jsonb default '{}'::jsonb, p_page int default 1, p_page_size int default 50)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_admin boolean := public.is_admin();
  v_size  int := least(greatest(coalesce(p_page_size, 50), 1), 100);
  v_page  int := least(greatest(coalesce(p_page, 1), 1), 1000);
  v_total bigint;
  v_rows  jsonb;
begin
  if not public.is_active_user() or not (v_admin or public.has_role('gestor')) then
    raise exception 'Seu perfil não permite consultar a auditoria.' using errcode = '42501';
  end if;
  select count(*) into v_total from public._audit_rows(p_filters, v_admin);
  select coalesce(jsonb_agg(public._audit_public(s.x, v_admin) order by (s.x).occurred_at desc, (s.x).id desc), '[]'::jsonb)
    into v_rows
    from (select x from public._audit_rows(p_filters, v_admin) x
           order by x.occurred_at desc, x.id desc
           offset (v_page - 1) * v_size limit v_size) s;
  if v_page = 1 then
    perform public.audit_event('auditoria.consultada', 'audit_logs', null, null, null, null,
      jsonb_build_object('filtros', coalesce(p_filters, '{}'::jsonb), 'resultados', v_total));
  end if;
  return jsonb_build_object('rows', v_rows, 'total', v_total, 'page', v_page, 'page_size', v_size);
end;
$$;

-- Histórico de uma ME (tela de detalhe). Quem não é gestor/admin recebe lista vazia.
create or replace function public.movement_audit(p_movement_id uuid)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare
  v_admin boolean := public.is_admin();
begin
  if not public.is_active_user() or not (v_admin or public.has_role('gestor')) or not public.can_access_movement(p_movement_id) then
    return '[]'::jsonb;
  end if;
  return coalesce((select jsonb_agg(public._audit_public(a, v_admin) order by a.occurred_at, a.id)
                     from public.audit_logs a where a.movement_id = p_movement_id), '[]'::jsonb);
end;
$$;

create or replace function public.export_audit(p_filters jsonb, p_reason text)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_reason text := public.audit_clean_text(btrim(coalesce(p_reason, '')), 500);
  v_total  bigint;
  v_rows   jsonb;
begin
  if not public.is_admin() then
    raise exception 'Somente o administrador exporta a auditoria.' using errcode = '42501';
  end if;
  if length(v_reason) < 10 then
    raise exception 'Informe a finalidade da exportação (mínimo de 10 caracteres).' using errcode = '22023';
  end if;
  select count(*) into v_total from public._audit_rows(p_filters, true);
  if v_total > 10000 then
    raise exception 'A exportação tem % eventos. O máximo é 10.000: reduza o período ou use filtros.', v_total using errcode = '22023';
  end if;
  select coalesce(jsonb_agg(public._audit_public(x, true) order by x.occurred_at desc, x.id desc), '[]'::jsonb)
    into v_rows from public._audit_rows(p_filters, true) x;
  perform public.audit_event('auditoria.exportada', 'audit_logs', null, null, null, null,
    jsonb_build_object('filtros', coalesce(p_filters, '{}'::jsonb), 'eventos', v_total), v_reason);
  return v_rows;
end;
$$;

-- A leitura direta da tabela deixa de existir: só pelas funções acima
revoke select on public.audit_logs from authenticated;
drop policy if exists audit_logs_select on public.audit_logs;

-- ---------------------------------------------------------------------
-- 7) Exportação de MEs registrada no servidor
-- ---------------------------------------------------------------------
create or replace function public.audit_export_event(p_kind text, p_filters jsonb, p_count int)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  if not public.is_active_user() or not public.has_any_role(array['gestor', 'admin', 'equipe_sa']::public.app_role[]) then
    raise exception 'Seu perfil não permite exportar dados.' using errcode = '42501';
  end if;
  perform public.audit_event('exportacao.dados', 'stock_movements', null, null, null, null,
    jsonb_build_object('tipo', case when p_kind = 'itens' then 'itens' else 'resumo' end,
                       'registros', p_count, 'filtros', coalesce(p_filters, '{}'::jsonb)));
end;
$$;

-- Exportação de MEs: agora registra o evento no servidor
create or replace function public.export_movements(p_filters jsonb default '{}'::jsonb, p_kind text default 'resumo')
returns jsonb
language plpgsql volatile security invoker
set search_path = public, pg_temp
as $$
declare
  v_tz  text := (public.get_settings()).timezone;
  v_out jsonb;
begin
  if not public.has_any_role(array['gestor', 'admin', 'equipe_sa']::public.app_role[]) then
    raise exception 'Seu perfil não permite exportar dados.' using errcode = '42501';
  end if;

  if p_kind = 'itens' then
    select coalesce(jsonb_agg(to_jsonb(x) order by x.movement_at desc, x.me_number, x.line_number), '[]'::jsonb)
      into v_out
      from (
        select v.me_number, v.movement_at, v.warehouse_name, i.line_number, i.material_code,
               i.material_reference, i.material_name, i.unit, i.quantity_requested, i.quantity_delivered,
               i.location, coalesce(i.account_code || ' - ' || i.account_name, i.account_code) as account,
               v.contract_code || ' - ' || v.contract_name as contract, v.sector_name,
               v.service_front_name, v.service_order, v.fixed_asset, v.application_location,
               v.requester_name, v.requester_registration, v.sa_number, v.status, v.storekeeper_name,
               i.notes as item_notes, v.is_emergency, v.emergency_reason
          from public.v_movements v
          join public.stock_movement_items i on i.movement_id = v.id
         where public.movement_matches(v, coalesce(p_filters, '{}'::jsonb), v_tz)
         order by v.movement_at desc
         limit 50000
      ) x;
  else
    select coalesce(jsonb_agg(to_jsonb(x) order by x.movement_at desc), '[]'::jsonb)
      into v_out
      from (
        select v.me_number, v.movement_at, v.warehouse_name,
               v.contract_code || ' - ' || v.contract_name as contract, v.sector_name,
               v.service_front_name, v.service_order, v.fixed_asset, v.application_location,
               v.requester_name, v.requester_registration, v.item_count, v.total_delivered,
               v.sa_number, v.status, v.storekeeper_name, v.sa_informed_at, v.sa_informed_by_name,
               v.cancel_reason, v.notes, v.is_emergency, v.emergency_reason
          from public.v_movements v
         where public.movement_matches(v, coalesce(p_filters, '{}'::jsonb), v_tz)
         order by v.movement_at desc
         limit 20000
      ) x;
  end if;

  -- registro no servidor (não depende da tela)
  perform public.audit_export_event(p_kind, p_filters, jsonb_array_length(v_out));
  return v_out;
end;
$$;

-- ---------------------------------------------------------------------
-- 8) Permissões
-- ---------------------------------------------------------------------
revoke all on function public.audit_verify_chain() from public, anon;
revoke all on function public.audit_create_anchor() from public, anon;
revoke all on function public.audit_check_anchor(bigint, text) from public, anon;
revoke all on function public.search_audit(jsonb, int, int) from public, anon;
revoke all on function public.movement_audit(uuid) from public, anon;
revoke all on function public.export_audit(jsonb, text) from public, anon;
revoke all on function public.audit_export_event(text, jsonb, int) from public, anon;
revoke all on function public.export_movements(jsonb, text) from public, anon;
grant execute on function public.audit_verify_chain() to authenticated;
grant execute on function public.audit_create_anchor() to authenticated;
grant execute on function public.audit_check_anchor(bigint, text) to authenticated;
grant execute on function public.search_audit(jsonb, int, int) to authenticated;
grant execute on function public.movement_audit(uuid) to authenticated;
grant execute on function public.export_audit(jsonb, text) to authenticated;
grant execute on function public.audit_export_event(text, jsonb, int) to authenticated;
grant execute on function public.export_movements(jsonb, text) to authenticated;


-- >>>>>>>>>> 07f_seguranca_alertas_retencao.sql
-- =====================================================================
-- 07f (= migração 23) - SEGURANÇA: LOGIN, ACESSO NEGADO, ALERTAS, RETENÇÃO E DESCARTE
--      (fase 2 do plano de auditoria e LGPD)
--
-- * Login com sucesso, falha e saída relatados pela tela no momento em que
--   acontecem (falha: sem login, com limite contra abuso e e-mail mascarado).
--   Troca de senha, recuperação e criação de usuário importadas do log do
--   Supabase Auth (auth.audit_log_entries), quando ele estiver gravando no banco.
-- * Acesso negado relatado pela tela (marcado como relato_da_tela), com limite.
-- * Alertas de segurança: falhas de login, acessos negados repetidos, volume de
--   exportação, perfil de administrador concedido/retirado, quebra da
--   integridade, coleta parada, retenção vencendo, descarte executado.
-- * Retenção por categoria (proposta -> aprovada), retenção legal (bloqueia
--   descarte) e descarte com DUPLA APROVAÇÃO (dois administradores diferentes).
--   O descarte apaga o CONTEÚDO do evento e preserva o esqueleto do
--   encadeamento de hash (a verificação continua íntegra).
-- * Verificações periódicas por pg_cron, quando disponível (senão: botão
--   "Rodar verificações agora" na tela Segurança).
-- * Corrige o evento duplicado da confirmação no balcão.
--
-- Pré-requisito: 22. Pode ser reexecutado.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) Tabelas
-- ---------------------------------------------------------------------
alter table public.audit_logs add column if not exists purged_at        timestamptz;
alter table public.audit_logs add column if not exists purge_request_id bigint;

create table if not exists public.security_alerts (
  id            bigint generated always as identity primary key,
  created_at    timestamptz not null default now(),
  last_seen_at  timestamptz not null default now(),
  rule          text not null,
  severity      text not null default 'aviso' check (severity in ('info', 'aviso', 'critico')),
  title         text not null,
  details       jsonb,
  dedupe_key    text not null default '',
  occurrences   integer not null default 1,
  status        text not null default 'aberto' check (status in ('aberto', 'em_analise', 'encerrado')),
  handled_by    uuid references public.profiles (id),
  handled_at    timestamptz,
  resolution    text
);
create unique index if not exists security_alerts_open_uk on public.security_alerts (rule, dedupe_key) where status <> 'encerrado';
create index if not exists security_alerts_status_idx on public.security_alerts (status, created_at desc);

create table if not exists public.auth_login_failures (
  email_hash    text not null,
  window_start  timestamptz not null,
  attempts      integer not null default 0,
  masked_email  text,
  last_ip       text,
  last_at       timestamptz not null default now(),
  primary key (email_hash, window_start)
);
create index if not exists auth_login_failures_last_idx on public.auth_login_failures (last_at desc);

create table if not exists public.security_state (
  key         text primary key,
  value       jsonb,
  updated_at  timestamptz not null default now()
);

create table if not exists public.audit_retention_policies (
  category     text primary key,
  retain_days  integer check (retain_days is null or retain_days between 30 and 7300),
  basis        text,
  status       text not null default 'proposta' check (status in ('proposta', 'aprovada')),
  updated_by   uuid references public.profiles (id),
  updated_at   timestamptz not null default now(),
  approved_by  uuid references public.profiles (id),
  approved_at  timestamptz
);

-- Propostas técnicas (NÃO aprovadas). Prazos sem fundamento ficam vazios.
insert into public.audit_retention_policies (category, retain_days, basis) values
  ('autenticacao', 180,  'Proposta: 6 meses (Marco Civil art. 15, se aplicável) - validar com o jurídico'),
  ('autorizacao',  180,  'Proposta: 6 meses - validar com o jurídico'),
  ('privacidade',  730,  'Proposta: 2 anos (investigação interna) - boa prática'),
  ('exportacao',   730,  'Proposta: 2 anos (investigação interna) - boa prática'),
  ('auditoria',    730,  'Proposta: 2 anos - boa prática'),
  ('incidente',    1825, 'Mínimo de 5 anos (Res. CD/ANPD 15/2024, art. 10)'),
  ('dados',        null, 'A definir com a contabilidade (prazo fiscal da baixa)'),
  ('cadastro',     null, 'A definir'),
  ('permissao',    null, 'A definir'),
  ('configuracao', null, 'A definir')
on conflict (category) do nothing;

create table if not exists public.audit_legal_holds (
  id              bigint generated always as identity primary key,
  reason          text not null check (length(btrim(reason)) between 10 and 500),
  date_from       date not null,
  date_to         date not null,
  category        text,
  created_by      uuid references public.profiles (id),
  created_at      timestamptz not null default now(),
  released_by     uuid references public.profiles (id),
  released_at     timestamptz,
  release_reason  text,
  check (date_from <= date_to)
);

create table if not exists public.audit_purge_requests (
  id             bigint generated always as identity primary key,
  category       text not null,
  before_date    date not null,
  events         integer not null,
  reason         text not null,
  status         text not null default 'pendente' check (status in ('pendente', 'executado', 'rejeitado')),
  requested_by   uuid not null references public.profiles (id),
  requested_at   timestamptz not null default now(),
  decided_by     uuid references public.profiles (id),
  decided_at     timestamptz,
  decision_note  text,
  executed_at    timestamptz,
  purged         integer
);

do $$
declare t text;
begin
  foreach t in array array['security_alerts', 'auth_login_failures', 'security_state',
                           'audit_retention_policies', 'audit_legal_holds', 'audit_purge_requests'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
  end loop;
end $$;

-- Descarte: a única alteração permitida em audit_logs é apagar o conteúdo de um evento,
-- dentro da função de descarte, mantendo a sequência e os hashes.
create or replace function public.tg_block_audit_change()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'UPDATE'
     and coalesce(current_setting('app.audit_purge', true), '') = 'on'
     and new.id = old.id and new.chain_seq = old.chain_seq and new.prev_hash = old.prev_hash
     and new.row_hash = old.row_hash and new.event_id = old.event_id and new.action = old.action
     and new.occurred_at = old.occurred_at and new.category is not distinct from old.category
     and old.purged_at is null and new.purged_at is not null and new.purge_request_id is not null
     and new.old_data is null and new.new_data is null and new.justification is null
     and new.ip_address is null and new.user_agent is null and new.user_id is null and new.user_email is null
     and new.entity_id is null
  then
    return new;
  end if;
  raise exception 'Registros de auditoria não podem ser alterados ou excluídos.' using errcode = 'P0001';
end;
$$;

-- ---------------------------------------------------------------------
-- 2) Alertas
-- ---------------------------------------------------------------------
create or replace function public._raise_alert(p_rule text, p_severity text, p_title text, p_key text, p_details jsonb)
returns bigint
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_id bigint;
begin
  update public.security_alerts
     set occurrences = occurrences + 1, last_seen_at = now(), details = coalesce(p_details, details)
   where rule = p_rule and dedupe_key = coalesce(p_key, '') and status <> 'encerrado'
  returning id into v_id;
  if v_id is null then
    insert into public.security_alerts (rule, severity, title, dedupe_key, details)
    values (p_rule, p_severity, left(p_title, 200), coalesce(p_key, ''), p_details)
    returning id into v_id;
    perform public.audit_event('alerta.aberto', 'security_alerts', v_id::text, null, null, null,
      jsonb_build_object('regra', p_rule, 'criticidade', p_severity, 'titulo', left(p_title, 200)));
  end if;
  return v_id;
end;
$$;
revoke all on function public._raise_alert(text, text, text, text, jsonb) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 3) Classificação, interface única com regras de alerta e verificação com descarte
-- ---------------------------------------------------------------------
create or replace function public.audit_classify(p_action text, p_entity text, out category text, out severity text)
language plpgsql immutable
set search_path = public, pg_temp
as $$
begin
  if p_action like 'auth.%' then
    category := 'autenticacao'; severity := 'aviso';
  elsif p_action like 'acesso.%' then
    category := 'autorizacao'; severity := 'aviso';
  elsif p_entity in ('user_roles', 'user_warehouses', 'profiles') or p_action like 'usuario.%' then
    category := 'permissao'; severity := 'critico';
  elsif p_entity in ('app_settings', 'warehouses') then
    category := 'configuracao'; severity := 'critico';
  elsif p_action like 'alerta.%' then
    category := 'incidente'; severity := 'aviso';
  elsif p_action like 'retencao%' or p_action like 'seguranca.%' then
    category := 'auditoria'; severity := 'critico';
  elsif p_action like 'auditoria.descarte_%' then
    category := 'auditoria'; severity := 'critico';
  elsif p_action like 'auditoria.%' then
    category := 'auditoria';
    severity := case when p_action in ('auditoria.exportada', 'auditoria.integridade_verificada', 'auditoria.ancora_conferida') then 'critico' else 'aviso' end;
  elsif p_action in ('me.assinatura_consultada', 'me.foto_consultada') then
    category := 'privacidade'; severity := 'aviso';
  elsif p_action like 'exportacao.%' or p_action in ('me.impressa', 'me.pdf_gerado', 'etiquetas.impressas') then
    category := 'exportacao'; severity := 'aviso';
  elsif p_entity in ('employees', 'materials', 'material_qr_codes', 'contracts', 'sectors', 'service_fronts',
                     'service_orders', 'fixed_assets', 'application_locations', 'accounts', 'material_categories') then
    category := 'cadastro'; severity := 'info';
  else
    category := 'dados'; severity := 'info';
  end if;
end;
$$;

create or replace function public.audit_event(
  p_action        text,
  p_entity        text,
  p_entity_id     text,
  p_movement_id   uuid,
  p_warehouse_id  uuid,
  p_old           jsonb,
  p_new           jsonb,
  p_justification text default null,
  p_result        text default 'sucesso',
  p_reason_code   text default null
)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_uid    uuid := auth.uid();
  v_cls    record;
  v_actor  text;
  v_corr   uuid;
  v_hdr    text := public.request_header('x-correlation-id');
  v_net    boolean;
begin
  select * into v_cls from public.audit_classify(p_action, p_entity);
  v_actor := case
    when v_uid is null and p_action like 'auth.%' then 'anonimo'
    when v_uid is null then 'sistema'
    when public.is_admin() then 'administrador'
    when public.has_role('terminal') and not public.has_any_role(array['almoxarife', 'equipe_sa', 'gestor']::public.app_role[]) then 'terminal'
    else 'usuario' end;
  -- Correlação: todos os eventos da mesma operação (transação) recebem o mesmo id.
  -- Um cabeçalho x-correlation-id válido, quando enviado por integração, tem prioridade.
  if v_hdr ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    v_corr := v_hdr::uuid;
  else
    v_corr := nullif(current_setting('app.correlation_id', true), '')::uuid;
    if v_corr is null then
      v_corr := gen_random_uuid();
      perform set_config('app.correlation_id', v_corr::text, true);
    end if;
  end if;
  -- IP e navegador só onde há finalidade de segurança
  v_net := v_cls.category in ('autenticacao', 'autorizacao') or coalesce(p_result, 'sucesso') <> 'sucesso';

  insert into public.audit_logs (
    user_id, user_email, action, entity, entity_id, movement_id, warehouse_id,
    old_data, new_data, justification, source, ip_address, user_agent,
    schema_version, category, actor_type, result, reason_code, severity, correlation_id
  ) values (
    v_uid, null, public.audit_clean_text(p_action, 80), public.audit_clean_text(p_entity, 80),
    public.audit_clean_text(p_entity_id, 200), p_movement_id, p_warehouse_id,
    public.audit_mask(p_entity, p_old), public.audit_mask(p_entity, p_new),
    public.audit_clean_text(coalesce(p_justification, nullif(current_setting('app.justification', true), '')), 2000),
    coalesce(nullif(current_setting('app.source', true), ''), case when v_uid is null then 'sistema' else 'app' end),
    case when v_net then nullif(split_part(coalesce(public.request_header('x-forwarded-for'), public.request_header('x-real-ip'), ''), ',', 1), '') end,
    case when v_net then public.audit_clean_text(public.request_header('user-agent'), 300) end,
    2, v_cls.category, v_actor, coalesce(p_result, 'sucesso'), public.audit_clean_text(p_reason_code, 80),
    case when coalesce(p_result, 'sucesso') <> 'sucesso' and v_cls.severity = 'info' then 'aviso' else v_cls.severity end,
    v_corr
  );

  -- Regras de alerta avaliadas no próprio registro
  if p_entity = 'user_roles' and ((p_new ->> 'role') = 'admin' or (p_old ->> 'role') = 'admin') then
    perform public._raise_alert('perfil_admin', 'critico',
      case when p_new ->> 'role' = 'admin' then 'Perfil de administrador concedido' else 'Perfil de administrador retirado' end,
      coalesce(p_entity_id, '') || ':' || coalesce(p_new ->> 'role', p_old ->> 'role', ''),
      jsonb_build_object('usuario_afetado', coalesce(p_new ->> 'user_id', p_old ->> 'user_id'), 'por', v_uid, 'acao', p_action));
  end if;
  if p_action in ('exportacao.dados', 'auditoria.exportada') and v_uid is not null then
    if (select count(*) from public.audit_logs where user_id = v_uid and action in ('exportacao.dados', 'auditoria.exportada')
          and occurred_at > now() - interval '24 hours') = 10 then
      perform public._raise_alert('exportacoes_volume', 'aviso', '10 exportações em 24 horas pelo mesmo usuário', v_uid::text,
        jsonb_build_object('usuario', v_uid));
    end if;
  end if;
end;
$$;

create or replace function public._audit_verify(p_upto bigint default null)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare
  r        public.audit_logs;
  v_prev   text := repeat('0', 64);
  v_seq    bigint := 0;
  v_n      bigint := 0;
  v_issue  text;
  v_bad    bigint;
begin
  for r in select * from public.audit_logs
            where p_upto is null or chain_seq <= p_upto
            order by chain_seq loop
    v_n := v_n + 1;
    if r.chain_seq is null then
      v_issue := 'sem_hash'; v_bad := r.id; exit;
    elsif r.chain_seq <> v_seq + 1 then
      v_issue := 'evento_removido'; v_bad := v_seq + 1; exit;
    elsif r.prev_hash is distinct from v_prev then
      v_issue := 'encadeamento_quebrado'; v_bad := r.chain_seq; exit;
    elsif r.purged_at is null and r.row_hash is distinct from public.audit_row_hash(r.prev_hash, r) then
      v_issue := 'conteudo_alterado'; v_bad := r.chain_seq; exit;
    elsif r.purged_at is not null and not exists (
            select 1 from public.audit_purge_requests q
             where q.id = r.purge_request_id and q.status = 'executado' and q.category = r.category
               and r.occurred_at < (q.before_date::timestamp at time zone (public.get_settings()).timezone)) then
      v_issue := 'descarte_nao_autorizado'; v_bad := r.chain_seq; exit;
    end if;
    v_seq := r.chain_seq;
    v_prev := r.row_hash;
  end loop;
  return jsonb_build_object('ok', v_issue is null, 'checked', v_n, 'last_seq', v_seq, 'last_hash', v_prev,
                            'problem', v_issue, 'problem_seq', v_bad);
end;
$$;
revoke all on function public._audit_verify(bigint) from public, anon, authenticated;
revoke all on function public.audit_event(text, text, text, uuid, uuid, jsonb, jsonb, text, text, text) from public, anon, authenticated;

-- Confirmação no balcão: o gatilho já registra 'me.confirmada'; os detalhes vão em evento próprio
create or replace function public.counter_confirm(p_movement_id uuid, p_payload jsonb)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  s          public.app_settings := public.get_settings();
  v_m        public.stock_movements;
  v_s        public.counter_sessions;
  v_wh       public.warehouses;
  v_method   text := coalesce(p_payload ->> 'method', '');
  v_path     text;
  v_obj      record;
  v_att      public.confirmation_attempts;
  v_year     int;
  v_status   public.movement_status;
  v_now      timestamptz := now();
  v_photo    text := nullif(btrim(coalesce(p_payload ->> 'photo_path', '')), '');
  v_no_photo text := nullif(btrim(coalesce(p_payload ->> 'photo_skipped_reason', '')), '');
  v_pobj     record;
begin
  if auth.uid() is null or not public.is_active_user() then
    raise exception 'Sessão inválida ou usuário inativo.' using errcode = '42501';
  end if;

  select * into v_m from public.stock_movements where id = p_movement_id for update;
  select * into v_s from public.counter_sessions where movement_id = p_movement_id for update;
  if v_m.id is null or v_s.id is null or v_s.terminal_user_id is distinct from auth.uid() then
    raise exception 'Tablet não pareado com esta ME.' using errcode = '42501';
  end if;
  if v_m.confirmed_at is not null or v_s.status = 'confirmada' then
    raise exception 'A ME % já foi confirmada.', v_m.me_number using errcode = 'P0001';
  end if;
  if v_m.status = 'rascunho' then
    raise exception 'A separação ainda não foi finalizada pelo almoxarife.' using errcode = 'P0001';
  end if;
  if v_m.status <> 'aguardando_assinatura' then
    raise exception 'A ME % não pode ser confirmada (status: %).', v_m.me_number, v_m.status using errcode = 'P0001';
  end if;

  select * into v_wh from public.warehouses where id = v_m.warehouse_id;
  v_year := extract(year from (v_m.movement_at at time zone s.timezone))::int;

  -- Foto do solicitante (evidência da retirada; visível só para gestor/admin)
  if v_photo is not null then
    if v_photo not like v_wh.code || '/' || v_year::text || '/' || v_m.id::text || '/%' then
      raise exception 'Foto inválida para esta ME.' using errcode = '22023';
    end if;
    select o.name, nullif(o.metadata ->> 'size', '')::int as size_bytes,
           coalesce(o.metadata ->> 'mimetype', 'image/jpeg') as mime_type
      into v_pobj from storage.objects o where o.bucket_id = 'fotos-retirada' and o.name = v_photo;
    if v_pobj.name is null then
      raise exception 'Foto do solicitante não encontrada. Tire a foto novamente.' using errcode = '22023';
    end if;
  elsif v_no_photo is null and v_method = 'assinatura' then
    raise exception 'Tire a foto do solicitante antes de confirmar.' using errcode = '22023';
  end if;

  if v_method = 'assinatura' then
    v_path := nullif(btrim(coalesce(p_payload ->> 'signature_path', '')), '');
    if v_path is null or v_path not like v_wh.code || '/' || v_year::text || '/' || v_m.id::text || '/%' then
      raise exception 'Assinatura inválida para esta ME.' using errcode = '22023';
    end if;
    select o.name, nullif(o.metadata ->> 'size', '')::int as size_bytes,
           coalesce(o.metadata ->> 'mimetype', 'image/png') as mime_type
      into v_obj from storage.objects o where o.bucket_id = 'assinaturas' and o.name = v_path;
    if v_obj.name is null then
      raise exception 'Arquivo da assinatura não encontrado. Tente assinar novamente.' using errcode = '22023';
    end if;
    insert into public.confirmation_attempts (movement_id, employee_id, method, provider, result, consumed_at, detail)
    values (v_m.id, v_m.requester_employee_id, 'assinatura', 'assinatura_digital', 'sucesso', v_now,
            jsonb_build_object('storage_path', v_path, 'foto', v_photo, 'sem_foto_motivo', v_no_photo))
    returning * into v_att;
    insert into public.signatures (movement_id, employee_id, signer_name, signer_registration, bucket, storage_path,
                                   mime_type, size_bytes, signed_at, uploaded_by, is_current)
    values (v_m.id, v_m.requester_employee_id, v_m.requester_name, v_m.requester_registration, 'assinaturas', v_path,
            case when v_obj.mime_type in ('image/png', 'image/jpeg', 'image/webp') then v_obj.mime_type else 'image/png' end,
            v_obj.size_bytes, v_now, auth.uid(), true);
  elsif v_method = 'facial' then
    -- A verificação facial é gravada pelo servidor (Edge Function); aqui só é consumida, uma única vez.
    select * into v_att from public.confirmation_attempts
     where id = nullif(p_payload ->> 'verification_id', '')::uuid
       and movement_id = v_m.id and method = 'facial' and result = 'sucesso'
       and consumed_at is null and created_at > v_now - interval '5 minutes'
     for update;
    if v_att.id is null then
      raise exception 'Validação facial não encontrada, expirada ou já utilizada. Faça a validação novamente.' using errcode = '22023';
    end if;
    update public.confirmation_attempts set consumed_at = v_now where id = v_att.id;
  else
    raise exception 'Método de confirmação inválido.' using errcode = '22023';
  end if;

  if v_photo is not null then
    insert into public.movement_photos (movement_id, employee_id, bucket, storage_path, kind, mime_type, size_bytes, taken_at, uploaded_by)
    values (v_m.id, v_m.requester_employee_id, 'fotos-retirada', v_photo, 'confirmacao_balcao',
            case when v_pobj.mime_type in ('image/jpeg', 'image/webp', 'image/png') then v_pobj.mime_type else 'image/jpeg' end,
            v_pobj.size_bytes, v_now, auth.uid())
    on conflict (storage_path) do nothing;
  end if;

  -- Emergencial: concluída na confirmação, apenas para controle (sem SA e sem baixa no ERP)
  v_status := case when v_m.is_emergency then 'concluida'
                   when s.require_approval then 'aguardando_aprovacao'
                   when v_m.requires_sa then 'aguardando_sa'
                   else 'sa_informada' end;

  perform set_config('app.audit_action', 'me.confirmada', true);
  perform set_config('app.source', 'balcao', true);
  perform set_config('app.justification', 'Confirmada pelo solicitante (' || v_method || ')', true);
  update public.stock_movements
     set status = v_status, confirmed_at = v_now, confirmation_method = v_method, received_at = v_now,
         completed_at = case when v_m.is_emergency then v_now else completed_at end,
         completed_by = case when v_m.is_emergency then v_m.storekeeper_id else completed_by end,
         updated_by = auth.uid()
   where id = v_m.id;
  perform public._counter_touch(v_m.id, 'me_confirmada', 'confirmada');

  perform public.write_audit('me.confirmacao_registrada', 'stock_movements', v_m.id::text, v_m.id, v_m.warehouse_id, null,
    jsonb_build_object('me_number', v_m.me_number, 'solicitante', v_m.requester_name, 'metodo', v_method,
                       'tentativa', v_att.id, 'itens', v_m.item_count, 'total_atendido', v_m.total_delivered,
                       'almoxarife', v_m.storekeeper_id, 'status', v_status,
                       'foto', v_photo is not null, 'sem_foto_motivo', v_no_photo,
                       'emergencial', v_m.is_emergency), null);

  return jsonb_build_object('id', v_m.id, 'me_number', v_m.me_number, 'status', v_status);
end;
$$;

-- ---------------------------------------------------------------------
-- 4) Login (relatado pela tela) e importação do log do Supabase Auth
-- ---------------------------------------------------------------------
-- Falha de login: chamada SEM sessão. E-mail guardado só mascarado e como hash
-- (hash com prefixo fixo NÃO é anonimização: serve só para contar tentativas).
create or replace function public.report_login_failure(p_email text)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_email   text := lower(btrim(left(coalesce(p_email, ''), 254)));
  v_hash    text;
  v_masked  text;
  v_window  timestamptz := date_trunc('hour', now()) + floor(extract(minute from now()) / 15) * interval '15 minutes';
  v_count   integer;
  v_recent  bigint;
  v_ip      text := nullif(split_part(coalesce(public.request_header('x-forwarded-for'), public.request_header('x-real-ip'), ''), ',', 1), '');
begin
  if v_email = '' or position('@' in v_email) = 0 then
    return;
  end if;
  -- proteção contra inundação: acima de 300 relatos por minuto, só registra o alerta
  select coalesce(sum(attempts), 0) into v_recent from public.auth_login_failures where last_at > now() - interval '1 minute';
  if v_recent > 300 then
    perform public._raise_alert('falhas_login_em_massa', 'critico', 'Muitas falhas de login no último minuto', '',
      jsonb_build_object('falhas_ultimo_minuto', v_recent));
    return;
  end if;

  v_hash := encode(sha256(convert_to('baixas-estoque:' || v_email, 'UTF8')), 'hex');
  v_masked := public.audit_mask_email(v_email);
  insert into public.auth_login_failures (email_hash, window_start, attempts, masked_email, last_ip, last_at)
  values (v_hash, v_window, 1, v_masked, left(v_ip, 64), now())
  on conflict (email_hash, window_start) do update
    set attempts = public.auth_login_failures.attempts + 1, last_ip = excluded.last_ip, last_at = now()
  returning attempts into v_count;

  -- um evento por conta e janela de 15 min (mais um ao atingir 5), sem inundar a trilha
  if v_count in (1, 5) then
    perform public.audit_event('auth.falha_login', 'auth', v_masked, null, null, null,
      jsonb_build_object('tentativas_na_janela', v_count), null, 'falha', 'credenciais_invalidas');
  end if;
  if v_count = 5 then
    perform public._raise_alert('falhas_login', 'aviso', '5 falhas de login em 15 minutos: ' || v_masked, v_hash,
      jsonb_build_object('conta', v_masked, 'tentativas', v_count, 'janela', v_window));
  end if;

  delete from public.auth_login_failures where window_start < now() - interval '7 days';
end;
$$;

create or replace function public.auth_log_session(p_action text)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_act text := case p_action when 'login' then 'auth.login' when 'logout' then 'auth.logout' end;
begin
  if v_uid is null or v_act is null then
    return;
  end if;
  if exists (select 1 from public.audit_logs where user_id = v_uid and action = v_act and occurred_at > now() - interval '10 seconds') then
    return;
  end if;
  if public.is_active_user() then
    perform public.audit_event(v_act, 'auth', v_uid::text, null, null, null, null);
  else
    perform public.audit_event(v_act, 'auth', v_uid::text, null, null, null, null, null, 'negado', 'usuario_inativo');
  end if;
end;
$$;

-- Importa do Supabase Auth os eventos que a tela não vê (senha, recuperação, criação de usuário).
create or replace function public.security_import_auth_events()
returns integer
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_since timestamptz;
  v_last  timestamptz;
  v_n     integer := 0;
  r       record;
  v_act   text;
begin
  if to_regclass('auth.audit_log_entries') is null then
    return 0;
  end if;
  select (value ->> 'since')::timestamptz into v_since from public.security_state where key = 'auth_import';
  v_since := coalesce(v_since, now() - interval '1 day');
  v_last := v_since;
  for r in execute
    'select id, created_at, ip_address, payload from auth.audit_log_entries where created_at > $1 order by created_at limit 1000'
    using v_since loop
    v_act := case (r.payload ->> 'action')
      when 'user_recovery_requested' then 'auth.recuperacao_solicitada'
      when 'user_updated_password'   then 'auth.senha_alterada'
      when 'user_signedup'           then 'auth.usuario_criado'
      when 'user_invited'            then 'auth.usuario_criado'
      when 'user_deleted'            then 'auth.usuario_excluido'
      when 'user_modified'           then 'auth.usuario_alterado'
      else null end;
    v_last := greatest(v_last, r.created_at);
    if v_act is not null then
      insert into public.audit_logs (occurred_at, user_id, action, entity, entity_id, new_data, source, ip_address,
                                     schema_version, category, actor_type, result, severity)
      values (r.created_at,
              case when (r.payload ->> 'actor_id') ~* '^[0-9a-f-]{36}$' then (r.payload ->> 'actor_id')::uuid end,
              v_act, 'auth', r.id::text,
              jsonb_build_object('origem', 'supabase_auth', 'evento_original', r.payload ->> 'action'),
              'supabase_auth', nullif(left(r.ip_address::text, 64), ''), 2, 'autenticacao', 'usuario', 'sucesso', 'aviso');
      v_n := v_n + 1;
    end if;
  end loop;
  insert into public.security_state (key, value, updated_at)
  values ('auth_import', jsonb_build_object('since', v_last, 'importados', v_n), now())
  on conflict (key) do update set value = excluded.value, updated_at = now();
  return v_n;
end;
$$;

-- ---------------------------------------------------------------------
-- 5) Acesso negado relatado pela tela
-- ---------------------------------------------------------------------
create or replace function public.log_access_denied(p_operation text, p_code text default null)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_n   integer;
begin
  if v_uid is null then
    return;
  end if;
  select count(*) into v_n from public.audit_logs
   where user_id = v_uid and action = 'acesso.negado' and occurred_at > now() - interval '1 hour';
  if v_n >= 30 then
    return; -- limite contra abuso
  end if;
  perform public.audit_event('acesso.negado', 'interface', public.audit_clean_text(p_operation, 80), null, null, null,
    jsonb_build_object('operacao', public.audit_clean_text(p_operation, 80), 'codigo', public.audit_clean_text(p_code, 20),
                       'origem', 'relato_da_tela'),
    null, 'negado', coalesce(public.audit_clean_text(p_code, 20), 'sem_permissao'));
  if v_n + 1 = 10 then
    perform public._raise_alert('acessos_negados', 'aviso', '10 acessos negados em 1 hora para o mesmo usuário', v_uid::text,
      jsonb_build_object('usuario', v_uid, 'ultima_operacao', public.audit_clean_text(p_operation, 80)));
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- 6) Verificações periódicas (pg_cron ou botão)
-- ---------------------------------------------------------------------
create or replace function public._security_checks()
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_chain   jsonb;
  v_last    timestamptz;
  v_imp     integer;
  v_alerts  integer := 0;
  p         record;
  v_due     bigint;
begin
  v_imp := public.security_import_auth_events();

  v_chain := public._audit_verify(null);
  if not (v_chain ->> 'ok')::boolean then
    perform public._raise_alert('integridade', 'critico', 'A verificação de integridade da auditoria falhou',
      coalesce(v_chain ->> 'problem_seq', ''), v_chain);
    v_alerts := v_alerts + 1;
  end if;

  select max(occurred_at) into v_last from public.audit_logs where category is distinct from 'auditoria';
  if v_last is null or v_last < now() - interval '72 hours' then
    perform public._raise_alert('coleta_parada', 'aviso', 'Nenhum evento de operação registrado há mais de 72 horas', '',
      jsonb_build_object('ultimo_evento', v_last));
    v_alerts := v_alerts + 1;
  end if;

  for p in select * from public.audit_retention_policies where status = 'aprovada' and retain_days is not null loop
    select count(*) into v_due from public.audit_logs
     where category = p.category and purged_at is null
       and occurred_at < now() - make_interval(days => greatest(p.retain_days - 30, 0));
    if v_due > 0 then
      perform public._raise_alert('retencao_vencendo', 'aviso',
        'Eventos de ' || p.category || ' chegando ao fim do prazo de retenção', p.category,
        jsonb_build_object('categoria', p.category, 'eventos', v_due, 'prazo_dias', p.retain_days));
      v_alerts := v_alerts + 1;
    end if;
  end loop;

  insert into public.security_state (key, value, updated_at)
  values ('last_checks', jsonb_build_object('at', now(), 'integridade', v_chain -> 'ok', 'importados_auth', v_imp, 'alertas', v_alerts), now())
  on conflict (key) do update set value = excluded.value, updated_at = now();

  return jsonb_build_object('integridade', v_chain, 'importados_auth', v_imp, 'alertas', v_alerts, 'at', now());
end;
$$;
revoke all on function public._security_checks() from public, anon, authenticated;

create or replace function public.security_run_checks()
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v jsonb;
begin
  if not public.is_admin() then
    raise exception 'Somente o administrador roda as verificações de segurança.' using errcode = '42501';
  end if;
  v := public._security_checks();
  perform public.audit_event('seguranca.verificacao', 'security_alerts', null, null, null, null,
    jsonb_build_object('integridade', v -> 'integridade' -> 'ok', 'alertas', v -> 'alertas', 'importados_auth', v -> 'importados_auth'));
  return v;
end;
$$;

-- Consulta da auditoria mostra quando o conteúdo do evento foi descartado
create or replace function public._audit_public(a public.audit_logs, p_admin boolean)
returns jsonb
language sql stable security definer
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'id', a.id, 'event_id', a.event_id, 'occurred_at', a.occurred_at, 'user_id', a.user_id,
    'user_name', (select p.full_name from public.profiles p where p.id = a.user_id),
    'user_email', case when p_admin then a.user_email end,
    'action', a.action, 'entity', a.entity, 'entity_id', a.entity_id, 'movement_id', a.movement_id,
    'warehouse_id', a.warehouse_id, 'old_data', a.old_data, 'new_data', a.new_data,
    'justification', a.justification, 'source', a.source,
    'ip_address', case when p_admin then a.ip_address end,
    'user_agent', case when p_admin then a.user_agent end,
    'category', a.category, 'actor_type', a.actor_type, 'result', a.result, 'reason_code', a.reason_code,
    'severity', a.severity, 'correlation_id', a.correlation_id, 'chain_seq', a.chain_seq)
    || jsonb_build_object('purged_at', a.purged_at);
$$;
revoke all on function public._audit_public(public.audit_logs, boolean) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 7) Tela de Segurança
-- ---------------------------------------------------------------------
create or replace function public.security_overview()
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare
  v_admin boolean := public.is_admin();
  v       jsonb;
begin
  if not public.is_active_user() or not (v_admin or public.has_role('gestor')) then
    raise exception 'Seu perfil não permite ver os alertas de segurança.' using errcode = '42501';
  end if;
  v := jsonb_build_object(
    'is_admin', v_admin,
    'alerts', coalesce((select jsonb_agg(to_jsonb(a) - case when v_admin then '' else 'details' end
                                         || jsonb_build_object('handled_by_name', (select full_name from public.profiles where id = a.handled_by))
                                         order by (a.status = 'encerrado'), a.last_seen_at desc)
                          from (select * from public.security_alerts
                                 where status <> 'encerrado' or handled_at > now() - interval '90 days'
                                 order by last_seen_at desc limit 200) a), '[]'::jsonb),
    'last_checks', (select value from public.security_state where key = 'last_checks'),
    'open_count', (select count(*) from public.security_alerts where status <> 'encerrado'),
    'open_critical', (select count(*) from public.security_alerts where status <> 'encerrado' and severity = 'critico'));
  if v_admin then
    v := v || jsonb_build_object(
      'policies', coalesce((select jsonb_agg(to_jsonb(p) || jsonb_build_object(
                              'approved_by_name', (select full_name from public.profiles where id = p.approved_by),
                              'updated_by_name', (select full_name from public.profiles where id = p.updated_by),
                              'events', (select count(*) from public.audit_logs l where l.category = p.category and l.purged_at is null))
                              order by p.category) from public.audit_retention_policies p), '[]'::jsonb),
      'holds', coalesce((select jsonb_agg(to_jsonb(h) || jsonb_build_object('created_by_name', (select full_name from public.profiles where id = h.created_by))
                              order by h.released_at nulls first, h.created_at desc) from public.audit_legal_holds h), '[]'::jsonb),
      'purges', coalesce((select jsonb_agg(to_jsonb(r) || jsonb_build_object(
                              'requested_by_name', (select full_name from public.profiles where id = r.requested_by),
                              'decided_by_name', (select full_name from public.profiles where id = r.decided_by))
                              order by r.requested_at desc) from (select * from public.audit_purge_requests order by requested_at desc limit 50) r), '[]'::jsonb),
      'admins', (select count(*) from public.user_roles ur join public.profiles pr on pr.id = ur.user_id where ur.role = 'admin' and pr.active),
      'cron', (to_regclass('cron.job') is not null));
  end if;
  return v;
end;
$$;

create or replace function public.security_alert_update(p_id bigint, p_status text, p_resolution text default null)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_old  public.security_alerts;
  v_note text := public.audit_clean_text(btrim(coalesce(p_resolution, '')), 1000);
begin
  if not public.is_admin() then
    raise exception 'Somente o administrador trata alertas.' using errcode = '42501';
  end if;
  if p_status not in ('aberto', 'em_analise', 'encerrado') then
    raise exception 'Situação inválida.' using errcode = '22023';
  end if;
  select * into v_old from public.security_alerts where id = p_id for update;
  if v_old.id is null then
    raise exception 'Alerta não encontrado.' using errcode = 'P0002';
  end if;
  if v_old.status = 'encerrado' then
    raise exception 'Alerta já encerrado.' using errcode = 'P0001';
  end if;
  if p_status = 'encerrado' and length(v_note) < 5 then
    raise exception 'Para encerrar, descreva o tratamento (mínimo de 5 caracteres).' using errcode = '22023';
  end if;
  update public.security_alerts
     set status = p_status, handled_by = auth.uid(), handled_at = now(), resolution = nullif(v_note, '')
   where id = p_id;
  perform public.audit_event('alerta.atualizado', 'security_alerts', p_id::text, null, null,
    jsonb_build_object('situacao', v_old.status), jsonb_build_object('situacao', p_status, 'regra', v_old.rule), nullif(v_note, ''));
end;
$$;

-- ---------------------------------------------------------------------
-- 8) Retenção, retenção legal e descarte com dupla aprovação
-- ---------------------------------------------------------------------
create or replace function public.retention_set_policy(p_category text, p_days integer, p_basis text)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_old public.audit_retention_policies;
begin
  if not public.is_admin() then
    raise exception 'Somente o administrador altera a retenção.' using errcode = '42501';
  end if;
  select * into v_old from public.audit_retention_policies where category = p_category for update;
  if v_old.category is null then
    raise exception 'Categoria inválida.' using errcode = '22023';
  end if;
  if p_days is not null and (p_days < 30 or p_days > 7300) then
    raise exception 'O prazo deve ficar entre 30 e 7300 dias.' using errcode = '22023';
  end if;
  if p_category = 'incidente' and (p_days is null or p_days < 1825) then
    raise exception 'Incidentes devem ser guardados por no mínimo 5 anos (1825 dias).' using errcode = '22023';
  end if;
  if length(btrim(coalesce(p_basis, ''))) < 5 then
    raise exception 'Informe o fundamento do prazo.' using errcode = '22023';
  end if;
  -- qualquer mudança volta para "proposta" e exige nova aprovação
  update public.audit_retention_policies
     set retain_days = p_days, basis = public.audit_clean_text(btrim(p_basis), 500), status = 'proposta',
         updated_by = auth.uid(), updated_at = now(), approved_by = null, approved_at = null
   where category = p_category;
  perform public.audit_event('retencao.alterada', 'audit_retention_policies', p_category, null, null,
    jsonb_build_object('dias', v_old.retain_days, 'situacao', v_old.status),
    jsonb_build_object('dias', p_days, 'fundamento', public.audit_clean_text(btrim(p_basis), 500)));
end;
$$;

create or replace function public.retention_approve_policy(p_category text)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v public.audit_retention_policies;
begin
  if not public.is_admin() then
    raise exception 'Somente o administrador aprova a retenção.' using errcode = '42501';
  end if;
  select * into v from public.audit_retention_policies where category = p_category for update;
  if v.category is null then
    raise exception 'Categoria inválida.' using errcode = '22023';
  end if;
  if v.retain_days is null then
    raise exception 'Defina o prazo antes de aprovar.' using errcode = '22023';
  end if;
  update public.audit_retention_policies set status = 'aprovada', approved_by = auth.uid(), approved_at = now()
   where category = p_category;
  perform public.audit_event('retencao.aprovada', 'audit_retention_policies', p_category, null, null, null,
    jsonb_build_object('dias', v.retain_days, 'fundamento', v.basis));
end;
$$;

create or replace function public.legal_hold_create(p_reason text, p_from date, p_to date, p_category text default null)
returns bigint
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_id bigint;
begin
  if not public.is_admin() then
    raise exception 'Somente o administrador abre retenção legal.' using errcode = '42501';
  end if;
  if length(btrim(coalesce(p_reason, ''))) < 10 then
    raise exception 'Informe o motivo (mínimo de 10 caracteres).' using errcode = '22023';
  end if;
  if p_from is null or p_to is null or p_from > p_to then
    raise exception 'Período inválido.' using errcode = '22023';
  end if;
  insert into public.audit_legal_holds (reason, date_from, date_to, category, created_by)
  values (public.audit_clean_text(btrim(p_reason), 500), p_from, p_to, nullif(p_category, ''), auth.uid())
  returning id into v_id;
  perform public.audit_event('retencao_legal.aberta', 'audit_legal_holds', v_id::text, null, null, null,
    jsonb_build_object('de', p_from, 'ate', p_to, 'categoria', nullif(p_category, '')), public.audit_clean_text(btrim(p_reason), 500));
  return v_id;
end;
$$;

create or replace function public.legal_hold_release(p_id bigint, p_reason text)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  if not public.is_admin() then
    raise exception 'Somente o administrador libera retenção legal.' using errcode = '42501';
  end if;
  if length(btrim(coalesce(p_reason, ''))) < 10 then
    raise exception 'Informe o motivo da liberação (mínimo de 10 caracteres).' using errcode = '22023';
  end if;
  update public.audit_legal_holds set released_by = auth.uid(), released_at = now(),
         release_reason = public.audit_clean_text(btrim(p_reason), 500)
   where id = p_id and released_at is null;
  if not found then
    raise exception 'Retenção legal não encontrada ou já liberada.' using errcode = 'P0002';
  end if;
  perform public.audit_event('retencao_legal.liberada', 'audit_legal_holds', p_id::text, null, null, null, null,
    public.audit_clean_text(btrim(p_reason), 500));
end;
$$;

-- Eventos que podem ser descartados (prazo vencido, sem retenção legal ativa)
create or replace function public._purge_candidates(p_category text, p_before date)
returns setof bigint
language sql stable security definer
set search_path = public, pg_temp
as $$
  select l.id from public.audit_logs l
   where l.category = p_category and l.purged_at is null
     and l.occurred_at < (p_before::timestamp at time zone (public.get_settings()).timezone)
     and not exists (select 1 from public.audit_legal_holds h
                      where h.released_at is null
                        and (h.category is null or h.category = l.category)
                        and (l.occurred_at at time zone (public.get_settings()).timezone)::date between h.date_from and h.date_to);
$$;
revoke all on function public._purge_candidates(text, date) from public, anon, authenticated;

create or replace function public.purge_request(p_category text, p_before date, p_reason text)
returns bigint
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_pol  public.audit_retention_policies;
  v_n    integer;
  v_id   bigint;
  v_tz   text := (public.get_settings()).timezone;
begin
  if not public.is_admin() then
    raise exception 'Somente o administrador pede descarte.' using errcode = '42501';
  end if;
  select * into v_pol from public.audit_retention_policies where category = p_category;
  if v_pol.category is null or v_pol.status <> 'aprovada' or v_pol.retain_days is null then
    raise exception 'A retenção desta categoria ainda não foi aprovada.' using errcode = 'P0001';
  end if;
  if p_before is null or p_before > (now() at time zone v_tz)::date - v_pol.retain_days then
    raise exception 'A data deve respeitar o prazo de % dias desta categoria.', v_pol.retain_days using errcode = '22023';
  end if;
  if length(btrim(coalesce(p_reason, ''))) < 10 then
    raise exception 'Informe o motivo (mínimo de 10 caracteres).' using errcode = '22023';
  end if;
  if exists (select 1 from public.audit_purge_requests where status = 'pendente' and category = p_category) then
    raise exception 'Já existe um pedido de descarte pendente para esta categoria.' using errcode = 'P0001';
  end if;
  select count(*) into v_n from public._purge_candidates(p_category, p_before);
  if v_n = 0 then
    raise exception 'Não há eventos a descartar nesse período (ou estão em retenção legal).' using errcode = 'P0002';
  end if;
  insert into public.audit_purge_requests (category, before_date, events, reason, requested_by)
  values (p_category, p_before, v_n, public.audit_clean_text(btrim(p_reason), 500), auth.uid())
  returning id into v_id;
  perform public.audit_event('auditoria.descarte_solicitado', 'audit_purge_requests', v_id::text, null, null, null,
    jsonb_build_object('categoria', p_category, 'antes_de', p_before, 'eventos', v_n), public.audit_clean_text(btrim(p_reason), 500));
  return v_id;
end;
$$;

-- Segundo administrador decide. Aprovado = executa na hora.
create or replace function public.purge_decide(p_id bigint, p_approve boolean, p_note text)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_req  public.audit_purge_requests;
  v_pol  public.audit_retention_policies;
  v_note text := public.audit_clean_text(btrim(coalesce(p_note, '')), 500);
  v_n    integer := 0;
  v_tz   text := (public.get_settings()).timezone;
begin
  if not public.is_admin() then
    raise exception 'Somente o administrador decide o descarte.' using errcode = '42501';
  end if;
  select * into v_req from public.audit_purge_requests where id = p_id for update;
  if v_req.id is null or v_req.status <> 'pendente' then
    raise exception 'Pedido não encontrado ou já decidido.' using errcode = 'P0002';
  end if;
  if v_req.requested_by = auth.uid() then
    raise exception 'O descarte precisa ser aprovado por OUTRO administrador.' using errcode = '42501';
  end if;
  if length(v_note) < 5 then
    raise exception 'Registre a justificativa da decisão (mínimo de 5 caracteres).' using errcode = '22023';
  end if;

  if not coalesce(p_approve, false) then
    update public.audit_purge_requests set status = 'rejeitado', decided_by = auth.uid(), decided_at = now(), decision_note = v_note
     where id = p_id;
    perform public.audit_event('auditoria.descarte_rejeitado', 'audit_purge_requests', p_id::text, null, null, null,
      jsonb_build_object('categoria', v_req.category), v_note);
    return jsonb_build_object('status', 'rejeitado');
  end if;

  -- revalida: política aprovada e prazo
  select * into v_pol from public.audit_retention_policies where category = v_req.category;
  if v_pol.status <> 'aprovada' or v_pol.retain_days is null
     or v_req.before_date > (now() at time zone v_tz)::date - v_pol.retain_days then
    raise exception 'A política de retenção mudou desde o pedido. Faça um novo pedido.' using errcode = 'P0001';
  end if;

  perform set_config('app.audit_purge', 'on', true);
  update public.audit_logs l
     set old_data = null, new_data = null, justification = null, ip_address = null, user_agent = null,
         user_id = null, user_email = null, entity_id = null, purged_at = now(), purge_request_id = p_id
   where l.id in (select public._purge_candidates(v_req.category, v_req.before_date));
  get diagnostics v_n = row_count;
  perform set_config('app.audit_purge', '', true);

  update public.audit_purge_requests
     set status = 'executado', decided_by = auth.uid(), decided_at = now(), decision_note = v_note,
         executed_at = now(), purged = v_n
   where id = p_id;
  perform public.audit_event('auditoria.descarte_executado', 'audit_purge_requests', p_id::text, null, null, null,
    jsonb_build_object('categoria', v_req.category, 'antes_de', v_req.before_date, 'eventos', v_n,
                       'solicitado_por', v_req.requested_by), v_note);
  perform public._raise_alert('descarte_executado', 'aviso', 'Descarte de eventos de auditoria executado (' || v_req.category || ')',
    p_id::text, jsonb_build_object('pedido', p_id, 'eventos', v_n));
  return jsonb_build_object('status', 'executado', 'eventos', v_n);
end;
$$;


-- ---------------------------------------------------------------------
-- 9) Agendamento (pg_cron, se disponível)
-- ---------------------------------------------------------------------
do $$
begin
  begin
    create extension if not exists pg_cron;
  exception when others then
    raise notice 'pg_cron indisponível: use o botão "Rodar verificações agora" na tela Segurança.';
  end;
  if to_regclass('cron.job') is not null then
    begin
      perform cron.unschedule(jobid) from cron.job where jobname = 'baixas-verificacoes-seguranca';
      perform cron.schedule('baixas-verificacoes-seguranca', '17 * * * *', 'select public._security_checks()');
    exception when others then
      raise notice 'Não foi possível agendar: %', sqlerrm;
    end;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 10) Permissões
-- ---------------------------------------------------------------------
revoke all on function public.report_login_failure(text) from public;
grant execute on function public.report_login_failure(text) to anon, authenticated;
revoke all on function public.security_import_auth_events() from public, anon, authenticated;
revoke all on function public.auth_log_session(text) from public, anon;
grant execute on function public.auth_log_session(text) to authenticated;
revoke all on function public.log_access_denied(text, text) from public, anon;
grant execute on function public.log_access_denied(text, text) to authenticated;
revoke all on function public.security_run_checks() from public, anon;
grant execute on function public.security_run_checks() to authenticated;
revoke all on function public.security_overview() from public, anon;
grant execute on function public.security_overview() to authenticated;
revoke all on function public.security_alert_update(bigint, text, text) from public, anon;
grant execute on function public.security_alert_update(bigint, text, text) to authenticated;
revoke all on function public.retention_set_policy(text, integer, text) from public, anon;
grant execute on function public.retention_set_policy(text, integer, text) to authenticated;
revoke all on function public.retention_approve_policy(text) from public, anon;
grant execute on function public.retention_approve_policy(text) to authenticated;
revoke all on function public.legal_hold_create(text, date, date, text) from public, anon;
grant execute on function public.legal_hold_create(text, date, date, text) to authenticated;
revoke all on function public.legal_hold_release(bigint, text) from public, anon;
grant execute on function public.legal_hold_release(bigint, text) to authenticated;
revoke all on function public.purge_request(text, date, text) from public, anon;
grant execute on function public.purge_request(text, date, text) to authenticated;
revoke all on function public.purge_decide(bigint, boolean, text) from public, anon;
grant execute on function public.purge_decide(bigint, boolean, text) to authenticated;
revoke all on function public.counter_confirm(uuid, jsonb) from public, anon;
grant execute on function public.counter_confirm(uuid, jsonb) to authenticated;


-- >>>>>>>>>> 07g_incidentes_lgpd.sql
-- =====================================================================
-- 24 - INCIDENTES DE SEGURANÇA E CONFIGURAÇÃO LGPD
--      (fase 3 do plano de auditoria e LGPD - parte técnica)
--
-- * Registro de incidentes com os campos mínimos do art. 10, § 1º, da
--   Resolução CD/ANPD nº 15/2024 (incisos I a VIII). Incidentes nunca são
--   apagados (o art. 10 exige guarda mínima de 5 anos).
-- * Prazos em dias úteis: comunicação à ANPD (art. 6º) e aos titulares
--   (art. 9º): 3 dias úteis contados do conhecimento de que o incidente
--   afetou dados pessoais; complementação (art. 6º, § 3º): 20 dias úteis da
--   comunicação; declaração da comunicação aos titulares (art. 9º, § 4º):
--   3 dias úteis após o fim do prazo do art. 9º. Em dobro para agente de
--   pequeno porte (art. 6º, § 8º; art. 9º, § 6º) - SÓ quando marcado.
--   Contagem (interpretação técnica, a validar com o jurídico): exclui o dia
--   do conhecimento; pula sábados, domingos e feriados cadastrados.
-- * Configuração LGPD: controlador, encarregado e porte ficam "a definir"
--   até a empresa decidir (D1 e D5). Sem porte definido, vale o prazo simples
--   (o mais curto).
-- * Alertas: prazo de comunicação vencendo/vencido e incidente sem avaliação
--   de risco.
--
-- Pré-requisito: 23. Pode ser reexecutado.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) Tabelas
-- ---------------------------------------------------------------------
create table if not exists public.privacy_settings (
  id               boolean primary key default true check (id),
  controller_name  text,
  controller_doc   text,
  dpo_name         text,
  dpo_contact      text,
  small_agent      boolean,
  updated_by       uuid references public.profiles (id),
  updated_at       timestamptz not null default now()
);
insert into public.privacy_settings (id) values (true) on conflict do nothing;

create table if not exists public.business_holidays (
  day         date primary key,
  name        text not null check (length(btrim(name)) between 2 and 120),
  scope       text not null default 'nacional' check (scope in ('nacional', 'estadual', 'municipal', 'empresa')),
  created_by  uuid references public.profiles (id),
  created_at  timestamptz not null default now()
);
-- Feriados nacionais (Lei 662/1949, Lei 6.802/1980, Lei 14.759/2023 e Sexta-feira Santa).
-- Estaduais e municipais (Pernambuco/Recife/Jaboatão) devem ser cadastrados pelo administrador.
insert into public.business_holidays (day, name) values
  ('2026-01-01', 'Confraternização Universal'), ('2026-04-03', 'Sexta-feira Santa'),
  ('2026-04-21', 'Tiradentes'), ('2026-05-01', 'Dia do Trabalho'),
  ('2026-09-07', 'Independência'), ('2026-10-12', 'Nossa Senhora Aparecida'),
  ('2026-11-02', 'Finados'), ('2026-11-15', 'Proclamação da República'),
  ('2026-11-20', 'Dia Nacional de Zumbi e da Consciência Negra'), ('2026-12-25', 'Natal'),
  ('2027-01-01', 'Confraternização Universal'), ('2027-03-26', 'Sexta-feira Santa'),
  ('2027-04-21', 'Tiradentes'), ('2027-05-01', 'Dia do Trabalho'),
  ('2027-09-07', 'Independência'), ('2027-10-12', 'Nossa Senhora Aparecida'),
  ('2027-11-02', 'Finados'), ('2027-11-15', 'Proclamação da República'),
  ('2027-11-20', 'Dia Nacional de Zumbi e da Consciência Negra'), ('2027-12-25', 'Natal')
on conflict (day) do nothing;

create table if not exists public.security_incidents (
  id                         bigint generated always as identity primary key,
  code                       text not null unique,
  title                      text not null check (length(btrim(title)) between 5 and 200),
  status                     text not null default 'aberto' check (status in ('aberto', 'em_tratamento', 'encerrado')),
  known_at                   timestamptz not null,          -- I  data de conhecimento do incidente
  personal_data_known_at     timestamptz,                   --    conhecimento de que afetou dados pessoais (início dos prazos)
  occurred_at                timestamptz,
  description                text,                          -- II circunstâncias
  data_categories            text[] not null default '{}',  -- III categoria dos dados
  data_nature                text,                          -- III natureza dos dados
  sensitive_data             boolean,
  affected_count             integer check (affected_count is null or affected_count >= 0), -- IV
  affected_count_note        text,
  risk_criteria              text[] not null default '{}',  --    critérios do art. 5º
  risk_level                 text not null default 'a_avaliar'
                             check (risk_level in ('a_avaliar', 'sem_risco_relevante', 'risco_relevante')),
  risk_assessment            text,                          -- V  avaliação do risco e possíveis danos
  measures                   text,                          -- VI medidas de correção e mitigação
  anpd_communicated_at       timestamptz,                   -- VII
  anpd_protocol              text,
  titulares_communicated_at  timestamptz,
  communication_form         text,
  communication_content      text,
  no_communication_reason    text,                          -- VIII
  alert_id                   bigint references public.security_alerts (id),
  created_by                 uuid references public.profiles (id),
  created_at                 timestamptz not null default now(),
  updated_by                 uuid references public.profiles (id),
  updated_at                 timestamptz not null default now(),
  closed_by                  uuid references public.profiles (id),
  closed_at                  timestamptz,
  closing_note               text
);
create index if not exists security_incidents_status_idx on public.security_incidents (status, created_at desc);

create table if not exists public.security_incident_notes (
  id           bigint generated always as identity primary key,
  incident_id  bigint not null references public.security_incidents (id),
  kind         text not null default 'nota' check (kind in ('nota', 'alteracao', 'status')),
  body         text not null,
  created_by   uuid references public.profiles (id),
  created_at   timestamptz not null default now()
);
create index if not exists security_incident_notes_idx on public.security_incident_notes (incident_id, created_at);

do $$
declare t text;
begin
  foreach t in array array['privacy_settings', 'business_holidays', 'security_incidents', 'security_incident_notes'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
  end loop;
end $$;

-- Incidentes e o histórico deles nunca são apagados; o histórico não é alterado.
create or replace function public.tg_block_incident_delete()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  raise exception 'Registros de incidente não podem ser excluídos (guarda mínima de 5 anos).' using errcode = 'P0001';
end;
$$;
drop trigger if exists block_delete on public.security_incidents;
create trigger block_delete before delete on public.security_incidents
  for each row execute function public.tg_block_incident_delete();
drop trigger if exists block_change on public.security_incident_notes;
create trigger block_change before update or delete on public.security_incident_notes
  for each row execute function public.tg_block_incident_delete();

-- ---------------------------------------------------------------------
-- 2) Classificação dos novos eventos (incidente.* = crítico, guarda mínima de 5 anos)
-- ---------------------------------------------------------------------
create or replace function public.audit_classify(p_action text, p_entity text, out category text, out severity text)
language plpgsql immutable
set search_path = public, pg_temp
as $$
begin
  if p_action like 'auth.%' then
    category := 'autenticacao'; severity := 'aviso';
  elsif p_action like 'acesso.%' then
    category := 'autorizacao'; severity := 'aviso';
  elsif p_entity in ('user_roles', 'user_warehouses', 'profiles') or p_action like 'usuario.%' then
    category := 'permissao'; severity := 'critico';
  elsif p_entity in ('app_settings', 'warehouses') then
    category := 'configuracao'; severity := 'critico';
  elsif p_action like 'incidente.%' then
    category := 'incidente'; severity := 'critico';
  elsif p_action like 'privacidade.%' then
    category := 'configuracao'; severity := 'critico';
  elsif p_action like 'alerta.%' then
    category := 'incidente'; severity := 'aviso';
  elsif p_action like 'retencao%' or p_action like 'seguranca.%' then
    category := 'auditoria'; severity := 'critico';
  elsif p_action like 'auditoria.descarte_%' then
    category := 'auditoria'; severity := 'critico';
  elsif p_action like 'auditoria.%' then
    category := 'auditoria';
    severity := case when p_action in ('auditoria.exportada', 'auditoria.integridade_verificada', 'auditoria.ancora_conferida') then 'critico' else 'aviso' end;
  elsif p_action in ('me.assinatura_consultada', 'me.foto_consultada') then
    category := 'privacidade'; severity := 'aviso';
  elsif p_action like 'exportacao.%' or p_action in ('me.impressa', 'me.pdf_gerado', 'etiquetas.impressas') then
    category := 'exportacao'; severity := 'aviso';
  elsif p_entity in ('employees', 'materials', 'material_qr_codes', 'contracts', 'sectors', 'service_fronts',
                     'service_orders', 'fixed_assets', 'application_locations', 'accounts', 'material_categories') then
    category := 'cadastro'; severity := 'info';
  else
    category := 'dados'; severity := 'info';
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- 3) Dias úteis
-- ---------------------------------------------------------------------
create or replace function public.is_business_day(p_day date)
returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$
  select extract(isodow from p_day) < 6 and not exists (select 1 from public.business_holidays h where h.day = p_day);
$$;

-- Data em que termina o prazo de N dias úteis contados a partir do dia seguinte a p_from.
create or replace function public.business_days_add(p_from date, p_days integer)
returns date
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare
  d date := p_from;
  n integer := 0;
begin
  if p_from is null or p_days is null then
    return null;
  end if;
  while n < p_days loop
    d := d + 1;
    if public.is_business_day(d) then
      n := n + 1;
    end if;
  end loop;
  return d;
end;
$$;

-- Dias úteis de p_from (exclusive) até p_to (inclusive); negativo quando p_to já passou.
create or replace function public.business_days_between(p_from date, p_to date)
returns integer
language sql stable security definer
set search_path = public, pg_temp
as $$
  select case
    when p_from is null or p_to is null then null
    when p_to >= p_from then (select count(*)::int from generate_series(p_from + 1, p_to, interval '1 day') g where public.is_business_day(g::date))
    else -(select count(*)::int from generate_series(p_to + 1, p_from, interval '1 day') g where public.is_business_day(g::date))
  end;
$$;

-- ---------------------------------------------------------------------
-- 4) Prazos de um incidente
-- ---------------------------------------------------------------------
create or replace function public._incident_deadlines(i public.security_incidents)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare
  v_tz      text := coalesce((public.get_settings()).timezone, 'America/Recife');
  v_small   boolean := (select small_agent from public.privacy_settings where id);
  v_mult    integer := case when v_small then 2 else 1 end;
  v_today   date := (now() at time zone v_tz)::date;
  v_start   date := (i.personal_data_known_at at time zone v_tz)::date;
  v_applies boolean := i.personal_data_known_at is not null and i.risk_level <> 'sem_risco_relevante';
  v_anpd    date;
  v_tit     date;
  v_decl    date;
  v_compl   date;
  v_anpd_done date := (i.anpd_communicated_at at time zone v_tz)::date;
  v_tit_done  date := (i.titulares_communicated_at at time zone v_tz)::date;
begin
  if v_applies then
    v_anpd := public.business_days_add(v_start, 3 * v_mult);
    v_tit  := public.business_days_add(v_start, 3 * v_mult);
    v_decl := public.business_days_add(v_tit, 3);
  end if;
  if v_anpd_done is not null then
    v_compl := public.business_days_add(v_anpd_done, 20 * v_mult);
  end if;
  return jsonb_build_object(
    'aplica', v_applies,
    'motivo', case
      when i.personal_data_known_at is null then 'Informe quando se soube que o incidente afetou dados pessoais'
      when i.risk_level = 'sem_risco_relevante' then 'Avaliado como sem risco ou dano relevante: comunicação não obrigatória (registre o motivo)'
      when i.risk_level = 'a_avaliar' then 'Risco ainda não avaliado: os prazos já estão correndo'
    end,
    'pequeno_porte', v_small,
    'multiplicador', v_mult,
    'hoje', v_today,
    'anpd_prazo', v_anpd,
    'anpd_dias_restantes', case when v_applies and v_anpd_done is null then public.business_days_between(v_today, v_anpd) end,
    'anpd_situacao', case when not v_applies then null
                          when v_anpd_done is not null then case when v_anpd_done <= v_anpd then 'cumprido' else 'cumprido_com_atraso' end
                          when v_today > v_anpd then 'atrasado' else 'pendente' end,
    'titulares_prazo', v_tit,
    'titulares_dias_restantes', case when v_applies and v_tit_done is null then public.business_days_between(v_today, v_tit) end,
    'titulares_situacao', case when not v_applies then null
                               when v_tit_done is not null then case when v_tit_done <= v_tit then 'cumprido' else 'cumprido_com_atraso' end
                               when v_today > v_tit then 'atrasado' else 'pendente' end,
    'declaracao_prazo', v_decl,
    'complementacao_prazo', v_compl
  );
end;
$$;

create or replace function public._incident_view(i public.security_incidents)
returns jsonb
language sql stable security definer
set search_path = public, pg_temp
as $$
  select to_jsonb(i)
    || jsonb_build_object(
      'created_by_name', (select full_name from public.profiles where id = i.created_by),
      'updated_by_name', (select full_name from public.profiles where id = i.updated_by),
      'closed_by_name',  (select full_name from public.profiles where id = i.closed_by),
      'prazos', public._incident_deadlines(i));
$$;

-- ---------------------------------------------------------------------
-- 5) Configuração LGPD e feriados
-- ---------------------------------------------------------------------
create or replace function public.incident_overview()
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
begin
  if not public.is_admin() then
    raise exception 'Somente o administrador acessa os incidentes de segurança.' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'settings', (select to_jsonb(s) - 'id' || jsonb_build_object('updated_by_name', (select full_name from public.profiles where id = s.updated_by))
                   from public.privacy_settings s where s.id),
    'holidays', coalesce((select jsonb_agg(to_jsonb(h) - 'created_by' order by h.day) from public.business_holidays h
                           where h.day >= current_date - 31), '[]'),
    'incidents', coalesce((select jsonb_agg(public._incident_view(i) order by (i.status = 'encerrado'), i.created_at desc)
                            from public.security_incidents i), '[]'),
    'open_alerts', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'title', a.title, 'severity', a.severity, 'created_at', a.created_at) order by a.created_at desc)
                              from public.security_alerts a where a.status <> 'encerrado'), '[]'));
end;
$$;

create or replace function public.privacy_settings_update(p jsonb)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_old public.privacy_settings;
  v_new public.privacy_settings;
  v_changed text[];
  k text;
begin
  if not public.is_admin() then
    raise exception 'Somente o administrador altera a configuração LGPD.' using errcode = '42501';
  end if;
  select * into v_old from public.privacy_settings where id for update;
  v_new := v_old;
  if p ? 'controller_name' then v_new.controller_name := nullif(btrim(left(p ->> 'controller_name', 200)), ''); end if;
  if p ? 'controller_doc'  then v_new.controller_doc  := nullif(btrim(left(p ->> 'controller_doc', 40)), ''); end if;
  if p ? 'dpo_name'        then v_new.dpo_name        := nullif(btrim(left(p ->> 'dpo_name', 200)), ''); end if;
  if p ? 'dpo_contact'     then v_new.dpo_contact     := nullif(btrim(left(p ->> 'dpo_contact', 200)), ''); end if;
  if p ? 'small_agent'     then v_new.small_agent     := (p ->> 'small_agent')::boolean; end if;
  select array_agg(key order by key) into v_changed
    from jsonb_each(to_jsonb(v_new)) n
   where key in ('controller_name', 'controller_doc', 'dpo_name', 'dpo_contact', 'small_agent')
     and n.value is distinct from to_jsonb(v_old) -> key;
  if v_changed is null then
    return;
  end if;
  update public.privacy_settings
     set controller_name = v_new.controller_name, controller_doc = v_new.controller_doc,
         dpo_name = v_new.dpo_name, dpo_contact = v_new.dpo_contact, small_agent = v_new.small_agent,
         updated_by = auth.uid(), updated_at = now()
   where id;
  -- Na trilha vão só os nomes dos campos (o nome do encarregado é dado pessoal)
  perform public.audit_event('privacidade.configuracao_alterada', 'privacy_settings', null, null, null, null,
    jsonb_build_object('campos', v_changed, 'pequeno_porte', v_new.small_agent));
end;
$$;

create or replace function public.holiday_add(p_day date, p_name text, p_scope text)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  if not public.is_admin() then
    raise exception 'Somente o administrador cadastra feriados.' using errcode = '42501';
  end if;
  if p_day is null or length(btrim(coalesce(p_name, ''))) < 2 then
    raise exception 'Informe a data e o nome do feriado.' using errcode = 'P0001';
  end if;
  if coalesce(p_scope, '') not in ('nacional', 'estadual', 'municipal', 'empresa') then
    raise exception 'Abrangência inválida.' using errcode = 'P0001';
  end if;
  insert into public.business_holidays (day, name, scope, created_by)
  values (p_day, btrim(left(p_name, 120)), p_scope, auth.uid())
  on conflict (day) do update set name = excluded.name, scope = excluded.scope;
  perform public.audit_event('privacidade.feriado_cadastrado', 'business_holidays', p_day::text, null, null, null,
    jsonb_build_object('data', p_day, 'nome', btrim(left(p_name, 120)), 'abrangencia', p_scope));
end;
$$;

create or replace function public.holiday_remove(p_day date)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v public.business_holidays;
begin
  if not public.is_admin() then
    raise exception 'Somente o administrador remove feriados.' using errcode = '42501';
  end if;
  delete from public.business_holidays where day = p_day returning * into v;
  if v.day is null then
    raise exception 'Feriado não encontrado.' using errcode = 'P0001';
  end if;
  perform public.audit_event('privacidade.feriado_removido', 'business_holidays', p_day::text, null, null,
    jsonb_build_object('data', v.day, 'nome', v.name, 'abrangencia', v.scope), null);
end;
$$;

-- ---------------------------------------------------------------------
-- 6) Incidentes
-- ---------------------------------------------------------------------
create or replace function public.incident_open(p jsonb)
returns bigint
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_tz    text := coalesce((public.get_settings()).timezone, 'America/Recife');
  v_title text := btrim(coalesce(p ->> 'title', ''));
  v_known timestamptz := coalesce((p ->> 'known_at')::timestamptz, now());
  v_alert bigint := nullif(p ->> 'alert_id', '')::bigint;
  v_year  integer;
  v_seq   integer;
  v_id    bigint;
  v_code  text;
begin
  if not public.is_admin() then
    raise exception 'Somente o administrador registra incidentes de segurança.' using errcode = '42501';
  end if;
  if length(v_title) not between 5 and 200 then
    raise exception 'Dê um título ao incidente (5 a 200 caracteres).' using errcode = 'P0001';
  end if;
  if v_known > now() + interval '5 minutes' then
    raise exception 'A data de conhecimento não pode estar no futuro.' using errcode = 'P0001';
  end if;
  if v_alert is not null and not exists (select 1 from public.security_alerts where id = v_alert) then
    raise exception 'Alerta não encontrado.' using errcode = 'P0001';
  end if;
  v_year := extract(year from (now() at time zone v_tz))::int;
  perform pg_advisory_xact_lock(704200124);
  select count(*) + 1 into v_seq from public.security_incidents where code like 'INC-' || v_year || '-%';
  v_code := 'INC-' || v_year || '-' || lpad(v_seq::text, 3, '0');

  insert into public.security_incidents (code, title, known_at, description, alert_id, created_by, updated_by)
  values (v_code, v_title, v_known, nullif(btrim(left(p ->> 'description', 5000)), ''), v_alert, auth.uid(), auth.uid())
  returning id into v_id;
  insert into public.security_incident_notes (incident_id, kind, body, created_by)
  values (v_id, 'status', 'Incidente registrado' || case when v_alert is not null then ' a partir do alerta nº ' || v_alert else '' end, auth.uid());

  -- O alerta de origem passa para "em análise"
  if v_alert is not null and exists (select 1 from public.security_alerts where id = v_alert and status = 'aberto') then
    update public.security_alerts set status = 'em_analise', handled_by = auth.uid(), handled_at = now(),
           resolution = coalesce(resolution, 'Tratado como incidente ' || v_code)
     where id = v_alert;
    perform public.audit_event('alerta.atualizado', 'security_alerts', v_alert::text, null, null, null,
      jsonb_build_object('status', 'em_analise', 'incidente', v_code));
  end if;

  perform public.audit_event('incidente.registrado', 'security_incidents', v_code, null, null, null,
    jsonb_build_object('codigo', v_code, 'conhecimento', v_known, 'alerta', v_alert));
  return v_id;
end;
$$;

create or replace function public.incident_get(p_id bigint)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare
  i public.security_incidents;
begin
  if not public.is_admin() then
    raise exception 'Somente o administrador acessa os incidentes de segurança.' using errcode = '42501';
  end if;
  select * into i from public.security_incidents where id = p_id;
  if i.id is null then
    raise exception 'Incidente não encontrado.' using errcode = 'P0001';
  end if;
  return public._incident_view(i) || jsonb_build_object('notes', coalesce((
    select jsonb_agg(jsonb_build_object('id', n.id, 'kind', n.kind, 'body', n.body, 'created_at', n.created_at,
                                        'created_by_name', (select full_name from public.profiles where id = n.created_by)) order by n.created_at, n.id)
      from public.security_incident_notes n where n.incident_id = p_id), '[]'));
end;
$$;

create or replace function public.incident_update(p_id bigint, p jsonb)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_old     public.security_incidents;
  v_new     public.security_incidents;
  v_allowed text[] := array['title', 'status', 'known_at', 'personal_data_known_at', 'occurred_at', 'description',
                             'data_categories', 'data_nature', 'sensitive_data', 'affected_count', 'affected_count_note',
                             'risk_criteria', 'risk_level', 'risk_assessment', 'measures', 'anpd_communicated_at',
                             'anpd_protocol', 'titulares_communicated_at', 'communication_form', 'communication_content',
                             'no_communication_reason'];
  v_texts   text[] := array['title', 'description', 'data_nature', 'affected_count_note', 'risk_assessment', 'measures',
                             'anpd_protocol', 'communication_form', 'communication_content', 'no_communication_reason'];
  v_clean   jsonb := '{}';
  v_changed text[];
  k         text;
  v         jsonb;
  c         text;
  v_limit   timestamptz := now() + interval '5 minutes';
begin
  if not public.is_admin() then
    raise exception 'Somente o administrador altera incidentes de segurança.' using errcode = '42501';
  end if;
  select * into v_old from public.security_incidents where id = p_id for update;
  if v_old.id is null then
    raise exception 'Incidente não encontrado.' using errcode = 'P0001';
  end if;
  if v_old.status = 'encerrado' then
    raise exception 'Incidente encerrado não pode ser alterado; acrescente uma anotação.' using errcode = 'P0001';
  end if;

  for k, v in select * from jsonb_each(coalesce(p, '{}')) loop
    if not (k = any (v_allowed)) then
      raise exception 'Campo não permitido: %', k using errcode = 'P0001';
    end if;
    if jsonb_typeof(v) = 'string' and btrim(v #>> '{}') = '' then
      v := 'null'::jsonb;
    elsif k = any (v_texts) and jsonb_typeof(v) = 'string' then
      v := to_jsonb(btrim(v #>> '{}'));
    end if;
    v_clean := v_clean || jsonb_build_object(k, v);
  end loop;
  v_new := jsonb_populate_record(v_old, v_clean);

  -- Validações
  if length(btrim(coalesce(v_new.title, ''))) not between 5 and 200 then
    raise exception 'Título com 5 a 200 caracteres.' using errcode = 'P0001';
  end if;
  if v_new.status not in ('aberto', 'em_tratamento') then
    raise exception 'Para encerrar, use o botão Encerrar incidente.' using errcode = 'P0001';
  end if;
  if v_new.risk_level not in ('a_avaliar', 'sem_risco_relevante', 'risco_relevante') then
    raise exception 'Nível de risco inválido.' using errcode = 'P0001';
  end if;
  if v_new.known_at is null or greatest(v_new.known_at, coalesce(v_new.personal_data_known_at, v_new.known_at), coalesce(v_new.occurred_at, v_new.known_at),
              coalesce(v_new.anpd_communicated_at, v_new.known_at), coalesce(v_new.titulares_communicated_at, v_new.known_at)) > v_limit then
    raise exception 'As datas não podem estar no futuro.' using errcode = 'P0001';
  end if;
  if v_new.personal_data_known_at < v_new.known_at then
    raise exception 'O conhecimento de que afetou dados pessoais não pode ser anterior ao conhecimento do incidente.' using errcode = 'P0001';
  end if;
  if v_new.occurred_at > v_new.known_at then
    raise exception 'A data de ocorrência não pode ser posterior à de conhecimento.' using errcode = 'P0001';
  end if;
  if (v_new.anpd_communicated_at is not null or v_new.titulares_communicated_at is not null) and v_new.personal_data_known_at is null then
    raise exception 'Informe quando se soube que o incidente afetou dados pessoais antes de registrar comunicações.' using errcode = 'P0001';
  end if;
  if coalesce(array_length(v_new.data_categories, 1), 0) > 20
     or exists (select 1 from unnest(v_new.data_categories) x where length(btrim(x)) not between 1 and 80) then
    raise exception 'Categorias de dados: até 20, com até 80 caracteres cada.' using errcode = 'P0001';
  end if;
  v_new.data_categories := array(select distinct btrim(x) from unnest(v_new.data_categories) x order by 1);
  if exists (select 1 from unnest(v_new.risk_criteria) x
              where x not in ('dados_sensiveis', 'vulneraveis', 'dados_financeiros', 'autenticacao', 'sigilo', 'larga_escala')) then
    raise exception 'Critério de risco inválido.' using errcode = 'P0001';
  end if;
  v_new.risk_criteria := array(select distinct x from unnest(v_new.risk_criteria) x order by 1);
  foreach c in array v_texts loop
    if length(coalesce(to_jsonb(v_new) ->> c, '')) > 5000 then
      raise exception 'Texto longo demais (máximo de 5000 caracteres).' using errcode = 'P0001';
    end if;
  end loop;

  select array_agg(n.key order by n.key) into v_changed
    from jsonb_each(to_jsonb(v_new)) n
   where n.key = any (v_allowed) and n.value is distinct from to_jsonb(v_old) -> n.key;
  if v_changed is null then
    return public._incident_view(v_old);
  end if;

  update public.security_incidents set
    title = v_new.title, status = v_new.status, known_at = v_new.known_at, personal_data_known_at = v_new.personal_data_known_at,
    occurred_at = v_new.occurred_at, description = v_new.description, data_categories = v_new.data_categories,
    data_nature = v_new.data_nature, sensitive_data = v_new.sensitive_data, affected_count = v_new.affected_count,
    affected_count_note = v_new.affected_count_note, risk_criteria = v_new.risk_criteria, risk_level = v_new.risk_level,
    risk_assessment = v_new.risk_assessment, measures = v_new.measures, anpd_communicated_at = v_new.anpd_communicated_at,
    anpd_protocol = v_new.anpd_protocol, titulares_communicated_at = v_new.titulares_communicated_at,
    communication_form = v_new.communication_form, communication_content = v_new.communication_content,
    no_communication_reason = v_new.no_communication_reason, updated_by = auth.uid(), updated_at = now()
  where id = p_id
  returning * into v_new;

  insert into public.security_incident_notes (incident_id, kind, body, created_by)
  values (p_id, case when 'status' = any (v_changed) then 'status' else 'alteracao' end,
          'Campos alterados: ' || (select string_agg(coalesce(('{"title":"título","status":"situação","known_at":"conhecimento do incidente",
             "personal_data_known_at":"conhecimento de dados pessoais afetados","occurred_at":"data de ocorrência","description":"circunstâncias",
             "data_categories":"categorias de dados","data_nature":"natureza dos dados","sensitive_data":"dado sensível",
             "affected_count":"número de titulares","affected_count_note":"observação sobre titulares","risk_criteria":"critérios de risco",
             "risk_level":"conclusão do risco","risk_assessment":"avaliação do risco","measures":"medidas","anpd_communicated_at":"comunicação à ANPD",
             "anpd_protocol":"protocolo da ANPD","titulares_communicated_at":"comunicação aos titulares","communication_form":"forma da comunicação",
             "communication_content":"conteúdo da comunicação","no_communication_reason":"motivo da ausência de comunicação"}'::jsonb ->> fld), fld), ', ')
             from unnest(v_changed) fld)
          || case when 'status' = any (v_changed) then ' (agora: ' || replace(v_new.status, '_', ' ') || ')' else '' end, auth.uid());
  -- Na trilha: só os nomes dos campos e os marcos (o texto do incidente pode conter dados pessoais)
  perform public.audit_event('incidente.atualizado', 'security_incidents', v_new.code, null, null, null,
    jsonb_build_object('campos', v_changed, 'situacao', v_new.status, 'risco', v_new.risk_level,
                       'comunicado_anpd', v_new.anpd_communicated_at, 'comunicado_titulares', v_new.titulares_communicated_at));
  return public._incident_view(v_new);
end;
$$;

create or replace function public.incident_add_note(p_id bigint, p_body text)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_code text;
begin
  if not public.is_admin() then
    raise exception 'Somente o administrador anota incidentes.' using errcode = '42501';
  end if;
  select code into v_code from public.security_incidents where id = p_id;
  if v_code is null then
    raise exception 'Incidente não encontrado.' using errcode = 'P0001';
  end if;
  if length(btrim(coalesce(p_body, ''))) not between 3 and 5000 then
    raise exception 'Escreva a anotação (3 a 5000 caracteres).' using errcode = 'P0001';
  end if;
  insert into public.security_incident_notes (incident_id, kind, body, created_by) values (p_id, 'nota', btrim(p_body), auth.uid());
  perform public.audit_event('incidente.anotado', 'security_incidents', v_code, null, null, null, jsonb_build_object('codigo', v_code));
end;
$$;

create or replace function public.incident_close(p_id bigint, p_note text)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  i public.security_incidents;
  v_missing text[] := '{}';
begin
  if not public.is_admin() then
    raise exception 'Somente o administrador encerra incidentes.' using errcode = '42501';
  end if;
  select * into i from public.security_incidents where id = p_id for update;
  if i.id is null then
    raise exception 'Incidente não encontrado.' using errcode = 'P0001';
  end if;
  if i.status = 'encerrado' then
    raise exception 'Incidente já encerrado.' using errcode = 'P0001';
  end if;
  if length(btrim(coalesce(p_note, ''))) < 10 then
    raise exception 'Descreva o encerramento (mínimo de 10 caracteres).' using errcode = 'P0001';
  end if;
  -- Campos mínimos do art. 10, § 1º, da Res. CD/ANPD 15/2024
  if i.description is null then v_missing := array_append(v_missing, 'descrição das circunstâncias (II)'); end if;
  if coalesce(array_length(i.data_categories, 1), 0) = 0 and i.data_nature is null then
    v_missing := array_append(v_missing, 'natureza e categoria dos dados (III)');
  end if;
  if i.affected_count is null and i.affected_count_note is null then v_missing := array_append(v_missing, 'número de titulares (IV)'); end if;
  if i.risk_level = 'a_avaliar' or i.risk_assessment is null then v_missing := array_append(v_missing, 'avaliação do risco (V)'); end if;
  if i.risk_level = 'risco_relevante' then
    if i.personal_data_known_at is null then v_missing := array_append(v_missing, 'data em que se soube que afetou dados pessoais'); end if;
    if i.anpd_communicated_at is null then v_missing := array_append(v_missing, 'data da comunicação à ANPD (VII)'); end if;
    if i.titulares_communicated_at is null then v_missing := array_append(v_missing, 'data da comunicação aos titulares (VII)'); end if;
    if i.communication_form is null then v_missing := array_append(v_missing, 'forma da comunicação (VII)'); end if;
  elsif i.risk_level = 'sem_risco_relevante' and coalesce(length(i.no_communication_reason), 0) < 10 then
    v_missing := array_append(v_missing, 'motivo da ausência de comunicação (VIII)');
  end if;
  if cardinality(v_missing) > 0 then
    raise exception 'Para encerrar, preencha: %.', array_to_string(v_missing, '; ') using errcode = 'P0001';
  end if;

  update public.security_incidents
     set status = 'encerrado', closed_by = auth.uid(), closed_at = now(), closing_note = btrim(left(p_note, 2000)),
         updated_by = auth.uid(), updated_at = now()
   where id = p_id;
  insert into public.security_incident_notes (incident_id, kind, body, created_by)
  values (p_id, 'status', 'Incidente encerrado: ' || btrim(left(p_note, 2000)), auth.uid());
  perform public.audit_event('incidente.encerrado', 'security_incidents', i.code, null, null, null,
    jsonb_build_object('codigo', i.code, 'risco', i.risk_level, 'prazos', public._incident_deadlines(i)));
end;
$$;

-- ---------------------------------------------------------------------
-- Verificações periódicas: inclui os prazos dos incidentes
-- ---------------------------------------------------------------------
create or replace function public._security_checks()
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_chain   jsonb;
  v_last    timestamptz;
  v_imp     integer;
  v_alerts  integer := 0;
  p         record;
  i         public.security_incidents;
  d         jsonb;
  v_due     bigint;
begin
  v_imp := public.security_import_auth_events();

  v_chain := public._audit_verify(null);
  if not (v_chain ->> 'ok')::boolean then
    perform public._raise_alert('integridade', 'critico', 'A verificação de integridade da auditoria falhou',
      coalesce(v_chain ->> 'problem_seq', ''), v_chain);
    v_alerts := v_alerts + 1;
  end if;

  select max(occurred_at) into v_last from public.audit_logs where category is distinct from 'auditoria';
  if v_last is null or v_last < now() - interval '72 hours' then
    perform public._raise_alert('coleta_parada', 'aviso', 'Nenhum evento de operação registrado há mais de 72 horas', '',
      jsonb_build_object('ultimo_evento', v_last));
    v_alerts := v_alerts + 1;
  end if;

  for p in select * from public.audit_retention_policies where status = 'aprovada' and retain_days is not null loop
    select count(*) into v_due from public.audit_logs
     where category = p.category and purged_at is null
       and occurred_at < now() - make_interval(days => greatest(p.retain_days - 30, 0));
    if v_due > 0 then
      perform public._raise_alert('retencao_vencendo', 'aviso',
        'Eventos de ' || p.category || ' chegando ao fim do prazo de retenção', p.category,
        jsonb_build_object('categoria', p.category, 'eventos', v_due, 'prazo_dias', p.retain_days));
      v_alerts := v_alerts + 1;
    end if;
  end loop;

  -- Incidentes: prazo de comunicação vencendo (até 1 dia útil) ou vencido; risco sem avaliação
  for i in select * from public.security_incidents where status <> 'encerrado' loop
    d := public._incident_deadlines(i);
    if (d ->> 'aplica')::boolean and i.anpd_communicated_at is null and (d ->> 'anpd_dias_restantes')::int <= 1 then
      perform public._raise_alert('incidente_prazo', 'critico',
        'Incidente ' || i.code || ': prazo de comunicação à ANPD ' ||
        case when (d ->> 'anpd_dias_restantes')::int < 0 then 'VENCIDO em ' else 'vence em ' end || to_char((d ->> 'anpd_prazo')::date, 'DD/MM/YYYY'),
        'anpd:' || i.id, jsonb_build_object('incidente', i.code, 'prazo', d ->> 'anpd_prazo', 'dias_uteis_restantes', d -> 'anpd_dias_restantes'));
      v_alerts := v_alerts + 1;
    end if;
    if (d ->> 'aplica')::boolean and i.titulares_communicated_at is null and (d ->> 'titulares_dias_restantes')::int <= 1 then
      perform public._raise_alert('incidente_prazo', 'critico',
        'Incidente ' || i.code || ': prazo de comunicação aos titulares ' ||
        case when (d ->> 'titulares_dias_restantes')::int < 0 then 'VENCIDO em ' else 'vence em ' end || to_char((d ->> 'titulares_prazo')::date, 'DD/MM/YYYY'),
        'titulares:' || i.id, jsonb_build_object('incidente', i.code, 'prazo', d ->> 'titulares_prazo', 'dias_uteis_restantes', d -> 'titulares_dias_restantes'));
      v_alerts := v_alerts + 1;
    end if;
    if i.risk_level = 'a_avaliar' and i.known_at < now() - interval '24 hours' then
      perform public._raise_alert('incidente_sem_avaliacao', 'aviso',
        'Incidente ' || i.code || ' sem avaliação de risco há mais de 24 horas', i.id::text,
        jsonb_build_object('incidente', i.code));
      v_alerts := v_alerts + 1;
    end if;
  end loop;

  insert into public.security_state (key, value, updated_at)
  values ('last_checks', jsonb_build_object('at', now(), 'integridade', v_chain -> 'ok', 'importados_auth', v_imp, 'alertas', v_alerts), now())
  on conflict (key) do update set value = excluded.value, updated_at = now();

  return jsonb_build_object('integridade', v_chain, 'importados_auth', v_imp, 'alertas', v_alerts, 'at', now());
end;
$$;

-- ---------------------------------------------------------------------
-- 7) Permissões
-- ---------------------------------------------------------------------
revoke all on function public.tg_block_incident_delete() from public, anon, authenticated;
revoke all on function public._incident_deadlines(public.security_incidents) from public, anon, authenticated;
revoke all on function public._incident_view(public.security_incidents) from public, anon, authenticated;
revoke all on function public._security_checks() from public, anon, authenticated;
do $$
declare f text;
begin
  foreach f in array array['is_business_day(date)', 'business_days_add(date, integer)', 'business_days_between(date, date)',
                           'incident_overview()', 'privacy_settings_update(jsonb)', 'holiday_add(date, text, text)',
                           'holiday_remove(date)', 'incident_open(jsonb)', 'incident_get(bigint)', 'incident_update(bigint, jsonb)',
                           'incident_add_note(bigint, text)', 'incident_close(bigint, text)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;


-- >>>>>>>>>> 07h_pedidos_titulares.sql
-- =====================================================================
-- 25 - PEDIDOS DE TITULARES (LGPD art. 18) - fase 4 do plano
--
-- * Registro dos pedidos dos titulares (colaboradores): direitos do art. 18
--   pedidos, canal, conferência de identidade, prazo, resposta e histórico.
--   Pedidos nunca são apagados.
-- * Prazo de resposta configurável (padrão 15 dias corridos, referência do
--   art. 19, II - declaração completa de confirmação/acesso). Para os demais
--   direitos não há prazo regulamentado: o padrão é o mesmo, a validar.
-- * Relatório "o que o sistema guarda sobre este funcionário" (apoio ao
--   direito de acesso), registrado na auditoria.
-- * Canal de atendimento (D6) fica "a definir" até a empresa decidir.
-- * Alerta de prazo de resposta vencendo/vencido.
--
-- A minimização e a validade da cópia offline do tablet ficam no site
-- (só nome e matrícula; 7 dias; apagada ao sair).
--
-- Pré-requisito: 24. Pode ser reexecutado.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) Tabelas
-- ---------------------------------------------------------------------
alter table public.privacy_settings add column if not exists titular_channel text;
alter table public.privacy_settings add column if not exists titular_response_days integer not null default 15;
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'privacy_settings_titular_days_ck') then
    alter table public.privacy_settings add constraint privacy_settings_titular_days_ck check (titular_response_days between 1 and 90);
  end if;
end $$;

create table if not exists public.data_subject_requests (
  id                      bigint generated always as identity primary key,
  code                    text not null unique,
  received_at             timestamptz not null,
  channel                 text,
  requester_name          text not null check (length(btrim(requester_name)) between 3 and 160),
  requester_registration  text,
  employee_id             uuid references public.employees (id),
  rights                  text[] not null,
  description             text,
  identity_verified       boolean not null default false,
  identity_method         text,
  status                  text not null default 'recebido'
                          check (status in ('recebido', 'em_analise', 'atendido', 'atendido_parcialmente', 'indeferido')),
  due_date                date not null,
  responded_at            timestamptz,
  response_summary        text,
  denial_reason           text,
  created_by              uuid references public.profiles (id),
  created_at              timestamptz not null default now(),
  updated_by              uuid references public.profiles (id),
  updated_at              timestamptz not null default now(),
  check (cardinality(rights) between 1 and 10)
);
create index if not exists data_subject_requests_status_idx on public.data_subject_requests (status, due_date);

create table if not exists public.data_subject_request_notes (
  id          bigint generated always as identity primary key,
  request_id  bigint not null references public.data_subject_requests (id),
  kind        text not null default 'nota' check (kind in ('nota', 'alteracao', 'status')),
  body        text not null,
  created_by  uuid references public.profiles (id),
  created_at  timestamptz not null default now()
);
create index if not exists data_subject_request_notes_idx on public.data_subject_request_notes (request_id, created_at);

do $$
declare t text;
begin
  foreach t in array array['data_subject_requests', 'data_subject_request_notes'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
  end loop;
end $$;

create or replace function public.tg_block_dsr_delete()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  raise exception 'Pedidos de titulares e o histórico deles não podem ser excluídos.' using errcode = 'P0001';
end;
$$;
drop trigger if exists block_delete on public.data_subject_requests;
create trigger block_delete before delete on public.data_subject_requests
  for each row execute function public.tg_block_dsr_delete();
drop trigger if exists block_change on public.data_subject_request_notes;
create trigger block_change before update or delete on public.data_subject_request_notes
  for each row execute function public.tg_block_dsr_delete();

-- ---------------------------------------------------------------------
-- 2) Classificação (titular.* = privacidade) e configuração do canal (D6)
-- ---------------------------------------------------------------------
create or replace function public.audit_classify(p_action text, p_entity text, out category text, out severity text)
language plpgsql immutable
set search_path = public, pg_temp
as $$
begin
  if p_action like 'auth.%' then
    category := 'autenticacao'; severity := 'aviso';
  elsif p_action like 'acesso.%' then
    category := 'autorizacao'; severity := 'aviso';
  elsif p_entity in ('user_roles', 'user_warehouses', 'profiles') or p_action like 'usuario.%' then
    category := 'permissao'; severity := 'critico';
  elsif p_entity in ('app_settings', 'warehouses') then
    category := 'configuracao'; severity := 'critico';
  elsif p_action like 'incidente.%' then
    category := 'incidente'; severity := 'critico';
  elsif p_action like 'titular.%' then
    category := 'privacidade'; severity := 'aviso';
  elsif p_action like 'privacidade.%' then
    category := 'configuracao'; severity := 'critico';
  elsif p_action like 'alerta.%' then
    category := 'incidente'; severity := 'aviso';
  elsif p_action like 'retencao%' or p_action like 'seguranca.%' then
    category := 'auditoria'; severity := 'critico';
  elsif p_action like 'auditoria.descarte_%' then
    category := 'auditoria'; severity := 'critico';
  elsif p_action like 'auditoria.%' then
    category := 'auditoria';
    severity := case when p_action in ('auditoria.exportada', 'auditoria.integridade_verificada', 'auditoria.ancora_conferida') then 'critico' else 'aviso' end;
  elsif p_action in ('me.assinatura_consultada', 'me.foto_consultada') then
    category := 'privacidade'; severity := 'aviso';
  elsif p_action like 'exportacao.%' or p_action in ('me.impressa', 'me.pdf_gerado', 'etiquetas.impressas') then
    category := 'exportacao'; severity := 'aviso';
  elsif p_entity in ('employees', 'materials', 'material_qr_codes', 'contracts', 'sectors', 'service_fronts',
                     'service_orders', 'fixed_assets', 'application_locations', 'accounts', 'material_categories') then
    category := 'cadastro'; severity := 'info';
  else
    category := 'dados'; severity := 'info';
  end if;
end;
$$;

create or replace function public.privacy_settings_update(p jsonb)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_old public.privacy_settings;
  v_new public.privacy_settings;
  v_changed text[];
  k text;
begin
  if not public.is_admin() then
    raise exception 'Somente o administrador altera a configuração LGPD.' using errcode = '42501';
  end if;
  select * into v_old from public.privacy_settings where id for update;
  v_new := v_old;
  if p ? 'controller_name' then v_new.controller_name := nullif(btrim(left(p ->> 'controller_name', 200)), ''); end if;
  if p ? 'controller_doc'  then v_new.controller_doc  := nullif(btrim(left(p ->> 'controller_doc', 40)), ''); end if;
  if p ? 'dpo_name'        then v_new.dpo_name        := nullif(btrim(left(p ->> 'dpo_name', 200)), ''); end if;
  if p ? 'dpo_contact'     then v_new.dpo_contact     := nullif(btrim(left(p ->> 'dpo_contact', 200)), ''); end if;
  if p ? 'small_agent'     then v_new.small_agent     := (p ->> 'small_agent')::boolean; end if;
  if p ? 'titular_channel' then v_new.titular_channel := nullif(btrim(left(p ->> 'titular_channel', 300)), ''); end if;
  if p ? 'titular_response_days' then
    v_new.titular_response_days := coalesce((p ->> 'titular_response_days')::int, 15);
    if v_new.titular_response_days not between 1 and 90 then
      raise exception 'Prazo de resposta entre 1 e 90 dias.' using errcode = 'P0001';
    end if;
  end if;
  select array_agg(key order by key) into v_changed
    from jsonb_each(to_jsonb(v_new)) n
   where key in ('controller_name', 'controller_doc', 'dpo_name', 'dpo_contact', 'small_agent', 'titular_channel', 'titular_response_days')
     and n.value is distinct from to_jsonb(v_old) -> key;
  if v_changed is null then
    return;
  end if;
  update public.privacy_settings
     set controller_name = v_new.controller_name, controller_doc = v_new.controller_doc,
         dpo_name = v_new.dpo_name, dpo_contact = v_new.dpo_contact, small_agent = v_new.small_agent,
         titular_channel = v_new.titular_channel, titular_response_days = v_new.titular_response_days,
         updated_by = auth.uid(), updated_at = now()
   where id;
  -- Na trilha vão só os nomes dos campos (o nome do encarregado é dado pessoal)
  perform public.audit_event('privacidade.configuracao_alterada', 'privacy_settings', null, null, null, null,
    jsonb_build_object('campos', v_changed, 'pequeno_porte', v_new.small_agent));
end;
$$;

-- ---------------------------------------------------------------------
-- 3) Funções
-- ---------------------------------------------------------------------
-- Direitos do art. 18 (I a IX) e oposição (§ 2º)
create or replace function public._dsr_valid_rights(p text[])
returns boolean
language sql immutable
set search_path = public, pg_temp
as $$
  select coalesce(cardinality(p), 0) between 1 and 10
     and not exists (select 1 from unnest(p) r where r not in (
       'confirmacao', 'acesso', 'correcao', 'anonimizacao_bloqueio_eliminacao', 'portabilidade',
       'eliminacao_consentimento', 'info_compartilhamento', 'info_nao_consentir', 'revogacao_consentimento', 'oposicao'));
$$;

create or replace function public._dsr_view(r public.data_subject_requests)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare
  v_tz    text := coalesce((public.get_settings()).timezone, 'America/Recife');
  v_today date := (now() at time zone v_tz)::date;
  v_open  boolean := r.status in ('recebido', 'em_analise');
  v_done  date := (r.responded_at at time zone v_tz)::date;
begin
  return to_jsonb(r) || jsonb_build_object(
    'created_by_name', (select full_name from public.profiles where id = r.created_by),
    'updated_by_name', (select full_name from public.profiles where id = r.updated_by),
    'employee', (select jsonb_build_object('id', e.id, 'registration', e.registration, 'full_name', e.full_name)
                   from public.employees e where e.id = r.employee_id),
    'dias_restantes', case when v_open then r.due_date - v_today end,
    'situacao_prazo', case
      when v_open and v_today > r.due_date then 'atrasado'
      when v_open then 'pendente'
      when v_done <= r.due_date then 'cumprido'
      else 'cumprido_com_atraso' end);
end;
$$;

create or replace function public.dsr_overview()
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
begin
  if not public.is_admin() then
    raise exception 'Somente o administrador acessa os pedidos de titulares.' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'settings', (select jsonb_build_object('titular_channel', s.titular_channel, 'titular_response_days', s.titular_response_days,
                                           'dpo_name', s.dpo_name, 'dpo_contact', s.dpo_contact)
                   from public.privacy_settings s where s.id),
    'requests', coalesce((select jsonb_agg(public._dsr_view(r) order by (r.status in ('recebido', 'em_analise')) desc, r.due_date, r.id desc)
                           from public.data_subject_requests r), '[]'));
end;
$$;

create or replace function public.dsr_open(p jsonb)
returns bigint
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_tz     text := coalesce((public.get_settings()).timezone, 'America/Recife');
  v_days   integer := (select titular_response_days from public.privacy_settings where id);
  v_recv   timestamptz := coalesce(nullif(p ->> 'received_at', '')::timestamptz, now());
  v_name   text := btrim(coalesce(p ->> 'requester_name', ''));
  v_reg    text := nullif(btrim(left(coalesce(p ->> 'requester_registration', ''), 30)), '');
  v_emp    uuid := nullif(p ->> 'employee_id', '')::uuid;
  v_rights text[] := array(select distinct jsonb_array_elements_text(coalesce(p -> 'rights', '[]')) order by 1);
  v_year   integer;
  v_seq    integer;
  v_code   text;
  v_id     bigint;
begin
  if not public.is_admin() then
    raise exception 'Somente o administrador registra pedidos de titulares.' using errcode = '42501';
  end if;
  if length(v_name) not between 3 and 160 then
    raise exception 'Informe o nome de quem fez o pedido.' using errcode = 'P0001';
  end if;
  if not public._dsr_valid_rights(v_rights) then
    raise exception 'Escolha ao menos um direito pedido (art. 18).' using errcode = 'P0001';
  end if;
  if v_recv > now() + interval '5 minutes' then
    raise exception 'A data do pedido não pode estar no futuro.' using errcode = 'P0001';
  end if;
  if v_emp is not null and not exists (select 1 from public.employees where id = v_emp) then
    raise exception 'Funcionário não encontrado.' using errcode = 'P0001';
  end if;
  if v_emp is null and v_reg is not null then
    select id into v_emp from public.employees where registration = v_reg;
  end if;

  v_year := extract(year from (now() at time zone v_tz))::int;
  perform pg_advisory_xact_lock(704200125);
  select count(*) + 1 into v_seq from public.data_subject_requests where code like 'SOL-' || v_year || '-%';
  v_code := 'SOL-' || v_year || '-' || lpad(v_seq::text, 3, '0');

  insert into public.data_subject_requests (code, received_at, channel, requester_name, requester_registration, employee_id,
                                            rights, description, due_date, created_by, updated_by)
  values (v_code, v_recv, nullif(btrim(left(coalesce(p ->> 'channel', ''), 200)), ''), v_name, v_reg, v_emp, v_rights,
          nullif(btrim(left(coalesce(p ->> 'description', ''), 5000)), ''),
          (v_recv at time zone v_tz)::date + v_days, auth.uid(), auth.uid())
  returning id into v_id;
  insert into public.data_subject_request_notes (request_id, kind, body, created_by)
  values (v_id, 'status', 'Pedido registrado; prazo de resposta: ' || v_days || ' dias', auth.uid());
  -- Na trilha: código e direitos (sem o nome de quem pediu)
  perform public.audit_event('titular.pedido_registrado', 'data_subject_requests', v_code, null, null, null,
    jsonb_build_object('codigo', v_code, 'direitos', v_rights, 'vinculado_a_funcionario', v_emp is not null));
  return v_id;
end;
$$;

create or replace function public.dsr_get(p_id bigint)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare
  r public.data_subject_requests;
begin
  if not public.is_admin() then
    raise exception 'Somente o administrador acessa os pedidos de titulares.' using errcode = '42501';
  end if;
  select * into r from public.data_subject_requests where id = p_id;
  if r.id is null then
    raise exception 'Pedido não encontrado.' using errcode = 'P0001';
  end if;
  return public._dsr_view(r) || jsonb_build_object('notes', coalesce((
    select jsonb_agg(jsonb_build_object('id', n.id, 'kind', n.kind, 'body', n.body, 'created_at', n.created_at,
                                        'created_by_name', (select full_name from public.profiles where id = n.created_by)) order by n.created_at, n.id)
      from public.data_subject_request_notes n where n.request_id = p_id), '[]'));
end;
$$;

create or replace function public.dsr_update(p_id bigint, p jsonb)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  r        public.data_subject_requests;
  v_new    public.data_subject_requests;
  v_changed text[] := '{}';
begin
  if not public.is_admin() then
    raise exception 'Somente o administrador altera pedidos de titulares.' using errcode = '42501';
  end if;
  select * into r from public.data_subject_requests where id = p_id for update;
  if r.id is null then
    raise exception 'Pedido não encontrado.' using errcode = 'P0001';
  end if;
  if r.status not in ('recebido', 'em_analise') then
    raise exception 'Pedido já respondido; acrescente uma anotação.' using errcode = 'P0001';
  end if;
  v_new := r;
  if p ? 'status' then
    if p ->> 'status' not in ('recebido', 'em_analise') then
      raise exception 'Para responder, use o botão Registrar resposta.' using errcode = 'P0001';
    end if;
    v_new.status := p ->> 'status';
  end if;
  if p ? 'rights' then
    v_new.rights := array(select distinct jsonb_array_elements_text(coalesce(p -> 'rights', '[]')) order by 1);
    if not public._dsr_valid_rights(v_new.rights) then
      raise exception 'Escolha ao menos um direito pedido (art. 18).' using errcode = 'P0001';
    end if;
  end if;
  if p ? 'employee_id' then
    v_new.employee_id := nullif(p ->> 'employee_id', '')::uuid;
    if v_new.employee_id is not null and not exists (select 1 from public.employees where id = v_new.employee_id) then
      raise exception 'Funcionário não encontrado.' using errcode = 'P0001';
    end if;
  end if;
  if p ? 'channel' then v_new.channel := nullif(btrim(left(coalesce(p ->> 'channel', ''), 200)), ''); end if;
  if p ? 'description' then v_new.description := nullif(btrim(left(coalesce(p ->> 'description', ''), 5000)), ''); end if;
  if p ? 'identity_verified' then v_new.identity_verified := coalesce((p ->> 'identity_verified')::boolean, false); end if;
  if p ? 'identity_method' then v_new.identity_method := nullif(btrim(left(coalesce(p ->> 'identity_method', ''), 500)), ''); end if;
  if v_new.identity_verified and v_new.identity_method is null then
    raise exception 'Descreva como a identidade foi conferida.' using errcode = 'P0001';
  end if;

  select array_agg(n.key order by n.key) into v_changed
    from jsonb_each(to_jsonb(v_new)) n
   where n.key in ('status', 'rights', 'employee_id', 'channel', 'description', 'identity_verified', 'identity_method')
     and n.value is distinct from to_jsonb(r) -> n.key;
  if v_changed is null then
    return;
  end if;
  update public.data_subject_requests
     set status = v_new.status, rights = v_new.rights, employee_id = v_new.employee_id, channel = v_new.channel,
         description = v_new.description, identity_verified = v_new.identity_verified, identity_method = v_new.identity_method,
         updated_by = auth.uid(), updated_at = now()
   where id = p_id;
  insert into public.data_subject_request_notes (request_id, kind, body, created_by)
  values (p_id, case when 'status' = any (v_changed) then 'status' else 'alteracao' end,
          'Alterado: ' || (select string_agg(coalesce(('{"status":"situação","rights":"direitos pedidos","employee_id":"funcionário vinculado",
             "channel":"canal","description":"descrição","identity_verified":"identidade conferida","identity_method":"forma de conferência"}'::jsonb ->> fld), fld), ', ')
             from unnest(v_changed) fld), auth.uid());
  perform public.audit_event('titular.pedido_atualizado', 'data_subject_requests', r.code, null, null, null,
    jsonb_build_object('codigo', r.code, 'campos', v_changed, 'situacao', v_new.status, 'identidade_conferida', v_new.identity_verified));
end;
$$;

create or replace function public.dsr_respond(p_id bigint, p_outcome text, p_summary text, p_denial_reason text)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  r public.data_subject_requests;
begin
  if not public.is_admin() then
    raise exception 'Somente o administrador responde pedidos de titulares.' using errcode = '42501';
  end if;
  select * into r from public.data_subject_requests where id = p_id for update;
  if r.id is null then
    raise exception 'Pedido não encontrado.' using errcode = 'P0001';
  end if;
  if r.status not in ('recebido', 'em_analise') then
    raise exception 'Pedido já respondido.' using errcode = 'P0001';
  end if;
  if coalesce(p_outcome, '') not in ('atendido', 'atendido_parcialmente', 'indeferido') then
    raise exception 'Resultado inválido.' using errcode = 'P0001';
  end if;
  if not r.identity_verified then
    raise exception 'Confira e registre a identidade de quem pediu antes de responder.' using errcode = 'P0001';
  end if;
  if length(btrim(coalesce(p_summary, ''))) < 10 then
    raise exception 'Resuma a resposta dada (mínimo de 10 caracteres).' using errcode = 'P0001';
  end if;
  if p_outcome <> 'atendido' and length(btrim(coalesce(p_denial_reason, ''))) < 10 then
    raise exception 'Explique o motivo de não atender (art. 18, § 4º; mínimo de 10 caracteres).' using errcode = 'P0001';
  end if;
  update public.data_subject_requests
     set status = p_outcome, responded_at = now(), response_summary = btrim(left(p_summary, 5000)),
         denial_reason = case when p_outcome <> 'atendido' then btrim(left(p_denial_reason, 5000)) end,
         updated_by = auth.uid(), updated_at = now()
   where id = p_id;
  insert into public.data_subject_request_notes (request_id, kind, body, created_by)
  values (p_id, 'status', 'Resposta registrada: ' || replace(p_outcome, '_', ' '), auth.uid());
  perform public.audit_event('titular.pedido_respondido', 'data_subject_requests', r.code, null, null, null,
    jsonb_build_object('codigo', r.code, 'resultado', p_outcome, 'no_prazo', (now() at time zone coalesce((public.get_settings()).timezone, 'America/Recife'))::date <= r.due_date));
end;
$$;

create or replace function public.dsr_add_note(p_id bigint, p_body text)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_code text;
begin
  if not public.is_admin() then
    raise exception 'Somente o administrador anota pedidos de titulares.' using errcode = '42501';
  end if;
  select code into v_code from public.data_subject_requests where id = p_id;
  if v_code is null then
    raise exception 'Pedido não encontrado.' using errcode = 'P0001';
  end if;
  if length(btrim(coalesce(p_body, ''))) not between 3 and 5000 then
    raise exception 'Escreva a anotação (3 a 5000 caracteres).' using errcode = 'P0001';
  end if;
  insert into public.data_subject_request_notes (request_id, kind, body, created_by) values (p_id, 'nota', btrim(p_body), auth.uid());
  perform public.audit_event('titular.pedido_anotado', 'data_subject_requests', v_code, null, null, null, jsonb_build_object('codigo', v_code));
end;
$$;

-- O que o sistema guarda sobre um funcionário (apoio ao direito de acesso, art. 18, II, e art. 19)
create or replace function public.dsr_employee_report(p_employee_id uuid, p_request_id bigint default null)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  e       public.employees;
  v_tz    text := coalesce((public.get_settings()).timezone, 'America/Recife');
  v_code  text;
  v_out   jsonb;
begin
  if not public.is_admin() then
    raise exception 'Somente o administrador gera o relatório do titular.' using errcode = '42501';
  end if;
  select * into e from public.employees where id = p_employee_id;
  if e.id is null then
    raise exception 'Funcionário não encontrado.' using errcode = 'P0001';
  end if;
  if p_request_id is not null then
    select code into v_code from public.data_subject_requests where id = p_request_id;
    if v_code is null then
      raise exception 'Pedido não encontrado.' using errcode = 'P0001';
    end if;
  end if;

  v_out := jsonb_build_object(
    'gerado_em', now(),
    'pedido', v_code,
    'cadastro', jsonb_build_object(
      'matricula', e.registration, 'nome', e.full_name, 'cargo', e.job_title,
      'setor', (select s.name from public.sectors s where s.id = e.sector_id),
      'ativo', e.active, 'cadastrado_em', e.created_at, 'atualizado_em', e.updated_at),
    'retiradas', coalesce((
      select jsonb_agg(jsonb_build_object(
               'me', m.me_number,
               'data', to_char(m.movement_at at time zone v_tz, 'DD/MM/YYYY HH24:MI'),
               'estoque', w.name,
               'situacao', m.status,
               'emergencial', coalesce(m.is_emergency, false),
               'itens', (select count(*) from public.stock_movement_items i where i.movement_id = m.id),
               'assinatura', exists (select 1 from public.signatures s where s.movement_id = m.id),
               'foto', exists (select 1 from public.movement_photos f where f.movement_id = m.id))
             order by m.movement_at desc)
        from public.stock_movements m join public.warehouses w on w.id = m.warehouse_id
       where m.requester_employee_id = e.id), '[]'),
    'fotos', (select count(*) from public.movement_photos f
               where f.employee_id = e.id or f.movement_id in (select id from public.stock_movements where requester_employee_id = e.id)),
    'assinaturas', (select count(*) from public.signatures s
                     where s.movement_id in (select id from public.stock_movements where requester_employee_id = e.id)),
    'eventos_de_auditoria_sobre_o_cadastro', (select count(*) from public.audit_logs a where a.entity = 'employees' and a.entity_id = e.id::text),
    'observacoes', jsonb_build_array(
      'Os registros de saída finalizados não podem ser apagados: servem de prova da movimentação de material.',
      'A trilha de auditoria guarda o nome do funcionário omitido e a matrícula mascarada.',
      'Cópias de assinatura e foto podem ser fornecidas mediante pedido, após conferência de identidade.'));

  if p_request_id is not null then
    insert into public.data_subject_request_notes (request_id, kind, body, created_by)
    values (p_request_id, 'nota', 'Relatório de dados do titular gerado', auth.uid());
  end if;
  perform public.audit_event('titular.relatorio_gerado', 'employees', e.id::text, null, null, null,
    jsonb_build_object('pedido', v_code, 'retiradas', jsonb_array_length(v_out -> 'retiradas')));
  return v_out;
end;
$$;

-- ---------------------------------------------------------------------
-- 4) Verificações periódicas: inclui o prazo dos pedidos de titulares
-- ---------------------------------------------------------------------
create or replace function public._security_checks()
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_chain   jsonb;
  v_last    timestamptz;
  v_imp     integer;
  v_alerts  integer := 0;
  p         record;
  i         public.security_incidents;
  d         jsonb;
  q         public.data_subject_requests;
  v_today   date := (now() at time zone coalesce((public.get_settings()).timezone, 'America/Recife'))::date;
  v_due     bigint;
begin
  v_imp := public.security_import_auth_events();

  v_chain := public._audit_verify(null);
  if not (v_chain ->> 'ok')::boolean then
    perform public._raise_alert('integridade', 'critico', 'A verificação de integridade da auditoria falhou',
      coalesce(v_chain ->> 'problem_seq', ''), v_chain);
    v_alerts := v_alerts + 1;
  end if;

  select max(occurred_at) into v_last from public.audit_logs where category is distinct from 'auditoria';
  if v_last is null or v_last < now() - interval '72 hours' then
    perform public._raise_alert('coleta_parada', 'aviso', 'Nenhum evento de operação registrado há mais de 72 horas', '',
      jsonb_build_object('ultimo_evento', v_last));
    v_alerts := v_alerts + 1;
  end if;

  for p in select * from public.audit_retention_policies where status = 'aprovada' and retain_days is not null loop
    select count(*) into v_due from public.audit_logs
     where category = p.category and purged_at is null
       and occurred_at < now() - make_interval(days => greatest(p.retain_days - 30, 0));
    if v_due > 0 then
      perform public._raise_alert('retencao_vencendo', 'aviso',
        'Eventos de ' || p.category || ' chegando ao fim do prazo de retenção', p.category,
        jsonb_build_object('categoria', p.category, 'eventos', v_due, 'prazo_dias', p.retain_days));
      v_alerts := v_alerts + 1;
    end if;
  end loop;

  -- Incidentes: prazo de comunicação vencendo (até 1 dia útil) ou vencido; risco sem avaliação
  for i in select * from public.security_incidents where status <> 'encerrado' loop
    d := public._incident_deadlines(i);
    if (d ->> 'aplica')::boolean and i.anpd_communicated_at is null and (d ->> 'anpd_dias_restantes')::int <= 1 then
      perform public._raise_alert('incidente_prazo', 'critico',
        'Incidente ' || i.code || ': prazo de comunicação à ANPD ' ||
        case when (d ->> 'anpd_dias_restantes')::int < 0 then 'VENCIDO em ' else 'vence em ' end || to_char((d ->> 'anpd_prazo')::date, 'DD/MM/YYYY'),
        'anpd:' || i.id, jsonb_build_object('incidente', i.code, 'prazo', d ->> 'anpd_prazo', 'dias_uteis_restantes', d -> 'anpd_dias_restantes'));
      v_alerts := v_alerts + 1;
    end if;
    if (d ->> 'aplica')::boolean and i.titulares_communicated_at is null and (d ->> 'titulares_dias_restantes')::int <= 1 then
      perform public._raise_alert('incidente_prazo', 'critico',
        'Incidente ' || i.code || ': prazo de comunicação aos titulares ' ||
        case when (d ->> 'titulares_dias_restantes')::int < 0 then 'VENCIDO em ' else 'vence em ' end || to_char((d ->> 'titulares_prazo')::date, 'DD/MM/YYYY'),
        'titulares:' || i.id, jsonb_build_object('incidente', i.code, 'prazo', d ->> 'titulares_prazo', 'dias_uteis_restantes', d -> 'titulares_dias_restantes'));
      v_alerts := v_alerts + 1;
    end if;
    if i.risk_level = 'a_avaliar' and i.known_at < now() - interval '24 hours' then
      perform public._raise_alert('incidente_sem_avaliacao', 'aviso',
        'Incidente ' || i.code || ' sem avaliação de risco há mais de 24 horas', i.id::text,
        jsonb_build_object('incidente', i.code));
      v_alerts := v_alerts + 1;
    end if;
  end loop;

  -- Pedidos de titulares: resposta vencendo (até 2 dias) ou vencida
  for q in select * from public.data_subject_requests where status in ('recebido', 'em_analise') and due_date - v_today <= 2 loop
    perform public._raise_alert('titular_prazo', case when v_today > q.due_date then 'critico' else 'aviso' end,
      'Pedido de titular ' || q.code || ': resposta ' || case when v_today > q.due_date then 'VENCIDA em ' else 'vence em ' end
        || to_char(q.due_date, 'DD/MM/YYYY'),
      q.id::text, jsonb_build_object('pedido', q.code, 'prazo', q.due_date));
    v_alerts := v_alerts + 1;
  end loop;

  insert into public.security_state (key, value, updated_at)
  values ('last_checks', jsonb_build_object('at', now(), 'integridade', v_chain -> 'ok', 'importados_auth', v_imp, 'alertas', v_alerts), now())
  on conflict (key) do update set value = excluded.value, updated_at = now();

  return jsonb_build_object('integridade', v_chain, 'importados_auth', v_imp, 'alertas', v_alerts, 'at', now());
end;
$$;

-- ---------------------------------------------------------------------
-- 5) Permissões
-- ---------------------------------------------------------------------
revoke all on function public.tg_block_dsr_delete() from public, anon, authenticated;
revoke all on function public._dsr_view(public.data_subject_requests) from public, anon, authenticated;
revoke all on function public._dsr_valid_rights(text[]) from public, anon, authenticated;
revoke all on function public._security_checks() from public, anon, authenticated;
do $$
declare f text;
begin
  foreach f in array array['dsr_overview()', 'dsr_open(jsonb)', 'dsr_get(bigint)', 'dsr_update(bigint, jsonb)',
                           'dsr_respond(bigint, text, text, text)', 'dsr_add_note(bigint, text)',
                           'dsr_employee_report(uuid, bigint)', 'privacy_settings_update(jsonb)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;


-- >>>>>>>>>> 07i_reconhecimento_facial.sql
-- =====================================================================
-- 26 - RECONHECIMENTO FACIAL NO BALCÃO
-- O solicitante toca em "Retirar peças" no tablet; o rosto é reconhecido e o
-- almoxarife já vê quem está pedindo. No final, a confirmação é feita pelo rosto
-- (sem assinatura e sem foto). Quem não for reconhecido segue com foto + assinatura.
--
-- Proteção dos dados (LGPD art. 11 — dado sensível):
--   * o reconhecimento roda no tablet; a imagem do rosto NÃO é enviada nem guardada;
--   * o banco guarda só a "impressão numérica" do rosto (128 números), sem foto e sem CPF;
--   * a comparação é feita no servidor: a base de rostos nunca vai para o tablet;
--   * só cadastro (admin/almoxarife) e o servidor tocam nos modelos; a trilha registra
--     cadastro, remoção e uso, nunca os números do rosto;
--   * funcionário inativado tem os modelos apagados na hora.
-- Começa DESLIGADO: o administrador liga em Cadastros › Reconhecimento facial.
-- Pré-requisito: 16b, 20, 21, 23, 24 e 25. Pode ser reexecutado.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) Tabelas
-- ---------------------------------------------------------------------
create table if not exists public.face_settings (
  id          int primary key default 1 check (id = 1),
  enabled     boolean not null default false,
  threshold   numeric(4,3) not null default 0.5 check (threshold between 0.35 and 0.65),
  margin      numeric(4,3) not null default 0.05 check (margin between 0 and 0.2),
  updated_at  timestamptz not null default now(),
  updated_by  uuid references public.profiles (id)
);
insert into public.face_settings (id) values (1) on conflict (id) do nothing;

create table if not exists public.employee_faces (
  id           bigserial primary key,
  employee_id  uuid not null references public.employees (id),
  descriptor   real[] not null,
  source       text not null,
  created_at   timestamptz not null default now(),
  created_by   uuid references public.profiles (id),
  constraint employee_faces_len_ck check (array_length(descriptor, 1) = 128),
  constraint employee_faces_source_ck check (source in ('importacao', 'camera'))
);
create index if not exists employee_faces_employee_idx on public.employee_faces (employee_id);

-- Pedido de retirada iniciado no tablet ("Retirar peças")
create table if not exists public.counter_requests (
  id                uuid primary key default gen_random_uuid(),
  warehouse_id      uuid not null references public.warehouses (id),
  terminal_user_id  uuid not null references public.profiles (id),
  employee_id       uuid references public.employees (id),
  method            text not null,
  similarity        numeric(4,3),
  reason            text,
  status            text not null default 'pendente',
  movement_id       uuid references public.stock_movements (id),
  created_at        timestamptz not null default now(),
  handled_at        timestamptz,
  handled_by        uuid references public.profiles (id),
  constraint counter_requests_method_ck check (method in ('facial', 'manual')),
  constraint counter_requests_status_ck check (status in ('pendente', 'atendido', 'cancelado', 'expirado')),
  constraint counter_requests_facial_ck check (method <> 'facial' or employee_id is not null)
);
create index if not exists counter_requests_pending_idx on public.counter_requests (warehouse_id, status, created_at);

-- Tentativas de identificação no início (para limite de tentativas e investigação)
create table if not exists public.face_attempts (
  id                bigserial primary key,
  terminal_user_id  uuid references public.profiles (id),
  warehouse_id      uuid references public.warehouses (id),
  employee_id       uuid references public.employees (id),
  result            text not null,
  similarity        numeric(4,3),
  liveness          boolean,
  created_at        timestamptz not null default now(),
  constraint face_attempts_result_ck check (result in ('reconhecido', 'nao_reconhecido', 'ambiguo', 'sem_prova_de_vida', 'sem_rosto'))
);
create index if not exists face_attempts_terminal_idx on public.face_attempts (terminal_user_id, created_at);

alter table public.stock_movements add column if not exists requester_identified_by text;
alter table public.stock_movements add column if not exists requester_request_id uuid;
alter table public.stock_movements drop constraint if exists stock_movements_identified_by_ck;
alter table public.stock_movements add constraint stock_movements_identified_by_ck
  check (requester_identified_by is null or requester_identified_by in ('facial', 'manual'));

do $$
declare t text;
begin
  foreach t in array array['face_settings', 'employee_faces', 'counter_requests', 'face_attempts'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on table public.%I from public, anon, authenticated', t);
  end loop;
end $$;
revoke all on sequence public.employee_faces_id_seq from public, anon, authenticated;
revoke all on sequence public.face_attempts_id_seq from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 2) Funções de apoio
-- ---------------------------------------------------------------------
create or replace function public._face_distance(a real[], b real[])
returns double precision
language sql immutable parallel safe
set search_path = public, pg_temp
as $$
  select sqrt(sum((x - y) ^ 2)) from unnest(a, b) as t(x, y);
$$;

-- Converte e valida um descritor vindo do tablet (128 números finitos)
create or replace function public._face_descriptor(p jsonb)
returns real[]
language plpgsql immutable
set search_path = public, pg_temp
as $$
declare v real[];
begin
  if p is null or jsonb_typeof(p) <> 'array' or jsonb_array_length(p) <> 128 then
    raise exception 'Leitura do rosto inválida.' using errcode = '22023';
  end if;
  select array_agg(x::real order by i) into v from jsonb_array_elements_text(p) with ordinality as t(x, i);
  if exists (select 1 from unnest(v) z where z is null or z = 'NaN'::real or abs(z) > 10) then
    raise exception 'Leitura do rosto inválida.' using errcode = '22023';
  end if;
  return v;
exception when invalid_text_representation or numeric_value_out_of_range then
  raise exception 'Leitura do rosto inválida.' using errcode = '22023';
end;
$$;

revoke all on function public._face_distance(real[], real[]) from public, anon, authenticated;
revoke all on function public._face_descriptor(jsonb) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 3) Configuração e cadastro
-- ---------------------------------------------------------------------
create or replace function public.face_config()
returns jsonb
language sql stable security definer
set search_path = public, pg_temp
as $$
  select jsonb_build_object('enabled', s.enabled, 'threshold', s.threshold, 'margin', s.margin)
    from public.face_settings s where s.id = 1 and public.is_active_user();
$$;

create or replace function public.face_settings_update(p jsonb)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  o public.face_settings;
  n public.face_settings;
begin
  if not public.is_admin() then
    raise exception 'Somente o administrador altera o reconhecimento facial.' using errcode = '42501';
  end if;
  select * into o from public.face_settings where id = 1 for update;
  update public.face_settings set
    enabled   = coalesce((p ->> 'enabled')::boolean, enabled),
    threshold = coalesce((p ->> 'threshold')::numeric, threshold),
    margin    = coalesce((p ->> 'margin')::numeric, margin),
    updated_at = now(), updated_by = auth.uid()
   where id = 1 returning * into n;
  perform public.audit_event('biometria.configuracao', 'face_settings', '1', null, null,
    jsonb_build_object('ligado', o.enabled, 'rigor', o.threshold, 'margem', o.margin),
    jsonb_build_object('ligado', n.enabled, 'rigor', n.threshold, 'margem', n.margin));
  return public.face_config();
exception when check_violation then
  raise exception 'Valores fora da faixa permitida (rigor entre 0,35 e 0,65).' using errcode = '22023';
end;
$$;

create or replace function public.face_overview()
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
begin
  if not public.can_manage_master_data() then
    raise exception 'Somente administrador ou almoxarife.' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'settings', public.face_config(),
    'ativos', (select count(*) from public.employees where active),
    'com_rosto', (select count(distinct f.employee_id) from public.employee_faces f join public.employees e on e.id = f.employee_id where e.active),
    'faces', coalesce((
      select jsonb_agg(jsonb_build_object('employee_id', e.id, 'registration', e.registration, 'full_name', e.full_name,
                                          'modelos', x.n, 'origem', x.src, 'cadastrado_em', x.at) order by e.full_name)
        from (select employee_id, count(*) n, max(created_at) at, string_agg(distinct source, ', ') src
                from public.employee_faces group by employee_id) x
        join public.employees e on e.id = x.employee_id), '[]'));
end;
$$;

create or replace function public._face_store(p_employee public.employees, p_descriptors jsonb, p_source text)
returns int
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  d jsonb;
  n int := 0;
begin
  if p_descriptors is null or jsonb_typeof(p_descriptors) <> 'array' or jsonb_array_length(p_descriptors) not between 1 and 5 then
    raise exception 'Envie de 1 a 5 leituras do rosto.' using errcode = '22023';
  end if;
  delete from public.employee_faces where employee_id = p_employee.id;
  for d in select * from jsonb_array_elements(p_descriptors) loop
    insert into public.employee_faces (employee_id, descriptor, source, created_by)
    values (p_employee.id, public._face_descriptor(d), p_source, auth.uid());
    n := n + 1;
  end loop;
  return n;
end;
$$;
revoke all on function public._face_store(public.employees, jsonb, text) from public, anon, authenticated;

create or replace function public.face_enroll(p_employee_id uuid, p_descriptors jsonb, p_source text default 'camera')
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  e public.employees;
  n int;
begin
  if not public.can_manage_master_data() then
    raise exception 'Somente administrador ou almoxarife cadastra rostos.' using errcode = '42501';
  end if;
  if p_source not in ('importacao', 'camera') then
    raise exception 'Origem inválida.' using errcode = '22023';
  end if;
  select * into e from public.employees where id = p_employee_id;
  if e.id is null then
    raise exception 'Funcionário não encontrado.' using errcode = 'P0001';
  end if;
  if not e.active then
    raise exception 'O funcionário % está inativo.', e.full_name using errcode = '22023';
  end if;
  n := public._face_store(e, p_descriptors, p_source);
  perform public.audit_event('biometria.cadastrada', 'employee_faces', e.id::text, null, null, null,
    jsonb_build_object('modelos', n, 'origem', p_source));
  return jsonb_build_object('employee_id', e.id, 'modelos', n);
end;
$$;

-- Importação em lote: [{registration, descriptors: [[128 números], ...]}], até 100 por chamada
create or replace function public.face_enroll_bulk(p_items jsonb)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  it        jsonb;
  e         public.employees;
  v_ok      int := 0;
  v_models  int := 0;
  v_missing jsonb := '[]';
  v_inact   jsonb := '[]';
  v_bad     jsonb := '[]';
  v_reg     text;
begin
  if not public.can_manage_master_data() then
    raise exception 'Somente administrador ou almoxarife cadastra rostos.' using errcode = '42501';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) not between 1 and 100 then
    raise exception 'Envie de 1 a 100 funcionários por vez.' using errcode = '22023';
  end if;
  for it in select * from jsonb_array_elements(p_items) loop
    v_reg := btrim(coalesce(it ->> 'registration', ''));
    select * into e from public.employees where upper(registration) = upper(v_reg);
    if e.id is null then
      v_missing := v_missing || to_jsonb(v_reg);
    elsif not e.active then
      v_inact := v_inact || to_jsonb(v_reg);
    else
      begin
        v_models := v_models + public._face_store(e, it -> 'descriptors', 'importacao');
        v_ok := v_ok + 1;
      exception when others then
        v_bad := v_bad || to_jsonb(v_reg);
      end;
    end if;
  end loop;
  perform public.audit_event('biometria.importada', 'employee_faces', null, null, null, null,
    jsonb_build_object('funcionarios', v_ok, 'modelos', v_models, 'nao_cadastrados', jsonb_array_length(v_missing),
                       'inativos', jsonb_array_length(v_inact), 'invalidos', jsonb_array_length(v_bad)));
  return jsonb_build_object('cadastrados', v_ok, 'modelos', v_models, 'nao_encontrados', v_missing,
                            'inativos', v_inact, 'invalidos', v_bad);
end;
$$;

create or replace function public.face_remove(p_employee_id uuid)
returns int
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare n int;
begin
  if not public.can_manage_master_data() then
    raise exception 'Somente administrador ou almoxarife remove rostos.' using errcode = '42501';
  end if;
  delete from public.employee_faces where employee_id = p_employee_id;
  get diagnostics n = row_count;
  if n > 0 then
    perform public.audit_event('biometria.removida', 'employee_faces', p_employee_id::text, null, null, null,
      jsonb_build_object('modelos', n, 'motivo', 'manual'));
  end if;
  return n;
end;
$$;

-- Funcionário inativado: o rosto é apagado na hora (não serve mais para nada)
create or replace function public.tg_employee_faces_on_inactive()
returns trigger
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare n int;
begin
  if old.active and not new.active then
    delete from public.employee_faces where employee_id = new.id;
    get diagnostics n = row_count;
    if n > 0 then
      perform public.audit_event('biometria.removida', 'employee_faces', new.id::text, null, null, null,
        jsonb_build_object('modelos', n, 'motivo', 'funcionario_inativado'));
    end if;
  end if;
  return new;
end;
$$;
drop trigger if exists employees_faces_inactive on public.employees;
create trigger employees_faces_inactive after update of active on public.employees
  for each row execute function public.tg_employee_faces_on_inactive();
revoke all on function public.tg_employee_faces_on_inactive() from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 4) Tablet: "Retirar peças" (identificação 1:N) e alternativa manual
-- ---------------------------------------------------------------------
create or replace function public._counter_terminal_check(p_warehouse_id uuid)
returns void
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null or not public.is_active_user() then
    raise exception 'Sessão inválida ou usuário inativo.' using errcode = '42501';
  end if;
  if not public.is_terminal_of_warehouse(p_warehouse_id) then
    raise exception 'Este tablet não está vinculado a este estoque.' using errcode = '42501';
  end if;
end;
$$;
revoke all on function public._counter_terminal_check(uuid) from public, anon, authenticated;

create or replace function public.face_identify(p_warehouse_id uuid, p_descriptor jsonb, p_liveness boolean)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  s        public.face_settings;
  v_d      real[];
  b1       record;
  b2       record;
  v_result text;
  v_req    public.counter_requests;
  v_sim    numeric;
begin
  perform public._counter_terminal_check(p_warehouse_id);
  select * into s from public.face_settings where id = 1;
  if not s.enabled then
    raise exception 'O reconhecimento facial está desligado.' using errcode = 'P0001';
  end if;
  if (select count(*) from public.face_attempts
       where terminal_user_id = auth.uid() and created_at > now() - interval '5 minutes') >= 30 then
    raise exception 'Muitas tentativas seguidas. Aguarde alguns minutos ou chame o almoxarife.' using errcode = 'P0001';
  end if;
  v_d := public._face_descriptor(p_descriptor);

  -- menor distância por funcionário ativo; melhor e segundo melhor
  select x.employee_id, x.d into b1 from (
    select f.employee_id, min(public._face_distance(f.descriptor, v_d)) d
      from public.employee_faces f join public.employees e on e.id = f.employee_id and e.active
     group by f.employee_id) x order by x.d limit 1;
  select x.employee_id, x.d into b2 from (
    select f.employee_id, min(public._face_distance(f.descriptor, v_d)) d
      from public.employee_faces f join public.employees e on e.id = f.employee_id and e.active
     group by f.employee_id) x where x.employee_id is distinct from b1.employee_id order by x.d limit 1;

  v_result := case
    when not coalesce(p_liveness, false) then 'sem_prova_de_vida'
    when b1.employee_id is null or b1.d > s.threshold then 'nao_reconhecido'
    when b2.employee_id is not null and b2.d - b1.d < s.margin then 'ambiguo'
    else 'reconhecido' end;
  v_sim := case when b1.d is not null then greatest(0, round((1 - b1.d)::numeric, 3)) end;

  insert into public.face_attempts (terminal_user_id, warehouse_id, employee_id, result, similarity, liveness)
  values (auth.uid(), p_warehouse_id, case when v_result = 'reconhecido' then b1.employee_id end, v_result,
          case when v_result = 'reconhecido' then v_sim end, coalesce(p_liveness, false));

  if v_result <> 'reconhecido' then
    return jsonb_build_object('ok', false, 'reason', v_result);
  end if;

  update public.counter_requests set status = 'cancelado', handled_at = now()
   where terminal_user_id = auth.uid() and status = 'pendente';
  insert into public.counter_requests (warehouse_id, terminal_user_id, employee_id, method, similarity)
  values (p_warehouse_id, auth.uid(), b1.employee_id, 'facial', v_sim)
  returning * into v_req;
  perform public.audit_event('biometria.identificacao', 'counter_requests', v_req.id::text, null, p_warehouse_id, null,
    jsonb_build_object('semelhanca', v_sim));
  return jsonb_build_object('ok', true, 'request_id', v_req.id, 'similarity', v_sim,
    'employee', (select jsonb_build_object('full_name', e.full_name, 'registration', e.registration)
                   from public.employees e where e.id = b1.employee_id));
end;
$$;

-- Sem reconhecimento: o tablet chama o almoxarife, que identifica pela matrícula
create or replace function public.counter_request_manual(p_warehouse_id uuid, p_reason text)
returns uuid
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare v_id uuid;
begin
  perform public._counter_terminal_check(p_warehouse_id);
  if (select count(*) from public.counter_requests
       where terminal_user_id = auth.uid() and created_at > now() - interval '5 minutes') >= 20 then
    raise exception 'Muitos pedidos seguidos. Aguarde o almoxarife.' using errcode = 'P0001';
  end if;
  update public.counter_requests set status = 'cancelado', handled_at = now()
   where terminal_user_id = auth.uid() and status = 'pendente';
  insert into public.counter_requests (warehouse_id, terminal_user_id, method, reason)
  values (p_warehouse_id, auth.uid(), 'manual', left(nullif(btrim(coalesce(p_reason, '')), ''), 200))
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.counter_request_cancel(p_id uuid)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare r public.counter_requests;
begin
  select * into r from public.counter_requests where id = p_id for update;
  if r.id is null then return; end if;
  if r.terminal_user_id <> auth.uid()
     and not (public.has_any_role(array['almoxarife', 'gestor', 'admin']::public.app_role[]) and public.can_access_warehouse(r.warehouse_id)) then
    raise exception 'Sem permissão.' using errcode = '42501';
  end if;
  if r.status = 'pendente' then
    update public.counter_requests set status = 'cancelado', handled_at = now(), handled_by = auth.uid() where id = p_id;
  end if;
end;
$$;

-- Situação do pedido para o tablet (aguardando ou já atendido)
create or replace function public.counter_request_status(p_id uuid)
returns jsonb
language sql stable security definer
set search_path = public, pg_temp
as $$
  select jsonb_build_object('status', case when r.status = 'pendente' and r.created_at < now() - interval '10 minutes'
                                           then 'expirado' else r.status end,
                            'movement_id', r.movement_id)
    from public.counter_requests r where r.id = p_id and r.terminal_user_id = auth.uid();
$$;

-- Tela do almoxarife: solicitantes esperando no balcão
create or replace function public.counter_requests_pending(p_warehouse_id uuid)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  if not public.has_any_role(array['almoxarife', 'gestor', 'admin']::public.app_role[]) or not public.can_access_warehouse(p_warehouse_id) then
    raise exception 'Sem permissão para este estoque.' using errcode = '42501';
  end if;
  update public.counter_requests set status = 'expirado', handled_at = now()
   where warehouse_id = p_warehouse_id and status = 'pendente' and created_at < now() - interval '10 minutes';
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', r.id, 'method', r.method, 'similarity', r.similarity, 'reason', r.reason, 'created_at', r.created_at,
             'terminal_user_id', r.terminal_user_id, 'terminal_name', p.full_name,
             'employee', case when e.id is not null then jsonb_build_object(
               'id', e.id, 'full_name', e.full_name, 'registration', e.registration, 'job_title', e.job_title,
               'sector_id', e.sector_id, 'active', e.active) end)
           order by r.created_at)
      from public.counter_requests r
      join public.profiles p on p.id = r.terminal_user_id
      left join public.employees e on e.id = r.employee_id
     where r.warehouse_id = p_warehouse_id and r.status = 'pendente'), '[]');
end;
$$;

-- Liga o pedido do tablet à ME aberta pelo almoxarife
create or replace function public.counter_request_attach(p_request_id uuid, p_movement_id uuid)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  r public.counter_requests;
  m public.stock_movements;
  v_s public.counter_sessions;
begin
  select * into r from public.counter_requests where id = p_request_id for update;
  select * into m from public.stock_movements where id = p_movement_id for update;
  select * into v_s from public.counter_sessions where movement_id = p_movement_id;
  if r.id is null or m.id is null or v_s.id is null then
    raise exception 'Pedido ou ME não encontrados.' using errcode = 'P0001';
  end if;
  if m.created_by <> auth.uid() then
    raise exception 'Só quem abriu a ME pode ligá-la ao pedido.' using errcode = '42501';
  end if;
  if r.status <> 'pendente' or r.created_at < now() - interval '10 minutes' then
    raise exception 'Este pedido do tablet já foi atendido, cancelado ou expirou.' using errcode = 'P0001';
  end if;
  if r.warehouse_id <> m.warehouse_id then
    raise exception 'O pedido é de outro estoque.' using errcode = '22023';
  end if;
  if r.employee_id is not null and r.employee_id <> m.requester_employee_id then
    raise exception 'O solicitante da ME é diferente do reconhecido no tablet.' using errcode = '22023';
  end if;
  if v_s.terminal_user_id is distinct from r.terminal_user_id then
    raise exception 'A ME precisa estar no mesmo tablet do pedido.' using errcode = '22023';
  end if;
  update public.counter_requests set status = 'atendido', movement_id = m.id, handled_at = now(), handled_by = auth.uid()
   where id = r.id;
  perform set_config('app.audit_action', 'me.solicitante_identificado', true);
  perform set_config('app.source', 'balcao', true);
  update public.stock_movements set requester_identified_by = r.method, requester_request_id = r.id where id = m.id;
end;
$$;

-- ---------------------------------------------------------------------
-- 5) Confirmação pelo rosto (1:1 com o solicitante da ME)
-- ---------------------------------------------------------------------
create or replace function public.face_confirmation_available(p_movement_id uuid)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare
  m public.stock_movements;
  v_s public.counter_sessions;
  v_fails int;
begin
  select * into m from public.stock_movements where id = p_movement_id;
  select * into v_s from public.counter_sessions where movement_id = p_movement_id;
  if v_s.id is null or v_s.terminal_user_id is distinct from auth.uid() then
    raise exception 'Tablet não pareado com esta ME.' using errcode = '42501';
  end if;
  if not (select enabled from public.face_settings where id = 1) then
    return jsonb_build_object('available', false, 'reason', 'desligado');
  end if;
  if not exists (select 1 from public.employee_faces where employee_id = m.requester_employee_id) then
    return jsonb_build_object('available', false, 'reason', 'sem_cadastro');
  end if;
  select count(*) into v_fails from public.confirmation_attempts
   where movement_id = m.id and method = 'facial' and result = 'falha';
  if v_fails >= 5 then
    return jsonb_build_object('available', false, 'reason', 'muitas_falhas');
  end if;
  return jsonb_build_object('available', true, 'tentativas_restantes', 5 - v_fails);
end;
$$;

create or replace function public.face_verify_confirmation(p_movement_id uuid, p_descriptor jsonb, p_liveness boolean)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  s     public.face_settings;
  m     public.stock_movements;
  v_av  jsonb;
  v_d   real[];
  v_min double precision;
  v_ok  boolean;
  v_sim numeric;
  v_att uuid;
begin
  v_av := public.face_confirmation_available(p_movement_id);
  if not (v_av ->> 'available')::boolean then
    raise exception 'Confirmação pelo rosto indisponível para esta ME (%). Confirme com foto e assinatura.', v_av ->> 'reason'
      using errcode = 'P0001';
  end if;
  select * into s from public.face_settings where id = 1;
  select * into m from public.stock_movements where id = p_movement_id;
  if m.status <> 'aguardando_assinatura' then
    raise exception 'A separação ainda não está pronta para confirmação.' using errcode = 'P0001';
  end if;
  v_d := public._face_descriptor(p_descriptor);
  select min(public._face_distance(f.descriptor, v_d)) into v_min
    from public.employee_faces f where f.employee_id = m.requester_employee_id;
  v_ok := coalesce(p_liveness, false) and v_min <= s.threshold;
  v_sim := greatest(0, round((1 - v_min)::numeric, 3));
  insert into public.confirmation_attempts (movement_id, employee_id, method, provider, result, score, liveness, detail)
  values (m.id, m.requester_employee_id, 'facial', 'reconhecimento_no_tablet', case when v_ok then 'sucesso' else 'falha' end,
          v_sim, coalesce(p_liveness, false),
          jsonb_build_object('rigor', s.threshold, 'motivo', case when not coalesce(p_liveness, false) then 'sem_prova_de_vida'
                                                                  when not v_ok then 'nao_reconhecido' end))
  returning id into v_att;
  if not v_ok then
    return jsonb_build_object('ok', false,
      'reason', case when not coalesce(p_liveness, false) then 'sem_prova_de_vida' else 'nao_reconhecido' end,
      'remaining', (public.face_confirmation_available(p_movement_id) ->> 'tentativas_restantes')::int);
  end if;
  return jsonb_build_object('ok', true, 'verification_id', v_att, 'similarity', v_sim);
end;
$$;

do $$
declare f text;
begin
  foreach f in array array['face_config()', 'face_settings_update(jsonb)', 'face_overview()', 'face_enroll(uuid, jsonb, text)',
                           'face_enroll_bulk(jsonb)', 'face_remove(uuid)', 'face_identify(uuid, jsonb, boolean)',
                           'counter_request_manual(uuid, text)', 'counter_request_cancel(uuid)', 'counter_request_status(uuid)',
                           'counter_requests_pending(uuid)', 'counter_request_attach(uuid, uuid)',
                           'face_confirmation_available(uuid)', 'face_verify_confirmation(uuid, jsonb, boolean)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- 7) Como o solicitante foi identificado e confirmou (tela de detalhe da ME)
-- ---------------------------------------------------------------------
create or replace function public.movement_identification(p_movement_id uuid)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare m public.stock_movements;
begin
  select * into m from public.stock_movements where id = p_movement_id;
  if m.id is null or not public.is_active_user() or not public.can_access_warehouse(m.warehouse_id) then
    return null;
  end if;
  return jsonb_build_object(
    'identificado_por', m.requester_identified_by,
    'confirmado_por', m.confirmation_method,
    'confirmado_em', m.confirmed_at,
    'semelhanca_inicio', (select r.similarity from public.counter_requests r where r.id = m.requester_request_id),
    'semelhanca_confirmacao', (select a.score from public.confirmation_attempts a
                                where a.movement_id = m.id and a.method = 'facial' and a.result = 'sucesso' and a.consumed_at is not null
                                order by a.created_at desc limit 1));
end;
$$;
revoke all on function public.movement_identification(uuid) from public, anon;
grant execute on function public.movement_identification(uuid) to authenticated;

-- Estoques do tablet (o perfil Terminal não recebe a lista de estoques no acesso)
create or replace function public.counter_terminal_warehouses()
returns jsonb
language sql stable security definer
set search_path = public, pg_temp
as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', w.id, 'name', w.name) order by w.name), '[]')
    from public.user_warehouses uw
    join public.warehouses w on w.id = uw.warehouse_id and w.active
   where uw.user_id = auth.uid() and public.is_terminal_of_warehouse(w.id);
$$;
revoke all on function public.counter_terminal_warehouses() from public, anon;
grant execute on function public.counter_terminal_warehouses() to authenticated;

-- ---------------------------------------------------------------------
-- 6) Trilha, alerta e relatório do titular (versões atualizadas)
-- ---------------------------------------------------------------------
create or replace function public.audit_classify(p_action text, p_entity text, out category text, out severity text)
language plpgsql immutable
set search_path = public, pg_temp
as $$
begin
  if p_action like 'auth.%' then
    category := 'autenticacao'; severity := 'aviso';
  elsif p_action like 'acesso.%' then
    category := 'autorizacao'; severity := 'aviso';
  elsif p_entity in ('user_roles', 'user_warehouses', 'profiles') or p_action like 'usuario.%' then
    category := 'permissao'; severity := 'critico';
  elsif p_entity in ('app_settings', 'warehouses') then
    category := 'configuracao'; severity := 'critico';
  elsif p_action like 'incidente.%' then
    category := 'incidente'; severity := 'critico';
  elsif p_action = 'biometria.configuracao' then
    category := 'configuracao'; severity := 'critico';
  elsif p_action like 'biometria.%' then
    category := 'privacidade'; severity := 'aviso';
  elsif p_action like 'titular.%' then
    category := 'privacidade'; severity := 'aviso';
  elsif p_action like 'privacidade.%' then
    category := 'configuracao'; severity := 'critico';
  elsif p_action like 'alerta.%' then
    category := 'incidente'; severity := 'aviso';
  elsif p_action like 'retencao%' or p_action like 'seguranca.%' then
    category := 'auditoria'; severity := 'critico';
  elsif p_action like 'auditoria.descarte_%' then
    category := 'auditoria'; severity := 'critico';
  elsif p_action like 'auditoria.%' then
    category := 'auditoria';
    severity := case when p_action in ('auditoria.exportada', 'auditoria.integridade_verificada', 'auditoria.ancora_conferida') then 'critico' else 'aviso' end;
  elsif p_action in ('me.assinatura_consultada', 'me.foto_consultada') then
    category := 'privacidade'; severity := 'aviso';
  elsif p_action like 'exportacao.%' or p_action in ('me.impressa', 'me.pdf_gerado', 'etiquetas.impressas') then
    category := 'exportacao'; severity := 'aviso';
  elsif p_entity in ('employees', 'materials', 'material_qr_codes', 'contracts', 'sectors', 'service_fronts',
                     'service_orders', 'fixed_assets', 'application_locations', 'accounts', 'material_categories') then
    category := 'cadastro'; severity := 'info';
  else
    category := 'dados'; severity := 'info';
  end if;
end;
$$;

create or replace function public._security_checks()
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_chain   jsonb;
  v_last    timestamptz;
  v_imp     integer;
  v_alerts  integer := 0;
  p         record;
  i         public.security_incidents;
  d         jsonb;
  q         public.data_subject_requests;
  v_today   date := (now() at time zone coalesce((public.get_settings()).timezone, 'America/Recife'))::date;
  v_due     bigint;
begin
  v_imp := public.security_import_auth_events();

  v_chain := public._audit_verify(null);
  if not (v_chain ->> 'ok')::boolean then
    perform public._raise_alert('integridade', 'critico', 'A verificação de integridade da auditoria falhou',
      coalesce(v_chain ->> 'problem_seq', ''), v_chain);
    v_alerts := v_alerts + 1;
  end if;

  select max(occurred_at) into v_last from public.audit_logs where category is distinct from 'auditoria';
  if v_last is null or v_last < now() - interval '72 hours' then
    perform public._raise_alert('coleta_parada', 'aviso', 'Nenhum evento de operação registrado há mais de 72 horas', '',
      jsonb_build_object('ultimo_evento', v_last));
    v_alerts := v_alerts + 1;
  end if;

  for p in select * from public.audit_retention_policies where status = 'aprovada' and retain_days is not null loop
    select count(*) into v_due from public.audit_logs
     where category = p.category and purged_at is null
       and occurred_at < now() - make_interval(days => greatest(p.retain_days - 30, 0));
    if v_due > 0 then
      perform public._raise_alert('retencao_vencendo', 'aviso',
        'Eventos de ' || p.category || ' chegando ao fim do prazo de retenção', p.category,
        jsonb_build_object('categoria', p.category, 'eventos', v_due, 'prazo_dias', p.retain_days));
      v_alerts := v_alerts + 1;
    end if;
  end loop;

  -- Incidentes: prazo de comunicação vencendo (até 1 dia útil) ou vencido; risco sem avaliação
  for i in select * from public.security_incidents where status <> 'encerrado' loop
    d := public._incident_deadlines(i);
    if (d ->> 'aplica')::boolean and i.anpd_communicated_at is null and (d ->> 'anpd_dias_restantes')::int <= 1 then
      perform public._raise_alert('incidente_prazo', 'critico',
        'Incidente ' || i.code || ': prazo de comunicação à ANPD ' ||
        case when (d ->> 'anpd_dias_restantes')::int < 0 then 'VENCIDO em ' else 'vence em ' end || to_char((d ->> 'anpd_prazo')::date, 'DD/MM/YYYY'),
        'anpd:' || i.id, jsonb_build_object('incidente', i.code, 'prazo', d ->> 'anpd_prazo', 'dias_uteis_restantes', d -> 'anpd_dias_restantes'));
      v_alerts := v_alerts + 1;
    end if;
    if (d ->> 'aplica')::boolean and i.titulares_communicated_at is null and (d ->> 'titulares_dias_restantes')::int <= 1 then
      perform public._raise_alert('incidente_prazo', 'critico',
        'Incidente ' || i.code || ': prazo de comunicação aos titulares ' ||
        case when (d ->> 'titulares_dias_restantes')::int < 0 then 'VENCIDO em ' else 'vence em ' end || to_char((d ->> 'titulares_prazo')::date, 'DD/MM/YYYY'),
        'titulares:' || i.id, jsonb_build_object('incidente', i.code, 'prazo', d ->> 'titulares_prazo', 'dias_uteis_restantes', d -> 'titulares_dias_restantes'));
      v_alerts := v_alerts + 1;
    end if;
    if i.risk_level = 'a_avaliar' and i.known_at < now() - interval '24 hours' then
      perform public._raise_alert('incidente_sem_avaliacao', 'aviso',
        'Incidente ' || i.code || ' sem avaliação de risco há mais de 24 horas', i.id::text,
        jsonb_build_object('incidente', i.code));
      v_alerts := v_alerts + 1;
    end if;
  end loop;

  -- Pedidos de titulares: resposta vencendo (até 2 dias) ou vencida
  for q in select * from public.data_subject_requests where status in ('recebido', 'em_analise') and due_date - v_today <= 2 loop
    perform public._raise_alert('titular_prazo', case when v_today > q.due_date then 'critico' else 'aviso' end,
      'Pedido de titular ' || q.code || ': resposta ' || case when v_today > q.due_date then 'VENCIDA em ' else 'vence em ' end
        || to_char(q.due_date, 'DD/MM/YYYY'),
      q.id::text, jsonb_build_object('pedido', q.code, 'prazo', q.due_date));
    v_alerts := v_alerts + 1;
  end loop;

  -- Reconhecimento facial: funcionário com rosto cadastrado confirmando por assinatura com frequência
  -- (pode ser só um cadastro ruim, mas também alguém evitando o reconhecimento)
  if (select enabled from public.face_settings where id = 1) then
    for q in
      select m.requester_employee_id as emp, count(*) as n
        from public.stock_movements m
       where m.confirmation_method = 'assinatura' and m.confirmed_at > now() - interval '7 days'
         and exists (select 1 from public.employee_faces f where f.employee_id = m.requester_employee_id)
       group by m.requester_employee_id having count(*) >= 3
    loop
      perform public._raise_alert('biometria_alternativa', 'aviso',
        'Funcionário com rosto cadastrado confirmou ' || q.n || ' retiradas por assinatura em 7 dias',
        q.emp::text, jsonb_build_object('employee_id', q.emp, 'confirmacoes_por_assinatura', q.n));
      v_alerts := v_alerts + 1;
    end loop;
  end if;

  insert into public.security_state (key, value, updated_at)
  values ('last_checks', jsonb_build_object('at', now(), 'integridade', v_chain -> 'ok', 'importados_auth', v_imp, 'alertas', v_alerts), now())
  on conflict (key) do update set value = excluded.value, updated_at = now();

  return jsonb_build_object('integridade', v_chain, 'importados_auth', v_imp, 'alertas', v_alerts, 'at', now());
end;
$$;
revoke all on function public._security_checks() from public, anon, authenticated;

create or replace function public.dsr_employee_report(p_employee_id uuid, p_request_id bigint default null)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  e       public.employees;
  v_tz    text := coalesce((public.get_settings()).timezone, 'America/Recife');
  v_code  text;
  v_out   jsonb;
begin
  if not public.is_admin() then
    raise exception 'Somente o administrador gera o relatório do titular.' using errcode = '42501';
  end if;
  select * into e from public.employees where id = p_employee_id;
  if e.id is null then
    raise exception 'Funcionário não encontrado.' using errcode = 'P0001';
  end if;
  if p_request_id is not null then
    select code into v_code from public.data_subject_requests where id = p_request_id;
    if v_code is null then
      raise exception 'Pedido não encontrado.' using errcode = 'P0001';
    end if;
  end if;

  v_out := jsonb_build_object(
    'gerado_em', now(),
    'pedido', v_code,
    'cadastro', jsonb_build_object(
      'matricula', e.registration, 'nome', e.full_name, 'cargo', e.job_title,
      'setor', (select s.name from public.sectors s where s.id = e.sector_id),
      'ativo', e.active, 'cadastrado_em', e.created_at, 'atualizado_em', e.updated_at),
    'retiradas', coalesce((
      select jsonb_agg(jsonb_build_object(
               'me', m.me_number,
               'data', to_char(m.movement_at at time zone v_tz, 'DD/MM/YYYY HH24:MI'),
               'estoque', w.name,
               'situacao', m.status,
               'emergencial', coalesce(m.is_emergency, false),
               'itens', (select count(*) from public.stock_movement_items i where i.movement_id = m.id),
               'assinatura', exists (select 1 from public.signatures s where s.movement_id = m.id),
               'foto', exists (select 1 from public.movement_photos f where f.movement_id = m.id))
             order by m.movement_at desc)
        from public.stock_movements m join public.warehouses w on w.id = m.warehouse_id
       where m.requester_employee_id = e.id), '[]'),
    'fotos', (select count(*) from public.movement_photos f
               where f.employee_id = e.id or f.movement_id in (select id from public.stock_movements where requester_employee_id = e.id)),
    'assinaturas', (select count(*) from public.signatures s
                     where s.movement_id in (select id from public.stock_movements where requester_employee_id = e.id)),
    'biometria', (select jsonb_build_object('rosto_cadastrado', count(*) > 0, 'modelos', count(*),
                                            'cadastrado_em', max(f.created_at), 'origem', string_agg(distinct f.source, ', '),
                                            'retiradas_confirmadas_pelo_rosto',
                                            (select count(*) from public.stock_movements m2
                                              where m2.requester_employee_id = e.id and m2.confirmation_method = 'facial'))
                    from public.employee_faces f where f.employee_id = e.id),
    'eventos_de_auditoria_sobre_o_cadastro', (select count(*) from public.audit_logs a where a.entity = 'employees' and a.entity_id = e.id::text),
    'observacoes', jsonb_build_array(
      'Os registros de saída finalizados não podem ser apagados: servem de prova da movimentação de material.',
      'A trilha de auditoria guarda o nome do funcionário omitido e a matrícula mascarada.',
      'Cópias de assinatura e foto podem ser fornecidas mediante pedido, após conferência de identidade.',
      'Do rosto, o sistema guarda só uma representação numérica usada na comparação (sem foto); ela é apagada quando o funcionário é inativado.'));

  if p_request_id is not null then
    insert into public.data_subject_request_notes (request_id, kind, body, created_by)
    values (p_request_id, 'nota', 'Relatório de dados do titular gerado', auth.uid());
  end if;
  perform public.audit_event('titular.relatorio_gerado', 'employees', e.id::text, null, null, null,
    jsonb_build_object('pedido', v_code, 'retiradas', jsonb_array_length(v_out -> 'retiradas')));
  return v_out;
end;
$$;
revoke all on function public.dsr_employee_report(uuid, bigint) from public, anon;
grant execute on function public.dsr_employee_report(uuid, bigint) to authenticated;


-- >>>>>>>>>> 08_dados_iniciais.sql
-- =====================================================================
-- 08 - DADOS INICIAIS (necessários para produção)
-- =====================================================================

insert into public.app_settings (id) values (1) on conflict (id) do nothing;

insert into public.warehouses (code, name) values
  ('MUR', 'Muribeca'),
  ('DIR', 'Dois Irmãos')
on conflict (code) do update set name = excluded.name;

insert into public.material_categories (code, name) values
  ('LUB', 'Lubrificantes'),
  ('FIL', 'Filtros'),
  ('PNE', 'Pneus e câmaras'),
  ('EPI', 'Equipamentos de proteção individual'),
  ('ELE', 'Elétrica automotiva'),
  ('ABR', 'Abrasivos e corte'),
  ('TRA', 'Transmissão'),
  ('ROL', 'Rolamentos'),
  ('GER', 'Uso geral')
on conflict (code) do nothing;
