-- =====================================================================
-- 14 - BAIXA NO ERP PELO ALMOXARIFE
-- Fluxo: almoxarife registra a ME -> equipe de SA informa o número da SA
-- -> almoxarife faz a baixa no ERP usando essa SA e confirma no sistema
-- (a ME passa para "Concluída").
-- Quem confirma: almoxarife (somente nos estoques dele), gestor e admin.
-- Executar uma vez no SQL Editor do Supabase (pode ser reexecutado).
-- =====================================================================
drop function if exists public.complete_movement(uuid);

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
    raise exception 'Somente MEs com SA informada podem ter a baixa no ERP confirmada (status atual: %).', v_m.status
      using errcode = 'P0001';
  end if;

  v_text := 'Baixa realizada no ERP com a SA ' || v_m.sa_number
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

revoke all on function public.complete_movement(uuid, text, text) from public;
grant execute on function public.complete_movement(uuid, text, text) to authenticated;
