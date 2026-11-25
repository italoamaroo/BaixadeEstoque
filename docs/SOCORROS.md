# Socorros

Socorros e Emergenciais são tipos separados. A opção **Retirada para socorro** está na nova saída e na abertura do balcão. O cadastro de saída e a confirmação da retirada usam as evidências e permissões existentes.

Após a retirada, a ME fica **Aguardando retorno do socorro**. Antes da conferência, usuários exclusivos da equipe SA não recebem essa ME, nem seus itens, pelas consultas protegidas. Não é permitido liberar SA/ERP antes do retorno.

O almoxarife do estoque (ou gestor/admin autorizado) confere com o mecânico cada quantidade utilizada e recebe fisicamente o restante. Todos os itens devem ser informados, inclusive utilizado zero. A soma utilizado + devolvido deve corresponder à retirada. Se houver divergência física, não confirmar: manter aberto até resolver.

A confirmação registra responsável, data, observação e histórico. A quantidade original fica em `rescue_quantity_out`, a devolvida em `rescue_quantity_returned`, e `quantity_delivered` passa a representar exclusivamente o utilizado para lançamento. Itens integralmente devolvidos não entram no Excel de itens para lançamento; a devolução continua nos detalhes e comprovante da ME. A assinatura original continua sendo evidência da retirada original, não uma nova assinatura de consumo.

Utilização integral: segue todo o consumo. Utilização parcial: segue apenas a parte utilizada. Sem utilização: conclui com consumo zero, sem SA/ERP e sem cancelar a retirada que de fato ocorreu. A aprovação já configurada continua sendo exigida após o retorno; sem ativo fixo mantém-se a regra existente de ir à baixa ERP sem SA.

A conferência é única, transacional e bloqueia alterações posteriores das quantidades por correção genérica. Uma segunda tentativa não repete a operação. Não modifica MEs antigas ou Emergenciais. Não altera automaticamente o estoque no ERP; o almoxarife continua responsável pela baixa efetiva.

## Aplicação

Banco existente: executar integralmente `supabase/sql/31_socorros.sql`, após a 30, sem envolver em outra transação (a nova situação exige a confirmação prévia do enum). Instalações novas usam `07n_socorros.sql` incluído no instalador. Publicar o front-end junto com a migração. Sem acesso administrativo conectado, a migração de produção precisa ser executada no SQL Editor pelo operador.
