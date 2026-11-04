/** Sons curtos de confirmação para o balcão (Web Audio, sem arquivos). */
let ctx: AudioContext | null = null;

function audio(): AudioContext | null {
  try {
    if (!ctx) {
      const AC = window.AudioContext ?? (window as unknown as { webkitAudioContext?: typeof AudioContext }).webkitAudioContext;
      if (!AC) return null;
      ctx = new AC();
    }
    if (ctx.state === 'suspended') void ctx.resume();
    return ctx;
  } catch {
    return null;
  }
}

function tone(freq: number, start: number, duration: number, type: OscillatorType = 'sine', volume = 0.15) {
  const a = audio();
  if (!a) return;
  const osc = a.createOscillator();
  const gain = a.createGain();
  osc.type = type;
  osc.frequency.value = freq;
  gain.gain.value = volume;
  osc.connect(gain);
  gain.connect(a.destination);
  const t = a.currentTime + start;
  osc.start(t);
  gain.gain.setValueAtTime(volume, t);
  gain.gain.exponentialRampToValueAtTime(0.0001, t + duration);
  osc.stop(t + duration + 0.02);
}

export type FeedbackKind = 'ok' | 'warn' | 'error' | 'info';

export function playFeedback(kind: FeedbackKind) {
  if (kind === 'ok') tone(1046, 0, 0.12, 'sine');
  else if (kind === 'info') tone(784, 0, 0.1, 'sine', 0.1);
  else if (kind === 'warn') {
    tone(660, 0, 0.12, 'triangle');
    tone(660, 0.16, 0.12, 'triangle');
  } else {
    tone(220, 0, 0.35, 'square', 0.12);
  }
}
