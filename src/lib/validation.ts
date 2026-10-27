import { z } from 'zod';

const uuid = z.string().uuid();
const optionalText = (max: number, label: string) =>
  z.string().trim().max(max, `${label}: máximo de ${max} caracteres.`).optional().or(z.literal(''));

export const movementDetailsSchema = z.object({
  warehouse_id: uuid.or(z.literal('')).refine((v) => v !== '', 'Selecione o estoque de origem.'),
  contract_id: z.string().min(1, 'Selecione o contrato.'),
  sector_id: z.string().min(1, 'Selecione o setor.'),
  service_front_id: z.string().optional(),
  service_order_text: optionalText(40, 'Ordem de serviço'),
  fixed_asset_text: optionalText(40, 'Ativo fixo'),
  application_location_id: z.string().optional(),
  application_location_text: optionalText(120, 'Local de aplicação'),
  notes: optionalText(2000, 'Observações'),
});
export type MovementDetails = z.infer<typeof movementDetailsSchema>;

export const requesterSchema = z.object({
  requester_employee_id: z.string().min(1, 'Identifique o funcionário requisitante.'),
  received_by_employee_id: z.string().min(1, 'Identifique quem recebeu o material.'),
});

export function saNumberError(value: string, pattern: string): string | null {
  const v = value.trim().toUpperCase();
  if (!v) return 'Informe o número da SA.';
  try {
    if (!new RegExp(pattern).test(v)) {
      return 'Número da SA em formato inválido. Use letras, números, ponto, barra ou hífen (3 a 30 caracteres).';
    }
  } catch {
    if (!/^[A-Za-z0-9./-]{3,30}$/.test(v)) return 'Número da SA em formato inválido.';
  }
  return null;
}

export const justificationSchema = z
  .string()
  .trim()
  .min(5, 'Informe a justificativa (mínimo 5 caracteres).')
  .max(500, 'Justificativa: máximo de 500 caracteres.');

export const materialSchema = z.object({
  code: z
    .string()
    .trim()
    .min(1, 'Informe o código do material.')
    .max(40, 'Código: máximo 40 caracteres.')
    .regex(/^[A-Za-z0-9._/-]+$/, 'Código: use letras, números, ponto, barra, hífen ou sublinhado.'),
  reference: optionalText(80, 'Referência'),
  name: z.string().trim().min(2, 'Informe o nome do material.').max(200, 'Nome: máximo 200 caracteres.'),
  description: optionalText(500, 'Descrição'),
  unit: z
    .string()
    .trim()
    .min(1, 'Informe a unidade.')
    .max(10, 'Unidade: máximo 10 caracteres.')
    .regex(/^[A-Za-z0-9²³/]+$/, 'Unidade inválida (ex.: UN, L, KG, PC, CX).'),
  location: optionalText(40, 'Localização'),
  account_id: z.string().optional(),
  category_id: z.string().optional(),
  warehouse_id: z.string().optional(),
  qr_code: z
    .string()
    .trim()
    .regex(/^([A-Za-z0-9._:-]{4,80})?$/, 'QR Code: 4 a 80 caracteres (letras, números, ponto, hífen, dois-pontos).')
    .optional()
    .or(z.literal('')),
  active: z.boolean(),
});
export type MaterialForm = z.infer<typeof materialSchema>;

export const employeeSchema = z.object({
  registration: z.string().trim().min(1, 'Informe a matrícula.').max(30, 'Matrícula: máximo 30 caracteres.'),
  full_name: z.string().trim().min(3, 'Informe o nome completo.').max(160, 'Nome: máximo 160 caracteres.'),
  job_title: optionalText(80, 'Cargo'),
  sector_id: z.string().optional(),
  active: z.boolean(),
});
export type EmployeeForm = z.infer<typeof employeeSchema>;

export const lookupSchema = z.object({
  code: z.string().trim().min(1, 'Informe o código.').max(40, 'Código: máximo 40 caracteres.'),
  name: z.string().trim().min(2, 'Informe o nome/descrição.').max(160, 'Nome: máximo 160 caracteres.'),
  active: z.boolean(),
  kind: z.enum(['frente', 'equipamento']).optional(),
});
export type LookupForm = z.infer<typeof lookupSchema>;

export const warehouseSchema = z.object({
  code: z
    .string()
    .trim()
    .toUpperCase()
    .regex(/^[A-Z0-9]{2,6}$/, 'Código: 2 a 6 letras maiúsculas ou números (usado no número da ME).'),
  name: z.string().trim().min(2, 'Informe o nome do estoque.').max(80),
  active: z.boolean(),
});

export const newUserSchema = z.object({
  email: z.string().trim().toLowerCase().email('E-mail inválido.'),
  full_name: z.string().trim().min(3, 'Informe o nome completo.'),
  password: z
    .string()
    .min(8, 'A senha deve ter pelo menos 8 caracteres.')
    .regex(/[A-Za-z]/, 'A senha deve conter letras.')
    .regex(/\d/, 'A senha deve conter números.')
    .optional()
    .or(z.literal('')),
});

export const passwordSchema = z
  .string()
  .min(8, 'A senha deve ter pelo menos 8 caracteres.')
  .regex(/[A-Za-z]/, 'A senha deve conter letras.')
  .regex(/\d/, 'A senha deve conter números.');

/** Primeira mensagem de erro de um resultado zod, ou null. */
export function firstError(result: z.SafeParseReturnType<unknown, unknown>): string | null {
  if (result.success) return null;
  return result.error.issues[0]?.message ?? 'Dados inválidos.';
}

/** Mapa campo -> mensagem. */
export function fieldErrors(result: z.SafeParseReturnType<unknown, unknown>): Record<string, string> {
  if (result.success) return {};
  const out: Record<string, string> = {};
  for (const issue of result.error.issues) {
    const k = String(issue.path[0] ?? '_');
    if (!out[k]) out[k] = issue.message;
  }
  return out;
}
