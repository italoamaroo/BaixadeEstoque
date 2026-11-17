import { MovementsPage } from './MovementsPage';

/** Mesmo fluxo de consulta, sempre limitado às MEs emergenciais. */
export function EmergencyMovementsPage() {
  return <MovementsPage emergencyOnly />;
}
