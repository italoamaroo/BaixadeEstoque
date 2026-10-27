# Baixas de Estoque por QR Code

Aplicação web para controlar as **saídas de material** dos almoxarifados **Muribeca** e **Dois Irmãos**, do Consórcio Recife Ambiental. O fluxo cobre:

- leitura do QR Code;
- montagem da **ME (Movimentação de Estoque)**;
- assinatura digital de quem recebe;
- numeração única;
- acompanhamento até o número da **SA** do ERP;
- histórico, auditoria e exportação para Excel.

> Arquitetura, premissas, modelo de dados e regras: [`docs/ARQUITETURA.md`](docs/ARQUITETURA.md).

---

## 1. Visão geral

| Perfil | O que faz |
|---|---|
| **Almoxarife** | Seleciona o estoque, lê QR Codes (ou pesquisa), monta a ME, identifica o requisitante, colhe a assinatura e gera a ME. |
| **Equipe SA** | Acompanha as **Pendências de SA**, informa/corrige a SA (com justificativa) e conclui. |
| **Gestor** | Painel, consultas, assinaturas, histórico, Excel, aprovação, correção e cancelamento. |
| **Administrador** | Usuários, perfis, estoques, funcionários, materiais/QR Codes, tabelas auxiliares, parâmetros e auditoria. |

Ciclo de status: **Aguardando SA → SA informada → Concluída**. Quando a aprovação está ligada, há a etapa opcional **Aguardando aprovação**. Uma ME pode ir para **Cancelada** a qualquer momento (cancelamento lógico).

## 2. Tecnologias utilizadas

| Camada | Tecnologia |
|---|---|
| Front-end | React 18, TypeScript, Vite 5, Tailwind CSS 3, React Router 6 |
| Backend | Supabase: PostgreSQL, Auth, Storage, Realtime, Edge Function |
| Leitura de QR | `html5-qrcode` (câmera traseira) |
| Geração de QR | `qrcode` |
| Assinatura | `signature_pad` (canvas, dedo ou caneta) |
| Excel | `exceljs` (gerado no navegador com dados do Supabase) |
| Validação | `zod` (front) + `CHECK`/funções (banco) |
| Datas | `date-fns` (pt-BR) |
| Notificações | `sonner` |
| Gráficos | `recharts` |
| PDF | Impressão do navegador ("Salvar como PDF") com layout do formulário oficial |
| Hospedagem | Render (Static Site) |
| Testes | Vitest, testes SQL (PostgreSQL), teste ponta a ponta com Playwright |

## 3. Requisitos

- Node.js **20 ou superior** (recomendado 22) e npm.
- Uma conta e um projeto no **Supabase**.
- Uma conta no **Render**, com o repositório Git (GitHub/GitLab) conectado.
- Opcional, para publicar a função de usuários: [Supabase CLI](https://supabase.com/docs/guides/cli).
- Opcional, para testes de banco: PostgreSQL 15+ local (`psql`).

## 4. Instalação

```bash
git clone <seu-repositorio> baixas-estoque
cd baixas-estoque
npm install
cp .env.example .env      # preencha conforme a seção 9
```

## 5. Configuração do Supabase

1. Crie um projeto em <https://supabase.com> (região mais próxima: `South America (São Paulo)`).
2. Em **Authentication → Sign In / Providers → Email**:
   - mantenha o provedor E-mail habilitado;
   - desative **"Allow new users to sign up"**. Usuários serão criados apenas pelo administrador.
3. Em **Authentication → URL Configuration**:
   - **Site URL**: a URL do Render (ex.: `https://baixas-estoque.onrender.com`);
   - **Redirect URLs**: inclua `https://baixas-estoque.onrender.com/redefinir-senha` e `http://localhost:5173/redefinir-senha`.
4. Em **Project Settings → API**, copie a **Project URL** e a chave **anon public**. Elas são usadas no `.env` e no Render.

## 6. Execução do SQL

Abra **SQL Editor → New query** e execute **na ordem**:

| Ordem | Arquivo | Conteúdo |
|---|---|---|
| 1 | `supabase/sql/01_extensoes_e_tipos.sql` | extensões e ENUMs |
| 2 | `supabase/sql/02_tabelas.sql` | tabelas, relacionamentos, constraints e índices |
| 3 | `supabase/sql/03_funcoes_e_triggers.sql` | funções de permissão, `updated_at`, auditoria, histórico, proteções |
| 4 | `supabase/sql/04_rpc_movimentacoes.sql` | numeração segura da ME, view, filtros, criação da ME, SA, conclusão, cancelamento, correção, exportação, dashboard |
| 5 | `supabase/sql/05_rpc_administracao.sql` | QR Code, importação, usuários, parâmetros, primeiro admin |
| 6 | `supabase/sql/06_rls_e_permissoes.sql` | Row Level Security, policies, permissões de execução, Realtime |
| 7 | `supabase/sql/07_storage.sql` | buckets privados e policies do Storage |
| 8 | `supabase/sql/08_dados_iniciais.sql` | Muribeca, Dois Irmãos, parâmetros, categorias |
| 9 *(opcional)* | `supabase/sql/09_dados_ficticios.sql` | cadastros fictícios para demonstração |

**Atalho:** `supabase/instalar_completo.sql` junta os arquivos 1 a 8 em um só. Para regenerá-lo: `npm run sql:montar`.

Os scripts podem ser **reexecutados** com segurança (`create or replace`, `if not exists`, `on conflict`).

> Não execute `supabase/tests/00_stubs_supabase_local.sql` no Supabase. Ele existe só para testes em PostgreSQL local.

## 7. Criação dos buckets

O script `07_storage.sql` já cria os buckets privados:

| Bucket | Conteúdo | Tipos | Limite | Estrutura |
|---|---|---|---|---|
| `assinaturas` | assinaturas | PNG, JPG ou WEBP | 1 MB | `{ESTOQUE}/{ANO}/{ID_DA_ME}/assinatura_{timestamp}.png` |
| `documentos` | PDFs e anexos futuros | — | 10 MB | — |

Confira em **Storage**. Os dois buckets devem aparecer como **Private**.

## 8. Configuração das políticas

Também já aplicadas pelos scripts 06 e 07. Para conferir:

- **Database → Tables:** todas as tabelas com **RLS enabled**.
- **Authentication → Policies:**
  - leitura limitada aos estoques do usuário;
  - nenhuma policy de escrita nas tabelas de movimentação (gravação só pelas funções `create_movement`, `inform_sa`, `cancel_movement` etc.).
- **Storage → Policies:**
  - upload só no estoque autorizado;
  - leitura por URL assinada;
  - sem UPDATE/DELETE.

### Edge Function de usuários (recomendado)

A tela **Usuários → Novo usuário** usa a função `admin-users`. Ela roda no Supabase com a service_role, que nunca vai para o navegador.

```bash
npm i -g supabase            # ou use npx supabase
supabase login
supabase link --project-ref <ref-do-projeto>
supabase functions deploy admin-users
# opcional: restringir a origem
supabase secrets set ALLOWED_ORIGIN=https://baixas-estoque.onrender.com
```

Sem a função, crie o usuário em **Authentication → Users → Add user**. Depois, defina perfis e estoques na tela **Usuários → Acesso**.

## 9. Variáveis de ambiente

Arquivo `.env.example` (somente nomes, sem valores reais):

| Variável | Onde cadastrar | Descrição |
|---|---|---|
| `VITE_SUPABASE_URL` | `.env` local **e Render** | URL do projeto Supabase |
| `VITE_SUPABASE_ANON_KEY` | `.env` local **e Render** | chave pública *anon* |
| `SUPABASE_SERVICE_ROLE_KEY` | **somente** `.env` local, para `npm run demo:seed` | **nunca** no Render nem no front-end |
| `DEMO_PASSWORD` | somente `.env` local | senha dos usuários fictícios |

> As variáveis `VITE_*` são embutidas no build e ficam públicas, por isso só a chave **anon** é usada. A segurança é garantida pela RLS e pelas funções do banco.

## 10. Execução local

```bash
npm run dev          # http://localhost:5173
```

- A câmera funciona em `localhost`.
- Para testar no celular pela rede local, use HTTPS: o navegador só libera a câmera em conexão segura. O mais simples é testar pela URL do Render.

## 11. Build

```bash
npm run build        # verifica tipos e gera ./dist
npm run preview      # serve o build localmente
```

## 12. Publicação no Render

### Opção A — Blueprint (recomendado)

1. Envie o repositório para o GitHub/GitLab.
2. No Render, siga **New → Blueprint** e selecione o repositório. O arquivo `render.yaml` cria o Static Site.
3. Informe `VITE_SUPABASE_URL` e `VITE_SUPABASE_ANON_KEY` quando solicitado.
4. Aguarde o deploy e acesse a URL `https://<nome>.onrender.com`.

### Opção B — manual

**New → Static Site**, com:

| Campo | Valor |
|---|---|
| Build Command | `npm ci && npm run build` |
| Publish Directory | `dist` |
| Environment | `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY`, `NODE_VERSION=22` |
| Redirects/Rewrites | Source `/*`, Destination `/index.html`, Action **Rewrite** |

Sem a regra de rewrite, atualizar uma página interna (ex.: `/movimentacoes/123`) causa erro 404.

### Atualizações

- `git push` na branch `main` dispara um novo deploy automaticamente.
- Ao mudar variáveis no Render, use **Manual Deploy → Clear build cache & deploy**, porque as variáveis entram no build.
- Mudanças de banco: execute no SQL Editor o arquivo SQL alterado.

Depois do primeiro deploy, atualize a **Site URL** e as **Redirect URLs** no Supabase (seção 5).

## 13. Criação do primeiro administrador

1. Supabase → **Authentication → Users → Add user → Create new user**: informe seu e-mail e uma senha e marque **Auto Confirm User**.
2. No **SQL Editor**:
   ```sql
   select public.bootstrap_admin('seu.email@empresa.com.br', 'Seu Nome Completo');
   ```
   A função só funciona enquanto não existir nenhum administrador e não pode ser chamada pelo navegador.
3. Entre no sistema e, em **Usuários**, crie os demais usuários e defina perfis e estoques.

## 14. Dados fictícios

| Passo | Como | O que cria |
|---|---|---|
| 1 | Execute `supabase/sql/09_dados_ficticios.sql` | Cadastros: contratos, setores, frentes, equipamentos, OS, ativos, locais, contas, 8 funcionários e 12 materiais com QR Code fixo. O código **MAT-DEMO000012** é um material inativo, para testar o bloqueio. |
| 2 | Preencha `SUPABASE_SERVICE_ROLE_KEY` e `DEMO_PASSWORD` no `.env` e rode `npm run demo:seed` | 4 usuários fictícios e 36 MEs criadas **pelo fluxo real** (assinatura no Storage + RPC). Inclui MEs aguardando SA, com SA informada, concluídas e canceladas, distribuídas nos últimos 45 dias. |

Usuários fictícios criados no passo 2:

| E-mail | Perfil | Estoques |
|---|---|---|
| `demo.almox.muribeca@example.com` | almoxarife | Muribeca |
| `demo.almox.doisirmaos@example.com` | almoxarife | Dois Irmãos |
| `demo.equipe.sa@example.com` | equipe SA | ambos |
| `demo.gestor@example.com` | gestor | ambos |

**Como identificar o que é fictício:**

- códigos e matrículas começam com `DEMO-`;
- as MEs têm `is_demo = true`, aparecem com o selo "Dado fictício" e trazem "[DADO FICTÍCIO]" nas observações.

**Para remover antes da produção:**

1. Rode `npm run demo:clean` para apagar as assinaturas fictícias do Storage.
2. Execute `supabase/sql/99_remover_dados_ficticios.sql`.
3. Exclua os usuários `demo.*@example.com` em Authentication.

Para imprimir etiquetas de teste, use **Cadastros → Etiquetas QR Code**. Para simular a leitura sem câmera, digite o código, por exemplo `MAT-DEMO000001`.

## 15. Testes

| Comando | O que testa |
|---|---|
| `npm test` | Unitários (Vitest): carrinho (soma de leitura repetida, quantidade zero, atendida > solicitada, material inativo), filtros e nome do arquivo Excel, validação da SA, importação CSV, tradução de erros, caminho da assinatura, permissões. |
| `npm run typecheck` | Tipos TypeScript. |
| `PGHOST=… PGPORT=… PGUSER=… npm run test:sql` | Banco, em PostgreSQL local com *stubs* do Supabase (ver abaixo). |

Cobertura de `npm run test:sql`:

- **Permissões e RLS:** isolamento entre estoques, usuário sem perfil, almoxarife não informa SA e não exporta, ninguém altera auditoria.
- **Criação da ME:** QR inválido, não cadastrado e inativo; ME sem itens; quantidade zero; assinatura ausente ou não enviada; idempotência.
- **SA:** formato inválido, SA duplicada, correção com justificativa, ME concluída só corrigível por gestor.
- **Cancelamento:** cancelamento lógico que preserva itens e assinatura; exclusão física bloqueada.
- **Consultas:** filtros, exportação, dashboard e aprovação.
- **Concorrência:** 80 MEs simultâneas (40 por estoque) sem número duplicado nem buraco, e 8 envios simultâneos do mesmo formulário gerando 1 ME.

**Teste ponta a ponta (opcional)** — pasta `tests/e2e/`:

- Usa PostgREST + um gateway que simula Auth e Storage + Playwright.
- Percorre o fluxo pela interface:
  - login;
  - leitura por código, QR inexistente e material inativo;
  - soma de leitura repetida e pesquisa manual;
  - dados, requisitante, assinatura e duplo clique em "Confirmar";
  - ME gerada;
  - SA (formato inválido e válido) e conclusão;
  - detalhe, assinatura, impressão e Excel;
  - cancelamento com justificativa;
  - telas administrativas.

**Roteiro manual recomendado em homologação (celular real):**

1. Câmera negada e depois liberada.
2. Leitura de etiqueta impressa.
3. Modo avião durante "Confirmar e gerar ME": a ME **não** é confirmada e os dados permanecem. Ao reconectar, "Tentar novamente" gera uma única ME.
4. Duas pessoas registrando saídas ao mesmo tempo em Muribeca e Dois Irmãos.
5. Exportação filtrada por período e estoque.

## 16. Solução de problemas comuns

| Sintoma | Causa provável / solução |
|---|---|
| Tela "Configuração pendente" | `VITE_SUPABASE_URL`/`VITE_SUPABASE_ANON_KEY` ausentes no build. Cadastre no Render e faça *Clear build cache & deploy*. |
| 404 ao atualizar uma página interna | Falta o rewrite `/* → /index.html` (seção 12). |
| "Seu usuário ainda não tem perfil de acesso" | O administrador precisa definir perfil e estoques em **Usuários → Acesso**. |
| Câmera não abre | É preciso HTTPS (o Render já usa) e permissão do navegador. Em iPhone, use o Safari. Sempre é possível digitar o código ou pesquisar. |
| "Material não localizado" | QR Code de outro sistema ou material não cadastrado. Confira em **Materiais** (o campo QR Code). |
| "Arquivo da assinatura não encontrado" | O upload falhou. Toque em "Tentar novamente": a assinatura é reenviada sem perder os dados. |
| "A SA X já está vinculada à ME Y" | Regra de SA única. Confira o número ou desligue a regra em **Configurações**. |
| Criar usuário: "função admin-users não está publicada" | Publique a Edge Function (seção 8) ou crie o usuário pelo painel do Supabase. |
| Link de redefinição de senha não abre o sistema | Ajuste a Site URL e as Redirect URLs no Supabase (seção 5). |
| Painel não atualiza sozinho | Confira em **Database → Publications** se `supabase_realtime` inclui `stock_movements` (o script 06 faz isso). |

## 17. Estrutura de pastas

```
├── render.yaml                    # Blueprint do Render (Static Site + rewrite + headers)
├── .env.example
├── docs/ARQUITETURA.md            # entendimento, premissas, diagramas, regras, segurança, deploy
├── scripts/
│   ├── montar-sql.mjs             # gera supabase/instalar_completo.sql
│   ├── demo-seed.mjs              # usuários e MEs fictícias pelo fluxo real
│   ├── demo-clean-storage.mjs     # remove assinaturas fictícias do Storage
│   └── _env.mjs                   # leitura do .env + PNG de assinatura demonstrativa
├── supabase/
│   ├── sql/01..09, 99             # scripts do banco (ordem numérica)
│   ├── instalar_completo.sql      # 01..08 em um arquivo
│   ├── functions/admin-users/     # Edge Function (criação de usuários)
│   └── tests/                     # stubs locais, testes de fluxo, admin e concorrência
├── tests/e2e/                     # teste ponta a ponta (PostgREST + gateway + Playwright)
└── src/
    ├── App.tsx, main.tsx, index.css
    ├── types/db.ts                # tipos do banco
    ├── lib/                       # supabase, api, cart, filters, validation, excel, import,
    │                              # signature, draft, errors, format, constants (+ testes)
    ├── contexts/                  # AuthContext (sessão/perfis), WarehouseContext (estoque em operação)
    ├── hooks/                     # conexão, debounce, cadastros, realtime
    ├── components/                # layout, guardas de rota, QRScanner, SignaturePad, QRCodeImage,
    │   └── ui/                    # FiltersPanel, InformSaModal, EmployeePicker, MaterialSearch...
    └── pages/
        ├── LoginPage, ForgotPasswordPage, ResetPasswordPage, DashboardPage,
        │   MovementsPage, SaPendingPage, ExportPage
        ├── movimentacao/          # wizard da nova saída (estoque, itens, dados, requisitante,
        │                          # assinatura, revisão, sucesso)
        ├── detail/                # detalhe da ME, impressão, histórico, correção, nova assinatura
        └── admin/                 # materiais, etiquetas, funcionários, estoques, auxiliares,
                                   # usuários, perfis, auditoria, configurações
```

## 18. Regras principais do sistema

1. **Cada saída gera uma ME** com estoque de origem obrigatório, um ou mais itens, requisitante e assinatura.
2. **Numeração gerada no banco**, por estoque e ano, em transação: `ME-MUR-2026-000001`, `ME-DIR-2026-000001`.
   - O formato é configurável em **Configurações**.
   - O número tem `UNIQUE` e é separado do UUID interno.
3. **A ME só é considerada criada quando o Supabase confirma.** Até lá, nada aparece como concluído.
   - O rascunho fica no navegador apenas para não perder o preenchimento.
   - Reenvios usam o mesmo ID e não duplicam a ME.
4. **O QR Code contém só o identificador do material.** Os dados vêm sempre do cadastro mestre.
   - Ao gravar, a ME guarda uma **cópia** do material, para que alterações futuras no cadastro não mudem o histórico.
5. **Quantidades** devem ser maiores que zero.
   - A atendida não pode passar da solicitada (salvo parâmetro).
   - Diferenças ficam destacadas e podem ter observação.
6. **Assinatura obrigatória**, salva no Storage privado e imutável.
   - Nova assinatura exige gestor/admin e justificativa, e a anterior fica no histórico.
7. **A SA é informada depois** pela equipe SA, com formato validado e unicidade (parâmetro).
   - Correções exigem justificativa.
   - Após a conclusão, só gestor ou admin pode corrigir.
8. **Nada é apagado.**
   - ME: cancelamento lógico com justificativa.
   - Cadastros: inativação.
   - A exclusão física é bloqueada no banco.
9. **Auditoria completa e imutável** de criação, itens, assinatura, aprovação, SA, status, cancelamento, correções, impressão, exportação e cadastros.
10. **Permissões no banco**, não só na tela: RLS + funções com checagem de perfil e estoque.
11. **Indicadores sem misturar unidades**: quantidade de MEs, linhas de itens e soma de quantidades aparecem separados. As quantidades por material ficam na unidade do material.
