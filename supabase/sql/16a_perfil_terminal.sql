-- =====================================================================
-- 16a - PERFIL "TERMINAL" (tablet do solicitante no balcão)
-- Execute ESTE arquivo primeiro, sozinho, e depois o 16b.
-- (O PostgreSQL exige que o novo valor seja gravado antes de ser usado.)
-- =====================================================================
alter type public.app_role add value if not exists 'terminal';
