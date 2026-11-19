-- 28: prazo de guarda de MEs e comprovantes. Decisão do responsável: 19/11/2026.
-- Aplicar após a migração 27. Não apaga, anonimiza ou modifica MEs existentes.
-- Política operacional: 10 anos civis desde conclusão; canceladas, desde cancelamento.
-- O fim do prazo gera necessidade de revisão, não autorização automática para apagar.
begin;

create or replace function public.movement_retention_status(p_movement_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  m public.stock_movements;
  v_start timestamptz;
  v_until timestamptz;
  v_tz text := coalesce((public.get_settings()).timezone,'America/Recife');
  v_state text;
begin
  select * into m from public.stock_movements where id=p_movement_id;
  if m.id is null or not public.is_active_user() or not public.can_access_warehouse(m.warehouse_id) then
    raise exception 'ME não encontrada ou acesso não permitido.' using errcode='42501';
  end if;
  v_start := case when m.status='cancelada' then m.cancelled_at when m.status='concluida' then m.completed_at end;
  -- Aritmética de calendário: não usar 3650 dias (anos bissextos).
  v_until := ((v_start at time zone v_tz) + interval '10 years') at time zone v_tz;
  v_state := case when m.status not in ('concluida','cancelada') then 'aguardando_encerramento'
                  when v_start is null then 'data_de_encerramento_ausente'
                  when now() >= v_until then 'revisao_pendente' else 'em_guarda' end;
  return jsonb_build_object('movement_id',m.id,'years',10,
    'basis_event',case when m.status='cancelada' then 'cancelamento' when m.status='concluida' then 'conclusao' else null end,
    'started_at',v_start,'retain_until',v_until,'state',v_state,'timezone',v_tz,
    'scope',jsonb_build_array('ME','itens','registros de SA','fotos vinculadas','assinaturas vinculadas'),
    'automatic_deletion',false);
end; $$;

create or replace function public.movement_retention_summary()
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  v_result jsonb;
  v_tz text := coalesce((public.get_settings()).timezone,'America/Recife');
begin
  if not public.has_any_role(array['gestor','admin']::public.app_role[]) then
    raise exception 'Somente gestor ou administrador.' using errcode='42501';
  end if;
  with scoped as (
    select m.status,case when m.status='cancelada' then m.cancelled_at when m.status='concluida' then m.completed_at end as started_at
    from public.stock_movements m where public.can_access_warehouse(m.warehouse_id)
  ), deadlines as (
    select *,((started_at at time zone v_tz)+interval '10 years') at time zone v_tz as retain_until from scoped
  )
  select jsonb_build_object('years',10,'automatic_deletion',false,
    'awaiting_closure',count(*) filter(where status not in ('concluida','cancelada')),
    'missing_date',count(*) filter(where status in ('concluida','cancelada') and started_at is null),
    'retained',count(*) filter(where retain_until>now()),
    'review_due',count(*) filter(where retain_until<=now()),
    'next_review_at',min(retain_until) filter(where retain_until>now())) into v_result from deadlines;
  return v_result;
end; $$;
revoke all on function public.movement_retention_status(uuid),public.movement_retention_summary() from public,anon;
grant execute on function public.movement_retention_status(uuid),public.movement_retention_summary() to authenticated;
comment on function public.movement_retention_status(uuid) is
  'Guarda de MEs e comprovantes por 10 anos civis desde conclusão ou cancelamento; sem descarte automático. Não altera retenção de biometria ou logs.';
commit;
