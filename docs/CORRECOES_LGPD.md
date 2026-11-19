# Correções técnicas do relatório LGPD e segurança

Esta entrega trata o código. Não certifica conformidade LGPD nem demonstra que uma migração foi aplicada em produção.
Não apaga MEs, assinaturas, fotos, modelos faciais ou retiradas offline pendentes.

## Implantação em banco existente: ordem obrigatória

1. Fazer backup e ensaiar a atualização em homologação, com pelo menos dois administradores conhecidos.
2. No Supabase Auth, habilitar cadastro e verificação de TOTP/MFA. Conservar um procedimento seguro de recuperação de conta pelo administrador do projeto Supabase.
3. Publicar primeiro o front-end deste PR. Enquanto a migração não existir, o painel continua acessível. Administradores devem abrir **Segurança** para cadastrar/verificar o autenticador. Após a migração, o segundo fator será exigido antes de acessar o painel. Confirmar o acesso de ambos com MFA. O PDF assinado fica indisponível com mensagem explícita até aplicar a migração; Excel permanece disponível. Nenhum segredo TOTP deve ser enviado pelo chat, e-mail, log ou capturas compartilhadas.
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
| A3/M2: retenção de modelos, tentativas e fila | Prazo de 10 anos confirmado pelo responsável também para cadastros faciais, logs, dados offline e backups. Definir os marcos das categorias sem conclusão de ME e implementar a política; prazo escolhido não equivale a prazo legal obrigatório. |
| Prova de vida | Continua sendo verificada no navegador e informada ao servidor. Não foi integrada solução de prova de vida independente nem criado atestado de identidade/recebimento. Depende de escolha de fornecedor, contrato, custos e dados permitidos. |
| M7/M8/M9 | Preencher controlador/canal, aprovar documentos, testar pedidos de titulares, confirmar pg_cron/contingência e protocolos de comunicação de incidentes. |
| M10/B10 | Conferir regiões, contratos, suboperadores, mecanismos de transferência quando aplicáveis, backups/PITR, RPO/RTO e restauração. |
| M11 — decisão registrada em 19/11/2026 | Catálogo de materiais compartilhado entre Muribeca e Dois Irmãos, conforme definição do responsável pelo projeto. Consulta para usuários ativos com papel autorizado; alterações e importações continuam dependentes das permissões de cadastro. MEs e movimentações permanecem restritas aos estoques autorizados. Ver [decisão na arquitetura](ARQUITETURA.md#decisão-de-negócio-catálogo-compartilhado-19112026). A escolha de negócio está resolvida; a validação operacional das policies permanece pendente. |
| B12 | O cenário vulnerável Node.js não foi demonstrado no PDF browser; atualização de jsPDF e revisão de advisories ficam para verificação específica de dependências. |
| Produção | Confirmar migrations, grants, default privileges, Auth, expiração/revogação de sessão, Storage e políticas realmente aplicados. Este PR não acessou o banco remoto. |

## Evidências de teste

- Suíte SQL inclui tentativas diretas sem papel, leitura de e-mail, admin AAL1/ausência de claim, AAL2, limites de cálculo, equipe SA sem assinatura/PDF e protocolo de exportação.
- Suítes existentes simulam admin já autenticado com AAL2; a suíte de endurecimento sobrescreve o claim para testar negações. Nenhum claim padrão foi adicionado à aplicação ou ao banco real.
- Testes frontend cobrem gate MFA, fila sem conta, isolamento da listagem, limpeza de rascunhos e limites de planilhas.

## Proposta de retenção definida pelo responsável (19/11/2026)

O responsável pelo projeto solicitou prazo de **10 anos** para guarda dos dados e confirmou os seguintes marcos para movimentações:

| Categoria | Prazo solicitado | Início da contagem |
|---|---|---|
| ME concluída e seus itens, registros de SA, fotos e assinaturas vinculados | 10 anos | Data de conclusão da ME (`completed_at`) |
| ME cancelada e seus itens, registros de SA, fotos e assinaturas vinculados | 10 anos | Data de cancelamento da ME (`cancelled_at`) |
| ME ainda não concluída nem cancelada | Não iniciar a contagem pelo critério acima | Aguardar o evento aplicável; revisar pendências antigas para evitar conservação sem necessidade |
| Cadastros faciais, tentativas, logs e incidentes sem vínculo direto com uma ME | 10 anos é a proposta solicitada, ainda sujeita a validação por categoria | Marco específico ainda não definido; não atribuir artificialmente uma conclusão de ME |

**Estado:** decisão de negócio registrada como proposta de política, sem validação jurídica presumida e sem alteração técnica dos prazos no Supabase. A aplicação geral a dados biométricos depende de comprovação de necessidade e base legal; a representação numérica do rosto continua sendo dado biométrico sensível. As regras vigentes de remoção do modelo facial ao inativar o funcionário não foram modificadas por este registro.

Antes de implementar descarte ou retenção: aprovar finalidade, necessidade, prazos e marcos por categoria com o jurídico; definir tratamento de retenção legal, backups e cópias; testar a execução. Este registro não autoriza guardar dados offline no aparelho por 10 anos: a fila pendente deve ser reconciliada e sua retenção local definida separadamente.

## Aplicação técnica da guarda de MEs — migração 28

O prazo solicitado para MEs e comprovantes foi implementado em `supabase/sql/28_retencao_mes.sql` (aplicar depois da migração 27).
O arquivo `07k` é a cópia usada em instalações novas. A política é lida do banco pelas RPCs `movement_retention_status` e `movement_retention_summary`, e exibida no detalhe da ME e na tela Segurança.

- Prazo de **10 anos civis**, calculado no fuso configurado da aplicação desde `completed_at` ou, em MEs canceladas, desde `cancelled_at`.
- Aplica-se também às MEs existentes, sem alterar suas datas, arquivos, itens ou histórico. Uma correção de material não reinicia a contagem; o prazo é derivado da data de encerramento registrada.
- MEs abertas aguardam encerramento. MEs encerradas sem data válida ficam pendentes de conferência, sem data final inventada.
- O fim do prazo sinaliza revisão pendente. Exclusões físicas continuam bloqueadas; esta migração não implementa descarte automático. Antes de qualquer eliminação, conferir necessidade, impedimentos e retenção legal.
- Os comprovantes seguem a ME, sem criar um prazo próprio a partir do upload. Não altera biometria, logs de segurança, incidentes, backups ou fila offline.
- O painel mostra pendência de migração enquanto a RPC não existir: publicar o site não aplica o SQL no Supabase.

Verificação após aplicar: `select public.movement_retention_summary();` deve ser chamada com sessão de gestor/admin autorizada; para testar pelo SQL Editor sem sessão de aplicação, prefira validar a existência das funções com `to_regprocedure` e conferir o painel com login real.

O registro anterior como proposta é o histórico da decisão. A implementação técnica desta seção não presume validação jurídica das demais categorias.

## Identificação de privacidade informada pelo responsável (19/11/2026)

Dados informados pelo responsável e com publicação no repositório público `italoamaroo/BaixadeEstoque` expressamente autorizada em 19/11/2026:

- **Controlador (razão social informada):** CONSORCIO RECIFE AMBIENTAL.
- **CNPJ informado do controlador:** 45.791.369/0001-06.
- **Encarregado (DPO) informado:** ITALO BRITO AMARO DA SILVA.
- **Canal informado para pedidos de privacidade:** italo.amaro@consorciorecifeambiental.com.br.
- **Telefone de contato informado:** (84) 99850-2396.

Esta identificação substitui o registro anterior que indicava Italo como controlador em nome próprio. A entidade controladora informada é o Consórcio; Italo foi indicado como encarregado. A indicação no sistema não comprova, por si só, designação formal do encarregado, validade cadastral do CNPJ ou publicação do aviso aos titulares. Não se presume atendimento por WhatsApp pelo simples fornecimento do telefone.

Após aplicar `supabase/operacoes/definir_responsaveis_privacidade.sql`, o responsável forneceu imagem do resultado da consulta no Supabase com os dados de identificação e contato. Essa evidência confirma a gravação apresentada, sem representar auditoria independente do ambiente.

O responsável confirmou a existência de termo assinado do DP e declarou expressamente que ele também abrange o reconhecimento facial para retirada de materiais. A existência e a abrangência declaradas ficam registradas; não se solicita nova confirmação desses fatos. O documento não foi examinado nesta revisão; a confirmação não constitui análise de seu conteúdo, da hipótese legal ou da necessidade do tratamento, nem comprova a designação formal do encarregado.


## Atualização da decisão de retenção (19/11/2026)

O responsável confirmou **o mesmo prazo de 10 anos** para cadastros faciais, logs, dados offline e backups, além das MEs e seus comprovantes. Esta decisão substitui a pendência de escolha do prazo dessas quatro categorias na proposta anterior. Não se trata de prazo legal obrigatório presumido.

A contagem de documentos vinculados à ME continua desde sua conclusão ou, se cancelada, desde o cancelamento. Para cadastros faciais, logs, dados offline e backups sem vínculo com uma ME, o responsável definiu expressamente a **data de criação de cada registro ou cópia** como início dos 10 anos. Não usar desligamento do funcionário, última utilização ou atualização como marco. Para backups, considerar a criação de cada cópia; a criação de uma cópia não reinicia a contagem dos registros de origem.

**Situação técnica:** a regra implementada pela migração 28 continua limitada às MEs e comprovantes. Este registro não modifica a remoção de modelos faciais, a expiração de logs, a limpeza de dados locais nem a política do provedor de backups. A guarda central de um registro originado offline e a permanência de sua cópia no aparelho são controles distintos; falta definir como executar a decisão para cada um.


### Marco confirmado para registros sem ME (19/11/2026)

Decisão do responsável: **10 anos desde a data de criação** para cadastros faciais, logs, dados offline e backups sem vínculo direto com ME. Esta decisão resolve a pendência do marco inicial dessas categorias nas seções anteriores. MEs e comprovantes vinculados mantêm o marco de conclusão/cancelamento já implementado. Registros sem data de criação confiável exigem conferência; não inventar datas. A confirmação registra a política, sem afirmar que sua implementação técnica ou a retenção do provedor de backups já foi alterada.


## Implementação da guarda adicional — migração 29

Implementados arquivo facial isolado do reconhecimento com criação original, piso de dez anos civis para descarte de logs (sem reduzir a guarda de logs vinculados a MEs), bloqueio de exclusão antecipada de tentativas faciais e de saídas offline pendentes pela interface, resumo administrativo com MFA e inventário de backups efetivamente gerados. Cópias temporárias de acesso continuam com validade própria; após sincronização, a evidência offline passa à ME.

A regra depende de aplicar `supabase/sql/29_retencao_adicional.sql` em produção. O script `scripts/backup-retention.py` e o procedimento de restauração estão preparados, mas destino externo, credenciais, agendamento e teste real de recuperação dependem do operador. Não foi configurada retenção nos provedores nem executado backup de produção. Detalhes e limitações: [RETENCAO_ADICIONAL.md](RETENCAO_ADICIONAL.md). As pendências históricas de implementação acima devem ser lidas à luz desta seção.
