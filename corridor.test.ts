import { describe, expect, it } from 'vitest';
import { buildSequence, parseCodes } from '@/pages/admin/CorridorLabels';

describe('etiquetas de corredor', () => {
  it('separa códigos colados', () => {
    expect(parseCodes('a01\nB02, c01;\tD03\n\n')).toEqual(['A01', 'B02', 'C01', 'D03']);
  });
  it('gera sequência letras × números', () => {
    expect(buildSequence('A', 'B', 1, 3, 2)).toEqual(['A01', 'A02', 'A03', 'B01', 'B02', 'B03']);
    expect(buildSequence('c', '', 9, 10, 3)).toEqual(['C009', 'C010']);
  });
});
