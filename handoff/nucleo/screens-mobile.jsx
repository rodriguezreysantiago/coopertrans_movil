// nucleo/screens-mobile.jsx
// Prototipo Coopertrans — flujo CHOFER (móvil oscuro).
// Pantallas: Splash · Login · Home · Perfil · VencList · VencDetail · Unidad · Notifs
//
// Cada pantalla recibe { go } para navegar y, opcionalmente, datos.
// Uses primitives from window.NS.
// Exposes: window.MobileScreens = { splash, login, home, perfil, venc_list, venc_detail, unidad, notifs }

const M = window.NS;
const Mtok = M.tokens.color.dark;
const Mtype = M.tokens.type;
const Mr = M.tokens.radius;
const Mic = M.icons;

// ----------------------------------------------------------------------------
// SHELL — common phone shell with status bar + nav back/title bar
// ----------------------------------------------------------------------------
function Shell({ children, title, onBack, right, glow = true }) {
  return (
    <div style={{
      width: '100%', height: '100%', background: Mtok.bg, color: Mtok.text,
      fontFamily: Mtype.fontDisplay,
      display: 'flex', flexDirection: 'column', boxSizing: 'border-box',
      position: 'relative', overflow: 'hidden',
    }}>
      {glow && <M.NAmbient color={Mtok.brand} x="50%" y="-10%" size={600} intensity={0.18} />}
      {/* status bar */}
      <div style={{ padding: '14px 22px 0', display: 'flex', justifyContent: 'space-between', fontFamily: Mtype.fontMono, fontSize: 11, fontVariantNumeric: 'tabular-nums', color: Mtok.text, zIndex: 5 }}>
        <span>14:32</span>
        <span style={{ display: 'flex', gap: 10 }}><span>5G</span><span>97%</span></span>
      </div>
      {/* nav bar */}
      {(onBack || title || right) && (
        <div style={{ padding: '12px 18px 4px', display: 'flex', alignItems: 'center', gap: 10, zIndex: 5 }}>
          {onBack && (
            <div onClick={onBack} style={{ width: 36, height: 36, borderRadius: 8, display: 'grid', placeItems: 'center', cursor: 'pointer', background: Mtok.surface2, border: `1px solid ${Mtok.border}` }}>
              {Mic.chevronLeft(18, Mtok.text)}
            </div>
          )}
          {title && (
            <div style={{ flex: 1, fontFamily: Mtype.fontDisplay, fontSize: 16, fontWeight: 600, color: Mtok.text, letterSpacing: '-0.01em' }}>{title}</div>
          )}
          {right}
        </div>
      )}
      {children}
    </div>
  );
}

// ----------------------------------------------------------------------------
// 01 · SPLASH
// ----------------------------------------------------------------------------
function Splash({ go }) {
  return (
    <Shell>
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', gap: 24, zIndex: 1 }}>
        <div style={{
          width: 72, height: 72, borderRadius: 18, background: Mtok.brand,
          display: 'grid', placeItems: 'center',
          fontFamily: Mtype.fontDisplay, fontSize: 42, fontWeight: 700, color: Mtok.brandFg,
          boxShadow: `0 0 60px ${Mtok.brandGlow}, 0 0 120px ${Mtok.brandGlow}`,
        }}>C</div>
        <div style={{ fontFamily: Mtype.fontDisplay, fontSize: 24, fontWeight: 600, letterSpacing: '-0.02em' }}>Coopertrans</div>
        <div style={{ fontFamily: Mtype.fontMono, fontSize: 10, color: Mtok.textMuted, letterSpacing: '0.14em', textTransform: 'uppercase' }}>Bahía Blanca · transporte</div>
      </div>
      <div style={{ padding: '0 22px 32px', zIndex: 1 }}>
        <div onClick={() => go('login')} style={{
          background: Mtok.brand, color: Mtok.brandFg,
          padding: '15px 18px', borderRadius: Mr.md,
          display: 'flex', alignItems: 'center', justifyContent: 'space-between',
          fontWeight: 600, fontSize: 15, cursor: 'pointer',
          boxShadow: `0 0 32px ${Mtok.brandGlow}`,
        }}>
          <span>Ingresar</span>{Mic.arrow(18, Mtok.brandFg)}
        </div>
        <div style={{ marginTop: 14, textAlign: 'center', fontFamily: Mtype.fontMono, fontSize: 10, color: Mtok.textMuted, letterSpacing: '0.06em' }}>v3.0.0 · build 240601</div>
      </div>
    </Shell>
  );
}

// ----------------------------------------------------------------------------
// 02 · LOGIN
// ----------------------------------------------------------------------------
function Login({ go }) {
  return (
    <Shell>
      {/* logo */}
      <div style={{ padding: '40px 28px 0', zIndex: 1 }}>
        <M.NLogo size={32} theme="dark" />
      </div>
      <div style={{ padding: '52px 28px 24px', zIndex: 1 }}>
        <M.NEyebrow style={{ color: Mtok.textSecondary, opacity: 1 }}>Acceso</M.NEyebrow>
        <div style={{ fontFamily: Mtype.fontDisplay, fontSize: 64, fontWeight: 600, letterSpacing: '-0.04em', lineHeight: 0.95, marginTop: 10 }}>
          Buenas<br/>tardes.
        </div>
      </div>
      <div style={{ padding: '0 28px', flex: 1, display: 'flex', flexDirection: 'column', gap: 10, zIndex: 1 }}>
        <M.NInput theme="dark" label="DNI" value="31.415.926" mono />
        <M.NInput theme="dark" label="Contraseña" value="••••••••" mono action="ver" focused />
        <div onClick={() => go('home')} style={{ marginTop: 18, cursor: 'pointer' }}>
          <M.NButton kind="primary" size="lg" theme="dark" full iconAfter={Mic.arrow}>Ingresar</M.NButton>
        </div>
      </div>
      <div style={{ padding: '0 28px 28px', zIndex: 1 }}>
        <div style={{ borderTop: `1px solid ${Mtok.border}`, paddingTop: 14, display: 'flex', justifyContent: 'space-between', fontFamily: Mtype.fontMono, fontSize: 10, color: Mtok.textMuted, letterSpacing: '0.06em', textTransform: 'uppercase' }}>
          <span>v3.0.0</span>
          <span style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
            <M.NDot color={Mtok.ok} size={5} /> sistemas ok
          </span>
        </div>
      </div>
    </Shell>
  );
}

// ----------------------------------------------------------------------------
// 03 · HOME
// ----------------------------------------------------------------------------
function Home({ go }) {
  return (
    <Shell>
      {/* topbar */}
      <div style={{ padding: '18px 22px 0', display: 'flex', justifyContent: 'space-between', alignItems: 'center', zIndex: 5 }}>
        <M.NLogo size={26} theme="dark" />
        <div style={{ display: 'flex', gap: 10 }}>
          <div onClick={() => go('notifs')} style={{ width: 34, height: 34, borderRadius: 8, background: Mtok.surface2, border: `1px solid ${Mtok.border}`, display: 'grid', placeItems: 'center', position: 'relative', cursor: 'pointer' }}>
            {Mic.bell(15, Mtok.text)}
            <div style={{ position: 'absolute', top: 6, right: 6, width: 6, height: 6, background: Mtok.brand, borderRadius: '50%', boxShadow: `0 0 8px ${Mtok.brand}` }} />
          </div>
          <div onClick={() => go('perfil')} style={{ width: 34, height: 34, borderRadius: '50%', border: `1px solid ${Mtok.borderStrong}`, display: 'grid', placeItems: 'center', fontSize: 11, fontWeight: 600, cursor: 'pointer' }}>SV</div>
        </div>
      </div>

      {/* greeting */}
      <div style={{ padding: '26px 22px 22px', zIndex: 1 }}>
        <M.NEyebrow style={{ color: Mtok.textSecondary, opacity: 1 }}>14:32 · Vie 01 Jun</M.NEyebrow>
        <div style={{ fontFamily: Mtype.fontDisplay, fontSize: 56, fontWeight: 600, letterSpacing: '-0.04em', lineHeight: 0.95, marginTop: 8 }}>Hola Santi.</div>
      </div>

      {/* warning row → vencimientos */}
      <div style={{ padding: '0 22px', display: 'flex', flexDirection: 'column', gap: 10, zIndex: 1 }}>
        <div onClick={() => go('venc_detail')} style={{
          background: Mtok.surface2, border: `1px solid ${Mtok.border}`,
          borderRadius: Mr.lg, padding: '16px 18px',
          display: 'flex', alignItems: 'center', gap: 14, cursor: 'pointer',
        }}>
          <M.NDot color={Mtok.warn} size={8} glow />
          <div style={{ flex: 1 }}>
            <div style={{ fontSize: 14, fontWeight: 500, color: Mtok.text }}>ART vence en <span style={{ color: Mtok.warn }}>23 días</span></div>
            <div style={{ fontFamily: Mtype.fontMono, fontSize: 11, color: Mtok.textMuted, marginTop: 2 }}>14 jun · subí el comprobante</div>
          </div>
          {Mic.arrow(14, Mtok.textMuted)}
        </div>

        {/* tile row */}
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10 }}>
          {[
            { id: 'perfil', i: Mic.person, l: 'Mi perfil', s: 'leg · 31415926' },
            { id: 'unidad', i: Mic.truck, l: 'Mi unidad', s: 'VOL-187 · scania' },
          ].map(t => (
            <div key={t.id} onClick={() => go(t.id)} style={{
              background: Mtok.surface2, border: `1px solid ${Mtok.border}`,
              borderRadius: Mr.lg, padding: 18,
              display: 'flex', flexDirection: 'column', gap: 14, minHeight: 140,
              cursor: 'pointer',
            }}>
              <div style={{ width: 32, height: 32, borderRadius: 8, background: Mtok.surface3, display: 'grid', placeItems: 'center' }}>{t.i(16, Mtok.brand)}</div>
              <div style={{ marginTop: 'auto' }}>
                <div style={{ fontSize: 15, fontWeight: 500, color: Mtok.text }}>{t.l}</div>
                <div style={{ fontFamily: Mtype.fontMono, fontSize: 10, color: Mtok.textMuted, marginTop: 2, letterSpacing: '0.04em' }}>{t.s}</div>
              </div>
            </div>
          ))}
        </div>

        {/* full-width vencim tile */}
        <div onClick={() => go('venc_list')} style={{
          background: Mtok.surface2, border: `1px solid ${Mtok.border}`,
          borderRadius: Mr.lg, padding: '18px 18px',
          display: 'flex', alignItems: 'center', gap: 16, cursor: 'pointer',
        }}>
          <div style={{ width: 36, height: 36, borderRadius: 8, background: Mtok.surface3, display: 'grid', placeItems: 'center' }}>{Mic.file(18, Mtok.brand)}</div>
          <div style={{ flex: 1 }}>
            <div style={{ fontSize: 15, fontWeight: 500, color: Mtok.text }}>Mis vencimientos</div>
            <div style={{ fontFamily: Mtype.fontMono, fontSize: 11, color: Mtok.textMuted, marginTop: 2 }}>Próximo · ART · 14 jun · 23d</div>
          </div>
          {Mic.arrow(15, Mtok.textMuted)}
        </div>
      </div>

      <div style={{ flex: 1 }} />

      {/* AI prompt */}
      <div style={{ padding: '0 22px 16px', zIndex: 1 }}>
        <div style={{
          background: Mtok.surface2, border: `1px solid ${Mtok.border}`,
          borderRadius: Mr.lg, padding: '12px 14px',
          display: 'flex', alignItems: 'center', gap: 10,
        }}>
          {Mic.sparkle(15, Mtok.brand)}
          <div style={{ flex: 1, fontFamily: Mtype.fontMono, fontSize: 11, color: Mtok.textMuted, letterSpacing: '0.02em' }}>
            preguntale a la app · "¿cuándo cobro?"
          </div>
        </div>
      </div>
    </Shell>
  );
}

// ----------------------------------------------------------------------------
// 04 · PERFIL
// ----------------------------------------------------------------------------
function Perfil({ go }) {
  const KV = ({ label, value, mono }) => (
    <div style={{ padding: '12px 0', borderTop: `1px solid ${Mtok.border}`, display: 'flex', justifyContent: 'space-between', gap: 14 }}>
      <div style={{ fontFamily: Mtype.fontMono, fontSize: 11, color: Mtok.textMuted, letterSpacing: '0.06em', textTransform: 'uppercase' }}>{label}</div>
      <div style={{ fontFamily: mono ? Mtype.fontMono : Mtype.fontDisplay, fontSize: 13.5, color: Mtok.text, fontVariantNumeric: 'tabular-nums' }}>{value}</div>
    </div>
  );

  return (
    <Shell onBack={() => go('home')} title="Mi perfil" right={
      <div style={{ width: 36, height: 36, borderRadius: 8, display: 'grid', placeItems: 'center', background: Mtok.surface2, border: `1px solid ${Mtok.border}` }}>{Mic.more(18, Mtok.text)}</div>
    }>
      {/* avatar block */}
      <div style={{ padding: '24px 22px 0', display: 'flex', alignItems: 'center', gap: 16, zIndex: 1 }}>
        <div style={{
          width: 64, height: 64, borderRadius: 16,
          background: `linear-gradient(135deg, ${Mtok.brand}, ${Mtok.brandDark})`,
          display: 'grid', placeItems: 'center',
          fontFamily: Mtype.fontDisplay, fontSize: 26, fontWeight: 600, color: Mtok.brandFg,
          boxShadow: `0 0 32px ${Mtok.brandGlow}`,
        }}>SV</div>
        <div>
          <div style={{ fontFamily: Mtype.fontDisplay, fontSize: 22, fontWeight: 600, letterSpacing: '-0.02em', lineHeight: 1.1 }}>Santiago Vecchi</div>
          <div style={{ fontFamily: Mtype.fontMono, fontSize: 11, color: Mtok.textMuted, marginTop: 4, letterSpacing: '0.04em' }}>chofer · activo</div>
        </div>
      </div>

      {/* stats trio */}
      <div style={{ padding: '20px 22px 0', zIndex: 1 }}>
        <div style={{ background: Mtok.surface2, border: `1px solid ${Mtok.border}`, borderRadius: Mr.lg, display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', overflow: 'hidden' }}>
          {[
            { l: 'antigüedad', v: '11', u: 'años' },
            { l: 'viajes 30d', v: '24', d: '+8%', dc: Mtok.ok },
            { l: 'eco', v: '91', d: '+3', dc: Mtok.ok },
          ].map((s, i) => (
            <div key={s.l} style={{ padding: '14px 14px', borderRight: i < 2 ? `1px solid ${Mtok.border}` : 'none' }}>
              <M.NEyebrow style={{ color: Mtok.textMuted, opacity: 1 }}>{s.l}</M.NEyebrow>
              <div style={{ display: 'flex', alignItems: 'baseline', gap: 4, marginTop: 5 }}>
                <div style={{ fontFamily: Mtype.fontDisplay, fontSize: 26, fontWeight: 600, letterSpacing: '-0.03em', lineHeight: 1, fontVariantNumeric: 'tabular-nums' }}>{s.v}</div>
                {s.u && <div style={{ fontFamily: Mtype.fontMono, fontSize: 10, color: Mtok.textMuted }}>{s.u}</div>}
              </div>
              {s.d && <div style={{ fontFamily: Mtype.fontMono, fontSize: 10, color: s.dc, marginTop: 3, fontWeight: 500 }}>{s.d}</div>}
            </div>
          ))}
        </div>
      </div>

      {/* identity */}
      <div style={{ padding: '22px 22px 0', zIndex: 1 }}>
        <M.NEyebrow style={{ color: Mtok.textMuted, opacity: 1, marginBottom: 4 }}>Datos personales</M.NEyebrow>
        <div style={{ background: Mtok.surface2, border: `1px solid ${Mtok.border}`, borderRadius: Mr.lg, padding: '4px 16px', marginTop: 10 }}>
          <KV label="Legajo" value="31415926" mono />
          <KV label="DNI" value="31.415.926" mono />
          <KV label="Teléfono" value="+54 291 415-6926" mono />
          <KV label="Mail" value="svecchi@coopertrans.coop" />
          <KV label="Domicilio" value="Av. Colón 1234" />
        </div>
      </div>

      <div style={{ padding: '20px 22px 28px', zIndex: 1, marginTop: 'auto' }}>
        <M.NButton kind="ghost" theme="dark" size="md" full icon={Mic.power}>Cerrar sesión</M.NButton>
      </div>
    </Shell>
  );
}

// ----------------------------------------------------------------------------
// 05 · VENCIMIENTOS LIST
// ----------------------------------------------------------------------------
function VencList({ go }) {
  const items = [
    { id: 'art',  l: 'ART',                  s: 'Provincia ART · póliza 4012',     date: '14·06', days: 23, c: Mtok.warn, st: 'próximo' },
    { id: 'lic',  l: 'Licencia profesional', s: 'Cat. E1 · Bahía Blanca',          date: '02·09', days: 103, c: Mtok.ok, st: 'al día' },
    { id: 'psi',  l: 'Psicofísico',          s: 'Cat. profesional · CNRT',         date: '02·09', days: 103, c: Mtok.ok, st: 'al día' },
    { id: 'curso',l: 'Curso CNRT',           s: 'Renovación cada 5 años',          date: '12·11', days: 174, c: Mtok.ok, st: 'al día' },
    { id: 'ant',  l: 'Antecedentes',         s: 'Reincidencia anual',              date: '08·05', days: -23, c: Mtok.crit, st: 'vencido' },
    { id: 'med',  l: 'Análisis clínicos',    s: 'Cada 12 meses',                   date: '20·07', days: 49, c: Mtok.ok, st: 'al día' },
  ];

  return (
    <Shell onBack={() => go('home')} title="Mis vencimientos" right={
      <div style={{ width: 36, height: 36, borderRadius: 8, display: 'grid', placeItems: 'center', background: Mtok.surface2, border: `1px solid ${Mtok.border}` }}>{Mic.filter(16, Mtok.text)}</div>
    }>
      {/* hero summary */}
      <div style={{ padding: '20px 22px 12px', zIndex: 1 }}>
        <div style={{ background: Mtok.surface2, border: `1px solid ${Mtok.border}`, borderRadius: Mr.lg, padding: '18px 20px', position: 'relative', overflow: 'hidden' }}>
          <div style={{ position: 'absolute', top: -40, right: -40, width: 200, height: 200, background: `radial-gradient(circle, ${Mtok.brandGlow}, transparent 65%)`, pointerEvents: 'none' }} />
          <M.NEyebrow style={{ color: Mtok.textMuted, opacity: 1, position: 'relative' }}>Estado general</M.NEyebrow>
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 14, marginTop: 12, position: 'relative' }}>
            {[
              { v: 1, l: 'vencido', c: Mtok.crit },
              { v: 1, l: 'próximo', c: Mtok.warn },
              { v: 4, l: 'al día', c: Mtok.ok },
            ].map(s => (
              <div key={s.l}>
                <div style={{ fontFamily: Mtype.fontDisplay, fontSize: 36, fontWeight: 600, color: s.c, letterSpacing: '-0.03em', lineHeight: 1, fontVariantNumeric: 'tabular-nums' }}>{s.v}</div>
                <div style={{ fontFamily: Mtype.fontMono, fontSize: 10, color: Mtok.textMuted, letterSpacing: '0.06em', textTransform: 'uppercase', marginTop: 6 }}>{s.l}</div>
              </div>
            ))}
          </div>
        </div>
      </div>

      {/* filter chips */}
      <div style={{ padding: '0 22px 10px', display: 'flex', gap: 6, flexWrap: 'wrap', zIndex: 1 }}>
        {[
          { l: 'Todos', n: 6, a: true },
          { l: 'Vencidos', n: 1 },
          { l: 'Próximos', n: 1 },
          { l: 'Al día', n: 4 },
        ].map(c => (
          <div key={c.l} style={{
            padding: '5px 11px', borderRadius: 999,
            background: c.a ? Mtok.text : 'transparent',
            color: c.a ? Mtok.bg : Mtok.textSecondary,
            fontSize: 11.5, fontWeight: 600,
            border: c.a ? 'none' : `1px solid ${Mtok.border}`,
            display: 'flex', gap: 6,
          }}>{c.l} <span style={{ opacity: 0.6 }}>{c.n}</span></div>
        ))}
      </div>

      {/* list */}
      <div style={{ flex: 1, overflow: 'hidden', zIndex: 1 }}>
        {items.map((it, i) => (
          <div key={it.id} onClick={() => go(it.id === 'art' ? 'venc_detail' : 'venc_detail')} style={{
            padding: '14px 22px',
            borderTop: i === 0 ? `1px solid ${Mtok.border}` : 'none',
            borderBottom: `1px solid ${Mtok.border}`,
            display: 'flex', alignItems: 'center', gap: 12,
            cursor: 'pointer',
          }}>
            <M.NDot color={it.c} size={8} glow={it.days < 30} />
            <div style={{ flex: 1 }}>
              <div style={{ fontSize: 13.5, fontWeight: 500, color: Mtok.text }}>{it.l}</div>
              <div style={{ fontFamily: Mtype.fontMono, fontSize: 10.5, color: Mtok.textMuted, marginTop: 2, letterSpacing: '0.02em' }}>{it.s}</div>
            </div>
            <div style={{ textAlign: 'right' }}>
              <div style={{ fontFamily: Mtype.fontMono, fontSize: 12, color: it.c, fontVariantNumeric: 'tabular-nums', fontWeight: 600 }}>{it.days < 0 ? `${Math.abs(it.days)}d` : `${it.days}d`}</div>
              <div style={{ fontFamily: Mtype.fontMono, fontSize: 10, color: Mtok.textMuted, marginTop: 2 }}>{it.date}</div>
            </div>
            {Mic.chevronRight(14, Mtok.textMuted)}
          </div>
        ))}
      </div>
    </Shell>
  );
}

// ----------------------------------------------------------------------------
// 06 · VENC DETAIL
// ----------------------------------------------------------------------------
function VencDetail({ go }) {
  return (
    <Shell onBack={() => go('venc_list')} title="ART · póliza 4012">
      {/* hero number */}
      <div style={{ padding: '20px 22px 4px', zIndex: 1 }}>
        <M.NEyebrow style={{ color: Mtok.textMuted, opacity: 1 }}>Vence en</M.NEyebrow>
        <div style={{ display: 'flex', alignItems: 'baseline', gap: 12, marginTop: 8 }}>
          <div style={{ fontFamily: Mtype.fontDisplay, fontSize: 112, fontWeight: 600, color: Mtok.warn, letterSpacing: '-0.055em', lineHeight: 0.85, fontVariantNumeric: 'tabular-nums' }}>23</div>
          <div style={{ fontFamily: Mtype.fontMono, fontSize: 14, color: Mtok.textMuted, letterSpacing: '0.04em' }}>días</div>
        </div>
        <div style={{ fontFamily: Mtype.fontMono, fontSize: 12, color: Mtok.textSecondary, marginTop: 6 }}>14 de junio de 2026 · sábado</div>
      </div>

      {/* meta card */}
      <div style={{ padding: '22px 22px 0', zIndex: 1 }}>
        <div style={{ background: Mtok.surface2, border: `1px solid ${Mtok.border}`, borderRadius: Mr.lg, padding: '4px 16px' }}>
          {[
            ['Tipo', 'ART'],
            ['Compañía', 'Provincia ART'],
            ['Póliza', '4012-78219-3'],
            ['Renovación', 'Anual'],
            ['Estado actual', 'Vigente'],
          ].map(([l, v], i) => (
            <div key={l} style={{ padding: '12px 0', borderTop: i ? `1px solid ${Mtok.border}` : 'none', display: 'flex', justifyContent: 'space-between' }}>
              <div style={{ fontFamily: Mtype.fontMono, fontSize: 11, color: Mtok.textMuted, letterSpacing: '0.06em', textTransform: 'uppercase' }}>{l}</div>
              <div style={{ fontSize: 13.5, color: Mtok.text, fontWeight: 500 }}>{v}</div>
            </div>
          ))}
        </div>
      </div>

      {/* timeline */}
      <div style={{ padding: '22px 22px 0', zIndex: 1 }}>
        <M.NEyebrow style={{ color: Mtok.textMuted, opacity: 1, marginBottom: 10 }}>Historial</M.NEyebrow>
        {[
          { t: 'jun 2025', e: 'Renovación · subido por SV', c: Mtok.ok },
          { t: 'jun 2024', e: 'Renovación · subido por RRHH', c: Mtok.ok },
          { t: 'jun 2023', e: 'Renovación · subido por SV', c: Mtok.ok },
        ].map((row, i) => (
          <div key={i} style={{ display: 'grid', gridTemplateColumns: '12px 1fr auto', gap: 12, padding: '10px 0', borderTop: i ? `1px solid ${Mtok.border}` : 'none', alignItems: 'center' }}>
            <M.NDot color={row.c} size={8} />
            <div style={{ fontSize: 13, color: Mtok.text }}>{row.e}</div>
            <div style={{ fontFamily: Mtype.fontMono, fontSize: 10.5, color: Mtok.textMuted, letterSpacing: '0.04em' }}>{row.t}</div>
          </div>
        ))}
      </div>

      <div style={{ flex: 1 }} />

      {/* CTA */}
      <div style={{ padding: '16px 22px 26px', display: 'flex', flexDirection: 'column', gap: 8, zIndex: 1 }}>
        <M.NButton kind="primary" size="lg" theme="dark" full icon={Mic.download}>Subir comprobante renovado</M.NButton>
        <M.NButton kind="ghost" size="md" theme="dark" full>Avisar a RRHH</M.NButton>
      </div>
    </Shell>
  );
}

// ----------------------------------------------------------------------------
// 07 · UNIDAD
// ----------------------------------------------------------------------------
function Unidad({ go }) {
  return (
    <Shell onBack={() => go('home')} title="Mi unidad">
      {/* unit hero */}
      <div style={{ padding: '20px 22px 4px', zIndex: 1 }}>
        <M.NEyebrow style={{ color: Mtok.textMuted, opacity: 1 }}>Asignada</M.NEyebrow>
        <div style={{ fontFamily: Mtype.fontDisplay, fontSize: 64, fontWeight: 600, letterSpacing: '-0.04em', lineHeight: 0.95, marginTop: 6 }}>
          VOL-<span style={{ color: Mtok.brand }}>187</span>
        </div>
        <div style={{ fontFamily: Mtype.fontMono, fontSize: 12, color: Mtok.textSecondary, marginTop: 6 }}>Volvo FH 540 · 2021 · chasis CN-892</div>
      </div>

      {/* live status strip */}
      <div style={{ padding: '20px 22px 0', zIndex: 1 }}>
        <div style={{ background: Mtok.surface2, border: `1px solid ${Mtok.border}`, borderRadius: Mr.lg, display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', overflow: 'hidden' }}>
          {[
            { l: 'estado', v: 'En ruta', c: Mtok.brand, big: false },
            { l: 'km totales', v: '418k', c: Mtok.text },
            { l: 'última carga', v: '67%', c: Mtok.text },
          ].map((s, i) => (
            <div key={s.l} style={{ padding: '14px 14px', borderRight: i < 2 ? `1px solid ${Mtok.border}` : 'none' }}>
              <M.NEyebrow style={{ color: Mtok.textMuted, opacity: 1 }}>{s.l}</M.NEyebrow>
              <div style={{ fontFamily: i === 0 ? Mtype.fontDisplay : Mtype.fontMono, fontSize: i === 0 ? 18 : 22, fontWeight: 600, color: s.c, letterSpacing: '-0.02em', lineHeight: 1, fontVariantNumeric: 'tabular-nums', marginTop: 6 }}>{s.v}</div>
            </div>
          ))}
        </div>
      </div>

      {/* vencimientos de la unidad */}
      <div style={{ padding: '22px 22px 0', zIndex: 1 }}>
        <M.NEyebrow style={{ color: Mtok.textMuted, opacity: 1, marginBottom: 8 }}>Vencimientos de la unidad</M.NEyebrow>
        <div style={{ background: Mtok.surface2, border: `1px solid ${Mtok.border}`, borderRadius: Mr.lg }}>
          {[
            { l: 'VTV', s: 'Bahía Blanca · planta 03', date: '12·08', days: 72, c: Mtok.ok },
            { l: 'Seguro RC', s: 'La Caja · póliza 8821', date: '01·07', days: 30, c: Mtok.warn },
            { l: 'RUTA / RTO', s: 'CNRT · revisión técnica', date: '24·05', days: -8, c: Mtok.crit },
          ].map((it, i) => (
            <div key={it.l} style={{
              padding: '14px 16px',
              borderTop: i ? `1px solid ${Mtok.border}` : 'none',
              display: 'flex', alignItems: 'center', gap: 12,
            }}>
              <M.NDot color={it.c} size={8} glow={it.days < 30} />
              <div style={{ flex: 1 }}>
                <div style={{ fontSize: 13.5, fontWeight: 500, color: Mtok.text }}>{it.l}</div>
                <div style={{ fontFamily: Mtype.fontMono, fontSize: 10.5, color: Mtok.textMuted, marginTop: 2, letterSpacing: '0.02em' }}>{it.s}</div>
              </div>
              <div style={{ fontFamily: Mtype.fontMono, fontSize: 12, color: it.c, fontVariantNumeric: 'tabular-nums', fontWeight: 600 }}>{it.days < 0 ? `${Math.abs(it.days)}d` : `${it.days}d`}</div>
            </div>
          ))}
        </div>
      </div>

      <div style={{ flex: 1 }} />

      <div style={{ padding: '16px 22px 26px', display: 'flex', gap: 8, zIndex: 1 }}>
        <M.NButton kind="secondary" theme="dark" size="md" icon={Mic.wrench}>Reportar falla</M.NButton>
        <div style={{ flex: 1 }} />
      </div>
    </Shell>
  );
}

// ----------------------------------------------------------------------------
// 08 · NOTIFS
// ----------------------------------------------------------------------------
function Notifs({ go }) {
  const groups = [
    {
      l: 'Hoy', items: [
        { t: '14:08', c: Mtok.brand, l: 'Cambio de turno registrado', s: 'Ing. White rotonda · VOL-187' },
        { t: '11:22', c: Mtok.warn, l: 'ART vence en 23 días', s: 'Recordatorio · Provincia ART' },
      ],
    },
    {
      l: 'Esta semana', items: [
        { t: 'mié', c: Mtok.ok, l: 'Liquidación quincena 1 acreditada', s: '$ 487.250 · cuenta CBU 0…2841' },
        { t: 'mar', c: Mtok.text, l: 'Curso CNRT · disponible', s: 'Renovación obligatoria · oct 2026' },
        { t: 'lun', c: Mtok.ok, l: 'Eco-driving score +3', s: 'Pasaste de 88 a 91 esta semana' },
      ],
    },
    {
      l: 'Antes', items: [
        { t: '24·05', c: Mtok.crit, l: 'RTO de la unidad vencida', s: 'VOL-187 · gestionar con taller' },
      ],
    },
  ];

  return (
    <Shell onBack={() => go('home')} title="Notificaciones" right={
      <div style={{ fontFamily: Mtype.fontMono, fontSize: 11, color: Mtok.brand, padding: '0 6px', fontWeight: 600, letterSpacing: '0.04em' }}>Marcar leídas</div>
    }>
      <div style={{ padding: '12px 22px 28px', zIndex: 1, display: 'flex', flexDirection: 'column', gap: 22 }}>
        {groups.map(g => (
          <div key={g.l}>
            <M.NEyebrow style={{ color: Mtok.textMuted, opacity: 1, marginBottom: 10 }}>{g.l}</M.NEyebrow>
            <div style={{ background: Mtok.surface2, border: `1px solid ${Mtok.border}`, borderRadius: Mr.lg, overflow: 'hidden' }}>
              {g.items.map((it, i) => (
                <div key={i} style={{
                  padding: '13px 16px',
                  borderTop: i ? `1px solid ${Mtok.border}` : 'none',
                  display: 'grid', gridTemplateColumns: '8px 1fr auto', gap: 12, alignItems: 'flex-start',
                }}>
                  <div style={{ width: 8, height: 8, background: it.c, borderRadius: '50%', marginTop: 6 }} />
                  <div>
                    <div style={{ fontSize: 13.5, fontWeight: 500, color: Mtok.text, lineHeight: 1.35 }}>{it.l}</div>
                    <div style={{ fontFamily: Mtype.fontMono, fontSize: 10.5, color: Mtok.textMuted, marginTop: 3, letterSpacing: '0.02em' }}>{it.s}</div>
                  </div>
                  <div style={{ fontFamily: Mtype.fontMono, fontSize: 10.5, color: Mtok.textMuted, letterSpacing: '0.04em', fontVariantNumeric: 'tabular-nums' }}>{it.t}</div>
                </div>
              ))}
            </div>
          </div>
        ))}
      </div>
    </Shell>
  );
}

window.MobileScreens = {
  splash: Splash,
  login: Login,
  home: Home,
  perfil: Perfil,
  venc_list: VencList,
  venc_detail: VencDetail,
  unidad: Unidad,
  notifs: Notifs,
};
