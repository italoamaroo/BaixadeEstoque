import { useEffect, useMemo, useState } from 'react';
import { useSearchParams } from 'react-router-dom';
import { Download, FileSpreadsheet, FileText, ListTree, Rows3 } from 'lucide-react';
import { toast } from 'sonner';
import clsx from 'clsx';
import { useAuth } from '@/contexts/AuthContext';
import { FiltersPanel } from '@/components/FiltersPanel';
import { Button } from '@/components/ui/Button';
import { Alert, Card, CardHeader, PageHeader } from '@/components/ui/Card';
import { exportMovements, logEvent, searchMovements } from '@/lib/api';
import { buildWorkbook, downloadBlob, type ExportKind } from '@/lib/excel';
import { buildMovementsPdf, fetchPdfData, PDF_LIMIT } from '@/lib/pdfReport';
import { errorMessage } from '@/lib/errors';
import { describeFilters, exportFileName, filtersFromSearchParams, filtersToSearchParams, toRpcFilters } from '@/lib/filters';
import { fmtInt } from '@/lib/format';

export function ExportPage() {
  const { warehouses, displayName, settings } = useAuth();
  const [params, setParams] = useSearchParams();
  const filters = useMemo(() => filtersFromSearchParams(params), [params]);
  const [kind, setKind] = useState<ExportKind>('resumo');
  const [count, setCount] = useState<number | null>(null);
  const [busy, setBusy] = useState(false);
  const [pdfBusy, setPdfBusy] = useState(false);
  const [pdfProgress, setPdfProgress] = useState('');
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let alive = true;
    setCount(null);
    searchMovements(filters, 1, 1, 'movement_at', 'desc')
      .then((r) => alive && setCount(r.total))
      .catch((e) => alive && setError(errorMessage(e)));
    return () => {
      alive = false;
    };
  }, [filters]);

  const lines = describeFilters(filters, warehouses);
  const fileName = exportFileName(filters, warehouses, kind);

  const run = async () => {
    if (busy) return;
    setBusy(true);
    setError(null);
    try {
      const rows = await exportMovements(filters, kind);
      if (rows.length === 0) {
        toast.info('Nenhum registro para exportar com os filtros atuais.');
        return;
      }
      const blob = await buildWorkbook(kind, rows, lines, displayName);
      downloadBlob(blob, fileName);
      void logEvent('exportacao.excel', null, { tipo: kind, registros: rows.length, filtros: toRpcFilters(filters), arquivo: fileName });
      toast.success(`${fmtInt(rows.length)} linha(s) exportada(s).`);
    } catch (err) {
      setError(errorMessage(err));
    } finally {
      setBusy(false);
    }
  };

  const runPdf = async () => {
    if (pdfBusy) return;
    setPdfBusy(true);
    setError(null);
    try {
      const data = await fetchPdfData(filters, setPdfProgress);
      if (data.rows.length === 0) {
        toast.info('Nenhuma ME para gerar o PDF com os filtros atuais.');
        return;
      }
      setPdfProgress('Montando o PDF…');
      const blob = await buildMovementsPdf(data.rows, {
        filterLines: lines,
        generatedBy: displayName,
        companyName: settings?.company_name ?? '',
        total: data.total,
        truncated: data.truncated,
      });
      const pdfName = fileName.replace(/(_itens)?\.xlsx$/, '_com_assinaturas.pdf');
      downloadBlob(blob, pdfName);
      void logEvent('me.pdf_gerado', null, { relatorio: true, mes: data.rows.length, filtros: toRpcFilters(filters), arquivo: pdfName });
      toast.success(`PDF gerado com ${fmtInt(data.rows.length)} ME(s).`);
      if (data.truncated) toast.warning(`Foram incluídas as primeiras ${PDF_LIMIT} MEs. Refine os filtros para gerar o restante.`);
    } catch (err) {
      setError(errorMessage(err));
    } finally {
      setPdfBusy(false);
      setPdfProgress('');
    }
  };

  return (
    <div className="space-y-4">
      <PageHeader title="Exportar Excel e PDF" subtitle="Os dados vêm direto do Supabase e respeitam exatamente os filtros abaixo." />
      <FiltersPanel value={filters} onApply={(f) => setParams(filtersToSearchParams(f), { replace: true })} defaultOpen />

      <Card>
        <CardHeader title="Tipo de relatório" />
        <div className="grid gap-3 sm:grid-cols-2">
          {(
            [
              ['resumo', 'Resumo por ME', 'Uma linha por ME com cabeçalho, requisitante, SA e status.', <Rows3 key="r" className="h-6 w-6" />],
              ['itens', 'Detalhamento por item', 'Uma linha por material, com quantidades, conta e localização.', <ListTree key="i" className="h-6 w-6" />],
            ] as const
          ).map(([k, title, desc, icon]) => (
            <button
              key={k}
              type="button"
              onClick={() => setKind(k)}
              aria-pressed={kind === k}
              className={clsx(
                'flex items-start gap-3 rounded-xl border-2 p-4 text-left',
                kind === k ? 'border-brand-600 bg-brand-50' : 'border-slate-200 hover:bg-slate-50',
              )}
            >
              <span className="text-brand-700">{icon}</span>
              <span>
                <span className="block font-semibold text-slate-900">{title}</span>
                <span className="text-sm text-slate-500">{desc}</span>
              </span>
            </button>
          ))}
        </div>

        <div className="mt-5 rounded-lg bg-slate-50 p-4 text-sm">
          <p className="flex items-center gap-2 font-semibold text-slate-800">
            <FileSpreadsheet className="h-4 w-4 text-emerald-700" /> {fileName}
          </p>
          <ul className="mt-2 space-y-0.5 text-slate-600">
            {lines.map((l) => (
              <li key={l}>{l}</li>
            ))}
            <li>
              MEs encontradas: <strong>{count === null ? '…' : fmtInt(count)}</strong>
              {kind === 'itens' && ' (o arquivo terá uma linha por item)'}
            </li>
          </ul>
        </div>
        {error && (
          <div className="mt-4">
            <Alert tone="error">{error}</Alert>
          </div>
        )}
        <div className="mt-5 flex justify-end">
          <Button size="lg" variant="success" icon={<Download className="h-5 w-5" />} loading={busy} onClick={() => void run()} disabled={count === 0 || pdfBusy}>
            Gerar Excel
          </Button>
        </div>
      </Card>

      <Card>
        <CardHeader
          title="PDF com itens e assinaturas"
          subtitle={`Uma página por ME com cabeçalho, materiais e a assinatura digital de quem recebeu. Usa os mesmos filtros acima (até ${PDF_LIMIT} MEs por arquivo).`}
        />
        <div className="flex flex-wrap items-center justify-between gap-3">
          <p className="text-sm text-slate-600">
            {pdfBusy ? pdfProgress : <>MEs no PDF: <strong>{count === null ? '…' : fmtInt(Math.min(count, PDF_LIMIT))}</strong></>}
          </p>
          <Button size="lg" icon={<FileText className="h-5 w-5" />} loading={pdfBusy} onClick={() => void runPdf()} disabled={count === 0 || busy}>
            Gerar PDF
          </Button>
        </div>
      </Card>
    </div>
  );
}
