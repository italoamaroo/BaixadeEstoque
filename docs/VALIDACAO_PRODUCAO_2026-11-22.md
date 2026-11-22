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
