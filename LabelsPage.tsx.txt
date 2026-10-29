import { useEffect, useState } from 'react';
import { useSearchParams } from 'react-router-dom';
import { Download, FileSpreadsheet, Printer, Trash2, Upload } from 'lucide-react';
import { toast } from 'sonner';
import clsx from 'clsx';
import { Button } from '@/components/ui/Button';
import { Alert, Card, CardHeader, EmptyState, PageHeader } from '@/components/ui/Card';
import { Checkbox, Select } from '@/components/ui/Field';
import { Modal } from '@/components/ui/Modal';
import { MaterialSearch } from '@/components/MaterialSearch';
import { QRCodeImage } from '@/components/QRCodeImage';
import { getMaterialsByCodes, getMaterialsByIds, importMaterials, markLabelsPrinted, withRetry } from '@/lib/api';
import { downloadBlob } from '@/lib/excel';
import { errorMessage } from '@/lib/errors';
import { fmtInt } from '@/lib/format';
import { parseLabelsFile, type LabelSheetRow } from '@/lib/import';
import { useAuth } from '@/contexts/AuthContext';
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
    // código em destaque (14pt) e nome em até 2 linhas
    nameLines: 'line-clamp-2 leading-[1.1]',
  },
  pequena: { label: 'Folha A4 – pequena (50 × 30 mm)', w: '50mm', h: '30mm', qr: 80, font: 'text-[8px]' },
  media: { label: 'Folha A4 – média (70 × 40 mm)', w: '70mm', h: '40mm', qr: 110, font: 'text-[10px]' },
  grande: { label: 'Folha A4 – grande (100 × 60 mm)', w: '100mm', h: '60mm', qr: 170, font: 'text-[12px]' },
} satisfies Record<string, LabelSize>;

type SizeKey = keyof typeof SIZES;
/** etiquetas por lote de impressão, para o navegador e a impressora não travarem */
const BATCH_SIZE = 300;
/** limite total da lista */
const MAX_LABELS = 10000;
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
  const [importOpen, setImportOpen] = useState(false);
  const [preparing, setPreparing] = useState(false);
  const [batch, setBatch] = useState(0);

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

  const print = async () => {
    if (labels.length > MAX_LABELS) {
      toast.error(`A lista tem mais de ${fmtInt(MAX_LABELS)} etiquetas. Reduza as cópias ou remova itens.`);
      return;
    }
    // espera todos os QR Codes do lote serem gerados antes de abrir a impressão
    setPreparing(true);
    const start = Date.now();
    while (document.querySelectorAll('.labels-sheet img').length < batchLabels.length && Date.now() - start < 30000) {
      await new Promise((r) => setTimeout(r, 150));
    }
    setPreparing(false);
    void markLabelsPrinted([...new Set(batchLabels.map((l) => l.material.id))]);
    window.print();
    if (batchCount > 1 && batch < batchCount - 1) {
      toast.success(`Lote ${batch + 1} de ${batchCount} enviado. Clique em Imprimir para o lote ${batch + 2}.`);
      setBatch(batch + 1);
    } else if (batchCount > 1) {
      toast.success('Todos os lotes foram enviados para impressão.');
    }
  };

  /** Inclui na lista os materiais vindos da planilha (somando cópias de quem já estava). */
  const addFromSheet = (list: { material: Material; copies: number }[], replace: boolean) => {
    setBatch(0);
    setItems((current) => {
      const base = replace ? [] : [...current];
      for (const it of list) {
        const ex = base.find((x) => x.material.id === it.material.id);
        if (ex) ex.copies = Math.min(100, ex.copies + it.copies);
        else base.push({ ...it });
      }
      return base;
    });
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
  const batchCount = Math.max(1, Math.ceil(labels.length / BATCH_SIZE));
  const currentBatch = Math.min(batch, batchCount - 1);
  const batchLabels = labels.slice(currentBatch * BATCH_SIZE, (currentBatch + 1) * BATCH_SIZE);
  const batchRange = (b: number) => `${fmtInt(b * BATCH_SIZE + 1)} a ${fmtInt(Math.min((b + 1) * BATCH_SIZE, labels.length))}`;

  return (
    <div>
      <div className="print:hidden">
        <PageHeader
          title="Etiquetas com QR Code"
          subtitle="Selecione os materiais, ajuste o tamanho e imprima. Funciona com impressora comum (A4) ou de etiquetas."
          actions={
            <>
              <Button variant="secondary" icon={<Upload className="h-4 w-4" />} onClick={() => setImportOpen(true)}>
                Importar planilha
              </Button>
              {items.length > 0 && (
                <Button variant="ghost" icon={<Trash2 className="h-4 w-4" />} onClick={() => { setItems([]); setBatch(0); }}>
                  Limpar lista
                </Button>
              )}
              <Button icon={<Printer className="h-4 w-4" />} onClick={() => void print()} disabled={items.length === 0} loading={preparing}>
                {preparing
                  ? 'Preparando…'
                  : batchCount > 1
                    ? `Imprimir lote ${currentBatch + 1} de ${batchCount} (${fmtInt(batchLabels.length)})`
                    : `Imprimir ${fmtInt(labels.length)} etiqueta(s)`}
              </Button>
            </>
          }
        />
        <div className="grid gap-4 lg:grid-cols-[1fr_380px]">
          <Card>
            <CardHeader
              title="Materiais selecionados"
              subtitle={items.length ? `${fmtInt(items.length)} material(is) · ${fmtInt(labels.length)} etiqueta(s)` : undefined}
            />
            {labels.length > MAX_LABELS && (
              <div className="mb-3">
                <Alert tone="warning">
                  São {fmtInt(labels.length)} etiquetas. O máximo da lista é {fmtInt(MAX_LABELS)}: reduza as cópias ou divida a planilha.
                </Alert>
              </div>
            )}
            {batchCount > 1 && labels.length <= MAX_LABELS && (
              <div className="mb-3 rounded-lg bg-brand-50 p-3 text-sm text-brand-900">
                <p>
                  São <strong>{fmtInt(labels.length)}</strong> etiquetas, impressas em <strong>{batchCount} lotes</strong> de até{' '}
                  {fmtInt(BATCH_SIZE)}. Depois de cada impressão o próximo lote é selecionado automaticamente.
                </p>
                <div className="mt-2 max-w-xs">
                  <Select label="Lote a imprimir" value={String(currentBatch)} onChange={(e) => setBatch(Number(e.target.value))}>
                    {Array.from({ length: batchCount }, (_, b) => (
                      <option key={b} value={b}>
                        Lote {b + 1} – etiquetas {batchRange(b)}
                      </option>
                    ))}
                  </Select>
                </div>
              </div>
            )}
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
          <h3 className="mb-2 mt-6 text-sm font-semibold text-slate-700">
            Pré-visualização{batchCount > 1 ? ` – lote ${currentBatch + 1} (etiquetas ${batchRange(currentBatch)})` : ''}
          </h3>
        )}
      </div>

      <div
        className={clsx(
          'labels-sheet flex flex-wrap',
          s.thermal ? 'gap-[3mm] print:block print:gap-0' : 'gap-[3mm] print:gap-[2mm]',
        )}
      >
        {batchLabels.map(({ material: m, n }, idx) => (
          <div
            key={`${m.id}-${n}`}
            style={{ width: s.w, height: s.h }}
            className={clsx(
              'flex items-center overflow-hidden bg-white text-black',
              s.font,
              s.thermal
                ? clsx(
                    'gap-[1.5mm] rounded-sm border border-slate-400 px-[1.5mm] py-[1mm] print:rounded-none print:border-0',
                    idx < batchLabels.length - 1 && 'print:[break-after:page]',
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
              <p
                className="truncate font-mono font-bold"
                // térmica: código em 14pt; códigos com mais de 12 caracteres em 12pt para caber na largura
                style={s.thermal ? { fontSize: m.code.length <= 12 ? '14pt' : '12pt', lineHeight: 1.05 } : undefined}
              >
                {m.code}
              </p>
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
      <ImportLabelsModal open={importOpen} onClose={() => setImportOpen(false)} onConfirm={addFromSheet} />
    </div>
  );
}

interface Analysis {
  rows: LabelSheetRow[];
  found: { material: Material; copies: number }[];
  inactive: Material[];
  missing: LabelSheetRow[];
}

/** Importa uma planilha (.xlsx/.csv) com os códigos dos materiais e gera as etiquetas de todos. */
function ImportLabelsModal({
  open,
  onClose,
  onConfirm,
}: {
  open: boolean;
  onClose: () => void;
  onConfirm: (list: { material: Material; copies: number }[], replace: boolean) => void;
}) {
  const { can } = useAuth();
  const [analysis, setAnalysis] = useState<Analysis | null>(null);
  const [busy, setBusy] = useState(false);
  const [progress, setProgress] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [replace, setReplace] = useState(true);
  const [createMissing, setCreateMissing] = useState(true);

  useEffect(() => {
    if (open) {
      setAnalysis(null);
      setError(null);
      setProgress('');
      setReplace(true);
      setCreateMissing(true);
    }
  }, [open]);

  const analyze = async (rows: LabelSheetRow[]): Promise<Analysis> => {
    setProgress(`Procurando ${fmtInt(rows.length)} código(s) no cadastro…`);
    const mats = await getMaterialsByCodes(rows.map((r) => r.code));
    const byCode = new Map(mats.map((m) => [m.code.toUpperCase(), m]));
    const found: Analysis['found'] = [];
    const inactive: Material[] = [];
    const missing: LabelSheetRow[] = [];
    for (const r of rows) {
      const m = byCode.get(r.code);
      if (!m) missing.push(r);
      else if (!m.active) inactive.push(m);
      else found.push({ material: m, copies: r.copies });
    }
    return { rows, found, inactive, missing };
  };

  const onFile = async (f: File | undefined) => {
    if (!f) return;
    setError(null);
    setAnalysis(null);
    setBusy(true);
    try {
      const rows = await parseLabelsFile(f);
      if (rows.length === 0) throw new Error('Nenhum código encontrado na planilha.');
      setAnalysis(await analyze(rows));
    } catch (err) {
      setError(errorMessage(err));
    } finally {
      setBusy(false);
      setProgress('');
    }
  };

  const creatable = (analysis?.missing ?? []).filter((r) => String(r.material.name ?? '').trim() && String(r.material.unit ?? '').trim());
  const canCreate = can('manageMasterData') && creatable.length > 0;

  const confirm = async () => {
    if (!analysis || busy) return;
    setBusy(true);
    setError(null);
    try {
      let result = analysis;
      if (canCreate && createMissing) {
        for (let i = 0; i < creatable.length; i += 500) {
          setProgress(`Cadastrando materiais ${fmtInt(Math.min(i + 500, creatable.length))} de ${fmtInt(creatable.length)}…`);
          const part = creatable.slice(i, i + 500).map((r) => r.material);
          await withRetry(() => importMaterials(part));
        }
        result = await analyze(analysis.rows);
        setAnalysis(result);
      }
      if (result.found.length === 0) throw new Error('Nenhum material ativo encontrado para gerar etiquetas.');
      onConfirm(result.found, replace);
      const total = result.found.reduce((s, x) => s + x.copies, 0);
      toast.success(`${fmtInt(result.found.length)} material(is) adicionados · ${fmtInt(total)} etiqueta(s).`);
      onClose();
    } catch (err) {
      setError(errorMessage(err));
    } finally {
      setBusy(false);
      setProgress('');
    }
  };

  const downloadTemplate = async () => {
    const ExcelJS = (await import('exceljs')).default;
    const wb = new ExcelJS.Workbook();
    const ws = wb.addWorksheet('etiquetas');
    ws.columns = [
      { header: 'codigo', key: 'code', width: 20 },
      { header: 'copias', key: 'copies', width: 10 },
      { header: 'nome', key: 'name', width: 40 },
      { header: 'unidade', key: 'unit', width: 10 },
      { header: 'localizacao', key: 'location', width: 14 },
    ];
    ws.addRow({ code: 'AA001466D', copies: 2, name: 'SERRA COPO BIMET TRAMONTINA 42620515 JG 15 PCS', unit: 'PC', location: 'D-03-02' });
    ws.addRow({ code: 'BC002A83', copies: 1 });
    ws.getRow(1).font = { bold: true };
    const buf = await wb.xlsx.writeBuffer();
    downloadBlob(new Blob([buf], { type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' }), 'modelo_etiquetas.xlsx');
  };

  const totalLabels = analysis?.found.reduce((s, x) => s + x.copies, 0) ?? 0;

  return (
    <Modal
      open={open}
      onClose={onClose}
      busy={busy}
      size="lg"
      title="Gerar etiquetas a partir de planilha"
      description="Planilha .xlsx ou .csv com os códigos dos materiais. Opcional: coluna de cópias (quantas etiquetas por item)."
      footer={
        <>
          <Button variant="ghost" icon={<Download className="h-4 w-4" />} onClick={() => void downloadTemplate()}>
            Baixar modelo
          </Button>
          <Button onClick={() => void confirm()} loading={busy} disabled={!analysis || (analysis.found.length === 0 && !(canCreate && createMissing))}>
            {busy && progress ? progress : 'Gerar etiquetas'}
          </Button>
        </>
      }
    >
      <div className="space-y-4">
        <p className="text-sm text-slate-600">
          Coluna obrigatória: <strong>codigo</strong> (também aceita “Cód. Produto”, “Código”, “Item”…). Opcional: <strong>copias</strong> (ou
          “Qtd”, “Quantidade”). Sem essa coluna, sai 1 etiqueta por item. Códigos repetidos somam as cópias. Pode usar a mesma planilha da
          importação de materiais.
        </p>
        <label className="flex cursor-pointer items-center gap-3 rounded-lg border-2 border-dashed border-slate-300 p-4 hover:border-brand-400">
          <FileSpreadsheet className="h-8 w-8 text-emerald-600" />
          <span className="text-sm">
            <span className="font-semibold text-brand-700">Escolher planilha</span>
            <span className="block text-slate-500">.xlsx ou .csv, até 5 MB</span>
          </span>
          <input type="file" accept=".xlsx,.xls,.csv,text/csv" className="hidden" onChange={(e) => void onFile(e.target.files?.[0])} />
        </label>
        {busy && progress && !analysis && <p className="text-sm text-slate-500">{progress}</p>}
        {error && <Alert tone="error">{error}</Alert>}
        {analysis && (
          <div className="space-y-3">
            <div className="grid grid-cols-3 gap-2 text-center text-sm">
              <div className="rounded-lg bg-emerald-50 p-3">
                <p className="text-xl font-bold text-emerald-700">{fmtInt(analysis.found.length)}</p>
                <p className="text-emerald-800">encontrados</p>
              </div>
              <div className="rounded-lg bg-orange-50 p-3">
                <p className="text-xl font-bold text-orange-700">{fmtInt(analysis.missing.length)}</p>
                <p className="text-orange-800">não cadastrados</p>
              </div>
              <div className="rounded-lg bg-slate-100 p-3">
                <p className="text-xl font-bold text-slate-700">{fmtInt(analysis.inactive.length)}</p>
                <p className="text-slate-600">inativos (ignorados)</p>
              </div>
            </div>
            <p className="text-sm text-slate-700">
              Etiquetas a gerar: <strong>{fmtInt(totalLabels)}</strong>
              {totalLabels > BATCH_SIZE && <span className="text-orange-700"> · será impresso em lotes de {fmtInt(BATCH_SIZE)}</span>}
            </p>
            {analysis.missing.length > 0 && (
              <Alert tone="warning" title={`${fmtInt(analysis.missing.length)} código(s) não estão cadastrados`}>
                <p className="max-h-20 overflow-auto font-mono text-xs">
                  {analysis.missing.slice(0, 60).map((r) => r.code).join(', ')}
                  {analysis.missing.length > 60 ? '…' : ''}
                </p>
                {canCreate ? (
                  <div className="mt-2">
                    <Checkbox
                      label={`Cadastrar automaticamente ${fmtInt(creatable.length)} item(ns) que têm nome e unidade na planilha`}
                      checked={createMissing}
                      onChange={setCreateMissing}
                    />
                  </div>
                ) : (
                  <p className="mt-1 text-xs">
                    {can('manageMasterData')
                      ? 'Para cadastrá-los aqui, a planilha precisa ter as colunas nome (ou descrição) e unidade.'
                      : 'Peça o cadastro ao almoxarife ou administrador.'}
                  </p>
                )}
              </Alert>
            )}
            <Checkbox label="Substituir a lista atual" description="Desmarque para somar aos materiais que já estão na tela." checked={replace} onChange={setReplace} />
          </div>
        )}
      </div>
    </Modal>
  );
}
