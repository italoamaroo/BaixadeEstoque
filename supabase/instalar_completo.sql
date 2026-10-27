-- =====================================================================
-- INSTALAÇÃO COMPLETA (gerado por scripts/montar-sql.mjs — não edite à mão)
-- Arquivos: 01_extensoes_e_tipos.sql, 02_tabelas.sql, 03_funcoes_e_triggers.sql, 04_rpc_movimentacoes.sql, 05_rpc_administracao.sql, 06_rls_e_permissoes.sql, 07_storage.sql, 08_dados_iniciais.sql
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
  create type public.app_role as enum ('almoxarife', 'equipe_sa', 'gestor', 'admin');
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
begin
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
  v_year := extract(year from (v_now at time zone s.timezone))::int;
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
    v_signed_at := coalesce(nullif(v_sig ->> 'signed_at', '')::timestamptz, v_now);
  exception when others then
    v_signed_at := v_now;
  end;
  if v_signed_at > v_now + interval '5 minutes' or v_signed_at < v_now - interval '1 day' then
    v_signed_at := v_now;
  end if;

  -- 8) Gravação
  perform set_config('app.creating', 'on', true);
  perform set_config('app.source', coalesce(nullif(p_payload ->> 'source', ''), 'app'), true);

  v_number := public.next_me_number(v_wh.id, v_now);
  v_status := case when s.require_approval then 'aguardando_aprovacao' else 'aguardando_sa' end;

  insert into public.stock_movements (
    id, me_number, movement_type, movement_at, warehouse_id, contract_id, sector_id,
    service_front_id, service_order_id, service_order_text, fixed_asset_id, fixed_asset_text,
    application_location_id, application_location_text, notes, status,
    requester_employee_id, requester_name, requester_registration, requested_at,
    received_by_employee_id, received_by_name, received_by_registration, received_at,
    storekeeper_id, created_by, updated_by, created_at
  ) values (
    v_id, v_number, 'saida', v_now, v_wh.id, v_contract_id, v_sector_id,
    v_front_id, v_so_id, v_so_text, v_fa_id, v_fa_text,
    v_appl_id, nullif(btrim(coalesce(p_payload ->> 'application_location_text', '')), ''),
    nullif(btrim(coalesce(p_payload ->> 'notes', '')), ''), v_status,
    v_requester.id, v_requester.full_name, v_requester.registration, v_now,
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

  update public.stock_movements
     set status = 'aguardando_sa', approved_by = auth.uid(), approved_at = now()
   where id = p_id;

  return jsonb_build_object('id', p_id, 'status', 'aguardando_sa');
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
-- Concluir (SA informada e validada)
-- ---------------------------------------------------------------------
create or replace function public.complete_movement(p_id uuid)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_m public.stock_movements;
begin
  if not public.has_any_role(array['equipe_sa', 'gestor', 'admin']::public.app_role[]) then
    raise exception 'Seu perfil não permite concluir a ME.' using errcode = '42501';
  end if;

  select * into v_m from public.stock_movements where id = p_id for update;
  if v_m.id is null or not public.can_access_warehouse(v_m.warehouse_id) then
    raise exception 'ME não encontrada.' using errcode = 'P0002';
  end if;
  if v_m.status <> 'sa_informada' then
    raise exception 'Somente MEs com SA informada podem ser concluídas (status atual: %).', v_m.status using errcode = 'P0001';
  end if;

  perform set_config('app.audit_action', 'me.concluida', true);
  update public.stock_movements
     set status = 'concluida', completed_at = now(), completed_by = auth.uid()
   where id = p_id;

  return jsonb_build_object('id', p_id, 'status', 'concluida');
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
  v_m      public.stock_movements;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if not public.has_any_role(array['gestor', 'admin']::public.app_role[]) then
    raise exception 'Somente gestor ou administrador pode cancelar uma ME.' using errcode = '42501';
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
  if p_action not in ('me.impressa', 'me.pdf_gerado', 'me.assinatura_consultada',
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
  if not public.is_admin() then
    raise exception 'Somente administrador pode gerar um novo QR Code.' using errcode = '42501';
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
  if not public.is_admin() then
    raise exception 'Somente administrador pode importar materiais.' using errcode = '42501';
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
-- Leitura: usuários ativos. Inclusão/alteração: administrador.
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
    execute format('create policy %I on public.%I for insert to authenticated with check (public.is_admin())',
                   t || '_insert', t);
    execute format('create policy %I on public.%I for update to authenticated using (public.is_admin()) with check (public.is_admin())',
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
  public.is_admin(), public.can_access_warehouse(uuid), public.can_access_warehouse_code(text),
  public.can_access_movement(uuid), public.get_settings(), public.request_header(text),
  public.jsonb_diff(jsonb, jsonb),
  public.movement_matches(public.v_movements, jsonb, text),
  public.search_movements(jsonb, int, int, text, text),
  public.find_material_by_code(text), public.search_materials(text, boolean, int),
  public.create_movement(jsonb), public.approve_movement(uuid, text),
  public.inform_sa(uuid, text, text), public.complete_movement(uuid),
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
