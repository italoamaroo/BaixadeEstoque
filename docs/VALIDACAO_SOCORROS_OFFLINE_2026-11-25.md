# Validação de Socorros offline — 25/11/2026

Resultado: aprovados os cenários abaixo em ambiente isolado, com dados fictícios. Não houve criação de ME, uso de credenciais ou leitura de dados de produção.

## Navegador

Chromium com IndexedDB real, alternância efetiva da conectividade e o `public/sw.js` do projeto. A fila, o cliente de API e a sincronização são os módulos reais do sistema, empacotados em uma página local de teste. As respostas de Storage e RPC foram simuladas; a idempotência do banco foi verificada separadamente em PostgreSQL.

- Com internet desligada, grava o tipo socorro, materiais, quantidade, assinatura e data da retirada no IndexedDB.
- Outra conta não recebe a saída guardada pelo primeiro usuário.
- Sem rede não tenta transmitir nem apaga a fila.
- Recarregar a página sem internet usa o service worker e recupera a saída, assinatura e data original da gravação.
- Tentar guardar o mesmo identificador novamente não sobrescreve a primeira retirada.
- Queda simulada depois da criação no servidor, mas antes da resposta ao aparelho, mantém a fila pendente e a assinatura já enviada.
- A retentativa usa o mesmo UUID, tipo socorro e data; aproveita a assinatura enviada. Só remove a cópia de transporte depois da confirmação do servidor.
- Fila vazia não reenvia a saída.
- Servidor sem migração de Socorros bloqueia a criação comum e mantém a saída com erro no aparelho. Após habilitar o recurso, o reenvio explícito conclui a sincronização.

## PostgreSQL local

`supabase/tests/99f_testes_socorros_offline.sql`, incluído na suíte padrão:

- Uma retirada ocorrida duas horas antes recebe o horário original e a situação `aguardando_retorno`.
- Preserva `is_rescue=true`, sem emergência, SA ou conclusão prematura.
- Repetir o envio devolve a ME existente, sem duplicar cabeçalho ou itens.
- Retirada fora da janela de sete dias é recusada pela regra existente.
- A equipe exclusiva de SA não consulta o socorro antes da conferência do retorno.

A suíte SQL completa passou, incluindo auditoria íntegra, 80 MEs concorrentes e oito envios simultâneos de um mesmo identificador com apenas uma criação.

## Limites e operação

O teste valida a retirada offline e a sincronização. A conferência do retorno e o lançamento continuam sendo operações online, centralizadas no servidor; não foi implementada uma fila offline de devoluções.

O aparelho precisa ter carregado o sistema, a sessão e os cadastros autorizados previamente com internet. O teste local não substitui uma validação autenticada no aparelho de produção. Limpeza dos dados do navegador ou perda do aparelho pode remover dados locais; sincronizar assim que possível.
