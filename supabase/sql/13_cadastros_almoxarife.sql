-- =====================================================================
-- 13 - CADASTROS PELO ALMOXARIFE
-- Libera ao almoxarife: materiais (incluir, editar, inativar, importar,
-- gerar QR Code), funcionários (incluir, editar, importar) e tabelas
-- auxiliares (contratos, setores, frentes, OS, ativos, locais, contas,
-- categorias). Estoques, usuários, perfis e parâmetros continuam só com
-- o administrador.
-- Executar uma vez no SQL Editor do Supabase (pode ser reexecutado).
-- =====================================================================
create or replace function public.can_manage_master_data()
returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$
  -- Cadastros de materiais, funcionários e tabelas auxiliares: administrador e almoxarife.
  select public.has_any_role(array['admin', 'almoxarife']::public.app_role[]);
$$;

grant execute on function public.can_manage_master_data() to authenticated;

-- Policies de inclusão/alteração dos cadastros
do $$
declare
  t text;
begin
  foreach t in array array[
    'contracts', 'sectors', 'service_fronts', 'service_orders', 'fixed_assets',
    'application_locations', 'accounts', 'material_categories', 'employees', 'materials'
  ] loop
    execute format('drop policy if exists %I on public.%I', t || '_insert', t);
    execute format('drop policy if exists %I on public.%I', t || '_update', t);
    execute format('create policy %I on public.%I for insert to authenticated with check (public.can_manage_master_data())',
                   t || '_insert', t);
    execute format('create policy %I on public.%I for update to authenticated using (public.can_manage_master_data()) with check (public.can_manage_master_data())',
                   t || '_update', t);
  end loop;
end $$;

-- Funções de QR Code e importação
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

grant execute on function public.regenerate_material_qr(uuid) to authenticated;
grant execute on function public.import_materials(jsonb) to authenticated;
grant execute on function public.import_employees(jsonb) to authenticated;
