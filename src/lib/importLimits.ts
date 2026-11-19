/** Limites técnicos conservadores. Não são prazos de retenção ou política jurídica. */
export const MAX_IMPORT_ROWS = 5001; // cabeçalho + até 5000 registros (limite da RPC de funcionários)
export const MAX_IMPORT_COLUMNS = 100;
export function validateImportMatrix(matrix: unknown[][]): void {
  if (matrix.length > MAX_IMPORT_ROWS) throw new Error('A planilha deve ter no máximo 5000 registros.');
  let cells = 0;
  for (const row of matrix) {
    cells += row.length;
    if (row.length > MAX_IMPORT_COLUMNS || cells > 100000) throw new Error('Planilha com células ou colunas em excesso.');
    if (row.some((v) => typeof v === 'string' && v.length > 5000)) throw new Error('Uma célula excede o limite de 5000 caracteres.');
  }
}
/** Examina a estrutura ZIP antes de entregar o XLSX ao ExcelJS. Rejeita ZIP64 e criptografia. */
export function validateXlsxArchive(buffer: ArrayBuffer): void {
  const view = new DataView(buffer);
  const bad = () => new Error('Arquivo XLSX inválido ou acima do limite de expansão (25 MB).');
  if (view.byteLength < 22 || view.getUint32(0, true) !== 0x04034b50) throw bad();
  let end = -1;
  for (let i = view.byteLength - 22; i >= Math.max(0, view.byteLength - 65557); i--) {
    if (view.getUint32(i, true) === 0x06054b50 && i + 22 + view.getUint16(i + 20,true) === view.byteLength) { end = i; break; }
  }
  if (end < 0 || view.getUint16(end+4,true) !== 0 || view.getUint16(end+6,true) !== 0) throw bad();
  const count = view.getUint16(end+10,true);
  let pos = view.getUint32(end+16,true);
  const directoryEnd = pos + view.getUint32(end+12,true);
  if (count > 1000 || directoryEnd !== end) throw bad();
  let total = 0;
  for (let n=0;n<count;n++) {
    if (pos+46 > end || view.getUint32(pos,true) !== 0x02014b50 || (view.getUint16(pos+8,true)&1)) throw bad();
    const expanded = view.getUint32(pos+24,true);
    total += expanded;
    if (total > 25*1024*1024 || expanded === 0xffffffff) throw bad();
    pos += 46 + view.getUint16(pos+28,true) + view.getUint16(pos+30,true) + view.getUint16(pos+32,true);
    if (pos > end) throw bad();
  }
  if (pos !== end) throw bad();
}
