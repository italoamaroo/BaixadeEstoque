-- =====================================================================
-- 12 - CANCELAMENTO PELO ALMOXARIFE (devolução antes do lançamento no ERP)
-- Executar uma vez no SQL Editor do Supabase (pode ser reexecutado).
-- =====================================================================
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
  -- (status Aguardando SA ou Aguardando aprovação), no estoque autorizado.
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
  if not v_manager and v_m.status not in ('aguardando_sa', 'aguardando_aprovacao') then
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

grant execute on function public.cancel_movement(uuid, text) to authenticated;
