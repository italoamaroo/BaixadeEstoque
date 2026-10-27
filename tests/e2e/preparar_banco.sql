-- Usuários e vínculos para o teste ponta a ponta (rodar após 00_stubs + sql/01..09)
do $$ begin if not exists (select 1 from pg_roles where rolname='authenticator') then create role authenticator login noinherit; end if; end $$;
grant anon, authenticated, service_role to authenticator;
insert into auth.users (id, email, raw_user_meta_data) values
 ('00000000-0000-0000-0000-00000000000a','admin@teste.local','{"full_name":"Ana Administradora"}'),
 ('00000000-0000-0000-0000-0000000000a1','almox.mur@teste.local','{"full_name":"Carlos Almoxarife"}'),
 ('00000000-0000-0000-0000-0000000000b1','sa@teste.local','{"full_name":"Beatriz Equipe SA"}'),
 ('00000000-0000-0000-0000-0000000000c1','gestor@teste.local','{"full_name":"Marcos Gestor"}')
on conflict do nothing;
select public.bootstrap_admin('admin@teste.local','Ana Administradora');
insert into user_roles(user_id, role) values ('00000000-0000-0000-0000-0000000000a1','almoxarife'),('00000000-0000-0000-0000-0000000000b1','equipe_sa'),('00000000-0000-0000-0000-0000000000c1','gestor') on conflict do nothing;
insert into user_warehouses select '00000000-0000-0000-0000-0000000000a1', id from warehouses where code='MUR' on conflict do nothing;
insert into user_warehouses select u, w.id from warehouses w, unnest(array['00000000-0000-0000-0000-0000000000b1','00000000-0000-0000-0000-0000000000c1']::uuid[]) u on conflict do nothing;
