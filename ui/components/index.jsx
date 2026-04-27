/**
 * SPZ-UI  ·  Shared Preact Component Library  (CDN bundle)
 * ─────────────────────────────────────────────────────────
 * Include before your app script:
 *   <script type="text/babel" src="components/index.jsx"></script>
 *
 * Destructure from window in your app script:
 *   const { Icon, Card, Button, Badge, Kbd, Prompt, Avatar, Modal, … } = window;
 */
/** @jsx h */
const { h, Fragment, createContext } = preact;
const { useRef, useEffect, useState, useCallback, useContext } = preactHooks;

/* ── Key symbol map (matches spz-ui Prompt.tsx) ─────────────── */
const KEY_SYMBOLS = {
  CMD:'⌘', SHIFT:'⇧', ALT:'⌥', OPT:'⌥', CTRL:'⌃',
  TAB:'⇥', CAPS:'⇪', ESC:'⎋', DEL:'⌫', ENTER:'↵',
  UP:'↑', DOWN:'↓', LEFT:'←', RIGHT:'→', SPACE:'␣',
};

/* ╔═══════════════════════════════════════════════════════════╗
   ║  PRIMITIVES                                               ║
   ╚═══════════════════════════════════════════════════════════╝ */

/* ── Icon (Lucide CDN) ──────────────────────────────────────── */
function Icon({ name, size = 14, strokeWidth = 1.75, color, className = '', style: extraStyle = {}, ...rest }) {
  const ref = useRef(null);
  useEffect(() => {
    if (window.lucide && ref.current)
      window.lucide.createIcons({ nameAttr: 'data-lucide', icons: window.lucide.icons, attrs: {} });
  }, [name]);
  return (
    <i
      ref={ref}
      data-lucide={name}
      className={className}
      style={{ width: size, height: size, display: 'inline-flex', strokeWidth, color, ...extraStyle }}
      {...rest}
    />
  );
}

/* ── Card ───────────────────────────────────────────────────── */
function Card({ children, className = '', variant = '', ...rest }) {
  return (
    <div className={`spz-card ${variant} ${className}`.trim()} {...rest}>
      {children}
    </div>
  );
}

function CardHeader({ title, desc, children }) {
  return (
    <div className="spz-card-header">
      <div>
        {title && <h3 className="spz-card-title">{title}</h3>}
        {desc  && <div className="spz-card-desc">{desc}</div>}
      </div>
      {children}
    </div>
  );
}

/* ── Button ─────────────────────────────────────────────────── */
function Button({ variant = 'default', size = 'default', icon, iconRight, children, className = '', ...rest }) {
  return (
    <button
      className={`spz-btn ${className}`.trim()}
      data-variant={variant !== 'default' ? variant : undefined}
      data-size={size !== 'default' ? size : undefined}
      {...rest}
    >
      {icon      && <Icon name={icon} />}
      {children}
      {iconRight && <Icon name={iconRight} />}
    </button>
  );
}

/* ── Input / Textarea / Select ─────────────────────────────── */
function Input({ className = '', ...props }) {
  return <input className={`spz-input ${className}`.trim()} {...props} />;
}
function Textarea({ className = '', ...props }) {
  return <textarea className={`spz-textarea ${className}`.trim()} {...props} />;
}
function Select({ children, className = '', ...rest }) {
  return <select className={`spz-select ${className}`.trim()} {...rest}>{children}</select>;
}

/* ── Badge ──────────────────────────────────────────────────── */
function Badge({ variant, children, className = '', ...rest }) {
  return (
    <span className={`spz-badge ${className}`.trim()} data-variant={variant} {...rest}>
      {children}
    </span>
  );
}

/* ── Keyboard / Keycap / Prompt ─────────────────────────────── */
function Kbd({ children, ...rest }) {
  return <span className="spz-kbd" {...rest}>{children}</span>;
}

function Keycap({ keys, size = 'md', className = '' }) {
  const items = (Array.isArray(keys) ? keys : [keys]).map(k => {
    const upper = k.toUpperCase();
    return { display: KEY_SYMBOLS[upper] ?? k, isSymbol: !!KEY_SYMBOLS[upper] };
  });
  return (
    <div className={`spz-keycap-group ${className}`.trim()}>
      {items.map(({ display, isSymbol }, i) => (
        <Fragment key={i}>
          {i > 0 && <span className="spz-keycap-sep">+</span>}
          <kbd className={`spz-keycap ${isSymbol ? 'symbol' : ''} ${size}`.trim()}>
            {display}
          </kbd>
        </Fragment>
      ))}
    </div>
  );
}

function KbdGroup({ keys }) {
  return (
    <span className="spz-keycap-group">
      {keys.map((k, i) => (
        <Fragment key={i}>
          {i > 0 && <span className="spz-keycap-sep">+</span>}
          <Kbd>{k}</Kbd>
        </Fragment>
      ))}
    </span>
  );
}

function Prompt({ label, keys, className = '' }) {
  return (
    <div className={`spz-prompt ${className}`.trim()}>
      {keys && <Keycap keys={Array.isArray(keys) ? keys : [keys]} />}
      <span className="prompt-label">{label}</span>
    </div>
  );
}

/* ── Avatar ─────────────────────────────────────────────────── */
function Avatar({ name = '', initials: initProp, src, size = 28, ring = false, className = '' }) {
  const initials = initProp || (name.split(' ').map(n => n[0]).join('').toUpperCase().substring(0, 2) || '?');
  return (
    <span
      className={`spz-avatar ${ring ? 'spz-avatar-ring' : ''} ${className}`.trim()}
      style={{ width: size, height: size, fontSize: size <= 24 ? 10 : 11 }}
    >
      {src ? <img src={src} alt={name} /> : initials}
    </span>
  );
}

/* ── Separator / Spinner / ProgressBar ─────────────────────── */
function Separator({ className = '' }) {
  return <hr className={`spz-sep ${className}`.trim()} />;
}

function Spinner({ size = 'md', className = '' }) {
  return <div className={`spz-spinner ${size !== 'md' ? size : ''} ${className}`.trim()} />;
}

function ProgressBar({ value = 0, variant = '', label, className = '' }) {
  return (
    <div className={`flex flex-col gap-1 ${className}`.trim()}>
      {label && <span className="spz-stat-label">{label}</span>}
      <div className="spz-progress">
        <div className={`spz-progress-fill ${variant}`} style={{ width: `${Math.min(100, Math.max(0, value))}%` }} />
      </div>
    </div>
  );
}

/* ── StatItem ───────────────────────────────────────────────── */
function StatItem({ label, value, variant = '', className = '' }) {
  return (
    <div className={`flex flex-col ${className}`.trim()}>
      <span className="spz-stat-label">{label}</span>
      <span className={`spz-stat-val ${variant}`.trim()}>{value}</span>
    </div>
  );
}

/* ── Table ──────────────────────────────────────────────────── */
function Table({ children, className = '' }) {
  return <table className={`spz-table ${className}`.trim()}>{children}</table>;
}

/* ── Switch ─────────────────────────────────────────────────── */
function Switch({ checked, onChange, ...rest }) {
  const [_on, _set] = useState(!!checked);
  const on = checked !== undefined ? checked : _on;
  const toggle = () => {
    const next = !on;
    if (checked === undefined) _set(next);
    onChange?.(next);
  };
  return (
    <button
      role="switch"
      aria-checked={on}
      className="spz-switch"
      data-on={on ? 'true' : 'false'}
      onClick={toggle}
      {...rest}
    />
  );
}

/* ── Checkbox ───────────────────────────────────────────────── */
function Checkbox({ checked, onChange, label, ...rest }) {
  const [_on, _set] = useState(!!checked);
  const on = checked !== undefined ? checked : _on;
  const toggle = () => {
    const next = !on;
    if (checked === undefined) _set(next);
    onChange?.(next);
  };
  return (
    <label style={{ display: 'inline-flex', alignItems: 'center', gap: 8, cursor: 'pointer' }}>
      <span role="checkbox" aria-checked={on} className="spz-checkbox" data-on={on} onClick={toggle} {...rest} />
      {label && <span style={{ fontSize: 13, color: 'var(--text-secondary)' }}>{label}</span>}
    </label>
  );
}

/* ── Tabs ───────────────────────────────────────────────────── */
function Tabs({ value, onChange, items }) {
  const [_v, _set] = useState(items[0]?.value);
  const v = value !== undefined ? value : _v;
  return (
    <div className="spz-tabs">
      {items.map((it) => (
        <button
          key={it.value}
          className="spz-tab"
          data-active={v === it.value ? 'true' : 'false'}
          onClick={() => { if (value === undefined) _set(it.value); onChange?.(it.value); }}
        >
          {it.label}
        </button>
      ))}
    </div>
  );
}

/* ── Segment ────────────────────────────────────────────────── */
function Segment({ value, onChange, items }) {
  const [_v, _set] = useState(items[0]?.value);
  const v = value !== undefined ? value : _v;
  return (
    <div className="spz-segment">
      {items.map((it) => (
        <button
          key={it.value}
          className="spz-segment-item"
          data-active={v === it.value}
          onClick={() => { if (value === undefined) _set(it.value); onChange?.(it.value); }}
        >
          {it.label}
        </button>
      ))}
    </div>
  );
}

/* ── Tooltip ────────────────────────────────────────────────── */
function Tooltip({ label, children }) {
  const [show, setShow] = useState(false);
  return (
    <span
      style={{ position: 'relative', display: 'inline-flex' }}
      onMouseEnter={() => setShow(true)}
      onMouseLeave={() => setShow(false)}
    >
      {children}
      {show && (
        <span className="spz-tooltip" style={{ bottom: 'calc(100% + 6px)', left: '50%', transform: 'translateX(-50%)' }}>
          {label}
        </span>
      )}
    </span>
  );
}

/* ── Dropdown Menu ──────────────────────────────────────────── */
function DropdownMenu({ trigger, children }) {
  const [open, setOpen] = useState(false);
  const ref = useRef(null);
  useEffect(() => {
    const onDoc = (e) => { if (ref.current && !ref.current.contains(e.target)) setOpen(false); };
    document.addEventListener('mousedown', onDoc);
    return () => document.removeEventListener('mousedown', onDoc);
  }, []);
  return (
    <div ref={ref} style={{ position: 'relative', display: 'inline-block' }}>
      <span onClick={() => setOpen(o => !o)}>{trigger}</span>
      {open && (
        <div className="spz-popover" style={{ position: 'absolute', top: 'calc(100% + 4px)', right: 0, zIndex: 20 }}>
          {children}
        </div>
      )}
    </div>
  );
}
function MenuItem({ icon, shortcut, children, onClick }) {
  return (
    <div className="spz-menu-item" onClick={onClick}>
      {icon && <Icon name={icon} />}
      <span>{children}</span>
      {shortcut && <span className="spz-menu-item-shortcut">{shortcut}</span>}
    </div>
  );
}
function MenuLabel({ children }) { return <div className="spz-menu-label">{children}</div>; }
function MenuDivider() { return <div className="spz-menu-divider" />; }

/* ── Modal / Overlay ────────────────────────────────────────── */
function Modal({ isOpen, onClose, children, className = '' }) {
  useEffect(() => {
    if (!isOpen) return;
    const handler = (e) => { if (e.key === 'Escape') onClose?.(); };
    window.addEventListener('keydown', handler);
    return () => window.removeEventListener('keydown', handler);
  }, [isOpen]);
  if (!isOpen) return null;
  return (
    <div className="spz-overlay" onClick={onClose}>
      <div className={`spz-modal ${className}`.trim()} onClick={e => e.stopPropagation()}>
        {children}
      </div>
    </div>
  );
}

/* ── Alert ──────────────────────────────────────────────────── */
function Alert({ variant = 'info', icon, title, children }) {
  const defaultIcon = { info:'info', success:'check-circle-2', warn:'triangle-alert', danger:'octagon-alert' }[variant] || 'info';
  return (
    <div className="spz-alert" data-variant={variant}>
      <Icon name={icon || defaultIcon} size={16} />
      <div>
        {title    && <p className="spz-alert-title">{title}</p>}
        {children && <p className="spz-alert-desc">{children}</p>}
      </div>
    </div>
  );
}

/* ── Live dot / Status ──────────────────────────────────────── */
function Live({ color, children = 'Live' }) {
  return <span className="spz-live" data-color={color}>{children}</span>;
}

function StatusDot() {
  return <span className="spz-status-dot" />;
}
function StatusPill({ children }) {
  return <span className="spz-status-pill">{children}</span>;
}

/* ── Toast System ───────────────────────────────────────────── */
const ToastCtx = createContext(null);

function ToastProvider({ children }) {
  const [toasts, setToasts] = useState([]);
  const dismiss = useCallback((id) => {
    setToasts((arr) => arr.map(t => t.id === id ? { ...t, leaving: true } : t));
    setTimeout(() => setToasts((arr) => arr.filter(t => t.id !== id)), 220);
  }, []);
  const push = useCallback((toast) => {
    const id = Math.random().toString(36).slice(2);
    const dur = toast.duration ?? 4000;
    setToasts((arr) => [...arr, { id, ...toast, dur }]);
    if (dur > 0) setTimeout(() => dismiss(id), dur);
    return id;
  }, [dismiss]);
  return (
    <ToastCtx.Provider value={{ push, dismiss }}>
      {children}
      <div className="spz-toast-stack">
        {toasts.map((t) => <ToastItem key={t.id} {...t} onClose={() => dismiss(t.id)} />)}
      </div>
    </ToastCtx.Provider>
  );
}

function useToast() { return useContext(ToastCtx); }

function ToastItem({ variant = 'info', icon, title, description, onClose, dur, leaving }) {
  const defaultIcon = { info:'info', success:'check-circle-2', warn:'triangle-alert', danger:'octagon-alert' }[variant] || 'info';
  return (
    <div
      className="spz-toast"
      data-variant={variant}
      data-leaving={leaving ? 'true' : undefined}
      style={{ '--_dur': `${dur}ms` }}
    >
      <Icon name={icon || defaultIcon} size={16} />
      <div>
        {title       && <p className="spz-toast-title">{title}</p>}
        {description && <p className="spz-toast-desc">{description}</p>}
      </div>
      <button className="spz-toast-close" onClick={onClose} aria-label="Close">
        <Icon name="x" size={12} />
      </button>
      {dur > 0 && <span className="spz-toast-progress" />}
    </div>
  );
}

/* ── Telemetry Tile (motorsport stat) ───────────────────────── */
function TelemetryTile({ label, value, unit, delta }) {
  return (
    <div className="spz-card" style={{ padding: '12px 14px', display: 'flex', flexDirection: 'column', gap: 6, minWidth: 140 }}>
      <span className="spz-eyebrow">{label}</span>
      <div style={{ display: 'flex', alignItems: 'baseline', gap: 4 }}>
        <span className="spz-stat-val" style={{ fontSize: 22 }}>{value}</span>
        {unit && <span className="spz-stat-label" style={{ fontSize: 11, letterSpacing: '0.12em' }}>{unit}</span>}
      </div>
      {delta !== undefined && (
        <span className="spz-mono" style={{
          fontSize: 11,
          color: delta < 0 ? 'var(--color-success)' : delta > 0 ? 'var(--color-danger)' : 'var(--text-muted)',
        }}>
          {delta > 0 ? '+' : ''}{delta}
        </span>
      )}
    </div>
  );
}

/* ╔═══════════════════════════════════════════════════════════╗
   ║  WINDOW EXPORTS                                           ║
   ╚═══════════════════════════════════════════════════════════╝ */
Object.assign(window, {
  /* Layout */
  Card, CardHeader,
  /* Actions */
  Button, Input, Textarea, Select,
  /* Feedback */
  Badge, Spinner, ProgressBar, Alert, Live, StatusDot, StatusPill,
  /* Keyboard */
  Kbd, KbdGroup, Keycap, Prompt,
  /* Navigation */
  Tabs, Segment,
  /* Data */
  Table, StatItem, TelemetryTile, Avatar,
  /* Form controls */
  Switch, Checkbox,
  /* Overlays */
  Modal, Tooltip, DropdownMenu, MenuItem, MenuLabel, MenuDivider,
  /* Toast */
  ToastProvider, useToast, ToastItem,
  /* Utility */
  Separator,
  /* Core */
  Icon,
});
