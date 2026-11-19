import { useRef, useCallback, useEffect, useMemo, useState, type ReactNode } from 'react';
import { Link, useSearchParams } from 'react-router-dom';
import {
  Bar,
  Cell,
  BarChart,
  CartesianGrid,
  Legend,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from 'recharts';
import { AlertTriangle, CalendarDays, CheckCheck, ClipboardList, Hourglass, PackageMinus, RefreshCw } from 'lucide-react';
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

const WH_COLORS = ['#4e803d', '#80ad68', '#64748b', '#c58b36', '#33522c'];
const AGING_COLORS: Record<string, string> = {
  'Até 1 dia': '#fbbf24',
  '2 a 3 dias': '#f97316',
  '4 a 7 dias': '#ea580c',
  'Mais de 7 dias': '#dc2626',
};

function StatCard({ label, value, unit, icon, tone = 'slate', hint, to }: { label: string; value: string; unit: string; icon: ReactNode; tone?: string; hint?: ReactNode; to?: string }) {
  const tones: Record<string, string> = {
    slate: 'bg-slate-100 text-slate-700',
    blue: 'bg-brand-50 text-brand-700',
    teal: 'bg-teal-50 text-teal-700',
    orange: 'bg-orange-50 text-orange-700',
    green: 'bg-emerald-50 text-emerald-700',
    red: 'bg-red-50 text-red-700',
    amber: 'bg-amber-50 text-amber-700',
  };
  const body = (
    <div className="flex h-full items-start gap-3 rounded-xl border border-slate-200 bg-white p-4 shadow-card transition-colors hover:border-brand-200">
      <span className={clsx('flex h-10 w-10 shrink-0 items-center justify-center rounded-lg', tones[tone])}>{icon}</span>
      <div className="min-w-0">
        <p className="text-xs font-medium text-slate-500">{label}</p>
        <p className="mt-1 text-3xl font-bold tabular-nums text-slate-900">{value}</p>
        <p className="text-[11px] text-slate-400">{unit}</p>
        {hint && <div className="mt-1 text-[11px] text-slate-500">{hint}</div>}
      </div>
    </div>
  );
  if (to?.startsWith('#')) return <a href={to}>{body}</a>;
  return to ? <Link to={to}>{body}</Link> : body;
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
  const overdue = (data?.pending_aging ?? []).filter((v) => v.bucket === 'Mais de 7 dias').reduce((sum, v) => sum + Number(v.mes), 0);
  const applyPeriod = (from: string, to: string) => setParams(filtersToSearchParams({ ...filters, date_from: from, date_to: to }), { replace: true });
  const nextAction = (m: MovementRow) => m.status === 'aguardando_assinatura' ? 'Confirmar retirada'
    : m.status === 'aguardando_aprovacao' ? 'Aprovar ME'
    : m.status === 'aguardando_sa' ? 'Informar SA' : 'Confirmar baixa no ERP';
  const statuses = c ? [
    { label: 'Aguardando confirmação', value: confirmationCount ?? 0, color: '#c58b36' },
    { label: 'Aguardando aprovação', value: c.aguardando_aprovacao, color: '#b7791f' },
    { label: 'Pendente SA / ERP', value: c.aguardando_sa + c.sa_informada, color: '#80ad68' },
    { label: 'Concluídas', value: c.concluida, color: '#4e803d' },
    { label: 'Canceladas', value: c.cancelada, color: '#94a3b8' },
    { label: 'Em preparação / outras', value: Math.max(0, c.total_mes - (confirmationCount ?? 0) - c.aguardando_aprovacao - c.aguardando_sa - c.sa_informada - c.concluida - c.cancelada), color: '#64748b' },
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
          <div className="grid grid-cols-1 gap-3 sm:grid-cols-2 xl:grid-cols-5">
            <StatCard label="MEs no período" value={fmtInt(c.total_mes)} unit={`${fmtInt(c.today_mes)} hoje no recorte selecionado`} icon={<ClipboardList className="h-5 w-5" />} tone="blue" to={withFilters({})} />
            <StatCard label="Aguardando confirmação" value={confirmationCount === null ? '—' : fmtInt(confirmationCount)} unit="retiradas a confirmar" icon={<CalendarDays className="h-5 w-5" />} tone="orange" to={withFilters({ status: ['aguardando_assinatura'] })} />
            <StatCard label="Pendentes SA / ERP" value={fmtInt(c.aguardando_sa + c.sa_informada)} unit={`${fmtInt(c.aguardando_sa)} SA · ${fmtInt(c.sa_informada)} baixa ERP`} icon={<Hourglass className="h-5 w-5" />} tone="orange" to={withFilters({ status: ['aguardando_sa', 'sa_informada'] })} />
            <StatCard label="SA há mais de 7 dias" value={fmtInt(overdue)} unit="MEs aguardando SA no recorte" icon={<AlertTriangle className="h-5 w-5" />} tone={overdue ? 'red' : 'green'} to="#pendencias-prioritarias" />
            <StatCard label="Concluídas no período" value={fmtInt(c.concluida)} unit="MEs finalizadas" icon={<CheckCheck className="h-5 w-5" />} tone="green" to={withFilters({ status: ['concluida'] })} />
          </div>
          <p className="text-xs text-slate-500">Todos os indicadores respeitam os filtros acima. Clique nos cartões para consultar as MEs.</p>

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
          <div className="grid gap-4 lg:grid-cols-2">
            <ChartCard title="Situação das MEs" subtitle="Quantidade de MEs por etapa, no período e nos filtros selecionados.">
              {confirmationCount === null ? <p className="py-16 text-center text-sm text-slate-500">Distribuição indisponível enquanto a confirmação não for consultada.</p> : c.total_mes === 0 ? <p className="py-16 text-center text-sm text-slate-500">Sem movimentações no período.</p> : <ResponsiveContainer>
                <BarChart data={statuses} layout="vertical" margin={{ left: 0, right: 24 }}>
                  <CartesianGrid strokeDasharray="3 3" horizontal={false} stroke="#e2e8f0" />
                  <XAxis type="number" allowDecimals={false} tick={{ fontSize: 11 }} />
                  <YAxis type="category" dataKey="label" width={145} tick={{ fontSize: 11 }} />
                  <Tooltip formatter={(v) => [`${v} MEs`, 'Quantidade']} />
                  <Bar dataKey="value" isAnimationActive={false} radius={[0, 4, 4, 0]}>{statuses.map((v) => <Cell key={v.label} fill={v.color} />)}</Bar>
                </BarChart>
              </ResponsiveContainer>}
            </ChartCard>
            <ChartCard title="Materiais mais retirados" subtitle="Número de linhas de retirada por material; não soma unidades diferentes.">
              {data.top_materials_lines.length === 0 ? <p className="py-16 text-center text-sm text-slate-500">Sem materiais no período.</p> : <ResponsiveContainer>
                <BarChart data={data.top_materials_lines.slice(0, 5).map((r) => ({ ...r, nome: short(r.material) }))} layout="vertical" margin={{ left: 0, right: 20 }}>
                  <CartesianGrid strokeDasharray="3 3" horizontal={false} stroke="#e2e8f0" />
                  <XAxis type="number" allowDecimals={false} tick={{ fontSize: 11 }} /><YAxis type="category" dataKey="nome" width={140} tick={{ fontSize: 11 }} />
                  <Tooltip formatter={(v) => [`${v} linhas de retirada`, 'Frequência']} labelFormatter={(_, p) => p?.[0]?.payload?.material ?? ''} />
                  <Bar isAnimationActive={false} dataKey="lines" fill="#4e803d" radius={[0, 4, 4, 0]} />
                </BarChart>
              </ResponsiveContainer>}
            </ChartCard>
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
                    <button key={k} type="button" onClick={() => setPeriod(k)} className={clsx('rounded-md px-3 py-1.5', period === k ? 'bg-white text-brand-800 shadow' : 'text-slate-600')}>
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
                    <Legend />
                    {whNames.map((w, i) => (
                      <Bar isAnimationActive={false} key={w} dataKey={w} name={w} fill={WH_COLORS[i % WH_COLORS.length]} radius={[3, 3, 0, 0]} />
                    ))}
                  </BarChart>
                </ResponsiveContainer>
              )}
            </div>
          </Card>

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
                  <Bar isAnimationActive={false} dataKey="mes" name="MEs" fill="#4e803d" radius={[3, 3, 0, 0]} />
                  <Bar isAnimationActive={false} dataKey="item_lines" name="Linhas de itens" fill="#a8c795" radius={[3, 3, 0, 0]} />
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
                  <Bar isAnimationActive={false} dataKey="lines" fill="#4e803d" radius={[0, 3, 3, 0]} />
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
                  <Bar isAnimationActive={false} dataKey="qty" fill="#669e50" radius={[0, 3, 3, 0]} />
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
                      <Bar isAnimationActive={false} dataKey="mes" fill="#4e803d" radius={[0, 3, 3, 0]} />
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
