# Estrutura e conferência do banco

## Uma única origem para cada módulo

- `src/main.tsx` inicia `src/App.tsx`.
- `src/pages/`: telas e rotas; `src/components/`: componentes visuais.
- `src/hooks/`: hooks; `src/lib/`: acesso à API, IndexedDB e regras auxiliares.
- `supabase/sql/`: instalação e atualizações; `supabase/tests/`: testes de banco.
- `tests/e2e/`: roteiros de navegador; `scripts/`: ferramentas locais.
- `public/`: arquivos publicados sem compilação, incluindo `sw.js`.

Os módulos soltos na raiz, as cópias em `src/` fora dessas pastas e o pacote parcial
`atualizacao-pdf/` foram removidos. O histórico Git preserva todas essas versões.
As variantes divergentes de Terminal e Pendências SA não foram ativadas automaticamente:
as rotas continuam usando os módulos já existentes em `src/pages/`.

As correções de IndexedDB, fila e sincronização offline foram consolidadas nos módulos
importados pelo aplicativo. Os testes de IndexedDB agora importam `src/lib/offlineDb.ts`,
o mesmo módulo utilizado pela fila, e verificam conclusão da transação e propagação de falhas.
O hook também tem testes de erro, troca de conta e respostas fora de ordem.

`npm run check:structure` evita novos módulos soltos na raiz e em `src/`.
Ao adicionar um novo arquivo legítimo de configuração na raiz, atualize a lista do verificador.

## O que foi recuperado do ZIP de referência

O ZIP `baixas-estoque.zip` fornecido pelo usuário foi comparado ao GitHub. Foram recuperados:

- Scripts de instalação `07b` a `07i`: balcão, retirada repetida, emergencial,
  auditoria, segurança/retenção, incidentes, pedidos de titulares e reconhecimento facial.
- Migrações `14` a `26`, incluindo `16a` e `16b`.
- Atualizações da base em `01`, `02`, `04`, `05` e `06`, compatíveis com esses recursos.
- Testes SQL e roteiros de homologação correspondentes.

Não foi consultado nem modificado o banco de produção. A existência de um arquivo no GitHub
não comprova que ele foi aplicado no Supabase. Os roteiros ponta a ponta foram recuperados,
mas exigem ambiente próprio e não são executados pelo workflow atual.

## Instalação nova

`npm run sql:montar` combina, em ordem, `01` a `08`, incluindo os complementos `07b` a `07i`.
O resultado é `supabase/instalar_completo.sql`; dados fictícios e scripts de testes ficam fora.
`npm run sql:check` verifica se o consolidado corresponde exatamente às fontes.

Use esse instalador em um projeto novo. Não execute os stubs de testes no Supabase.
Os arquivos `09` e `99` são dados fictícios e limpeza, não atualizações obrigatórias.

## Banco existente

Não reaplique indiscriminadamente o instalador completo: views de versões posteriores podem
ter colunas adicionais, e `CREATE OR REPLACE VIEW` não permite removê-las. A validação local
reproduziu esse erro ao tentar reinstalar a base sobre a versão completa.

Antes de atualizar, consulte o histórico do SQL Editor e o esquema real, faça backup e teste
as migrações em homologação. Aplique apenas o que faltar, respeitando os pré-requisitos:

| Ordem | Migração |
|---|---|
| 10–13 | Importações, cancelamento e cadastros pelo almoxarife |
| 14 | Confirmação de baixa no ERP |
| 15 | ME sem ativo fixo e importação de auxiliares |
| 16a | Perfil terminal; executar sozinho e concluir antes de 16b |
| 16b | Balcão de separação |
| 17 | Escolha e pareamento de tablet |
| 18 | Retirada repetida por ativo |
| 19 | Saída offline |
| 20 | Foto do solicitante |
| 21 | Contrato fixo e ME emergencial |
| 22 | Auditoria |
| 23 | Segurança, alertas e retenção |
| 24 | Incidentes |
| 25 | Pedidos de titulares |
| 26 | Reconhecimento facial |

Os complementos `07b`–`07i` são a versão integrada desses recursos para instalação nova;
não constituem uma segunda sequência de atualizações para executar após `26`.

## Validação e CI

`npm run check` verifica estrutura, geração de SQL, testes unitários e build.
`npm run test:sql` cria um banco temporário, instala o consolidado, carrega dados fictícios,
executa a suíte SQL e os testes de concorrência e remove o banco ao terminar.
Falhas SQL e de integridade encerram o comando com código diferente de zero.

O GitHub Actions executa os dois grupos de verificações com Node 22 e PostgreSQL 16.
Não altera Render nem Supabase. A aprovação do PR e a proteção de branch são configurações separadas.


### MEs nos dois estoques ao mesmo tempo

O teste `supabase/tests/20_teste_concorrencia.sh` executa dois lotes simultâneos,
com usuário de Muribeca e usuário de Dois Irmãos, cada lote com até 20 processos paralelos.
A suíte usa 40 MEs por estoque e verifica separadamente as 40 gravações em cada um,
além do total de 80, ausência de números duplicados e sequências sem buracos.
Também reenvia o mesmo formulário oito vezes simultaneamente e exige uma única ME.
São testes contra PostgreSQL local com stubs de Auth/Storage; não simulam dispositivos,
latência de rede real nem duas pessoas operando a interface em produção.
