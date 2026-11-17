-- =====================================================================
-- 18 - ALERTA: MESMO ATIVO FIXO RETIRANDO O MESMO MATERIAL EM POUCOS DIAS
-- Lista, no Painel, os casos em que o mesmo ativo fixo recebeu o mesmo
-- material em MEs diferentes dentro de uma janela de dias (padrão 7).
-- Considera MEs confirmadas (exclui canceladas e as ainda em separação).
-- Visível somente para gestor e administrador.
-- Respeita os filtros do Painel (período, estoque etc.) para a ME mais
-- recente e a permissão de estoque de cada usuário (RLS).
-- Pode ser reexecutado.
-- =====================================================================
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
