-- =====================================================================
-- 08 - DADOS INICIAIS (necessários para produção)
-- =====================================================================

insert into public.app_settings (id) values (1) on conflict (id) do nothing;

insert into public.warehouses (code, name) values
  ('MUR', 'Muribeca'),
  ('DIR', 'Dois Irmãos')
on conflict (code) do update set name = excluded.name;

insert into public.material_categories (code, name) values
  ('LUB', 'Lubrificantes'),
  ('FIL', 'Filtros'),
  ('PNE', 'Pneus e câmaras'),
  ('EPI', 'Equipamentos de proteção individual'),
  ('ELE', 'Elétrica automotiva'),
  ('ABR', 'Abrasivos e corte'),
  ('TRA', 'Transmissão'),
  ('ROL', 'Rolamentos'),
  ('GER', 'Uso geral')
on conflict (code) do nothing;
