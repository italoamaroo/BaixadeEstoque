import { useRef, useCallback, useEffect, useMemo, useState, type ReactNode } from 'react';
import { Link, useSearchParams } from 'react-router-dom';
import {
  Bar,
  BarChart,
  CartesianGrid,
  Legend,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from 'recharts';
import { PackageMinus, RefreshCw } from 'lucide-react';
import clsx from 'clsx';
import { useAuth } from '@/contexts/AuthContext';
import { FiltersPanel } from '@/components/FiltersPanel';
import { Button, LinkButton } from '@/components/ui/Button';
import { Alert, Card, CardHeader, PageHeader } from '@/components/ui/Card';
import { PageLoader } from '@/components/ui/Spinner';
import { getDashboard, getRepeatAssetWithdrawals, searchMovements, type RepeatAssetWithdrawal } from '@/lib/api';
import { RepeatAssetCard } from '@/components/RepeatAssetCard';
import { errorMessage } from '@/lib/errors';
import { filtersFromSearchParams, filtersToSearchParams, type MovementFilters } from '@/lib/filters';
import { fmtInt, fmtQty, fmtDateTime, fmtRelative, daysSince, todayISO, firstDayOfMonthISO, isoDaysAgo } from '@/lib/format';
import { useRealtimeMovements } from '@/hooks/useRealtimeMovements';
import { useHeaderWarehouseFilter } from '@/hooks/useHeaderWarehouseFilter';
import { STATUS_LABELS } from '@/lib/constants';
import type { DashboardData, MovementRow, MovementStatus } from '@/types/db';

const WH_COLORS = ['#142b60', '#60a5ed', '#2563eb', '#7c3aed', '#64748b'];
const AGING_COLORS: Record<string, string> = {
  'Até 1 dia': '#fbbf24',
  '2 a 3 dias': '#f97316',
  '4 a 7 dias': '#ea580c',
  'Mais de 7 dias': '#dc2626',
};

function StatCard({ label, value, unit, to }: { label: string; value: string; unit: string; to: string }) {
  return <Link to={to} className="block h-full rounded-xl border border-slate-300 bg-white p-5 shadow-card transition-colors hover:border-brand-500 focus-visible:outline focus-visible:outline-2 focus-visible:outline-brand-600">
    <p className="text-base font-medium text-slate-900 sm:text-lg">{label}</p>
    <p className="mt-2 text-5xl font-bold tabular-nums tracking-tight text-slate-950">{value}</p>
    <p className="mt-2 text-xs text-slate-500">{unit}</p>
  </Link>;
}

function ChartCard({ title, subtitle, children, height = 260 }: { title: string; subtitle: string; children: ReactNode; height?: number }) {
  return (
    <Card>
      <CardHeader title={title} subtitle={subtitle} />
      <div style={{ height }}>{children}</div>
    </Card>
  );
}

/** Converte linhas {chave, warehouse, mes} em [{chave, Muribeca: n, Dois Irmãos: m}] */
function pivot<T extends Record<string, unknown>>(rows: T[], key: keyof T, label: (k: string) => string) {
  const map = new Map<string, Record<string, number | string>>();
  for (const r of rows) {
    const k = String(r[key]);
    const entry = map.get(k) ?? { periodo: label(k) };
    entry[String(r.warehouse)] = Number(r.mes);
    map.set(k, entry);
  }
  return [...map.entries()].sort(([a], [b]) => a.localeCompare(b)).map(([, v]) => v);
}

const short = (s: string, n = 22) => (s.length > n ? `${s.slice(0, n - 1)}…` : s);

export function DashboardPage() {
  const { warehouses, can, displayName } = useAuth();
  useHeaderWarehouseFilter();
  const [params, setParams] = useSearchParams();
  const filters = useMemo(() => filtersFromSearchParams(params), [params]);
  const [data, setData] = useState<DashboardData | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [updatedAt, setUpdatedAt] = useState<Date | null>(null);
  const [priority, setPriority] = useState<MovementRow[]>([]);
  const [confirmationCount, setConfirmationCount] = useState<number | null>(null);
  const [priorityError, setPriorityError] = useState<string | null>(null);
  const [period, setPeriod] = useState<'daily' | 'weekly' | 'monthly'>('daily');
  const [repeatDays, setRepeatDays] = useState(7);
  const [repeat, setRepeat] = useState<{ total: number; items: RepeatAssetWithdrawal[] } | null>(null);
  const [repeatLoading, setRepeatLoading] = useState(true);

  const showRepeat = can('viewRepeatAlerts');
  const repeatSeq = useRef(0);
  const loadRepeat = useCallback(async () => {
    if (!showRepeat) return;
    const my = ++repeatSeq.current;
    try {
      const r = await getRepeatAssetWithdrawals(filters, repeatDays);
      if (my === repeatSeq.current) setRepeat(r);
    } catch {
      if (my === repeatSeq.current) setRepeat(null);
    } finally {
      if (my === repeatSeq.current) setRepeatLoading(false);
    }
  }, [filters, repeatDays, showRepeat]);
  useEffect(() => {
    setRepeatLoading(true);
    void loadRepeat();
  }, [loadRepeat]);

  // só a resposta mais recente vale (troca rápida de estoque/filtros)
  const seq = useRef(0);
  const load = useCallback(async () => {
    const my = ++seq.current;
    try {
      const d = await getDashboard(filters);
      if (my !== seq.current) return;
      setData(d);
      setUpdatedAt(new Date());
      setError(null);
    } catch (err) {
      if (my === seq.current) setError(errorMessage(err));
    } finally {
      if (my === seq.current) setLoading(false);
    }
  }, [filters]);

  useEffect(() => {
    setLoading(true);
    setData(null);
    setUpdatedAt(null);
    void load();
  }, [load]);
  const prioritySeq = useRef(0);
  const loadPriority = useCallback(async () => {
    const my = ++prioritySeq.current;
    const pending: MovementStatus[] = ['aguardando_assinatura', 'aguardando_aprovacao', 'aguardando_sa', 'sa_informada'];
    const status = filters.status.length ? pending.filter((v) => filters.status.includes(v)) : pending;
    try {
      const [rows, confirmations] = await Promise.all([
        status.length ? searchMovements({ ...filters, status }, 1, 5, 'movement_at', 'asc') : Promise.resolve({ rows: [] }),
        !filters.status.length || filters.status.includes('aguardando_assinatura')
          ? searchMovements({ ...filters, status: ['aguardando_assinatura'] }, 1, 1, 'movement_at', 'asc')
          : Promise.resolve({ total: 0 }),
      ]);
      if (my !== prioritySeq.current) return;
      setPriority(rows.rows);
      setConfirmationCount(confirmations.total);
      setPriorityError(null);
    } catch (err) {
      if (my !== prioritySeq.current) return;
      setPriority([]);
      setConfirmationCount(null);
      setPriorityError(errorMessage(err));
    }
  }, [filters]);
  useEffect(() => {
    setPriority([]);
    setConfirmationCount(null);
    setPriorityError(null);
    void loadPriority();
    return () => { prioritySeq.current++; };
  }, [loadPriority]);
  useRealtimeMovements(() => {
    void load();
    void loadRepeat();
    void loadPriority();
  });

  const whNames = useMemo(() => (data?.by_warehouse ?? []).map((w) => w.warehouse), [data]);
  const series = useMemo(() => {
    if (!data) return [];
    if (period === 'daily') return pivot(data.daily, 'date', (k) => `${k.slice(8, 10)}/${k.slice(5, 7)}`);
    if (period === 'weekly') return pivot(data.weekly, 'week', (k) => `sem. ${k.slice(8, 10)}/${k.slice(5, 7)}`);
    return pivot(data.monthly, 'month', (k) => `${k.slice(5, 7)}/${k.slice(0, 4)}`);
  }, [data, period]);

  const aging = useMemo(() => {
    if (!data) return [];
    const map = new Map<string, Record<string, number | string>>();
    for (const r of data.pending_aging) {
      const e = map.get(r.warehouse) ?? { estoque: r.warehouse };
      e[r.bucket] = r.mes;
      map.set(r.warehouse, e);
    }
    return [...map.values()];
  }, [data]);

  const withFilters = (extra: Partial<MovementFilters>) => `/movimentacoes?${filtersToSearchParams({ ...filters, ...extra }).toString()}`;

  if (loading && !data) return <PageLoader label="Carregando painel…" />;

  const c = data?.cards;
  const applyPeriod = (from: string, to: string) => setParams(filtersToSearchParams({ ...filters, date_from: from, date_to: to }), { replace: true });
  const nextAction = (m: MovementRow) => m.status === 'aguardando_assinatura' ? 'Confirmar retirada'
    : m.status === 'aguardando_aprovacao' ? 'Aprovar ME'
    : m.status === 'aguardando_sa' ? 'Informar SA' : 'Confirmar baixa no ERP';
  const statuses = c ? [
    { label: 'Concluídas', value: c.concluida, color: '#142b60' },
    { label: 'Canceladas', value: c.cancelada, color: '#2354cb' },
    { label: 'Pendente SA / ERP', value: c.aguardando_sa + c.sa_informada, color: '#3983dc' },
    { label: 'Aguardando confirmação', value: confirmationCount ?? 0, color: '#579ce6' },
    { label: 'Aguardando aprovação', value: c.aguardando_aprovacao, color: '#7ab6ef' },
    { label: 'Em preparação / outras', value: Math.max(0, c.total_mes - (confirmationCount ?? 0) - c.aguardando_aprovacao - c.aguardando_sa - c.sa_informada - c.concluida - c.cancelada), color: '#a1cdf5' },
  ].filter((v) => v.value > 0) : [];
  return (
    <div className="space-y-5">
      <PageHeader
        title="Painel do almoxarifado"
        subtitle={`Olá, ${displayName.split(' ')[0]}. ${
          filters.warehouse_id
            ? `Indicadores do estoque ${warehouses.find((w) => w.id === filters.warehouse_id)?.name ?? ''}.`
            : 'Acompanhe as retiradas e priorize as pendências dos estoques autorizados.'
        }`}
        actions={
          can('createMovement') && (
            <LinkButton to="/nova-saida" size="lg" icon={<PackageMinus className="h-5 w-5" />}>
              Nova saída
            </LinkButton>
          )
        }
      />

      <div className="flex flex-wrap items-center justify-between gap-3 rounded-xl border border-slate-200 bg-white p-3">
        <div className="flex flex-wrap gap-2" aria-label="Atalhos de período">
          <Button size="sm" variant="secondary" onClick={() => applyPeriod(todayISO(), todayISO())}>Hoje</Button>
          <Button size="sm" variant="secondary" onClick={() => applyPeriod(isoDaysAgo(6), todayISO())}>Últimos 7 dias</Button>
          <Button size="sm" variant="secondary" onClick={() => applyPeriod(firstDayOfMonthISO(), todayISO())}>Este mês</Button>
          <Button size="sm" variant="ghost" onClick={() => applyPeriod('', '')}>Todo o período</Button>
        </div>
        <div className="flex flex-wrap gap-2">
          <select aria-label="Estoque do painel" className="h-9 max-w-full rounded-lg border border-slate-300 bg-white px-2 text-sm" value={filters.warehouse_id} onChange={(e) => setParams(filtersToSearchParams({ ...filters, warehouse_id: e.target.value }), { replace: true })}>
            <option value="">Todos os estoques autorizados</option>
            {warehouses.map((w) => <option key={w.id} value={w.id}>{w.name}</option>)}
          </select>
          <select aria-label="Status do painel" className="h-9 max-w-full rounded-lg border border-slate-300 bg-white px-2 text-sm" value={filters.status.length === 1 ? filters.status[0] : filters.status.length ? 'multiple' : ''} onChange={(e) => setParams(filtersToSearchParams({ ...filters, status: e.target.value ? [e.target.value as MovementStatus] : [] }), { replace: true })}>
            <option value="">Todos os status</option>
            {filters.status.length > 1 && <option value="multiple" disabled>Vários status selecionados</option>}
            {Object.entries(STATUS_LABELS).map(([value, label]) => <option key={value} value={value}>{label}</option>)}
          </select>
        </div>
        <div className="flex items-center gap-3 text-xs text-slate-500" role="status">
          <span>{loading ? 'Atualizando…' : updatedAt ? `Atualizado em ${fmtDateTime(updatedAt)}` : 'Dados indisponíveis'}</span>
          <Button size="sm" variant="ghost" aria-label="Atualizar painel" disabled={loading} icon={<RefreshCw className="h-4 w-4" />} onClick={() => { setLoading(true); void load(); void loadPriority(); void loadRepeat(); }}>Atualizar</Button>
        </div>
      </div>
      <FiltersPanel value={filters} onApply={(f) => setParams(filtersToSearchParams(f), { replace: true })} quickSearch={false} />

      {error && <Alert tone="error">{error}</Alert>}

      {c && data && (
        <>
          <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 xl:grid-cols-4">
            <StatCard label="Total de MEs" value={fmtInt(c.total_mes)} unit="No período e filtros selecionados" to={withFilters({})} />
            <StatCard label="Concluídas" value={fmtInt(c.concluida)} unit="MEs finalizadas no período" to={withFilters({ status: ['concluida'] })} />
            <StatCard label="Canceladas" value={fmtInt(c.cancelada)} unit="MEs canceladas no período" to={withFilters({ status: ['cancelada'] })} />
            <StatCard label="Pendentes SA / ERP" value={fmtInt(c.aguardando_sa + c.sa_informada)} unit={`${fmtInt(c.aguardando_sa)} aguardando SA · ${fmtInt(c.sa_informada)} baixa ERP`} to={withFilters({ status: ['aguardando_sa', 'sa_informada'] })} />
          </div>
          <div className="grid gap-4 lg:grid-cols-2">
            <Card className="border-slate-300">
              <CardHeader title="Situação das MEs" subtitle="Distribuição no período e nos filtros selecionados." />
              {confirmationCount === null ? <p className="py-10 text-sm text-slate-500">Distribuição indisponível enquanto a confirmação não for consultada.</p> : c.total_mes === 0 ? <p className="py-10 text-sm text-slate-500">Sem movimentações no período.</p> : <>
                <div className="mt-6 flex h-14 overflow-hidden rounded-lg" role="img" aria-label={statuses.map((v) => `${v.label}: ${fmtInt(v.value)}`).join('; ')}>
                  {statuses.map((v) => <div key={v.label} style={{ flex: v.value, backgroundColor: v.color }} className="flex min-w-0 items-center justify-center overflow-hidden text-sm font-semibold text-white" title={`${v.label}: ${fmtInt(v.value)}`}><span>{fmtInt(v.value)}</span></div>)}
                </div>
                <ul className="mt-5 flex flex-wrap gap-x-5 gap-y-2 text-sm">{statuses.map((v) => <li key={v.label} className="flex items-center gap-2"><span className="h-4 w-4 shrink-0 rounded" style={{ backgroundColor: v.color }} /><span>{v.label} <strong className="tabular-nums">{fmtInt(v.value)}</strong></span></li>)}</ul>
              </>}
            </Card>
            <Card className="border-slate-300">
              <CardHeader title="Materiais mais retirados" subtitle="Frequência em linhas de retirada; não soma unidades diferentes." />
              {data.top_materials_lines.length === 0 ? <p className="py-10 text-sm text-slate-500">Sem materiais no período.</p> : <ul className="space-y-3">{data.top_materials_lines.slice(0, 5).map((r, i) => <li key={`${r.material}-${i}`} className="grid grid-cols-[minmax(0,1fr)_minmax(50px,1fr)_2rem] items-center gap-3 text-sm">
                <span className="truncate" title={r.material}>{r.material}</span>
                <span className="h-2 overflow-hidden rounded-full bg-slate-100"><span className="block h-full rounded-full bg-blue-700" style={{ width: `${Math.max(0, Number(r.lines)) / Math.max(1, ...data.top_materials_lines.slice(0, 5).map((m) => Number(m.lines))) * 100}%` }} /></span>
                <strong className="text-right tabular-nums">{fmtInt(r.lines)}</strong>
              </li>)}</ul>}
            </Card>
          </div>

          <Card>
            <CardHeader
              title="Evolução das saídas"
              subtitle="Quantidade de MEs por período, comparando os estoques."
              actions={
                <div className="inline-flex rounded-lg bg-slate-100 p-0.5 text-xs font-semibold">
                  {(
                    [
                      ['daily', 'Diária'],
                      ['weekly', 'Semanal'],
                      ['monthly', 'Mensal'],
                    ] as const
                  ).map(([k, l]) => (
                    <button key={k} type="button" onClick={() => setPeriod(k)} className={clsx('rounded-md px-3 py-1.5', period === k ? 'bg-slate-800 text-white shadow' : 'text-slate-600')}>
                      {l}
                    </button>
                  ))}
                </div>
              }
            />
            <div style={{ height: 280 }}>
              {series.length === 0 ? (
                <p className="py-16 text-center text-sm text-slate-500">Sem movimentações no período.</p>
              ) : (
                <ResponsiveContainer>
                  <BarChart data={series} margin={{ left: -20, right: 8 }}>
                    <CartesianGrid strokeDasharray="3 3" vertical={false} stroke="#e2e8f0" />
                    <XAxis dataKey="periodo" tick={{ fontSize: 11 }} />
                    <YAxis allowDecimals={false} tick={{ fontSize: 11 }} />
                    <Tooltip cursor={{ fill: '#f1f5f9' }} formatter={(v) => [`${v} MEs`]} />
                    <Legend verticalAlign="top" />
                    {whNames.map((w, i) => (
                      <Bar isAnimationActive={false} key={w} dataKey={w} name={w} fill={WH_COLORS[i % WH_COLORS.length]} radius={[3, 3, 0, 0]} />
                    ))}
                  </BarChart>
                </ResponsiveContainer>
              )}
            </div>
          </Card>

          <section id="pendencias-prioritarias" className="scroll-mt-20">
            <Card>
              <CardHeader title="Pendências que precisam de atenção" subtitle="As cinco MEs pendentes mais antigas no recorte selecionado. Tempo contado desde a movimentação." actions={<LinkButton size="sm" variant="secondary" to={withFilters({ status: ['aguardando_assinatura', 'aguardando_aprovacao', 'aguardando_sa', 'sa_informada'] })}>Ver pendências</LinkButton>} />
              {priorityError ? <Alert tone="error">Não foi possível consultar as pendências: {priorityError}</Alert> : confirmationCount === null ? <p className="py-6 text-sm text-slate-500">Carregando pendências…</p> : priority.length === 0 ? <p className="py-6 text-sm text-emerald-700">Nenhuma pendência encontrada com estes filtros.</p> : (
                <div className="overflow-x-auto">
                  <table className="w-full min-w-[700px] text-left text-sm">
                    <thead className="bg-slate-50 text-xs uppercase text-slate-500"><tr>{['ME', 'Tempo em espera', 'Funcionário', 'Estoque', 'Próxima ação', 'Consulta'].map((h) => <th key={h} className="px-3 py-3">{h}</th>)}</tr></thead>
                    <tbody className="divide-y divide-slate-100">{priority.map((m) => <tr key={m.id}>
                      <td className="px-3 py-4 font-mono font-semibold text-brand-700"><Link to={`/movimentacoes/${m.id}`}>{m.me_number}</Link></td>
                      <td className="px-3 py-4"><span className={clsx('rounded-full px-2 py-1 text-xs font-semibold', daysSince(m.movement_at) >= 2 ? 'bg-red-50 text-red-700' : 'bg-amber-50 text-amber-800')}>{fmtRelative(m.movement_at)}</span></td>
                      <td className="px-3 py-4">{m.requester_name}</td><td className="px-3 py-4">{m.warehouse_name}</td>
                      <td className="px-3 py-4">{nextAction(m)}<span className="block text-xs text-slate-400">{STATUS_LABELS[m.status]}</span></td>
                      <td className="px-3 py-4"><LinkButton size="sm" variant="secondary" to={`/movimentacoes/${m.id}`}>Abrir ME</LinkButton></td>
                    </tr>)}</tbody>
                  </table>
                </div>
              )}
            </Card>
          </section>

          <details className="rounded-xl border border-slate-200 bg-white p-4">
            <summary className="cursor-pointer font-semibold text-brand-800">Análises detalhadas por estoque, material, setor e usuário</summary>
            <div className="mt-4">
              {showRepeat && <RepeatAssetCard data={repeat} loading={repeatLoading} days={repeatDays} onDaysChange={setRepeatDays} />}
            </div>
          <div className="grid gap-4 lg:grid-cols-2">
            <ChartCard title="Comparação entre estoques" subtitle="MEs, linhas de itens e pendências de SA por estoque (cada série em sua unidade).">
              <ResponsiveContainer>
                <BarChart data={data.by_warehouse} margin={{ left: -20, right: 8 }}>
                  <CartesianGrid strokeDasharray="3 3" vertical={false} stroke="#e2e8f0" />
                  <XAxis dataKey="warehouse" tick={{ fontSize: 12 }} />
                  <YAxis allowDecimals={false} tick={{ fontSize: 11 }} />
                  <Tooltip cursor={{ fill: '#f1f5f9' }} />
                  <Legend />
                  <Bar isAnimationActive={false} dataKey="mes" name="MEs" fill="#1d43c4" radius={[3, 3, 0, 0]} />
                  <Bar isAnimationActive={false} dataKey="item_lines" name="Linhas de itens" fill="#93b4fd" radius={[3, 3, 0, 0]} />
                  <Bar isAnimationActive={false} dataKey="pending_sa" name="Aguardando SA" fill="#f97316" radius={[3, 3, 0, 0]} />
                </BarChart>
              </ResponsiveContainer>
            </ChartCard>

            <ChartCard title="Pendências de SA por tempo" subtitle="Quantidade de MEs aguardando SA, por idade da pendência.">
              {aging.length === 0 ? (
                <p className="py-16 text-center text-sm text-emerald-700">Nenhuma pendência de SA.</p>
              ) : (
                <ResponsiveContainer>
                  <BarChart data={aging} margin={{ left: -20, right: 8 }}>
                    <CartesianGrid strokeDasharray="3 3" vertical={false} stroke="#e2e8f0" />
                    <XAxis dataKey="estoque" tick={{ fontSize: 12 }} />
                    <YAxis allowDecimals={false} tick={{ fontSize: 11 }} />
                    <Tooltip cursor={{ fill: '#f1f5f9' }} formatter={(v) => [`${v} MEs`]} />
                    <Legend />
                    {Object.keys(AGING_COLORS).map((b) => (
                      <Bar isAnimationActive={false} key={b} dataKey={b} stackId="a" fill={AGING_COLORS[b]} />
                    ))}
                  </BarChart>
                </ResponsiveContainer>
              )}
            </ChartCard>

            <ChartCard title="Materiais mais movimentados" subtitle="Quantidade de linhas de itens (vezes em que o material saiu)." height={320}>
              {data.top_materials_lines.length === 0 ? (
                <p className="py-16 text-center text-sm text-slate-500">Sem dados.</p>
              ) : (
              <ResponsiveContainer>
                <BarChart data={data.top_materials_lines.map((r) => ({ ...r, nome: short(r.material) }))} layout="vertical" margin={{ left: 10, right: 16 }}>
                  <CartesianGrid strokeDasharray="3 3" horizontal={false} stroke="#e2e8f0" />
                  <XAxis type="number" allowDecimals={false} tick={{ fontSize: 11 }} />
                  <YAxis type="category" dataKey="nome" width={150} tick={{ fontSize: 11 }} />
                  <Tooltip cursor={{ fill: '#f1f5f9' }} formatter={(v) => [`${v} linhas`, 'Saídas']} labelFormatter={(_, p) => p?.[0]?.payload?.material ?? ''} />
                  <Bar isAnimationActive={false} dataKey="lines" fill="#1d43c4" radius={[0, 3, 3, 0]} />
                </BarChart>
              </ResponsiveContainer>
              )}
            </ChartCard>

            <ChartCard title="Quantidade atendida por material" subtitle="Soma das quantidades atendidas — cada barra na unidade do próprio material." height={320}>
              {data.top_materials_qty.length === 0 ? (
                <p className="py-16 text-center text-sm text-slate-500">Sem dados.</p>
              ) : (
              <ResponsiveContainer>
                <BarChart data={data.top_materials_qty.map((r) => ({ ...r, qty: Number(r.qty), nome: `${short(r.material, 18)} (${r.unit})` }))} layout="vertical" margin={{ left: 10, right: 16 }}>
                  <CartesianGrid strokeDasharray="3 3" horizontal={false} stroke="#e2e8f0" />
                  <XAxis type="number" tick={{ fontSize: 11 }} />
                  <YAxis type="category" dataKey="nome" width={170} tick={{ fontSize: 11 }} />
                  <Tooltip cursor={{ fill: '#f1f5f9' }} formatter={(v, _n, p) => [`${fmtQty(Number(v))} ${p?.payload?.unit ?? ''}`, 'Atendido']} labelFormatter={(_, p) => p?.[0]?.payload?.material ?? ''} />
                  <Bar isAnimationActive={false} dataKey="qty" fill="#0d9488" radius={[0, 3, 3, 0]} />
                </BarChart>
              </ResponsiveContainer>
              )}
            </ChartCard>

            {(
              [
                ['Movimentações por setor', 'Quantidade de MEs (sem canceladas).', data.by_sector],
                ['Por frente de serviço / equipamento', 'Quantidade de MEs (sem canceladas).', data.by_service_front],
                ['Movimentações por usuário', 'MEs registradas por almoxarife (sem canceladas).', data.by_user],
              ] as const
            ).map(([title, subtitle, rows]) => (
              <ChartCard key={title} title={title} subtitle={subtitle} height={Math.max(200, rows.length * 30 + 40)}>
                {rows.length === 0 ? (
                  <p className="py-16 text-center text-sm text-slate-500">Sem dados.</p>
                ) : (
                  <ResponsiveContainer>
                    <BarChart data={rows.map((r) => ({ ...r, nome: short(r.label, 26) }))} layout="vertical" margin={{ left: 10, right: 16 }}>
                      <CartesianGrid strokeDasharray="3 3" horizontal={false} stroke="#e2e8f0" />
                      <XAxis type="number" allowDecimals={false} tick={{ fontSize: 11 }} />
                      <YAxis type="category" dataKey="nome" width={170} tick={{ fontSize: 11 }} />
                      <Tooltip cursor={{ fill: '#f1f5f9' }} formatter={(v) => [`${v} MEs`]} labelFormatter={(_, p) => p?.[0]?.payload?.label ?? ''} />
                      <Bar isAnimationActive={false} dataKey="mes" fill="#1d43c4" radius={[0, 3, 3, 0]} />
                    </BarChart>
                  </ResponsiveContainer>
                )}
              </ChartCard>
            ))}
          </div>
          </details>
          {warehouses.length === 0 && <Alert tone="warning">Você não tem estoques vinculados; os indicadores ficarão vazios.</Alert>}
        </>
      )}
    </div>
  );
}
