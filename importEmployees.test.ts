import { describe, expect, it } from 'vitest';
import { employeeMatrixToRows } from './importEmployees';

describe('importação de funcionários', () => {
  it('reconhece cabeçalhos de RH abaixo do título e converte situação', () => {
    const rows = employeeMatrixToRows([
      ['Relação de colaboradores'],
      ['Chapa', 'Colaborador', 'Função', 'Departamento', 'Situação'],
      [1001, 'José Carlos da Silva', 'Mecânico', 'Manutenção', 'Ativo'],
      ['1002', 'Maria Santos', '', '', 'Desligado'],
      ['', '', '', '', ''],
    ]);
    expect(rows).toEqual([
      { registration: '1001', full_name: 'José Carlos da Silva', job_title: 'Mecânico', sector: 'Manutenção', active: true },
      { registration: '1002', full_name: 'Maria Santos', job_title: '', sector: '', active: false },
    ]);
  });
  it('exige matrícula e nome', () => {
    expect(() => employeeMatrixToRows([['Nome', 'Cargo'], ['A', 'B']])).toThrow(/matricula/);
  });
});
