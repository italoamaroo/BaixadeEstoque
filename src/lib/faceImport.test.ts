import { describe, expect, it } from 'vitest';
import { cpfMapFromMatrix, groupPhotosByCpf, maskCpf, normalizeCpf } from './faceImport';

describe('importação da base de fotos', () => {
  it('agrupa as fotos pela pasta do CPF (com subpastas 1 a 5)', () => {
    const g = groupPhotosByCpf([
      { name: 'a.jpg', path: 'Fotos/00201955407/1/0f22.jpg' },
      { name: 'b.JPG', path: 'Fotos/00201955407/2/9a1b.JPG' },
      { name: 'c.png', path: 'Fotos/002.019.804-36/1/x.png' },
      { name: 'Thumbs.db', path: 'Fotos/00201955407/1/Thumbs.db' },
      { name: 'z.jpg', path: 'Fotos/outros/z.jpg' },
    ]);
    expect([...g.keys()].sort()).toEqual(['00201955407', '00201980436']);
    expect(g.get('00201955407')).toHaveLength(2);
  });
  it('limita a 5 fotos por pessoa', () => {
    const files = Array.from({ length: 7 }, (_, i) => ({ name: `${i}.jpg`, path: `R/12345678901/${i}/f.jpg` }));
    expect(groupPhotosByCpf(files).get('12345678901')).toHaveLength(5);
  });
  it('lê CPF e matrícula da planilha, recuperando zeros à esquerda', () => {
    const r = cpfMapFromMatrix([
      ['Relação de funcionários'],
      ['Nome', 'Matrícula', 'Função', 'CPF'],
      ['JOSÉ', '1001', 'MECÂNICO', 201955407],
      ['ANA', ' 1002 ', 'AUXILIAR', '002.019.804-36'],
    ]);
    expect(r.map.get('00201955407')).toBe('1001');
    expect(r.map.get('00201980436')).toBe('1002');
    expect(r.cpfHeader).toBe('CPF');
  });
  it('avisa quando faltam as colunas', () => {
    expect(() => cpfMapFromMatrix([['Nome', 'CPF']])).toThrow(/CPF e de matrícula/);
  });
  it('normaliza e mascara o CPF', () => {
    expect(normalizeCpf('201.955.407')).toBe('00201955407');
    expect(normalizeCpf('123456789012')).toBeNull();
    expect(maskCpf('00201955407')).toBe('***.***.554-07');
  });
});
