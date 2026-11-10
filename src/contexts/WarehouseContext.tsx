import { createContext, useContext, useEffect, useMemo, useState, type ReactNode } from 'react';
import { useAuth } from './AuthContext';
import type { Warehouse } from '@/types/db';

interface WarehouseState {
  /** Estoque em que o usuário está operando (preferência local, não é dado do sistema). */
  current: Warehouse | null;
  /** id do estoque, ou ALL_WAREHOUSES para ver todos (consolidado) */
  setCurrentId: (id: string) => void;
  /** true quando o usuário escolheu "Todos os estoques" no topo */
  allSelected: boolean;
  options: Warehouse[];
}

const WarehouseContext = createContext<WarehouseState | null>(null);
const KEY = 'baixas-estoque:estoque-atual:';
export const ALL_WAREHOUSES = 'todos';

export function WarehouseProvider({ children }: { children: ReactNode }) {
  const { warehouses, userId, access } = useAuth();
  const [currentId, setCurrentIdState] = useState<string>('');

  useEffect(() => {
    if (!userId || warehouses.length === 0) {
      setCurrentIdState('');
      return;
    }
    let saved = '';
    try {
      saved = localStorage.getItem(KEY + userId) ?? '';
    } catch {
      /* ignore */
    }
    const valid = (id: string) => warehouses.some((w) => w.id === id);
    const def = access?.profile?.default_warehouse_id ?? '';
    if (saved === ALL_WAREHOUSES && warehouses.length > 1) {
      setCurrentIdState(ALL_WAREHOUSES);
      return;
    }
    const next = valid(saved) ? saved : valid(def) ? def : warehouses.length === 1 ? warehouses[0].id : '';
    setCurrentIdState(next);
  }, [userId, warehouses, access?.profile?.default_warehouse_id]);

  const value = useMemo<WarehouseState>(
    () => ({
      current: warehouses.find((w) => w.id === currentId) ?? null,
      allSelected: currentId === ALL_WAREHOUSES,
      options: warehouses,
      setCurrentId: (id) => {
        setCurrentIdState(id);
        try {
          if (userId) localStorage.setItem(KEY + userId, id);
        } catch {
          /* ignore */
        }
      },
    }),
    [currentId, warehouses, userId],
  );

  return <WarehouseContext.Provider value={value}>{children}</WarehouseContext.Provider>;
}

export function useWarehouse(): WarehouseState {
  const ctx = useContext(WarehouseContext);
  if (!ctx) throw new Error('useWarehouse deve ser usado dentro de WarehouseProvider');
  return ctx;
}
