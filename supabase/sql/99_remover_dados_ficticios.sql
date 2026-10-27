-- =====================================================================
-- 99 - REMOVER DADOS FICTÍCIOS (executar antes de entrar em produção)
-- Remove somente MEs marcadas como is_demo e cadastros com código "DEMO-".
-- Os registros de auditoria são mantidos.
-- =====================================================================
begin;

select set_config('app.purge_demo', 'on', true);

delete from public.stock_movement_items where movement_id in (select id from public.stock_movements where is_demo);
delete from public.signatures            where movement_id in (select id from public.stock_movements where is_demo);
delete from public.erp_sa_records        where movement_id in (select id from public.stock_movements where is_demo);
delete from public.movement_status_history where movement_id in (select id from public.stock_movements where is_demo);
delete from public.stock_movements where is_demo;

-- Arquivos de assinatura das MEs fictícias: remova pelo painel do Supabase
-- (Storage > assinaturas) ou pelo script "npm run demo:clean".

delete from public.material_qr_codes where material_id in (select id from public.materials where code like 'DEMO-%');
delete from public.materials where code like 'DEMO-%'
  and not exists (select 1 from public.stock_movement_items i where i.material_id = materials.id);
delete from public.employees where registration like 'DEMO-%'
  and not exists (select 1 from public.stock_movements m where m.requester_employee_id = employees.id or m.received_by_employee_id = employees.id)
  and not exists (select 1 from public.signatures s where s.employee_id = employees.id);
delete from public.service_orders        where code like 'DEMO-%' and not exists (select 1 from public.stock_movements m where m.service_order_id = service_orders.id);
delete from public.fixed_assets          where code like 'DEMO-%' and not exists (select 1 from public.stock_movements m where m.fixed_asset_id = fixed_assets.id);
delete from public.application_locations where code like 'DEMO-%' and not exists (select 1 from public.stock_movements m where m.application_location_id = application_locations.id);
delete from public.service_fronts        where code like 'DEMO-%' and not exists (select 1 from public.stock_movements m where m.service_front_id = service_fronts.id);
delete from public.accounts              where code like 'DEMO-%' and not exists (select 1 from public.materials m where m.account_id = accounts.id);
delete from public.sectors               where code like 'DEMO-%'
  and not exists (select 1 from public.stock_movements m where m.sector_id = sectors.id)
  and not exists (select 1 from public.employees e where e.sector_id = sectors.id);
delete from public.contracts             where code like 'DEMO-%' and not exists (select 1 from public.stock_movements m where m.contract_id = contracts.id);

-- Reinicia a numeração caso não exista nenhuma ME real
delete from public.movement_sequences ms
 where not exists (select 1 from public.stock_movements m where m.warehouse_id = ms.warehouse_id);

commit;
