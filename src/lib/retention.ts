/** Anos civis em UTC para registros locais; 29/02 ajusta ao último dia de fevereiro. */
export function createdRetentionUntil(createdAt: string): string | null {
  const date = new Date(createdAt);
  if (!Number.isFinite(date.getTime())) return null;
  const month = date.getUTCMonth();
  date.setUTCFullYear(date.getUTCFullYear() + 10);
  if (date.getUTCMonth() !== month) date.setUTCDate(0);
  return date.toISOString();
}

export function canReviewLocalRetention(createdAt: string, now = Date.now()): boolean {
  const until = createdRetentionUntil(createdAt);
  return until !== null && new Date(until).getTime() <= now;
}
