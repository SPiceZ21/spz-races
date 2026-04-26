/** @jsx h */
const { h, Fragment } = preact;
const { useRef, useEffect } = preactHooks;

function Icon({ name, size = 14, strokeWidth = 1.75, ...rest }) {
  const ref = useRef(null);
  useEffect(() => {
    if (window.lucide && ref.current) window.lucide.createIcons({ nameAttr: 'data-lucide', icons: window.lucide.icons, attrs: {}, });
  }, [name]);
  return (
    <i
      ref={ref}
      data-lucide={name}
      style={{ width: size, height: size, display: 'inline-flex', strokeWidth }}
      {...rest}
    />
  );
}

function Card({ children, className = '', ...rest }) {
  return <div className={`spz-card ${className}`} {...rest}>{children}</div>;
}

function CardHeader({ title, desc, children }) {
  return (
    <div className="spz-card-header">
      <div>
        {title && <h3 className="spz-card-title">{title}</h3>}
        {desc && <div className="spz-card-desc">{desc}</div>}
      </div>
      {children}
    </div>
  );
}

function Button({ variant = 'default', size = 'default', children, ...rest }) {
  return (
    <button className="spz-btn" data-variant={variant} data-size={size} {...rest}>
      {children}
    </button>
  );
}

function Input(props) { return <input className="spz-input" {...props} />; }

function Badge({ variant, children, ...rest }) {
  return <span className="spz-badge" data-variant={variant} {...rest}>{children}</span>;
}

function Kbd({ children }) { return <span className="spz-kbd">{children}</span>; }

window.Card = Card;
window.CardHeader = CardHeader;
window.Button = Button;
window.Input = Input;
window.Badge = Badge;
window.Kbd = Kbd;
window.Icon = Icon;
