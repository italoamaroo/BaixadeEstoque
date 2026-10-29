-- =====================================================================
-- 01 - EXTENSÕES E TIPOS
-- Sistema de Baixas de Estoque por QR Code - Consórcio Recife Ambiental
-- Executar no SQL Editor do Supabase, na ordem numérica dos arquivos.
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;
create extension if not exists pg_trgm with schema extensions;

-- Perfis de acesso
do $$ begin
  create type public.app_role as enum ('almoxarife', 'equipe_sa', 'gestor', 'admin');
exception when duplicate_object then null; end $$;

-- Status da ME (Movimentação de Estoque)
do $$ begin
  create type public.movement_status as enum (
    'rascunho',
    'aguardando_assinatura',
    'aguardando_aprovacao',
    'aguardando_sa',
    'sa_informada',
    'concluida',
    'cancelada'
  );
exception when duplicate_object then null; end $$;

-- Tipo de movimentação (o formulário em papel possui SAÍDA / ENTRADA)
do $$ begin
  create type public.movement_type as enum ('saida', 'entrada');
exception when duplicate_object then null; end $$;

-- Forma de inclusão do item na ME
do $$ begin
  create type public.item_entry_method as enum ('qr_code', 'pesquisa_manual');
exception when duplicate_object then null; end $$;

-- Ações registradas sobre a SA
do $$ begin
  create type public.sa_action as enum ('inclusao', 'correcao');
exception when duplicate_object then null; end $$;
