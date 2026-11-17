import { useCallback, useEffect, useRef, useState } from 'react';
import { useAuth } from '@/contexts/AuthContext';
import { useRealtimeMovements } from '@/hooks/useRealtimeMovements';
import { getRepeatAssetWithdrawals, type RepeatAssetWithdrawal } from '@/lib/api';
import { errorMessage } from '@/lib/errors';
import type { MovementFilters } from '@/lib/filters';
import { Alert } from './ui/Card';
import { RepeatAssetCard } from './RepeatAssetCard';

export function EmergencyRepeatWithdrawals({ filters }: { filters: MovementFilters }) {
  const { can } = useAuth();
  const allowed = can('viewRepeatAlerts');
  const [days, setDays] = useState(7);
  const [data, setData] = useState<{ total: number; items: RepeatAssetWithdrawal[] } | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const sequence = useRef(0);
  const load = useCallback(async () => {
    if (!allowed) return;
    const request = ++sequence.current;
    setLoading(true);
    setData(null);
    setError(null);
    try {
      const result = await getRepeatAssetWithdrawals(filters, days);
      if (request === sequence.current) setData(result);
    } catch (err) {
      if (request === sequence.current) setError(errorMessage(err));
    } finally {
      if (request === sequence.current) setLoading(false);
    }
  }, [allowed, filters, days]);
  useEffect(() => {
    void load();
    return () => { sequence.current++; };
  }, [load]);
  useRealtimeMovements(() => void load());

  if (!allowed) return null;
  return (
    <div className="space-y-2">
      <p className="text-xs text-slate-500">Compara as MEs emergenciais filtradas com retiradas anteriores do mesmo ativo e material, incluindo MEs normais.</p>
      {error ? <Alert tone="error">Não foi possível consultar as retiradas repetidas: {error}</Alert> :
        <RepeatAssetCard data={data} loading={loading} days={days} onDaysChange={setDays} />}
    </div>
  );
}
