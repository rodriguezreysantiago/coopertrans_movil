// nucleo/screens-desktop-core.jsx
// Desktop ADMIN flow — core screens: Login · Dashboard · Personal · PersonalDetail · Vencimientos
// Uses primitives from window.NS.
// Exposes: window.DesktopCoreScreens = { login, dashboard, personal, personal_detail, vencimientos }

const D = window.NS;
const Dtok = D.tokens.color.dark;
const Dtype = D.tokens.type;
const Dr = D.tokens.radius;
const Dic = D.icons;

// ----------------------------------------------------------------------------
// SHELL — desktop chrome (topbar + optional secondary nav + content frame)
// ----------------------------------------------------------------------------
const DESKTOP_NAV = ['Inicio', 'Personal', 'Flota', 'Vencimientos', 'Logística', 'Gomería', 'Eco-D', 'ICM', 'Servicios'];
const NAV_KEYS    = ['dashboard','personal','flota','vencimientos','logistica','gomeria','eco','icm','servicios'];

function DShell({ children, active = 0, breadcrumbs, go, ambient = true }) {
  return (
    <div style={{
      width: '100%', height: '100%', background: Dtok.bg, color: Dtok.text,
      fontFamily: Dtype.fontDisplay,
      display: 'flex', flexDirection: 'column', boxSizing: 'border-box',
      position: 'relative', overflow: 'hidden',
    }}>
      {ambient && (
        <div style={{
          position: 'absolute', top: -250, left: '50%', width: 1200, height: 700,
          background: `radial-gradient(ellipse, ${Dtok.brandGlow}, transparent 60%)`,
          pointerEvents: 'none', filter: 'blur(40px)', transform: 'translateX(-50%)',
        }} />
      )}

      {/* TOP NAV */}
      <div style={{
        borderBottom: `1px solid ${Dtok.border}`,
        padding: '12px 24px',
        display: 'flex', alignItems: 'center', justifyContent: 'space-between',
        background: 'rgba(5,5,5,0.6)', backdropFilter: 'blur(10px)', zIndex: 5,
      }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 24 }}>
          <div onClick={() => go && go('dashboard')} style={{ cursor: 'pointer' }}>
            <D.NLogo size={26} theme="dark" />
          </div>
          <div style={{ display: 'flex', gap: 2 }}>
            {DESKTOP_NAV.map((s, i) => (
              <div key={s} onClick={() => go && go(NAV_KEYS[i])} style={{
                padding: '6px 11px', borderRadius: 6,
                fontSize: 13, fontWeight: 500,
                color: i === active ? Dtok.text : Dtok.textSecondary,
                background: i === active ? Dtok.surface3 : 'transparent',
                cursor: 'pointer',
              }}>{s}</div>
            ))}
          </div>
        </div>
        <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
          <div style={{
            background: Dtok.surface2, border: `1px solid ${Dtok.border}`,
            borderRadius: 8, padding: '6px 12px',
            display: 'flex', alignItems: 'center', gap: 8, minWidth: 260,
          }}>
            {Dic.search(13, Dtok.textMuted)}
            <div style={{ fontFamily: Dtype.fontMono, fontSize: 11, color: Dtok.textMuted }}>Buscar o saltar a…</div>
            <div style={{ marginLeft: 'auto', fontFamily: Dtype.fontMono, fontSize: 10, color: Dtok.textMuted, padding: '1px 5px', background: Dtok.surface3, borderRadius: 3 }}>⌘K</div>
          </div>
          <div style={{ width: 28, height: 28, borderRadius: '50%', border: `1px solid ${Dtok.borderStrong}`, display: 'grid', placeItems: 'center', fontSize: 11, fontWeight: 600 }}>SV</div>
        </div>
      </div>

      {/* BREADCRUMBS (optional) */}
      {breadcrumbs && (
        <div style={{
          padding: '8px 24px', borderBottom: `1px solid ${Dtok.border}`,
          display: 'flex', alignItems: 'center', gap: 8,
          fontFamily: Dtype.fontMono, fontSize: 11, color: Dtok.textMuted, letterSpacing: '0.04em',
          zIndex: 2,
        }}>
          {breadcrumbs.map((b, i) => (
            <React.Fragment key={i}>
              {i > 0 && <span style={{ opacity: 0.4 }}>/</span>}
              <span onClick={() => b.go && go(b.go)} style={{ color: i === breadcrumbs.length - 1 ? Dtok.text : Dtok.textMuted, cursor: b.go ? 'pointer' : 'default' }}>{b.label}</span>
            </React.Fragment>
          ))}
        </div>
      )}

      {/* CONTENT */}
      <div style={{ flex: 1, overflow: 'hidden', position: 'relative', zIndex: 1 }}>
        {children}
      </div>
    </div>
  );
}

// ----------------------------------------------------------------------------
// 00 · LOGIN (desktop)
// ----------------------------------------------------------------------------
function LoginD({ go }) {
  return (
    <div style={{
      width: '100%', height: '100%', background: Dtok.bg, color: Dtok.text,
      fontFamily: Dtype.fontDisplay,
      display: 'grid', gridTemplateColumns: '1fr 1fr', boxSizing: 'border-box',
      position: 'relative', overflow: 'hidden',
    }}>
      <div style={{ position: 'absolute', top: '40%', left: '25%', width: 800, height: 800, background: `radial-gradient(circle, ${Dtok.brandGlow}, transparent 65%)`, pointerEvents: 'none', filter: 'blur(40px)', transform: 'translate(-50%, -50%)' }} />

      {/* LEFT — pitch */}
      <div style={{ padding: '80px 80px', display: 'flex', flexDirection: 'column', justifyContent: 'space-between', zIndex: 1 }}>
        <D.NLogo size={32} theme="dark" />
        <div>
          <D.NEyebrow style={{ color: Dtok.brand, opacity: 1 }}>Panel ejecutivo · v3.0</D.NEyebrow>
          <div style={{ fontFamily: Dtype.fontDisplay, fontSize: 80, fontWeight: 600, letterSpacing: '-0.045em', lineHeight: 0.92, marginTop: 18, maxWidth: 480 }}>
            Buenas<br/>tardes.
          </div>
          <div style={{ fontSize: 15, color: Dtok.textSecondary, marginTop: 22, maxWidth: 420, lineHeight: 1.55 }}>
            Sistema interno de Coopertrans Móvil. Operativo en cabina, oficina y directorio.
          </div>
        </div>
        <div style={{ display: 'flex', gap: 24, fontFamily: Dtype.fontMono, fontSize: 11, color: Dtok.textMuted, letterSpacing: '0.04em' }}>
          <span><span style={{ color: Dtok.ok }}>●</span> 12/12 unidades</span>
          <span><span style={{ color: Dtok.brand }}>●</span> bot wa · ok</span>
          <span>uptime <span style={{ color: Dtok.text }}>99.97%</span></span>
        </div>
      </div>

      {/* RIGHT — form card */}
      <div style={{ display: 'grid', placeItems: 'center', padding: 40, zIndex: 1 }}>
        <div style={{ width: '100%', maxWidth: 380, background: Dtok.surface2, border: `1px solid ${Dtok.border}`, borderRadius: Dr.xl, padding: 36 }}>
          <D.NEyebrow style={{ color: Dtok.textMuted, opacity: 1 }}>Acceso</D.NEyebrow>
          <div style={{ fontFamily: Dtype.fontDisplay, fontSize: 30, fontWeight: 600, letterSpacing: '-0.03em', marginTop: 8 }}>Ingresá a tu cuenta.</div>
          <div style={{ marginTop: 24, display: 'flex', flexDirection: 'column', gap: 10 }}>
            <D.NInput theme="dark" label="DNI" value="31.415.926" mono />
            <D.NInput theme="dark" label="Contraseña" value="••••••••" mono action="ver" focused />
            <div style={{ marginTop: 12 }} onClick={() => go('dashboard')}>
              <D.NButton kind="primary" size="lg" theme="dark" full iconAfter={Dic.arrow}>Ingresar</D.NButton>
            </div>
          </div>
          <div style={{ marginTop: 24, paddingTop: 18, borderTop: `1px solid ${Dtok.border}`, fontFamily: Dtype.fontMono, fontSize: 10, color: Dtok.textMuted, display: 'flex', justifyContent: 'space-between' }}>
            <span>v3.0.0</span>
            <span>¿olvidaste tu clave?</span>
          </div>
        </div>
      </div>
    </div>
  );
}

// ----------------------------------------------------------------------------
// 01 · DASHBOARD
// ----------------------------------------------------------------------------
function Dashboard({ go }) {
  const chart = [82, 96, 110, 95, 124, 132, 142, 138];
  const max = 150;

  return (
    <DShell active={0} go={go}>
      {/* live ticker */}
      <div style={{
        padding: '7px 24px', borderBottom: `1px solid ${Dtok.border}`,
        display: 'flex', gap: 22, fontFamily: Dtype.fontMono, fontSize: 10.5, color: Dtok.textMuted, letterSpacing: '0.04em', alignItems: 'center',
      }}>
        <span style={{ color: Dtok.brand, fontWeight: 600 }}>● ops live</span>
        <span>units <span style={{ color: Dtok.text }}>12/12</span></span>
        <span>on-route <span style={{ color: Dtok.brand }}>5</span></span>
        <span>idle <span style={{ color: Dtok.textMuted }}>2</span></span>
        <span>bot wa <span style={{ color: Dtok.ok }}>OK 12s</span></span>
        <span>volvo <span style={{ color: Dtok.warn }}>WARN +6m</span></span>
        <span style={{ marginLeft: 'auto', color: Dtok.text }}>vie 01 jun · 14:32:08</span>
      </div>

      <div style={{ padding: '28px 24px', display: 'flex', flexDirection: 'column', gap: 18, height: 'calc(100% - 32px)', overflow: 'hidden' }}>
        {/* HERO */}
        <div style={{ display: 'flex', alignItems: 'flex-end', justifyContent: 'space-between' }}>
          <div>
            <D.NEyebrow style={{ color: Dtok.textMuted, opacity: 1 }}>Vie 1 jun · 14:32</D.NEyebrow>
            <div style={{ fontFamily: Dtype.fontDisplay, fontSize: 52, fontWeight: 600, letterSpacing: '-0.04em', lineHeight: 0.95, marginTop: 8 }}>
              Hola Santiago.
            </div>
          </div>
          <D.NSegmented theme="dark" options={['Hoy','7d','30d','90d']} active={2} />
        </div>

        {/* BENTO */}
        <div style={{ flex: 1, display: 'grid', gridTemplateColumns: 'repeat(12, 1fr)', gap: 12, gridAutoRows: 'auto' }}>
          {/* URGENT */}
          <D.NCard theme="dark" style={{ gridColumn: 'span 8' }} padded={false}>
            <div style={{ padding: '22px 26px', display: 'flex', alignItems: 'flex-end', justifyContent: 'space-between', gap: 20 }}>
              <div>
                <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                  {Dic.alert(14, Dtok.crit)}
                  <D.NEyebrow style={{ color: Dtok.crit, opacity: 1 }}>Urgente · 3 items</D.NEyebrow>
                </div>
                <div style={{ fontFamily: Dtype.fontDisplay, fontSize: 22, fontWeight: 500, marginTop: 10, letterSpacing: '-0.02em', lineHeight: 1.3, maxWidth: 520 }}>
                  Tenés <span style={{ color: Dtok.crit }}>7 papeles vencidos</span>, <span style={{ color: Dtok.warn }}>3 trámites</span> esperando revisión, y <span style={{ color: Dtok.warn }}>12 vencimientos</span> en los próximos 7 días.
                </div>
              </div>
              <div onClick={() => go('vencimientos')}>
                <D.NButton kind="secondary" theme="dark" size="md" iconAfter={Dic.arrow}>Abrir</D.NButton>
              </div>
            </div>
          </D.NCard>

          {/* AI ASSIST */}
          <D.NCard theme="dark" style={{ gridColumn: 'span 4' }} padded={false}>
            <div style={{ padding: '20px 22px', display: 'flex', flexDirection: 'column', gap: 10, position: 'relative', overflow: 'hidden' }}>
              <div style={{ position: 'absolute', top: -40, right: -40, width: 200, height: 200, background: `radial-gradient(circle, ${Dtok.brandGlow}, transparent 65%)` }} />
              <div style={{ display: 'flex', alignItems: 'center', gap: 8, position: 'relative' }}>
                {Dic.sparkle(14, Dtok.brand)}
                <D.NEyebrow style={{ color: Dtok.brand, opacity: 1 }}>Asistente</D.NEyebrow>
              </div>
              <div style={{ fontSize: 13.5, color: Dtok.text, lineHeight: 1.4, position: 'relative' }}>
                "¿Cuál chofer tuvo más alertas de Volvo este mes?"
              </div>
              <div style={{ marginTop: 4, paddingTop: 10, borderTop: `1px solid ${Dtok.border}`, fontFamily: Dtype.fontMono, fontSize: 11, color: Dtok.textMuted, position: 'relative' }}>
                Preguntale a la app cualquier cosa.
              </div>
            </div>
          </D.NCard>

          {/* KPI STRIP */}
          <D.NCard theme="dark" style={{ gridColumn: 'span 12' }} padded={false}>
            <div style={{ display: 'grid', gridTemplateColumns: 'repeat(5, 1fr)' }}>
              {[
                { l: 'Viajes 30d', v: '142', d: '+8.0%', dc: Dtok.ok, s: [82, 96, 110, 95, 124, 132, 142, 138] },
                { l: 'Eficiencia', v: '2.41', u: 'km/L', d: '+3.2%', dc: Dtok.ok, s: [2.2, 2.3, 2.35, 2.3, 2.4, 2.41, 2.41, 2.41] },
                { l: 'ICM flota', v: '87', d: '−2.1', dc: Dtok.warn, s: [89, 88, 88, 89, 88, 87, 87, 87] },
                { l: 'Alertas', v: '14', d: '−5', dc: Dtok.ok, s: [22, 18, 20, 19, 16, 14, 14, 14] },
                { l: 'Mantenim.', v: '3', u: 'abiertos', d: '—', dc: Dtok.textMuted, s: [4, 5, 3, 3, 4, 3, 3, 3] },
              ].map((k, i) => (
                <div key={k.l} style={{ padding: '18px 22px', borderRight: i < 4 ? `1px solid ${Dtok.border}` : 'none' }}>
                  <D.NEyebrow style={{ color: Dtok.textMuted, opacity: 1 }}>{k.l}</D.NEyebrow>
                  <div style={{ display: 'flex', alignItems: 'baseline', gap: 5, marginTop: 6 }}>
                    <div style={{ fontFamily: Dtype.fontDisplay, fontSize: 40, fontWeight: 600, letterSpacing: '-0.04em', lineHeight: 1, fontVariantNumeric: 'tabular-nums' }}>{k.v}</div>
                    {k.u && <div style={{ fontFamily: Dtype.fontMono, fontSize: 11, color: Dtok.textMuted }}>{k.u}</div>}
                  </div>
                  <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginTop: 6 }}>
                    <div style={{ fontFamily: Dtype.fontMono, fontSize: 11, color: k.dc, fontWeight: 500 }}>{k.d}</div>
                    <D.NSparkline data={k.s} color={k.dc} w={90} h={22} />
                  </div>
                </div>
              ))}
            </div>
          </D.NCard>

          {/* CHART */}
          <D.NCard theme="dark" style={{ gridColumn: 'span 8' }} padded={false}>
            <div style={{ padding: '20px 24px', display: 'flex', flexDirection: 'column', gap: 12 }}>
              <div style={{ display: 'flex', alignItems: 'flex-end', justifyContent: 'space-between' }}>
                <div>
                  <D.NEyebrow style={{ color: Dtok.textMuted, opacity: 1 }}>Viajes por semana · S15 → S22</D.NEyebrow>
                  <div style={{ display: 'flex', alignItems: 'baseline', gap: 12, marginTop: 6 }}>
                    <div style={{ fontFamily: Dtype.fontDisplay, fontSize: 56, fontWeight: 600, letterSpacing: '-0.04em', lineHeight: 0.9, fontVariantNumeric: 'tabular-nums' }}>142</div>
                    <div style={{ fontFamily: Dtype.fontMono, fontSize: 13, color: Dtok.ok }}>+8.0%</div>
                  </div>
                </div>
                <div style={{ fontFamily: Dtype.fontMono, fontSize: 10.5, color: Dtok.textMuted, textAlign: 'right' }}>
                  <div>min · <span style={{ color: Dtok.text }}>82</span></div>
                  <div>avg · <span style={{ color: Dtok.text }}>115</span></div>
                  <div>max · <span style={{ color: Dtok.text }}>142</span></div>
                </div>
              </div>
              <D.NAreaChart data={chart} labels={['S15','S16','S17','S18','S19','S20','S21','S22']} color={Dtok.brand} theme="dark" height={130} />
            </div>
          </D.NCard>

          {/* SERVICES */}
          <D.NCard theme="dark" style={{ gridColumn: 'span 4' }} padded={false}>
            <div style={{ padding: '16px 18px', borderBottom: `1px solid ${Dtok.border}`, display: 'flex', justifyContent: 'space-between' }}>
              <D.NEyebrow style={{ color: Dtok.textMuted, opacity: 1 }}>Servicios externos</D.NEyebrow>
              <div style={{ fontFamily: Dtype.fontMono, fontSize: 10, color: Dtok.ok, fontWeight: 500 }}>● 3 ok · 1 lag</div>
            </div>
            {[
              { n: 'Bot WhatsApp', d: 'pulso 12s · 6 destinos', c: Dtok.ok, m: 'OK' },
              { n: 'Cachatore', d: '4 turnos pend.', c: Dtok.ok, m: 'OK' },
              { n: 'Sitrack', d: 'sync 2m', c: Dtok.ok, m: 'OK' },
              { n: 'Volvo API', d: 'driver · scores', c: Dtok.warn, m: 'LAG 6m' },
            ].map((s, i) => (
              <div key={s.n} onClick={() => go('servicios')} style={{
                padding: '12px 18px', borderTop: i ? `1px solid ${Dtok.border}` : 'none',
                display: 'grid', gridTemplateColumns: '8px 1fr auto', gap: 12, alignItems: 'center', cursor: 'pointer',
              }}>
                <D.NDot color={s.c} size={6} glow />
                <div>
                  <div style={{ fontSize: 13, fontWeight: 500 }}>{s.n}</div>
                  <div style={{ fontFamily: Dtype.fontMono, fontSize: 10, color: Dtok.textMuted, marginTop: 1 }}>{s.d}</div>
                </div>
                <div style={{ fontFamily: Dtype.fontMono, fontSize: 10, color: s.c, fontWeight: 500 }}>{s.m}</div>
              </div>
            ))}
          </D.NCard>
        </div>
      </div>
    </DShell>
  );
}

// ----------------------------------------------------------------------------
// 02 · PERSONAL (list)
// ----------------------------------------------------------------------------
function Personal({ go }) {
  const people = [
    { id: 'sv', n: 'Santiago Vecchi',  rol: 'Chofer',    leg: '31415926', un: 'VOL-187', st: { l: 'Activo',         c: Dtok.ok }, alert: null },
    { id: 'mr', n: 'Martín Ruiz',      rol: 'Chofer',    leg: '28194726', un: 'VOL-204', st: { l: 'En ruta',        c: Dtok.brand }, alert: { l: 'ART · 7d', c: Dtok.warn } },
    { id: 'jp', n: 'Juan Pereyra',     rol: 'Chofer',    leg: '24881932', un: 'VOL-219', st: { l: 'Activo',         c: Dtok.ok }, alert: null },
    { id: 'dl', n: 'Daniel Lobos',     rol: 'Chofer',    leg: '31888041', un: 'SCN-302', st: { l: 'Activo',         c: Dtok.ok }, alert: { l: 'Licencia · venc.', c: Dtok.crit } },
    { id: 'fa', n: 'Federico Aguirre', rol: 'Chofer',    leg: '29772084', un: 'IVE-401', st: { l: 'En ruta',        c: Dtok.brand }, alert: null },
    { id: 'pm', n: 'Pablo Méndez',     rol: 'Chofer',    leg: '32910844', un: 'IVE-410', st: { l: 'En descanso',    c: Dtok.textMuted }, alert: null },
    { id: 'ci', n: 'Carlos Ibáñez',    rol: 'Chofer',    leg: '27044912', un: 'VOL-225', st: { l: 'En ruta',        c: Dtok.brand }, alert: null },
    { id: 'ng', n: 'Norberto González',rol: 'Taller',    leg: '22338721', un: '—',       st: { l: 'Activo',         c: Dtok.ok }, alert: null },
    { id: 'ma', n: 'Mauro Alonso',     rol: 'Logística', leg: '30441288', un: '—',       st: { l: 'Activo',         c: Dtok.ok }, alert: null },
    { id: 'rr', n: 'Romina Ramírez',   rol: 'RRHH',      leg: '29107466', un: '—',       st: { l: 'Activo',         c: Dtok.ok }, alert: null },
  ];

  return (
    <DShell active={1} go={go} breadcrumbs={[{ label: 'Coopertrans', go: 'dashboard' }, { label: 'Personal' }]}>
      <div style={{ padding: '24px 24px', display: 'flex', flexDirection: 'column', gap: 18, height: 'calc(100% - 0px)', overflow: 'hidden' }}>
        {/* hero */}
        <div style={{ display: 'flex', alignItems: 'flex-end', justifyContent: 'space-between' }}>
          <div>
            <D.NEyebrow style={{ color: Dtok.textMuted, opacity: 1 }}>Equipo</D.NEyebrow>
            <div style={{ display: 'flex', alignItems: 'baseline', gap: 14, marginTop: 6 }}>
              <div style={{ fontFamily: Dtype.fontDisplay, fontSize: 56, fontWeight: 600, letterSpacing: '-0.04em', lineHeight: 0.9, fontVariantNumeric: 'tabular-nums' }}>32</div>
              <div style={{ fontFamily: Dtype.fontMono, fontSize: 13, color: Dtok.textMuted }}>activos</div>
              <div style={{ fontFamily: Dtype.fontMono, fontSize: 11, color: Dtok.warn, marginLeft: 8 }}>● 2 con alertas</div>
            </div>
          </div>
          <div style={{ display: 'flex', gap: 10 }}>
            <D.NButton kind="ghost" theme="dark" size="md" icon={Dic.filter}>Filtros</D.NButton>
            <D.NButton kind="ghost" theme="dark" size="md" icon={Dic.download}>Exportar</D.NButton>
            <D.NButton kind="primary" theme="dark" size="md" icon={Dic.plus}>Nuevo</D.NButton>
          </div>
        </div>

        {/* filter chips */}
        <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
          {[
            { l: 'Todos', n: 32, a: true },
            { l: 'Choferes', n: 18 },
            { l: 'Taller', n: 4 },
            { l: 'Logística', n: 6 },
            { l: 'Administración', n: 4 },
            { l: 'Con alertas', n: 2, c: Dtok.warn },
          ].map(c => (
            <div key={c.l} style={{
              padding: '5px 11px', borderRadius: 999,
              background: c.a ? Dtok.text : 'transparent',
              color: c.a ? Dtok.bg : (c.c || Dtok.textSecondary),
              fontSize: 11.5, fontWeight: 600,
              border: c.a ? 'none' : `1px solid ${c.c ? c.c + '40' : Dtok.border}`,
              display: 'flex', gap: 6, cursor: 'pointer',
            }}>{c.l} <span style={{ opacity: 0.6 }}>{c.n}</span></div>
          ))}
        </div>

        {/* TABLE */}
        <div style={{ flex: 1, background: Dtok.surface2, border: `1px solid ${Dtok.border}`, borderRadius: Dr.lg, overflow: 'hidden', display: 'flex', flexDirection: 'column' }}>
          {/* header */}
          <div style={{
            display: 'grid', gridTemplateColumns: '2fr 1fr 1fr 1fr 1fr 40px',
            padding: '12px 20px', borderBottom: `1px solid ${Dtok.border}`,
            fontFamily: Dtype.fontMono, fontSize: 10, color: Dtok.textMuted, letterSpacing: '0.08em', textTransform: 'uppercase', fontWeight: 500,
            background: Dtok.surface1,
          }}>
            <div>Persona</div>
            <div>Rol</div>
            <div>Legajo</div>
            <div>Unidad</div>
            <div>Estado</div>
            <div></div>
          </div>
          <div style={{ flex: 1, overflow: 'hidden' }}>
            {people.map((p, i) => (
              <div key={p.id} onClick={() => go('personal_detail', { id: p.id })} style={{
                display: 'grid', gridTemplateColumns: '2fr 1fr 1fr 1fr 1fr 40px',
                padding: '13px 20px', borderTop: i ? `1px solid ${Dtok.border}` : 'none',
                alignItems: 'center', cursor: 'pointer',
              }}>
                <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
                  <div style={{
                    width: 32, height: 32, borderRadius: '50%',
                    background: p.id === 'sv' ? Dtok.brand : Dtok.surface3,
                    color: p.id === 'sv' ? Dtok.brandFg : Dtok.text,
                    display: 'grid', placeItems: 'center',
                    fontSize: 11, fontWeight: 600,
                  }}>{p.n.split(' ').map(w => w[0]).slice(0, 2).join('')}</div>
                  <div>
                    <div style={{ fontSize: 13.5, fontWeight: 500 }}>{p.n}</div>
                    {p.alert && <div style={{ fontFamily: Dtype.fontMono, fontSize: 10, color: p.alert.c, marginTop: 2 }}>● {p.alert.l}</div>}
                  </div>
                </div>
                <div style={{ fontSize: 13, color: Dtok.textSecondary }}>{p.rol}</div>
                <div style={{ fontFamily: Dtype.fontMono, fontSize: 12, color: Dtok.textSecondary, fontVariantNumeric: 'tabular-nums' }}>{p.leg}</div>
                <div style={{ fontFamily: Dtype.fontMono, fontSize: 12, color: Dtok.text, fontVariantNumeric: 'tabular-nums' }}>{p.un}</div>
                <div>
                  <D.NBadge theme="dark" color={p.st.c} dot size="sm">{p.st.l}</D.NBadge>
                </div>
                <div style={{ display: 'grid', placeItems: 'center' }}>{Dic.chevronRight(13, Dtok.textMuted)}</div>
              </div>
            ))}
          </div>
        </div>
      </div>
    </DShell>
  );
}

// ----------------------------------------------------------------------------
// 03 · PERSONAL DETAIL (full-page drawer)
// ----------------------------------------------------------------------------
function PersonalDetail({ go }) {
  return (
    <DShell active={1} go={go} breadcrumbs={[{ label: 'Coopertrans', go: 'dashboard' }, { label: 'Personal', go: 'personal' }, { label: 'Santiago Vecchi' }]}>
      <div style={{ padding: '24px 24px', display: 'grid', gridTemplateColumns: '320px 1fr', gap: 20, height: '100%', boxSizing: 'border-box', overflow: 'hidden' }}>
        {/* LEFT identity card */}
        <div style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
          <D.NCard theme="dark" padded={24}>
            <div style={{
              width: 72, height: 72, borderRadius: 18,
              background: `linear-gradient(135deg, ${Dtok.brand}, ${Dtok.brandDark})`,
              display: 'grid', placeItems: 'center',
              fontFamily: Dtype.fontDisplay, fontSize: 28, fontWeight: 600, color: Dtok.brandFg,
              boxShadow: `0 0 40px ${Dtok.brandGlow}`,
            }}>SV</div>
            <div style={{ fontFamily: Dtype.fontDisplay, fontSize: 26, fontWeight: 600, letterSpacing: '-0.025em', lineHeight: 1.1, marginTop: 16 }}>
              Santiago<br/>Vecchi
            </div>
            <div style={{ display: 'flex', gap: 6, marginTop: 12, flexWrap: 'wrap' }}>
              <D.NBadge theme="dark" color={Dtok.ok} dot size="sm">Activo</D.NBadge>
              <D.NBadge theme="dark" color={Dtok.brand} size="sm">Chofer</D.NBadge>
              <D.NBadge theme="dark" color={Dtok.text} size="sm">11 años</D.NBadge>
            </div>
            <div style={{ marginTop: 16, paddingTop: 14, borderTop: `1px solid ${Dtok.border}` }}>
              {[
                ['Legajo', '31415926', true],
                ['DNI', '31.415.926', true],
                ['Teléfono', '+54 291 415-6926', true],
                ['Mail', 'svecchi@coopertrans.coop', false],
                ['Domicilio', 'Av. Colón 1234', false],
                ['Ingreso', '11 mar 2015', false],
              ].map(([l, v, mono]) => (
                <div key={l} style={{ padding: '8px 0', display: 'flex', justifyContent: 'space-between', gap: 14 }}>
                  <div style={{ fontFamily: Dtype.fontMono, fontSize: 10, color: Dtok.textMuted, letterSpacing: '0.06em', textTransform: 'uppercase' }}>{l}</div>
                  <div style={{ fontFamily: mono ? Dtype.fontMono : Dtype.fontDisplay, fontSize: 12, color: Dtok.text, fontVariantNumeric: 'tabular-nums' }}>{v}</div>
                </div>
              ))}
            </div>
          </D.NCard>
          <div style={{ display: 'flex', gap: 8 }}>
            <div style={{ flex: 1 }}><D.NButton kind="ghost" theme="dark" size="md" full icon={Dic.whatsapp}>WhatsApp</D.NButton></div>
            <div style={{ flex: 1 }}><D.NButton kind="ghost" theme="dark" size="md" full icon={Dic.phone}>Llamar</D.NButton></div>
          </div>
        </div>

        {/* RIGHT content */}
        <div style={{ display: 'flex', flexDirection: 'column', gap: 16, overflow: 'hidden' }}>
          {/* stats strip */}
          <D.NCard theme="dark" padded={false}>
            <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)' }}>
              {[
                { l: 'Viajes 30d', v: '24', d: '+8%', dc: Dtok.ok },
                { l: 'Km recorridos', v: '6.8k', d: '+11%', dc: Dtok.ok },
                { l: 'Eco-driving', v: '91', d: '+3', dc: Dtok.ok },
                { l: 'Alertas Volvo', v: '2', d: '−4', dc: Dtok.ok },
              ].map((k, i) => (
                <div key={k.l} style={{ padding: '18px 22px', borderRight: i < 3 ? `1px solid ${Dtok.border}` : 'none' }}>
                  <D.NEyebrow style={{ color: Dtok.textMuted, opacity: 1 }}>{k.l}</D.NEyebrow>
                  <div style={{ display: 'flex', alignItems: 'baseline', gap: 6, marginTop: 6 }}>
                    <div style={{ fontFamily: Dtype.fontDisplay, fontSize: 36, fontWeight: 600, letterSpacing: '-0.04em', lineHeight: 1, fontVariantNumeric: 'tabular-nums' }}>{k.v}</div>
                    <div style={{ fontFamily: Dtype.fontMono, fontSize: 11, color: k.dc, fontWeight: 500, marginLeft: 'auto' }}>{k.d}</div>
                  </div>
                </div>
              ))}
            </div>
          </D.NCard>

          {/* vencimientos */}
          <D.NCard theme="dark" padded={false}>
            <div style={{ padding: '16px 22px', borderBottom: `1px solid ${Dtok.border}`, display: 'flex', justifyContent: 'space-between', alignItems: 'baseline' }}>
              <D.NEyebrow style={{ color: Dtok.textMuted, opacity: 1 }}>Vencimientos</D.NEyebrow>
              <div style={{ fontFamily: Dtype.fontMono, fontSize: 10, color: Dtok.textMuted }}>6 items · 1 próx · 4 al día</div>
            </div>
            {[
              { l: 'ART · Provincia',           c: Dtok.warn, d: 23, date: '14·06' },
              { l: 'Licencia profesional',      c: Dtok.ok,   d: 103, date: '02·09' },
              { l: 'Psicofísico CNRT',          c: Dtok.ok,   d: 103, date: '02·09' },
              { l: 'Curso CNRT',                c: Dtok.ok,   d: 174, date: '12·11' },
              { l: 'Antecedentes',              c: Dtok.crit, d: -23, date: '08·05' },
              { l: 'Análisis clínicos',         c: Dtok.ok,   d: 49,  date: '20·07' },
            ].map((v, i) => (
              <div key={i} style={{ padding: '10px 22px', borderTop: i ? `1px solid ${Dtok.border}` : 'none', display: 'grid', gridTemplateColumns: '12px 1fr auto auto', gap: 14, alignItems: 'center' }}>
                <D.NDot color={v.c} size={7} />
                <div style={{ fontSize: 13 }}>{v.l}</div>
                <div style={{ fontFamily: Dtype.fontMono, fontSize: 11, color: Dtok.textMuted, letterSpacing: '0.04em' }}>{v.date}</div>
                <div style={{ fontFamily: Dtype.fontMono, fontSize: 12, color: v.c, fontVariantNumeric: 'tabular-nums', fontWeight: 600, minWidth: 40, textAlign: 'right' }}>{v.d < 0 ? `${Math.abs(v.d)}d` : `${v.d}d`}</div>
              </div>
            ))}
          </D.NCard>

          {/* activity */}
          <D.NCard theme="dark" padded={false} style={{ flex: 1 }}>
            <div style={{ padding: '16px 22px', borderBottom: `1px solid ${Dtok.border}` }}>
              <D.NEyebrow style={{ color: Dtok.textMuted, opacity: 1 }}>Actividad reciente</D.NEyebrow>
            </div>
            {[
              { t: 'hoy 14:08', e: 'Cambio de turno · iButton ok', c: Dtok.brand },
              { t: 'hoy 06:50', e: 'Pre-viaje · checklist completo', c: Dtok.ok },
              { t: 'jue', e: 'Liquidación quincena 1 acreditada', c: Dtok.ok },
              { t: 'lun', e: 'Subió comprobante VTV', c: Dtok.text },
            ].map((row, i) => (
              <div key={i} style={{ padding: '11px 22px', display: 'grid', gridTemplateColumns: '60px 12px 1fr', gap: 12, borderTop: i ? `1px solid ${Dtok.border}` : 'none', alignItems: 'center' }}>
                <div style={{ fontFamily: Dtype.fontMono, fontSize: 10, color: Dtok.textMuted, letterSpacing: '0.04em' }}>{row.t}</div>
                <D.NDot color={row.c} size={6} />
                <div style={{ fontSize: 13 }}>{row.e}</div>
              </div>
            ))}
          </D.NCard>
        </div>
      </div>
    </DShell>
  );
}

// ----------------------------------------------------------------------------
// 04 · VENCIMIENTOS (table)
// ----------------------------------------------------------------------------
function VencimientosD({ go }) {
  const rows = [
    { p: 'Daniel Lobos',    rol: 'Chofer', t: 'Antecedentes',          d: -23, date: '08·05·25', c: Dtok.crit },
    { p: 'Pablo Méndez',    rol: 'Chofer', t: 'Licencia profesional',   d: -18, date: '14·05·25', c: Dtok.crit },
    { p: 'IVE-410',         rol: 'Unidad', t: 'RTO / CNRT',             d: -8,  date: '24·05·25', c: Dtok.crit },
    { p: 'Martín Ruiz',     rol: 'Chofer', t: 'ART',                    d: 7,   date: '08·06·26', c: Dtok.warn },
    { p: 'Santiago Vecchi', rol: 'Chofer', t: 'ART',                    d: 23,  date: '14·06·26', c: Dtok.warn },
    { p: 'SCN-318',         rol: 'Unidad', t: 'Seguro RC · La Caja',    d: 30,  date: '01·07·26', c: Dtok.warn },
    { p: 'Federico Aguirre',rol: 'Chofer', t: 'Psicofísico',            d: 45,  date: '16·07·26', c: Dtok.ok },
    { p: 'Carlos Ibáñez',   rol: 'Chofer', t: 'Análisis clínicos',      d: 49,  date: '20·07·26', c: Dtok.ok },
    { p: 'VOL-187',         rol: 'Unidad', t: 'VTV',                    d: 72,  date: '12·08·26', c: Dtok.ok },
    { p: 'Juan Pereyra',    rol: 'Chofer', t: 'Licencia profesional',   d: 89,  date: '29·08·26', c: Dtok.ok },
    { p: 'Santiago Vecchi', rol: 'Chofer', t: 'Licencia profesional',   d: 103, date: '02·09·26', c: Dtok.ok },
  ];

  return (
    <DShell active={3} go={go} breadcrumbs={[{ label: 'Coopertrans', go: 'dashboard' }, { label: 'Vencimientos' }]}>
      <div style={{ padding: '24px 24px', display: 'flex', flexDirection: 'column', gap: 18, height: '100%', boxSizing: 'border-box', overflow: 'hidden' }}>
        {/* hero */}
        <div style={{ display: 'flex', alignItems: 'flex-end', justifyContent: 'space-between' }}>
          <div>
            <D.NEyebrow style={{ color: Dtok.textMuted, opacity: 1 }}>Próximos 90 días</D.NEyebrow>
            <div style={{ fontFamily: Dtype.fontDisplay, fontSize: 52, fontWeight: 600, letterSpacing: '-0.04em', lineHeight: 0.95, marginTop: 8 }}>
              Vencimientos.
            </div>
          </div>
          <div style={{ display: 'flex', gap: 10 }}>
            <D.NSegmented theme="dark" options={['Lista','Calendario']} active={0} />
            <D.NButton kind="ghost" theme="dark" size="md" icon={Dic.download}>Exportar</D.NButton>
          </div>
        </div>

        {/* summary strip */}
        <D.NCard theme="dark" padded={false}>
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)' }}>
            {[
              { l: 'Vencidos', v: '7', c: Dtok.crit, sub: 'requieren acción' },
              { l: 'Próx. 7d', v: '3', c: Dtok.warn, sub: 'preparar renovación' },
              { l: 'Próx. 30d', v: '12', c: Dtok.warn, sub: 'avisar al equipo' },
              { l: 'Próx. 90d', v: '28', c: Dtok.ok, sub: 'al día' },
            ].map((s, i) => (
              <div key={s.l} style={{ padding: '20px 22px', borderRight: i < 3 ? `1px solid ${Dtok.border}` : 'none' }}>
                <D.NEyebrow style={{ color: s.c, opacity: 1 }}>{s.l}</D.NEyebrow>
                <div style={{ fontFamily: Dtype.fontDisplay, fontSize: 48, fontWeight: 600, color: s.c, letterSpacing: '-0.04em', lineHeight: 0.95, fontVariantNumeric: 'tabular-nums', marginTop: 6 }}>{s.v}</div>
                <div style={{ fontFamily: Dtype.fontMono, fontSize: 10.5, color: Dtok.textMuted, marginTop: 4, letterSpacing: '0.04em' }}>{s.sub}</div>
              </div>
            ))}
          </div>
        </D.NCard>

        {/* filters */}
        <div style={{ display: 'flex', gap: 6 }}>
          {[
            { l: 'Todo', n: 50, a: true },
            { l: 'Personal', n: 38 },
            { l: 'Unidades', n: 12 },
            { l: 'ART', n: 14 },
            { l: 'Licencias', n: 8 },
            { l: 'CNRT', n: 6 },
            { l: 'Seguros', n: 4 },
          ].map(c => (
            <div key={c.l} style={{
              padding: '5px 11px', borderRadius: 999,
              background: c.a ? Dtok.text : 'transparent',
              color: c.a ? Dtok.bg : Dtok.textSecondary,
              fontSize: 11.5, fontWeight: 600,
              border: c.a ? 'none' : `1px solid ${Dtok.border}`,
              display: 'flex', gap: 6, cursor: 'pointer',
            }}>{c.l} <span style={{ opacity: 0.6 }}>{c.n}</span></div>
          ))}
        </div>

        {/* TABLE */}
        <div style={{ flex: 1, background: Dtok.surface2, border: `1px solid ${Dtok.border}`, borderRadius: Dr.lg, overflow: 'hidden', display: 'flex', flexDirection: 'column' }}>
          <div style={{
            display: 'grid', gridTemplateColumns: '2fr 1fr 2fr 1fr 1fr 40px',
            padding: '12px 20px', borderBottom: `1px solid ${Dtok.border}`,
            fontFamily: Dtype.fontMono, fontSize: 10, color: Dtok.textMuted, letterSpacing: '0.08em', textTransform: 'uppercase', fontWeight: 500,
            background: Dtok.surface1,
          }}>
            <div>Sujeto</div>
            <div>Tipo</div>
            <div>Documento</div>
            <div>Vence</div>
            <div style={{ textAlign: 'right' }}>Plazo</div>
            <div></div>
          </div>
          <div style={{ flex: 1, overflow: 'hidden' }}>
            {rows.map((r, i) => (
              <div key={i} onClick={() => go(r.rol === 'Chofer' ? 'personal_detail' : 'flota')} style={{
                display: 'grid', gridTemplateColumns: '2fr 1fr 2fr 1fr 1fr 40px',
                padding: '12px 20px', borderTop: i ? `1px solid ${Dtok.border}` : 'none',
                alignItems: 'center', cursor: 'pointer', gap: 8,
              }}>
                <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
                  <D.NDot color={r.c} size={7} glow={r.d < 30 && r.d > -100} />
                  <div style={{ fontSize: 13, fontWeight: 500 }}>{r.p}</div>
                </div>
                <div style={{ fontSize: 12, color: Dtok.textSecondary }}>{r.rol}</div>
                <div style={{ fontSize: 13, color: Dtok.text }}>{r.t}</div>
                <div style={{ fontFamily: Dtype.fontMono, fontSize: 11.5, color: Dtok.textSecondary, fontVariantNumeric: 'tabular-nums' }}>{r.date}</div>
                <div style={{ fontFamily: Dtype.fontMono, fontSize: 12.5, color: r.c, fontVariantNumeric: 'tabular-nums', fontWeight: 600, textAlign: 'right' }}>{r.d < 0 ? `vencido ${Math.abs(r.d)}d` : `${r.d}d`}</div>
                <div style={{ display: 'grid', placeItems: 'center' }}>{Dic.chevronRight(13, Dtok.textMuted)}</div>
              </div>
            ))}
          </div>
        </div>
      </div>
    </DShell>
  );
}

window.DesktopCoreScreens = {
  login: LoginD,
  dashboard: Dashboard,
  personal: Personal,
  personal_detail: PersonalDetail,
  vencimientos: VencimientosD,
};
window.DShell = DShell;
