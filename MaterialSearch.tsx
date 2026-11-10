import { useEffect, useState } from 'react';
import { Search } from 'lucide-react';
import { searchMaterials } from '@/lib/api';
import { errorMessage } from '@/lib/errors';
import { useDebounce } from '@/hooks/useDebounce';
import type { Material } from '@/types/db';
import { ActiveBadge } from './ui/Badge';
import { Spinner } from './ui/Spinner';
import { Alert } from './ui/Card';

interface Props {
  onSelect: (m: Material) => void;
  autoFocus?: boolean;
}

/** Pesquisa manual por código, referência, nome ou descrição. */
export function MaterialSearch({ onSelect, autoFocus }: Props) {
  const [term, setTerm] = useState('');
  const debounced = useDebounce(term, 300);
  const [rows, setRows] = useState<Material[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let alive = true;
    const t = debounced.trim();
    if (t.length < 2) {
      setRows([]);
      setError(null);
      return;
    }
    setLoading(true);
    searchMaterials(t, false, 40)
      .then((r) => alive && (setRows(r), setError(null)))
      .catch((e) => alive && setError(errorMessage(e)))
      .finally(() => alive && setLoading(false));
    return () => {
      alive = false;
    };
  }, [debounced]);

  return (
    <div className="space-y-3">
      <div className="relative">
        <Search className="pointer-events-none absolute left-3 top-1/2 h-5 w-5 -translate-y-1/2 text-slate-400" />
        <input
          autoFocus={autoFocus}
          data-autofocus
          className="h-12 w-full rounded-lg border-0 pl-10 pr-10 text-base ring-1 ring-inset ring-slate-300 focus:ring-2 focus:ring-brand-600"
          placeholder="Código, referência, nome ou descrição"
          value={term}
          onChange={(e) => setTerm(e.target.value)}
          aria-label="Pesquisar material"
          autoComplete="off"
        />
        {loading && <Spinner className="absolute right-3 top-1/2 h-5 w-5 -translate-y-1/2 text-brand-600" />}
      </div>
      {error && <Alert tone="error">{error}</Alert>}
      {term.trim().length >= 2 && !loading && rows.length === 0 && !error && (
        <p className="py-6 text-center text-sm text-slate-500">Nenhum material encontrado para “{term.trim()}”.</p>
      )}
      <ul className="divide-y divide-slate-100 overflow-hidden rounded-lg border border-slate-200">
        {rows.map((m) => (
          <li key={m.id}>
            <button
              type="button"
              disabled={!m.active}
              onClick={() => onSelect(m)}
              className="flex w-full items-start justify-between gap-3 px-4 py-3 text-left hover:bg-brand-50 disabled:cursor-not-allowed disabled:opacity-60 disabled:hover:bg-transparent"
            >
              <div className="min-w-0">
                <p className="font-medium text-slate-900">{m.name}</p>
                <p className="text-xs text-slate-500">
                  {m.code}
                  {m.reference ? ` · Ref. ${m.reference}` : ''} · {m.unit}
                  {m.location ? ` · Loc. ${m.location}` : ''}
                </p>
              </div>
              {!m.active && <ActiveBadge active={false} />}
            </button>
          </li>
        ))}
      </ul>
    </div>
  );
}
