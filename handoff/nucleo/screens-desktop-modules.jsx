// nucleo/screens-desktop-modules.jsx
// Desktop ADMIN flow — module screens: Flota (mapa) · Logistica (viajes) · Servicios
// Uses primitives from window.NS and window.DShell.
// Exposes: window.DesktopModuleScreens = { flota, logistica, servicios, gomeria, eco, icm }

const X = window.NS;
const Xtok = X.tokens.color.dark;
const Xtype = X.tokens.type;
const Xr = X.tokens.radius;
const Xic = X.icons;
const XShell = window.DShell;

// ----------------------------------------------------------------------------
// FLOTA · mapa + lista + detalle
// ----------------------------------------------------------------------------
function Flota({ go }) {
  const units = [
    { id: 'VOL-187', driver: 'S. Vecchi', speed: 72, eta: 'Ing. White · 14 km', st: 'ON', sel: true },
    { id: 'VOL-204', driver: 'M. Ruiz', speed: 88, eta: 'Cnel. Suárez · 92 km', st: 'ON' },
    { id: 'VOL-219', driver: 'J. Pereyra', speed: 0, eta: 'Base · ralentí', st: 'IDLE' },
    { id: 'SCN-302', driver: 'D. Lobos', speed: 65, eta: 'Médanos · 38 km', st: 'ON' },
    { id: 'SCN-318', driver: '—', speed: 0, eta: 'Taller · gomería', st: 'TLR' },
    { id: 'IVE-401', driver: 'F. Aguirre', speed: 81, eta: 'Tres Arroyos · 121 km', st: 'ON' },
    { id: 'IVE-410', driver: 'P. Méndez', speed: 0, eta: 'YPF · stop 2m', st: 'STP' },
    { id: 'VOL-225', driver: 'C. Ibáñez', speed: 76, eta: 'Pigüé · 64 km', st: 'ON' },
  ];
  const stColor = (st) => st === 'ON' ? Xtok.brand : (st === 'STP' || st === 'TLR') ? Xtok.warn : Xtok.textMuted;

  return (
    <XShell active={2} go={go} breadcrumbs={[{ label: 'Coopertrans', go: 'dashboard' }, { label: 'Flota' }, { label: 'Mapa' }]} ambient={false}>
      {/* ticker */}
      <div style={{
        padding: '7px 24px', borderBottom: `1px solid ${Xtok.border}`,
        display: 'flex', gap: 22, fontFamily: Xtype.fontMono, fontSize: 10, color: Xtok.textMuted, letterSpacing: '0.04em',
      }}>
        <span style={{ color: Xtok.brand, fontWeight: 600 }}>● sitrack live</span>
        <span>units <span style={{ color: Xtok.text }}>12/12</span></span>
        <span>on-route <span style={{ color: Xtok.brand }}>5</span></span>
        <span>idle <span style={{ color: Xtok.textMuted }}>2</span></span>
        <span>stopped <span style={{ color: Xtok.warn }}>1</span></span>
        <span>taller <span style={{ color: Xtok.warn }}>1</span></span>
        <span>avg-speed <span style={{ color: Xtok.text }}>74 km/h</span></span>
        <span>fuel-avg <span style={{ color: Xtok.text }}>2.38 km/L</span></span>
        <span style={{ marginLeft: 'auto', color: Xtok.text }}>sync 2 min ago</span>
      </div>

      {/* 3-col layout */}
      <div style={{ height: 'calc(100% - 32px)', display: 'grid', gridTemplateColumns: '320px 1fr 320px', overflow: 'hidden' }}>
        {/* LEFT — list */}
        <div style={{ borderRight: `1px solid ${Xtok.border}`, background: Xtok.surface1, display: 'flex', flexDirection: 'column' }}>
          <div style={{ padding: '18px 20px', borderBottom: `1px solid ${Xtok.border}` }}>
            <X.NEyebrow style={{ color: Xtok.textMuted, opacity: 1 }}>Activas</X.NEyebrow>
            <div style={{ display: 'flex', alignItems: 'baseline', gap: 10, marginTop: 4 }}>
              <div style={{ fontFamily: Xtype.fontDisplay, fontSize: 44, fontWeight: 600, letterSpacing: '-0.04em', lineHeight: 0.9, fontVariantNumeric: 'tabular-nums' }}>8</div>
              <div style={{ fontFamily: Xtype.fontMono, fontSize: 12, color: Xtok.textMuted }}>de 12</div>
            </div>
            <div style={{ display: 'flex', gap: 4, marginTop: 14 }}>
              {[
                { l: '5', s: 'ON', c: Xtok.brand },
                { l: '2', s: 'Idle', c: Xtok.textMuted },
                { l: '1', s: 'Stop', c: Xtok.warn },
                { l: '1', s: 'Tlr', c: Xtok.warn },
              ].map(b => (
                <div key={b.s} style={{ flex: 1, padding: '6px 0', textAlign: 'center', background: Xtok.surface2, border: `1px solid ${Xtok.border}`, borderRadius: 6 }}>
                  <div style={{ fontFamily: Xtype.fontMono, fontSize: 13, color: b.c, fontWeight: 600, fontVariantNumeric: 'tabular-nums' }}>{b.l}</div>
                  <div style={{ fontFamily: Xtype.fontMono, fontSize: 9, color: Xtok.textMuted, letterSpacing: '0.06em', textTransform: 'uppercase' }}>{b.s}</div>
                </div>
              ))}
            </div>
          </div>
          <div style={{ padding: '10px 20px', borderBottom: `1px solid ${Xtok.border}`, display: 'flex', alignItems: 'center', gap: 8 }}>
            {Xic.search(13, Xtok.textMuted)}
            <div style={{ fontFamily: Xtype.fontMono, fontSize: 11, color: Xtok.textMuted }}>Buscar unidad…</div>
          </div>
          <div style={{ overflow: 'hidden' }}>
            {units.map(u => (
              <div key={u.id} style={{
                padding: '12px 20px', borderBottom: `1px solid ${Xtok.border}`,
                background: u.sel ? Xtok.surface2 : 'transparent',
                borderLeft: u.sel ? `2px solid ${Xtok.brand}` : '2px solid transparent',
                display: 'grid', gridTemplateColumns: '1fr auto', gap: 8, alignItems: 'center', cursor: 'pointer',
              }}>
                <div>
                  <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                    <div style={{ fontFamily: Xtype.fontMono, fontSize: 12, fontWeight: 600 }}>{u.id}</div>
                    <div style={{ fontFamily: Xtype.fontMono, fontSize: 9, color: stColor(u.st), letterSpacing: '0.08em', fontWeight: 600 }}>{u.st}</div>
                  </div>
                  <div style={{ fontSize: 12, color: Xtok.textSecondary, marginTop: 2 }}>{u.driver}</div>
                  <div style={{ fontFamily: Xtype.fontMono, fontSize: 10, color: Xtok.textMuted, marginTop: 1 }}>{u.eta}</div>
                </div>
                <div style={{ fontFamily: Xtype.fontMono, fontSize: 13, color: u.speed > 0 ? Xtok.text : Xtok.textMuted, fontVariantNumeric: 'tabular-nums', fontWeight: 500, textAlign: 'right' }}>
                  {u.speed > 0 ? u.speed : '—'}
                  {u.speed > 0 && <div style={{ fontSize: 9, color: Xtok.textMuted, fontWeight: 400 }}>km/h</div>}
                </div>
              </div>
            ))}
          </div>
        </div>

        {/* CENTER — map */}
        <div style={{ position: 'relative', background: Xtok.surface1, overflow: 'hidden' }}>
          <div style={{
            position: 'absolute', inset: 0,
            backgroundImage: `linear-gradient(${Xtok.border} 1px, transparent 1px), linear-gradient(90deg, ${Xtok.border} 1px, transparent 1px)`,
            backgroundSize: '32px 32px', opacity: 0.6,
          }} />
          <div style={{
            position: 'absolute', top: '30%', left: '50%', width: 500, height: 500,
            background: `radial-gradient(circle, ${Xtok.brandGlow}, transparent 70%)`,
            transform: 'translate(-50%, -50%)', filter: 'blur(40px)', pointerEvents: 'none',
          }} />
          <svg width="100%" height="100%" style={{ position: 'absolute', inset: 0 }}>
            <path d="M 0 280 Q 200 220 380 260 T 720 200" stroke={Xtok.borderStrong} strokeWidth="1.5" fill="none" />
            <path d="M 100 40 Q 240 200 360 320 T 580 520" stroke={Xtok.borderStrong} strokeWidth="1.5" fill="none" />
            <path d="M 0 420 Q 300 380 500 440 T 720 460" stroke={Xtok.borderStrong} strokeWidth="1.5" fill="none" />
          </svg>
          {[
            { x: '50%', y: '38%', l: 'VOL-187', sel: true, n: 72 },
            { x: '68%', y: '28%', l: 'VOL-204', n: 88 },
            { x: '32%', y: '34%', l: 'VOL-219', dim: true, n: 0 },
            { x: '60%', y: '55%', l: 'SCN-302', n: 65 },
            { x: '24%', y: '62%', l: 'IVE-410', warn: true, n: 0 },
            { x: '75%', y: '58%', l: 'IVE-401', n: 81 },
            { x: '42%', y: '70%', l: 'VOL-225', n: 76 },
          ].map(m => (
            <div key={m.l} style={{
              position: 'absolute', left: m.x, top: m.y,
              transform: 'translate(-50%, -50%)',
              display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 4,
            }}>
              {m.sel && (
                <div style={{ position: 'absolute', width: 60, height: 60, borderRadius: '50%', border: `1px solid ${Xtok.brand}`, opacity: 0.4 }} />
              )}
              <div style={{
                width: m.sel ? 12 : 8, height: m.sel ? 12 : 8,
                background: m.warn ? Xtok.warn : m.dim ? Xtok.textMuted : Xtok.brand,
                borderRadius: '50%',
                boxShadow: m.sel ? `0 0 16px ${Xtok.brand}` : `0 0 8px ${m.warn ? Xtok.warn : m.dim ? 'transparent' : Xtok.brand}`,
                border: m.sel ? `2px solid ${Xtok.text}` : 'none',
              }} />
              <div style={{
                background: 'rgba(15,15,16,0.85)', backdropFilter: 'blur(8px)',
                borderRadius: 4, padding: '2px 6px',
                fontFamily: Xtype.fontMono, fontSize: 9, fontWeight: 600,
                color: Xtok.text, letterSpacing: '0.04em',
                border: `1px solid ${Xtok.border}`,
              }}>{m.l}{m.n > 0 && ` · ${m.n}`}</div>
            </div>
          ))}
          <div style={{ position: 'absolute', top: 14, left: 14, display: 'flex', gap: 8 }}>
            {['−38.7196° / −62.2724°', 'zoom 11', 'Bahía Blanca SO'].map(s => (
              <div key={s} style={{
                background: 'rgba(15,15,16,0.7)', backdropFilter: 'blur(8px)',
                border: `1px solid ${Xtok.border}`, borderRadius: 6,
                padding: '6px 10px', fontFamily: Xtype.fontMono, fontSize: 10, color: Xtok.text,
              }}>{s}</div>
            ))}
          </div>
        </div>

        {/* RIGHT — detail */}
        <div style={{ borderLeft: `1px solid ${Xtok.border}`, background: Xtok.surface1, display: 'flex', flexDirection: 'column' }}>
          <div style={{ padding: '18px 20px', borderBottom: `1px solid ${Xtok.border}` }}>
            <X.NEyebrow style={{ color: Xtok.textMuted, opacity: 1 }}>Seleccionada</X.NEyebrow>
            <div style={{ fontFamily: Xtype.fontDisplay, fontSize: 38, fontWeight: 600, letterSpacing: '-0.03em', lineHeight: 1, marginTop: 6 }}>VOL-187</div>
            <div style={{ fontFamily: Xtype.fontMono, fontSize: 11, color: Xtok.textSecondary, marginTop: 4 }}>S. Vecchi · Volvo FH 540</div>
          </div>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr' }}>
            {[
              { l: 'Velocidad', v: '72', u: 'km/h' },
              { l: 'Combustible', v: '67', u: '%' },
              { l: 'RPM', v: '1.420', u: '' },
              { l: 'Eco score', v: '91', u: '', h: true },
              { l: 'Temp', v: '88', u: '°C' },
              { l: 'Jornada', v: '6:14', u: '' },
            ].map((k, i) => (
              <div key={k.l} style={{
                padding: '14px 18px',
                borderRight: i % 2 === 0 ? `1px solid ${Xtok.border}` : 'none',
                borderBottom: `1px solid ${Xtok.border}`,
              }}>
                <X.NEyebrow style={{ color: Xtok.textMuted, opacity: 1 }}>{k.l}</X.NEyebrow>
                <div style={{ display: 'flex', alignItems: 'baseline', gap: 4, marginTop: 4 }}>
                  <div style={{ fontFamily: Xtype.fontDisplay, fontSize: 26, fontWeight: 600, color: k.h ? Xtok.brand : Xtok.text, fontVariantNumeric: 'tabular-nums', letterSpacing: '-0.03em', lineHeight: 1 }}>{k.v}</div>
                  {k.u && <div style={{ fontFamily: Xtype.fontMono, fontSize: 11, color: Xtok.textMuted }}>{k.u}</div>}
                </div>
              </div>
            ))}
          </div>
          <div style={{ padding: '16px 20px', borderBottom: `1px solid ${Xtok.border}` }}>
            <X.NEyebrow style={{ color: Xtok.textMuted, opacity: 1 }}>Últimos eventos</X.NEyebrow>
          </div>
          {[
            { t: '14:08', e: 'Cambio turno · iButton OK' },
            { t: '13:42', e: 'Ralentí 4 min · Ing. White' },
            { t: '13:11', e: 'Salida base · km 0' },
          ].map((row, i) => (
            <div key={i} style={{ padding: '11px 20px', display: 'grid', gridTemplateColumns: '44px 1fr', gap: 10, borderBottom: `1px solid ${Xtok.border}` }}>
              <div style={{ fontFamily: Xtype.fontMono, fontSize: 10, color: Xtok.textMuted, fontVariantNumeric: 'tabular-nums' }}>{row.t}</div>
              <div style={{ fontSize: 12 }}>{row.e}</div>
            </div>
          ))}
          <div style={{ padding: '14px 20px', marginTop: 'auto' }} onClick={() => go('personal_detail')}>
            <X.NButton kind="primary" theme="dark" size="md" full iconAfter={Xic.arrow}>Ver ficha del chofer</X.NButton>
          </div>
        </div>
      </div>
    </XShell>
  );
}

// ----------------------------------------------------------------------------
// LOGÍSTICA · viajes
// ----------------------------------------------------------------------------
function Logistica({ go }) {
  const trips = [
    { id: '2841', dt: 'hoy 06:30', orig: 'Bahía Blanca', dest: 'Ing. White', driver: 'S. Vecchi', un: 'VOL-187', km: 14, st: 'En curso',     c: Xtok.brand,  $: '$ 42.800' },
    { id: '2840', dt: 'hoy 05:45', orig: 'Bahía Blanca', dest: 'Cnel. Suárez',driver: 'M. Ruiz',   un: 'VOL-204', km: 92, st: 'En curso',     c: Xtok.brand,  $: '$ 178.500' },
    { id: '2839', dt: 'hoy 04:10', orig: 'Bahía Blanca', dest: 'Médanos',     driver: 'D. Lobos',  un: 'SCN-302', km: 38, st: 'En curso',     c: Xtok.brand,  $: '$ 64.200' },
    { id: '2838', dt: 'ayer 22:15', orig: 'Bahía Blanca',dest: 'Tres Arroyos',driver: 'F. Aguirre',un: 'IVE-401', km: 121, st: 'Completado', c: Xtok.ok,     $: '$ 224.600' },
    { id: '2837', dt: 'ayer 19:42', orig: 'Pigüé',       dest: 'Bahía Blanca',driver: 'C. Ibáñez', un: 'VOL-225', km: 64, st: 'Completado',  c: Xtok.ok,     $: '$ 118.900' },
    { id: '2836', dt: 'ayer 16:08', orig: 'Bahía Blanca',dest: 'Pigüé',       driver: 'C. Ibáñez', un: 'VOL-225', km: 64, st: 'Completado',  c: Xtok.ok,     $: '$ 118.900' },
    { id: '2835', dt: 'ayer 14:30', orig: 'Bahía Blanca',dest: 'YPF Ruta 3',  driver: 'P. Méndez', un: 'IVE-410', km: 28, st: 'Anulado',     c: Xtok.crit,   $: '— ' },
    { id: '2834', dt: 'ayer 10:00', orig: 'Punta Alta',  dest: 'Bahía Blanca',driver: 'M. Ruiz',   un: 'VOL-204', km: 28, st: 'Completado',  c: Xtok.ok,     $: '$ 52.400' },
  ];

  return (
    <XShell active={4} go={go} breadcrumbs={[{ label: 'Coopertrans', go: 'dashboard' }, { label: 'Logística' }, { label: 'Viajes' }]}>
      <div style={{ padding: '24px 24px', display: 'flex', flexDirection: 'column', gap: 18, height: '100%', boxSizing: 'border-box', overflow: 'hidden' }}>
        {/* hero */}
        <div style={{ display: 'flex', alignItems: 'flex-end', justifyContent: 'space-between' }}>
          <div>
            <X.NEyebrow style={{ color: Xtok.textMuted, opacity: 1 }}>Hoy · 14:32</X.NEyebrow>
            <div style={{ fontFamily: Xtype.fontDisplay, fontSize: 52, fontWeight: 600, letterSpacing: '-0.04em', lineHeight: 0.95, marginTop: 8 }}>
              Viajes.
            </div>
          </div>
          <div style={{ display: 'flex', gap: 10 }}>
            <X.NSegmented theme="dark" options={['Hoy','7d','30d']} active={0} />
            <X.NButton kind="primary" theme="dark" size="md" icon={Xic.plus}>Nuevo viaje</X.NButton>
          </div>
        </div>

        {/* summary */}
        <X.NCard theme="dark" padded={false}>
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(5, 1fr)' }}>
            {[
              { l: 'En curso', v: '3', c: Xtok.brand, sub: 'arrancaron hoy' },
              { l: 'Completados', v: '5', c: Xtok.ok, sub: 'últimas 24h' },
              { l: 'Anulados', v: '1', c: Xtok.crit, sub: 'cliente canceló' },
              { l: 'Km totales', v: '449', c: Xtok.text, sub: 'flota completa' },
              { l: 'Facturado', v: '$800k', c: Xtok.text, sub: '24h móviles' },
            ].map((s, i) => (
              <div key={s.l} style={{ padding: '18px 22px', borderRight: i < 4 ? `1px solid ${Xtok.border}` : 'none' }}>
                <X.NEyebrow style={{ color: Xtok.textMuted, opacity: 1 }}>{s.l}</X.NEyebrow>
                <div style={{ fontFamily: Xtype.fontDisplay, fontSize: 36, fontWeight: 600, color: s.c, letterSpacing: '-0.04em', lineHeight: 0.95, fontVariantNumeric: 'tabular-nums', marginTop: 6 }}>{s.v}</div>
                <div style={{ fontFamily: Xtype.fontMono, fontSize: 10, color: Xtok.textMuted, marginTop: 4, letterSpacing: '0.04em' }}>{s.sub}</div>
              </div>
            ))}
          </div>
        </X.NCard>

        {/* table */}
        <div style={{ flex: 1, background: Xtok.surface2, border: `1px solid ${Xtok.border}`, borderRadius: Xr.lg, overflow: 'hidden', display: 'flex', flexDirection: 'column' }}>
          <div style={{
            display: 'grid', gridTemplateColumns: '80px 1.2fr 1.5fr 1.2fr 1fr 80px 1fr 1fr 40px',
            padding: '12px 20px', borderBottom: `1px solid ${Xtok.border}`,
            fontFamily: Xtype.fontMono, fontSize: 10, color: Xtok.textMuted, letterSpacing: '0.08em', textTransform: 'uppercase', fontWeight: 500,
            background: Xtok.surface1, gap: 8, alignItems: 'center',
          }}>
            <div>#</div>
            <div>Hora</div>
            <div>Recorrido</div>
            <div>Chofer</div>
            <div>Unidad</div>
            <div style={{ textAlign: 'right' }}>Km</div>
            <div>Estado</div>
            <div style={{ textAlign: 'right' }}>Facturado</div>
            <div></div>
          </div>
          <div style={{ flex: 1, overflow: 'hidden' }}>
            {trips.map((t, i) => (
              <div key={t.id} style={{
                display: 'grid', gridTemplateColumns: '80px 1.2fr 1.5fr 1.2fr 1fr 80px 1fr 1fr 40px',
                padding: '13px 20px', borderTop: i ? `1px solid ${Xtok.border}` : 'none',
                alignItems: 'center', cursor: 'pointer', gap: 8,
              }}>
                <div style={{ fontFamily: Xtype.fontMono, fontSize: 12, color: Xtok.textSecondary, fontVariantNumeric: 'tabular-nums' }}>#{t.id}</div>
                <div style={{ fontFamily: Xtype.fontMono, fontSize: 11, color: Xtok.textSecondary, letterSpacing: '0.02em' }}>{t.dt}</div>
                <div style={{ fontSize: 13, color: Xtok.text }}>
                  {t.orig} <span style={{ color: Xtok.textMuted, margin: '0 6px' }}>→</span> {t.dest}
                </div>
                <div style={{ fontSize: 13, color: Xtok.text }}>{t.driver}</div>
                <div style={{ fontFamily: Xtype.fontMono, fontSize: 12, color: Xtok.text, fontVariantNumeric: 'tabular-nums' }}>{t.un}</div>
                <div style={{ fontFamily: Xtype.fontMono, fontSize: 12.5, color: Xtok.text, fontVariantNumeric: 'tabular-nums', textAlign: 'right' }}>{t.km}</div>
                <div>
                  <X.NBadge theme="dark" color={t.c} dot size="sm">{t.st}</X.NBadge>
                </div>
                <div style={{ fontFamily: Xtype.fontMono, fontSize: 12.5, color: Xtok.text, fontVariantNumeric: 'tabular-nums', textAlign: 'right' }}>{t.$}</div>
                <div style={{ display: 'grid', placeItems: 'center' }}>{Xic.chevronRight(13, Xtok.textMuted)}</div>
              </div>
            ))}
          </div>
        </div>
      </div>
    </XShell>
  );
}

// ----------------------------------------------------------------------------
// SERVICIOS · status panel (bot WA, cachatore, sitrack, volvo, iturnos)
// ----------------------------------------------------------------------------
function Servicios({ go }) {
  const svcs = [
    {
      id: 'wa', n: 'Bot WhatsApp', icon: Xic.whatsapp, c: Xtok.ok, m: 'OK',
      pulse: '12s', queue: 4, lastEvt: '14:31 · respuesta enviada · +54 9 291...',
      stats: [
        { l: 'mensajes 24h', v: '218', d: '+12%' },
        { l: 'respuesta media', v: '6s' },
        { l: 'destinos', v: '6' },
        { l: 'uptime', v: '99.97%' },
      ],
      spark: [180, 195, 178, 210, 222, 198, 218, 218],
    },
    {
      id: 'ca', n: 'Cachatore', icon: Xic.calendar, c: Xtok.ok, m: 'OK',
      pulse: 'turnos · 4', queue: 4, lastEvt: '14:18 · turno confirmado · J. Pereyra',
      stats: [
        { l: 'turnos hoy', v: '12' },
        { l: 'completados', v: '8' },
        { l: 'pendientes', v: '4' },
        { l: 'no-shows', v: '0' },
      ],
      spark: [10, 8, 12, 9, 11, 13, 12, 12],
    },
    {
      id: 'st', n: 'Sitrack', icon: Xic.map, c: Xtok.ok, m: 'OK',
      pulse: 'sync 2m', queue: null, lastEvt: '14:30 · snapshot recibido · 8 unidades',
      stats: [
        { l: 'unidades', v: '12' },
        { l: 'gps lock', v: '12' },
        { l: 'lag avg', v: '2m' },
        { l: 'eventos 24h', v: '418' },
      ],
      spark: [400, 412, 395, 418, 425, 410, 418, 418],
    },
    {
      id: 'vo', n: 'Volvo Connect', icon: Xic.truck, c: Xtok.warn, m: 'LAG 6m',
      pulse: 'driver · scores', queue: null, lastEvt: '14:26 · score recibido · 5 unidades (esperaban 7)',
      stats: [
        { l: 'unidades', v: '5/7' },
        { l: 'scores', v: '5' },
        { l: 'lag actual', v: '6m' },
        { l: 'alertas 24h', v: '14' },
      ],
      spark: [22, 18, 20, 19, 16, 14, 14, 14],
    },
    {
      id: 'it', n: 'iTurnos · mantenim.', icon: Xic.wrench, c: Xtok.ok, m: 'OK',
      pulse: 'reservas · 3', queue: 3, lastEvt: '13:50 · reserva · SCN-318 · gomería',
      stats: [
        { l: 'reservas 7d', v: '8' },
        { l: 'completadas', v: '5' },
        { l: 'pendientes', v: '3' },
        { l: 'taller', v: '2' },
      ],
      spark: [3, 5, 4, 3, 6, 4, 3, 3],
    },
  ];

  return (
    <XShell active={8} go={go} breadcrumbs={[{ label: 'Coopertrans', go: 'dashboard' }, { label: 'Servicios externos' }]}>
      <div style={{ padding: '24px 24px', display: 'flex', flexDirection: 'column', gap: 18, height: '100%', boxSizing: 'border-box', overflow: 'auto' }}>
        {/* hero */}
        <div style={{ display: 'flex', alignItems: 'flex-end', justifyContent: 'space-between' }}>
          <div>
            <X.NEyebrow style={{ color: Xtok.textMuted, opacity: 1 }}>Integraciones</X.NEyebrow>
            <div style={{ fontFamily: Xtype.fontDisplay, fontSize: 52, fontWeight: 600, letterSpacing: '-0.04em', lineHeight: 0.95, marginTop: 8 }}>
              Servicios externos.
            </div>
            <div style={{ fontFamily: Xtype.fontMono, fontSize: 12, color: Xtok.textMuted, marginTop: 8 }}>
              <span style={{ color: Xtok.ok, fontWeight: 600 }}>● 4 en línea</span>
              &nbsp;&nbsp; <span style={{ color: Xtok.warn, fontWeight: 600 }}>● 1 con lag</span>
              &nbsp;&nbsp; refresh 5s
            </div>
          </div>
          <X.NButton kind="ghost" theme="dark" size="md" icon={Xic.refresh}>Forzar sync</X.NButton>
        </div>

        {/* service cards — bento */}
        {svcs.map((s, i) => (
          <X.NCard key={s.id} theme="dark" padded={false} accent={s.c === Xtok.warn ? Xtok.warn : null}>
            <div style={{ padding: '22px 24px', display: 'grid', gridTemplateColumns: '52px 1fr 280px auto', gap: 24, alignItems: 'center' }}>
              <div style={{ width: 44, height: 44, borderRadius: 12, background: `${s.c}22`, display: 'grid', placeItems: 'center', boxShadow: s.c === Xtok.ok ? `0 0 16px ${s.c}30` : 'none' }}>
                {s.icon(22, s.c)}
              </div>
              <div>
                <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
                  <div style={{ fontFamily: Xtype.fontDisplay, fontSize: 22, fontWeight: 600, letterSpacing: '-0.02em' }}>{s.n}</div>
                  <X.NBadge theme="dark" color={s.c} dot solid={false} size="sm">{s.m}</X.NBadge>
                </div>
                <div style={{ fontFamily: Xtype.fontMono, fontSize: 11, color: Xtok.textMuted, marginTop: 4, letterSpacing: '0.02em' }}>
                  {s.lastEvt}
                </div>
              </div>
              <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 4 }}>
                {s.stats.map(k => (
                  <div key={k.l}>
                    <div style={{ fontFamily: Xtype.fontMono, fontSize: 9, color: Xtok.textMuted, letterSpacing: '0.06em', textTransform: 'uppercase', fontWeight: 500 }}>{k.l}</div>
                    <div style={{ display: 'flex', alignItems: 'baseline', gap: 4, marginTop: 4 }}>
                      <div style={{ fontFamily: Xtype.fontDisplay, fontSize: 20, fontWeight: 600, letterSpacing: '-0.025em', fontVariantNumeric: 'tabular-nums', lineHeight: 1 }}>{k.v}</div>
                      {k.d && <div style={{ fontFamily: Xtype.fontMono, fontSize: 9, color: Xtok.ok }}>{k.d}</div>}
                    </div>
                  </div>
                ))}
              </div>
              <div style={{ display: 'flex', alignItems: 'center', gap: 14 }}>
                <X.NSparkline data={s.spark} color={s.c} w={100} h={32} fill />
                <X.NButton kind="ghost" theme="dark" size="sm" iconAfter={Xic.arrow}>Detalle</X.NButton>
              </div>
            </div>
          </X.NCard>
        ))}
      </div>
    </XShell>
  );
}

// ----------------------------------------------------------------------------
// Placeholder for Gomería/Eco/ICM — same shell, "coming soon" empty state
// ----------------------------------------------------------------------------
function ComingSoon({ go, title, eyebrow }) {
  return (
    <XShell active={0} go={go} breadcrumbs={[{ label: 'Coopertrans', go: 'dashboard' }, { label: title }]}>
      <div style={{ padding: '24px 24px', height: '100%', display: 'flex', flexDirection: 'column' }}>
        <X.NEyebrow style={{ color: Xtok.textMuted, opacity: 1 }}>{eyebrow}</X.NEyebrow>
        <div style={{ fontFamily: Xtype.fontDisplay, fontSize: 52, fontWeight: 600, letterSpacing: '-0.04em', lineHeight: 0.95, marginTop: 8 }}>{title}.</div>
        <div style={{ flex: 1, display: 'grid', placeItems: 'center' }}>
          <div style={{ textAlign: 'center', maxWidth: 480 }}>
            <div style={{ width: 64, height: 64, borderRadius: 16, background: Xtok.surface3, display: 'grid', placeItems: 'center', margin: '0 auto' }}>
              {Xic.box(28, Xtok.textMuted)}
            </div>
            <div style={{ fontFamily: Xtype.fontDisplay, fontSize: 22, fontWeight: 600, letterSpacing: '-0.02em', marginTop: 22 }}>
              Módulo en migración al sistema Núcleo
            </div>
            <div style={{ fontSize: 14, color: Xtok.textSecondary, marginTop: 10, lineHeight: 1.5 }}>
              Mantiene la funcionalidad actual del Flutter mientras se aplica el nuevo lenguaje visual. Esperado en la semana 2 del rollout.
            </div>
            <div style={{ marginTop: 24, display: 'flex', justifyContent: 'center', gap: 10 }}>
              <div onClick={() => go('dashboard')}><X.NButton kind="secondary" theme="dark" size="md">Volver al dashboard</X.NButton></div>
              <div onClick={() => go('servicios')}><X.NButton kind="ghost" theme="dark" size="md">Ver otros módulos</X.NButton></div>
            </div>
          </div>
        </div>
      </div>
    </XShell>
  );
}

window.DesktopModuleScreens = {
  flota: Flota,
  logistica: Logistica,
  servicios: Servicios,
  gomeria: ({ go }) => <ComingSoon go={go} title="Gomería" eyebrow="Stock · recapados · vida útil" />,
  eco:     ({ go }) => <ComingSoon go={go} title="Eco-driving" eyebrow="Volvo Connect · scores" />,
  icm:     ({ go }) => <ComingSoon go={go} title="ICM" eyebrow="Índice consumo medio" />,
};
