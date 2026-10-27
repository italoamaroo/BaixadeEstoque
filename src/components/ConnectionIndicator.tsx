import { Wifi, WifiOff } from 'lucide-react';
import { useOnlineStatus } from '@/hooks/useOnlineStatus';

export function ConnectionBanner() {
  const online = useOnlineStatus();
  if (online) return null;
  return (
    <div className="sticky top-0 z-40 flex items-center justify-center gap-2 bg-red-600 px-4 py-2 text-sm font-medium text-white" role="alert">
      <WifiOff className="h-4 w-4" />
      Sem conexão. Os dados preenchidos ficam guardados; nada será confirmado até a internet voltar.
    </div>
  );
}

export function ConnectionDot() {
  const online = useOnlineStatus();
  return (
    <span className="inline-flex items-center gap-1.5 text-xs font-medium" title={online ? 'Conectado' : 'Sem conexão'}>
      {online ? <Wifi className="h-4 w-4 text-emerald-600" /> : <WifiOff className="h-4 w-4 text-red-600" />}
      <span className={online ? 'text-emerald-700' : 'text-red-700'}>{online ? 'Online' : 'Offline'}</span>
    </span>
  );
}
