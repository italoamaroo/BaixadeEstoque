import { useState } from 'react';
import { AlertTriangle, MapPin, QrCode, Search, Trash2 } from 'lucide-react';
import { toast } from 'sonner';
import clsx from 'clsx';
import { cartTotals, removeCartItem, updateCartItem, type CartRules } from '@/lib/cart';
import { fmtQty, parseQty } from '@/lib/format';
import type { CartItem } from '@/types/db';
import { EmptyState } from '@/components/ui/Card';

interface Props {
  cart: CartItem[];
  setCart: (c: CartItem[]) => void;
  rules: CartRules;
  readOnly?: boolean;
}

function QtyInput({ value, onCommit, label, disabled }: { value: number; onCommit: (n: number) => boolean; label: string; disabled?: boolean }) {
  const [text, setText] = useState(fmtQty(value));
  const [focused, setFocused] = useState(false);
  const shown = focused ? text : fmtQty(value);
  return (
    <input
      aria-label={label}
      disabled={disabled}
      inputMode="decimal"
      className="h-10 w-full rounded-lg border-0 text-center text-base font-semibold tabular-nums ring-1 ring-inset ring-slate-300 focus:ring-2 focus:ring-brand-600 disabled:bg-slate-50"
      value={shown}
      onFocus={(e) => {
        setFocused(true);
        setText(fmtQty(value));
        requestAnimationFrame(() => e.target.select());
      }}
      onChange={(e) => setText(e.target.value.replace(/[^0-9.,]/g, ''))}
      onBlur={() => {
        setFocused(false);
        const n = parseQty(text);
        if (n !== value && !onCommit(n)) setText(fmtQty(value));
      }}
      onKeyDown={(e) => {
        if (e.key === 'Enter') (e.target as HTMLInputElement).blur();
      }}
    />
  );
}

/** "Carrinho" da ME: revisão e ajuste dos materiais antes de finalizar. */
export function CartList({ cart, setCart, rules, readOnly }: Props) {
  const totals = cartTotals(cart);

  if (cart.length === 0) {
    return (
      <EmptyState
        icon={<QrCode className="h-10 w-10" />}
        title="Nenhum material na ME"
        description="Leia o QR Code da etiqueta do material ou use a pesquisa manual."
      />
    );
  }

  const commit = (key: string, patch: Partial<Pick<CartItem, 'quantity_requested' | 'quantity_delivered' | 'notes'>>): boolean => {
    try {
      setCart(updateCartItem(cart, key, patch, rules));
      return true;
    } catch (err) {
      toast.error((err as Error).message);
      return false;
    }
  };

  return (
    <div className="space-y-3">
      <ul className="space-y-3">
        {cart.map((item, idx) => {
          const short = item.quantity_delivered < item.quantity_requested;
          return (
            <li key={item.key} className={clsx('rounded-xl border bg-white p-4', short ? 'border-orange-300' : 'border-slate-200')}>
              <div className="flex items-start justify-between gap-3">
                <div className="min-w-0">
                  <p className="text-xs font-medium text-slate-500">
                    Item {idx + 1} · {item.entry_method === 'qr_code' ? (
                      <span className="inline-flex items-center gap-1"><QrCode className="h-3 w-3" /> QR Code</span>
                    ) : (
                      <span className="inline-flex items-center gap-1"><Search className="h-3 w-3" /> pesquisa manual</span>
                    )}
                  </p>
                  <p className="font-semibold text-slate-900">{item.material.name}</p>
                  <p className="text-sm text-slate-500">
                    {item.material.code}
                    {item.material.reference ? ` · Ref. ${item.material.reference}` : ''} · {item.material.unit}
                    {item.material.location && (
                      <span className="ml-1 inline-flex items-center gap-0.5">
                        · <MapPin className="h-3 w-3" /> {item.material.location}
                      </span>
                    )}
                  </p>
                </div>
                {!readOnly && (
                  <button
                    type="button"
                    className="rounded-lg p-2 text-slate-400 hover:bg-red-50 hover:text-red-600"
                    aria-label={`Excluir ${item.material.name}`}
                    onClick={() => {
                      if (window.confirm(`Excluir "${item.material.name}" da ME?`)) setCart(removeCartItem(cart, item.key));
                    }}
                  >
                    <Trash2 className="h-5 w-5" />
                  </button>
                )}
              </div>

              <div className="mt-3 grid grid-cols-2 gap-3">
                <label className="text-xs font-medium text-slate-600">
                  Solicitada ({item.material.unit})
                  <QtyInput
                    label={`Quantidade solicitada de ${item.material.name}`}
                    value={item.quantity_requested}
                    disabled={readOnly}
                    onCommit={(n) => commit(item.key, { quantity_requested: n })}
                  />
                </label>
                <label className="text-xs font-medium text-slate-600">
                  Atendida ({item.material.unit})
                  <QtyInput
                    label={`Quantidade atendida de ${item.material.name}`}
                    value={item.quantity_delivered}
                    disabled={readOnly}
                    onCommit={(n) => commit(item.key, { quantity_delivered: n })}
                  />
                </label>
              </div>

              {short && (
                <div className="mt-3 space-y-2">
                  <p className="flex items-center gap-1.5 text-sm font-medium text-orange-700">
                    <AlertTriangle className="h-4 w-4" /> Diferença: {fmtQty(item.quantity_requested - item.quantity_delivered)} {item.material.unit} não atendido(s)
                  </p>
                  {!readOnly && (
                    <input
                      className="h-10 w-full rounded-lg border-0 px-3 text-sm ring-1 ring-inset ring-orange-300 focus:ring-2 focus:ring-orange-500"
                      placeholder="Observação (ex.: saldo insuficiente)"
                      defaultValue={item.notes}
                      maxLength={500}
                      onBlur={(e) => e.target.value !== item.notes && commit(item.key, { notes: e.target.value })}
                      aria-label="Observação da diferença"
                    />
                  )}
                </div>
              )}
              {!short && item.notes && <p className="mt-2 text-sm text-slate-600">Obs.: {item.notes}</p>}
              {readOnly && short && item.notes && <p className="mt-1 text-sm text-slate-600">Obs.: {item.notes}</p>}
            </li>
          );
        })}
      </ul>

      <div className="flex flex-wrap items-center justify-between gap-2 rounded-xl bg-slate-100 px-4 py-3 text-sm">
        <span>
          <strong>{totals.lines}</strong> {totals.lines === 1 ? 'item' : 'itens'}
        </span>
        <span className="text-slate-700">
          Total atendido:{' '}
          {totals.byUnit.map((u, i) => (
            <span key={u.unit}>
              {i > 0 && ' + '}
              <strong>{fmtQty(u.qty)}</strong> {u.unit}
            </span>
          ))}
        </span>
      </div>
    </div>
  );
}
