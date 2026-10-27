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
