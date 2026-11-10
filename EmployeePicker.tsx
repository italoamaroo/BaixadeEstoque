import { useEffect, useState } from 'react';
import { Check, Search, UserRound } from 'lucide-react';
import clsx from 'clsx';
import { listEmployees } from '@/lib/api';
import { errorMessage } from '@/lib/errors';
import { useDebounce } from '@/hooks/useDebounce';
import type { Employee } from '@/types/db';
import { Spinner } from './ui/Spinner';
import { Alert } from './ui/Card';

interface Props {
  value: Employee | null;
  onChange: (e: Employee | null) => void;
  label: string;
}

/** Identificação do funcionário por nome ou matrícula. */
export function EmployeePicker({ value, onChange, label }: Props) {
  const [term, setTerm] = useState('');
  const debounced = useDebounce(term, 300);
  const [rows, setRows] = useState<Employee[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let alive = true;
    const t = debounced.trim();
    if (t.length < 2) {
      setRows([]);
      return;
    }
    setLoading(true);
    listEmployees({ search: t, limit: 20 })
      .then((r) => alive && (setRows(r), setError(null)))
      .catch((e) => alive && setError(errorMessage(e)))
      .finally(() => alive && setLoading(false));
    return () => {
      alive = false;
    };
  }, [debounced]);

  if (value) {
    return (
      <div className="flex items-center justify-between gap-3 rounded-xl border-2 border-brand-600 bg-brand-50 p-4">
        <div className="flex items-center gap-3">
          <div className="flex h-11 w-11 items-center justify-center rounded-full bg-brand-700 text-white">
            <UserRound className="h-6 w-6" />
          </div>
          <div>
            <p className="text-xs font-medium uppercase tracking-wide text-brand-700">{label}</p>
            <p className="font-semibold text-slate-900">{value.full_name}</p>
            <p className="text-sm text-slate-600">
              Matrícula {value.registration}
              {value.job_title ? ` · ${value.job_title}` : ''}
            </p>
          </div>
        </div>
        <button type="button" className="text-sm font-medium text-brand-700 hover:underline" onClick={() => onChange(null)}>
          Trocar
        </button>
      </div>
    );
  }

  return (
    <div className="space-y-2">
      <p className="text-sm font-medium text-slate-700">
        {label} <span className="text-red-600">*</span>
      </p>
      <div className="relative">
        <Search className="pointer-events-none absolute left-3 top-1/2 h-5 w-5 -translate-y-1/2 text-slate-400" />
        <input
          className="h-12 w-full rounded-lg border-0 pl-10 pr-10 text-base ring-1 ring-inset ring-slate-300 focus:ring-2 focus:ring-brand-600"
          placeholder="Nome ou matrícula do funcionário"
          value={term}
          onChange={(e) => setTerm(e.target.value)}
          aria-label={`Pesquisar ${label.toLowerCase()}`}
          autoComplete="off"
        />
        {loading && <Spinner className="absolute right-3 top-1/2 h-5 w-5 -translate-y-1/2 text-brand-600" />}
      </div>
      {error && <Alert tone="error">{error}</Alert>}
      {term.trim().length >= 2 && !loading && rows.length === 0 && !error && (
        <p className="py-3 text-sm text-slate-500">Nenhum funcionário ativo encontrado. Confira o nome/matrícula ou peça o cadastro ao administrador.</p>
      )}
      {rows.length > 0 && (
        <ul className="divide-y divide-slate-100 overflow-hidden rounded-lg border border-slate-200">
          {rows.map((e) => (
            <li key={e.id}>
              <button
                type="button"
                onClick={() => {
                  onChange(e);
                  setTerm('');
                }}
                className={clsx('flex w-full items-center justify-between px-4 py-3 text-left hover:bg-brand-50')}
              >
                <span>
                  <span className="block font-medium text-slate-900">{e.full_name}</span>
                  <span className="text-sm text-slate-500">
                    Matrícula {e.registration}
                    {e.job_title ? ` · ${e.job_title}` : ''}
                  </span>
                </span>
                <Check className="h-5 w-5 text-slate-300" />
              </button>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
