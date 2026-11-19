-- 27: endurecimento técnico. Publicar o front-end com MFA ANTES de aplicar em produção.
-- Não apaga MEs, filas, modelos faciais ou auditoria; retenção depende de aprovação da empresa.
begin;

create or replace function public.session_is_aal2()
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'aal', '') = 'aal2';
$$;

-- Papel administrativo só é efetivo com segundo fator verificado pelo Supabase Auth.
create or replace function public.has_role(p_role public.app_role)
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from public.user_roles r join public.profiles p on p.id = r.user_id
    where r.user_id = auth.uid() and p.active and r.role = p_role
      and (r.role <> 'admin' or public.session_is_aal2()));
$$;
create or replace function public.has_any_role(p_roles public.app_role[])
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from public.user_roles r join public.profiles p on p.id = r.user_id
    where r.user_id = auth.uid() and p.active and r.role = any(p_roles)
      and (r.role <> 'admin' or public.session_is_aal2()));
$$;
create or replace function public.is_active_user()
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from public.profiles p where p.id = auth.uid() and p.active
    and exists (select 1 from public.user_roles r where r.user_id = p.id));
$$;

-- E-mails e perfis completos são obtidos pelas RPCs de acesso/administração, não pela tabela direta.
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select to authenticated
  using (id = auth.uid() or public.has_any_role(array['almoxarife','equipe_sa','gestor','admin']::public.app_role[]));
-- A policy controla linhas; privilégios de coluna impedem vazamento de e-mail via API direta.
revoke select on public.profiles from authenticated;
grant select (id,full_name,active) on public.profiles to authenticated;
create or replace function public.profile_directory()
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if not public.is_active_user() or not public.has_any_role(array['almoxarife','equipe_sa','gestor','admin']::public.app_role[]) then
    raise exception 'Acesso não permitido.' using errcode = '42501';
  end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'full_name',p.full_name,'active',p.active) order by p.full_name)
    from public.profiles p where p.id = auth.uid() or public.is_admin() or exists (
      select 1 from public.user_warehouses w where w.user_id = p.id and public.can_access_warehouse(w.warehouse_id)
    )), '[]'::jsonb);
end; $$;

drop policy if exists counter_sessions_select on public.counter_sessions;
create policy counter_sessions_select on public.counter_sessions for select to authenticated using (
  public.is_active_user() and (opened_by = auth.uid() or terminal_user_id = auth.uid()
    or (public.has_any_role(array['gestor','admin']::public.app_role[]) and public.can_access_warehouse(warehouse_id)))
);

-- Equipe SA pode exportar Excel; PDF com assinatura exige gestor/admin.
create or replace function public.can_read_signature(p_movement_id uuid)
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select public.can_access_movement(p_movement_id) and (
    public.has_any_role(array['gestor','admin']::public.app_role[])
    or (public.has_role('almoxarife') and exists (
      select 1 from public.stock_movements m where m.id = p_movement_id and m.created_by = auth.uid()
    )));
$$;
drop policy if exists signatures_select on public.signatures;
create policy signatures_select on public.signatures for select to authenticated using (public.can_read_signature(movement_id));
drop policy if exists "assinaturas: leitura por estoque autorizado" on storage.objects;
create policy "assinaturas: leitura por estoque autorizado" on storage.objects for select to authenticated using (
  bucket_id = 'assinaturas' and exists (
    select 1 from public.signatures s where s.storage_path = name and s.bucket = bucket_id
      and public.can_read_signature(s.movement_id)
  )
);
-- Permite verificar reenvio do próprio arquivo antes de sua vinculação (idempotência offline).
-- A permissão de criação continua limitada a pasta/estoque/papel nas policies anteriores.
drop policy if exists "assinaturas: verificar proprio envio" on storage.objects;
create policy "assinaturas: verificar proprio envio" on storage.objects for select to authenticated using (
  bucket_id = 'assinaturas' and owner = auth.uid() and public.is_active_user()
    and public.has_any_role(array['almoxarife','gestor','admin','terminal']::public.app_role[])
    and public.can_access_warehouse_code((storage.foldername(name))[1])
);

create or replace function public.authorize_signed_pdf_export(p_filters jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_total int;
  v_rows jsonb;
  v_id uuid := gen_random_uuid();
  v_tz text := coalesce((public.get_settings()).timezone, 'America/Recife');
begin
  if not public.has_any_role(array['gestor','admin']::public.app_role[]) then
    raise exception 'Somente gestor ou administrador pode exportar PDF com assinaturas.' using errcode = '42501';
  end if;
  if jsonb_typeof(p_filters) is distinct from 'object' then
    raise exception 'Filtros inválidos.' using errcode = '22023';
  end if;
  select count(*) into v_total from public.v_movements m where public.can_access_warehouse(m.warehouse_id) and public.movement_matches(m,p_filters,v_tz);
  select coalesce(jsonb_agg(to_jsonb(t) order by t.movement_at,t.id),'[]'::jsonb) into v_rows
    from (select m.* from public.v_movements m where public.can_access_warehouse(m.warehouse_id) and public.movement_matches(m,p_filters,v_tz)
          order by m.movement_at,m.id limit 500) t;
  perform public.audit_event('exportacao.pdf_autorizada','stock_movements',v_id::text,null,null,null,
    jsonb_build_object('protocolo',v_id,'quantidade',jsonb_array_length(v_rows),'total',v_total,
      'observacao','Solicitação autorizada; não comprova download no navegador.'));
  return jsonb_build_object('rows',v_rows,'total',v_total,'request_id',v_id);
end; $$;

-- Remover a entrada pública de relatos não verificáveis. Auth permanece fonte de falhas reais.
revoke all on function public.report_login_failure(text) from public, anon, authenticated;

create or replace function public.business_days_add(p_from date, p_days integer)
returns date language plpgsql stable security definer set search_path = public, pg_temp as $$
declare d date := p_from; n int := 0; scanned int := 0;
begin
  if p_from is null or p_days is null then return null; end if;
  if not isfinite(p_from) or p_days < 0 or p_days > 366 or p_from < date '1900-01-01' or p_from > date '2200-01-01' then
    raise exception 'Prazo fora do limite permitido (0 a 366 dias úteis).' using errcode = '22023';
  end if;
  while n < p_days loop
    d := d + 1; scanned := scanned + 1;
    if scanned > 1098 then raise exception 'Calendário sem dias úteis suficientes.' using errcode='22023'; end if;
    if public.is_business_day(d) then n := n + 1; end if;
  end loop;
  return d;
end; $$;
create or replace function public.business_days_between(p_from date, p_to date)
returns integer language plpgsql stable security definer set search_path = public, pg_temp as $$
declare n int;
begin
  if p_from is null or p_to is null then return null; end if;
  if not isfinite(p_from) or not isfinite(p_to) or p_from < date '1900-01-01' or p_to < date '1900-01-01'
    or p_from > date '2200-01-01' or p_to > date '2200-01-01' or abs(p_to-p_from) > 3660 then
    raise exception 'Intervalo fora do limite permitido (3660 dias).' using errcode = '22023';
  end if;
  select count(*)::int into n from generate_series(least(p_from,p_to)+1,greatest(p_from,p_to),interval '1 day') g
    where public.is_business_day(g::date);
  return case when p_to >= p_from then n else -n end;
end; $$;

-- Esta função só pode ser chamada pela Edge Function com service_role.
create or replace function public.audit_admin_provisioning(p_actor uuid,p_target text,p_stage text)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if p_stage not in ('solicitada','concluida','falha') or not exists (
    select 1 from public.profiles p join public.user_roles r on r.user_id=p.id
    where p.id=p_actor and p.active and r.role='admin'
  ) then raise exception 'Registro administrativo inválido.' using errcode='42501'; end if;
  perform public.audit_event('usuario.provisionamento_' || p_stage,'profiles',p_actor::text,null,null,null,
    jsonb_build_object('ator',p_actor,'destinatario',public.audit_mask_email(p_target),'etapa',p_stage));
end; $$;
revoke all on function public.audit_admin_provisioning(uuid,text,text) from public,anon,authenticated;
grant execute on function public.audit_admin_provisioning(uuid,text,text) to service_role;

do $$ declare f text; begin
  foreach f in array array['session_is_aal2()','profile_directory()','can_read_signature(uuid)','authorize_signed_pdf_export(jsonb)'] loop
    execute format('revoke all on function public.%s from public,anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
create or replace function public.log_event(
  p_action      text,
  p_movement_id uuid default null,
  p_details     jsonb default null
)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_wh uuid;
begin
  if not public.is_active_user() then
    raise exception 'Sessão inválida ou usuário inativo.' using errcode = '42501';
  end if;
  if p_action not in ('me.impressa', 'me.pdf_gerado', 'me.assinatura_consultada', 'me.foto_consultada',
                      'exportacao.excel', 'etiquetas.impressas', 'qr.leitura_nao_encontrada') then
    raise exception 'Evento não permitido.' using errcode = '22023';
  end if;
  if p_movement_id is not null then
    select warehouse_id into v_wh from public.stock_movements where id = p_movement_id;
    if v_wh is null or not public.can_access_warehouse(v_wh) then
      raise exception 'ME não encontrada.' using errcode = 'P0002';
    end if;
  end if;
  if p_details is not null and length(p_details::text) > 4000 then
    p_details := jsonb_build_object('aviso', 'detalhes truncados');
  end if;

  perform set_config('app.source','relato_da_tela',true);
  perform public.write_audit(p_action, case when p_movement_id is null then 'interface' else 'stock_movements' end,
                             p_movement_id::text, p_movement_id, v_wh, null, p_details, null);
end;
$$;
commit;
