# Retenção adicional de 10 anos

Decisão do responsável em 19/11/2026: cadastros faciais, logs, dados offline e backups sem vínculo com ME contam **10 anos desde a criação**. MEs e comprovantes continuam seguindo conclusão/cancelamento (migração 28). Prazo cumprido exige revisão; não há exclusão automática.

## Aplicação

1. Publicar o front-end atualizado.
2. No SQL Editor do Supabase, executar **todo** `supabase/sql/29_retencao_adicional.sql`, depois da 28. Não executar o instalador completo para atualizar produção.
3. Entrar como administrador com MFA e abrir Segurança. A nova seção deve apresentar o prazo e as contagens. Se faltar a migração, a tela avisa.
4. Conferência estrutural no SQL Editor:

```sql
select to_regprocedure('public.additional_retention_summary()') is not null as resumo_existe,
       to_regclass('public.employee_faces_archive') is not null as arquivo_facial_existe,
       to_regclass('public.retention_backups') is not null as inventario_backups_existe;
```

## Comportamento

- **Modelos faciais:** remoção manual, recadastro e inativação preservam os modelos anteriores em tabela isolada, com a data de criação original. O reconhecimento só consulta a base operacional; não recebe modelos arquivados. Não há leitura de descritores arquivados pela aplicação, nem pela chave de serviço via tabelas. Guardar o modelo não prova quem retirou material: confirmação da ME e evidências são registros próprios.
- **Logs da aplicação:** `_purge_candidates` exige dez anos civis desde `occurred_at`, o marco temporal do evento. Revalida inclusive pedidos de descarte antigos. Logs vinculados a ME também exigem que ela esteja encerrada com data válida e que seus dez anos desde conclusão/cancelamento tenham sido cumpridos. Retenção legal e dupla aprovação continuam valendo. A tabela legada de políticas usa dias para alertas e pode propor prazo maior; a regra de calendário impede descarte antes de dez anos mesmo se houver proposta menor. Os conteúdos já anonimizados não são recuperados.
- **Contadores legados de falha de login:** exclusão bloqueada por dez anos desde a janela do evento (`window_start`, marco legado disponível). A função pública continua revogada e não deve ser usada como fonte de falhas reais de Auth.
- **Tentativas faciais:** exclusão bloqueada durante os dez anos desde `created_at`.
- **Offline pendente:** criação local registrada em `saved_at`, sem reinício nas tentativas de envio. Descarte pela interface bloqueado antes dos dez anos; data desconhecida exige conferência. Após confirmação do servidor, a cópia de transporte é removida, pois os itens e assinatura passam a integrar a ME, sob sua regra de guarda. Isso é transferência, não perda da evidência. A limpeza do navegador, remoção do aparelho, quota e adulteração local não podem ser impedidas por JavaScript: sincronização continua necessária.
- **Caches:** cópias de consulta, rascunhos e autorização não são arquivo de prova. A validade de sete dias e limpeza no logout continuam sendo controles de atualização e acesso; não se autoriza acesso offline de dez anos. O histórico oficial está nas MEs e nos logs.
- **Backups:** cada cópia começa seu próprio prazo na criação. O inventário só recebe cópias geradas; instalar a migração não cria backup. O resumo nunca afirma que a retenção do provedor foi configurada. Não há modificação dos prazos de logs nativos de Supabase/Render.

O arquivo facial é aditivo; a migração não recupera modelos já apagados. Não altera conclusão de ME nem datas existentes. Registros cujo prazo venceu continuam preservados até procedimento específico de revisão. Não há RPC para descarte do arquivo facial nesta entrega.

## Backup cifrado de banco e Storage

`scripts/backup-retention.py` gera dump PostgreSQL e baixa todos os objetos dos buckets, grava manifesto com hashes, cifra o conjunto com chave pública GPG e registra o hash da cópia no banco. Não executar em produção sem preparar o destino de guarda.

Pré-requisitos operacionais:

- Pasta externa durável, privada e com capacidade para dez anos de cópias (`BACKUP_DIR`); configure retenção/versionamento/imutabilidade no armazenamento escolhido. A pasta temporária de Render ou deste ambiente não serve como destino definitivo.
- `pg_dump` compatível com a versão do PostgreSQL do projeto e GPG com chave pública importada. Guarde a chave privada de restauração em local separado, com acesso restrito.
- Serviço libpq (`PGSERVICE`) com acesso ao banco, configurado por arquivo de serviço e arquivo de senha de modo 0600. Não coloque senha na linha de comando, no Git ou neste documento.
- Variáveis `SUPABASE_URL` e `SUPABASE_SERVICE_ROLE_KEY` em ambiente protegido do operador (nunca no front-end); `BACKUP_GPG_RECIPIENT` é a impressão digital da chave pública conferida pelo operador.

Com essas variáveis configuradas, executar:

```sh
python3 scripts/backup-retention.py
```

O programa não agenda tarefas, não apaga backups e não transmite o arquivo para um destino adicional. `BACKUP_DIR` deve apontar ao armazenamento já montado e configurado pelo operador. Não imprime credenciais nem dados de objetos. Em falha de inventário após backup pronto, preserva o arquivo e informa os parâmetros para registro posterior com a função `register_retention_backup`, disponível somente à chave de serviço.

**Consistência:** banco usa o snapshot do `pg_dump`; download dos objetos não é atômico com esse snapshot. Execute em janela sem alterações de anexos, confira o manifesto e realize um teste de restauração antes de considerar a cópia utilizável. Frequência/agendamento, armazenamento e monitoramento de falhas precisam ser configurados pelo operador; não estão ativos pela publicação do código.

## Teste de restauração

Em ambiente isolado, sem usuários reais conectados: decifrar com a chave privada, verificar os hashes do manifesto, restaurar `database.dump` com `pg_restore` em PostgreSQL compatível e restaurar cada objeto ao bucket/caminho do manifesto. Conferir permissões privadas, referências de assinaturas/fotos, consulta de uma ME e integridade da auditoria. Uma lista de backups ou arquivo cifrado, sozinha, não comprova restauração.
