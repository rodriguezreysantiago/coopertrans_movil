// nucleo/system.jsx
// NÚCLEO design system — single source of truth for the Coopertrans refactor.
// All primitives consumed by Styleguide.html and the prototype live here.
//
// Exposes: window.NS (Núcleo System) with shape:
//   tokens.color.{dark,light}     — semantic palette per theme
//   tokens.type                   — display/heading/body/mono/eyebrow specs
//   tokens.space                  — 4-step scale (4 / 8 / 12 / 16 / 24 / 32 / 48)
//   tokens.radius                 — 4 / 6 / 8 / 12 / 999
//   tokens.shadow                 — none / glow(color)
//   useTheme(themeName)           — returns { t, theme }
//   <NThemeProvider theme>        — sets a CSS-var context (used inside artboards)
//   <NLogo size />                — wordmark + monogram
//   <NEyebrow color>              — small uppercase mono label
//   <NHairline />                 — 1px border line
//   <NButton kind size>           — primary | secondary | ghost
//   <NInput label value mono />   — text/dni field shell
//   <NCard padded glow>           — bento card surface
//   <NBadge color>                — pill
//   <NKpi label value unit delta />
//   <NStat big? />                — variant for hero numbers
//   <NSparkline data color />     — small inline svg
//   <NAreaChart data color />     — full bento chart
//   <NDot color glow />           — status indicator
//   <NTopbar />                   — desktop chrome
//   <NMobileFrame children />     — mobile shell (status bar + body)
//   <NAmbient color x y size intensity />
//   icons.{arrow,truck,person,file,bell,power,search,sparkle,alert,more,check,
//          calendar,settings,close,menu,chevronRight,chevronLeft,plus,download,
//          map,filter,clock,phone,whatsapp,mail,refresh,trend,gauge,wrench}
//
// Co-presented with: <NPostIt> via Design Canvas is OK, but inside individual
// HTML files we render straight against NThemeProvider.

(function () {
  const NS = {};

  // -------------------------------------------------------------------------
  // TOKENS
  // -------------------------------------------------------------------------
  const dark = {
    bg: '#050505',
    surface1: '#0a0a0b',
    surface2: '#0f0f10',
    surface3: '#16161a',
    surfaceHover: '#1d1d22',
    border: 'rgba(255,255,255,0.07)',
    borderStrong: 'rgba(255,255,255,0.14)',
    borderFocus: 'rgba(124,131,255,0.5)',
    text: '#fafafa',
    textSecondary: 'rgba(250,250,250,0.62)',
    textMuted: 'rgba(250,250,250,0.4)',
    textPlaceholder: 'rgba(250,250,250,0.28)',
    brand: '#7c83ff',
    brandSoft: '#a5acff',
    brandDark: '#5b62e0',
    brandFg: '#050505',
    brandGlow: 'rgba(124,131,255,0.20)',
    ok: '#4ade80',
    okSoft: 'rgba(74,222,128,0.16)',
    warn: '#fbbf24',
    warnSoft: 'rgba(251,191,36,0.16)',
    crit: '#fb7185',
    critSoft: 'rgba(251,113,133,0.16)',
    info: '#60a5fa',
    infoSoft: 'rgba(96,165,250,0.16)',
  };
  const light = {
    bg: '#fafafa',
    surface1: '#f4f4f5',
    surface2: '#ffffff',
    surface3: '#e9e9eb',
    surfaceHover: '#dededf',
    border: 'rgba(0,0,0,0.06)',
    borderStrong: 'rgba(0,0,0,0.12)',
    borderFocus: 'rgba(91,98,224,0.4)',
    text: '#0a0a0a',
    textSecondary: 'rgba(10,10,10,0.62)',
    textMuted: 'rgba(10,10,10,0.4)',
    textPlaceholder: 'rgba(10,10,10,0.28)',
    brand: '#5b62e0',
    brandSoft: '#7c83ff',
    brandDark: '#3f44b0',
    brandFg: '#ffffff',
    brandGlow: 'rgba(91,98,224,0.10)',
    ok: '#16a34a',
    okSoft: 'rgba(22,163,74,0.10)',
    warn: '#d97706',
    warnSoft: 'rgba(217,119,6,0.10)',
    crit: '#e11d48',
    critSoft: 'rgba(225,29,72,0.10)',
    info: '#2563eb',
    infoSoft: 'rgba(37,99,235,0.10)',
  };

  NS.tokens = {
    color: { dark, light },
    type: {
      fontDisplay: '"Geist", "Inter", system-ui, -apple-system, sans-serif',
      fontMono: '"Geist Mono", ui-monospace, "SF Mono", Menlo, monospace',
      sizes: {
        eyebrow: 10.5, label: 11, body: 13, bodyLg: 14.5,
        h6: 14, h5: 18, h4: 22, h3: 30, h2: 44, h1: 56, hero: 72, mega: 96,
      },
      weights: { regular: 400, medium: 500, semibold: 600 },
      tracking: { displayTight: '-0.04em', display: '-0.03em', body: 0, eyebrow: '0.06em', label: '0.04em' },
    },
    space: { px: 1, '0.5': 2, 1: 4, 1.5: 6, 2: 8, 2.5: 10, 3: 12, 4: 16, 5: 20, 6: 24, 8: 32, 10: 40, 12: 48 },
    radius: { xs: 4, sm: 6, md: 8, lg: 12, xl: 16, pill: 999 },
    shadow: {
      none: 'none',
      lift: (c) => `0 1px 2px rgba(0,0,0,0.18), 0 4px 12px rgba(0,0,0,0.12)`,
      glow: (c) => `0 0 0 1px ${c}30, 0 8px 32px ${c}40`,
    },
  };

  // -------------------------------------------------------------------------
  // useTheme hook
  // -------------------------------------------------------------------------
  NS.useTheme = function (name) {
    const t = name === 'light' ? light : dark;
    return { t, name: name === 'light' ? 'light' : 'dark' };
  };

  // -------------------------------------------------------------------------
  // ICONS — outline 1.5, round caps. Single source of truth.
  // -------------------------------------------------------------------------
  const ic = (path, fill) => (size, color) => (
    <svg width={size} height={size} viewBox="0 0 24 24" fill={fill ? color : 'none'} stroke={fill ? 'none' : color} strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round">{path}</svg>
  );

  NS.icons = {
    arrow: ic(<path d="M5 12h14M13 6l6 6-6 6"/>),
    arrowUp: ic(<path d="M7 17L17 7M9 7h8v8"/>),
    chevronRight: ic(<path d="M9 6l6 6-6 6"/>),
    chevronLeft: ic(<path d="M15 6l-6 6 6 6"/>),
    truck: ic(<g><rect x="1.5" y="6.5" width="12" height="10.5" rx="1"/><path d="M13.5 9.5h4.5l3 3.5v4h-7.5z"/><circle cx="6" cy="18.5" r="1.5"/><circle cx="18" cy="18.5" r="1.5"/></g>),
    person: ic(<g><circle cx="12" cy="8" r="4"/><path d="M4 21c0-4.4 3.6-8 8-8s8 3.6 8 8"/></g>),
    people: ic(<g><circle cx="9" cy="8" r="3.5"/><path d="M2 20c0-4 3.1-7 7-7s7 3 7 7"/><circle cx="17" cy="6" r="2.5"/><path d="M22 18c0-3.3-2.2-6-5-6"/></g>),
    file: ic(<g><path d="M5 3h9l5 5v13H5z"/><path d="M14 3v5h5"/></g>),
    files: ic(<g><path d="M7 5h8l4 4v12H7z"/><path d="M15 5v4h4"/><path d="M4 8v13h12"/></g>),
    bell: ic(<g><path d="M6 16V11a6 6 0 1 1 12 0v5l2 3H4z"/><path d="M10 21h4"/></g>),
    power: ic(<g><path d="M12 3v9"/><path d="M7 6a8 8 0 1 0 10 0"/></g>),
    search: ic(<g><circle cx="11" cy="11" r="6"/><path d="m20 20-4.5-4.5"/></g>),
    sparkle: ic(<path d="M12 3v3M12 18v3M3 12h3M18 12h3M6 6l2 2M16 16l2 2M6 18l2-2M16 8l2-2"/>),
    alert: ic(<g><circle cx="12" cy="12" r="9"/><path d="M12 8v5M12 16v.5"/></g>),
    alertTriangle: ic(<g><path d="M12 4l9.5 16h-19z"/><path d="M12 10v5M12 18v.5"/></g>),
    more: ic(<g><circle cx="5" cy="12" r="1.2"/><circle cx="12" cy="12" r="1.2"/><circle cx="19" cy="12" r="1.2"/></g>, true),
    check: ic(<path d="M5 12l5 5L20 7"/>),
    close: ic(<path d="M6 6l12 12M6 18L18 6"/>),
    menu: ic(<path d="M4 7h16M4 12h16M4 17h16"/>),
    plus: ic(<path d="M12 5v14M5 12h14"/>),
    download: ic(<g><path d="M12 4v12M7 11l5 5 5-5"/><path d="M5 20h14"/></g>),
    calendar: ic(<g><rect x="3.5" y="5" width="17" height="15" rx="1.5"/><path d="M3.5 10h17"/><path d="M8 3v4M16 3v4"/></g>),
    map: ic(<g><path d="M3 7l6-3 6 3 6-3v14l-6 3-6-3-6 3z"/><path d="M9 4v17M15 7v17"/></g>),
    pin: ic(<g><path d="M12 22s7-7 7-12a7 7 0 1 0-14 0c0 5 7 12 7 12z"/><circle cx="12" cy="10" r="2.5"/></g>),
    filter: ic(<path d="M3 5h18l-7 9v6l-4-2v-4z"/>),
    clock: ic(<g><circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/></g>),
    phone: ic(<path d="M5 4h4l2 5-3 2c1.5 3 3.5 5 6.5 6.5l2-3 5 2v4c0 1-1 2-2 2C9 22 2 15 2 6c0-1 1-2 2-2z"/>),
    whatsapp: ic(<g><path d="M3 21l1.6-5.6A8 8 0 1 1 8.4 19.4z"/><path d="M9 9c0 5 3 8 8 8-1 1.6-2.5 2-4 1.5C8.5 17.5 5.5 14.5 4.5 10c-.5-1.5-.1-3 1.5-4 1 0 2 1 2 2-.4.5-.6 1.1 0 1.6.5.5 1 .7 1.6.4z"/></g>),
    mail: ic(<g><rect x="3" y="5" width="18" height="14" rx="1.5"/><path d="M3 7l9 6 9-6"/></g>),
    refresh: ic(<g><path d="M3 12a9 9 0 0 1 15-6.7L21 8"/><path d="M21 3v5h-5"/><path d="M21 12a9 9 0 0 1-15 6.7L3 16"/><path d="M3 21v-5h5"/></g>),
    trend: ic(<g><path d="M3 17l6-6 4 4 8-9"/><path d="M14 6h7v7"/></g>),
    gauge: ic(<g><path d="M3 15a9 9 0 1 1 18 0"/><path d="M12 15l5-5"/><circle cx="12" cy="15" r="1.5" fill="currentColor" stroke="none"/></g>),
    wrench: ic(<path d="M14 6a4 4 0 1 1-4 4l-7 7v3h3l7-7a4 4 0 0 1 4-4z"/>),
    fuel: ic(<g><rect x="4" y="3" width="9" height="18" rx="1"/><path d="M13 8h2l3 3v8a2 2 0 0 1-2 2 2 2 0 0 1-2-2v-2h-1"/><path d="M7 7h3v3H7z"/></g>),
    eye: ic(<g><path d="M2 12s4-7 10-7 10 7 10 7-4 7-10 7S2 12 2 12z"/><circle cx="12" cy="12" r="3"/></g>),
    settings: ic(<g><circle cx="12" cy="12" r="3"/><path d="M19.4 15a7.8 7.8 0 0 0 .1-3l2-1.5-2-3.5-2.4 1a8 8 0 0 0-2.6-1.5L14 4h-4l-.5 2.5a8 8 0 0 0-2.6 1.5l-2.4-1-2 3.5L4.5 12A7.8 7.8 0 0 0 4.6 15l-2 1.5 2 3.5 2.4-1a8 8 0 0 0 2.6 1.5L10 22h4l.5-2.5a8 8 0 0 0 2.6-1.5l2.4 1 2-3.5z"/></g>),
    box: ic(<g><path d="M3 7l9-4 9 4-9 4z"/><path d="M3 7v10l9 4 9-4V7"/><path d="M12 11v10"/></g>),
    tire: ic(<g><circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="4"/><path d="M12 3v5M12 16v5M3 12h5M16 12h5"/></g>),
  };

  // -------------------------------------------------------------------------
  // BASE PRIMITIVES
  // -------------------------------------------------------------------------
  const T = NS.tokens.type;

  NS.NEyebrow = function ({ children, color, mono = true, size = 'md', style }) {
    const fs = size === 'sm' ? 9.5 : size === 'lg' ? 12 : 10.5;
    return (
      <div style={{
        fontFamily: mono ? T.fontMono : T.fontDisplay,
        fontSize: fs, color: color || 'currentColor',
        letterSpacing: T.tracking.eyebrow,
        textTransform: 'uppercase', fontWeight: T.weights.medium,
        opacity: color ? 1 : 0.5,
        ...style,
      }}>{children}</div>
    );
  };

  NS.NHairline = function ({ vertical, color, style }) {
    return (
      <div style={{
        ...(vertical ? { width: 1, height: '100%' } : { height: 1, width: '100%' }),
        background: color || 'currentColor', opacity: 0.08,
        ...style,
      }} />
    );
  };

  NS.NLogo = function ({ size = 28, theme = 'dark', label = true, mono = false }) {
    const t = theme === 'light' ? light : dark;
    return (
      <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
        <div style={{
          width: size, height: size, borderRadius: size * 0.25,
          background: t.brand,
          display: 'grid', placeItems: 'center',
          fontFamily: T.fontDisplay, fontSize: size * 0.58, fontWeight: 700,
          color: t.brandFg,
          boxShadow: `0 0 ${size}px ${t.brandGlow}`,
        }}>C</div>
        {label && (
          <div style={{
            fontFamily: mono ? T.fontMono : T.fontDisplay,
            fontSize: Math.round(size * 0.52),
            fontWeight: mono ? 500 : 600,
            color: t.text,
            letterSpacing: mono ? '0.04em' : '-0.01em',
          }}>{mono ? 'coopertrans' : 'Coopertrans'}</div>
        )}
      </div>
    );
  };

  // -------------------------------------------------------------------------
  // BUTTON
  // -------------------------------------------------------------------------
  NS.NButton = function ({ children, kind = 'primary', size = 'md', icon, iconAfter, theme = 'dark', full, style, glow = true }) {
    const t = theme === 'light' ? light : dark;
    const sizes = {
      sm: { px: 10, py: 6, fs: 12, gap: 6, ic: 13 },
      md: { px: 14, py: 9, fs: 13, gap: 8, ic: 14 },
      lg: { px: 18, py: 13, fs: 15, gap: 10, ic: 16 },
      xl: { px: 22, py: 16, fs: 16, gap: 12, ic: 18 },
    }[size];
    const kinds = {
      primary: { bg: t.brand, fg: t.brandFg, border: 'transparent', shadow: glow ? `0 0 24px ${t.brandGlow}` : 'none' },
      secondary: { bg: t.surface3, fg: t.text, border: t.borderStrong, shadow: 'none' },
      ghost: { bg: 'transparent', fg: t.text, border: t.border, shadow: 'none' },
      danger: { bg: t.crit, fg: '#fff', border: 'transparent', shadow: glow ? `0 0 24px ${t.crit}40` : 'none' },
    }[kind];
    return (
      <div style={{
        display: 'inline-flex', alignItems: 'center', justifyContent: full ? 'space-between' : 'flex-start',
        gap: sizes.gap, padding: `${sizes.py}px ${sizes.px}px`,
        background: kinds.bg, color: kinds.fg,
        border: `1px solid ${kinds.border}`,
        borderRadius: NS.tokens.radius.md,
        fontFamily: T.fontDisplay, fontSize: sizes.fs, fontWeight: 600,
        letterSpacing: '-0.005em',
        boxShadow: kinds.shadow,
        width: full ? '100%' : 'auto',
        cursor: 'pointer', userSelect: 'none',
        ...style,
      }}>
        {icon && icon(sizes.ic, kinds.fg)}
        <span>{children}</span>
        {iconAfter && iconAfter(sizes.ic, kinds.fg)}
      </div>
    );
  };

  // -------------------------------------------------------------------------
  // INPUT
  // -------------------------------------------------------------------------
  NS.NInput = function ({ label, value, mono = false, theme = 'dark', icon, action, focused, type = 'text', placeholder, style }) {
    const t = theme === 'light' ? light : dark;
    return (
      <label style={{
        display: 'flex', alignItems: 'center', gap: 12,
        background: t.surface2,
        border: `1px solid ${focused ? t.borderFocus : t.border}`,
        borderRadius: NS.tokens.radius.md,
        padding: '12px 14px',
        boxShadow: focused ? `0 0 0 4px ${t.brandGlow}` : 'none',
        ...style,
      }}>
        {icon && (
          <div style={{ display: 'flex' }}>{icon(15, t.textMuted)}</div>
        )}
        {label && (
          <div style={{
            fontFamily: T.fontMono, fontSize: 10, fontWeight: 500,
            color: t.textMuted, letterSpacing: T.tracking.eyebrow,
            textTransform: 'uppercase', minWidth: 60,
          }}>{label}</div>
        )}
        <div style={{
          flex: 1,
          fontFamily: mono || type === 'tel' || type === 'number' || type === 'password' ? T.fontMono : T.fontDisplay,
          fontSize: 15, color: value ? t.text : t.textPlaceholder,
          fontVariantNumeric: 'tabular-nums',
          letterSpacing: type === 'password' ? '0.3em' : 0,
        }}>{value || placeholder}</div>
        {action && (
          <div style={{
            fontFamily: T.fontMono, fontSize: 11,
            color: t.brand, fontWeight: 600,
            letterSpacing: T.tracking.eyebrow, textTransform: 'uppercase',
          }}>{action}</div>
        )}
      </label>
    );
  };

  // -------------------------------------------------------------------------
  // CARD
  // -------------------------------------------------------------------------
  NS.NCard = function ({ children, theme = 'dark', padded = true, glow, accent, style, onClick, hover }) {
    const t = theme === 'light' ? light : dark;
    return (
      <div onClick={onClick} style={{
        background: t.surface2,
        border: `1px solid ${t.border}`,
        borderLeft: accent ? `3px solid ${accent}` : `1px solid ${t.border}`,
        borderRadius: NS.tokens.radius.lg,
        padding: padded === false ? 0 : (typeof padded === 'number' ? padded : 20),
        position: 'relative', overflow: 'hidden',
        boxShadow: glow ? `0 0 32px ${glow}` : 'none',
        cursor: onClick ? 'pointer' : 'default',
        ...style,
      }}>
        {children}
      </div>
    );
  };

  // -------------------------------------------------------------------------
  // BADGE
  // -------------------------------------------------------------------------
  NS.NBadge = function ({ children, color, theme = 'dark', size = 'md', solid = false, dot = false }) {
    const t = theme === 'light' ? light : dark;
    const c = color || t.brand;
    const soft = c + (theme === 'light' ? '15' : '22');
    const sizes = { sm: { px: 7, py: 2, fs: 10 }, md: { px: 9, py: 3, fs: 11 }, lg: { px: 12, py: 5, fs: 12 } }[size];
    return (
      <span style={{
        display: 'inline-flex', alignItems: 'center', gap: 6,
        padding: `${sizes.py}px ${sizes.px}px`,
        background: solid ? c : soft,
        color: solid ? (theme === 'light' ? '#fff' : '#050505') : c,
        borderRadius: NS.tokens.radius.pill,
        fontFamily: T.fontDisplay, fontSize: sizes.fs, fontWeight: 600,
        letterSpacing: '-0.005em',
      }}>
        {dot && <span style={{ width: 6, height: 6, background: c, borderRadius: '50%' }} />}
        {children}
      </span>
    );
  };

  // -------------------------------------------------------------------------
  // DOT (status indicator)
  // -------------------------------------------------------------------------
  NS.NDot = function ({ color, glow = false, size = 8 }) {
    return (
      <span style={{
        width: size, height: size, background: color,
        borderRadius: '50%',
        boxShadow: glow ? `0 0 12px ${color}` : 'none',
        display: 'inline-block',
      }} />
    );
  };

  // -------------------------------------------------------------------------
  // KPI / STAT (the workhorse for dashboards)
  // -------------------------------------------------------------------------
  NS.NStat = function ({ label, value, unit, delta, deltaColor, prefix, big = false, sparkline, theme = 'dark', accent }) {
    const t = theme === 'light' ? light : dark;
    return (
      <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
        <NS.NEyebrow style={{ color: t.textMuted, opacity: 1 }}>{label}</NS.NEyebrow>
        <div style={{ display: 'flex', alignItems: 'baseline', gap: 5 }}>
          {prefix && <span style={{ fontFamily: T.fontMono, fontSize: 13, color: t.textMuted }}>{prefix}</span>}
          <span style={{
            fontFamily: T.fontDisplay,
            fontSize: big ? T.sizes.h1 : T.sizes.h3,
            fontWeight: T.weights.semibold,
            color: accent || t.text,
            fontVariantNumeric: 'tabular-nums',
            letterSpacing: T.tracking.displayTight, lineHeight: 0.95,
          }}>{value}</span>
          {unit && <span style={{ fontFamily: T.fontMono, fontSize: 11, color: t.textMuted }}>{unit}</span>}
          {delta && (
            <span style={{ marginLeft: 'auto', fontFamily: T.fontMono, fontSize: 11, color: deltaColor || t.textMuted, fontWeight: 500 }}>{delta}</span>
          )}
        </div>
        {sparkline && <div style={{ marginTop: 4, opacity: 0.7 }}>{sparkline}</div>}
      </div>
    );
  };

  // -------------------------------------------------------------------------
  // SPARKLINE
  // -------------------------------------------------------------------------
  NS.NSparkline = function ({ data, color, w = 120, h = 28, fill = false }) {
    const max = Math.max(...data), min = Math.min(...data);
    const range = max - min || 1;
    const pts = data.map((v, i) => `${(i / (data.length - 1)) * w},${h - ((v - min) / range) * h}`).join(' ');
    return (
      <svg width={w} height={h} style={{ display: 'block' }}>
        {fill && (
          <>
            <defs>
              <linearGradient id={`spfill-${color.replace(/[^a-z0-9]/gi, '')}`} x1="0" y1="0" x2="0" y2="1">
                <stop offset="0%" stopColor={color} stopOpacity="0.4"/>
                <stop offset="100%" stopColor={color} stopOpacity="0"/>
              </linearGradient>
            </defs>
            <polygon points={`${pts} ${w},${h} 0,${h}`} fill={`url(#spfill-${color.replace(/[^a-z0-9]/gi, '')})`} />
          </>
        )}
        <polyline points={pts} fill="none" stroke={color} strokeWidth="1.4" strokeLinecap="round" strokeLinejoin="round" />
      </svg>
    );
  };

  // -------------------------------------------------------------------------
  // AREA CHART (bento-size)
  // -------------------------------------------------------------------------
  NS.NAreaChart = function ({ data, labels, color, theme = 'dark', height = 140 }) {
    const t = theme === 'light' ? light : dark;
    const W = 400, H = height;
    const max = Math.max(...data) * 1.05;
    const pts = data.map((v, i) => `${(i / (data.length - 1)) * W},${H - (v / max) * H}`).join(' ');
    const gradId = `area-${color.replace(/[^a-z0-9]/gi, '')}`;

    return (
      <svg width="100%" height={H + 20} viewBox={`0 0 ${W} ${H + 20}`} preserveAspectRatio="none" style={{ display: 'block' }}>
        <defs>
          <linearGradient id={gradId} x1="0" y1="0" x2="0" y2="1">
            <stop offset="0%" stopColor={color} stopOpacity="0.32"/>
            <stop offset="100%" stopColor={color} stopOpacity="0"/>
          </linearGradient>
        </defs>
        {[0, 0.25, 0.5, 0.75, 1].map(g => (
          <line key={g} x1="0" y1={H * g} x2={W} y2={H * g} stroke={t.border} strokeWidth="1" />
        ))}
        <polygon points={`${pts} ${W},${H} 0,${H}`} fill={`url(#${gradId})`} />
        <polyline points={pts} fill="none" stroke={color} strokeWidth="2" />
        {data.map((v, i) => {
          const x = (i / (data.length - 1)) * W;
          const y = H - (v / max) * H;
          return (
            <g key={i}>
              <circle cx={x} cy={y} r="3" fill={t.bg} stroke={color} strokeWidth="1.5" />
              {labels && <text x={x} y={H + 14} fontSize="9" fill={t.textMuted} textAnchor="middle" fontFamily={T.fontMono}>{labels[i]}</text>}
            </g>
          );
        })}
      </svg>
    );
  };

  // -------------------------------------------------------------------------
  // AMBIENT GLOW
  // -------------------------------------------------------------------------
  NS.NAmbient = function ({ color, x = '50%', y = 0, size = 600, intensity = 0.18 }) {
    return (
      <div style={{
        position: 'absolute', left: x, top: y,
        width: size, height: size,
        background: `radial-gradient(circle at center, ${color} 0%, transparent 70%)`,
        opacity: intensity,
        pointerEvents: 'none',
        transform: 'translate(-50%, -30%)',
        filter: 'blur(40px)',
        zIndex: 0,
      }} />
    );
  };

  // -------------------------------------------------------------------------
  // TOP BAR (desktop chrome)
  // -------------------------------------------------------------------------
  NS.NTopbar = function ({ theme = 'dark', nav, active = 0, search = true, user = 'SV', breadcrumbs }) {
    const t = theme === 'light' ? light : dark;
    return (
      <div style={{
        borderBottom: `1px solid ${t.border}`,
        padding: '12px 24px',
        display: 'flex', alignItems: 'center', justifyContent: 'space-between',
        background: theme === 'light' ? 'rgba(255,255,255,0.7)' : 'rgba(5,5,5,0.7)',
        backdropFilter: 'blur(10px)',
        position: 'relative', zIndex: 5,
      }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 24 }}>
          <NS.NLogo theme={theme} size={26} />
          {breadcrumbs && (
            <div style={{ display: 'flex', alignItems: 'center', gap: 6, fontFamily: T.fontMono, fontSize: 11, color: t.textMuted, letterSpacing: '0.04em' }}>
              {breadcrumbs.map((b, i) => (
                <React.Fragment key={i}>
                  {i > 0 && <span>/</span>}
                  <span style={{ color: i === breadcrumbs.length - 1 ? t.text : t.textMuted }}>{b}</span>
                </React.Fragment>
              ))}
            </div>
          )}
          {nav && (
            <div style={{ display: 'flex', gap: 2 }}>
              {nav.map((s, i) => (
                <div key={s} style={{
                  padding: '6px 12px', borderRadius: 6,
                  fontSize: 13, fontWeight: 500,
                  color: i === active ? t.text : t.textSecondary,
                  background: i === active ? t.surface3 : 'transparent',
                }}>{s}</div>
              ))}
            </div>
          )}
        </div>
        <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
          {search && (
            <div style={{
              background: t.surface2, border: `1px solid ${t.border}`,
              borderRadius: 8, padding: '6px 12px',
              display: 'flex', alignItems: 'center', gap: 8, minWidth: 240,
            }}>
              {NS.icons.search(13, t.textMuted)}
              <div style={{ fontFamily: T.fontMono, fontSize: 11, color: t.textMuted }}>Buscar o saltar a…</div>
              <div style={{ marginLeft: 'auto', fontFamily: T.fontMono, fontSize: 10, color: t.textMuted, padding: '1px 5px', background: t.surface3, borderRadius: 3 }}>⌘K</div>
            </div>
          )}
          <div style={{
            width: 28, height: 28, borderRadius: '50%',
            border: `1px solid ${t.borderStrong}`,
            display: 'grid', placeItems: 'center',
            fontFamily: T.fontDisplay, fontSize: 11, fontWeight: 600, color: t.text,
          }}>{user}</div>
        </div>
      </div>
    );
  };

  // -------------------------------------------------------------------------
  // MOBILE STATUS BAR
  // -------------------------------------------------------------------------
  NS.NStatusBar = function ({ theme = 'dark', time = '14:32', battery = '97%' }) {
    const t = theme === 'light' ? light : dark;
    return (
      <div style={{
        padding: '14px 22px 0', display: 'flex', justifyContent: 'space-between',
        fontFamily: T.fontMono, fontSize: 11, fontVariantNumeric: 'tabular-nums',
        color: t.text, zIndex: 5, position: 'relative',
      }}>
        <span>{time}</span>
        <span style={{ display: 'flex', gap: 10 }}><span>5G</span><span>{battery}</span></span>
      </div>
    );
  };

  // -------------------------------------------------------------------------
  // SEGMENTED CONTROL
  // -------------------------------------------------------------------------
  NS.NSegmented = function ({ options, active = 0, theme = 'dark' }) {
    const t = theme === 'light' ? light : dark;
    return (
      <div style={{ display: 'flex', gap: 0, border: `1px solid ${t.border}`, borderRadius: 8, background: t.surface2, overflow: 'hidden' }}>
        {options.map((p, i) => (
          <div key={p} style={{
            padding: '6px 14px', fontSize: 12, fontWeight: 500,
            color: i === active ? (theme === 'light' ? '#fff' : '#050505') : t.textSecondary,
            background: i === active ? t.text : 'transparent',
            fontFamily: T.fontDisplay,
          }}>{p}</div>
        ))}
      </div>
    );
  };

  // -------------------------------------------------------------------------
  // THEME PROVIDER (used inside artboards)
  // -------------------------------------------------------------------------
  NS.NThemeProvider = function ({ theme = 'dark', children, style }) {
    const t = theme === 'light' ? light : dark;
    return (
      <div style={{
        background: t.bg, color: t.text,
        fontFamily: T.fontDisplay,
        width: '100%', height: '100%',
        boxSizing: 'border-box',
        position: 'relative', overflow: 'hidden',
        ...style,
      }}>{children}</div>
    );
  };

  window.NS = NS;
})();
