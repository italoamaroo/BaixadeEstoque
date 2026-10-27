import { ChevronLeft, ChevronRight } from 'lucide-react';
import { fmtInt } from '@/lib/format';

interface Props {
  page: number;
  pageSize: number;
  total: number;
  onPage: (p: number) => void;
  onPageSize?: (s: number) => void;
}

export function Pagination({ page, pageSize, total, onPage, onPageSize }: Props) {
  const pages = Math.max(1, Math.ceil(total / pageSize));
  const from = total === 0 ? 0 : (page - 1) * pageSize + 1;
  const to = Math.min(total, page * pageSize);
  return (
    <div className="flex flex-wrap items-center justify-between gap-3 border-t border-slate-100 px-4 py-3 text-sm text-slate-600">
      <span>
        {fmtInt(from)}–{fmtInt(to)} de {fmtInt(total)}
      </span>
      <div className="flex items-center gap-2">
        {onPageSize && (
          <select
            aria-label="Registros por página"
            className="h-8 rounded-md border-0 py-0 pl-2 pr-7 text-sm ring-1 ring-inset ring-slate-300"
            value={pageSize}
            onChange={(e) => onPageSize(Number(e.target.value))}
          >
            {[10, 25, 50, 100].map((n) => (
              <option key={n} value={n}>
                {n} por página
              </option>
            ))}
          </select>
        )}
        <button
          type="button"
          className="rounded-md p-1.5 ring-1 ring-inset ring-slate-300 hover:bg-slate-50 disabled:opacity-40"
          onClick={() => onPage(page - 1)}
          disabled={page <= 1}
          aria-label="Página anterior"
        >
          <ChevronLeft className="h-4 w-4" />
        </button>
        <span className="tabular-nums">
          {page} / {pages}
        </span>
        <button
          type="button"
          className="rounded-md p-1.5 ring-1 ring-inset ring-slate-300 hover:bg-slate-50 disabled:opacity-40"
          onClick={() => onPage(page + 1)}
          disabled={page >= pages}
          aria-label="Próxima página"
        >
          <ChevronRight className="h-4 w-4" />
        </button>
      </div>
    </div>
  );
}
