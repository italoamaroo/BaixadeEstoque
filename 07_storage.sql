-- =====================================================================
-- 07 - SUPABASE STORAGE: BUCKETS PRIVADOS E POLICIES
-- Estrutura dos arquivos:
--   assinaturas/{COD_ESTOQUE}/{ANO}/{ID_DA_ME}/assinatura_{timestamp}.png
--   documentos/{COD_ESTOQUE}/{ANO}/{ID_DA_ME}/{arquivo}   (PDFs e anexos futuros)
-- Nenhum bucket é público: a leitura usa URL assinada de curta duração.
-- Não há policy de UPDATE/DELETE: arquivos são imutáveis (evidência).
-- =====================================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  ('assinaturas', 'assinaturas', false, 1048576, array['image/png', 'image/jpeg', 'image/webp']),
  ('documentos',  'documentos',  false, 10485760, array['application/pdf', 'image/png', 'image/jpeg'])
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "assinaturas: leitura por estoque autorizado" on storage.objects;
drop policy if exists "assinaturas: envio por almoxarife/gestor/admin" on storage.objects;
drop policy if exists "documentos: leitura por estoque autorizado" on storage.objects;
drop policy if exists "documentos: envio por gestor/admin/almoxarife" on storage.objects;

-- Leitura: qualquer perfil ativo com acesso ao estoque da pasta
create policy "assinaturas: leitura por estoque autorizado"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'assinaturas'
    and public.can_access_warehouse_code((storage.foldername(name))[1])
  );

-- Envio: somente perfis que registram saídas, no estoque autorizado,
-- em pasta {ESTOQUE}/{ANO}/{UUID}/ e arquivo .png/.jpg/.webp
create policy "assinaturas: envio por almoxarife/gestor/admin"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'assinaturas'
    and public.has_any_role(array['almoxarife', 'gestor', 'admin']::public.app_role[])
    and public.can_access_warehouse_code((storage.foldername(name))[1])
    and (storage.foldername(name))[2] ~ '^[0-9]{4}$'
    and (storage.foldername(name))[3] ~ '^[0-9a-f-]{36}$'
    and name ~* '\.(png|jpe?g|webp)$'
  );

create policy "documentos: leitura por estoque autorizado"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'documentos'
    and public.can_access_warehouse_code((storage.foldername(name))[1])
  );

create policy "documentos: envio por gestor/admin/almoxarife"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'documentos'
    and public.has_any_role(array['almoxarife', 'gestor', 'admin']::public.app_role[])
    and public.can_access_warehouse_code((storage.foldername(name))[1])
  );
