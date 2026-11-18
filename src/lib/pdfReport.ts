import { supabase, SIGNATURE_BUCKET } from './supabase';
import { searchMovements } from './api';
import { toAppError } from './errors';
import { STATUS_LABELS } from './constants';
import { fmtDateTime, fmtQty } from './format';
import type { MovementFilters } from './filters';
import type { MovementItem, MovementRow, SignatureRecord } from '@/types/db';

export const PDF_LIMIT = 500;

export interface PdfMovement {
  movement: MovementRow;
  items: MovementItem[];
  signature: SignatureRecord | null;
  signatureDataUrl: string | null;
}

export type Progress = (msg: string) => void;

function chunk<T>(arr: T[], size: number): T[][] {
  const out: T[][] = [];
  for (let i = 0; i < arr.length; i += size) out.push(arr.slice(i, i + size));
  return out;
}

async function blobToDataUrl(blob: Blob): Promise<string> {
  return new Promise((resolve, reject) => {
    const r = new FileReader();
    r.onload = () => resolve(String(r.result));
    r.onerror = () => reject(r.error);
    r.readAsDataURL(blob);
  });
}

/** Busca MEs (mesmos filtros da tela), itens e assinatura atual de cada uma. */
export async function fetchPdfData(filters: Partial<MovementFilters>, onProgress: Progress = () => undefined) {
  const movements: MovementRow[] = [];
  let total = 0;
  for (let page = 1; movements.length < PDF_LIMIT; page++) {
    onProgress(`Buscando MEs (${movements.length})…`);
    const r = await searchMovements(filters, page, 200, 'movement_at', 'asc');
    total = r.total;
    movements.push(...r.rows);
    if (r.rows.length < 200) break;
  }
  const list = movements.slice(0, PDF_LIMIT);
  const ids = list.map((m) => m.id);

  const items = new Map<string, MovementItem[]>();
  const sigs = new Map<string, SignatureRecord>();
  for (const part of chunk(ids, 100)) {
    onProgress(`Buscando itens e assinaturas (${items.size}/${ids.length})…`);
    const [it, sg] = await Promise.all([
      supabase.from('stock_movement_items').select('*').in('movement_id', part).order('line_number'),
      supabase.from('signatures').select('*').in('movement_id', part).eq('is_current', true),
    ]);
    if (it.error) throw toAppError(it.error);
    if (sg.error) throw toAppError(sg.error);
    for (const row of (it.data ?? []) as MovementItem[]) {
      const l = items.get(row.movement_id) ?? [];
      l.push(row);
      items.set(row.movement_id, l);
    }
    for (const row of (sg.data ?? []) as SignatureRecord[]) sigs.set(row.movement_id, row);
  }

  // Imagens das assinaturas (bucket privado → URLs assinadas de curta duração)
  const images = new Map<string, string>();
  const withSig = [...sigs.values()];
  let done = 0;
  for (const part of chunk(withSig, 50)) {
    const { data, error } = await supabase.storage.from(SIGNATURE_BUCKET).createSignedUrls(
      part.map((s) => s.storage_path),
      600,
    );
    if (error) throw toAppError(error);
    const urls = new Map((data ?? []).filter((d) => d.signedUrl).map((d) => [d.path, d.signedUrl as string]));
    for (const group of chunk(part, 6)) {
      await Promise.all(
        group.map(async (s) => {
          const url = urls.get(s.storage_path);
          if (!url) return;
          try {
            const res = await fetch(url);
            if (res.ok) images.set(s.movement_id, await blobToDataUrl(await res.blob()));
          } catch {
            /* assinatura indisponível: o PDF indica a ausência */
          }
        }),
      );
      done += group.length;
      onProgress(`Carregando assinaturas (${done}/${withSig.length})…`);
    }
  }

  const rows: PdfMovement[] = list.map((m) => ({
    movement: m,
    items: items.get(m.id) ?? [],
    signature: sigs.get(m.id) ?? null,
    signatureDataUrl: images.get(m.id) ?? null,
  }));
  return { rows, total, truncated: total > list.length };
}

/** Mantém texto compatível com a fonte padrão do PDF. */
function clean(v: string): string {
  return v.replace(/²/g, '2').replace(/³/g, '3').replace(/[\u2018\u2019]/g, "'").replace(/[\u201C\u201D]/g, '"');
}

/** Logo do consórcio (public/logo-consorcio.png) como data URL; sem logo, o relatório sai sem ela. */
async function loadLogo(): Promise<string | null> {
  try {
    const r = await fetch(`${import.meta.env.BASE_URL ?? '/'}logo-consorcio.png`.replace('//', '/'));
    if (!r.ok || !(r.headers.get('content-type') ?? '').includes('image')) return null;
    const b = await r.blob();
    return await new Promise((res) => {
      const fr = new FileReader();
      fr.onload = () => res(typeof fr.result === 'string' ? fr.result : null);
      fr.onerror = () => res(null);
      fr.readAsDataURL(b);
    });
  } catch {
    return null;
  }
}

/** Formulário oficial, sem capa: uma ME por página, com continuação para itens longos. */
export async function buildMovementsPdf(
  data: PdfMovement[],
  _opts: { filterLines: string[]; generatedBy: string; companyName: string; total: number; truncated: boolean },
): Promise<Blob> {
  const { jsPDF } = await import('jspdf');
  const { autoTable } = await import('jspdf-autotable');
  const doc = new jsPDF({ unit: 'mm', format: 'a4', orientation: 'portrait' });
  const logo = await loadLogo();
  const M = 7;
  const width = 196;
  const third = width / 3;
  const generatedAt = fmtDateTime(new Date());
  doc.setLineWidth(0.2);
  doc.setDrawColor(0);
  doc.setTextColor(0);

  // Desenha campos com rótulo pequeno e conteúdo quebrado dentro da célula.
  const field = (x: number, y: number, w: number, h: number, label: string, value: string) => {
    doc.rect(x, y, w, h);
    doc.setFont('helvetica', 'normal');
    doc.setFontSize(6);
    doc.text(label, x + 1.5, y + 3);
    doc.setFontSize(8);
    doc.text(doc.splitTextToSize(clean(value), w - 3), x + 1.5, y + 7);
  };

  for (const [index, { movement: m, items, signature, signatureDataUrl }] of data.entries()) {
    if (index) doc.addPage();
    const y = 6;
    doc.rect(M, y, 55, 30);
    if (logo) {
      const props = doc.getImageProperties(logo);
      const scale = Math.min(49 / props.width, 22 / props.height);
      doc.addImage(logo, props.fileType, M + 2, y + 1, props.width * scale, props.height * scale);
    }
    doc.setFontSize(7);
    doc.text(doc.splitTextToSize(`Almoxarifado ${m.warehouse_name}`, 51), M + 2, y + 27);
    doc.rect(M + 55, y, 67, 30);
    doc.setFont('helvetica', 'bold');
    doc.setFontSize(13);
    doc.text(['MOVIMENTAÇÃO DE', 'ESTOQUE'], M + 88.5, y + 7, { align: 'center', lineHeightFactor: 1.5 });
    field(M + 122, y, 32, 30, 'TIPO', `[${m.movement_type === 'saida' ? 'X' : ' '}] SAÍDA\n[${m.movement_type === 'entrada' ? 'X' : ' '}] ENTRADA`);
    field(M + 154, y, 42, 30, 'ME Nº', m.me_number);
    doc.setFontSize(6);
    doc.text('DATA', M + 155.5, y + 13);
    doc.setFontSize(8);
    doc.text(fmtDateTime(m.movement_at), M + 155.5, y + 17);

    field(M, 36, third, 10, 'CONTRATO', `${m.contract_code} - ${m.contract_name}`);
    field(M + third, 36, third, 10, 'SETOR', m.sector_name);
    field(M + third * 2, 36, third, 10, 'FRENTE DE SERVIÇO / EQUIPAMENTO', m.service_front_name ?? '--');
    field(M, 46, third, 10, 'ORDEM DE SERVIÇO', m.service_order ?? '');
    field(M + third, 46, third, 10, 'ATIVO FIXO (AF)', m.fixed_asset ?? '');
    field(M + third * 2, 46, third, 10, 'LOCAL APLICAÇÃO', m.application_location ?? '-');

    const rows = items.map((i) => [
      String(i.line_number),
      [i.material_reference, i.material_code].filter(Boolean).join('\n'),
      i.notes ? `${i.material_name}\nObs.: ${i.notes}` : i.material_name,
      i.unit, fmtQty(i.quantity_requested), fmtQty(i.quantity_delivered), i.location ?? '', i.account_code ?? '',
    ].map(clean));
    while (rows.length < 8) rows.push(Array(8).fill(''));
    autoTable(doc, {
      startY: 56,
      theme: 'grid',
      head: [['ITEM', 'REFERÊNCIA', 'NOME DO MATERIAL', 'UNID.', 'QTD. SOL.', 'QTD. ATD.', 'LOCALIZ.', 'CONTA']],
      body: rows,
      styles: { font: 'helvetica', fontSize: 7, cellPadding: 1, minCellHeight: 5.5, lineWidth: 0.2, lineColor: 0, textColor: 0, overflow: 'linebreak' },
      headStyles: { fillColor: 255, textColor: 0, fontSize: 6, halign: 'center', fontStyle: 'bold' },
      columnStyles: { 0: { cellWidth: 15, halign: 'center' }, 1: { cellWidth: 29 }, 2: { cellWidth: 44 }, 3: { cellWidth: 16, halign: 'center' }, 4: { cellWidth: 25, halign: 'right' }, 5: { cellWidth: 24, halign: 'right' }, 6: { cellWidth: 24 }, 7: { cellWidth: 19 } },
      margin: { left: M, right: M, top: 10, bottom: 12 },
      rowPageBreak: 'avoid',
    });
    let bottom = (doc as unknown as { lastAutoTable: { finalY: number } }).lastAutoTable.finalY;
    const notes = m.notes ? doc.splitTextToSize(clean(`Observações: ${m.notes}`), width) : [];
    const cancelled = m.status === 'cancelada'
      ? doc.splitTextToSize(clean(`CANCELADA em ${fmtDateTime(m.cancelled_at)} por ${m.cancelled_by_name ?? '-'}: ${m.cancel_reason ?? ''}`), width) : [];
    if (bottom + 49 + (notes.length + cancelled.length) * 4 > 285) {
      doc.addPage();
      bottom = 10;
      doc.setFontSize(8);
      doc.text(`${m.me_number} - continuação`, M, 7);
    }
    field(M, bottom, third, 31, 'REQUISITANTE / DATA', `${m.requester_name}\n(${m.requester_registration})\n${fmtDateTime(m.requested_at)}`);
    field(M + third, bottom, third, 31, 'APROVADO / DATA', m.approved_by_name
      ? `${m.approved_by_name}\n${fmtDateTime(m.approved_at)}`
      : `Baixa: ${m.storekeeper_name ?? ''}\n${fmtDateTime(m.created_at)}`);
    const sx = M + third * 2;
    field(sx, bottom, third, 31, 'RECEBIDO / DATA', '');
    if (signatureDataUrl) {
      try {
        const props = doc.getImageProperties(signatureDataUrl);
        const scale = Math.min((third - 4) / props.width, 14 / props.height);
        const w = props.width * scale;
        doc.addImage(signatureDataUrl, props.fileType, sx + (third - w) / 2, bottom + 4, w, props.height * scale);
      } catch {
        doc.setFontSize(6);
        doc.text('Imagem da assinatura indisponível', sx + 2, bottom + 12);
      }
    } else if (signature) {
      doc.setFontSize(6);
      doc.text('Imagem da assinatura indisponível', sx + 2, bottom + 12);
    }
    doc.line(sx + 2, bottom + 20, sx + third - 2, bottom + 20);
    doc.setFontSize(7);
    const receiver = `${signature?.signer_name ?? m.received_by_name ?? ''}\n(${signature?.signer_registration ?? m.received_by_registration ?? ''}) - ${fmtDateTime(signature?.signed_at ?? m.received_at)}`;
    doc.text(doc.splitTextToSize(clean(receiver), third - 4), sx + 2, bottom + 24);
    bottom += 36;
    doc.setFontSize(7);
    doc.text(`Status: ${STATUS_LABELS[m.status]}`, M, bottom);
    doc.text(m.is_emergency ? 'ME EMERGENCIAL (só controle)' : `SA: ${m.sa_number ?? 'pendente'}`, M + width, bottom, { align: 'right' });
    for (const line of [...notes, ...cancelled]) {
      bottom += 4;
      if (bottom > 278) {
        doc.addPage();
        bottom = 14;
        doc.setFontSize(7);
        doc.text(`${m.me_number} - continuação`, M, 7);
      }
      doc.text(line, M, bottom);
    }
    doc.setFontSize(6);
    doc.text(`Documento gerado eletronicamente em ${generatedAt}. Identificador: ${m.id}`, M, bottom + 6);
  }
  return doc.output('blob');
}
