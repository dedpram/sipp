import type { ReactNode } from 'react';
import { cn } from '@/lib/cn';

export type BadgeTone = 'neutral' | 'waiting' | 'process' | 'success' | 'danger' | 'attention';

const tones: Record<BadgeTone, string> = {
  neutral: 'bg-slate-100 text-slate-700 ring-slate-200',
  waiting: 'bg-amber-50 text-amber-800 ring-amber-200',
  process: 'bg-sky-50 text-sky-800 ring-sky-200',
  success: 'bg-green-50 text-green-800 ring-green-200',
  danger: 'bg-red-50 text-red-700 ring-red-200',
  attention: 'bg-orange-50 text-orange-800 ring-orange-200',
};

export function Badge({ tone = 'neutral', children, className }: { tone?: BadgeTone; children: ReactNode; className?: string }) {
  return (
    <span
      className={cn(
        'inline-flex items-center whitespace-nowrap rounded-full px-2 py-0.5 text-xs font-medium ring-1 ring-inset',
        tones[tone],
        className,
      )}
    >
      {children}
    </span>
  );
}
