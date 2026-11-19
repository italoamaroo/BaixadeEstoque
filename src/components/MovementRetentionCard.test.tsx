import { act } from 'react';
import { createRoot, type Root } from 'react-dom/client';
import { beforeEach, afterEach, describe, it, expect, vi } from 'vitest';
import { MovementRetentionCard } from './MovementRetentionCard';
const m = vi.hoisted(() => ({ status: vi.fn(), summary: vi.fn() }));
vi.mock('@/lib/api', () => ({ getMovementRetention: m.status, getMovementRetentionSummary: m.summary }));
let root: Root; let node: HTMLDivElement;
beforeEach(() => { vi.stubGlobal('IS_REACT_ACT_ENVIRONMENT',true); node=document.createElement('div'); root=createRoot(node); m.status.mockReset(); m.summary.mockReset(); });
afterEach(async () => { await act(async () => root.unmount()); vi.unstubAllGlobals(); });
describe('consulta da guarda de MEs',()=>{
  it('apresenta a regra somente após consultá-la no banco',async()=>{
    m.summary.mockResolvedValue({years:10,retained:3,review_due:1,awaiting_closure:2,missing_date:0,next_review_at:null});
    await act(async()=>root.render(<MovementRetentionCard />));
    expect(node.textContent).toContain('10 anos'); expect(node.textContent).toContain('Em guarda: 3'); expect(node.textContent).toContain('Sem exclusão automática');
  });
  it('não apresenta uma falsa política aplicada quando falta a migração',async()=>{
    m.summary.mockRejectedValue(new Error('PGRST202: function not found'));
    await act(async()=>root.render(<MovementRetentionCard />));
    expect(node.textContent).toContain('migração 28'); expect(node.textContent).not.toContain('10 anos');
  });
  it('mostra ME encerrada sem data como pendência de qualidade, sem inventar prazo',async()=>{
    m.status.mockResolvedValue({movement_id:'me1',years:10,basis_event:'conclusao',started_at:null,retain_until:null,state:'data_de_encerramento_ausente'});
    await act(async()=>root.render(<MovementRetentionCard movementId="me1" />));
    expect(node.textContent).toContain('não possui data de encerramento'); expect(m.status).toHaveBeenCalledWith('me1');
  });
});
