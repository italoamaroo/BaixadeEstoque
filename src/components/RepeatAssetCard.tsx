import { Fragment, useState } from 'react';
import { Link } from 'react-router-dom';
import { AlertTriangle, ChevronDown, ChevronUp } from 'lucide-react';
import clsx from 'clsx';
import { Card, CardHeader } from './ui/Card';
import { Spinner } from './ui/Spinner';
import { fmtDateTime, fmtInt, fmtQty } from '@/lib/format';
import type { RepeatAssetWithdrawal } from '@/lib/api';

export const REPEAT_WINDOWS = [7, 15, 30] as const;

function gapLabel(days: number): string {
  if (days * 24 < 1) return 'menos de 1 hora';
  if (days < 1) {
    const h = Math.round(days * 24);
    return `${h} hora${h > 1 ? 's' : ''}`;
  }
  const d = Math.round(days * 10) / 10;
  return `${d.toLocaleString('pt-BR')} dia${d >= 2 ? 's' : ''}`;
}

/** Painel: mesmo ativo fixo retirando o mesmo material dentro da janela de dias. */
export function RepeatAssetCard({
  data,
  loading,
  days,
  onDaysChange,
}: {
  data: { total: number; items: RepeatAssetWithdrawal[] } | null;
  loading: boolean;
  days: number;
  onDaysChange: (d: number) => void;
}) {
  const [open, setOpen] = useState<string | null>(null);
  const items = data?.items ?? [];
  return (
    <div id="retiradas-repetidas" className="scroll-mt-20">
    <Card className={clsx(items.length > 0 && 'ring-2 ring-amber-300')}>
      <CardHeader
        title={
          <span className="flex items-center gap-2">
            <AlertTriangle className={clsx('h-5 w-5', items.length ? 'text-amber-600' : 'text-slate-400')} />
            Retiradas repetidas por ativo fixo
            {items.length > 0 && (
              <span className="rounded-full bg-amber-100 px-2 py-0.5 text-xs font-bold text-amber-800">{fmtInt(data?.total ?? items.length)}</span>
            )}
          </span>
        }
        subtitle={`Mesmo ativo fixo recebendo o mesmo material em MEs diferentes em até ${days} dias (MEs canceladas não contam).`}
        actions={
          <div className="inline-flex rounded-lg bg-slate-100 p-0.5 text-xs font-semibold">
            {REPEAT_WINDOWS.map((d) => (
              <button
                key={d}
                type="button"
                onClick={() => onDaysChange(d)}
                className={clsx('rounded-md px-3 py-1.5', days === d ? 'bg-white text-brand-800 shadow' : 'text-slate-600')}
              >
                {d} dias
              </button>
            ))}
          </div>
        }
      />
      {loading && !data ? (
        <div className="flex justify-center py-8">
          <Spinner />
        </div>
      ) : items.length === 0 ? (
        <p className="py-6 text-center text-sm text-emerald-700">Nenhuma retirada repetida no período filtrado.</p>
      ) : (
        <div className="overflow-x-auto">
          <table className="min-w-full text-sm">
            <thead className="bg-slate-50 text-left text-xs uppercase text-slate-500">
              <tr>
                <th className="px-3 py-2">Ativo fixo</th>
                <th className="px-3 py-2">Material</th>
                <th className="px-3 py-2 text-right">Retiradas</th>
                <th className="px-3 py-2 text-right">Qtd. total</th>
                <th className="px-3 py-2">Menor intervalo</th>
                <th className="px-3 py-2">Última</th>
                <th className="px-3 py-2" />
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100">
              {items.map((r) => {
                const key = `${r.asset}|${r.material_id}`;
                const expanded = open === key;
                return (
                  <Fragment key={key}>
                    <tr className="hover:bg-amber-50/50">
                      <td className="px-3 py-2">
                        <p className="font-mono font-semibold text-slate-900">{r.asset}</p>
                        {r.asset_name && <p className="text-xs text-slate-500">{r.asset_name}</p>}
                      </td>
                      <td className="px-3 py-2">
                        <p className="font-medium text-slate-900">{r.material_name}</p>
                        <p className="font-mono text-xs text-slate-500">{r.material_code}</p>
                      </td>
                      <td className="px-3 py-2 text-right font-bold text-amber-800">{fmtInt(r.times)}×</td>
                      <td className="whitespace-nowrap px-3 py-2 text-right">
                        {fmtQty(r.total_qty)} {r.unit}
                      </td>
                      <td className="whitespace-nowrap px-3 py-2 font-semibold">{gapLabel(Number(r.min_gap_days))}</td>
                      <td className="whitespace-nowrap px-3 py-2 text-slate-600">{fmtDateTime(r.last_at)}</td>
                      <td className="px-3 py-2 text-right">
                        <button
                          type="button"
                          onClick={() => setOpen(expanded ? null : key)}
                          className="inline-flex items-center gap-1 rounded-md px-2 py-1 text-xs font-semibold text-brand-700 hover:bg-brand-50"
                        >
                          MEs {expanded ? <ChevronUp className="h-3.5 w-3.5" /> : <ChevronDown className="h-3.5 w-3.5" />}
                        </button>
                      </td>
                    </tr>
                    {expanded && (
                      <tr className="bg-slate-50">
                        <td colSpan={7} className="px-3 py-2">
                          <ul className="space-y-1">
                            {r.occurrences.map((o) => (
                              <li key={o.movement_id} className="flex flex-wrap items-center gap-x-3 text-sm">
                                <Link to={`/movimentacoes/${o.movement_id}`} className="font-mono font-semibold text-brand-700 hover:underline">
                                  {o.me_number}
                                </Link>
                                <span className="text-slate-600">{fmtDateTime(o.movement_at)}</span>
                                <span>
                                  {fmtQty(o.quantity)} {r.unit}
                                </span>
                                <span className="text-slate-600">
                                  {o.requester} · {o.warehouse}
                                </span>
                              </li>
                            ))}
                          </ul>
                        </td>
                      </tr>
                    )}
                  </Fragment>
                );
              })}
            </tbody>
          </table>
        </div>
      )}
    </Card>
    </div>
  );
}
