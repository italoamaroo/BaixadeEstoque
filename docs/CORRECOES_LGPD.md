# Correções técnicas do relatório LGPD e segurança

Esta entrega trata o código. Não certifica conformidade LGPD nem demonstra que uma migração foi aplicada em produção.
Não apaga MEs, assinaturas, fotos, modelos faciais ou retiradas offline pendentes.

## Implantação em banco existente: ordem obrigatória

1. Fazer backup e ensaiar a atualização em homologação, com pelo menos dois administradores conhecidos.
2. No Supabase Auth, habilitar cadastro e verificação de TOTP/MFA. Conservar um procedimento seguro de recuperação de conta pelo administrador do projeto Supabase.
3. Publicar primeiro o front-end deste PR. Administradores serão conduzidos ao cadastro/verificação do autenticador antes de acessar o painel. Confirmar o acesso de ambos com MFA. Nenhum segredo TOTP deve ser enviado pelo chat, e-mail, log ou capturas compartilhadas.
4. Aplicar **somente `supabase/sql/27_endurecimento_lgpd.sql`** no SQL Editor. O arquivo `07j` é sua cópia para instalação nova. Não reexecutar o SQL 06 isoladamente: ele remove policies de outras migrações.
5. Configurar `ALLOWED_ORIGIN=https://baixadeestoque.onrender.com` e `APP_URL=https://baixadeestoque.onrender.com` nos secrets da Edge Function. Restringir também a allow-list de redirects no painel Auth. Publicar `admin-users`. A função antiga também passa a exigir MFA através de `is_admin`, após a migração.
6. Validar usuários administrador com/sem MFA, gestor, equipe SA, almoxarife, terminal, usuário sem papel e usuário inativo. Usar consultas diretas à API em homologação, além da interface. Testar tablet e reenvio offline com assinatura.
7. Verificar GitHub Actions e build do Render. O Render passa a executar `npm run check`, incluindo testes antes de gerar o build. A instalação completa do banco é validada em CI separado; a proteção de branch e o bloqueio por esse job ainda devem ser conferidos na conta GitHub/Render.
8. Conferir headers CSP Report-Only e violações no navegador. Esta etapa não bloqueia scripts e não configura coletor externo. Criar endpoint de relatórios com minimização e política própria antes de enviar telemetria. Só passar a enforcement após teste com câmera, facial, impressão e PDF.

## Controles implementados

- **M1/B1**: usuário ativo precisa ter papel; ramos de leitura do balcão exigem atividade. Leitura direta de `profiles` expõe apenas id, nome e atividade; e-mail e demais campos passam pelas RPCs de acesso/administração. Diretório sem e-mail para filtros, limitado ao próprio usuário/admin e estoques autorizados. Nomes operacionais nas views continuam disponíveis para papéis operacionais.
- **M2 parcial**: limpa rascunhos/duplicação e caches de referência no logout; lista de fila sem usuário retorna vazia sem consultar IndexedDB. Pendências não enviadas são preservadas. A filtragem por usuário é proteção da interface, não criptografia contra outro usuário do mesmo perfil do navegador.
- **M3**: gate TOTP de cadastro/verificação; papéis administrativos exigem claim AAL2 assinado pelo Auth nas funções `has_role`/`has_any_role`. Interface sozinha não autoriza operação. `my_access` continua permitindo reconhecer a conta e apresentar a etapa MFA.
- **M4/O1 parcial**: exportação PDF com assinatura exclusiva de gestor/admin, autorizada e auditada por RPC no servidor antes da coleta de dados. Protocolo de solicitação retornado; evento significa autorização, não prova de download. RLS de assinaturas/Storage restringe gestor/admin e almoxarife responsável pela ME. Reenvio do próprio arquivo em estoque autorizado permanece permitido. URLs já emitidas podem funcionar até expirar; o PDF usa 10 minutos atualmente. A política de documentos do estoque permanece para decisão de negócio.
- **M5/B2**: revogada a função pública de relato de falha de login. A tela não fabrica mais eventos de falha de Auth; log nativo do Supabase continua sendo fonte de investigação. O importador existente não necessariamente traz todas as categorias de falha para os alertas internos: conferir cobertura e integração do provedor em produção. Eventos genéricos enviados pela interface são marcados `relato_da_tela`.
- **M6**: cálculo de dias úteis limitado a 366 dias adicionados/3660 dias de intervalo, rejeitando datas infinitas e intervalos extremos; limite adicional de iteração.
- **M12 parcial**: valida estrutura ZIP e tamanho expandido declarado antes do ExcelJS, com limites de registros, colunas, células e caracteres. Isso não substitui um parser com descompressão incremental limitada nem validações no servidor. Um worker cancelável e validação independente de conteúdo descomprimido continuam recomendados para arquivos hostis.
- **B5/B6/B7/B8/B9/B11**: origem obrigatória e redirect configurado no servidor, `.env.*` ignorado, CSP inicialmente report-only, Vite local por padrão (`--host` explícito para teste remoto), testes no build Render e auditoria de solicitação/resultado do provisionamento de usuário. Falha no registro inicial impede criação; falha no registro final gera aviso, porque a operação Auth já pode ter ocorrido.

## Pendências que exigem decisão ou acesso ao ambiente

| Tema | Responsável e próxima ação |
|---|---|
| A1/A2: biometria, base legal, necessidade, inventário e RIPD | Empresa/RH/jurídico: aprovar finalidades 1:N e 1:1, alternativas, hipótese legal aplicável, avisos e avaliação de risco. Não ampliar o uso antes dessa decisão. |
| A3/M2: retenção de modelos, tentativas e fila | Empresa/jurídico: aprovar prazos e exceções. Depois implementar expiração, eliminação/anonimização e cobertura de backups. Nenhum prazo legal foi inventado neste PR. |
| Prova de vida | Continua sendo verificada no navegador e informada ao servidor. Não foi integrada solução de prova de vida independente nem criado atestado de identidade/recebimento. Depende de escolha de fornecedor, contrato, custos e dados permitidos. |
| M7/M8/M9 | Preencher controlador/canal, aprovar documentos, testar pedidos de titulares, confirmar pg_cron/contingência e protocolos de comunicação de incidentes. |
| M10/B10 | Conferir regiões, contratos, suboperadores, mecanismos de transferência quando aplicáveis, backups/PITR, RPO/RTO e restauração. |
| M11 | Decidir catálogo de materiais global ou segregado antes de alterar RLS de cadastro. |
| B12 | O cenário vulnerável Node.js não foi demonstrado no PDF browser; atualização de jsPDF e revisão de advisories ficam para verificação específica de dependências. |
| Produção | Confirmar migrations, grants, default privileges, Auth, expiração/revogação de sessão, Storage e políticas realmente aplicados. Este PR não acessou o banco remoto. |

## Evidências de teste

- Suíte SQL inclui tentativas diretas sem papel, leitura de e-mail, admin AAL1/ausência de claim, AAL2, limites de cálculo, equipe SA sem assinatura/PDF e protocolo de exportação.
- Suítes existentes simulam admin já autenticado com AAL2; a suíte de endurecimento sobrescreve o claim para testar negações. Nenhum claim padrão foi adicionado à aplicação ou ao banco real.
- Testes frontend cobrem gate MFA, fila sem conta, isolamento da listagem, limpeza de rascunhos e limites de planilhas.
