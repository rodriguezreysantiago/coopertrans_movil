# Pendientes follow-up

Cosas que requieren acción nuestra en una fecha específica. Para roadmap general
del proyecto, ver `ESTADO_PROYECTO.md`. Para procedimientos operativos, `RUNBOOK.md`.

Convención: orden cronológico (los próximos arriba). Sacar el ítem cuando se ejecuta.

---

## 📅 2026-05-16 (sáb) — Re-análisis de eventos Sitrack con ventana de 60h

**Contexto**: el primer análisis se corrió el 2026-05-14 a las 32h del deploy
y devolvió 1036 eventos / 28.8 evt/h. Hallazgos clave:
- ✅ **CONDUCCIÓN PELIGROSA** = 108 eventos (10.4%) — categoría dominante.
  Distribución: salida de carril 1006 (77%), sobrevelocidad 8/9 (15%),
  giro brusco 383, distancia frenado 444, frenada brusca 67.
- ✅ Hay LDWS/cámara en algunos tractores (eventos 1006).
- ✅ 88.8% eventos con chofer identificado, 53.6% con cartography_limit_speed.
- ❌ **JORNADA** con eventos directos NO viable (los GPS son básicos sin
  ICAN, no emiten 152/153/513/514). El `vigiladorJornadaChofer` actual
  con proxy `speed > 15` SE QUEDA — no migrar.
- ❌ Viajes / combustible / fatiga MobileEye / mantenimiento — 0 eventos.
- ⚠️ Solo 29 de ~53 tractores emitiendo. Confirmar si los 24 restantes
  son inactivos o sin configurar (consultar a Sitrack).

**Decisión Santiago 2026-05-14**: esperar UN día más antes de codear el
consumer. Una ventana de 36h es muestra chica — quiero validar que la
distribución se mantiene estable antes de decidir features.

**Acción**: el sábado 2026-05-16 (o domingo) correr el análisis de nuevo
con ventana 60h:

```powershell
cd "C:\Users\Colo Logistica\coopertrans_movil"
node scripts/analizar_sitrack_eventos.js --horas 60
```

**Qué validar**:
- ¿La distribución por categoría se mantiene estable o cambia?
  (ej. Conducción peligrosa sigue siendo > 10% del total).
- ¿Aparecen tipos de evento que no vimos en 36h (ej. mantenimiento,
  combustible)?
- ¿La cobertura de patentes sube de 29 o se queda?
- ¿Cuántos eventos de salida de carril (1006) por chofer? Identificar
  quién maneja peor.

**Decisión a tomar después**: con muestra más grande, elegir entre:
- 🥇 Camino A: Resumen diario a Molina con eventos peligrosos del día
  (~150 LOC, mínimo riesgo).
- 🥈 Camino B: Score Sitrack por chofer (compite con Volvo Scores)
  (~400 LOC + UI).
- 🥉 Camino C: Alerta sobrevelocidad cartográfica en tiempo real
  (~100 LOC, posible spam).

Mi recomendación al cierre del 14/05: empezar por A.
