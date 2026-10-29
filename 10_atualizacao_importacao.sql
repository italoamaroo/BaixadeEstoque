-- Atualização: importação de materiais preserva valores existentes quando a célula está vazia.
-- Executar uma vez no SQL Editor do Supabase.
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
