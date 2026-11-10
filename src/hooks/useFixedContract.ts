import { useAuth } from '@/contexts/AuthContext';

interface ContractOption {
  id: string;
  code: string;
  name: string;
}

/**
 * Contrato fixo das telas de saída: o "contrato padrão" dos Parâmetros ou,
 * se não houver, o único contrato ativo. Com mais de um contrato e nenhum
 * padrão definido, devolve null (a tela mostra a lista para escolher).
 */
export function useFixedContract(contracts: ContractOption[] | undefined): ContractOption | null {
  const { settings } = useAuth();
  const list = contracts ?? [];
  const byDefault = settings?.default_contract_id ? list.find((c) => c.id === settings.default_contract_id) : undefined;
  if (byDefault) return byDefault;
  if (list.length === 1) return list[0];
  return null;
}
