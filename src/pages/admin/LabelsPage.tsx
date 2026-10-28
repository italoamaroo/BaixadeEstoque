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

interface LabelSize {
  label: string;
  w: string;
  h: string;
  qr: number;
  font: string;
  /** impressora térmica: 1 etiqueta por página, página do tamanho exato da etiqueta */
  thermal?: boolean;
  qrMm?: string;
  nameLines?: string;
}

const SIZES = {
  termica7025: {
    label: 'Térmica 67,5 × 25 mm (Elgin L42 Pro)',
    w: '67.5mm',
    h: '25mm',
    qr: 220,
    font: 'text-[8pt]',
    thermal: true,
    qrMm: '21mm',
    // nome maior e em até 3 linhas para ocupar a área livre da etiqueta
    nameLines: 'line-clamp-3 leading-[1.1]',
  },
  pequena: { label: 'Folha A4 – pequena (50 × 30 mm)', w: '50mm', h: '30mm', qr: 80, font: 'text-[8px]' },
  media: { label: 'Folha A4 – média (70 × 40 mm)', w: '70mm', h: '40mm', qr: 110, font: 'text-[10px]' },
  grande: { label: 'Folha A4 – grande (100 × 60 mm)', w: '100mm', h: '60mm', qr: 170, font: 'text-[12px]' },
} satisfies Record<string, LabelSize>;

type SizeKey = keyof typeof SIZES;
const SIZE_KEY = 'baixas-estoque:etiqueta-tamanho';

function loadSize(): SizeKey {
  try {
    const v = localStorage.getItem(SIZE_KEY);
    if (v && v in SIZES) return v as SizeKey;
  } catch {
    /* ignore */
  }
  return 'termica7025';
}

export function LabelsPage() {
  const [params] = useSearchParams();
  const [items, setItems] = useState<{ material: Material; copies: number }[]>([]);
  const [size, setSizeState] = useState<SizeKey>(loadSize);
  const setSize = (k: SizeKey) => {
    setSizeState(k);
    try {
      localStorage.setItem(SIZE_KEY, k);
    } catch {
      /* ignore */
    }
  };
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

  const s: LabelSize = SIZES[size];

  // Na térmica, a página de impressão tem exatamente o tamanho da etiqueta e sem margens.
  useEffect(() => {
    const el = document.createElement('style');
    el.setAttribute('data-labels-page', '');
    el.textContent = s.thermal
      ? `@media print {
          @page { size: ${s.w} ${s.h}; margin: 0; }
          html, body { margin: 0 !important; padding: 0 !important; width: ${s.w}; }
          /* etiqueta um pouco menor que a página para nunca "vazar" para uma segunda página */
          .labels-sheet > div { height: calc(${s.h} - 0.6mm) !important; break-inside: avoid; page-break-inside: avoid; }
          [data-sonner-toaster] { display: none !important; }
        }`
      : '@media print { @page { size: A4 portrait; margin: 8mm; } }';
    document.head.appendChild(el);
    return () => el.remove();
  }, [s.thermal, s.w, s.h]);
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
                {s.thermal && (
                  <div className="rounded-lg bg-brand-50 p-3 text-xs text-brand-900">
                    <p className="font-semibold">Na janela de impressão do navegador:</p>
                    <ul className="mt-1 list-disc space-y-0.5 pl-4">
                      <li>Destino: <strong>Elgin L42 Pro</strong></li>
                      <li>Margens: <strong>Nenhuma</strong> · Escala: <strong>100%</strong> (ou “Padrão”)</li>
                      <li>Desmarque “Cabeçalhos e rodapés”</li>
                      <li>
                        No driver da impressora (Preferências de impressão), deixe o papel em <strong>67,5 × 25 mm</strong> e o tipo de mídia
                        como <strong>etiqueta com gap</strong>.
                      </li>
                    </ul>
                    <p className="mt-1">Cada etiqueta sai em uma página; as cópias saem em sequência.</p>
                  </div>
                )}
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

      <div
        className={clsx(
          'labels-sheet flex flex-wrap',
          s.thermal ? 'gap-[3mm] print:block print:gap-0' : 'gap-[3mm] print:gap-[2mm]',
        )}
      >
        {labels.map(({ material: m, n }, idx) => (
          <div
            key={`${m.id}-${n}`}
            style={{ width: s.w, height: s.h }}
            className={clsx(
              'flex items-center overflow-hidden bg-white text-black',
              s.font,
              s.thermal
                ? clsx(
                    'gap-[1.5mm] rounded-sm border border-slate-400 px-[1.5mm] py-[1mm] print:rounded-none print:border-0',
                    idx < labels.length - 1 && 'print:[break-after:page]',
                  )
                : 'gap-[2mm] rounded border border-slate-400 p-[2mm] [break-inside:avoid]',
            )}
          >
            <QRCodeImage
              value={m.qr_code}
              size={s.qr}
              className={clsx('shrink-0 [image-rendering:pixelated]', !s.qrMm && 'h-full w-auto')}
              style={s.qrMm ? { width: s.qrMm, height: s.qrMm } : undefined}
            />
            <div className={clsx('min-w-0 flex-1', s.thermal ? 'flex h-full flex-col justify-center gap-[0.4mm] leading-[1.1]' : 'leading-[1.15]')}>
              <p className="truncate font-mono font-bold">{m.code}</p>
              {m.reference && <p className="truncate">Ref. {m.reference}</p>}
              <p
                className={clsx('font-semibold', s.nameLines ?? 'line-clamp-3')}
                // térmica: nomes curtos ficam maiores para preencher a etiqueta
                style={s.thermal ? { fontSize: m.name.length <= 22 ? '12pt' : m.name.length <= 40 ? '11pt' : '10pt' } : undefined}
              >
                {m.name}
              </p>
              <p className="truncate">
                Unid.: {m.unit}
                {s.thermal && showLocation && m.location ? ` · Loc.: ${m.location}` : ''}
              </p>
              {!s.thermal && showLocation && m.location && <p>Loc.: {m.location}</p>}
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}
