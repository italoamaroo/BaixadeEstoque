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
