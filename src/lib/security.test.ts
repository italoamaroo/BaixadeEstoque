import { afterEach, describe, expect, it, vi } from 'vitest';
import { clearSessionDrafts, saveDraft, emptyDraft } from './draft';
import { validateImportMatrix, validateXlsxArchive } from './importLimits';

vi.mock('./api', () => ({ createMovement: vi.fn(), uploadSignature: vi.fn() }));
vi.mock('./offlineDb', () => ({ queueAll: vi.fn(), queueDel: vi.fn(), queuePut: vi.fn() }));
import { listQueued } from './offlineQueue';
import { queueAll } from './offlineDb';

afterEach(() => { sessionStorage.clear(); vi.clearAllMocks(); });
describe('proteção local e importações', () => {
  it('não consulta nem revela a fila quando não há usuário autenticado', async () => {
    expect(await listQueued(null)).toEqual([]); expect(queueAll).not.toHaveBeenCalled();
  });
  it('filtra a fila pela conta atual', async () => {
    vi.mocked(queueAll).mockResolvedValue([{ user_id: 'a', saved_at: '2026-11-19' }, { user_id: 'b', saved_at: '2026-11-19' }]);
    expect(await listQueued('a')).toHaveLength(1);
    expect((await listQueued('a'))[0].user_id).toBe('a');
  });
  it('remove rascunhos e duplicação, preservando outras preferências da sessão', () => {
    // Usa a API pública do rascunho para não espelhar o prefixo interno.
    saveDraft('usuario-a', emptyDraft());
    saveDraft('usuario-b', emptyDraft());
    sessionStorage.setItem('baixas-estoque:duplicar', 'assinatura');
    sessionStorage.setItem('preferencia', 'manter');
    clearSessionDrafts();
    expect(sessionStorage.getItem('baixas-estoque:duplicar')).toBeNull();
    expect(Object.keys(sessionStorage)).toEqual(['preferencia']);
  });
  it('rejeita excesso de registros, colunas e conteúdo', () => {
    expect(() => validateImportMatrix(Array.from({ length: 5002 }, () => []))).toThrow(/5000/);
    expect(() => validateImportMatrix([Array(101).fill('x')])).toThrow(/excesso/);
    expect(() => validateImportMatrix([['x'.repeat(5001)]])).toThrow(/caracteres/);
  });
  it('rejeita arquivo que não seja ZIP antes de carregar ExcelJS', () => {
    expect(() => validateXlsxArchive(new ArrayBuffer(30))).toThrow(/XLSX/);
  });
  it('aceita XLSX real dentro dos limites e rejeita expansão declarada excessiva', async () => {
    const ExcelJS = (await import('exceljs')).default;
    const workbook = new ExcelJS.Workbook(); workbook.addWorksheet('Teste').addRow(['codigo','nome']);
    const raw = new Uint8Array(await workbook.xlsx.writeBuffer());
    const buffer = raw.slice().buffer;
    expect(() => validateXlsxArchive(buffer)).not.toThrow();
    const v = new DataView(buffer);
    for (let i=0;i<buffer.byteLength-46;i++) if (v.getUint32(i,true) === 0x02014b50) { v.setUint32(i+24,30*1024*1024,true); break; }
    expect(() => validateXlsxArchive(buffer)).toThrow(/expansão/);
  });
});
