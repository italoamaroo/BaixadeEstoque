import { useCallback, useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { CheckCheck, Hourglass, Search } from 'lucide-react';
import { toast } from 'sonner';
import clsx from 'clsx';
import { useAuth } from '@/contexts/AuthContext';
import { InformSaModal } from '@/components/InformSaModal';
import { Button } from '@/components/ui/Button';
import { Badge } from '@/components/ui/Badge';
import { Alert, EmptyState, PageHeader } from '@/components/ui/Card';
import { Pagination } from '@/components/ui/Pagination';
import { PageLoader } from '@/components/ui/Spinner';
import { completeMovement, searchMovements, type SearchResult } from '@/lib/api';
import { errorMessage } from '@/lib/errors';
import { daysSince, fmtDateTime } from '@/lib/format';
import { EMPTY_FILTERS } from '@/lib/filters';
import { useRealtimeMovements } from '@/hooks/useRealtimeMovements';
import type { MovementRow } from '@/types/db';

type Tab = 'aguardando_sa' | 'sa_informada';

function AgeBadge({ since }: { since: string }) {
  const d = daysSince(since);
  const style = d > 7 ? 'bg-red-50 text-red-700 ring-red-300' : d > 3 ? 'bg-orange-50 text-orange-800 ring-orange-300' : 'bg-amber-50 text-amber-800 ring-amber-300';
  return <Badge className={style}>{d === 0 ? 'Hoje' : d === 1 ? '1 dia' : `${d} dias`}</Badge>;
}

export function SaPendingPage() {
  const { warehouses, can } = useAuth();
  const [tab, setTab] = useState<Tab>('aguardando_sa');
  const [warehouseId, setWarehouseId] = useState('');
  const [q, setQ] = useState('');
  const [query, setQuery] = useState('');
  const [page, setPage] = useState(1);
  const [data, setData] = useState<SearchResult | null>(null);
  const [counts, setCounts] = useState<Record<Tab, number>>({ aguardando_sa: 0, sa_informada: 0 });
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [target, setTarget] = useState<MovementRow | null>(null);
  const [completing, setCompleting] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    const base = { ...EMPTY_FILTERS, warehouse_id: warehouseId, q: query };
    try {
      const [rows, a, b] = await Promise.all([
        searchMovements({ ...base, status: [tab] }, page, 25, 'movement_at', 'asc'),
        searchMovements({ ...base, status: ['aguardando_sa'] }, 1, 1, 'movement_at', 'asc'),
        searchMovements({ ...base, status: ['sa_informada'] }, 1, 1, 'movement_at', 'asc'),
      ]);
      setData(rows);
      setCounts({ aguardando_sa: a.total, sa_informada: b.total });
      setError(null);
    } catch (err) {
      setError(errorMessage(err));
    } finally {
      setLoading(false);
    }
  }, [tab, warehouseId, query, page]);

  useEffect(() => {
    void load();
  }, [load]);
  useRealtimeMovements(() => void load());

  const complete = async (m: MovementRow) => {
    if (completing) return;
    setCompleting(m.id);
    try {
      await completeMovement(m.id);
      toast.success(`${m.me_number} concluída.`);
      void load();
    } catch (err) {
      toast.error(errorMessage(err));
    } finally {
      setCompleting(null);
    }
  };

  return (
    <div>
      <PageHeader title="Pendências de SA" subtitle="MEs aguardando o lançamento no ERP e o número da SA. As mais antigas aparecem primeiro." />

      <div className="mb-4 flex flex-wrap items-center gap-2">
        <div className="inline-flex rounded-xl bg-slate-100 p-1">
          {(
            [
              ['aguardando_sa', 'Aguardando SA'],
              ['sa_informada', 'SA informada (a concluir)'],
            ] as [Tab, string][]
          ).map(([k, label]) => (
            <button
              key={k}
              type="button"
              onClick={() => {
                setTab(k);
                setPage(1);
              }}
              className={clsx('rounded-lg px-3 py-2 text-sm font-semibold', tab === k ? 'bg-white text-brand-800 shadow' : 'text-slate-600')}
            >
              {label} <span className="ml-1 rounded-full bg-slate-200 px-2 text-xs">{counts[k]}</span>
            </button>
          ))}
        </div>
        <select
          className="h-10 rounded-lg border-0 pl-3 pr-8 text-sm ring-1 ring-inset ring-slate-300"
          value={warehouseId}
          onChange={(e) => {
            setWarehouseId(e.target.value);
            setPage(1);
          }}
          aria-label="Estoque"
        >
          <option value="">Todos os estoques</option>
          {warehouses.map((w) => (
            <option key={w.id} value={w.id}>
              {w.name}
            </option>
          ))}
        </select>
        <form
          className="relative min-w-[220px] flex-1"
          onSubmit={(e) => {
            e.preventDefault();
            setQuery(q);
            setPage(1);
          }}
        >
          <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-slate-400" />
          <input
            className="h-10 w-full rounded-lg border-0 pl-9 pr-3 text-sm ring-1 ring-inset ring-slate-300 focus:ring-2 focus:ring-brand-600"
            placeholder="ME, requisitante ou material (Enter)"
            value={q}
            onChange={(e) => setQ(e.target.value)}
          />
        </form>
      </div>

      <div className="rounded-xl border border-slate-200 bg-white shadow-card">
        {error && (
          <div className="p-4">
            <Alert tone="error">{error}</Alert>
          </div>
        )}
        {loading && !data ? (
          <PageLoader />
        ) : data && data.rows.length === 0 ? (
          <EmptyState
            icon={<CheckCheck className="h-10 w-10 text-emerald-500" />}
            title={tab === 'aguardando_sa' ? 'Nenhuma ME aguardando SA' : 'Nenhuma ME aguardando conclusão'}
            description="Tudo em dia para os filtros selecionados."
          />
        ) : data ? (
          <>
            <ul className={clsx('divide-y divide-slate-100', loading && 'opacity-60')}>
              {data.rows.map((m) => (
                <li key={m.id} className="grid gap-3 px-4 py-3 md:grid-cols-[1fr_auto] md:items-center">
                  <div className="min-w-0">
                    <div className="flex flex-wrap items-center gap-2">
                      <Link to={`/movimentacoes/${m.id}`} className="font-mono text-sm font-semibold text-brand-700 hover:underline">
                        {m.me_number}
                      </Link>
                      <Badge className="bg-slate-100 text-slate-700 ring-slate-300">{m.warehouse_name}</Badge>
                      <AgeBadge since={tab === 'aguardando_sa' ? m.movement_at : (m.sa_informed_at ?? m.movement_at)} />
                      {m.sa_number && <span className="font-mono text-xs text-slate-600">SA {m.sa_number}</span>}
                    </div>
                    <p className="mt-1 text-sm text-slate-900">
                      {m.requester_name} <span className="text-slate-500">· {m.item_count} {m.item_count === 1 ? 'item' : 'itens'}</span>
                    </p>
                    <p className="text-xs text-slate-500">
                      {fmtDateTime(m.movement_at)} · {m.sector_name}
                      {m.service_front_name ? ` · ${m.service_front_name}` : ''} · Baixa: {m.storekeeper_name}
                    </p>
                    <p className="truncate text-xs text-slate-500">{m.materials_summary}</p>
                  </div>
                  <div className="flex gap-2">
                    {tab === 'aguardando_sa' ? (
                      can('informSa') && (
                        <Button variant="warning" icon={<Hourglass className="h-4 w-4" />} onClick={() => setTarget(m)}>
                          Informar SA
                        </Button>
                      )
                    ) : (
                      <>
                        <Button variant="secondary" onClick={() => setTarget(m)}>
                          Corrigir SA
                        </Button>
                        {can('completeMovement') && (
                          <Button variant="success" icon={<CheckCheck className="h-4 w-4" />} loading={completing === m.id} onClick={() => void complete(m)}>
                            Concluir
                          </Button>
                        )}
                      </>
                    )}
                  </div>
                </li>
              ))}
            </ul>
            <Pagination page={page} pageSize={25} total={data.total} onPage={setPage} />
          </>
        ) : null}
      </div>

      <InformSaModal movement={target} onClose={() => setTarget(null)} onDone={() => void load()} />
    </div>
  );
}
