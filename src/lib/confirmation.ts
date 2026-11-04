/**
 * Confirmação da retirada pelo solicitante, desacoplada do restante do balcão.
 *
 * Hoje: "assinatura" (assinatura digital no tablet, já usada no sistema).
 * Depois: "facial". O fornecedor escolhido (ex.: AWS Rekognition Face Liveness, Unico, idwall)
 * roda numa Edge Function do Supabase com a chave do fornecedor. A função compara o rosto
 * capturado com o cadastro facial do funcionário, grava o resultado em
 * public.confirmation_attempts (method = 'facial', result = 'sucesso' | 'falha', score, liveness)
 * usando a chave de serviço, e devolve o id da tentativa. O tablet então chama
 * counter_confirm(me, { method: 'facial', verification_id }). O banco só aceita uma
 * verificação com sucesso, recente (5 min), desta ME e ainda não utilizada.
 * Nada do balcão, do tempo real ou da ME precisa mudar para ligar o facial.
 */
export type ConfirmationMethod = 'assinatura' | 'facial';

export interface ConfirmationMethodInfo {
  id: ConfirmationMethod;
  label: string;
  available: boolean;
  description: string;
}

export const CONFIRMATION_METHODS: ConfirmationMethodInfo[] = [
  {
    id: 'assinatura',
    label: 'Assinatura digital',
    available: true,
    description: 'O solicitante assina na tela do tablet.',
  },
  {
    id: 'facial',
    label: 'Reconhecimento facial',
    available: false,
    description: 'Aguardando a definição do fornecedor (com prova de vida).',
  },
];

/** Método usado no tablet: o primeiro disponível na ordem de preferência. */
export function activeConfirmationMethod(): ConfirmationMethodInfo {
  return CONFIRMATION_METHODS.find((m) => m.id === 'facial' && m.available) ?? CONFIRMATION_METHODS[0];
}

/** Caminho da assinatura no bucket: {ESTOQUE}/{ANO da ME}/{ID da ME}/assinatura_balcao_{timestamp}.png */
export function counterSignaturePath(warehouseCode: string, movementId: string, movementAt: string, timeZone = 'America/Recife'): string {
  let year = new Date(movementAt).getFullYear();
  try {
    year = Number(new Intl.DateTimeFormat('en-US', { timeZone, year: 'numeric' }).format(new Date(movementAt)));
  } catch {
    /* fuso inválido: usa o ano local */
  }
  const stamp = new Date().toISOString().replace(/[-:.TZ]/g, '').slice(0, 17);
  return `${warehouseCode}/${year}/${movementId}/assinatura_balcao_${stamp}.png`;
}
