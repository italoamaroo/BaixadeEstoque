import { useEffect, useRef } from 'react';
import { useSearchParams } from 'react-router-dom';
import { useWarehouse } from '@/contexts/WarehouseContext';

/**
 * Faz o seletor de estoque do topo valer para a tela (Painel, Movimentações, Exportar):
 * - ao trocar o estoque no topo, o filtro de estoque da tela muda junto;
 * - "Todos os estoques" no topo mostra o consolidado;
 * - ao abrir a tela com um estoque já no endereço (ex.: link do Painel), ele é respeitado.
 */
export function useHeaderWarehouseFilter() {
  const { current } = useWarehouse();
  const [params, setParams] = useSearchParams();
  const first = useRef(true);
  const id = current?.id ?? '';

  useEffect(() => {
    const inUrl = params.get('warehouse_id') ?? '';
    if (first.current) {
      first.current = false;
      if (inUrl || !id) return;
    }
    if (inUrl === id) return;
    const next = new URLSearchParams(params);
    if (id) next.set('warehouse_id', id);
    else next.delete('warehouse_id');
    next.delete('pagina');
    setParams(next, { replace: true });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [id]);
}
