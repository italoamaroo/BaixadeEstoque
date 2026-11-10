import { describe, expect, it } from 'vitest';
import { lookupMatrixToRows } from './importLookups';

describe('importação de cadastros auxiliares', () => {
  it('ativos fixos: coluna "Ativo" é o código e "Descrição" é o nome', () => {
    const rows = lookupMatrixToRows('fixed_assets', [
      ['Relatório de ativos'],
      ['Ativo', 'Descrição', 'Situação'],
      ['AF-01', 'Caminhão 01', 'Ativo'],
      ['AF-02', 'Pá carregadeira', 'Inativo'],
      ['', '', ''],
    ]);
    expect(rows).toEqual([
      { code: 'AF-01', name: 'Caminhão 01', active: true },
      { code: 'AF-02', name: 'Pá carregadeira', active: false },
    ]);
  });
  it('locais de aplicação com código e nome', () => {
    expect(lookupMatrixToRows('application_locations', [['codigo', 'nome'], ['LOC-1', 'Oficina']])).toEqual([{ code: 'LOC-1', name: 'Oficina' }]);
  });
  it('sem cabeçalho dá erro claro', () => {
    expect(() => lookupMatrixToRows('fixed_assets', [['x', 'y']])).toThrow(/Cabeçalho não encontrado/);
  });
});
