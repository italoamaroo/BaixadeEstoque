# Tablet: retirada sem internet

Decisão do responsável: **antes da queda**, o almoxarife prepara e autoriza a lista; o mecânico apenas confere e assina no tablet. Não é permitido criar listas livres nem alterar materiais, quantidades, requisitante ou tipo no terminal.

## Preparação

1. Aplicar integralmente `supabase/sql/32_tablet_offline.sql` após a 31 no Supabase. O instalador de bancos novos inclui `07o_tablet_offline.sql`.
2. Publicar o aplicativo e atualizar o tablet ainda com internet.
3. O almoxarife abre a ME no balcão, pareia o terminal e finaliza a separação. A lista final deve aparecer no tablet com o solicitante correto.
4. Abrir **Retirada sem internet** para conferir que a lista autorizada já está disponível neste aparelho. Se a tela já estiver aberta, a lista aparece automaticamente ao chegar a autorização; o botão **Verificar lista autorizada** permite consultar novamente sem voltar ao balcão. Se ainda não houve finalização/pareamento ou faltar a migração, a tela bloqueia a confirmação e explica o preparo necessário.

O aparelho guarda somente a lista pareada, sem copiar todos os funcionários ou todas as MEs do estoque. A cópia é vinculada à conta, vale até sete dias desde a última atualização e sai do cache no logout. O código de pareamento é removido da cópia. Uma lista reaberta, cancelada ou substituída invalida a autorização local quando o servidor é consultado.

## Sem conexão

No menu do tablet há **Balcão ao vivo**, **Retirada sem internet** e **Saídas aguardando envio**. A nova tela segue o layout aprovado, com requisitante/tipo, tabela de materiais, autorização do almoxarife, foto e assinatura. Os dados autorizados são somente leitura.

O mecânico confere os materiais, registra a foto e assina. A indisponibilidade efetiva da câmera usa o motivo informado pelo componente existente, sem remover a exigência da assinatura. **Guardar confirmação no tablet** grava assinatura, foto e lista de forma atômica no IndexedDB. Só depois mostra a mensagem de dados guardados. Não declara confirmação no servidor antecipadamente.

A ME já existe porque foi preparada no balcão; a tela mostra seu número. O envio transmite apenas a confirmação para essa ME, sem criar outra retirada. Uma nova separação não preparada previamente continua dependendo de conexão e do almoxarife.

## Reconexão e validação

A fila é enviada automaticamente ao voltar a internet e permite nova tentativa manual. Assinatura e foto são reaproveitadas se o envio de parte das evidências já tiver concluído. A confirmação só sai da fila após o servidor responder com sucesso.

A nova RPC exige terminal ativo, pareamento atual, vínculo ao estoque e separação finalizada. Confere a versão da autorização, a data de finalização e todos os identificadores/quantidades da lista. Valida autoria das evidências, limita a assinatura a sete dias e recusa datas anteriores à autorização ou futuras. Não concede ao terminal permissão de criar MEs ou consultar outras movimentações.

Um comprovante imutável registra o identificador da confirmação, ME, terminal, horário capturado, horário do servidor e versão autorizada. O reenvio do mesmo identificador é idempotente. O horário original fica na assinatura e no recebimento; a auditoria identifica a sincronização posterior. A guarda do comprovante acompanha a ME, sem descarte automático.

Se a lista mudou, foi cancelada, reaberta ou transferida a outro terminal, o servidor bloqueia o envio. As evidências ficam no aparelho com a mensagem do erro para conferência pelo almoxarife; não são aplicadas a uma lista diferente. Não se deve limpar o navegador para remover uma pendência.

Socorros seguem aguardando o retorno após a confirmação; Emergenciais seguem sua regra de controle; MEs normais seguem a aprovação/SA/ERP existente. A conferência de retorno do Socorro continua online.

## Validação

- Testes de cache: autorização obrigatória, isolamento por conta, ausência de código de pareamento, identificador estável por versão, invalidação e expiração.
- Testes de fila: confirma a ME existente sem chamar criação, mantém evidências se a autorização mudou.
- PostgreSQL: confirma pelo terminal pareado, bloqueia versão e quantidades divergentes, data inválida e outro terminal; preserva o horário capturado e não duplica assinatura/comprovante.
- Navegador local com dados fictícios: interface real, IndexedDB, foto sintética e assinatura desenhada, rede desligada, fila persistente e reconexão com perda da primeira resposta. Duas chamadas de confirmação produziram um comprovante no servidor simulado; as evidências foram enviadas uma vez. SQL foi validado separadamente no banco local.
- Conferência visual em desktop e celular, sem transbordamento horizontal.

Esses testes não usaram credenciais, dados ou MEs de produção. A ativação e uma conferência no tablet real dependem da migração e do carregamento prévio da lista autorizada.
