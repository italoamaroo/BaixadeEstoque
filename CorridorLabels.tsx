import { useEffect, useMemo, useState } from 'react';
import { ListPlus, Printer, Trash2 } from 'lucide-react';
import { toast } from 'sonner';
import { Button } from '@/components/ui/Button';
import { Alert, Card, CardHeader, EmptyState, PageHeader } from '@/components/ui/Card';
import { Input, Textarea } from '@/components/ui/Field';
import { fmtInt } from '@/lib/format';

/** Etiquetas de corredor/localização: só texto, grande, na térmica 67,5 × 25 mm. */
const W = '67.5mm';
const H = '25mm';
const MAX = 1000;

/** Fonte do código conforme o tamanho do texto, para sempre caber na largura. */
function codeFont(code: string): string {
  const n = code.length;
  if (n <= 3) return '50pt';
  if (n <= 4) return '44pt';
  if (n <= 5) return '38pt';
  if (n <= 6) return '33pt';
  if (n <= 8) return '26pt';
  if (n <= 10) return '21pt';
  return '17pt';
}

/** Separa por linha, vírgula, ponto e vírgula ou tabulação (colar de uma coluna do Excel funciona). */
export function parseCodes(text: string): string[] {
  return text
    .split(/[\n,;\t]+/)
    .map((s) => s.trim().toUpperCase())
    .filter(Boolean)
    .map((s) => s.slice(0, 20));
}

/** Gera sequência: letras de A até C × números de 1 até 20 → A01…C20. */
export function buildSequence(fromLetter: string, toLetter: string, fromNum: number, toNum: number, digits: number): string[] {
  const a = (fromLetter.trim().toUpperCase() || 'A').charCodeAt(0);
  const b = (toLetter.trim().toUpperCase() || fromLetter.trim().toUpperCase() || 'A').charCodeAt(0);
  const out: string[] = [];
  for (let c = Math.min(a, b); c <= Math.max(a, b); c++) {
    for (let n = Math.min(fromNum, toNum); n <= Math.max(fromNum, toNum); n++) {
      out.push(String.fromCharCode(c) + String(n).padStart(digits, '0'));
      if (out.length > MAX) return out;
    }
  }
  return out;
}

export function CorridorLabels() {
  const [title, setTitle] = useState('CORREDOR');
  const [codes, setCodes] = useState<string[]>([]);
  const [copies, setCopies] = useState(1);
  const [paste, setPaste] = useState('');
  const [seq, setSeq] = useState({ fromLetter: 'A', toLetter: 'C', fromNum: '1', toNum: '10', digits: '2' });

  const labels = useMemo(() => codes.flatMap((c) => Array.from({ length: copies }, (_, n) => ({ code: c, n }))), [codes, copies]);

  // página de impressão do tamanho exato da etiqueta, sem margens
  useEffect(() => {
    const el = document.createElement('style');
    el.textContent = `@media print {
      @page { size: ${W} ${H}; margin: 0; }
      html, body { margin: 0 !important; padding: 0 !important; width: ${W}; }
      .corridor-sheet > div { height: calc(${H} - 0.6mm) !important; break-inside: avoid; page-break-inside: avoid; }
      [data-sonner-toaster] { display: none !important; }
    }`;
    document.head.appendChild(el);
    return () => el.remove();
  }, []);

  const addCodes = (list: string[]) => {
    if (list.length === 0) {
      toast.error('Nenhum código informado.');
      return;
    }
    setCodes((cur) => {
      const merged = [...cur];
      for (const c of list) if (!merged.includes(c)) merged.push(c);
      if (merged.length > MAX) toast.warning(`Limite de ${fmtInt(MAX)} corredores; os excedentes foram ignorados.`);
      return merged.slice(0, MAX);
    });
  };

  const addSequence = () => {
    const fromNum = Number(seq.fromNum);
    const toNum = Number(seq.toNum);
    const digits = Math.min(4, Math.max(1, Number(seq.digits) || 2));
    if (!/^[A-Za-z]$/.test(seq.fromLetter.trim()) || (seq.toLetter.trim() && !/^[A-Za-z]$/.test(seq.toLetter.trim()))) {
      toast.error('Use uma letra de A a Z nos campos de letra.');
      return;
    }
    if (!Number.isInteger(fromNum) || !Number.isInteger(toNum) || fromNum < 0 || toNum < 0) {
      toast.error('Informe números inteiros no intervalo.');
      return;
    }
    addCodes(buildSequence(seq.fromLetter, seq.toLetter, fromNum, toNum, digits));
  };

  const print = () => {
    if (labels.length > MAX) {
      toast.error(`Imprima no máximo ${fmtInt(MAX)} etiquetas por vez.`);
      return;
    }
    window.print();
  };

  return (
    <div>
      <div className="print:hidden">
        <PageHeader
          title="Etiquetas de corredor"
          subtitle="Só texto, em tamanho grande, na térmica 67,5 × 25 mm (Elgin L42 Pro)."
          actions={
            <>
              {codes.length > 0 && (
                <Button variant="ghost" icon={<Trash2 className="h-4 w-4" />} onClick={() => setCodes([])}>
                  Limpar lista
                </Button>
              )}
              <Button icon={<Printer className="h-4 w-4" />} onClick={print} disabled={labels.length === 0}>
                Imprimir {fmtInt(labels.length)} etiqueta(s)
              </Button>
            </>
          }
        />
        <div className="grid gap-4 lg:grid-cols-[1fr_380px]">
          <Card>
            <CardHeader title="Corredores" subtitle={codes.length ? `${fmtInt(codes.length)} corredor(es) · ${fmtInt(labels.length)} etiqueta(s)` : undefined} />
            {codes.length === 0 ? (
              <EmptyState title="Nenhum corredor na lista" description="Digite os códigos ou gere uma sequência ao lado." />
            ) : (
              <div className="flex flex-wrap gap-2">
                {codes.map((c) => (
                  <span key={c} className="inline-flex items-center gap-1 rounded-lg bg-slate-100 py-1 pl-3 pr-1 font-mono text-sm font-semibold">
                    {c}
                    <button
                      type="button"
                      aria-label={`Remover ${c}`}
                      className="rounded p-1 text-slate-400 hover:bg-red-50 hover:text-red-600"
                      onClick={() => setCodes((l) => l.filter((x) => x !== c))}
                    >
                      <Trash2 className="h-3.5 w-3.5" />
                    </button>
                  </span>
                ))}
              </div>
            )}
          </Card>
          <div className="space-y-4">
            <Card>
              <CardHeader title="Formato" />
              <div className="grid grid-cols-[1fr_110px] gap-3">
                <Input label="Título" value={title} onChange={(e) => setTitle(e.target.value.toUpperCase())} maxLength={20} placeholder="CORREDOR" />
                <Input
                  label="Cópias de cada"
                  type="number"
                  min={1}
                  max={50}
                  value={copies}
                  onChange={(e) => setCopies(Math.min(50, Math.max(1, Number(e.target.value) || 1)))}
                />
              </div>
              <p className="mt-2 text-xs text-slate-500">Deixe o título vazio para imprimir só o código.</p>
            </Card>
            <Card>
              <CardHeader title="Digitar ou colar" />
              <Textarea
                label="Códigos (um por linha, ou separados por vírgula)"
                value={paste}
                onChange={(e) => setPaste(e.target.value)}
                rows={3}
                placeholder={'A01\nB02\nC01'}
              />
              <Button
                className="mt-2"
                variant="secondary"
                icon={<ListPlus className="h-4 w-4" />}
                onClick={() => {
                  addCodes(parseCodes(paste));
                  setPaste('');
                }}
              >
                Adicionar à lista
              </Button>
            </Card>
            <Card>
              <CardHeader title="Gerar sequência" subtitle="Ex.: letras A até C, números 1 até 10 → A01…C10" />
              <div className="grid grid-cols-2 gap-3">
                <Input label="Letra inicial" value={seq.fromLetter} maxLength={1} onChange={(e) => setSeq({ ...seq, fromLetter: e.target.value.toUpperCase() })} />
                <Input label="Letra final" value={seq.toLetter} maxLength={1} onChange={(e) => setSeq({ ...seq, toLetter: e.target.value.toUpperCase() })} />
                <Input label="Número inicial" type="number" min={0} value={seq.fromNum} onChange={(e) => setSeq({ ...seq, fromNum: e.target.value })} />
                <Input label="Número final" type="number" min={0} value={seq.toNum} onChange={(e) => setSeq({ ...seq, toNum: e.target.value })} />
                <Input label="Dígitos" type="number" min={1} max={4} value={seq.digits} onChange={(e) => setSeq({ ...seq, digits: e.target.value })} />
              </div>
              <Button className="mt-3" variant="secondary" icon={<ListPlus className="h-4 w-4" />} onClick={addSequence}>
                Gerar e adicionar
              </Button>
            </Card>
          </div>
        </div>
        {labels.length > MAX && (
          <div className="mt-4">
            <Alert tone="warning">São {fmtInt(labels.length)} etiquetas. Imprima no máximo {fmtInt(MAX)} por vez.</Alert>
          </div>
        )}
        {labels.length > 0 && <h3 className="mb-2 mt-6 text-sm font-semibold text-slate-700">Pré-visualização</h3>}
      </div>

      <div className="corridor-sheet flex flex-wrap gap-[3mm] print:block print:gap-0">
        {labels.map(({ code, n }, idx) => (
          <div
            key={`${code}-${n}`}
            style={{ width: W, height: H }}
            className={
              'flex flex-col items-center justify-center overflow-hidden rounded-sm border border-slate-400 bg-white p-[1mm] text-black print:rounded-none print:border-0' +
              (idx < labels.length - 1 ? ' print:[break-after:page]' : '')
            }
          >
            {title.trim() && <div className="text-[9pt] font-bold uppercase tracking-[2px]">{title.trim()}</div>}
            <div className="whitespace-nowrap font-black leading-[0.95]" style={{ fontSize: codeFont(code), fontFamily: 'Arial, Helvetica, sans-serif' }}>
              {code}
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}
