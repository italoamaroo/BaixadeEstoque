import { forwardRef, useId, type InputHTMLAttributes, type ReactNode, type SelectHTMLAttributes, type TextareaHTMLAttributes } from 'react';
import clsx from 'clsx';

const base =
  'block w-full rounded-lg border-0 bg-white px-3 text-slate-900 shadow-sm ring-1 ring-inset placeholder:text-slate-400 focus:ring-2 focus:ring-inset focus:ring-brand-600 disabled:cursor-not-allowed disabled:bg-slate-50 disabled:text-slate-500';

function ring(error?: string | null) {
  return error ? 'ring-red-400' : 'ring-slate-300';
}

interface FieldWrapProps {
  label?: ReactNode;
  hint?: ReactNode;
  error?: string | null;
  required?: boolean;
  id: string;
  children: ReactNode;
  className?: string;
}

export function FieldWrap({ label, hint, error, required, id, children, className }: FieldWrapProps) {
  return (
    <div className={clsx('space-y-1.5', className)}>
      {label && (
        <label htmlFor={id} className="block text-sm font-medium text-slate-700">
          {label}
          {required && <span className="ml-0.5 text-red-600" aria-hidden="true">*</span>}
        </label>
      )}
      {children}
      {error ? (
        <p id={`${id}-err`} className="text-sm text-red-600" role="alert">
          {error}
        </p>
      ) : hint ? (
        <p className="text-xs text-slate-500">{hint}</p>
      ) : null}
    </div>
  );
}

type Common = { label?: ReactNode; hint?: ReactNode; error?: string | null; wrapClassName?: string; inputSize?: 'md' | 'lg' };

export const Input = forwardRef<HTMLInputElement, InputHTMLAttributes<HTMLInputElement> & Common>(function Input(
  { label, hint, error, wrapClassName, className, id, required, inputSize = 'md', ...rest },
  ref,
) {
  const auto = useId();
  const fid = id ?? auto;
  return (
    <FieldWrap label={label} hint={hint} error={error} required={required} id={fid} className={wrapClassName}>
      <input
        ref={ref}
        id={fid}
        required={required}
        aria-invalid={error ? true : undefined}
        aria-describedby={error ? `${fid}-err` : undefined}
        className={clsx(base, ring(error), inputSize === 'lg' ? 'h-12 text-base' : 'h-10 text-sm', className)}
        {...rest}
      />
    </FieldWrap>
  );
});

export const Select = forwardRef<HTMLSelectElement, SelectHTMLAttributes<HTMLSelectElement> & Common>(function Select(
  { label, hint, error, wrapClassName, className, id, required, children, inputSize = 'md', ...rest },
  ref,
) {
  const auto = useId();
  const fid = id ?? auto;
  return (
    <FieldWrap label={label} hint={hint} error={error} required={required} id={fid} className={wrapClassName}>
      <select
        ref={ref}
        id={fid}
        required={required}
        aria-invalid={error ? true : undefined}
        className={clsx(base, ring(error), 'pr-8', inputSize === 'lg' ? 'h-12 text-base' : 'h-10 text-sm', className)}
        {...rest}
      >
        {children}
      </select>
    </FieldWrap>
  );
});

export const Textarea = forwardRef<HTMLTextAreaElement, TextareaHTMLAttributes<HTMLTextAreaElement> & Common>(function Textarea(
  { label, hint, error, wrapClassName, className, id, required, rows = 3, ...rest },
  ref,
) {
  const auto = useId();
  const fid = id ?? auto;
  return (
    <FieldWrap label={label} hint={hint} error={error} required={required} id={fid} className={wrapClassName}>
      <textarea
        ref={ref}
        id={fid}
        rows={rows}
        required={required}
        aria-invalid={error ? true : undefined}
        className={clsx(base, ring(error), 'py-2 text-sm', className)}
        {...rest}
      />
    </FieldWrap>
  );
});

export function Checkbox({
  label,
  checked,
  onChange,
  disabled,
  description,
}: {
  label: ReactNode;
  checked: boolean;
  onChange: (v: boolean) => void;
  disabled?: boolean;
  description?: ReactNode;
}) {
  const id = useId();
  return (
    <div className="flex items-start gap-3">
      <input
        id={id}
        type="checkbox"
        className="mt-0.5 h-5 w-5 rounded border-slate-300 text-brand-700 focus:ring-brand-600"
        checked={checked}
        disabled={disabled}
        onChange={(e) => onChange(e.target.checked)}
      />
      <label htmlFor={id} className="text-sm">
        <span className="font-medium text-slate-800">{label}</span>
        {description && <span className="block text-slate-500">{description}</span>}
      </label>
    </div>
  );
}
