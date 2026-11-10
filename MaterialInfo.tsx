import type { Material } from '@/types/db';
import { ActiveBadge } from './ui/Badge';
import { KeyValue } from './ui/Card';

/** Dados do material identificado pela leitura do QR Code. */
export function MaterialInfo({ material }: { material: Material }) {
  return (
    <div className="space-y-3">
      <div className="flex items-start justify-between gap-3">
        <div>
          <p className="text-lg font-semibold leading-tight text-slate-900">{material.name}</p>
          {material.description && <p className="mt-0.5 text-sm text-slate-500">{material.description}</p>}
        </div>
        <ActiveBadge active={material.active} />
      </div>
      <dl className="grid grid-cols-2 gap-x-4 gap-y-3 sm:grid-cols-4">
        <KeyValue label="Código" value={material.code} />
        <KeyValue label="Referência" value={material.reference} />
        <KeyValue label="Unidade" value={material.unit} />
        <KeyValue label="Localização" value={material.location} />
        <KeyValue label="Conta" value={material.account_code ? `${material.account_code} – ${material.account_name ?? ''}` : null} />
        <KeyValue label="Categoria" value={material.category_name} />
        <KeyValue label="Estoque relacionado" value={material.warehouse_name ?? 'Todos'} />
        <KeyValue label="QR Code" value={<span className="font-mono text-xs">{material.qr_code}</span>} />
      </dl>
    </div>
  );
}
