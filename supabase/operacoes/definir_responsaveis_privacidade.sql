-- Aplicar no SQL Editor do projeto Supabase de produção, com a função postgres.
-- Dados fornecidos pelo responsável e publicação autorizada em 19/11/2026.
-- Atualiza somente a identificação e os canais de privacidade.
-- Não comprova designação formal do encarregado nem validação jurídica.
begin;

do $$
begin
  if not exists (select 1 from public.privacy_settings where id = true) then
    raise exception 'Configuração de privacidade ausente. Verifique a instalação antes de continuar.';
  end if;
end;
$$;

update public.privacy_settings
set controller_name = 'CONSORCIO RECIFE AMBIENTAL',
    controller_doc = '45.791.369/0001-06',
    dpo_name = 'ITALO BRITO AMARO DA SILVA',
    dpo_contact = 'italo.amaro@consorciorecifeambiental.com.br | (84) 99850-2396',
    titular_channel = 'italo.amaro@consorciorecifeambiental.com.br',
    updated_by = null, -- aplicação pelo SQL Editor; não atribuir a usuário anterior
    updated_at = now()
where id = true;

commit;

select controller_name, controller_doc, dpo_name, dpo_contact,
       titular_channel, updated_at
from public.privacy_settings
where id = true;
