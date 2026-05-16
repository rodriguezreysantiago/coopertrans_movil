# Pendientes follow-up

Cosas que requieren acción nuestra en una fecha específica. Para roadmap general
del proyecto, ver `ESTADO_PROYECTO.md`. Para procedimientos operativos, `RUNBOOK.md`.

Convención: orden cronológico (los próximos arriba). Sacar el ítem cuando se ejecuta.

---

## 📅 2026-05-15 EOD — Cierre del día (lo que quedó deployable)

Sesión gigante: 17 commits + bump 1.0.55+58 → 1.0.56+59. Lo que sigue
es el orden recomendado para mañana sábado / lunes:

### Deploys pendientes
```powershell
# Trae lo del día (release_completo.ps1 ya pusheó hasta 974dbaf):
git push                              # por si quedó algo

# Backend:
firebase deploy --only firestore:rules,firestore:indexes
firebase deploy --only functions

# Una vez deployado el vigilador v2, limpiar la legacy:
node scripts/limpiar_jornadas_chofer_legacy.js --dry-run
node scripts/limpiar_jornadas_chofer_legacy.js --apply
```

### Releases ya hechos hoy
- ✅ 1.0.55+58 (release_completo.ps1) — adelantos para todo personal +
  primera versión del cron `resumenConductaManejoDiario`.
- ✅ 1.0.56+59 (974dbaf) — módulo ICM completo (hub + ranking + reporte
  semanal + detalle por chofer + mapa de calor placeholder) + reporte
  Excel ICM en menú Reportes + sobrevelocidades por chofer en resumen
  Molina + capability `verIcm` (admin/supervisor/seg_higiene).

### Cosas a validar mañana 8 AM ART (cuando llegue el resumen Molina)
- Mensaje del cron `resumenConductaManejoDiario` con el formato nuevo
  unificado (Sitrack + Volvo AEBS/ESP, sin jerga técnica) + línea
  "Peor exceso: X km/h (límite Y, +Z)" cuando hubo sobrevelocidad
  (event_id 8/9).
- Mensaje del cron `resumenExcesosJornadaDiario` (vigilador v2 con
  modelo bloques 3×4h).

---

## 📅 Post 2026-05-15 — Build #9 Xcode Cloud (iOS Plan A)

**Estado al cierre**: 8 builds previos fallaron — los primeros por
backend Apple propagando cuenta nueva ("Communication with Apple
failed"), después por base64 corrupto de los secrets en App Store
Connect (paste duplicado).

Cambios commiteados (ya están en `main`):
- `d3b7155` — `ci_post_clone.sh` con `printf '%s' + tr -d '\r\n\t '` +
  validación de longitudes y tamaños. Si vuelve a fallar, los logs
  ahora dicen exactamente qué env var está mal.
- Cert (`coopertrans_dist.p12`, password `coopertrans2026`) y profile
  (`Coopertrans_Movil_App_Store.mobileprovision`) backupeados en
  `G:\Mi unidad\ClaudeCodeSync\secrets-ios\`.
- 3 secret env vars seteadas en el workflow Xcode Cloud
  (`IOS_DIST_CERT_P12_BASE64`, `_PASSWORD`, `IOS_DIST_PROFILE_BASE64`).

**Acción**: App Store Connect → Coopertrans Móvil → Xcode Cloud →
workflow → Start Build → branch `main`. Esperar ~30 min.

Si OK: mail "Build available in TestFlight" a `santiagocoopertrans@gmail.com`.
Si falla: bajar logs y revisar — `cert b64 length: 0` indica secret
no inyectado por Xcode Cloud (problema Apple, no nuestro).

---

## 📅 2026-05-16 (sáb) — ya cumplido / re-evaluar consumer Sitrack

El re-análisis de la ventana 60h se corrió 2026-05-15 (`scripts/analizar_sitrack_eventos.js --horas 60`):
- 7437 eventos / 124 evt/h.
- Conducción peligrosa = 573 eventos (7.7%): 407 salida de carril, 92
  sobrevelocidad, 37 giro brusco, 23 frenada brusca, 10 distancia
  frenado insuficiente, 1 aceleración brusca, 2 colisión.
- 87.9% chofer identificado, 52.3% con cartografía.

**Decisión tomada 2026-05-15**: NO armar consumer Sitrack adicional —
los 10 tipos peligrosos ya entran al `resumenConductaManejoDiario` y
al módulo ICM. Está cubierto end-to-end.

---

## 🟡 Pendientes operativos (sin fecha fija)

### Bot WhatsApp en PC dedicada 24/7 — pendiente migración física
Kit completo armado en `G:\Mi unidad\ClaudeCodeSync\bot-pc-dedicada\`
(683 MB). Cuando Santiago prenda la PC dedicada (Windows Pro recién
instalado):

1. Esperar que Drive sincronice la carpeta.
2. Click derecho `instalar_todo.ps1` → Run with PowerShell (admin).
3. ~10-15 min: instala Node+Git via winget, clona repo, copia los 3
   archivos secret, npm install, registra servicio NSSM, configura
   Windows 24/7, instala auto-update Scheduled Task, smoke test.
4. Cuando confirme heartbeat OK desde `bot_estado_remoto.js`, apagar
   bot en PC oficina (`Stop-Service CoopertransMovilBot` +
   `Set-Service ... -StartupType Manual`).

Ver memoria `project_bot_pc_dedicada.md` para detalle.

### Acceso remoto PC dedicada → casa
Recomendado: Tailscale + RDP nativo. Setup en `docs/SETUP_PC_DEDICADA_BOT.md`
(actualizar con sección Tailscale cuando se concrete). Windows Pro ya
instalado en la PC dedicada — RDP funciona out-of-the-box.

### Multi-tramo Logística — features chicas
- Reordenar tramos (drag handle).
- Duplicar tramo (botón "+ copiar").
- Validar encadenamiento (origen tramo N+1 = destino tramo N).
- Buscador en empresas y tarifas (igual al de ubicaciones).
- Pantalla "viajes borrados" para revisar/restaurar soft-deleted.
- Exportar liquidación a Excel.

### Volvo Driver/Tachograph Files API
Módulos activos pero feeds vacíos. Pedir a Volvo Argentina alta de 48
choferes + activación transmisión por unidad.

### iOS post-Build OK
Una vez TestFlight Internal funcione:
- Crear grupo "External Testing" en App Store Connect.
- Compartir link de TestFlight a choferes con iPhone.
- Listing público (capturas + descripción) cuando se quiera publicar
  al App Store. Material similar a `docs/PLAY_STORE_LISTING.md`.

### Refinamientos ICM (no urgentes)
- Cuando haya histórico de odómetros por patente (snapshot diario
  desde TELEMETRIA_HISTORICO), reemplazar el baseline `1 evento = 100
  km` del calculator por cálculo real. El factor del ICM (default 5)
  podría calibrarse para que matchee con el Tablero ICM YPF.
- Iconos custom para ICM verde/amarillo/rojo (hoy usa `Icons.leaderboard`
  + colores de fondo).
