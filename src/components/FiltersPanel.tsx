import { useEffect, useState } from 'react';
import { Filter, RotateCcw, Search, SlidersHorizontal } from 'lucide-react';
import clsx from 'clsx';
import { Button } from './ui/Button';
import { Input, Select } from './ui/Field';
import { Badge } from './ui/Badge';
import { useAuth } from '@/contexts/AuthContext';
import { useLookups } from '@/hooks/useLookups';
import { listProfiles, type ProfileName } from '@/lib/api';
import { STATUS_LABELS, STATUS_ORDER } from '@/lib/constants';
import { EMPTY_FILTERS, countActiveFilters, validateFilters, type MovementFilters } from '@/lib/filters';
import { firstDayOfMonthISO, isoDaysAgo, todayISO } from '@/lib/format';
import type { MovementStatus } from '@/types/db';

interface Props {
  value: MovementFilters;
  onApply: (f: MovementFilters) => void;
  /** mostra a pesquisa rápida acima do painel */
  quickSearch?: boolean;
  defaultOpen?: boolean;
}

let profileCache: ProfileName[] | null = null;

export function FiltersPanel({ value, onApply, quickSearch = true, defaultOpen = false }: Props) {
  const { warehouses } = useAuth();
  const [draft, setDraft] = useState<MovementFilters>(value);
  const [open, setOpen] = useState(defaultOpen);
  const [error, setError] = useState<string | null>(null);
  const [profiles, setProfiles] = useState<ProfileName[]>(profileCache ?? []);
  const { data: lk } = useLookups(['sectors', 'service_fronts', 'application_locations']);

  useEffect(() => setDraft(value), [value]);

  useEffect(() => {
    if (!open || profileCache) return;
    listProfiles()
      .then((p) => {
        profileCache = p;
        setProfiles(p);
      })
      .catch(() => undefined);
  }, [open]);

  const set = <K extends keyof MovementFilters>(k: K, v: MovementFilters[K]) => setDraft((d) => ({ ...d, [k]: v }));
  const active = countActiveFilters(value);

  const apply = (f = draft) => {
    const err = validateFilters(f);
    setError(err);
    if (err) return;
    onApply(f);
  };

  const toggleStatus = (s: MovementStatus) =>
    set('status', draft.status.includes(s) ? draft.status.filter((x) => x !== s) : [...draft.status, s]);

  const preset = (from: string, to: string) => setDraft((d) => ({ ...d, date_from: from, date_to: to }));

  return (
    <div className="rounded-xl border border-slate-200 bg-white shadow-card">
      <div className="flex flex-wrap items-center gap-2 p-3">
        {quickSearch && (
          <form
            className="relative min-w-[200px] flex-1"
            onSubmit={(e) => {
              e.preventDefault();
              apply();
            }}
          >
            <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-slate-400" />
            <input
              className="h-10 w-full rounded-lg border-0 pl-9 pr-3 text-sm ring-1 ring-inset ring-slate-300 focus:ring-2 focus:ring-brand-600"
              placeholder="Pesquisa rápida: ME, SA, requisitante, material…"
              value={draft.q}
              onChange={(e) => set('q', e.target.value)}
              aria-label="Pesquisa rápida"
            />
          </form>
        )}
        <Button
          variant={open ? 'primary' : 'secondary'}
          icon={<SlidersHorizontal className="h-4 w-4" />}
          onClick={() => setOpen((o) => !o)}
          aria-expanded={open}
        >
          Filtros
          {active > 0 && <Badge className="ml-1 bg-orange-100 text-orange-800 ring-orange-300">{active}</Badge>}
        </Button>
        {quickSearch && (
          <Button variant="secondary" onClick={() => apply()} icon={<Search className="h-4 w-4" />}>
            Buscar
          </Button>
        )}
        {active > 0 && (
          <Button
            variant="ghost"
            icon={<RotateCcw className="h-4 w-4" />}
            onClick={() => {
              const cleared = { ...EMPTY_FILTERS, status: [] };
              setDraft(cleared);
              apply(cleared);
            }}
          >
            Limpar filtros
          </Button>
        )}
      </div>

      <div className={clsx('border-t border-slate-100 p-4', !open && 'hidden')}>
        <div className="mb-4 flex flex-wrap gap-2 text-xs">
          <span className="self-center font-medium text-slate-500">Período:</span>
          <button type="button" className="rounded-full bg-slate-100 px-3 py-1 hover:bg-slate-200" onClick={() => preset(todayISO(), todayISO())}>
            Hoje
          </button>
          <button type="button" className="rounded-full bg-slate-100 px-3 py-1 hover:bg-slate-200" onClick={() => preset(isoDaysAgo(6), todayISO())}>
            7 dias
          </button>
          <button type="button" className="rounded-full bg-slate-100 px-3 py-1 hover:bg-slate-200" onClick={() => preset(isoDaysAgo(29), todayISO())}>
            30 dias
          </button>
          <button type="button" className="rounded-full bg-slate-100 px-3 py-1 hover:bg-slate-200" onClick={() => preset(firstDayOfMonthISO(), todayISO())}>
            Mês atual
          </button>
        </div>

        <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-4">
          <Input label="Período inicial" type="date" value={draft.date_from} onChange={(e) => set('date_from', e.target.value)} />
          <Input label="Período final" type="date" value={draft.date_to} onChange={(e) => set('date_to', e.target.value)} />
          <Select label="Estoque" value={draft.warehouse_id} onChange={(e) => set('warehouse_id', e.target.value)}>
            <option value="">Todos (consolidado)</option>
            {warehouses.map((w) => (
              <option key={w.id} value={w.id}>
                {w.name}
              </option>
            ))}
          </Select>
          <Input label="Número da ME" value={draft.me_number} onChange={(e) => set('me_number', e.target.value)} placeholder="ME-MUR-2026-…" />
          <Input label="Número da SA" value={draft.sa_number} onChange={(e) => set('sa_number', e.target.value)} />
          <Input label="Material (nome/código/ref.)" value={draft.material} onChange={(e) => set('material', e.target.value)} />
          <Input label="Código do material" value={draft.material_code} onChange={(e) => set('material_code', e.target.value)} />
          <Input label="Referência" value={draft.reference} onChange={(e) => set('reference', e.target.value)} />
          <Input label="Unidade" value={draft.unit} onChange={(e) => set('unit', e.target.value.toUpperCase())} placeholder="UN, L, KG…" />
          <Select label="Setor" value={draft.sector_id} onChange={(e) => set('sector_id', e.target.value)}>
            <option value="">Todos</option>
            {(lk.sectors ?? []).map((s) => (
              <option key={s.id} value={s.id}>
                {s.name}
              </option>
            ))}
          </Select>
          <Select label="Frente de serviço / equipamento" value={draft.service_front_id} onChange={(e) => set('service_front_id', e.target.value)}>
            <option value="">Todas</option>
            {(lk.service_fronts ?? []).map((s) => (
              <option key={s.id} value={s.id}>
                {s.name}
              </option>
            ))}
          </Select>
          <Input label="Ordem de serviço" value={draft.service_order} onChange={(e) => set('service_order', e.target.value)} />
          <Input label="Ativo fixo" value={draft.fixed_asset} onChange={(e) => set('fixed_asset', e.target.value)} />
          <Select label="Local de aplicação" value={draft.application_location_id} onChange={(e) => set('application_location_id', e.target.value)}>
            <option value="">Todos</option>
            {(lk.application_locations ?? []).map((s) => (
              <option key={s.id} value={s.id}>
                {s.name}
              </option>
            ))}
          </Select>
          <Input label="Requisitante (nome ou matrícula)" value={draft.requester} onChange={(e) => set('requester', e.target.value)} />
          <Select label="Almoxarife (responsável pela baixa)" value={draft.storekeeper_id} onChange={(e) => set('storekeeper_id', e.target.value)}>
            <option value="">Todos</option>
            {profiles.map((p) => (
              <option key={p.id} value={p.id}>
                {p.full_name}
              </option>
            ))}
          </Select>
          <Select label="Usuário responsável (qualquer ação)" value={draft.responsible_user_id} onChange={(e) => set('responsible_user_id', e.target.value)}>
            <option value="">Todos</option>
            {profiles.map((p) => (
              <option key={p.id} value={p.id}>
                {p.full_name}
              </option>
            ))}
          </Select>
        </div>

        <fieldset className="mt-4">
          <legend className="text-sm font-medium text-slate-700">Status</legend>
          <div className="mt-2 flex flex-wrap gap-2">
            {STATUS_ORDER.map((s) => (
              <button
                key={s}
                type="button"
                onClick={() => toggleStatus(s)}
                aria-pressed={draft.status.includes(s)}
                className={clsx(
                  'rounded-full px-3 py-1.5 text-sm ring-1 ring-inset',
                  draft.status.includes(s) ? 'bg-brand-700 text-white ring-brand-700' : 'bg-white text-slate-700 ring-slate-300 hover:bg-slate-50',
                )}
              >
                {STATUS_LABELS[s]}
              </button>
            ))}
            <label className="ml-2 inline-flex items-center gap-2 text-sm text-slate-700">
              <input
                type="checkbox"
                className="h-4 w-4 rounded border-slate-300 text-brand-700"
                checked={draft.pending_sa}
                onChange={(e) => set('pending_sa', e.target.checked)}
              />
              Somente pendência de SA
            </label>
          </div>
        </fieldset>

        {error && <p className="mt-3 text-sm text-red-600">{error}</p>}

        <div className="mt-5 flex flex-wrap justify-end gap-2">
          <Button
            variant="secondary"
            icon={<RotateCcw className="h-4 w-4" />}
            onClick={() => {
              const cleared = { ...EMPTY_FILTERS, status: [] };
              setDraft(cleared);
              apply(cleared);
            }}
          >
            Limpar filtros
          </Button>
          <Button
            icon={<Filter className="h-4 w-4" />}
            onClick={() => {
              apply();
              setOpen(false);
            }}
          >
            Aplicar filtros
          </Button>
        </div>
      </div>
    </div>
  );
}
