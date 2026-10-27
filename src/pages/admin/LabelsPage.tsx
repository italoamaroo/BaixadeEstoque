import { useEffect, useState } from 'react';
import { useSearchParams } from 'react-router-dom';
import { Printer, Trash2 } from 'lucide-react';
import clsx from 'clsx';
import { Button } from '@/components/ui/Button';
import { Card, CardHeader, EmptyState, PageHeader } from '@/components/ui/Card';
import { Checkbox, Select } from '@/components/ui/Field';
import { MaterialSearch } from '@/components/MaterialSearch';
import { QRCodeImage } from '@/components/QRCodeImage';
import { getMaterialsByIds, markLabelsPrinted } from '@/lib/api';
import type { Material } from '@/types/db';

const SIZES = {
  pequena: { label: 'Pequena (50 × 30 mm)', w: '50mm', h: '30mm', qr: 80, font: 'text-[8px]' },
  media: { label: 'Média (70 × 40 mm)', w: '70mm', h: '40mm', qr: 110, font: 'text-[10px]' },
  grande: { label: 'Grande (100 × 60 mm)', w: '100mm', h: '60mm', qr: 170, font: 'text-[12px]' },
} as const;

type SizeKey = keyof typeof SIZES;

export function LabelsPage() {
  const [params] = useSearchParams();
  const [items, setItems] = useState<{ material: Material; copies: number }[]>([]);
  const [size, setSize] = useState<SizeKey>('media');
  const [showLocation, setShowLocation] = useState(true);

  useEffect(() => {
    const ids = (params.get('ids') ?? '').split(',').filter(Boolean);
    if (ids.length) {
      getMaterialsByIds(ids)
        .then((ms) => setItems(ms.map((m) => ({ material: m, copies: 1 }))))
        .catch(() => undefined);
    }
  }, [params]);

  const add = (m: Material) =>
    setItems((list) => (list.some((x) => x.material.id === m.id) ? list : [...list, { material: m, copies: 1 }]));

  const print = () => {
    void markLabelsPrinted(items.map((i) => i.material.id));
    window.print();
  };

  const s = SIZES[size];
  const labels = items.flatMap((i) => Array.from({ length: i.copies }, (_, n) => ({ ...i, n })));

  return (
    <div>
      <div className="print:hidden">
        <PageHeader
          title="Etiquetas com QR Code"
          subtitle="Selecione os materiais, ajuste o tamanho e imprima. Funciona com impressora comum (A4) ou de etiquetas."
          actions={
            <Button icon={<Printer className="h-4 w-4" />} onClick={print} disabled={items.length === 0}>
              Imprimir {labels.length} etiqueta(s)
            </Button>
          }
        />
        <div className="grid gap-4 lg:grid-cols-[1fr_380px]">
          <Card>
            <CardHeader title="Materiais selecionados" />
            {items.length === 0 ? (
              <EmptyState title="Nenhum material selecionado" description="Pesquise ao lado ou selecione na tela de Materiais." />
            ) : (
              <ul className="divide-y divide-slate-100">
                {items.map((i) => (
                  <li key={i.material.id} className="flex items-center justify-between gap-3 py-2">
                    <div className="min-w-0">
                      <p className="truncate font-medium">{i.material.name}</p>
                      <p className="text-xs text-slate-500">
                        {i.material.code} · {i.material.qr_code}
                      </p>
                    </div>
                    <div className="flex items-center gap-2">
                      <label className="text-xs text-slate-500">
                        Cópias
                        <input
                          type="number"
                          min={1}
                          max={100}
                          value={i.copies}
                          onChange={(e) =>
                            setItems((list) =>
                              list.map((x) => (x.material.id === i.material.id ? { ...x, copies: Math.min(100, Math.max(1, Number(e.target.value) || 1)) } : x)),
                            )
                          }
                          className="ml-1 h-8 w-16 rounded-md border-0 text-center ring-1 ring-inset ring-slate-300"
                        />
                      </label>
                      <button
                        type="button"
                        aria-label="Remover"
                        className="rounded p-1.5 text-slate-400 hover:bg-red-50 hover:text-red-600"
                        onClick={() => setItems((list) => list.filter((x) => x.material.id !== i.material.id))}
                      >
                        <Trash2 className="h-4 w-4" />
                      </button>
                    </div>
                  </li>
                ))}
              </ul>
            )}
          </Card>
          <div className="space-y-4">
            <Card>
              <CardHeader title="Formato" />
              <div className="space-y-3">
                <Select label="Tamanho da etiqueta" value={size} onChange={(e) => setSize(e.target.value as SizeKey)}>
                  {Object.entries(SIZES).map(([k, v]) => (
                    <option key={k} value={k}>
                      {v.label}
                    </option>
                  ))}
                </Select>
                <Checkbox label="Mostrar localização" checked={showLocation} onChange={setShowLocation} />
              </div>
            </Card>
            <Card>
              <CardHeader title="Adicionar material" />
              <MaterialSearch onSelect={add} />
            </Card>
          </div>
        </div>
        {labels.length > 0 && (
          <h3 className="mb-2 mt-6 text-sm font-semibold text-slate-700">Pré-visualização</h3>
        )}
      </div>

      <div className="labels-sheet flex flex-wrap gap-[3mm] print:gap-[2mm]">
        {labels.map(({ material: m, n }) => (
          <div
            key={`${m.id}-${n}`}
            style={{ width: s.w, height: s.h }}
            className={clsx('flex items-center gap-[2mm] overflow-hidden rounded border border-slate-400 bg-white p-[2mm] text-black [break-inside:avoid]', s.font)}
          >
            <QRCodeImage value={m.qr_code} size={s.qr} className="h-full w-auto shrink-0" />
            <div className="min-w-0 leading-tight">
              <p className="font-mono font-bold">{m.code}</p>
              {m.reference && <p className="truncate">Ref. {m.reference}</p>}
              <p className="line-clamp-3 font-semibold">{m.name}</p>
              <p>Unid.: {m.unit}</p>
              {showLocation && m.location && <p>Loc.: {m.location}</p>}
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}
