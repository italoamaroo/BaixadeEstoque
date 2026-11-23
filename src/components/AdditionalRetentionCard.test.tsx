import { act } from 'react';
import { createRoot } from 'react-dom/client';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { AdditionalRetentionCard } from './AdditionalRetentionCard';
const m = vi.hoisted(() => ({ summary: vi.fn() }));
vi.mock('@/lib/api', () => ({ getAdditionalRetentionSummary: m.summary }));
let node: HTMLDivElement; let root: ReturnType<typeof createRoot>;
beforeEach(() => { vi.stubGlobal('IS_REACT_ACT_ENVIRONMENT', true); node=document.createElement('div'); root=createRoot(node); m.summary.mockReset(); });
afterEach(async () => { await act(async () => root.unmount()); vi.unstubAllGlobals(); });
describe('política adicional', () => {
  it('não afirma migração aplicada quando a função está ausente', async () => {
    m.summary.mockRejectedValue(new Error('PGRST202 function not found'));
    await act(async () => root.render(<AdditionalRetentionCard />));
    expect(node.textContent).toContain('migração 29');
    expect(node.textContent).not.toContain('10 anos desde a criação');
  });
  it('permite repetir consulta após falha sem recarregar o sistema', async () => {
    m.summary.mockRejectedValueOnce(new Error('Failed to fetch'));
    await act(async () => root.render(<AdditionalRetentionCard />));
    expect(node.textContent).toContain('Sem conexão');
    m.summary.mockResolvedValue({ years:10, categories:{} });
    await act(async () => node.querySelector('button')!.click());
    expect(m.summary).toHaveBeenCalledTimes(2);
    expect(node.textContent).toContain('10 anos desde a criação');
    expect(node.textContent).not.toContain('Sem conexão');
  });
  it('repete a consulta depois de uma nova verificação administrativa', async () => {
    m.summary.mockRejectedValueOnce(new Error('Failed to fetch'));
    await act(async () => root.render(<AdditionalRetentionCard refreshKey="primeira" />));
    m.summary.mockResolvedValue({ years:10, categories:{} });
    await act(async () => root.render(<AdditionalRetentionCard refreshKey="segunda" />));
    expect(m.summary).toHaveBeenCalledTimes(2);
    expect(node.textContent).toContain('10 anos desde a criação');
  });
  it('mostra contagens sem prometer disponibilidade dos backups', async () => {
    m.summary.mockResolvedValue({ years:10,categories:{cadastros_faciais:{total:3,review_due:1,next_review_at:null}} });
    await act(async () => root.render(<AdditionalRetentionCard />));
    expect(node.textContent).toContain('10 anos desde a criação');
    expect(node.textContent).toContain('não comprova que as cópias externas continuam disponíveis');
    expect(node.textContent).toContain('não participam do reconhecimento');
  });
});
