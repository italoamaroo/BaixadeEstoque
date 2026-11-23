# Validação parcial de produção — 22/11/2026

Ambiente: aplicação publicada em `baixadeestoque.onrender.com`. Escopo: navegação pública e consultas ao backend com a credencial **pública** do build, sem sessão de usuário. Nenhuma credencial privada, cookie ou token de sessão foi obtido. Nenhuma ME, pedido de titular ou incidente foi criado ou alterado.

**Resultado geral: PARCIAL. Não encerra a homologação de produção.**

## Verificado em produção

- A abertura de Segurança sem sessão redirecionou para a tela de login, observado no navegador. Isso comprova a proteção da rota da interface, não a autorização entre perfis.
- Login e aviso de privacidade responderam HTTP 200; o aviso apresenta o contato e a versão publicada.
- A configuração pública foi validada pelo endpoint público de configurações de Auth antes de interpretar as negativas de acesso.
- Consultas de um único identificador, sem leitura de nomes, e-mails, descritores ou comprovantes, foram recusadas para as tabelas abaixo.
- Nenhum teste autenticado foi marcado como aprovado: o acesso pelo formulário seguro não foi autorizado.

| Verificação sem sessão | HTTP | Resultado observado |
|---|---|---|
| `employees` | 401 | Acesso recusado nesta consulta |
| `profiles` | 401 | Acesso recusado nesta consulta |
| `stock_movements` | 401 | Acesso recusado nesta consulta |
| `audit_logs` | 401 | Acesso recusado nesta consulta |
| `employee_faces` | 401 | Acesso recusado nesta consulta |
| `employee_faces_archive` | 401 | Acesso recusado nesta consulta |
| `retention_backups` | 401 | Acesso recusado nesta consulta |
| `RPC: security_overview` | 401 | Acesso recusado nesta consulta |
| `RPC: dsr_overview` | 401 | Acesso recusado nesta consulta |
| `RPC: incident_overview` | 401 | Acesso recusado nesta consulta |
| `RPC: additional_retention_summary` | 401 | Acesso recusado nesta consulta |

Essas negativas não demonstram isolamento entre usuários autenticados, entre estoques, nem proteção de todas as funções e colunas.

## Cabeçalhos observados em /login

- HSTS presente: `max-age=315360000; includeSubdomains; preload`.
- `X-Content-Type-Options: nosniff` presente.
- `X-Frame-Options` e `Content-Security-Policy-Report-Only`, previstos no `render.yaml`, **não apareceram na resposta examinada**. Conferir os Headers do site estático e a aplicação do Blueprint no Render; o arquivo no GitHub, sozinho, não comprova configuração ativa. Esta observação é específica da resposta examinada.

Para corrigir a configuração no serviço existente, conferir os valores já definidos em `render.yaml`: `X-Frame-Options: DENY` e a política completa `Content-Security-Policy-Report-Only`. Não desativar autenticação ou permissões para realizar esses testes. Após aplicar, repetir a verificação HTTP. A política em report-only observa violações; não equivale a CSP bloqueante.

## Testes ainda pendentes por falta de autenticação

| Cenário | Evidência necessária |
|---|---|
| Administrador e MFA | Sessão real administrativa exige e valida o segundo fator antes de operações protegidas. |
| Almoxarife por estoque | Conta com acesso a um estoque não lê nem altera ME do outro, inclusive em requisição direta ao backend. |
| Equipe SA | Permissões operacionais autorizadas funcionam; assinatura/PDF e administração continuam restritos conforme regras. |
| Terminal do balcão | Apenas a separação pareada é apresentada e operações fora desse contexto são recusadas. |
| Pedido de titular | Protocolo, conferência de identidade, prazo, resposta e histórico validados em cenário de teste identificado, sem mensagens externas ou dados de terceiros. |
| Incidente | Registro, classificação, avaliação, prazos e encerramento validados em cenário claramente identificado como simulação; não comunicar ANPD ou titulares automaticamente. |

Não foram alterados perfis, senhas, permissões, configurações ou registros de negócio. O acesso autenticado precisa ser retomado pelo mecanismo seguro, sem fornecer senhas ou códigos no chat. Testes de escrita exigem cuidado com a identificação da simulação, pois a trilha de auditoria e os pedidos de titulares são preservados.


## Nova conferência em 23/11/2026

Requisições HTTPS sem autenticação, com `Cache-Control: no-cache`, para `/`, `/login` e `/aviso-de-privacidade.html` responderam HTTP 200. Em todas as três respostas, `X-Frame-Options`, `Content-Security-Policy-Report-Only` e uma eventual CSP bloqueante não estavam presentes. HSTS estava presente. Nenhuma configuração do Render foi alterada por esta conferência.

Os valores pretendidos continuam definidos em `render.yaml`. É necessário conferir os cabeçalhos do serviço existente no painel do Render ou sincronizar seu Blueprint, se o serviço for gerenciado por ele. Para a correção mínima, aplicar ao caminho `/*`: `X-Frame-Options` com valor `DENY` e `Content-Security-Policy-Report-Only` com a política completa definida no YAML. Não trocar report-only por uma CSP bloqueante sem validar os fluxos de câmera, autenticação e exportação. Depois de salvar a configuração, repetir a leitura dos cabeçalhos HTTP; publicar código sozinho não comprova aplicação desses valores.


## Cabeçalhos confirmados após configuração pelo responsável — 23/11/2026

Após o responsável informar que salvou as regras no painel do Render, novas requisições HTTPS com `Cache-Control: no-cache` a `/`, `/login` e `/aviso-de-privacidade.html` retornaram HTTP 200 com **`X-Frame-Options: DENY`** e **`Content-Security-Policy-Report-Only`**. A política recebida corresponde integralmente ao valor previsto em `render.yaml`. A pendência específica dos dois cabeçalhos está resolvida para as respostas examinadas. A CSP permanece em modo de observação (report-only), não em modo bloqueante. Esta confirmação não encerra os testes autenticados, a ativação de backups ou a avaliação de fornecedores.


## Teste administrativo acompanhado por imagens — 23/11/2026

O responsável executou **Rodar verificações agora** em seu próprio navegador. A imagem final mostra: `Verificações concluídas: integridade ok, 0 alerta(s), 0 evento(s) do Supabase Auth importados`, último horário exibido 23/11/2026 às 14:48 e pg_cron ativo, com verificação de hora em hora. A operação administrativa e seu retorno de sucesso foram observados por essa evidência; não houve sessão compartilhada com o assistente. A imagem não demonstra isoladamente a etapa de desafio MFA, nem o isolamento entre perfis/estoques. Zero eventos importados não comprova cobertura de todos os eventos do provedor.

**Pendência encontrada:** a seção `Guarda de cadastros faciais, logs e dados offline` continua com erro de consulta, embora a verificação administrativa tenha terminado com sucesso. Não marcar essa seção como aprovada. A mensagem genérica de rede do front-end também pode ser usada para timeouts; a imagem não identifica a causa técnica. Próxima verificação: recarregar a página para repetir a consulta; se persistir, obter o erro específico da RPC sem expor cabeçalhos de autenticação ou dados de titulares. Perfis/estoques, pedidos e incidentes continuam pendentes.


## Resumo de guarda adicional funcionando após SQL 30 — 23/11/2026

O responsável apresentou sucesso da execução da migração 30 no SQL Editor e, depois, captura de Segurança com a seção de guarda adicional carregada, exibindo categorias, contagens e próximos prazos, sem a mensagem de falha. A regra de dez anos desde a criação e a ausência de exclusão automática aparecem na tela. **O teste de carregamento dessa seção está aprovado pela evidência apresentada.** Os totais de produção não foram copiados para este relatório.

A imagem mostra zero backups registrados no inventário da aplicação; isso não demonstra presença ou ausência de backups nativos do provedor e não substitui ativação e restauração de cópia externa. A conclusão do carregamento não aprova isolamento entre perfis/estoques nem fluxos de pedidos de titulares e incidentes, que seguem para testes específicos.
