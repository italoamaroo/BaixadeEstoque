import type { CartItem, EntryMethod, Material } from '@/types/db';

export interface CartRules {
  allowDeliveredAboveRequested: boolean;
  allowDuplicateLines: boolean;
}

export const DEFAULT_RULES: CartRules = {
  allowDeliveredAboveRequested: false,
  allowDuplicateLines: false,
};

export const MAX_QTY = 999_999;
export const MAX_ITEMS = 200;

export type DuplicateMode = 'somar' | 'separar';

export interface AddInput {
  material: Material;
  quantity_requested: number;
  quantity_delivered: number;
  entry_method: EntryMethod;
  scanned_code?: string | null;
  notes?: string;
}

let counter = 0;
function newKey(): string {
  counter += 1;
  return `${Date.now().toString(36)}-${counter}`;
}

export function findDuplicate(cart: CartItem[], materialId: string): CartItem | undefined {
  return cart.find((i) => i.material.id === materialId);
}

/** Valida quantidades de uma linha. Retorna mensagem de erro ou null. */
export function validateQuantities(req: number, del: number, rules: CartRules = DEFAULT_RULES): string | null {
  if (!Number.isFinite(req) || req <= 0) return 'A quantidade solicitada deve ser maior que zero.';
  if (!Number.isFinite(del) || del <= 0) return 'A quantidade atendida deve ser maior que zero.';
  if (req > MAX_QTY || del > MAX_QTY) return 'Quantidade acima do limite permitido.';
  if (!rules.allowDeliveredAboveRequested && del > req) {
    return 'A quantidade atendida não pode ser maior que a solicitada.';
  }
  const decimals = (n: number) => (String(n).split('.')[1] ?? '').length;
  if (decimals(req) > 3 || decimals(del) > 3) return 'Use no máximo 3 casas decimais.';
  return null;
}

/**
 * Adiciona um material à ME.
 * - mesmo material já presente + mode "somar": soma as quantidades na linha existente;
 * - mode "separar": cria nova linha (somente se a regra permitir).
 */
export function addToCart(cart: CartItem[], input: AddInput, mode: DuplicateMode = 'somar', rules: CartRules = DEFAULT_RULES): CartItem[] {
  if (!input.material.active) throw new Error('Material inativo não pode ser adicionado à ME.');
  const qtyError = validateQuantities(input.quantity_requested, input.quantity_delivered, rules);
  if (qtyError) throw new Error(qtyError);

  const existing = findDuplicate(cart, input.material.id);
  if (existing && mode === 'somar') {
    const req = round3(existing.quantity_requested + input.quantity_requested);
    const del = round3(existing.quantity_delivered + input.quantity_delivered);
    const err = validateQuantities(req, del, rules);
    if (err) throw new Error(err);
    return cart.map((i) =>
      i.key === existing.key
        ? { ...i, quantity_requested: req, quantity_delivered: del, notes: joinNotes(i.notes, input.notes) }
        : i,
    );
  }
  if (existing && mode === 'separar' && !rules.allowDuplicateLines) {
    throw new Error('A regra atual não permite o mesmo material em linhas separadas. Some as quantidades.');
  }
  if (cart.length >= MAX_ITEMS) throw new Error(`Limite de ${MAX_ITEMS} itens por ME.`);

  return [
    ...cart,
    {
      key: newKey(),
      material: input.material,
      quantity_requested: round3(input.quantity_requested),
      quantity_delivered: round3(input.quantity_delivered),
      entry_method: input.entry_method,
      scanned_code: input.scanned_code ?? null,
      notes: input.notes?.trim() ?? '',
    },
  ];
}

export function updateCartItem(
  cart: CartItem[],
  key: string,
  patch: Partial<Pick<CartItem, 'quantity_requested' | 'quantity_delivered' | 'notes'>>,
  rules: CartRules = DEFAULT_RULES,
): CartItem[] {
  return cart.map((i) => {
    if (i.key !== key) return i;
    const next = { ...i, ...patch };
    const err = validateQuantities(next.quantity_requested, next.quantity_delivered, rules);
    if (err) throw new Error(err);
    return { ...next, quantity_requested: round3(next.quantity_requested), quantity_delivered: round3(next.quantity_delivered) };
  });
}

export function removeCartItem(cart: CartItem[], key: string): CartItem[] {
  return cart.filter((i) => i.key !== key);
}

export function cartTotals(cart: CartItem[]) {
  const lines = cart.length;
  const requested = round3(cart.reduce((s, i) => s + i.quantity_requested, 0));
  const delivered = round3(cart.reduce((s, i) => s + i.quantity_delivered, 0));
  const shortLines = cart.filter((i) => i.quantity_delivered < i.quantity_requested).length;
  const byUnit = new Map<string, number>();
  for (const i of cart) byUnit.set(i.material.unit, round3((byUnit.get(i.material.unit) ?? 0) + i.quantity_delivered));
  return { lines, requested, delivered, shortLines, byUnit: [...byUnit.entries()].map(([unit, qty]) => ({ unit, qty })) };
}

/** Validação completa antes de finalizar. Retorna lista de problemas (vazia = ok). */
export function validateCart(cart: CartItem[], rules: CartRules = DEFAULT_RULES): string[] {
  const errors: string[] = [];
  if (cart.length === 0) errors.push('Adicione pelo menos um material à ME.');
  const seen = new Set<string>();
  cart.forEach((i, idx) => {
    const label = `Item ${idx + 1} (${i.material.name})`;
    if (!i.material.active) errors.push(`${label}: material inativo.`);
    const err = validateQuantities(i.quantity_requested, i.quantity_delivered, rules);
    if (err) errors.push(`${label}: ${err}`);
    if (seen.has(i.material.id) && !rules.allowDuplicateLines) errors.push(`${label}: material repetido.`);
    seen.add(i.material.id);
  });
  return errors;
}

export function toPayloadItems(cart: CartItem[]) {
  return cart.map((i) => ({
    material_id: i.material.id,
    quantity_requested: i.quantity_requested,
    quantity_delivered: i.quantity_delivered,
    entry_method: i.entry_method,
    scanned_code: i.scanned_code,
    notes: i.notes || null,
  }));
}

function round3(n: number): number {
  return Math.round(n * 1000) / 1000;
}

function joinNotes(a?: string, b?: string): string {
  return [a?.trim(), b?.trim()].filter(Boolean).join(' | ');
}
