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
