-- =====================================================================
-- 11 - IMPORTAÇÃO DE FUNCIONÁRIOS POR PLANILHA (requisitantes/recebedores)
-- Executar uma vez no SQL Editor do Supabase (pode ser reexecutado).
-- Cada linha: {registration, full_name, job_title, sector, active}
--  - matrícula nova: inclui; matrícula existente: atualiza;
--  - células vazias mantêm o valor atual;
--  - setor é localizado pelo código ou pelo nome; se não existir, é criado.
-- =====================================================================
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
