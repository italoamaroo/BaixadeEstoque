import { useCallback, useEffect, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { toast } from 'sonner';
import { Boxes, Download, Pencil, Plus, QrCode, RefreshCw, Search, Tags, Upload } from 'lucide-react';
import { Button } from '@/components/ui/Button';
import { ActiveBadge } from '@/components/ui/Badge';
import { Alert, EmptyState, PageHeader } from '@/components/ui/Card';
import { Checkbox, Input, Select, Textarea } from '@/components/ui/Field';
import { Modal } from '@/components/ui/Modal';
import { Pagination } from '@/components/ui/Pagination';
import { PageLoader } from '@/components/ui/Spinner';
import { QRCodeImage, qrDataUrl } from '@/components/QRCodeImage';
import { useLookups } from '@/hooks/useLookups';
import { useDebounce } from '@/hooks/useDebounce';
import { useAuth } from '@/contexts/AuthContext';
import { importMaterials, listMaterials, regenerateQr, saveMaterial } from '@/lib/api';
import { errorMessage } from '@/lib/errors';
import { fieldErrors, materialSchema, type MaterialForm } from '@/lib/validation';
import { parseImportFile, IMPORT_COLUMNS, downloadImportTemplate } from '@/lib/import';
import type { Material } from '@/types/db';

const emptyForm: MaterialForm = {
  code: '',
  reference: '',
  name: '',
  description: '',
  unit: 'UN',
  location: '',
  account_id: '',
  category_id: '',
  warehouse_id: '',
  qr_code: '',
  active: true,
};

export function MaterialsPage() {
  const navigate = useNavigate();
  const { warehouses } = useAuth();
  const { data: lk } = useLookups(['accounts', 'material_categories']);
  const [search, setSearch] = useState('');
  const term = useDebounce(search, 350);
  const [status, setStatus] = useState<'todos' | 'ativos' | 'inativos'>('ativos');
  const [page, setPage] = useState(1);
  const [pageSize, setPageSize] = useState(25);
  const [rows, setRows] = useState<Material[]>([]);
  const [total, setTotal] = useState(0);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [selected, setSelected] = useState<Set<string>>(new Set());

  const [editing, setEditing] = useState<Material | null | 'new'>(null);
  const [form, setForm] = useState<MaterialForm>(emptyForm);
  const [errors, setErrors] = useState<Record<string, string>>({});
  const [saving, setSaving] = useState(false);
  const [qrFor, setQrFor] = useState<Material | null>(null);
  const [importOpen, setImportOpen] = useState(false);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const r = await listMaterials({ search: term, status, page, pageSize });
      setRows(r.rows);
      setTotal(r.total);
      setError(null);
    } catch (err) {
      setError(errorMessage(err));
    } finally {
      setLoading(false);
    }
  }, [term, status, page, pageSize]);

  useEffect(() => {
    void load();
  }, [load]);
  useEffect(() => setPage(1), [term, status]);

  const openEdit = (m: Material | 'new') => {
    setEditing(m);
    setErrors({});
    setForm(
      m === 'new'
        ? emptyForm
        : {
            code: m.code,
            reference: m.reference ?? '',
            name: m.name,
            description: m.description ?? '',
            unit: m.unit,
            location: m.location ?? '',
            account_id: m.account_id ?? '',
            category_id: m.category_id ?? '',
            warehouse_id: m.warehouse_id ?? '',
            qr_code: m.qr_code,
            active: m.active,
          },
    );
  };

  const save = async () => {
    const r = materialSchema.safeParse(form);
    const errs = fieldErrors(r);
    setErrors(errs);
    if (Object.keys(errs).length) return;
    setSaving(true);
    try {
      const saved = await saveMaterial({ ...form, id: editing !== 'new' ? editing?.id : undefined } as Material);
      toast.success(editing === 'new' ? `Material ${saved.code} cadastrado com QR Code ${saved.qr_code}.` : 'Material atualizado.');
      setEditing(null);
      void load();
    } catch (err) {
      toast.error(errorMessage(err));
    } finally {
      setSaving(false);
    }
  };

  const toggleActive = async (m: Material) => {
    if (!window.confirm(m.active ? `Inativar "${m.name}"? Ele deixará de poder ser baixado.` : `Reativar "${m.name}"?`)) return;
    try {
      await saveMaterial({ ...m, active: !m.active });
      toast.success(m.active ? 'Material inativado.' : 'Material reativado.');
      void load();
    } catch (err) {
      toast.error(errorMessage(err));
    }
  };

  const toggleSel = (id: string) =>
    setSelected((s) => {
      const n = new Set(s);
      if (n.has(id)) n.delete(id);
      else n.add(id);
      return n;
    });

  const set = <K extends keyof MaterialForm>(k: K, v: MaterialForm[K]) => setForm((f) => ({ ...f, [k]: v }));

  return (
    <div>
      <PageHeader
        title="Materiais"
        subtitle="Cadastro mestre. O QR Code de cada material contém apenas o identificador; os dados são sempre consultados aqui."
        actions={
          <>
            <Button variant="secondary" icon={<Upload className="h-4 w-4" />} onClick={() => setImportOpen(true)}>
              Importar
            </Button>
            <Button
              variant="secondary"
              icon={<Tags className="h-4 w-4" />}
              disabled={selected.size === 0}
              onClick={() => navigate(`/cadastros/etiquetas?ids=${[...selected].join(',')}`)}
            >
              Etiquetas ({selected.size})
            </Button>
            <Button icon={<Plus className="h-4 w-4" />} onClick={() => openEdit('new')}>
              Novo material
            </Button>
          </>
        }
      />

      <div className="mb-4 flex flex-wrap gap-2">
        <div className="relative min-w-[240px] flex-1">
          <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-slate-400" />
          <input
            className="h-10 w-full rounded-lg border-0 pl-9 pr-3 text-sm ring-1 ring-inset ring-slate-300 focus:ring-2 focus:ring-brand-600"
            placeholder="Código, referência, nome, descrição ou QR"
            value={search}
            onChange={(e) => setSearch(e.target.value)}
          />
        </div>
        <select className="h-10 rounded-lg border-0 pl-3 pr-8 text-sm ring-1 ring-inset ring-slate-300" value={status} onChange={(e) => setStatus(e.target.value as typeof status)} aria-label="Situação">
          <option value="ativos">Ativos</option>
          <option value="inativos">Inativos</option>
          <option value="todos">Todos</option>
        </select>
      </div>

      <div className="rounded-xl border border-slate-200 bg-white shadow-card">
        {error && (
          <div className="p-4">
            <Alert tone="error">{error}</Alert>
          </div>
        )}
        {loading && rows.length === 0 ? (
          <PageLoader />
        ) : rows.length === 0 ? (
          <EmptyState icon={<Boxes className="h-10 w-10" />} title="Nenhum material encontrado" />
        ) : (
          <>
            <div className="overflow-x-auto">
              <table className="min-w-full divide-y divide-slate-200 text-sm">
                <thead className="bg-slate-50 text-xs font-semibold uppercase tracking-wide text-slate-500">
                  <tr>
                    <th className="w-10 px-3 py-2.5">
                      <input
                        type="checkbox"
                        aria-label="Selecionar todos"
                        checked={rows.every((r) => selected.has(r.id))}
                        onChange={(e) =>
                          setSelected((s) => {
                            const n = new Set(s);
                            rows.forEach((r) => (e.target.checked ? n.add(r.id) : n.delete(r.id)));
                            return n;
                          })
                        }
                      />
                    </th>
                    <th className="px-3 py-2.5 text-left">Código</th>
                    <th className="px-3 py-2.5 text-left">Material</th>
                    <th className="px-3 py-2.5 text-left">Unid.</th>
                    <th className="px-3 py-2.5 text-left">Localização</th>
                    <th className="px-3 py-2.5 text-left">Conta / categoria</th>
                    <th className="px-3 py-2.5 text-left">QR Code</th>
                    <th className="px-3 py-2.5 text-left">Situação</th>
                    <th className="px-3 py-2.5 text-right">Ações</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-slate-100">
                  {rows.map((m) => (
                    <tr key={m.id} className={m.active ? '' : 'bg-slate-50 text-slate-500'}>
                      <td className="px-3 py-2.5 text-center">
                        <input type="checkbox" checked={selected.has(m.id)} onChange={() => toggleSel(m.id)} aria-label={`Selecionar ${m.name}`} />
                      </td>
                      <td className="whitespace-nowrap px-3 py-2.5 font-mono text-xs">{m.code}</td>
                      <td className="px-3 py-2.5">
                        <span className="font-medium text-slate-900">{m.name}</span>
                        <span className="block text-xs text-slate-500">
                          {m.reference ? `Ref. ${m.reference}` : ''}
                          {m.warehouse_name ? ` · ${m.warehouse_name}` : ''}
                        </span>
                      </td>
                      <td className="px-3 py-2.5">{m.unit}</td>
                      <td className="px-3 py-2.5">{m.location ?? '—'}</td>
                      <td className="px-3 py-2.5 text-xs">
                        {m.account_code ?? '—'}
                        <span className="block text-slate-500">{m.category_name ?? ''}</span>
                      </td>
                      <td className="px-3 py-2.5">
                        <button type="button" onClick={() => setQrFor(m)} className="inline-flex items-center gap-1 whitespace-nowrap font-mono text-xs text-brand-700 hover:underline">
                          <QrCode className="h-4 w-4" /> {m.qr_code}
                        </button>
                      </td>
                      <td className="px-3 py-2.5">
                        <button type="button" onClick={() => void toggleActive(m)} title="Ativar/inativar">
                          <ActiveBadge active={m.active} />
                        </button>
                      </td>
                      <td className="px-3 py-2.5 text-right">
                        <Button size="sm" variant="ghost" icon={<Pencil className="h-4 w-4" />} onClick={() => openEdit(m)}>
                          Editar
                        </Button>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            <Pagination page={page} pageSize={pageSize} total={total} onPage={setPage} onPageSize={(s) => (setPageSize(s), setPage(1))} />
          </>
        )}
      </div>

      <Modal
        open={editing !== null}
        onClose={() => setEditing(null)}
        busy={saving}
        size="lg"
        title={editing === 'new' ? 'Novo material' : 'Editar material'}
        footer={
          <>
            <Button variant="secondary" onClick={() => setEditing(null)} disabled={saving}>
              Cancelar
            </Button>
            <Button onClick={() => void save()} loading={saving}>
              Salvar
            </Button>
          </>
        }
      >
        <div className="grid gap-4 sm:grid-cols-2">
          <Input label="Código do material" required value={form.code} onChange={(e) => set('code', e.target.value.toUpperCase())} error={errors.code} maxLength={40} />
          <Input label="Referência" value={form.reference} onChange={(e) => set('reference', e.target.value)} error={errors.reference} maxLength={80} />
          <Input label="Nome do material" required value={form.name} onChange={(e) => set('name', e.target.value)} error={errors.name} wrapClassName="sm:col-span-2" maxLength={200} />
          <Textarea label="Descrição complementar" value={form.description} onChange={(e) => set('description', e.target.value)} error={errors.description} wrapClassName="sm:col-span-2" rows={2} />
          <Input label="Unidade" required value={form.unit} onChange={(e) => set('unit', e.target.value.toUpperCase())} error={errors.unit} list="units" maxLength={10} />
          <datalist id="units">
            {['UN', 'PC', 'PAR', 'L', 'ML', 'KG', 'G', 'M', 'M²', 'CX', 'RL', 'GL', 'JG'].map((u) => (
              <option key={u} value={u} />
            ))}
          </datalist>
          <Input label="Localização" value={form.location} onChange={(e) => set('location', e.target.value.toUpperCase())} error={errors.location} placeholder="Ex.: A-01-03" maxLength={40} />
          <Select label="Conta" value={form.account_id} onChange={(e) => set('account_id', e.target.value)}>
            <option value="">Não informada</option>
            {(lk.accounts ?? []).map((a) => (
              <option key={a.id} value={a.id}>
                {a.code} – {a.name}
              </option>
            ))}
          </Select>
          <Select label="Categoria" value={form.category_id} onChange={(e) => set('category_id', e.target.value)}>
            <option value="">Não informada</option>
            {(lk.material_categories ?? []).map((a) => (
              <option key={a.id} value={a.id}>
                {a.name}
              </option>
            ))}
          </Select>
          <Select label="Estoque relacionado" value={form.warehouse_id} onChange={(e) => set('warehouse_id', e.target.value)} hint="Opcional: deixe em branco se o material existe nos dois estoques.">
            <option value="">Todos</option>
            {warehouses.map((w) => (
              <option key={w.id} value={w.id}>
                {w.name}
              </option>
            ))}
          </Select>
          <Input
            label="Código do QR Code"
            value={form.qr_code}
            onChange={(e) => set('qr_code', e.target.value.toUpperCase())}
            error={errors.qr_code}
            hint={editing === 'new' ? 'Deixe em branco para gerar automaticamente.' : 'Para trocar, use “Gerar novo QR Code”.'}
            disabled={editing !== 'new'}
          />
          <div className="sm:col-span-2">
            <Checkbox label="Material ativo" description="Materiais inativos não podem ser baixados." checked={form.active} onChange={(v) => set('active', v)} />
          </div>
        </div>
      </Modal>

      <QrModal material={qrFor} onClose={() => setQrFor(null)} onChanged={() => void load()} />
      <ImportModal open={importOpen} onClose={() => setImportOpen(false)} onDone={() => void load()} />
    </div>
  );
}

function QrModal({ material, onClose, onChanged }: { material: Material | null; onClose: () => void; onChanged: () => void }) {
  const [qr, setQr] = useState('');
  const [busy, setBusy] = useState(false);
  useEffect(() => setQr(material?.qr_code ?? ''), [material]);

  const download = async () => {
    const url = await qrDataUrl(qr, 800);
    const a = document.createElement('a');
    a.href = url;
    a.download = `qrcode_${material?.code ?? qr}.png`;
    a.click();
  };

  const regenerate = async () => {
    if (!material || !window.confirm('Gerar um novo QR Code? As etiquetas antigas deixarão de funcionar e precisarão ser reimpressas.')) return;
    setBusy(true);
    try {
      const v = await regenerateQr(material.id);
      setQr(v);
      toast.success('Novo QR Code gerado. Imprima a nova etiqueta.');
      onChanged();
    } catch (err) {
      toast.error(errorMessage(err));
    } finally {
      setBusy(false);
    }
  };

  return (
    <Modal
      open={Boolean(material)}
      onClose={onClose}
      title="QR Code do material"
      description={material ? `${material.code} · ${material.name}` : undefined}
      footer={
        <>
          <Button variant="ghost" icon={<RefreshCw className="h-4 w-4" />} loading={busy} onClick={() => void regenerate()}>
            Gerar novo QR Code
          </Button>
          <Button variant="secondary" icon={<Download className="h-4 w-4" />} onClick={() => void download()}>
            Baixar PNG
          </Button>
        </>
      }
    >
      {material && (
        <div className="flex flex-col items-center gap-3 py-2">
          <QRCodeImage value={qr} size={220} />
          <p className="font-mono text-sm">{qr}</p>
          <p className="text-center text-xs text-slate-500">O QR Code contém somente este identificador. Ao ler, o sistema busca os dados atualizados do material.</p>
        </div>
      )}
    </Modal>
  );
}

function ImportModal({ open, onClose, onDone }: { open: boolean; onClose: () => void; onDone: () => void }) {
  const [rows, setRows] = useState<Record<string, unknown>[] | null>(null);
  const [fileError, setFileError] = useState<string | null>(null);
  const [result, setResult] = useState<Awaited<ReturnType<typeof importMaterials>> | null>(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    if (open) {
      setRows(null);
      setFileError(null);
      setResult(null);
    }
  }, [open]);

  const onFile = async (f: File | undefined) => {
    if (!f) return;
    setFileError(null);
    setResult(null);
    try {
      const parsed = await parseImportFile(f);
      if (parsed.length === 0) throw new Error('Nenhuma linha encontrada no arquivo.');
      setRows(parsed);
    } catch (err) {
      setRows(null);
      setFileError((err as Error).message);
    }
  };

  const run = async () => {
    if (!rows) return;
    setBusy(true);
    try {
      const r = await importMaterials(rows);
      setResult(r);
      toast.success(`${r.inseridos} inserido(s), ${r.atualizados} atualizado(s).`);
      onDone();
    } catch (err) {
      setFileError(errorMessage(err));
    } finally {
      setBusy(false);
    }
  };

  return (
    <Modal
      open={open}
      onClose={onClose}
      busy={busy}
      size="lg"
      title="Importar materiais"
      description="Arquivo .xlsx ou .csv (separado por ; ou ,). Materiais com o mesmo código são atualizados."
      footer={
        <>
          <Button variant="ghost" icon={<Download className="h-4 w-4" />} onClick={() => void downloadImportTemplate()}>
            Baixar modelo
          </Button>
          <Button onClick={() => void run()} loading={busy} disabled={!rows || Boolean(result)}>
            Importar {rows ? `${rows.length} linha(s)` : ''}
          </Button>
        </>
      }
    >
      <div className="space-y-4">
        <p className="text-sm text-slate-600">
          Colunas aceitas: {IMPORT_COLUMNS.map((c) => <code key={c.key} className="mx-0.5 rounded bg-slate-100 px-1 text-xs">{c.header}</code>)}. Obrigatórias: código, nome e unidade.
        </p>
        <input type="file" accept=".xlsx,.csv,text/csv" onChange={(e) => void onFile(e.target.files?.[0])} className="block w-full text-sm" />
        {fileError && <Alert tone="error">{fileError}</Alert>}
        {rows && !result && (
          <div className="max-h-56 overflow-auto rounded border border-slate-200 text-xs">
            <table className="min-w-full">
              <thead className="bg-slate-50">
                <tr>
                  {IMPORT_COLUMNS.slice(0, 6).map((c) => (
                    <th key={c.key} className="px-2 py-1 text-left">
                      {c.header}
                    </th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {rows.slice(0, 20).map((r, i) => (
                  <tr key={i} className="border-t border-slate-100">
                    {IMPORT_COLUMNS.slice(0, 6).map((c) => (
                      <td key={c.key} className="px-2 py-1">
                        {String(r[c.key] ?? '')}
                      </td>
                    ))}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
        {result && (
          <Alert tone={result.erros.length ? 'warning' : 'success'} title={`${result.inseridos} inserido(s) · ${result.atualizados} atualizado(s) · ${result.erros.length} com erro`}>
            {result.erros.length > 0 && (
              <ul className="mt-1 max-h-40 list-disc overflow-auto pl-5">
                {result.erros.map((e) => (
                  <li key={e.linha}>
                    Linha {e.linha} ({e.codigo || 'sem código'}): {e.erro}
                  </li>
                ))}
              </ul>
            )}
          </Alert>
        )}
      </div>
    </Modal>
  );
}
