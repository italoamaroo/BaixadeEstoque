import { useRef, useCallback, useEffect, useMemo, useState } from 'react';
import { Link, useNavigate, useSearchParams } from 'react-router-dom';
import { ArrowDown, ArrowUp, ClipboardList, Eye, FileSpreadsheet, Hourglass, PackageMinus, Printer } from 'lucide-react';
import clsx from 'clsx';
import { useAuth } from '@/contexts/AuthContext';
import { FiltersPanel } from '@/components/FiltersPanel';
import { InformSaModal } from '@/components/InformSaModal';
import { LinkButton } from '@/components/ui/Button';
import { StatusBadge } from '@/components/ui/Badge';
import { Alert, EmptyState, PageHeader } from '@/components/ui/Card';
import { Pagination } from '@/components/ui/Pagination';
import { PageLoader } from '@/components/ui/Spinner';
import { searchMovements, type SearchResult } from '@/lib/api';
import { errorMessage } from '@/lib/errors';
import { filtersFromSearchParams, filtersToSearchParams, type MovementFilters } from '@/lib/filters';
import { fmtDate, fmtDateTime, fmtTime } from '@/lib/format';
import { useRealtimeMovements } from '@/hooks/useRealtimeMovements';
import { useHeaderWarehouseFilter } from '@/hooks/useHeaderWarehouseFilter';
import { EmergencyRepeatWithdrawals } from '@/components/EmergencyRepeatWithdrawals';
import type { MovementRow } from '@/types/db';

const SORTABLE: Record<string, string> = {
  me_number: 'ME',
  movement_at: 'Data',
  warehouse_name: 'Estoque',
  item_count: 'Itens',
  requester_name: 'Requisitante',
  sector_name: 'Setor',
  sa_number: 'SA',
  status: 'Status',
  updated_at: 'Última alteração',
};

export function MovementsPage({ emergencyOnly = false, rescueOnly = false }: { emergencyOnly?: boolean; rescueOnly?: boolean }) {
  const { can } = useAuth();
  const navigate = useNavigate();
  useHeaderWarehouseFilter();
  const [params, setParams] = useSearchParams();
  const filters = useMemo(() => {
    const parsed = filtersFromSearchParams(params);
    if (rescueOnly) return { ...parsed, rescue: 'sim' as const, emergency: 'nao' as const };
    return emergencyOnly ? { ...parsed, emergency: 'sim' as const, pending_sa: false, sa_number: '' } : parsed;
  }, [params, emergencyOnly, rescueOnly]);
  const page = Number(params.get('pagina') ?? 1) || 1;
  const pageSize = Number(params.get('por_pagina') ?? 25) || 25;
  const sort = params.get('ordem') ?? 'movement_at';
  const dir = (params.get('dir') as 'asc' | 'desc') ?? 'desc';

  const [data, setData] = useState<SearchResult | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [saTarget, setSaTarget] = useState<MovementRow | null>(null);

  // só a resposta da busca mais recente vale (troca rápida de estoque/filtros)
  const seq = useRef(0);
  const load = useCallback(async () => {
    const my = ++seq.current;
    setLoading(true);
    try {
      const r = await searchMovements(filters, page, pageSize, sort, dir);
      if (my !== seq.current) return;
      setData(r);
      setError(null);
    } catch (err) {
      if (my === seq.current) setError(errorMessage(err));
    } finally {
      if (my === seq.current) setLoading(false);
    }
  }, [filters, page, pageSize, sort, dir]);

  useEffect(() => {
    void load();
    return () => { seq.current++; };
  }, [load]);

  useRealtimeMovements(() => void load());

  const setQuery = (f: MovementFilters, extra: Record<string, string> = {}) => {
    const p = filtersToSearchParams(rescueOnly ? { ...f, rescue: 'sim', emergency: 'nao' } : emergencyOnly ? { ...f, emergency: 'sim', pending_sa: false, sa_number: '' } : f);
    const merged: Record<string, string> = { ordem: sort, dir, por_pagina: String(pageSize), ...extra };
    for (const [k, v] of Object.entries(merged)) p.set(k, v);
    setParams(p, { replace: true });
  };

  const toggleSort = (key: string) => {
    const nextDir = sort === key && dir === 'desc' ? 'asc' : 'desc';
    const p = new URLSearchParams(params);
    p.set('ordem', key);
    p.set('dir', nextDir);
    p.set('pagina', '1');
    setParams(p, { replace: true });
  };

  const goPage = (n: number) => {
    const p = new URLSearchParams(params);
    p.set('pagina', String(n));
    setParams(p, { replace: true });
  };

  const SortHeader = ({ k, className }: { k: string; className?: string }) => (
    <th scope="col" className={clsx('whitespace-nowrap px-3 py-2.5 text-left text-xs font-semibold uppercase tracking-wide text-slate-500', className)}>
      <button type="button" onClick={() => toggleSort(k)} className="inline-flex items-center gap-1 hover:text-slate-800">
        {SORTABLE[k]}
        {sort === k && (dir === 'asc' ? <ArrowUp className="h-3 w-3" /> : <ArrowDown className="h-3 w-3" />)}
      </button>
    </th>
  );

  const exportHref = `/exportar?${filtersToSearchParams(filters).toString()}`;

  return (
    <div>
      <PageHeader
        title={rescueOnly ? 'Socorros' : emergencyOnly ? 'Emergenciais' : 'Movimentações'}
        subtitle={rescueOnly ? 'Retiradas para socorro: confira o retorno para encaminhar somente o material utilizado à equipe de lançamento.' : emergencyOnly ? 'MEs emergenciais para controle: consulte os materiais retirados e o motivo de cada saída.' : 'Todas as MEs dos estoques que você pode consultar.'}
        actions={
          <>
            {can('exportExcel') && (
              <LinkButton to={exportHref} variant="secondary" icon={<FileSpreadsheet className="h-4 w-4" />}>
                Exportar Excel/PDF
              </LinkButton>
            )}
            {can('createMovement') && (
              <LinkButton to={rescueOnly ? '/nova-saida?tipo=socorro' : '/nova-saida'} icon={<PackageMinus className="h-4 w-4" />}>
                {rescueOnly ? 'Novo socorro' : 'Nova saída'}
              </LinkButton>
            )}
          </>
        }
      />

      <FiltersPanel hideMovementType={rescueOnly} emergencyOnly={emergencyOnly} value={filters} onApply={(f) => setQuery(f, { pagina: '1' })} />

      {rescueOnly && <Alert>As MEs aguardam o retorno. Quantidades devolvidas ficam no histórico; somente o utilizado segue para SA / ERP.</Alert>}
      {emergencyOnly && (
        <div className="mt-4 space-y-4">
          <Alert tone="warning">Saídas emergenciais não exigem SA nem baixa no ERP. Consulte os detalhes da ME para ver quantidades, assinatura e evidências autorizadas.</Alert>
          {!loading && !error && data && <p className="text-sm font-semibold text-slate-700">{data.total.toLocaleString('pt-BR')} {data.total === 1 ? 'ME emergencial encontrada' : 'MEs emergenciais encontradas'}</p>}
          <EmergencyRepeatWithdrawals filters={filters} />
        </div>
      )}

      <div className="mt-4 rounded-xl border border-slate-200 bg-white shadow-card">
        {error && (
          <div className="p-4">
            <Alert tone="error">{error}</Alert>
          </div>
        )}
        {loading && !data ? (
          <PageLoader />
        ) : data && data.rows.length === 0 ? (
          <EmptyState icon={<ClipboardList className="h-10 w-10" />} title={emergencyOnly ? 'Nenhuma ME emergencial encontrada' : 'Nenhuma ME encontrada'} description="Ajuste os filtros ou o período da consulta." />
        ) : data ? (
          <>
            {/* Desktop */}
            <div className={clsx('hidden overflow-x-auto lg:block', loading && 'opacity-60')}>
              <table className="min-w-full divide-y divide-slate-200 text-sm">
                <thead className="bg-slate-50">
                  <tr>
                    <SortHeader k="me_number" />
                    <SortHeader k="movement_at" />
                    <SortHeader k="warehouse_name" />
                    <SortHeader k="item_count" className="text-right" />
                    <th className="px-3 py-2.5 text-left text-xs font-semibold uppercase tracking-wide text-slate-500">Materiais</th>
                    <SortHeader k="requester_name" />
                    <SortHeader k="sector_name" />
                    <th className="px-3 py-2.5 text-left text-xs font-semibold uppercase tracking-wide text-slate-500">Frente / OS</th>
                    {emergencyOnly ? (
                      <>
                        <th scope="col" className="px-3 py-2.5 text-left text-xs font-semibold uppercase tracking-wide text-slate-500">Ativo fixo</th>
                        <th scope="col" className="px-3 py-2.5 text-left text-xs font-semibold uppercase tracking-wide text-slate-500">Motivo da emergência</th>
                      </>
                    ) : <SortHeader k="sa_number" />}
                    <SortHeader k="status" />
                    <th className="px-3 py-2.5 text-left text-xs font-semibold uppercase tracking-wide text-slate-500">Responsável</th>
                    <SortHeader k="updated_at" />
                    <th className="px-3 py-2.5 text-right text-xs font-semibold uppercase tracking-wide text-slate-500">Ações</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-slate-100">
                  {data.rows.map((m) => (
                    <tr key={m.id} className="hover:bg-slate-50">
                      <td className="whitespace-nowrap px-3 py-2.5 font-mono text-xs font-semibold">
                        <Link to={`/movimentacoes/${m.id}`} className="text-brand-700 hover:underline">
                          {m.me_number}
                        </Link>
                      </td>
                      <td className="whitespace-nowrap px-3 py-2.5">
                        {fmtDate(m.movement_at)} <span className="text-slate-500">{fmtTime(m.movement_at)}</span>
                      </td>
                      <td className="whitespace-nowrap px-3 py-2.5">{m.warehouse_name}</td>
                      <td className="px-3 py-2.5 text-right tabular-nums">{m.item_count}</td>
                      <td className="max-w-[220px] truncate px-3 py-2.5 text-slate-600" title={m.materials_summary ?? ''}>
                        {m.materials_summary}
                        {m.item_count > 3 ? '…' : ''}
                      </td>
                      <td className="max-w-[160px] truncate px-3 py-2.5" title={m.requester_name}>
                        {m.requester_name}
                      </td>
                      <td className="max-w-[140px] truncate px-3 py-2.5">{m.sector_name}</td>
                      <td className="max-w-[180px] truncate px-3 py-2.5 text-slate-600" title={[m.service_front_name, m.service_order].filter(Boolean).join(' · ')}>
                        {m.service_front_name ?? '—'}
                        {m.service_order ? <span className="block text-xs">OS {m.service_order}</span> : null}
                      </td>
                      {emergencyOnly ? (
                        <>
                          <td className="whitespace-nowrap px-3 py-2.5 font-mono text-xs">{m.fixed_asset ?? '—'}</td>
                          <td className="min-w-[180px] max-w-[280px] whitespace-normal break-words px-3 py-2.5 text-slate-600">{m.emergency_reason ?? '—'}</td>
                        </>
                      ) : <td className="whitespace-nowrap px-3 py-2.5 font-mono text-xs">{m.sa_number ?? '—'}</td>}
                      <td className="px-3 py-2.5">
                        <StatusBadge status={m.status} emergency={m.is_emergency} />{m.is_rescue && <span className="ml-2 text-xs font-semibold text-sky-700">{m.rescue_returned_at && Number(m.total_delivered) === 0 ? 'Socorro · sem consumo' : 'Socorro'}</span>}
                      </td>
                      <td className="max-w-[140px] truncate px-3 py-2.5 text-slate-600">{m.storekeeper_name}</td>
                      <td className="whitespace-nowrap px-3 py-2.5 text-xs text-slate-500">
                        {fmtDateTime(m.updated_at)}
                        {m.updated_by_name ? <span className="block">{m.updated_by_name}</span> : null}
                      </td>
                      <td className="whitespace-nowrap px-3 py-2.5 text-right">
                        <div className="inline-flex gap-1">
                          <button type="button" title="Visualizar" className="rounded-md p-1.5 text-slate-500 hover:bg-slate-100 hover:text-brand-700" onClick={() => navigate(`/movimentacoes/${m.id}`)}>
                            <Eye className="h-4 w-4" />
                          </button>
                          {!emergencyOnly && can('informSa') && (m.status === 'aguardando_sa' || (m.status === 'sa_informada' && m.sa_number)) && (
                            <button type="button" title={m.sa_number ? 'Corrigir SA' : 'Informar SA'} className="rounded-md p-1.5 text-orange-600 hover:bg-orange-50" onClick={() => setSaTarget(m)}>
                              <Hourglass className="h-4 w-4" />
                            </button>
                          )}
                          <button type="button" title="Imprimir ME" className="rounded-md p-1.5 text-slate-500 hover:bg-slate-100 hover:text-brand-700" onClick={() => navigate(`/movimentacoes/${m.id}?imprimir=1`)}>
                            <Printer className="h-4 w-4" />
                          </button>
                        </div>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>

            {/* Mobile/tablet */}
            <ul className={clsx('divide-y divide-slate-100 lg:hidden', loading && 'opacity-60')}>
              {data.rows.map((m) => (
                <li key={m.id}>
                  <Link to={`/movimentacoes/${m.id}`} className="block px-4 py-3 hover:bg-slate-50">
                    <div className="flex items-start justify-between gap-2">
                      <span className="font-mono text-sm font-semibold text-brand-700">{m.me_number}</span>
                      <StatusBadge status={m.status} emergency={m.is_emergency} />{m.is_rescue && <span className="ml-2 text-xs font-semibold text-sky-700">{m.rescue_returned_at && Number(m.total_delivered) === 0 ? 'Socorro · sem consumo' : 'Socorro'}</span>}
                    </div>
                    <p className="mt-1 text-sm text-slate-900">{m.requester_name}</p>
                    <p className="truncate text-xs text-slate-500">{m.materials_summary}</p>
                    {emergencyOnly && <>
                      <p className="mt-1 text-xs text-slate-600">Ativo fixo: {m.fixed_asset ?? 'Não informado'}</p>
                      <p className="mt-1 break-words text-sm text-slate-700"><span className="font-semibold">Motivo:</span> {m.emergency_reason ?? 'Não informado'}</p>
                    </>}
                    <p className="mt-1 text-xs text-slate-500">
                      {fmtDateTime(m.movement_at)} · {m.warehouse_name} · {m.item_count} {m.item_count === 1 ? 'item' : 'itens'}
                      {m.sa_number ? ` · SA ${m.sa_number}` : ''}
                    </p>
                  </Link>
                </li>
              ))}
            </ul>
            <Pagination
              page={page}
              pageSize={pageSize}
              total={data.total}
              onPage={goPage}
              onPageSize={(s) => {
                const p = new URLSearchParams(params);
                p.set('por_pagina', String(s));
                p.set('pagina', '1');
                setParams(p, { replace: true });
              }}
            />
          </>
        ) : null}
      </div>

      <InformSaModal movement={saTarget} onClose={() => setSaTarget(null)} onDone={() => void load()} />
    </div>
  );
}
