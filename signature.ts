export function dataUrlToBlob(dataUrl: string): Blob {
  const [header, base64] = dataUrl.split(',');
  const mime = /data:([^;]+);/.exec(header)?.[1] ?? 'image/png';
  const bin = atob(base64);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return new Blob([bytes], { type: mime });
}

/**
 * Caminho no bucket "assinaturas": {ESTOQUE}/{ANO}/{ID_DA_ME}/assinatura_{timestamp}.png
 * O nome com timestamp garante arquivo único (inclusive em substituições).
 */
export function buildSignaturePath(
  warehouseCode: string,
  movementId: string,
  timeZone = 'America/Recife',
  date = new Date(),
): string {
  // O ano segue o fuso configurado no sistema (o banco valida o mesmo ano).
  let year = date.getFullYear();
  try {
    year = Number(new Intl.DateTimeFormat('en-US', { timeZone, year: 'numeric' }).format(date));
  } catch {
    /* fuso inválido: usa o ano local */
  }
  const stamp = date.toISOString().replace(/[-:.TZ]/g, '').slice(0, 14);
  return `${warehouseCode}/${year}/${movementId}/assinatura_${stamp}.png`;
}

/** Percentual de pixels pintados (para rejeitar assinatura vazia ou só um ponto). */
export function inkRatio(canvas: HTMLCanvasElement): number {
  const ctx = canvas.getContext('2d');
  if (!ctx || canvas.width === 0 || canvas.height === 0) return 0;
  const { data } = ctx.getImageData(0, 0, canvas.width, canvas.height);
  let painted = 0;
  for (let i = 3; i < data.length; i += 4) if (data[i] > 0) painted++;
  return painted / (canvas.width * canvas.height);
}
