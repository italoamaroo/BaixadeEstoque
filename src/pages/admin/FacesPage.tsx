import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { toast } from 'sonner';
import { Camera, FolderOpen, ScanFace, ShieldCheck, Trash2 } from 'lucide-react';
import { Button } from '@/components/ui/Button';
import { Alert, Card, CardHeader, EmptyState, PageHeader } from '@/components/ui/Card';
import { Input } from '@/components/ui/Field';
import { Modal } from '@/components/ui/Modal';
import { PageLoader } from '@/components/ui/Spinner';
import { EmployeePicker } from '@/components/EmployeePicker';
import { FaceScanner } from '@/components/FaceScanner';
import { useAuth } from '@/contexts/AuthContext';
import { faceEnroll, faceEnrollBulk, faceRemove, getFaceOverview, updateFaceSettings, withRetry, type FaceBulkResult, type FaceOverview } from '@/lib/api';
import { errorMessage } from '@/lib/errors';
import { groupPhotosByCpf, maskCpf, readCpfSheet } from '@/lib/faceImport';
import { loadFaceApi, readFaceFromFile } from '@/lib/face';
import { fmtDateTime, fmtInt } from '@/lib/format';
import type { Employee } from '@/types/db';

/** Cadastro de rostos para o balcão: liga/desliga, importação da base de fotos e cadastro pela câmera. */
export function FacesPage() {
  const { hasRole } = useAuth();
  const [data, setData] = useState<FaceOverview | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [search, setSearch] = useState('');
  const [cameraOpen, setCameraOpen] = useState(false);
  const [removing, setRemoving] = useState<FaceOverview['faces'][number] | null>(null);

  const load = useCallback(async () => {
    try {
      setData(await getFaceOverview());
      setError(null);
    } catch (e) {
      setError(errorMessage(e));
    }
  }, []);
  useEffect(() => {
    void load();
  }, [load]);

  const list = useMemo(() => {
    const t = search.trim().toLowerCase();
    return (data?.faces ?? []).filter((f) => !t || f.full_name.toLowerCase().includes(t) || f.registration.toLowerCase().includes(t));
  }, [data, search]);

  if (!data && !error) return <PageLoader label="Carregando…" />;

  return (
    <div className="space-y-4">
      <PageHeader
        title="Reconhecimento facial"
        subtitle="Rostos usados no balcão para identificar quem retira e confirmar a retirada. O sistema guarda só uma representação numérica do rosto, sem foto e sem CPF."
        actions={
          <Button icon={<Camera className="h-4 w-4" />} onClick={() => setCameraOpen(true)}>
            Cadastrar pela câmera
          </Button>
        }
      />
      {error && <Alert tone="error">{error}</Alert>}
      {data && (
        <>
          <div className="grid gap-4 lg:grid-cols-2">
            <SettingsCard data={data} isAdmin={hasRole('admin')} onSaved={load} />
            <Card>
              <CardHeader title="Situação" />
              <p className="text-3xl font-bold text-slate-900">
                {fmtInt(data.com_rosto)} <span className="text-lg font-medium text-slate-500">de {fmtInt(data.ativos)} funcionários ativos com rosto</span>
              </p>
              <p className="mt-2 text-sm text-slate-600">
                Quem não tem rosto cadastrado continua sendo atendido normalmente: o almoxarife identifica pela matrícula e a confirmação é por foto e
                assinatura. O rosto é apagado automaticamente quando o funcionário é inativado.
              </p>
            </Card>
          </div>
          <ImportCard onDone={load} />
          <Card padded={false}>
            <div className="flex flex-wrap items-center justify-between gap-3 border-b border-slate-100 p-4">
              <h2 className="font-semibold text-slate-900">Funcionários com rosto cadastrado</h2>
              <div className="w-full max-w-xs">
                <Input label="Pesquisar" value={search} onChange={(e) => setSearch(e.target.value)} placeholder="Nome ou matrícula" />
              </div>
            </div>
            {list.length === 0 ? (
              <EmptyState icon={<ScanFace className="h-10 w-10" />} title="Nenhum rosto cadastrado" description="Importe a base de fotos ou cadastre pela câmera." />
            ) : (
              <div className="overflow-x-auto">
                <table className="w-full text-sm">
                  <thead className="bg-slate-50 text-left text-xs uppercase text-slate-500">
                    <tr>
                      <th className="px-4 py-2">Funcionário</th>
                      <th className="px-4 py-2">Leituras</th>
                      <th className="px-4 py-2">Origem</th>
                      <th className="px-4 py-2">Cadastrado em</th>
                      <th className="px-4 py-2" />
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-slate-100">
                    {list.map((f) => (
                      <tr key={f.employee_id}>
                        <td className="px-4 py-2">
                          <p className="font-medium text-slate-900">{f.full_name}</p>
                          <p className="font-mono text-xs text-slate-500">{f.registration}</p>
                        </td>
                        <td className="px-4 py-2">{f.modelos}</td>
                        <td className="px-4 py-2">{f.origem === 'camera' ? 'Câmera' : f.origem === 'importacao' ? 'Base de fotos' : f.origem}</td>
                        <td className="px-4 py-2">{fmtDateTime(f.cadastrado_em)}</td>
                        <td className="px-4 py-2 text-right">
                          <Button variant="ghost" size="sm" icon={<Trash2 className="h-4 w-4" />} onClick={() => setRemoving(f)}>
                            Remover
                          </Button>
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </Card>
        </>
      )}
      <CameraEnroll open={cameraOpen} onClose={() => setCameraOpen(false)} onDone={load} />
      <Modal
        open={Boolean(removing)}
        onClose={() => setRemoving(null)}
        title="Remover o rosto cadastrado?"
        description={removing ? `${removing.full_name} (${removing.registration})` : ''}
        footer={
          <>
            <Button variant="secondary" onClick={() => setRemoving(null)}>
              Voltar
            </Button>
            <Button
              variant="danger"
              onClick={async () => {
                if (!removing) return;
                try {
                  await faceRemove(removing.employee_id);
                  toast.success('Rosto removido.');
                  setRemoving(null);
                  void load();
                } catch (e) {
                  toast.error(errorMessage(e));
                }
              }}
            >
              Remover
            </Button>
          </>
        }
      >
        <p className="text-sm text-slate-600">O funcionário passa a ser identificado pela matrícula, com foto e assinatura, até cadastrar o rosto de novo.</p>
      </Modal>
    </div>
  );
}

function SettingsCard({ data, isAdmin, onSaved }: { data: FaceOverview; isAdmin: boolean; onSaved: () => void }) {
  const [enabled, setEnabled] = useState(data.settings.enabled);
  const [threshold, setThreshold] = useState(Number(data.settings.threshold));
  const [saving, setSaving] = useState(false);
  const minSim = Math.round((1 - threshold) * 100);
  const changed = enabled !== data.settings.enabled || threshold !== Number(data.settings.threshold);
  return (
    <Card>
      <CardHeader title="Uso no balcão" subtitle={isAdmin ? undefined : 'Só o administrador altera.'} />
      <div className="space-y-4">
        <label className="flex items-center gap-3">
          <input type="checkbox" className="h-5 w-5" checked={enabled} disabled={!isAdmin} onChange={(e) => setEnabled(e.target.checked)} />
          <span className="font-medium text-slate-800">Reconhecimento facial ligado no balcão</span>
        </label>
        <div>
          <label htmlFor="face-rigor" className="text-sm font-medium text-slate-700">
            Rigor: semelhança mínima de {minSim}% {threshold <= 0.45 ? '(rigoroso)' : threshold >= 0.56 ? '(tolerante)' : '(normal)'}
          </label>
          <input
            id="face-rigor"
            type="range"
            min={0.4}
            max={0.6}
            step={0.01}
            value={threshold}
            disabled={!isAdmin}
            onChange={(e) => setThreshold(Number(e.target.value))}
            className="mt-1 w-full"
          />
          <p className="text-xs text-slate-500">Mais rigoroso erra menos para o lado da pessoa errada, mas recusa a pessoa certa com mais frequência. Use 50% para começar.</p>
        </div>
        {isAdmin && (
          <Button
            icon={<ShieldCheck className="h-4 w-4" />}
            disabled={!changed}
            loading={saving}
            onClick={async () => {
              setSaving(true);
              try {
                await updateFaceSettings({ enabled, threshold });
                toast.success('Configuração salva.');
                onSaved();
              } catch (e) {
                toast.error(errorMessage(e));
              } finally {
                setSaving(false);
              }
            }}
          >
            Salvar
          </Button>
        )}
      </div>
    </Card>
  );
}

type FileWithPath = File & { webkitRelativePath?: string };

function ImportCard({ onDone }: { onDone: () => void }) {
  const [photos, setPhotos] = useState<Map<string, File[]> | null>(null);
  const [sheet, setSheet] = useState<{ map: Map<string, string>; cpfHeader: string; regHeader: string; name: string } | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [running, setRunning] = useState(false);
  const [progress, setProgress] = useState<{ done: number; total: number; started: number } | null>(null);
  const [report, setReport] = useState<{ result: FaceBulkResult; semMatricula: string[]; semRosto: string[] } | null>(null);
  const cancel = useRef(false);

  const onFolder = (files: FileList | null) => {
    setReport(null);
    setErr(null);
    if (!files?.length) return;
    const list = [...files] as FileWithPath[];
    const byPath = new Map(list.map((f) => [f.webkitRelativePath || f.name, f]));
    const groups = groupPhotosByCpf(list.map((f) => ({ name: f.name, path: f.webkitRelativePath || f.name })));
    const out = new Map<string, File[]>();
    for (const [cpf, paths] of groups) out.set(cpf, paths.map((p) => byPath.get(p)!).filter(Boolean));
    if (!out.size) {
      setErr('Não achei pastas com CPF (11 números) nessa pasta. Escolha a pasta principal, a que contém as pastas dos CPFs.');
      setPhotos(null);
      return;
    }
    setPhotos(out);
  };

  const onSheet = async (f: File | undefined) => {
    setReport(null);
    setErr(null);
    if (!f) return;
    try {
      setSheet({ ...(await readCpfSheet(f)), name: f.name });
    } catch (e) {
      setSheet(null);
      setErr(errorMessage(e));
    }
  };

  const linked = photos && sheet ? [...photos.keys()].filter((c) => sheet.map.has(c)) : [];
  const semMatricula = photos && sheet ? [...photos.keys()].filter((c) => !sheet.map.has(c)) : [];

  const run = async () => {
    if (!photos || !sheet || running) return;
    setRunning(true);
    setErr(null);
    setReport(null);
    cancel.current = false;
    const total: FaceBulkResult = { cadastrados: 0, modelos: 0, nao_encontrados: [], inativos: [], invalidos: [] };
    const semRosto: string[] = [];
    try {
      await loadFaceApi();
      setProgress({ done: 0, total: linked.length, started: Date.now() });
      let batch: { registration: string; descriptors: number[][] }[] = [];
      const flush = async () => {
        if (!batch.length) return;
        const r = await withRetry(() => faceEnrollBulk(batch));
        total.cadastrados += r.cadastrados;
        total.modelos += r.modelos;
        total.nao_encontrados.push(...r.nao_encontrados);
        total.inativos.push(...r.inativos);
        total.invalidos.push(...r.invalidos);
        batch = [];
      };
      for (let i = 0; i < linked.length; i++) {
        if (cancel.current) break;
        const cpf = linked[i];
        const descriptors: number[][] = [];
        for (const f of photos.get(cpf) ?? []) {
          const r = await readFaceFromFile(f).catch(() => null);
          if (r && r.score >= 0.6) descriptors.push(r.descriptor);
        }
        if (descriptors.length) batch.push({ registration: sheet.map.get(cpf)!, descriptors });
        else semRosto.push(sheet.map.get(cpf)!);
        if (batch.length >= 20) await flush();
        setProgress((p) => (p ? { ...p, done: i + 1 } : p));
      }
      await flush();
      setReport({ result: total, semMatricula, semRosto });
      toast.success(`${fmtInt(total.cadastrados)} funcionário(s) com rosto cadastrado.`);
      onDone();
    } catch (e) {
      setErr(`${errorMessage(e)} Os que já foram enviados ficaram cadastrados; pode rodar de novo.`);
      if (total.cadastrados) onDone();
    } finally {
      setRunning(false);
    }
  };

  const eta = (() => {
    if (!progress || progress.done < 2) return '';
    const per = (Date.now() - progress.started) / progress.done;
    const left = Math.round(((progress.total - progress.done) * per) / 60000);
    return left >= 1 ? ` · faltam cerca de ${left} min` : ' · menos de 1 min';
  })();

  return (
    <Card>
      <CardHeader
        title="Importar a base de fotos"
        subtitle="Escolha a pasta principal (com uma pasta por CPF e as subpastas 1 a 5) e a planilha com CPF e matrícula. As fotos são lidas neste computador; nenhuma foto e nenhum CPF são enviados."
      />
      <div className="grid gap-3 sm:grid-cols-2">
        <label className="flex cursor-pointer items-center gap-3 rounded-lg border-2 border-dashed border-slate-300 p-4 hover:border-brand-400">
          <FolderOpen className="h-8 w-8 text-amber-500" />
          <span className="text-sm">
            <span className="font-semibold text-brand-700">1. Escolher a pasta das fotos</span>
            <span className="block text-slate-500">{photos ? `${fmtInt(photos.size)} pessoa(s) encontradas` : 'pasta principal'}</span>
          </span>
          <input
            type="file"
            className="hidden"
            multiple
            disabled={running}
            data-testid="face-folder"
            // @ts-expect-error atributo de seleção de pasta (Chrome/Edge)
            webkitdirectory=""
            onChange={(e) => onFolder(e.target.files)}
          />
        </label>
        <label className="flex cursor-pointer items-center gap-3 rounded-lg border-2 border-dashed border-slate-300 p-4 hover:border-brand-400">
          <ScanFace className="h-8 w-8 text-emerald-600" />
          <span className="text-sm">
            <span className="font-semibold text-brand-700">2. Escolher a planilha (CPF e matrícula)</span>
            <span className="block text-slate-500">
              {sheet ? `${sheet.name}: colunas “${sheet.cpfHeader}” e “${sheet.regHeader}”, ${fmtInt(sheet.map.size)} linha(s)` : '.xlsx ou .csv'}
            </span>
          </span>
          <input type="file" className="hidden" accept=".xlsx,.csv" disabled={running} data-testid="face-sheet" onChange={(e) => void onSheet(e.target.files?.[0])} />
        </label>
      </div>
      {err && (
        <div className="mt-3">
          <Alert tone="error">{err}</Alert>
        </div>
      )}
      {photos && sheet && !report && (
        <div className="mt-3 space-y-2 text-sm">
          <p>
            <strong>{fmtInt(linked.length)}</strong> pessoa(s) ligadas a uma matrícula
            {semMatricula.length > 0 && (
              <span className="text-amber-700">
                {' '}
                · {fmtInt(semMatricula.length)} CPF(s) da pasta não estão na planilha ({semMatricula.slice(0, 5).map(maskCpf).join(', ')}
                {semMatricula.length > 5 ? '…' : ''})
              </span>
            )}
          </p>
          {progress && (
            <div>
              <div className="h-2 overflow-hidden rounded-full bg-slate-200">
                <div className="h-full bg-brand-600 transition-all" style={{ width: `${(progress.done / Math.max(1, progress.total)) * 100}%` }} />
              </div>
              <p className="mt-1 text-slate-600">
                Lendo {fmtInt(progress.done)} de {fmtInt(progress.total)}
                {eta}. Deixe esta tela aberta.
              </p>
            </div>
          )}
          <div className="flex gap-2">
            <Button icon={<ScanFace className="h-4 w-4" />} loading={running} disabled={!linked.length} onClick={() => void run()}>
              Ler as fotos e cadastrar
            </Button>
            {running && (
              <Button variant="secondary" onClick={() => (cancel.current = true)}>
                Parar
              </Button>
            )}
          </div>
        </div>
      )}
      {report && (
        <div className="mt-3 space-y-2">
          <Alert tone="success" title={`${fmtInt(report.result.cadastrados)} funcionário(s) cadastrados (${fmtInt(report.result.modelos)} leituras)`}>
            Pode conferir na lista abaixo.
          </Alert>
          {(report.semRosto.length > 0 || report.result.nao_encontrados.length > 0 || report.result.inativos.length > 0 || report.semMatricula.length > 0) && (
            <Alert tone="warning" title="Ficaram de fora">
              <ul className="list-disc space-y-1 pl-5 text-sm">
                {report.semRosto.length > 0 && <li>Foto sem rosto aproveitável (matrículas): {report.semRosto.join(', ')}. Cadastre pela câmera.</li>}
                {report.result.nao_encontrados.length > 0 && <li>Matrícula não cadastrada no sistema: {report.result.nao_encontrados.join(', ')}.</li>}
                {report.result.inativos.length > 0 && <li>Funcionário inativo: {report.result.inativos.join(', ')}.</li>}
                {report.semMatricula.length > 0 && <li>{fmtInt(report.semMatricula.length)} CPF(s) da pasta sem linha na planilha.</li>}
              </ul>
            </Alert>
          )}
        </div>
      )}
    </Card>
  );
}

function CameraEnroll({ open, onClose, onDone }: { open: boolean; onClose: () => void; onDone: () => void }) {
  const [emp, setEmp] = useState<Employee | null>(null);
  const [scanning, setScanning] = useState(false);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  useEffect(() => {
    if (open) {
      setEmp(null);
      setScanning(false);
      setErr(null);
    }
  }, [open]);
  return (
    <Modal open={open} onClose={onClose} busy={busy} size="lg" title="Cadastrar rosto pela câmera" description="O funcionário olha para a câmera e vira o rosto devagar. Nenhuma foto é guardada.">
      <div className="space-y-4">
        <EmployeePicker label="Funcionário" value={emp} onChange={(e) => (setEmp(e), setScanning(false), setErr(null))} />
        {emp && !scanning && (
          <Button icon={<Camera className="h-4 w-4" />} onClick={() => setScanning(true)}>
            Abrir a câmera
          </Button>
        )}
        {emp && scanning && (
          <FaceScanner
            samplesNeeded={4}
            onResult={async (r) => {
              setBusy(true);
              setErr(null);
              try {
                await faceEnroll(emp.id, r.samples, 'camera');
                toast.success(`Rosto de ${emp.full_name} cadastrado.`);
                onDone();
                onClose();
              } catch (e) {
                setErr(errorMessage(e));
                setScanning(false);
              } finally {
                setBusy(false);
              }
            }}
          />
        )}
        {err && <Alert tone="error">{err}</Alert>}
      </div>
    </Modal>
  );
}
