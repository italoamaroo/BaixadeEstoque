import { useCallback, useEffect, useMemo, useState, type ReactNode } from 'react';
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
import { Ban, CalendarDays, CheckCheck, ClipboardList, Hourglass, Layers, PackageMinus, Scale, ShieldQuestion, Warehouse } from 'lucide-react';
import clsx from 'clsx';
import { useAuth } from '@/contexts/AuthContext';
import { FiltersPanel } from '@/components/FiltersPanel';
import { LinkButton } from '@/components/ui/Button';
import { Alert, Card, CardHeader, PageHeader } from '@/components/ui/Card';
import { PageLoader } from '@/components/ui/Spinner';
import { getDashboard } from '@/lib/api';
import { errorMessage } from '@/lib/errors';
import { filtersFromSearchParams, filtersToSearchParams, type MovementFilters } from '@/lib/filters';
import { fmtInt, fmtQty } from '@/lib/format';
import { useRealtimeMovements } from '@/hooks/useRealtimeMovements';
import type { DashboardData } from '@/types/db';

const WH_COLORS = ['#1d43c4', '#0d9488', '#f97316', '#7c3aed', '#64748b'];
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
        <p className="text-2xl font-bold tabular-nums text-slate-900">{value}</p>
        <p className="text-[11px] text-slate-400">{unit}</p>
        {hint && <div className="mt-1 text-[11px] text-slate-500">{hint}</div>}
      </div>
    </div>
  );
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
  const [params, setParams] = useSearchParams();
  const filters = useMemo(() => filtersFromSearchParams(params), [params]);
  const [data, setData] = useState<DashboardData | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [period, setPeriod] = useState<'daily' | 'weekly' | 'monthly'>('daily');

  const load = useCallback(async () => {
    try {
      setData(await getDashboard(filters));
      setError(null);
    } catch (err) {
      setError(errorMessage(err));
    } finally {
      setLoading(false);
    }
  }, [filters]);

  useEffect(() => {
    setLoading(true);
    void load();
  }, [load]);
  useRealtimeMovements(() => void load());

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
  return (
    <div className="space-y-5">
      <PageHeader
        title="Painel"
        subtitle={`Olá, ${displayName.split(' ')[0]}. Indicadores dos estoques autorizados${filters.warehouse_id ? '' : ' (consolidado)'}.`}
        actions={
          can('createMovement') && (
            <LinkButton to="/nova-saida" size="lg" icon={<PackageMinus className="h-5 w-5" />}>
              Nova saída
            </LinkButton>
          )
        }
      />

      <FiltersPanel value={filters} onApply={(f) => setParams(filtersToSearchParams(f), { replace: true })} quickSearch={false} />

      {error && <Alert tone="error">{error}</Alert>}

      {c && data && (
        <>
          <div className="grid grid-cols-2 gap-3 md:grid-cols-3 xl:grid-cols-5">
            <StatCard label="Total de MEs" value={fmtInt(c.total_mes)} unit="MEs (inclui canceladas)" icon={<ClipboardList className="h-5 w-5" />} tone="blue" to={withFilters({})} />
            <StatCard label="MEs hoje" value={fmtInt(c.today_mes)} unit="MEs" icon={<CalendarDays className="h-5 w-5" />} tone="blue" />
            {data.by_warehouse.map((w, i) => (
              <StatCard
                key={w.warehouse_id}
                label={`MEs ${w.warehouse}`}
                value={fmtInt(w.mes)}
                unit="MEs"
                icon={<Warehouse className="h-5 w-5" />}
                tone={i === 0 ? 'blue' : 'teal'}
                hint={`${fmtInt(w.pending_sa)} aguardando SA`}
                to={withFilters({ warehouse_id: w.warehouse_id })}
              />
            ))}
            <StatCard label="Itens movimentados" value={fmtInt(c.item_lines)} unit="linhas de itens (sem canceladas)" icon={<Layers className="h-5 w-5" />} />
            <StatCard
              label="Quantidades atendidas"
              value={fmtQty(c.qty_delivered)}
              unit="soma de unidades diferentes"
              icon={<Scale className="h-5 w-5" />}
              hint={data.qty_by_unit.slice(0, 4).map((u) => `${fmtQty(u.qty)} ${u.unit}`).join(' · ')}
            />
            <StatCard label="Aguardando SA" value={fmtInt(c.aguardando_sa)} unit="MEs" icon={<Hourglass className="h-5 w-5" />} tone="orange" to={withFilters({ status: ['aguardando_sa'] })} />
            <StatCard label="SA informada" value={fmtInt(c.sa_informada)} unit="MEs" icon={<Hourglass className="h-5 w-5" />} tone="blue" to={withFilters({ status: ['sa_informada'] })} />
            <StatCard label="Concluídas" value={fmtInt(c.concluida)} unit="MEs" icon={<CheckCheck className="h-5 w-5" />} tone="green" to={withFilters({ status: ['concluida'] })} />
            <StatCard label="Canceladas" value={fmtInt(c.cancelada)} unit="MEs" icon={<Ban className="h-5 w-5" />} tone="red" to={withFilters({ status: ['cancelada'] })} />
            {c.aguardando_aprovacao > 0 && (
              <StatCard label="Aguardando aprovação" value={fmtInt(c.aguardando_aprovacao)} unit="MEs" icon={<ShieldQuestion className="h-5 w-5" />} tone="amber" to={withFilters({ status: ['aguardando_aprovacao'] })} />
            )}
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
                      <Bar isAnimationActive={false} dataKey="mes" fill="#3b6ef5" radius={[0, 3, 3, 0]} />
                    </BarChart>
                  </ResponsiveContainer>
                )}
              </ChartCard>
            ))}
          </div>
          {warehouses.length === 0 && <Alert tone="warning">Você não tem estoques vinculados; os indicadores ficarão vazios.</Alert>}
        </>
      )}
    </div>
  );
}
