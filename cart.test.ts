import { describe, expect, it } from 'vitest';
import { addToCart, cartTotals, removeCartItem, toPayloadItems, updateCartItem, validateCart, validateQuantities } from './cart';
import type { Material } from '@/types/db';

const mat = (over: Partial<Material> = {}): Material => ({
  id: 'm1', code: 'DEMO-0001', reference: 'SAE', name: 'Óleo', description: null, unit: 'L', location: 'A-01',
  account_id: null, category_id: null, warehouse_id: null, qr_code: 'MAT-DEMO000001', active: true, ...over,
});

describe('quantidades', () => {
  it('rejeita zero, negativo e atendida maior que solicitada', () => {
    expect(validateQuantities(0, 0)).toMatch(/maior que zero/);
    expect(validateQuantities(-1, 1)).toMatch(/maior que zero/);
    expect(validateQuantities(2, 0)).toMatch(/atendida deve ser maior que zero/);
    expect(validateQuantities(2, 3)).toMatch(/não pode ser maior/);
    expect(validateQuantities(2, 3, { allowDeliveredAboveRequested: true, allowDuplicateLines: false })).toBeNull();
    expect(validateQuantities(1.2345, 1)).toMatch(/3 casas/);
    expect(validateQuantities(5, 5)).toBeNull();
  });
});

describe('carrinho da ME', () => {
  it('adiciona material e soma leitura repetida', () => {
    let cart = addToCart([], { material: mat(), quantity_requested: 2, quantity_delivered: 2, entry_method: 'qr_code', scanned_code: 'MAT-DEMO000001' });
    cart = addToCart(cart, { material: mat(), quantity_requested: 3, quantity_delivered: 1, entry_method: 'qr_code' }, 'somar');
    expect(cart).toHaveLength(1);
    expect(cart[0].quantity_requested).toBe(5);
    expect(cart[0].quantity_delivered).toBe(3);
  });

  it('linha separada só quando a regra permite', () => {
    const cart = addToCart([], { material: mat(), quantity_requested: 1, quantity_delivered: 1, entry_method: 'qr_code' });
    expect(() => addToCart(cart, { material: mat(), quantity_requested: 1, quantity_delivered: 1, entry_method: 'qr_code' }, 'separar')).toThrow(/não permite/);
    const ok = addToCart(cart, { material: mat(), quantity_requested: 1, quantity_delivered: 1, entry_method: 'qr_code' }, 'separar', {
      allowDeliveredAboveRequested: false,
      allowDuplicateLines: true,
    });
    expect(ok).toHaveLength(2);
  });

  it('bloqueia material inativo e quantidade zero', () => {
    expect(() => addToCart([], { material: mat({ active: false }), quantity_requested: 1, quantity_delivered: 1, entry_method: 'qr_code' })).toThrow(/inativo/);
    expect(() => addToCart([], { material: mat(), quantity_requested: 0, quantity_delivered: 0, entry_method: 'qr_code' })).toThrow(/maior que zero/);
  });

  it('altera, remove e totaliza por unidade', () => {
    let cart = addToCart([], { material: mat(), quantity_requested: 4, quantity_delivered: 4, entry_method: 'qr_code' });
    cart = addToCart(cart, { material: mat({ id: 'm2', unit: 'UN', name: 'Filtro' }), quantity_requested: 2, quantity_delivered: 1, entry_method: 'pesquisa_manual' });
    cart = updateCartItem(cart, cart[0].key, { quantity_delivered: 3 });
    expect(() => updateCartItem(cart, cart[0].key, { quantity_delivered: 0 })).toThrow();
    const t = cartTotals(cart);
    expect(t.lines).toBe(2);
    expect(t.shortLines).toBe(2);
    expect(t.byUnit).toEqual([{ unit: 'L', qty: 3 }, { unit: 'UN', qty: 1 }]);
    cart = removeCartItem(cart, cart[1].key);
    expect(cart).toHaveLength(1);
    expect(toPayloadItems(cart)[0]).toMatchObject({ material_id: 'm1', quantity_requested: 4, quantity_delivered: 3, entry_method: 'qr_code' });
  });

  it('impede ME sem itens', () => {
    expect(validateCart([])).toContain('Adicione pelo menos um material à ME.');
  });
});
