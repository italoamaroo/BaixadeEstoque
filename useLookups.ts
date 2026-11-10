import { useCallback, useEffect, useState } from 'react';
import { listLookup } from '@/lib/api';
import type { LookupTable } from '@/lib/constants';
import type { Lookup } from '@/types/db';

type LookupMap = Partial<Record<LookupTable, Lookup[]>>;

const cache: LookupMap = {};

/** Carrega tabelas auxiliares (ativos), com cache em memória durante a sessão. */
export function useLookups(tables: LookupTable[], includeInactive = false) {
  const key = tables.join(',');
  const [data, setData] = useState<LookupMap>(() => (includeInactive ? {} : { ...cache }));
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(
    async (force = false) => {
      setLoading(true);
      setError(null);
      try {
        const entries = await Promise.all(
          key.split(',').filter(Boolean).map(async (t) => {
            const table = t as LookupTable;
            if (!force && !includeInactive && cache[table]) return [table, cache[table]] as const;
            const rows = await listLookup(table, includeInactive);
            if (!includeInactive) cache[table] = rows;
            return [table, rows] as const;
          }),
        );
        setData(Object.fromEntries(entries));
      } catch (e) {
        setError(e instanceof Error ? e.message : 'Falha ao carregar cadastros.');
      } finally {
        setLoading(false);
      }
    },
    [key, includeInactive],
  );

  useEffect(() => {
    void load();
  }, [load]);

  return { data, loading, error, reload: () => load(true) };
}

export function invalidateLookups(table?: LookupTable) {
  if (table) delete cache[table];
  else for (const k of Object.keys(cache)) delete cache[k as LookupTable];
}
