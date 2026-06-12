# Auditoría total — Anexo completo de hallazgos (2026-06-12)

> Generado por la auditoría multi-agente del 2026-06-12: 21 áreas revisadas archivo por archivo
> (46 agentes, ~1.300 lecturas de herramientas), bugs críticos/altos verificados adversarialmente
> por agentes independientes, + 4 análisis estratégicos. El reporte ejecutivo curado vive en
> `docs/auditorias/2026-06-12_reporte.md`. Este anexo es el detalle completo sin curar.

**Números:** 21 áreas · 95 bugs reportados · 17 confirmados · 4 descartados como falsos positivos.

---

# 1. Bugs confirmados adversarialmente (17)

#### [ALTA] Recálculo masivo usa comisionPct=0 para viajes previamente 'todo-fijo', zeroeando el pago al chofer
- **Área:** logistica-negocio · **Archivo:** `lib/features/logistica/services/viajes_service.dart:531` · **Confianza del revisor:** alta
- En `_recalcularViajesConTarifa`, al llamar `_construirDataActualizacion` se pasa `comisionPct: v.comisionChoferPct`. Si el viaje tenía todos los tramos con `montoFijoChofer`, el campo persistido `comision_chofer_pct` es 0.0 (el `pctReportado = 0` de `calcularTodoMultiTramo`). Cuando la nueva vigencia es por-unidad (sin fijo), los tramos recalculados no tienen `montoFijoChofer` → entran al branch de porcentaje con `pct = 0.0 ?? 18 = 0.0` (0.0 no es null, el operador `??` no activa el default) → `montoTramo = brutoChofer * 0 = 0`. El chofer queda con pago cero en Firestore para viajes no liquidados que hicieron ese tránsito modo-fijo→modo-porcentaje. Solución: en `_construirDataActualizacion`, reemplazar `comisionPct: v.comisionChoferPct` por `comisionPct: v.comisionChoferPct > 0 ? v.comisionChoferPct : null` para que el default 18% se active cuando el pct almacenado es 0.
- **Veredicto del verificador:** El bug es real y el flujo que lo dispara es alcanzable. En `calculos_viaje.dart:293`, cuando todos los tramos tienen `montoFijoChofer != null`, `hayAlgunTramoConPct` queda en `false` y `pctReportado = 0.0`. Ese `0.0` se escribe en Firestore como `comision_chofer_pct`. Al leer el viaje en `Viaje.fromMap` (viaje.dart:787), `(d['comision_chofer_pct'] as num?)?.toDouble() ?? 18` devuelve `0.0` (no null) — el fallback `?? 18` no se activa. En `_recalcularViajesConTarifa` (viajes_service.dart:531), ese `0.0` se pasa como `comisionPct: v.comisionChoferPct`. Cuando la nueva vigencia es por-unidad (`montoFijoChofer == null`), los tramos recalculados caen en `calcularTodoMultiTramo:281` (`montoTramo = brutos.montoChofer * (pct / 100.0)`), donde `pct = comisionPct ?? comisionChoferDefaultPct = 0.0 ?? 18 = 0.0` — el `??` no activa porque `0.0` no es null. Resultado: `monto_chofer = 0` y `liquidacion_chofer = 0` escritos en Firestore. La transición fijo→por-unidad sí se alcanza: `recalcularTramo` (viajes_service.dart:437-441) detecta el cambio del par `(tarifaChofer, montoFijoChofer)` y retorna el tramo actualizado. La solución propuesta (`comisionPct: v.comisionChoferPct > 0 ? v.comisionChoferPct : null`) es correcta.

#### [ALTA] TELEMETRIA_HISTORICO: fecha guardada como Timestamp pero leída como String — gráfico de km y tabla de consumo siempre vacíos
- **Área:** vehiculos · **Archivo:** `lib/features/vehicles/services/vehiculo_repository.dart:263` · **Confianza del revisor:** alta
- guardarSnapshotsDiarios escribe el campo 'fecha' como Timestamp.fromDate(fecha) (línea 263). OdometrosService._fromDoc (odometros_service.dart:50) lo lee como (m['fecha'] as String?) ?? '' — el cast Timestamp→String siempre retorna null, por lo que fecha queda ''. Consecuencia: agruparPorMes descarta todos los registros (od.fecha.length < 7 en línea 122), la tabla de consumo mensual nunca muestra datos. En el gráfico de días (_GraficoDias) las etiquetas del eje X resultan vacías porque fecha.substring(8,10) se llama sobre ''. El chart igual se dibuja porque usa deltaKm (calculado correctamente), pero los labels de fecha en el eje X son siempre en blanco. Fix: en guardarSnapshotsDiarios usar 'fecha': fechaTxt (el String YYYY-MM-DD ya calculado) en lugar de Timestamp.
- **Veredicto del verificador:** Bug confirmado. En vehiculo_repository.dart:263 y en functions/src/telemetria.ts:276, el campo `fecha` se escribe como `Timestamp.fromDate(fecha)`. OdometrosService._fromDoc (odometros_service.dart:50) lo lee con `(m['fecha'] as String?) ?? ''` — el cast de Timestamp a String? falla en runtime (Dart devuelve null para un as? fallido), dejando `fecha = ''` en cada OdometroDia. La guardia en _GraficoDias:1012 (`if (f.length < 10) return const Text('')`) evita el RangeError pero confirma el síntoma: todos los labels del eje X son Text vacíos. La guardia en agruparPorMes:122 (`if (od.fecha.length < 7) continue`) descarta todos los registros, dejando la tabla de consumo mensual y los KPIs completamente vacíos. report_consumo.dart:306-309 lee `fecha` correctamente como Timestamp (`if (ts is! Timestamp) continue; fecha: ts.toDate()`) — ese reporte no está afectado. El impacto es real y no teórico: toda unidad Volvo que se abra en la pantalla de detalle muestra el gráfico sin etiquetas y la tabla de consumo vacía.

#### [ALTA] kmUnidadAlMontar no se pasa al montar: semáforo de desgaste siempre 'sin datos' en tractores nuevos
- **Área:** gomeria-checklist · **Archivo:** `lib/features/gomeria/screens/gomeria_v2_unidad_screen.dart:535` · **Confianza del revisor:** alta
- El método _montar() llama a _service.montar(...) sin pasar el parámetro kmUnidadAlMontar. El servicio acepta double? y lo guarda como null. Consecuencia: km_unidad_al_montar = null en Firestore para todo montaje creado desde la UI nueva. kmRecorridoPorPosicion calcula (kmActual - null) = null para cada posición, y el semáforo muestra NivelDesgaste.sinDatos en lugar del nivel real para TODOS los tractores con montajes recientes. La función _kmActualTractor ya existe en el servicio; solo falta leerla antes de llamar a montar y pasarla. El bug existe desde que se creó la pantalla nueva (refactor Núcleo jun 2026).
- **Veredicto del verificador:** El bug es real y alcanzable en producción. En `gomeria_v2_unidad_screen.dart:535-546`, `_montar()` llama a `_service.montar(...)` sin pasar `kmUnidadAlMontar`, por lo que el campo `km_unidad_al_montar` queda `null` en Firestore para todo montaje creado desde esta pantalla. Aguas abajo, `kmRecorridoPorPosicion` (`montajes_service.dart:659-666`) hace `kmActual - base` donde `base = m.kmUnidadAlMontar`; si `base` es null, devuelve null para esa posición. La pantalla llama a `construirEstadoUnidad` (`estado_posicion.dart:110-114`) SIN pasar `kmActualUnidad`, por lo que el fallback directo de `porcentajeVidaConsumida` (`montaje.dart:185-191`) tampoco puede calcular nada, y `nivelDesgaste(null)` siempre retorna `NivelDesgaste.sinDatos` (gris). No existe ningún Cloud Function ni backfill posterior que rellene `km_unidad_al_montar`. El helper `_kmActualTractor` ya existe en el servicio pero solo se invoca desde `kmRecorridoPorPosicion` y `kmCierreRetiro`, nunca desde `montar()`. La severidad "alta" es correcta: el semáforo —funcionalidad principal del módulo— queda en gris para todos los tractores con montajes creados desde la UI nueva.

#### [ALTA] backupFirestoreScheduled omite colecciones nuevas críticas
- **Área:** fx-plataforma · **Archivo:** `functions/src/mantenimiento.ts:130` · **Confianza del revisor:** alta
- El array `collectionIds` del backup semanal a GCS no incluye cinco colecciones que se agregaron al sistema después de la última actualización de la lista: `ZONA_DESCARGA_HISTORICO`, `REGISTRO_JORNADAS`, `PARADAS_REPORTADAS`, `REPORTES_DISCREPANCIA` y `VOLVO_JORNADAS_HISTORICO`. En un escenario de disaster recovery, todo el historial de descargas YPF (fuente del módulo descargas), los registros del vigilador v3 (fuente oficial de jornadas, base del reporte a Molina), las paradas reportadas por los choferes y los reclamos de discrepancia serían irrecuperables. El comentario de auditoría en el archivo reconoce que la lista se desactualizó antes — es un patrón recurrente cuando se agregan colecciones sin actualizar el backup.
- **Veredicto del verificador:** Las cinco colecciones existen en producción y ninguna aparece en `collectionIds` de `mantenimiento.ts:130-184`. `ZONA_DESCARGA_HISTORICO` se escribe en `zonas_descarga.ts:383` y `historico_descargas.ts:177`; `REGISTRO_JORNADAS` se define como fuente oficial v3 en `jornadas_v3_batch.ts:46` y es la base del reporte diario a Molina; `PARADAS_REPORTADAS` y `REPORTES_DISCREPANCIA` se escriben en `paradas_reportadas.ts:206,211`; `VOLVO_JORNADAS_HISTORICO` se escribe en `jornada_historico.ts:329`. El comentario en `sitrack.ts:694-695` marca explícitamente `ZONA_DESCARGA_HISTORICO` y `VOLVO_JORNADAS_HISTORICO` como PERMANENTES (sin TTL). El script manual `scripts/backup_firestore.ps1` ya fue corregido post-auditoría 2026-05-16 para exportar todas las colecciones sin filtro, pero la Cloud Function semanal (la única cobertura automática cloud-side sin necesitar PC encendida) no se actualizó. No existe otro mecanismo de backup que cubra estas cinco colecciones.

#### [ALTA] AGENTE_CONVERSACIONES sin regla en firestore.rules — permission-denied en el dashboard del agente
- **Área:** infra-config · **Archivo:** `firestore.rules:1505` · **Confianza del revisor:** alta
- La colección AGENTE_CONVERSACIONES es escrita por el bot vía Admin SDK (whatsapp-bot/src/agente.js línea 3015) y leída por el Flutter client en AgenteConversacionesService (lib/features/whatsapp_bot/services/agente_conversaciones_service.dart línea 153). No existe ningún bloque `match /AGENTE_CONVERSACIONES/...` en firestore.rules: cae al catch-all `match /{document=**} { allow read, write: if false; }` de la línea 1505. Toda consulta desde la pantalla admin_agente_conversaciones_screen lanza FirebaseException: permission-denied. El dashboard de conversaciones del agente IA está completamente roto en producción para cualquier usuario.
- **Veredicto del verificador:** La colección AGENTE_CONVERSACIONES no tiene ningún bloque `match` en firestore.rules (grep sin resultados en los 1509 líneas del archivo). El catch-all en firestore.rules:1505 `match /{document=**} { allow read, write: if false; }` deniega toda lectura desde el cliente Flutter. El bot en whatsapp-bot/src/agente.js:21 usa `require('firebase-admin')` (Admin SDK), por lo que sus escrituras no pasan por las rules y funcionan correctamente. El lector afectado es agente_conversaciones_service.dart:153, que usa `FirebaseFirestore.instance` (client SDK autenticado, sujeto a rules). La pantalla admin_agente_conversaciones_screen.dart:36 llama a ese stream directamente; el guard `_protegerAdmin` en app_router.dart:402 es solo UI-side y no suple la regla faltante. Toda query desde el dashboard lanza permission-denied en producción.

#### [ALTA] POLITICA_PRIVACIDAD.md: afirma falsamente que no se rastrea la ubicación del vehículo de forma continua
- **Área:** docs-onboarding · **Archivo:** `POLITICA_PRIVACIDAD.md:59` · **Confianza del revisor:** alta
- La línea 59 dice literalmente: 'no se rastrea continuamente la ubicación del vehículo, solo el punto donde se generó la alerta'. En realidad SITRACK_POSICIONES se pollea cada 5 minutos y todos los registros se persisten en Firestore (confirmado en functions/src/sitrack.ts y en docs/SITRACK_DEPLOY.md). Adicionalmente la privacy policy omite por completo: REGISTRO_JORNADAS (horas de manejo, pausas con timestamps, análisis de velocidad), AGENTE_CONVERSACIONES (historial de conversaciones WhatsApp procesadas por Gemini AI), SITRACK_EVENTOS (30 campos por evento incluyendo iButton y speed), e HISTORICO_IBUTTONS. El incumplimiento afecta Ley 25.326 (Argentina), el App Store Review Guidelines 5.1.1 (Data Collection and Storage) y el Play Store Data Safety. Un inspector de Apple o un chofer que lea la política puede detectar la contradicción.
- **Veredicto del verificador:** La oración específica de la línea 59 NO es técnicamente falsa: la sección 3.4 está explícitamente acotada a "vehículos Volvo de la flota / API oficial de Volvo Connect", y esa API sí dispara solo eventos puntuales (sitrack.ts línea 47-51 confirma: "Volvo Vehicle Alerts solo nos dispara eventos puntuales, no la posición continua"). El bug confunde dos integraciones distintas. SIN EMBARGO, el hallazgo de fondo es real: la política omite por completo la integración Sitrack — que incluye SITRACK_POSICIONES (snapshot cada 5 min, un doc por patente sin historial) y SITRACK_EVENTOS (eventos discretos persistidos con TTL, 30 campos por evento incluyendo iButton, speed y posición GPS) — además de REGISTRO_JORNADAS (horas/pausas con timestamps), AGENTE_CONVERSACIONES (whatsapp-bot/src/agente.js:3015, guarda DNI + teléfono + pregunta + respuesta del chat IA, TTL 60d) e HISTORICO_IBUTTONS. Ninguno de estos aparece en la tabla de proveedores ni en la sección 3. La omisión es real y debe corregirse, pero la severidad "critica" está inflada: la app es exclusivamente B2B/interna (empleados autenticados con DNI, acceso no público), no hay consumidores finales expuestos, y el riesgo inmediato de enforcement App Store / Play Store por este gap es bajo comparado con una app de consumo. Severidad ajustada a alta.

#### [ALTA] docs/EMAIL_SITRACK_API.md: credenciales de servicio web Sitrack expuestas en texto plano
- **Área:** docs-onboarding · **Archivo:** `docs/EMAIL_SITRACK_API.md:26` · **Confianza del revisor:** alta
- El archivo contiene el usuario 'ws41629VecchiSRL' en texto claro como parte de un template de email. Si bien la contraseña '[contraseña redactada]' no aparece explícitamente en el fragmento visible del doc, este archivo está commiteado en el repositorio git (no es un secret ignorado por .gitignore). Cualquier persona con acceso de lectura al repo puede recuperar estas credenciales del historial git.
- **Veredicto del verificador:** El bug es real y la severidad reportada es correcta, pero el hallazgo original subestimó el alcance: la contraseña [redactada] SÍ está commiteada explícitamente en el repo, no solo en el archivo señalado sino en docs/SITRACK_DEPLOY.md:17 (comentario de setup: "# Cuando te pida el valor, pegá: [contraseña redactada]") y en ESTADO_PROYECTO.md:8 (log de sesión que la menciona en texto plano). El archivo docs/EMAIL_SITRACK_API.md:26 solo expone el usuario "ws41629VecchiSRL", que además aparece en 10+ archivos adicionales (functions/src/sitrack.ts, functions/src/excluidos.ts, scripts/*.js, RUNBOOK.md). Agravante crítico: el repositorio GitHub es PÚBLICO (gh repo view confirma isPrivate:false), lo que significa que estas credenciales son accesibles a cualquier persona en internet desde el primer commit que las introdujo (a961f37, 2026-05-07 para SITRACK_DEPLOY.md; 5f9652f para EMAIL_SITRACK_API.md). La contraseña en producción activa está en Google Cloud Secret Manager (SITRACK_PASSWORD via defineSecret en functions/src/sitrack.ts:31), por lo que la pregunta inmediata es si la contraseña [redactada] del doc es la misma que está en el secret — si lo es, la credencial debe rotarse en el portal Sitrack antes de eliminar los archivos del historial git.

#### [MEDIA] Parcial success en _guardar: viaje creado sin remito, reintento genera duplicado
- **Área:** logistica-ui · **Archivo:** `lib/features/logistica/screens/logistica_viaje_form_screen.dart:580` · **Confianza del revisor:** alta
- En _guardar, crearViaje escribe el doc en Firestore, y luego subirRemito() hace un upload separado. Si la red cae entre esos dos pasos, el viaje queda en Firestore sin URL de remito pero el operador ve un error genérico 'No se pudo guardar el viaje'. Al reintentar, la detección de duplicados (últimas 24h, mismo chofer + tarifa IDs) aplica solo en modo alta y no distingue el doc ya creado del nuevo intento, generando un segundo viaje idéntico. El primer viaje huérfano no tiene remito y no hay pantalla de 'retomar'.
- **Veredicto del verificador:** El flujo parcial es alcanzable. En `_guardar` (logistica_viaje_form_screen.dart:777-835), `ViajesService.crearViaje` hace `docRef.set(data)` y retorna el `viajeId` antes de que empiece el loop de `subirRemito` (línea 810). Si la red cae durante `putData` (timeout 30s configurado en viajes_service.dart:778), la excepción sube al `catch` de línea 890, se muestra "No se pudo guardar el viaje" y `_guardando` se resetea — el viaje ya existe en Firestore con `activo: true` pero sin `remito_url`. En el reintento, `buscarPosiblesDuplicados` (viajes_service.dart:111-116) busca `activo==true AND creado_en > corte AND chofer_dni == choferDni` y filtra por `tarifaId`, por lo que el doc huérfano ya escrito ES encontrado como candidato y se muestra el dialog. El problema es que el dialog pregunta "¿es un viaje distinto?" — el operador, creyendo que el primer intento falló completamente, muy probablemente confirma "Sí, guardar igual", creando un segundo doc idéntico. Sin embargo: (a) la falla requiere que el operador haya adjuntado un remito al crear (condición `remitoBytesPendientes != null`, no siempre presente), (b) no hay corrupción de montos (todos los campos financieros quedaron correctos en el primer write), (c) el viaje huérfano es editable desde la lista para agregar el remito faltante y el duplicado puede eliminarse con soft-delete. La severidad alta está inflada: no hay pérdida de datos financieros, el impacto es un doc duplicado en la lista que el operador admin puede limpiar.

#### [MEDIA] Stream VOLVO_ALERTAS sin límite de documentos en mapa Volvo
- **Área:** icm-eco · **Archivo:** `lib/features/eco_driving/screens/admin_mapa_volvo_screen.dart:113` · **Confianza del revisor:** alta
- El stream de `VOLVO_ALERTAS` en `_AdminMapaVolvoScreenState.build()` (líneas 113–118) filtra por `creado_en >= _desde` y aplica `orderBy`, pero no tiene `.limit()`. Con rango de 90 días y ~50 unidades Volvo generando alertas cada 5 minutos en múltiples tipos, la colección puede tener fácilmente decenas de miles de documentos. El stream descarga TODOS al cliente en tiempo real: lectura de Firestore ilimitada (costo directo), presión de memoria en Windows desktop y en iOS/Android, y un snapshot completo en cada cambio. Si se selecciona el rango máximo de 90 días habitual, esto dispara un listener con N documentos sin cap que crece con el tiempo.
- **Veredicto del verificador:** El stream en `lib/features/eco_driving/screens/admin_mapa_volvo_screen.dart` líneas 113–118 confirma la ausencia de `.limit()`: solo tiene `where creado_en >= _desde` y `orderBy creado_en descending`. El volumen real está documentado en `functions/src/resumenes_diarios.ts` línea 885 ("Volvo genera ~50-200 alertas/día normales"), no "cada 5 minutos por unidad" como implicaba el reporte: el techo real es 200/día × 90 días = ~18,000 docs, no decenas de miles. La TTL de 12 meses existe como campo `expira_en` en cada doc (`volvo.ts` línea 632–635), pero la policy de Firestore sigue siendo un comentario pendiente ("Activar policy con: gcloud…") sin evidencia de ejecución en PENDIENTES.md ni en commits — los docs se acumulan sin expiración real. El bug es alcanzable: cualquier admin que abra la pantalla con rango 90 días abre un listener sin tope que crece con el tiempo. La severidad "alta" está inflada: es pantalla admin exclusiva (no chofer), y el volumen real es 1-2 órdenes de magnitud menor al sugerido; el impacto es costo Firestore (lecturas por sesión abierta) y memoria moderada, no colapso de app.

#### [MEDIA] Unicode minus (U+2212) rompe parseo silencioso de vértices del polígono
- **Área:** mapa-zonas-cachatore-ui · **Archivo:** `lib/features/zonas_descarga/screens/admin_zonas_descarga_screen.dart:630` · **Confianza del revisor:** alta
- El método `_parsearVertices` llama `double.tryParse(partes[0])` sobre cada vértice pegado desde el clipboard. Dart `double.tryParse` solo acepta el guión ASCII (U+002D) como signo negativo; el guión largo/minus de Unicode (U+2212, '−') que usan Google Maps, Wikipedia y otros devuelve null. El resultado es que el punto se descarta silenciosamente (el if `lat != null && lng != null` falla) y el vértice no aparece en el polígono ni en el mapa, sin warning. El comentario en la línea 620 dice explícitamente 'Tolera −38.35274, −68.71163' con el carácter U+2212, pero el código no lo hace. Un operador que pega coordenadas del formato 'lat, lon' de Google Maps puede terminar con un polígono roto (menos de 3 puntos) o directamente vacío.
- **Veredicto del verificador:** Bug real y verificado en `admin_zonas_descarga_screen.dart:630-631`. `double.tryParse` con U+2212 retorna `null` — confirmado ejecutando Dart 3.12.0 en el mismo repo. El método `_parsearVertices` (línea 621-635) aplica solo `replaceAll(RegExp(r'[,;\s]+'), ' ')` antes del parse: no hay ninguna normalización del unicode minus. El comentario de la línea 620 ("Tolera '−38.35274, −68.71163'") usa el propio carácter U+2212 y es una mentira de documentación. La severidad se ajusta a MEDIA (no alta): si TODOS los vértices copiados vienen con U+2212, el validator de la línea 823-825 atrapa el caso (`pts.length < 3` → "Mínimo 3 puntos") y bloquea el guardado con error visible al usuario. Sin embargo, si una mezcla de formatos resulta en ≥3 puntos válidos y otros se descartan silenciosamente, el polígono queda geométricamente corrupto sin ningún aviso — el operador cree haber guardado la geocerca correcta pero la zona tiene vértices faltantes. El hintText (línea 816) usa ASCII `-` correctamente, lo que reduce la probabilidad de exposición, pero cualquier pegado desde Google Maps Earth o Wikipedia podría disparar el bug.

#### [MEDIA] cierreActivo() Firestore error retorna false: toda la corrida de cierres se saltea silenciosamente
- **Área:** fx-jornadas · **Archivo:** `functions/src/cierre_reportes_jornada.ts:212` · **Confianza del revisor:** alta
- La función cierreActivo() tiene un catch que retorna false ante cualquier error de Firestore (quota, timeout, network). Retornar false hace que el cron considere el módulo APAGADO y salte todos los reclamos sin escribir nada. El log solo dice 'APAGADO · N reclamos pendientes', que es indistinguible del kill-switch real. En la primera semana de operación del cron (activo desde 2026-06-11) cualquier spike de Firestore a las 08:00 deja todos los reclamos del día sin procesar, y Santiago lo descubrirá recién cuando los choferes se quejen de no haber recibido respuesta. Impacto: todos los reclamos de jornada quedan en estado 'pendiente' para siempre hasta que una corrida exitosa los procese — ese día puede ser el siguiente si el problema fue puntual, o nunca si el doc META no existe (caso nuevo deploy sin seeding). Fix: ante error de lectura del flag, loguear warn y retornar true (activo) en lugar de false, que es la semántica declarada en el comentario.
- **Veredicto del verificador:** El bug es real pero la severidad está inflada y la descripción del impacto es parcialmente incorrecta. En cierre_reportes_jornada.ts:217-219, el catch devuelve false ante cualquier error de Firestore al leer el flag. Esto es intencional por comentario en línea 218 ("no arriesgamos esta corrida"), pero es el comportamiento incorrecto desde la semántica declarada en el encabezado (líneas 21-22: "Sin ese doc — o con activo:true — corre normal") que equipara doc ausente con activo, no error de red con apagado. Efecto real: el cron corre en modo "dry-run" involuntario. PERO la descripción de "silencioso" es incorrecta: en la línea 282-290 se loguea "[cierreReportesJornada] APAGADO · N reclamos", y en el loop (líneas 324-333) se loguea cada veredicto por reclamo ("CIERTO", "NO_CIERTO", "MANUAL") — no es indistinguible de un kill-switch real porque el kill-switch real tampoco loguea verdicts individuales si el cron se saltea antes... espera, NO: el loop corre igual con activo=false hasta el guard de línea 335 que solo saltea el .update(). Es decir, en ambos casos (kill-switch manual Y error Firestore) los logs son idénticos. El impacto real es: reclamos quedan en estado pendiente ese día, el cron del día siguiente los reintenta, sin pérdida permanente salvo que el doc META no exista por deploy nuevo (aunque en ese caso snap.exists=false retorna true correctamente en línea 216, por lo que ese sub-caso no aplica). La severidad crítica está inflada: no hay pérdida de datos permanente, hay recuperación automática al día siguiente, y los errores de Firestore en Cloud Functions dentro del mismo proyecto son infrecuentes. Severidad real: media.

#### [MEDIA] Firestore Security Rules sin ningún test
- **Área:** tests-cobertura · **Archivo:** `firestore.rules:1` · **Confianza del revisor:** alta
- Las reglas de Firestore no tienen tests en ninguna capa (no existe functions/src/__tests__/, no hay firebase-functions-test ni @firebase/rules-unit-testing). Un error de regla puede exponer datos sensibles (DNI, salarios, jornadas) a cualquier usuario autenticado. La auditoría de 2026-05-30 ya identificó 5 fixes de seguridad — sin tests esos fixes no están protegidos contra regresión.
- **Veredicto del verificador:** El hallazgo es real: no existe ningún paquete `@firebase/rules-unit-testing` ni ningún test de rules en el proyecto (confirmado revisando `functions/package.json` líneas 18-33 y todos los archivos en `functions/test/`). Los propios comentarios en `functions/test/helpers.test.js:9` y `functions/test/jornadas_v2_helpers.test.js:10` reconocen explícitamente que el testing con emulator queda como "trabajo aparte". Las reglas de `firestore.rules` son 1510 líneas con fixes de seguridad no triviales (ej. whitelist de `campo` en REVISIONES líneas 221-224 que previene escalada de privilegios, whitelist de campos en VOLVO_ALERTAS líneas 563-565) — ninguno tiene cobertura de regresión. Sin embargo, las reglas en sí están correctamente escritas con fallback seguro (`allow read, write: if false` en línea 1505), por lo que no hay exposición activa: el riesgo es que una edición futura rompa una regla sin que nadie lo detecte automáticamente. La severidad `critica` está inflada: es una brecha de red de seguridad (sin net de regresión), no una vulnerabilidad en producción hoy.

#### [BAJA] JornadaDia.fromDoc: cast no-null en Timestamp causa TypeError en runtime
- **Área:** jornadas-flutter · **Archivo:** `lib/features/jornada_historico/models/jornada_dia.dart:81` · **Confianza del revisor:** alta
- Las líneas 81-82 (JornadaDia), 119-120 (TramoManejo) y 154-155 (Parada) usan `(m['x'] as Timestamp).toDate()` sin el operador nullable `?`. Si algún doc de VOLVO_JORNADAS_HISTORICO tiene `inicio`, `fin`, `desde` o `hasta` ausentes o nulos (doc corrupto, escrito antes de que el campo existiera, o error en la CF reconstruirJornadasDiario), el `fromDoc` lanza TypeError que propaga como error al StreamBuilder, rompiendo toda la pantalla JornadaDiaScreen. El modelo v3 hermano (registro_jornada.dart) hace esto correctamente con `(m['x'] as Timestamp?)?.toDate() ?? DateTime.fromMillisecondsSinceEpoch(0)` en todos sus campos. El chofer o admin ve AppErrorState en vez de su jornada, y el stream no se recupera sin recargar.
- **Veredicto del verificador:** El cast no-null existe y está confirmado en lib/features/jornada_historico/models/jornada_dia.dart líneas 81-82, 119-120 y 154-155. Sin embargo, la CF única escritora (functions/src/jornada_historico.ts) SOLO persiste un doc cuando reconstruirJornadaDia() devuelve no-null (línea 232: `if (tramos.length === 0) return null`), y en ese punto inicio/fin/desde/hasta son objetos Date derivados de eventos reales; jornadaToFirestore() los serializa con Timestamp.fromDate() sin posibilidad de null. No existe ningún otro escritor de VOLVO_JORNADAS_HISTORICO en el repo. El crash es real si se escribe un doc malformado manualmente o desde un futuro writer que no respete el invariante, pero hoy no hay camino alcanzable en producción que lo dispare. La severidad alta está inflada: con un único writer tipado en TypeScript que garantiza los campos, el riesgo real es bajo.

#### [BAJA] cerrarReportesJornadaDiario no tiene lock de idempotencia: doble disparo GCP procesa los mismos reclamos dos veces
- **Área:** fx-jornadas · **Archivo:** `functions/src/cierre_reportes_jornada.ts:277` · **Confianza del revisor:** alta
- Todos los crons de resúmenes diarios usan adquirirIdempotenciaDiaria para garantizar que un retry o double-trigger de GCP Cloud Scheduler no envíe el mensaje dos veces. cerrarReportesJornadaDiario carece completamente de este mecanismo. Si GCP re-dispara el cron (habitual en la ventana de ejecución de Cloud Scheduler, documentado en los comentarios del propio código), dos instancias concurrentes leerán el mismo conjunto de REPORTES_DISCREPANCIA con estado='pendiente', ambas calcularán el mismo veredicto y ambas harán update(). El update en sí es idempotente (mismo veredicto, serverTimestamp diferente). Pero el trigger onReporteDiscrepanciaRevisado (reportes_discrepancia.ts) dispara para CADA escritura — la idempotencia de ese trigger se basa en doc.create() con docId determinístico, por lo que el WhatsApp al chofer solo se manda una vez. Sin embargo el campo revisado_en queda con el timestamp de la segunda escritura, y si las dos instancias corren en paralelo sobre distintos reclamos pueden generar race conditions en el estado de PARADAS_REPORTADAS. El fix es agregar adquirirIdempotenciaDiaria al inicio del cron, igual que los otros 4.
- **Veredicto del verificador:** El gap es real: cerrarReportesJornadaDiario (cierre_reportes_jornada.ts:277) no llama a adquirirIdempotenciaDiaria, a diferencia de los 4 crons de resumenes_diarios.ts. Sin embargo el impacto concreto es mínimo: el único efecto observable de un doble disparo es que revisado_en queda con el timestamp de la segunda escritura en lugar de la primera (doc.ref.update es idempotente en todos los demás campos). El trigger onReporteDiscrepanciaRevisado (reportes_discrepancia.ts:102) se dispara dos veces, pero su propia idempotencia — COLA_WHATSAPP.doc('devolucion__${reporteId}__${veredicto}').create() con docId determinístico, lines 144-169 — garantiza que el WhatsApp al chofer se encola UNA sola vez; el segundo create() falla con ALREADY_EXISTS y se descarta silenciosamente. La afirmación sobre race conditions en PARADAS_REPORTADAS es incorrecta: esa colección no es tocada por este cron en ninguna línea de cierre_reportes_jornada.ts; la escribe un cron completamente distinto (paradas_reportadas.ts, 07:00 ART). El bug merece un fix preventivo (agregar el lock igual que los otros 4 crons), pero la severidad reportada como 'alta' está inflada: el daño real es cosmético (timestamp levemente diferente) con cero riesgo de mensaje duplicado al chofer.

#### [BAJA] zonaDescargaPoller: batch único sin control de tamaño puede superar 500 ops
- **Área:** fx-integraciones · **Archivo:** `functions/src/zonas_descarga.ts:238` · **Confianza del revisor:** alta
- Se crea un único `db.batch()` que acumula ops de los pasos 4, 4b y 5 sin nunca hacer flush intermedio. El máximo teórico es (unidades × zonas × 1 set) + (unidades_por_evento × zonas × 1 set) + (cola_salientes × 2 ops histórico+delete). Con 55 tractores y 10 zonas activas esto suma ~1100 ops, excediendo el límite de 500 de Firestore. Hoy con pocas zonas no explota, pero agregar zonas nuevas rompe el cron en producción con 'INVALID_ARGUMENT: maximum 500 writes per commit'. El cron en vivo de descargas deja de funcionar completamente hasta que se corrija.
- **Veredicto del verificador:** El bug estructural existe: `zonas_descarga.ts:238` crea un único `db.batch()` y lo commitea en la línea 411 sin ningún flush intermedio. El contador `writes` acumula ops de los tres pasos sin guardia. Sin embargo, la severidad "alta" está inflada porque el cálculo del auditor asume que los pasos 4+4b y el paso 5 pueden ser simultáneamente máximos, ignorando la invariante del código: `visitadosCola` hace que el conjunto de unidades-zonas que escriben en los pasos 4+4b sea estrictamente DISJUNTO del que procesa el paso 5 (línea 362). El peor caso real es max(writes_dentro, writes_cola_saliente × 2), no su suma. Con las zonas operativas actuales (pocas, no superpuestas, distribuidas en distintas ciudades) en un tick típico hay 5-10 camiones dentro de zonas y otros pocos saliendo, resultando en decenas de writes, muy lejos de 500. Para superar 500 se necesitarían ~50+ tractores simultáneamente en zona (físicamente imposible con zonas geográficamente dispersas) o decenas de zonas superpuestas en el mismo punto. El riesgo crece si se agregan muchas zonas solapadas, pero no hay evidencia de esa tendencia operativa. La corrección (chunk batches a 400 ops) es deseable como hardening preventivo, pero no es urgente con la configuración de producción actual.

#### [BAJA] README.md: crons catalog obsoleto (última actualización 2026-05-18), omite 10+ funciones deployadas
- **Área:** docs-onboarding · **Archivo:** `README.md:111` · **Confianza del revisor:** alta
- El header de la sección crons dice 'última actualización 2026-05-18'. No aparecen en el catálogo: cerrarReportesJornadaDiario, bot_alerta_externa, paradas_reportadas, reportes_discrepancia, cierre_reportes_jornada, volvo_estado, canales_pausados, jornadas_v3_batch, ni tampoco vigías watchdog. Un desarrollador que lea el README para entender qué corre en Cloud Scheduler tendrá una imagen incompleta y puede dejar funciones sin monitorear durante un incidente.
- **Veredicto del verificador:** El README.md línea 111 tiene "última actualización 2026-05-18" y lista 15 crons. El código fuente tiene 24 funciones `onSchedule` reales. Los 9 ausentes confirmados son: `cerrarReportesJornadaDiario` (cierre_reportes_jornada.ts:277), `registrarJornadasV3Diario` (jornadas_v3_batch.ts:372), `cruzarParadasReportadasV3Diario` (paradas_reportadas.ts:295), `backfillDescargasDiario` (historico_descargas.ts:442), `reconstruirJornadasDiario` (jornada_historico.ts:408), `reconstruirHistoricoIButtonsDiario` (historico_ibuttons.ts:172), `zonaDescargaPoller` (zonas_descarga.ts:103), `resumenMantenimientoVehiculosDiario` (volvo_mantenimiento.ts:245), `estadoVolvoPoller` (volvo_estado.ts:250). Sin embargo, tres nombres del bug report (`bot_alerta_externa`, `canales_pausados`, `reportes_discrepancia`) no tienen `onSchedule` en su código — son módulos normales, no crons. El impacto es puramente documental: las funciones se ejecutan desde Cloud Scheduler independientemente del README, y el proyecto es bus-factor-1 con un solo operador que conoce el sistema. No hay riesgo operativo real — el README no es la fuente de verdad de monitoring en producción. Severidad inflada de alta a baja.

#### [BAJA] README.md: lista de features de Flutter omite 8 módulos que ya están en lib/features/
- **Área:** docs-onboarding · **Archivo:** `README.md:60` · **Confianza del revisor:** alta
- El README documenta 16 features pero lib/features/ tiene 24 directorios reales. Los ausentes son: administracion, auditoria_asignaciones, cachatore, empresas_empleadoras, icm, jornada_historico, registro_jornadas, vista_ejecutiva, zonas_descarga. Un incorporado que siga el README para orientarse en el árbol de archivos ignorará módulos enteros en producción.
- **Veredicto del verificador:** El bug es real pero la severidad está inflada. README.md líneas 57-60 lista 16 features (incluyendo `sync_dashboard` que ya no existe) mientras que `lib/features/` tiene 24 directorios reales, con 9 módulos ausentes: administracion, auditoria_asignaciones, cachatore, empresas_empleadoras, icm, jornada_historico, registro_jornadas, vista_ejecutiva, zonas_descarga. Sin embargo, el README declara explícitamente en la línea 81 que su propósito es únicamente "Onboarding inicial. Cómo arrancar el proyecto la primera vez." y redirige a `ESTADO_PROYECTO.md` para "Handoff completo. Stack, arquitectura, convenciones, decisiones técnicas". ESTADO_PROYECTO.md cubre exhaustivamente todos los módulos faltantes. Un incorporado que siga el flujo documentado en el README (leer README para arrancar, luego ESTADO_PROYECTO.md antes de cambiar algo) no ignorará esos módulos. La severidad correcta es baja: es un issue de doc stale en el archivo de onboarding ligero, sin impacto funcional ni riesgo operativo.


# 2. Bugs reportados sin verificación adversarial (74)

Severidad media/baja — el revisor los reportó pero no pasaron por el verificador independiente (solo se verificaron críticos/altos). Tomar como "a revisar", no como confirmados.

#### [MEDIA] docs/APP_STORE_LISTING.md: Privacy URL apunta al dominio firebase hosting antiguo y versión 30+ releases atrás
- **Área:** docs-onboarding · **Archivo:** `docs/APP_STORE_LISTING.md:1` · **Confianza del revisor:** alta
- La Privacy URL en el listing es 'https://coopertrans-movil.web.app/privacidad' (Firebase Hosting antiguo, no cooper-trans.com.ar). La referencia de versión en 'qué hay de nuevo' menciona '1.0.57+60' mientras el proyecto ya está en 1.2.28+10228. Si este documento se usa como base para la próxima actualización del listing sin revisión, se publicará información de versión incorrecta y el link de privacidad podría dar 404 si Firebase Hosting se da de baja.

#### [MEDIA] SITRACK_DEPLOY.md: región GCP us-central1 en lugar de southamerica-east1
- **Área:** docs-onboarding · **Archivo:** `docs/SITRACK_DEPLOY.md:42` · **Confianza del revisor:** alta
- Los comandos gcloud scheduler usan --location=us-central1. El proyecto migró a southamerica-east1 el 2026-05-02 (confirmado en ESTADO_PROYECTO.md y en memories). Si un desarrollador ejecuta los comandos tal cual, los jobs de Cloud Scheduler no se crearán en la región correcta y las funciones de southamerica-east1 no los verán.

#### [MEDIA] RUNBOOK.md: conteo de tests obsoleto (275 Flutter; CI section: '67 tests')
- **Área:** docs-onboarding · **Archivo:** `RUNBOOK.md:1200` · **Confianza del revisor:** alta
- El quick-diagnostics de RUNBOOK.md dice '275 tests cliente (al 2026-05-13)' y la sección CI/CD menciona '67 tests' para el job Flutter. Las suites reales al 2026-06-10 son 458 Flutter + 294 functions + 262 bot (confirmado en ESTADO_PROYECTO.md sección 19 y en los commits recientes). Durante un rollback el operador podría confundir una regresión legítima con 'los tests que faltan' al ver más tests de los esperados.

#### [MEDIA] README.md: procesarSilenciadosExpirados documentado como 'cada 1h' pero corre cada 10 minutos
- **Área:** docs-onboarding · **Archivo:** `README.md:124` · **Confianza del revisor:** alta
- functions/src/mantenimiento.ts línea 508 tiene schedule: 'every 10 minutes'. El README lo lista con frecuencia incorrecta. Impacto operativo: si alguien ajusta la función basándose en el README asumirá que el volumen de ejecuciones es 6x menor de lo real, afectando estimaciones de costo y cuota de Firestore reads.

#### [MEDIA] commands_identidad.test.js: _resolverChoferPorTelefono no prueba la reconciliación del '9' móvil
- **Área:** tests-cobertura · **Archivo:** `whatsapp-bot/test/commands_identidad.test.js:24` · **Confianza del revisor:** alta
- Los tests cubren match exacto, inactivos y fail-safe, pero no prueban el caso en que el TELEFONO en Firestore tiene el '9' móvil (5492915...) y el ID de WhatsApp llega sin el '9' (542915...). Este es exactamente el bug B3 ya fixeado en message_handler — pero commands usa su propio resolver y no está verificado que también reconcilia el canónico.

#### [MEDIA] agente.test.js: tests de _toolsGemini no verifican roles SUPERVISOR ni PLANTA con tools de acción
- **Área:** tests-cobertura · **Archivo:** `whatsapp-bot/test/agente.test.js` · **Confianza del revisor:** alta
- Los tests de _toolsGemini cubren CHOFER, ADMIN, SEG_HIGIENE, PLANTA y GOMERIA. No existe ningún test que verifique que el rol SUPERVISOR tiene acceso correcto a sus tools de acción (crear_adelanto, etc.) ni que un rol desconocido/null no recibe tools que no debería. Una regresión en el switch de roles del agente podría dar tools de ADMIN a SUPERVISOR o dejar a SUPERVISOR sin tools de acción.

#### [MEDIA] Índice compuesto faltante en GOMERIA_MONTAJES para query unidad_id + posicion + hasta
- **Área:** infra-config · **Archivo:** `firestore.indexes.json:386` · **Confianza del revisor:** alta
- MontajesService (lib/features/gomeria/services/montajes_service.dart) ejecuta en dos lugares (líneas ~348-352 y ~575-580) la query .where('unidad_id').where('posicion').where('hasta', isNull: true).limit(1). Firestore requiere un índice compuesto cuando se combinan 3+ filtros de igualdad sobre campos distintos con isNull. El índice declarado en firestore.indexes.json solo cubre dos campos (unidad_id + hasta). En producción Firestore lanzará 'FAILED_PRECONDITION: The query requires an index' durante el flujo de instalar/rotar cubiertas en el módulo Gomería V2, bloqueando esas operaciones en el piso de la gomería.

#### [MEDIA] orquestador.py no verifica doble reserva tras 'reserva sin confirmar'
- **Área:** python-servicios · **Archivo:** `cachatore/orquestador.py:119` · **Confianza del revisor:** alta
- En el worker del orquestador, cuando reservar() devuelve un resultado no-ok y no-tomado ('revisar' u otro motivo), el código loguea 'reserva sin confirmar; reintento' y duerme POLL_SEG antes de reintentar — sin consultar mis_turnos() para verificar si la reserva en realidad sí entró. vigia.py resuelve este mismo escenario explícitamente (línea 487-500): consulta mis_turnos() antes de reintentar para evitar doble reserva. orquestador.py es el modo 'drop de las 10:30' que ya se usa menos (el vigía latente lo reemplazó), pero sigue instalado como fallback y si alguien lo usa en un drop podría generar una doble reserva para el chofer afectado. Fix: replicar el patrón de vigia.py: antes del siguiente intento, hacer mis_turnos() y si ya tiene turno, retornar.

#### [MEDIA] TTL de chequeos one-shot nunca limpia (TypeError silenciado)
- **Área:** python-servicios · **Archivo:** `cachatore/nube.py:250` · **Confianza del revisor:** alta
- listar_chequeos_resueltos_viejos() compara ts (DatetimeWithNanoseconds de Firestore) con antes_de_ts (datetime tz-aware). Cuando la comparación ts < antes_de_ts lanza TypeError (incompatibilidad de tipos), el except simplemente hace continue — silenciando el error y nunca agregando el doc a la lista de viejos. El comment mismo lo reconoce: 'ts viene como DatetimeWithNanoseconds; comparar con datetime tz-aware'. Contraste con flushear_avisos_encargado (línea 464) que SÍ resuelve el mismo problema con .replace(tzinfo=timezone.utc). Resultado: los docs CACHATORE_CHEQUEOS/{dni} resueltos se acumulan indefinidamente en Firestore. En producción la única forma de limpiarlos es que la UI los borre explícitamente (si el operador cierra la app antes de ver el resultado, quedan para siempre). Fix: replicar el patrón de flushear_avisos_encargado: edad = (antes_de_ts.replace(tzinfo=None) - ts.replace(tzinfo=None)).total_seconds() o usar el mismo try/except con .replace(tzinfo=timezone.utc) como fallback.

#### [MEDIA] canales_pausados: hasta_iso malformada congela el canal pausado para siempre
- **Área:** bot-features · **Archivo:** `whatsapp-bot/src/canales_pausados.js:56` · **Confianza del revisor:** alta
- En estaCanalPausado(), si raw.hasta_iso existe pero no es parseable por Date.parse (valor vacío, timezone raro, string corrupto), Number.isFinite(NaN) == false salta el return false, y la función retorna true (canal pausado) de forma indefinida. El cron de service diario y vencimientos próximos quedan silenciados hasta que el admin corrija el doc META/canales_pausados manualmente — nadie recibe el reporte diario y no hay alerta. El fix es manejar el NaN explícitamente: si el parse falla, tratar como 'sin expiración' (retornar true) está bien, pero debería loguear warn para que el admin lo detecte. Alternativamente: si ms es NaN, asumir que ya expiró (return false) es la postura más segura.

#### [MEDIA] _primerNombreDe en commands.js retorna el APELLIDO en vez del nombre
- **Área:** bot-features · **Archivo:** `whatsapp-bot/src/commands.js:1225` · **Confianza del revisor:** alta
- La función privada _primerNombreDe (usada en los mensajes de /silenciar y /desilenciar al chofer) hace nom.split(/\s+/)[0], que devuelve el PRIMER token del campo NOMBRE. Como el campo sigue el formato 'APELLIDO NOMBRE', retorna el apellido: el chofer recibe 'Hola PEREZ' en lugar de 'Hola Juan'. El bug afecta a los dos únicos mensajes que llegan al chofer desde este módulo (aviso de silencio activo y aviso de reanudación). Por contraste, extraerPrimerNombre en aviso_builder.js (el helper canónico) usa correctamente partes[1]. La corrección es cambiar [0] a [1] — o mejor, reusar resolverNombreSaludo de aviso_builder.

#### [MEDIA] `agente_pedir_llamada` no está en ORIGENES_TIME_SENSITIVE: la llamada urgente al encargado espera hasta las 8 AM
- **Área:** bot-nucleo · **Archivo:** `whatsapp-bot/src/humano.js:30` · **Confianza del revisor:** alta
- `ORIGENES_TIME_SENSITIVE` incluye `agente_registrar_parada` pero no `agente_pedir_llamada`. Cuando un chofer pide al agente que llame a la oficina fuera del horario laboral (por ejemplo ante una emergencia en ruta a las 2 AM), el mensaje al encargado se encola pero `_estaEnHorarioLaboral()` bloquea el envío hasta las 08:00. La parada reportada sí llega de noche (origen `agente_registrar_parada` está en la whitelist), pero la solicitud de llamada queda silenciada. El impacto es que la urgencia comunicada por el chofer no llega al encargado en tiempo real.

#### [MEDIA] `_adelantosPendientes` nunca se barre: fuga de memoria en sesiones largas
- **Área:** bot-nucleo · **Archivo:** `whatsapp-bot/src/agente.js:1199` · **Confianza del revisor:** alta
- El Map `_adelantosPendientes` almacena el estado pendiente de confirmación de cada adelanto (paso 1 → paso 2). El TTL de 5 minutos se chequea únicamente cuando el chofer envía el paso 2 (lazy expiry). El `_sweepTimer` que corre cada 5 minutos (líneas 181-191) solo barre `_histPorClave` y `_rlPorClave`, no toca `_adelantosPendientes`. Entradas expiradas de choferes que iniciaron la creación de adelanto pero nunca confirmaron acumulan indefinidamente. El proceso reinicia a diario vía NSSM (¿?), pero en períodos de alta actividad de muchos choferes el mapa puede crecer sin cota. No hay límite de tamaño ni janitor.

#### [MEDIA] renombrarEmpleadoDni — query sin límite sobre SITRACK_EVENTOS puede timeout
- **Área:** fx-plataforma · **Archivo:** `functions/src/auth.ts:910` · **Confianza del revisor:** alta
- La función `actualizarReferencias` hace un `.get()` sin `.limit()` sobre `SITRACK_EVENTOS` buscando por `driver_dni`. Un chofer activo 2+ años en el sistema puede tener fácilmente 50 000+ eventos (el poller corre cada 5 min y puede traer múltiples eventos por tick). El resultado completo se carga en memoria antes de procesarlo en batches de 500. Con `timeoutSeconds: 60` en `renombrarEmpleadoDni`, la function puede timeout durante la lectura inicial, dejando el estado inconsistente: el doc nuevo de EMPLEADOS ya fue creado pero el doc viejo no fue borrado todavía. La operación no es idempotente (la segunda invocación falla con ALREADY_EXISTS en el doc nuevo). Para VOLVO_ALERTAS el riesgo es menor pero real si la flota lleva años acumulando alertas.

#### [MEDIA] renombrarEmpleadoDni cascada incompleta — colecciones nuevas omitidas
- **Área:** fx-plataforma · **Archivo:** `functions/src/auth.ts:892` · **Confianza del revisor:** alta
- La cascada de `renombrarEmpleadoDni` actualiza `chofer_dni` en ASIGNACIONES_VEHICULO, VOLVO_ALERTAS, COLA_WHATSAPP, SITRACK_EVENTOS, JORNADAS y ADELANTOS_CHOFER, pero omite cuatro colecciones que también guardan `chofer_dni` y fueron agregadas después: `ZONA_DESCARGA_HISTORICO` (historico_descargas.ts), `REGISTRO_JORNADAS` (jornadas_v3_batch.ts), `PARADAS_REPORTADAS` y `REPORTES_DISCREPANCIA` (paradas_reportadas.ts / cierre_reportes_jornada.ts). Consecuencia: tras un renombre de DNI, el ICM del jornada v3, el histórico de descargas YPF, las paradas reportadas por WhatsApp y los reclamos de discrepancia siguen apuntando al DNI viejo. El vigilador v3 y el cruce de paradas no encontrarán los registros previos del chofer renombrado.

#### [MEDIA] historico_ibuttons: persistirTramo es individual (no batch) y se llama con Promise.all
- **Área:** fx-integraciones · **Archivo:** `functions/src/historico_ibuttons.ts:164` · **Confianza del revisor:** alta
- `procesarRango` hace `await Promise.all(tramos.map(persistirTramo))` donde cada `persistirTramo` es un `.set()` individual (no batched). En el cron diario (1 día, ~55 tractores con varios tramos) esto son ~100-200 writes concurrentes. En el callable de backfill con `dias=60` esto se multiplica por 60 iteraciones secuenciales pero cada una lanza sus writes en paralelo. Más allá del desperdicio de conexiones, el backfill puede llegar al límite de concurrencia de Firestore (~500 ops simultáneas) y empezar a recibir errores RESOURCE_EXHAUSTED. Solución: agrupar en batch de 400 como hace `persistirDescargas` en historico_descargas.ts (el patrón correcto ya existe en el mismo repo).

#### [MEDIA] v3ConfirmaPausa — ventana de 'reciencia' usa el timestamp del reclamo original, no la hora de la pausa reclamada
- **Área:** fx-jornadas · **Archivo:** `functions/src/cierre_reportes_jornada.ts:130` · **Confianza del revisor:** alta
- La rama de reciencia en v3ConfirmaPausa busca pausas v3 cuyo finMs esté dentro de [reporteMs - 90min, reporteMs + 30min]. reporteMs es el creado_en del reclamo — la hora en que el chofer lo mandó por WhatsApp. Para un reclamo reciente (el chofer lo mandó el mismo día), la ventana tiene sentido: busca la última pausa en la hora previa al reclamo. Para un reclamo de 3 días atrás procesado hoy, reporteMs es 3 días en el pasado y la ventana también es 3 días en el pasado, solapando con el día de la jornada y puede dar matches espurios o fallar en encontrar la pausa real. Caso concreto: el chofer reclamó ayer a las 20:00 que paró a las 11:00; el cron lo procesa mañana a las 08:00 (creado_en = ayer 20:00). Si v3 no matcheó por hora, la rama de reciencia busca pausas que terminaron entre 18:30 y 20:30 de ayer — que puede ser una pausa completamente diferente a las 11:00 reclamadas, resultando en un CIERTO incorrecto. El fix es no usar la rama de reciencia para reclamos con más de N horas de antigüedad, o pasar siempre a la ventana explícita de la jornada.

#### [MEDIA] eventosGpsDelDia usa boundary '23:59:59' en lugar de medianoche del día siguiente
- **Área:** fx-jornadas · **Archivo:** `functions/src/cierre_reportes_jornada.ts:255` · **Confianza del revisor:** alta
- La query de SITRACK_EVENTOS usa `where('report_date', '<=', Timestamp.fromDate(new Date(fechaArt + 'T23:59:59-03:00')))`. Esto excluye los eventos entre 23:59:59.001 y 23:59:59.999 (submilisegundo de Firestore Timestamps) del día reclamado. En la práctica Sitrack no genera eventos exactamente en ese rango, pero el patrón correcto para toda la app es `where('report_date', '<', Timestamp.fromDate(new Date(diaNext + 'T00:00:00-03:00')))`. Más importante: si un reclamo es por una pausa que el chofer hizo a las 23:58 con un evento Sitrack de 'Fin de detenido' a las 23:59:59.500, ese evento no entraría a analizarGpsVentana y el veredicto sería 'incierto' en lugar de 'cierto'. En el primer día real de operación del cron (hoy) esto ya puede afectar reclamos.

#### [MEDIA] RoleGuard crea un nuevo Future en cada rebuild del padre
- **Área:** nucleo-shared · **Archivo:** `lib/shared/widgets/guards/role_guard.dart:75` · **Confianza del revisor:** alta
- RoleGuard es StatelessWidget. En build(), `future: user.getIdTokenResult()` crea un nuevo Future en CADA rebuild del padre (al rotar pantalla, al cambiar estado global, etc.). El FutureBuilder sin cache dispara un nuevo getIdToken() en cada rebuild, y si falla el JWT, genera además un segundo FutureBuilder anidado con una nueva query Firestore (.doc(dni).get()). Eso produce lecturas Firestore repetidas e innecesarias. Impacto: costos de lectura y latencia extra ante cualquier rebuild. Fix: convertir a StatefulWidget y cachear el Future en initState/didUpdateWidget.

#### [MEDIA] StreamSubscription de notificaciones no se cancela en dispose
- **Área:** nucleo-core · **Archivo:** `lib/main.dart:495` · **Confianza del revisor:** alta
- En _LogisticaAppState.initState, el stream.listen() del selectNotificationStream (línea 495) devuelve un StreamSubscription que nunca se asigna a una variable ni se cancela en dispose(). dispose() solo llama NotificationService.dispose() que cierra el StreamController, pero la suscripción del widget queda viva. En una hot-reload en debug o si el widget se desmonta y remonta, la suscripción previa sigue activa y puede causar navegación fantasma. El patrón correcto es guardar la referencia: StreamSubscription<String?>? _notifSub, asignarla en initState, y cancelarla en dispose.

#### [MEDIA] Stream de histórico de descargas sin límite puede saturar el listener en rangos de 365 días
- **Área:** mapa-zonas-cachatore-ui · **Archivo:** `lib/features/zonas_descarga/screens/admin_descargas_screen.dart:729` · **Confianza del revisor:** alta
- `_DescargasDelRango` usa `.snapshots()` (stream permanente) con `.limit(500)` sobre ZONA_DESCARGA_HISTORICO. El _KpisZona ya fue corregido para usar `.get()` one-shot por la misma razón (auditoría 2026-05-30), pero `_DescargasDelRango` mantiene el stream. Con el date-range picker que permite hasta 365 días, en una operación activa pueden existir cientos de docs llegando continuamente; el stream no se filtra por salida del rango, solo por entrada, y vuelve a emitir el snapshot completo cada vez que cualquier doc cambia en ese rango (por ejemplo cuando se cierra una descarga activa). No es una query sin índice (el índice DESC existe), pero genera lecturas Firestore innecesarias y rebuilds del widget. La alternativa correcta es el mismo patrón que `_KpisZona`: `.get()` one-shot recalculado al cambiar slug/rango vía `didUpdateWidget`.

#### [MEDIA] Año por defecto 2025 hardcodeado en AdminVacacionesScreen
- **Área:** paneles-admin · **Archivo:** `lib/features/administracion/screens/admin_vacaciones_screen.dart:79` · **Confianza del revisor:** alta
- `int _anio = 2025;` mientras que _aniosDisponibles = [2026, 2025, 2024]. En 2026 la pantalla abre mostrando los datos del año anterior, lo que confunde al admin que espera ver el año vigente. El FutureBuilder carga datos para `_anio`, así que el bug es funcional: se muestra data equivocada por defecto. Fix: `int _anio = DateTime.now().year;` o `_aniosDisponibles.first`.

#### [MEDIA] Mutación de _currentIndex dentro de build() sin setState
- **Área:** paneles-admin · **Archivo:** `lib/features/admin_dashboard/screens/admin_shell.dart:307` · **Confianza del revisor:** alta
- La línea `if (_currentIndex >= visibles.length) _currentIndex = 0;` muta estado de instancia directamente dentro de build(), violando el contrato de Flutter. En modo debug activa el assert de dirty-state-during-build. En producción no falla silenciosamente pero puede provocar que el índice visible diverja del estado real si el rebuild se produce mientras Flutter ya está en una fase de layout activa. Fix: mover el clamp a didChangeDependencies() o a un setter que llame setState.

#### [MEDIA] StreamController de _IconoMas nunca se cierra (memory leak)
- **Área:** paneles-admin · **Archivo:** `lib/features/admin_dashboard/screens/admin_shell.dart:709` · **Confianza del revisor:** alta
- _IconoMas es un StatelessWidget cuyo método _hayPendientes() crea un StreamController<bool> nuevo en cada llamada a build() (via listen en onListen). El onCancel cancela las suscripciones pero controller.close() nunca se invoca. En cada rebuild del shell (cambio de sección, resize, rotación) se acumula un controller zombie. En sesiones largas con muchos rebuilds esto puede causar leak de memoria y listeners huérfanos de Firestore que nunca se desuscriben de forma limpia. Fix: convertir _IconoMas a StatefulWidget con el controller inicializado en initState() y cerrado en dispose().

#### [MEDIA] AdminWhatsappHistoricoScreen: consulta con múltiples filtros server-side sin índice compuesto puede fallar en runtime
- **Área:** jornadas-flutter · **Archivo:** `lib/features/whatsapp_bot/screens/admin_whatsapp_historico_screen.dart:103` · **Confianza del revisor:** alta
- El método `_ejecutarConsulta` pasa simultáneamente `estado`, `destinatarioId` y `origen` a `WhatsAppHistoricoService.consultar()`. El servicio los aplica todos al mismo query con `orderBy('registrado_en')`. Los índices de WHATSAPP_HISTORICO solo cubren pares (destinatario_id + registrado_en), (origen + registrado_en), (estado + registrado_en) — no existe índice para combinaciones de dos o más campos de igualdad con el rango de fechas. Si el admin completa DNI + estado (2 filtros activos), Firestore lanza un error 'no index found' que la pantalla muestra como AppErrorState. El UI muestra un warning visible (línea 251) pero igual ejecuta la consulta, por lo que el flujo falla en runtime en vez de prevenirlo.

#### [MEDIA] _combinarRegistros: descansoPrevioSeg siempre del primer turno, misleads al admin en vista combinada
- **Área:** jornadas-flutter · **Archivo:** `lib/features/registro_jornadas/screens/admin_registro_jornada_screen.dart:507` · **Confianza del revisor:** alta
- Al fusionar N turnos, `descansoPrevioSeg` se toma siempre del primer (más viejo) de los registros, ignorando los de los siguientes. El flag `descansoInsuficiente` se OR-reduce correctamente (línea 482), así que el badge de alerta puede encenderse correctamente. Pero el badge muestra `'Descanso previo ${_hm(j.descansoPrevioSeg!)}'` (registro_jornada_card.dart línea 103) con el tiempo del primer turno aunque el infractor sea el segundo. Si el admin revisa compliance de un chofer que tuvo descanso insuficiente entre turno-lunes y turno-martes, la vista combinada le muestra el descanso previo al lunes, no el gap lunes→martes que es el real problema.

#### [MEDIA] cancelAll() en reagendar recordatorios borra notificaciones NO de vencimientos
- **Área:** reportes-vencimientos · **Archivo:** `lib/core/services/notification_service.dart:264` · **Confianza del revisor:** alta
- cancelarTodosLosRecordatorios() llama a _notificationsPlugin.cancelAll() que cancela TODAS las notificaciones pendientes del plugin, incluyendo las agendadas de otros canales si en el futuro alguna usa zonedSchedule. Por ahora solo vencimientos usan zonedSchedule, así que el impacto es nulo en producción; pero si se agrega una notificación agendada de otro tipo (ej. recordatorio de checklist del día 14), el admin o chofer perderá esa notificación cada vez que el chofer abra MIS VENCIMIENTOS. El método está documentado como 'cancela recordatorios agendados' pero implementado como 'cancela todo' — divergencia entre nombre y comportamiento que se va a activar en la primera extensión.

#### [MEDIA] EcoDrivingService instanciado en build() de StatelessWidget — streams se re-abren en cada rebuild
- **Área:** icm-eco · **Archivo:** `lib/features/eco_driving/widgets/score_drilldown_sheet.dart:33` · **Confianza del revisor:** alta
- `ScoreDrilldownSheet.build()` instancia `EcoDrivingService()` y `AsignacionVehiculoService()` en líneas 33–34, dentro de un `StatelessWidget`. Cada vez que Flutter reconstruye este widget (p.ej. por cambio en el padre o por el `DraggableScrollableSheet`), se crean nuevos servicios. Los `StreamBuilder` descendientes cancelan el stream anterior y abren uno nuevo, generando lecturas Firestore extras innecesarias durante la vida del sheet. Lo correcto es instanciar los servicios fuera de `build()`, por ejemplo en un `StatefulWidget` o pasarlos como parámetros.

#### [MEDIA] ChoferActividadService: lookups de Sitrack secuenciales dentro del loop de asignaciones
- **Área:** personal · **Archivo:** `lib/features/employees/services/chofer_actividad_service.dart:222` · **Confianza del revisor:** alta
- Para cada asignación activa con `odoIni != null` (puede haber N si el chofer tiene múltiples asignaciones abiertas simultáneamente o si hay datos inconsistentes), se hace `await snapSvc.obtener(patente)` de forma secuencial dentro del bucle for (líneas 221-237). Si hay 3+ asignaciones activas, la latencia se multiplica linealmente. El patrón correcto es acumular todos los futuros y resolverlos con `Future.wait` fuera del loop, como se hace en el bloque inicial de queries paralelas (líneas 133-161).

#### [MEDIA] Botón 'Resetear contraseña' visible para CHOFER/PLANTA sin gate de capability
- **Área:** personal · **Archivo:** `lib/features/employees/screens/admin_personal_lista_widgets.dart:346` · **Confianza del revisor:** alta
- En `_BotonBajaReactivarEmpleado.build` el botón 'Resetear contraseña' (que llama a `confirmarYResetearContrasena`) se muestra sin ningún `Capabilities.can(...)`. La Cloud Function `resetearContrasenaEmpleadoAdmin` valida server-side que el caller sea ADMIN o SUPERVISOR, así que no es un agujero de seguridad real, pero un chofer que abra la ficha de otro empleado (si el routing lo permitiera) o que acceda desde algún path admin vería el botón y recibiría un error opaco 403 sin entender qué pasó. El patrón correcto es envolver con la misma capability gate que `puedeBaja` o agregar una capability `resetearContrasenaEmpleado`.

#### [MEDIA] stockActual() hace full-scan sin límite en colección que crece ilimitadamente
- **Área:** gomeria-checklist · **Archivo:** `lib/features/gomeria/services/montajes_service.dart:75` · **Confianza del revisor:** alta
- stockActual() lee TODOS los documentos de GOMERIA_STOCK_MOVIMIENTOS sin filtros ni límite. Esta función se llama en cada tap de 'Montar' desde gomeria_v2_unidad_screen.dart (línea 467) y en cada apertura del detalle de conteo. Cada montaje, retiro, compra, ajuste agrega un documento permanente. Con ~50 camiones y movimientos frecuentes, en 1-2 años la colección puede tener miles de docs. streamStock() tiene el mismo problema: escucha todos los docs y recalcula en cliente en cada snapshot. Impacto actual bajo pero crece con el tiempo y con el uso del módulo.

#### [MEDIA] Rechazo de revisión no borra el archivo de Storage: storage leak garantizado
- **Área:** gomeria-checklist · **Archivo:** `lib/features/revisions/screens/admin_revisiones_screen.dart:521` · **Confianza del revisor:** alta
- Cuando el admin rechaza un trámite, _procesarDecision(context, false) ejecuta directamente FirebaseFirestore.doc(idDoc).delete() en lugar de llamar a RevisionService.finalizarRevision(aprobado: false). El servicio es el único lugar que borra el archivo de Storage (líneas 389-399 de revision_service.dart). El mensaje de confirmación al usuario dice explícitamente 'Se va a borrar el comprobante que subió el chofer', pero el archivo queda en Storage para siempre. Cada rechazo acumula un archivo huérfano. Además, el audit log se registra igual (como 'rechazarRevision') dando falsa sensación de completitud.

#### [MEDIA] Inconsistencia de cálculo de km restantes: _ResumenService usa INTERVALO_SERVICE_KM del doc pero _resolverServiceDistance usa la constante fija 50000
- **Área:** vehiculos · **Archivo:** `lib/features/vehicles/screens/admin_vehiculos_lista_widgets.dart:1376` · **Confianza del revisor:** alta
- En el bottom sheet de detalle del vehículo, _ResumenService (línea 1376-1383) lee INTERVALO_SERVICE_KM del doc y lo usa como intervalo (fallback a AppMantenimiento.intervaloServiceKm=50000). Pero _resolverServiceDistance en admin_mantenimiento_widgets.dart siempre invoca AppMantenimiento.serviceDistanceDesdeManual, que usa el intervalo fijo 50000 hardcodeado en AppMantenimiento. Si algún tractor tuviera INTERVALO_SERVICE_KM distinto de 50000, el sheet de la lista mostraría un km restante diferente al que muestra la pantalla de mantenimiento preventivo para el mismo vehículo. Por ahora todos los tractores usan 50000, pero el campo ya existe en la lógica y la discrepancia puede aparecer en producción sin aviso.

#### [MEDIA] onCambio (→ setState del padre) llamado sin mounted check en _TramoCard._pickRemito
- **Área:** logistica-ui · **Archivo:** `lib/features/logistica/screens/logistica_viaje_form_tramos.dart:410` · **Confianza del revisor:** alta
- _pickRemito es async: llama FilePicker.pickFiles y luego onCambio(). _TramoCard es StatelessWidget por lo que no tiene acceso a mounted. Si el parent StatefulWidget fue disposed durante la selección de archivo (ej. navegación atrás rápida), onCambio() llama setState() en el padre destruido. En debug mode lanza 'setState() called after dispose()'. En release puede ser silencioso pero indica estado inválido.

#### [MEDIA] Tramos no dispuestos si widget se destruye durante hidratación de borrador
- **Área:** logistica-ui · **Archivo:** `lib/features/logistica/screens/logistica_viaje_form_screen.dart:320` · **Confianza del revisor:** alta
- _hidratarDesdeBorrador es async. Cuando el Future.wait interno resuelve, la función construye nuevos _TramoEditState y los asigna a _tramos ANTES del guard if (!mounted). Si el widget fue disposed entre el await y esa asignación, dispose() ya corrió sobre la lista vacía/anterior, y los nuevos TramoEditState (con TextEditingControllers y listas de gastos) quedan huérfanos sin dispose. Impacto: memory/resource leak de controllers; en debug mode Flutter puede lanzar un assert posterior al usar el controller.

#### [MEDIA] El `streamViajesEnRango` de LIQUIDACIÓN filtra por `fecha_carga` denormalizada del primer tramo, ignorando viajes multi-tramo con primer tramo sin fecha
- **Área:** logistica-negocio · **Archivo:** `lib/features/logistica/services/liquidacion_service.dart:53` · **Confianza del revisor:** alta
- La query de LIQUIDACIÓN usa `fecha_carga` (la del primer tramo, denormalizada al nivel del doc). Un viaje multi-tramo planeado donde el primer tramo todavía no tiene fecha de carga tiene `fecha_carga: null` y el Firestore range query lo EXCLUYE silenciosamente. El viaje existe, está activo, puede tener tramos con fechas en el período, pero no aparece en la liquidación. Puede ser intencional (viaje no iniciado = no liquidable), pero un viaje con tramo 1 sin fecha y tramo 2 ya descargado tampoco aparece. Este borde debe documentarse o validarse explícitamente en la UI.

#### [MEDIA] Scan completo de la colección VIAJES_LOGISTICA en cada recálculo masivo de tarifa
- **Área:** logistica-negocio · **Archivo:** `lib/features/logistica/services/viajes_service.dart:487` · **Confianza del revisor:** alta
- `_recalcularViajesConTarifa` hace `_col.where('activo', isEqualTo: true).get()` — baja TODOS los viajes activos para encontrar los que usan la tarifa cambiada. Con 100 viajes/mes × 12 meses = 1200+ docs, cada cambio de precio hace un full-scan. El impacto actual es bajo (colección chica) pero crece linealmente. El comentario reconoce que Firestore no soporta queries en arrays de objetos. La mitigación correcta es denormalizar un campo `tarifa_ids: List<String>` al nivel del doc, actualizado en `crearViaje`/`actualizarViaje`, que permita un query `arrayContains` directo. Impacto inmediato: lentitud + reads Firestore quemados en cada nuevo precio.

#### [MEDIA] Riesgo real de superar 1 MB del doc ICM_OFICIAL en meses intensos
- **Área:** python-servicios · **Archivo:** `sitrack_sync/sync_icm.py:216` · **Confianza del revisor:** media
- El comentario reconoce '~700 KB para un mes normal de la flota Vecchi (50 choferes × ~33 infracciones promedio)' y que el cap de 100 por chofer da '~30% de margen'. Sin embargo, un mes con alta accidentalidad puede fácilmente llevar a 50 choferes activos × 100 infracciones × ~400 bytes = ~2 MB, superando el límite de 1 MB de Firestore y causando una excepción al escribir el doc (sync falla silenciosamente salvo por el print de 'COMMIT OK' que no aparecería). El riesgo aumenta al crecer la flota o en períodos con muchos incidentes. Fix de bajo riesgo: reducir MAX_INFRAC_POR_CHOFER a 50 (cubre todos los outliers vistos, los 'casos reales de 91' quedan como warning) o migrar las infracciones a una subcolección ICM_OFICIAL/{periodo}/infracciones/{dni}.

#### [BAJA] docs/SETUP_PC_DEDICADA_BOT.md: requiere Node.js 18 en el paso 1 pero el runtime es Node 22
- **Área:** docs-onboarding · **Archivo:** `docs/SETUP_PC_DEDICADA_BOT.md:1` · **Confianza del revisor:** alta
- La sección de instalación manual dice 'Node.js 18 LTS o superior' pero el proyecto usa Node 22 (confirmado en functions/package.json y en el workflow de GitHub Actions). Un operador que instale Node 18 para el bot podría encontrar incompatibilidades con dependencias modernas y no entender por qué el bot no arranca.

#### [BAJA] backup_auth.test.js: test de orden lexicográfico puede empatar en el límite de minuto
- **Área:** tests-cobertura · **Archivo:** `whatsapp-bot/test/backup_auth.test.js:38` · **Confianza del revisor:** alta
- El test 'timestamp ordenable lexicográficamente' llama _construirNombre dos veces consecutivas y verifica n1 <= n2. Si las dos llamadas caen en minutos distintos el assert pasa trivialmente. Si caen en el mismo minuto n1 == n2 también pasa. El test documenta el comportamiento pero tiene precisión a minutos — no detectaría un bug que invierta el orden dentro del mismo minuto. Riesgo de falso-positivo documentado en el propio comentario.

#### [BAJA] Runner.rc muestra CompanyName y LegalCopyright con 'com.example' en lugar de Coopertrans/Vecchi
- **Área:** infra-config · **Archivo:** `windows/runner/Runner.rc:92` · **Confianza del revisor:** alta
- Los campos CompanyName y LegalCopyright en el resource info del ejecutable Windows siguen con el valor de template 'com.example' (líneas 92 y 96). Esto aparece en propiedades del .exe en Windows Explorer y en herramientas de inventario de software. No afecta el funcionamiento pero se ve poco profesional si un auditor de Vecchi revisa las propiedades del instalador o el ejecutable.

#### [BAJA] NSLocationAlwaysAndWhenInUseUsageDescription en iOS Info.plist más permisivo de lo necesario
- **Área:** infra-config · **Archivo:** `ios/Runner/Info.plist:79` · **Confianza del revisor:** alta
- El plist declara NSLocationAlwaysAndWhenInUseUsageDescription además de NSLocationWhenInUseUsageDescription. Fue agregado para silenciar el warning ITMS-90683 de Apple. La app sólo llama Geolocator.requestPermission() (whileInUse), nunca solicita background/always. Tener la key 'always' en el plist no otorga el permiso solo, pero puede generar confusion si en un futuro alguien agrega geolocator con always y Apple lo activa sin el prompt esperado. Además la privacidad.html (sección 9) declara explícitamente que no se accede al GPS en background — si Apple audita el plist vs la política hay inconsistencia.

#### [BAJA] installer/VERSION.txt desactualizado en el repo (1.2.28 vs pubspec 1.2.33)
- **Área:** infra-config · **Archivo:** `installer/VERSION.txt:1` · **Confianza del revisor:** alta
- installer/VERSION.txt contiene '1.2.28+10228' mientras pubspec.yaml está en '1.2.33+10233'. build_installer.ps1 sobreescribe este archivo con la versión real al compilar (línea 77), así que el instalador producido siempre lleva la versión correcta. Sin embargo, si alguien clonaría el repo en una PC nueva y corriera el launcher directo (modo 'sin instalador') usando el VERSION.txt del repo como referencia, vería la versión como 5 releases vieja y descargaría un update innecesario. Impacto operativo bajo porque el flujo normal usa el installer que sobreescribe el archivo.

#### [BAJA] File handle sin cerrar en sync_icm.py y sync_taller.py
- **Área:** python-servicios · **Archivo:** `sitrack_sync/sync_icm.py:365` · **Confianza del revisor:** alta
- json.load(open(_CLAVES, encoding='utf-8')) en sync_icm.py (línea 365) y sync_taller.py (línea 190) abre el archivo sin context manager (sin 'with'). El file handle queda abierto hasta que el GC lo recolecta. En Windows, esto puede dejar un lock activo sobre claves.json mientras el script Playwright corre (potencialmente varios minutos). Si otro proceso (backup_secrets, el vigía al releer claves.json, o un deploy) intenta escribir ese archivo durante ese tiempo, puede fallar con PermissionError. Fix: usar 'with open(...) as f: cfg = json.load(f)'.

#### [BAJA] telefono declarado pero no usado en loop de vencimientos personales y vehiculos (dead code)
- **Área:** bot-features · **Archivo:** `whatsapp-bot/src/cron.js:337` · **Confianza del revisor:** alta
- En el loop de vencimientos personales (línea 337) y de vehículos (línea 403), se declara 'const telefono' inmediatamente después de la validación de normalizarTelefonoAWid, pero esa variable nunca se usa en el cuerpo del loop — los items se acumulan en itemsPorChofer y el teléfono real se lee recién al encolar (línea 484). No hay impacto funcional, pero genera confusión: un lector puede pensar que el teléfono se pasa en algún item y buscar dónde. Puede causar que en un futuro refactor se omita la re-validación del teléfono al encolar.

#### [BAJA] `_toolListarEmpleadosPorRol` omite el cache `_getEmpleadosDocs` y va a Firestore en cada llamada
- **Área:** bot-nucleo · **Archivo:** `whatsapp-bot/src/agente.js:1968` · **Confianza del revisor:** alta
- La función hace `db.collection('EMPLEADOS').where('ROL', '==', rol).get()` directamente en cada invocación, sin pasar por `_getEmpleadosDocs` que cachea el listado de empleados activos por 5 minutos. En contextos de conversación activa (varios mensajes seguidos que incluyen este tool), genera reads redundantes. El patrón correcto es cargar con `_getEmpleadosDocs` y filtrar localmente por ROL, como lo hace `_resolverPersonaAgente` en message_handler.js.

#### [BAJA] `_toolAdelantosEmitidos` hace full-scan de ADELANTOS_CHOFER sin filtro server-side
- **Área:** bot-nucleo · **Archivo:** `whatsapp-bot/src/agente.js:1920` · **Confianza del revisor:** alta
- La función llama `db.collection('ADELANTOS_CHOFER').get()` sin where-clause, descarga todos los documentos de la colección, y filtra `creado_en` en memoria del cliente. Con el tiempo (colección crece indefinidamente) esto aumenta latencia, costo de lectura Firestore y uso de memoria en cada consulta de adelantos. El filtro debería ser `.where('creado_en', '>=', limiteTs)` antes del `.get()`.

#### [BAJA] loginConDni — cuenta inactiva revela existencia del DNI y no carga rate limit IP
- **Área:** fx-plataforma · **Archivo:** `functions/src/auth.ts:109` · **Confianza del revisor:** alta
- Cuando `ACTIVO=false`, el callable devuelve el mensaje específico `'Usuario inactivo. Contacte a administración.'` — distinguible del genérico `'Usuario o contraseña incorrectos.'` que se usa para DNI-no-existe y password incorrecta. Esto permite a un atacante externo enumerar qué DNIs corresponden a empleados dados de baja. Adicionalmente, este path no registra intento fallido en `LOGIN_ATTEMPTS_IP` ni en `LOGIN_ATTEMPTS`, por lo que se puede probar un número ilimitado de DNIs de inactivos sin throttle. En el contexto de una flota de ~50 personas el impacto es bajo, pero es inconsistente con el modelo de anti-enumeración aplicado en el resto del flujo.

#### [BAJA] volvoAlertasPoller: cursor no avanza si el primer fetch trae 0 alertas sin requestServerDateTime
- **Área:** fx-integraciones · **Archivo:** `functions/src/volvo.ts:480` · **Confianza del revisor:** alta
- El cursor `ultimo_request_server_datetime` solo se persiste si `nuevoServerDateTime != null`. Este se setea únicamente cuando `pages === 1 && serverTs` — si la primera página trae 0 alertas y `alertsResponse.requestServerDateTime` llega ausente o nulo (escenario posible ante error 204 parcial o parsing inesperado del API Volvo), el cursor queda en el valor anterior. Los siguientes runs re-escanean desde el mismo `starttime`, generando lecturas redundantes de Volvo. No genera duplicados (la dedup por docId lo bloquea) pero repite el mismo scan hasta que Volvo devuelva eventos nuevos con serverTs. Impacto: desgaste de cuota de la API Volvo.

#### [BAJA] AppOfflineBanner no reinicia el timer si cambia `deadline`
- **Área:** nucleo-shared · **Archivo:** `lib/shared/widgets/app_offline_banner.dart:78` · **Confianza del revisor:** alta
- didUpdateWidget solo verifica `!identical(oldWidget.stream, widget.stream)`. Si el padre cambia `deadline` o `mensaje` dinámicamente, el viejo timer sigue corriendo con el plazo anterior. En la práctica deadline es constante en todos los call-sites actuales, pero el contrato del widget no lo documenta ni lo impone.

#### [BAJA] AppSparkline: shouldRepaint compara listas por referencia, no por valor
- **Área:** nucleo-shared · **Archivo:** `lib/shared/widgets/app_stat.dart:201` · **Confianza del revisor:** alta
- _SparkPainter.shouldRepaint hace `old.data != data` que en Dart es comparación de identidad de objeto. Si el caller pasa una lista literal nueva en cada build (ej. `spark: [v1, v2, v3]` inline), el painter redibuja en todos los frames aunque los valores no cambiaron —performance innecesaria. Inversamente, si el caller mutase la lista in-place (anti-pattern pero posible), no repainta cuando debería. Fix: comparar por contenido con `!listEquals(old.data, data)` de foundation.dart.

#### [BAJA] VacacionesCalendarioScreen no excluye tanqueros/testers
- **Área:** paneles-admin · **Archivo:** `lib/features/administracion/screens/vacaciones_calendario_screen.dart:1` · **Confianza del revisor:** alta
- La tabla de vacaciones (AdminVacacionesScreen) usa ExcluidosService para filtrar tanqueros y testers, pero el calendario Gantt (VacacionesCalendarioScreen) carga empleados directamente del stream sin aplicar la misma exclusión. Si un tanquero o tester tiene registros de vacaciones cargados, aparece en el calendario pero no en la tabla, generando una vista inconsistente. Fix: aplicar el mismo filtro de ExcluidosService en VacacionesCalendarioScreen.

#### [BAJA] Diff de días usa DateTime.now() (device local) vs Timestamp.toDate() (UTC)
- **Área:** paneles-admin · **Archivo:** `lib/features/home/screens/main_panel.dart:412` · **Confianza del revisor:** alta
- _LineaEstado._resolverEstado y _TileVencimientos._resumirProximos calculan `fecha.difference(hoy).inDays` donde `hoy = DateTime.now()` (zona local del dispositivo) y `fecha` proviene de `Timestamp.toDate()` que devuelve DateTime en UTC. En dispositivos con zona UTC el día resultante puede estar desfasado hasta 3 horas respecto de ART (UTC-3), lo que puede hacer que un documento que vence hoy aparezca como 'vence mañana' o viceversa. En producción los dispositivos están en ART por lo que el impacto es bajo, pero es frágil para testers o dispositivos con zona incorrecta. Fix: normalizar ambas fechas a `DateUtils.dateOnly()` en ART antes del diff.

#### [BAJA] _HeroEstadoGeneral usa async* con get() one-shot: no reacciona a cambios en tiempo real
- **Área:** reportes-vencimientos · **Archivo:** `lib/features/expirations/screens/user_mis_vencimientos_widgets.dart:671` · **Confianza del revisor:** alta
- _equiposStream() es un async* generator que hace un get() por cada patente y hace yield de la lista una sola vez. StreamBuilder lo trata como stream, pero como el generator termina después del yield, nunca emite un segundo evento aunque cambien VEHICULO o ENGANCHE del chofer durante la sesión. El hero 'Estado general' puede mostrar vencimientos del equipo ANTERIOR si el chofer es reasignado mientras la pantalla está abierta. Los vencimientos de la sección inferior (_DetalleEquipo) sí usan snapshots() en tiempo real. La inconsistencia es baja en impacto (reasignaciones son raras durante una sesión activa) pero real.

#### [BAJA] RANKING de consumo: columnas LITROS/KM sin formato AR cuando proviene de acumulado
- **Área:** reportes-vencimientos · **Archivo:** `lib/features/reports/services/report_consumo.dart:511` · **Confianza del revisor:** alta
- La hoja RANKING solo incluye filas con esPeriodo==true (línea 511: .where((f) => f.esPeriodo && f.km > 0)), así que los acumulados no llegan al ranking. Pero en la hoja DETALLE, cuando esPeriodo==false, LITROS y KILOMETROS se escriben como TextCellValue con el texto '${f.litros.round()} (acum.)'. Si el admin ordena esa columna en Excel, el orden alfabético mezcla los numéricos con los textuales de forma confusa (ej. '12345 (acum.)' va ANTES de '200' en orden de texto). No hay pérdida de plata, pero el reporte de auditoría puede confundir.

#### [BAJA] admin_personal_form_screen: _RoleSelector sin descripción para roles GOMERIA y SEG_HIGIENE
- **Área:** personal · **Archivo:** `lib/features/employees/screens/admin_personal_form_screen.dart:620` · **Confianza del revisor:** alta
- El método `_descripcion(String r)` tiene casos para CHOFER, PLANTA, SUPERVISOR y ADMIN, pero cae al `return ''` vacío para GOMERIA y SEG_HIGIENE. El dropdown de alta incluye esos roles (vienen de `AppRoles.todos`) pero la sublínea de descripción queda en blanco, lo que puede confundir al admin que quiere dar de alta un gomero. No rompe la lógica pero es un descuido de UX cuando se agregaron los nuevos roles.

#### [BAJA] Cálculo de km para enganche: hasta 180 lecturas Firestore seriales por unidad
- **Área:** gomeria-checklist · **Archivo:** `lib/features/gomeria/services/montajes_service.dart:755` · **Confianza del revisor:** alta
- _odometroTractorEnFecha hace hasta ventanaDias*2+1 = 15 lecturas Firestore seriales buscando el doc de telemetría más cercano. kmRecorridoPorPosicion llama a _kmEnganche para cada posición activa del enganche (hasta 12). Caso peor: 15 reads * 12 posiciones = 180 lecturas seriales al cargar la pantalla de un enganche con 12 montajes activos. En práctica con 4-5 posiciones y ventana que suele hit en off=0, serán 5-10 reads, pero con enganches sin telemetría reciente puede escalar. No rompe nada ahora, pero la UX se degrada en red lenta.

#### [BAJA] Doble código de aprobación de documentos con campos distintos: audit trail inconsistente
- **Área:** gomeria-checklist · **Archivo:** `lib/features/revisions/screens/admin_revisiones_screen.dart:710` · **Confianza del revisor:** alta
- _aprobarDocumento() (en la pantalla) escribe ultima_actualizacion_sistema con serverTimestamp(), mientras que planificarAprobacion() en revision_service.dart escribe ultima_auditoria. Los documentos aprobados via UI directa (no-cambio-equipo) tendrán un campo diferente al que el servicio documentaría. Consultas o reportes que filtren por ultima_auditoria no encontrarán estos registros. Es deuda derivada de no unificar los dos caminos de aprobación.

#### [BAJA] Label 'Comisión chofer (18%)' incorrecto en viajes mixtos fijo+porcentaje
- **Área:** logistica-ui · **Archivo:** `lib/features/logistica/screens/logistica_viaje_form_secciones.dart:95` · **Confianza del revisor:** alta
- En _SeccionResumen, la etiqueta 'Comisión chofer (18%)' se muestra cuando calcularTodoMultiTramo.comisionChoferPct == 18, lo cual ocurre si hay AL MENOS UN tramo con modo porcentaje (hayAlgunTramoConPct = true), incluso si otros tramos tienen monto fijo. El operador puede malinterpretar que todos los tramos usan 18% cuando en realidad la liquidación es mixta.

#### [BAJA] ID de tramo por microsegundo puede colisionar al restaurar borrador multi-tramo rápido
- **Área:** logistica-ui · **Archivo:** `lib/features/logistica/screens/logistica_viaje_form_tramos.dart` · **Confianza del revisor:** media
- _TramoEditState.vacio() genera el ID interno como DateTime.now().microsecondsSinceEpoch.toString(). Al restaurar un borrador con múltiples tramos, _hidratarDesdeBorrador llama _TramoEditState.vacio() en un loop sincrónico antes de poblar los campos; en plataformas donde microsecondsSinceEpoch tiene resolución de 1ms (especialmente en Windows), dos tramos adyacentes pueden recibir el mismo ID. Esto no tiene impacto en Firestore (el ID es solo local/UI) pero puede causar duplicate key si se usa como Key en la lista de widgets.

#### [BAJA] motivoCtrl leak si showDialog lanza excepción en _confirmarBorrar
- **Área:** logistica-ui · **Archivo:** `lib/features/logistica/screens/logistica_viaje_detalle_screen.dart` · **Confianza del revisor:** media
- _confirmarBorrar crea motivoCtrl antes del await showDialog. El controller se disposa en ambas ramas ok=true y ok=false. Sin embargo, si showDialog en sí lanza (raro pero posible en hot-reload o navigator error), ninguna rama ejecuta dispose(). No tiene impacto en producción normal.

#### [BAJA] Race condition leve en _evaluarMantenimiento: re-lee KM_ACTUAL que acaba de ser escrito, puede clasificar con valor stale
- **Área:** vehiculos · **Archivo:** `lib/features/vehicles/services/vehiculo_manager.dart:177` · **Confianza del revisor:** media
- _executeSync escribe KM_ACTUAL via actualizarTelemetria (línea 164) y luego lanza _evaluarMantenimiento como fire-and-forget (línea 177). _evaluarMantenimiento hace un get() fresco del doc VEHICULOS (línea 249 del mismo archivo) para leer ULTIMO_SERVICE_KM y KM_ACTUAL y calcular serviceDistanceDesdeManual. Dado que el write en Firestore puede no estar committed cuando ocurre el get() en el mismo cliente, _evaluarMantenimiento podría calcular el estado con el KM_ACTUAL anterior al sync y clasificar erróneamente si el tractor cruzó el umbral exactamente en ese ciclo. El impacto es solo una notificación local incorrecta (o ausente) en ese ciclo; en el próximo sync se recalcula correctamente.

#### [BAJA] asignacion_mutex: ventana TOCTOU entre delete() del lock vencido y set() del nuevo
- **Área:** personal · **Archivo:** `lib/features/asignaciones/services/asignacion_mutex.dart:56` · **Confianza del revisor:** media
- Cuando un lock ya existe pero está vencido, el código hace `await ref.delete()` seguido de `await ref.set(...)`. Entre esas dos operaciones, un segundo proceso concurrente puede hacer también su `get()` (que verá el doc borrado), saltar el check y llegar al `set()` simultáneamente. La Firestore rule `update: if false` mitiga el caso donde ambos llegan al `set()` cuando el doc ya existe (el segundo rebota), pero si el segundo hace su propio `delete()` del lock vencido y luego su `set()` después del `set()` del primero, ambos quedan con lock válido. La probabilidad es muy baja en la práctica (1 operador simultáneo en Vecchi), pero no está formalmente protegido.

#### [BAJA] Fallback DateTime.now() en VolvoScoreDiario.fromMap silencia fecha corrupta
- **Área:** icm-eco · **Archivo:** `lib/features/eco_driving/models/volvo_score_diario.dart:137` · **Confianza del revisor:** media
- `fechaTs: (d['fecha_ts'] as Timestamp?)?.toDate() ?? DateTime.now()` — si el campo `fecha_ts` está ausente o tiene tipo incorrecto en Firestore, el doc se guarda con la fecha actual del cliente. Esto hace que el doc aparezca siempre dentro del rango temporal activo, pero con `fecha` string posiblemente de otra fecha. El impacto es silencioso: un doc con fecha antigua se procesa como si fuera hoy, pudiendo inflar el promedio del día en curso. El fallback correcto sería retornar null o usar un valor sentinel, no `DateTime.now()`.

#### [BAJA] Gráfico velocidad: intervaloX = 0 si todos los puntos tienen el mismo timestamp
- **Área:** jornadas-flutter · **Archivo:** `lib/features/jornada_historico/screens/jornada_dia_screen.dart:981` · **Confianza del revisor:** media
- Si `serieVelocidad` tiene 2+ puntos pero todos con el mismo `tsMs` (edge case de un doc malformado por la CF), entonces `minTs == maxTs`, `intervaloX = (maxTs - minTs) / 5 = 0`. fl_chart recibe `interval: 0` en los títulos del eje X, lo que en producción puede causar un bucle de renderizado o assertion error. El mismo patrón existe en registro_jornada_detalle_screen.dart línea 202. El guard de 'length < 2' no cubre el caso de múltiples puntos con idéntico timestamp.

#### [BAJA] Kill-switch toggle visible para rol SUPERVISOR aunque Firestore bloquea la escritura
- **Área:** paneles-admin · **Archivo:** `lib/features/admin_dashboard/screens/admin_estado_bot_widgets.dart:1` · **Confianza del revisor:** media
- _ToggleKillSwitch se renderiza para cualquier usuario que llegue a la pantalla de estado del bot. SUPERVISOR tiene acceso a esa pantalla por capability pero las rules de Firestore bloquean la escritura a BOT_CONTROL/main para ese rol. El resultado es que el SUPERVISOR ve el control, intenta activarlo/desactivarlo, confirma el diálogo, y recibe un error silencioso o un snackbar de error sin explicación clara. La confianza es media porque no tracé el capability exacto requerido para llegar a esa pantalla desde el router versus el capability chequeado dentro del widget.

#### [BAJA] ScaffoldMessenger capturado antes del await en _cargarRecorrido puede referirse a context desmontado
- **Área:** mapa-zonas-cachatore-ui · **Archivo:** `lib/features/fleet_map/screens/admin_mapa_flota_screen.dart:267` · **Confianza del revisor:** media
- `_cargarRecorrido` captura `ScaffoldMessenger.of(context)` en la línea 267 ANTES de un await largo (consulta a Firestore con potencialmente miles de eventos). Si el usuario navega lejos de la pantalla durante la espera, el `messenger` sigue siendo válido (ScaffoldMessenger sobrevive al widget hijo) pero el `if (!mounted) return -1` del catch en la línea 285 no evita llamar `messenger.showSnackBar` en el caso de error, porque el check de mounted ocurre DESPUÉS de `messenger.showSnackBar`. En la línea 290 el snackBar se muestra ANTES del check de mounted. El patrón correcto es capturar el messenger antes del await (como está) pero agregar `if (!mounted) return -1` inmediatamente al entrar al catch, antes de usar el messenger.

#### [BAJA] RoleGuard crea un nuevo Future en cada build() — potencial rebuild loop
- **Área:** nucleo-core · **Archivo:** `lib/shared/widgets/guards/role_guard.dart:76` · **Confianza del revisor:** media
- RoleGuard es un StatelessWidget que llama user.getIdTokenResult() directamente en build(). Cada vez que el árbol padre fuerza un rebuild se crea un nuevo Future, lo que hace que FutureBuilder reinicie el spinner de 'waiting'. getIdTokenResult() usa caché local y tarda <50ms, pero en pantallas con animaciones de tema o AnimatedSwitcher puede mostrar un flash del spinner. El FutureBuilder del Firestore fallback (línea 103) tiene el mismo problema.

#### [BAJA] _parseUniversalDate no maneja Timestamp de Firestore
- **Área:** nucleo-core · **Archivo:** `lib/shared/utils/formatters.dart:145` · **Confianza del revisor:** media
- La función _parseUniversalDate acepta 'dynamic' y maneja String y DateTime nativo, pero no Timestamp de Firestore. Si algún campo VENCIMIENTO_* alguna vez se escribe como Timestamp (error en la console de Firebase o migración), su .toString() devuelve 'Timestamp(seconds=..., nanoseconds=...)' que el parser no reconoce y retorna null. El impacto sería que ese vencimiento aparezca como 'Sin datos' en la UI. Actualmente todos los campos se guardan como strings ISO con aIsoFechaLocal(), pero el guard defensivo valdra la pena: agregar 'if (fecha is Timestamp) return fecha.toDate();' al inicio de la función.

#### [BAJA] DatoEditableEnumExtensible usa context stale tras pop del dialog
- **Área:** nucleo-shared · **Archivo:** `lib/shared/widgets/dato_editable.dart:405` · **Confianza del revisor:** media
- En _mostrarSelector(), al tocar 'Otro...', se hace Navigator.pop(dCtx) y luego _mostrarInputOtro(context). El `context` capturado es el del StatelessWidget padre, que puede haber sido desmontado si la pantalla hizo rebuild o fue removida del árbol mientras el dialog estaba abierto. No hay chequeo de mounted (StatelessWidget no lo tiene) ni de context.mounted antes de llamar showDialog. En un flujo normal no explota, pero en casos borde (el usuario popea la pantalla mientras el dialog está abierto, que Flutter permite) puede arrojar 'widget tree is not mounted' o navegar a un context inválido.

#### [BAJA] backfillDescargasDiario: cálculo de 00:00 ART como UTC-3 fijo es frágil ante eventos edge
- **Área:** fx-integraciones · **Archivo:** `functions/src/historico_descargas.ts:452` · **Confianza del revisor:** media
- El patrón `new Date(Date.now() - 3 * 60 * 60 * 1000)` asume UTC-3 fijo. Argentina efectivamente no tiene DST, por lo que esto es correcto hoy. Sin embargo si el cron se ejecuta exactamente en el segundo de cambio de día (borde de 03:00 UTC) y el servidor Cloud Run tiene un reloj con drift de algunos segundos, podría calcular un día distinto. El riesgo es muy bajo en la práctica — se documenta para que si en el futuro Argentina implementa DST (ha sucedido históricamnte) esta suposición se revise. El patrón correcto sería usar `Intl.DateTimeFormat` con `timeZone: America/Argentina/Buenos_Aires` como lo hace `telemetriaSnapshotScheduled`.

#### [BAJA] `wmic` deprecado en `_matarChromesHuerfanos` de whatsapp.js
- **Área:** bot-nucleo · **Archivo:** `whatsapp-bot/src/whatsapp.js:1` · **Confianza del revisor:** media
- `_matarChromesHuerfanos` usa `wmic process where ...` que está deprecado desde Windows 10 21H1 y ausente en Windows 11 builds recientes con feature-on-demand. En contraste, `matarProcesosChromiumZombi` en index.js usa PowerShell `Get-Process | Where-Object`. Si el PC dedicado actualiza a una build sin wmic, este helper falla silenciosamente (el error se atrapa con catch) y los Chromes zombie no se matan. La función no tiene fallback a PowerShell.

#### [BAJA] aIsoYMD en fecha_extractor.js ignora el caso Firestore Timestamp
- **Área:** bot-features · **Archivo:** `whatsapp-bot/src/fecha_extractor.js:60` · **Confianza del revisor:** media
- aIsoYMD acepta Date o string, pero no Firestore Timestamp (objeto con .toDate()). Si en el futuro message_handler pasa un Timestamp al agente para guardar en Firestore, new Date(fechaTimestamp) produce '1970-01-01' (convierte el objeto a [object Object]). El módulo fechas.js ya tiene aIsoLocal que maneja todos los tipos incluyendo Timestamp — reemplazar aIsoYMD con una llamada a aIsoLocal evitaría el problema. Actualmente el único caller (message_handler.js:720) pasa el resultado de extraerFechaMasLejana (siempre un Date), así que no hay impacto hoy.

#### [BAJA] test_vigia.py TestSemanasAEscanear: fecha relativa con timedelta(days=1) puede ser flakey en CI nocturno
- **Área:** tests-cobertura · **Archivo:** `cachatore/test_vigia.py:78` · **Confianza del revisor:** media
- El test test_reserva_a_pendiente_cuando_el_scanner_ve_un_hueco usa datetime.now() + timedelta(days=1) para generar una fecha 'mañana'. Si el slot ISO apunta a 00:xx UTC y el test corre cerca de medianoche ART (03:00 UTC), slot_es_futuro puede devolver False en algunos runners de CI. El autor lo menciona como fix respecto a una fecha hardcodeada, pero la ventana de fallo persiste a medianoche.


# 3. Falsos positivos descartados (4)

Reportados por un revisor y REFUTADOS por el verificador (se listan para no re-investigarlos):

- **TramoIButton.fromDoc: crash con TypeError si 'desde' o 'hasta' son null en Firestore** (personal, `lib/features/auditoria_asignaciones/models/tramo_ibutton.dart`)
  - Veredicto: El `fromDoc` de `TramoIButton` (lib/features/auditoria_asignaciones/models/tramo_ibutton.dart:37-38) tiene efectivamente los casts sin null-check, pero el código es código muerto: `HistoricoIButtonService.streamPorRango` no tiene ningún caller en todo `lib/` (grep confirma que solo aparece en su propia definición). La pantalla que antes lo usaba (`admin_auditoria_asignaciones_screen.dart`) fue refactoreada explícitamente el 2026-05-27 para eliminar el cruce contra `SITRACK_IBUTTONS_HISTORICO` (el comentario en las líneas 60-65 de esa pantalla documenta la decisión). Adicionalmente, incluso si el servicio fuera llamado, el writer de la CF (`historico_ibuttons.ts:121-130`) siempre persiste `desde` y `hasta` desde objetos `Timestamp` validados, con un guard explícito `if (!patente || !driverDni || !ts) continue` (línea 154) que descarta cualquier evento con timestamp nulo antes de construir el tramo; el script Python de backfill tiene el mismo guard (línea 94). Las Firestore rules bloquean toda escritura cliente-side (`allow create, update, delete: if false`). No hay ruta alcanzable que materialice el crash reportado.
- **armarResumenJornadasV3Diario calcula 'ayer' restando 24h brutas (UTC), no con la medianoche ART** (fx-jornadas, `functions/src/jornadas_v3_batch.ts`)
  - Veredicto: El bug report tiene dos premisas incorrectas. (1) Afirma que jornadas_v2 usa "medianoche ART como Timestamp explícito" y es robusto ante cualquier hora de ejecución — pero jornadas_v2.ts:1747-1750 usa exactamente el mismo patrón `ahora.getTime() - 24 * 60 * 60 * 1000` para derivar `fechaArtAyer`; la "mejora" que le atribuye al v2 no existe: ambos son idénticos en fragilidad teórica. (2) El escenario de falla requiere que Cloud Scheduler retarde el cron 16-19 horas (de 08:00 ART hasta el rango 00:00-02:59 ART del día siguiente); Cloud Scheduler tiene un máximo de retry de ~1 hora, por lo que ese retraso solo ocurriría ante una interrupción regional de GCP de casi un día, que escapa a toda planificación operativa razonable. La lógica en jornadas_v3_batch.ts:605 — `fechaArt(Date.now() - 24 * 60 * 60 * 1000)` — corriendo a las 11:00 UTC (08:00 ART) produce correctamente la fecha de ayer en ART, y no difiere en robustez de los demás módulos del sistema.
- **Double-offset timezone en descargas históricas: horas con -6h en lugar de ART** (bot-nucleo, `whatsapp-bot/src/agente.js`)
  - Veredicto: El patrón en agente.js:2116-2122 es correcto. `getUTCHours()` lee la componente UTC del objeto Date y es inmune a `process.env.TZ`; el env var solo afecta los métodos "locales" (`getHours()`, `toLocaleString()`, etc.). El flujo real para un evento a las 14:00 ART (17:00 UTC): `ts.toMillis()` devuelve los ms de 17:00 UTC → restar 3h deja los ms de 14:00 UTC → `new Date(...).getUTCHours()` = 14. El resultado es exactamente la hora ART, sin double-offset. El bug reportado habría existido si se usara `.getHours()` (que sí honra el TZ del proceso), pero el código usa explícitamente `.getUTCHours()`. `_horaArtDeTs` (línea 1657) usa `toLocaleTimeString` con `timeZone` explícito, que es un enfoque distinto pero igualmente correcto; no existe inconsistencia funcional entre ambas implementaciones.
- **Cloud Functions TypeScript completamente sin cobertura** (tests-cobertura, `functions/src/index.ts`)
  - Veredicto: El bug parte de una premisa falsa: busca tests en `functions/src/__tests__/` (que no existe) pero el proyecto los tiene en `functions/test/`, directorio hermano de `src/`. Ese directorio contiene 16 archivos con ~294 llamadas a `test()` usando Node's built-in runner (`node:test`), cubriendo precisamente los módulos críticos que el reporte dice "sin cobertura": jornadas v2 (jornadas_v2_helpers.test.js, jornadas_v2_tick.test.js), jornadas v3 (jornadas_v3.test.js, jornadas_v3_batch.test.js, jornadas_v3_metricas.test.js), resúmenes diarios (resumenes_diarios.test.js), alertas Volvo (volvo_estado.test.js, volvo_mantenimiento.test.js, volvo_telltales.test.js), cierre de jornadas (cierre_reportes_jornada.test.js) y bot de alerta (bot_alerta_externa.test.js). El script de CI en package.json:scripts.test ejecuta exactamente ese directorio. Sí existen módulos sin cobertura propia (zonas_descarga.ts, excluidos.ts, historico_descargas.ts, sitrack.ts), pero eso es una brecha de cobertura parcial, no "completamente sin tests". La severidad crítica y la afirmación de cobertura cero son incorrectas.

---

# 4. Detalle por área (estado, mejoras, ideas, deuda)

## logistica-negocio — 22 archivos leídos

El módulo de Logística es el corazón financiero de la app: liquida los viajes, calcula lo que cobra el chofer (18% sobre tarifa chofer, redondeo a múltiplo de 5 por tramo), gestiona adelantos con recibos PDF, recalcula retroactivamente las tarifas no liquidadas y exporta la planilla Excel histórica. El código está bien estructurado, con separación clara entre modelos inmutables, services de persistencia y utils de cálculo. El estado general de salud es bueno; se encontró un bug de severidad alta en el recálculo masivo y dos de severidad media.

### Mejoras

| Mejora | Categoría | Impacto | Esfuerzo |
|---|---|---|---|
| Denormalizar `tarifa_ids` en el viaje para queries de recálculo eficientes | rendimiento | alto | medio |
| Guardar comisionPct efectiva por tramo, no por viaje | mantenibilidad | alto | medio |
| Timeout en `marcarLiquidadosBulk` y `desmarcarLiquidadosBulk` al hacer per-doc reads | ux | medio | bajo |
| Validar que `sumarMesesPreservandoDia` se llame solo con meses ≥ 0 | robustez | bajo | bajo |
| El `_cacheRutas` de OSRM es un Map estático que crece sin límite en sesiones largas | rendimiento | bajo | bajo |
| Agregar índice Firestore para query de adelantos por rango de fechas sin choferDni | rendimiento | medio | bajo |
| El borrador de viaje (BORRADORES_VIAJE) no tiene TTL ni limpieza automática | datos | bajo | bajo |
| El formato de monto en `_MitadPlanCuotas._fmtMonto` es un helper local duplicado de AppFormatters | mantenibilidad | bajo | bajo |

- **Denormalizar `tarifa_ids` en el viaje para queries de recálculo eficientes:** Agregar campo `tarifa_ids: List<String>` al nivel del doc de VIAJES_LOGISTICA (array de los tarifaId únicos de todos los tramos). Actualizar en `crearViaje` y `actualizarViaje`. Reemplaza el full-scan de `_recalcularViajesConTarifa` por `.where('tarifa_ids', arrayContains: tarifa.id)`. Requiere también migrar docs existentes (script one-shot con `scripts/` del repo).
- **Guardar comisionPct efectiva por tramo, no por viaje:** El campo `comision_chofer_pct` al nivel del viaje mezcla lógica de tramos fijo y por-porcentaje. Si hay tramos mixtos (algunos fijo, algunos pct), el pct reportado es el global pero no es el que se usó en cada tramo fijo. Guardar `comision_pct` dentro de cada tramo del array (en `TramoViaje.toMap()`) permite auditoría por tramo y elimina la ambigüedad que causa el bug actual en el recálculo.
- **Timeout en `marcarLiquidadosBulk` y `desmarcarLiquidadosBulk` al hacer per-doc reads:** En `marcarLiquidadosBulk` el loop hace N reads individuales secuenciales antes del batch. Para 500 viajes en un chunk, con 50-100ms de latencia por read en Windows, puede tardar 25-50 segundos bloqueando la UI sin feedback de progreso. Usar `Promise.all` / `Future.wait` en grupos de 10-20 lecturas paralelas, o agregar un indicador de progreso con el count de docs procesados.
- **Validar que `sumarMesesPreservandoDia` se llame solo con meses ≥ 0:** La función `sumarMesesPreservandoDia` con `meses = 0` retorna inmediatamente correcto, pero si por algún bug del form se llama con negativo (offset por error de índice), generaría fechas en el pasado sin error. Agregar `assert(meses >= 0)` o guard con `ArgumentError` para detectar temprano.
- **El `_cacheRutas` de OSRM es un Map estático que crece sin límite en sesiones largas:** En `logistica_geo_utils.dart`, `_cacheRutas` se acumula para toda la sesión sin eviction. En la práctica son pocas rutas (~50-100 tarifas únicas), así que no es urgente. Pero un `LRU` de 200 entradas o TTL de 1 hora daría el beneficio de caché sin el riesgo de memory leak en una sesión de Windows que dura días.
- **Agregar índice Firestore para query de adelantos por rango de fechas sin choferDni:** `streamAdelantosEnRango` sin `choferDnis` hace `.where('fecha', range)` sin equality prefix → requiere índice simple sobre `fecha`. Verificar que `firestore.indexes.json` lo incluye explícitamente. Si no, Firestore puede degradar a full-collection scan o rechazar la query en producción.
- **El borrador de viaje (BORRADORES_VIAJE) no tiene TTL ni limpieza automática:** Los docs en BORRADORES_VIAJE se acumulan indefinidamente (un por operador+modo, así que son pocos). No es urgente, pero un `expira_en` con TTL de 7 días (seteado en el service `guardar`) y una regla de Firestore TTL o una Cloud Function de limpieza semanal evitaría acumulación. Ahora si el operador no vuelve al form, el borrador queda para siempre.
- **El formato de monto en `_MitadPlanCuotas._fmtMonto` es un helper local duplicado de AppFormatters:** La función privada `_fmtMonto` en `recibos_adelanto_service.dart` reimplementa el formato AR (punto miles, coma decimal) manualmente. Si `AppFormatters.formatearMonto` cambia (ej. símbolo de moneda, soporte de decimales), este helper queda desincronizado. Reemplazar con `AppFormatters.formatearMonto(v)`.

### Ideas de features que esta área habilita

- Alerta automática de 'primer viaje del mes sin liquidar' a supervisor/admin al llegar al día 5 del mes siguiente: la data ya existe (viajes CONCLUIDOS con liquidado=false del mes anterior), solo falta un cron en Cloud Functions que consulte y notifique por WhatsApp al grupo operativo.
- Dashboard de margen bruto por tarifa: la colección VIAJES_LOGISTICA tiene montoVecchi, montoChofer, gastosTotal, y cada tarifa tiene porcentajeComisionDador/montoFijoDador. Con estos datos se puede calcular el margen neto Vecchi por tarifa (tarifaReal - tarifaChofer - comisiónDador) y ranquear las más y menos rentables para que Santiago pueda renegociar.
- Historial de precio por tarifa visible en la UI de detalle de tarifa: el modelo ya soporta vigenciasReal y vigenciasChofer como listas de historial ordenadas. Una pantalla de 'Historial de vigencias' similar a un timeline permitiría ver cuándo subió/bajó el precio y si el aumento de la real se trasladó al chofer.
- Proyección de cierre de mes: con los viajes EN_CURSO+PLANEADOS del mes actual y el historial de concreción (cuántos viajes planeados terminaron CONCLUIDO vs CANCELADO en los últimos 3 meses), se podría mostrar un rango 'NETO ESTIMADO: $X a $Y' para que contabilidad proyecte la caja.
- Importar viajes desde Excel: el operador a veces tiene los datos del viaje en una planilla antes de cargarlos en la app. Un importador CSV/Excel con mapeo de columnas (fecha, chofer DNI, origen, destino, kg) ahorraría carga manual en meses con muchos viajes.
- Ranking de choferes por ganancia/km: con montoChoferRedondeado y los km por tarifa ya disponibles, se puede calcular $/km por chofer y período, útil para evaluar eficiencia operativa y detectar viajes cortos con alta comisión vs largos con baja.

### Deuda técnica

- El helper `_stripParentesis` está triplicado: en `TarifaSnapshot`, en `TarifaLogistica` y en `ReportPlanillaChofer.stripParentesis` (este último público). Deberían fusionarse en `AppFormatters` o en un `LogisticaFormatters` compartido.
- Los campos `adelanto_monto`, `adelanto_fecha`, `adelanto_observacion` al nivel del doc `Viaje` son legacy (pre-2026-05-13). Siguen escribiéndose condicionalmente en `_construirDataActualizacion` para no romper viajes viejos, pero la lectura del recibo impreso (`Viaje.adelantoMonto`) ya no es la fuente de verdad. Un script de migración que mueva esos campos a docs `ADELANTOS_CHOFER` permitiría eliminar el código de compat.
- El campo `fecha_carga` denormalizado al nivel de viaje NO se actualiza si el operador cambia la fecha del primer tramo en una edición parcial. La denormalización se recalcula solo en `actualizarViaje` completo. Si hay un flujo que edita solo el tramo sin pasar por `actualizarViaje`, el campo queda desincronizado y la query de LIQUIDACIÓN puede excluir o incluir el viaje en el mes equivocado.
- El modelo `TarifaVigencia` (formato viejo combinado) todavía vive como clase completa aunque su único propósito post-migración es (a) parsear docs viejos y (b) ser escrito como `vigencias` de compat. Podría reducirse a un factory method en `TarifaLogistica` para clarificar que es solo un formato de persistencia, no un concepto del dominio.
- El `grupoCuotasId` en `AdelantosService.crearAdelantosEnCuotas` se genera con timestamp + substring de un ID de Firestore de una colección '_' auxiliar. Es funcional pero raro: el `_db.collection('_').doc().id` crea un doc fantasma en una colección inexistente. Usar `DateTime.now().microsecondsSinceEpoch.toString()` + un random puro (sin Firestore) sería más limpio.
- El `_cacheRutas` estático en `LogisticaGeoUtils` es estado mutable compartido entre todas las llamadas de la app. No hay tests que puedan aislar este cache; `invalidarCacheRutas` existe pero no se llama automáticamente. Para tests de integración del futuro motor de planeamiento esto va a ser un problema.
- El campo `vigente_desde` plano en `TarifaLogistica` se escribe con `FieldValue.serverTimestamp()` al crear pero después `_persistirVigencias` lo escribe con client-time (`Timestamp.fromDate(vigenteDesde)`). Hay una inconsistencia de fuente de tiempo entre el alta y los updates de vigencia.


## logistica-ui — 17 archivos leídos

El módulo de logística es la parte más compleja del proyecto: cubre tarifas con vigencias duales (real vs. chofer), viajes multi-tramo con snapshots inmutables, borradores auto-guardados, liquidación diferenciada FIRME/ESPECULACIÓN, adelantos, y mapas de geocercas. El código está bien estructurado, con responsabilidades separadas en services/models/screens/widgets y una cobertura de casos borde generalmente buena (mounted checks, dispose de controllers, guards de NaN/Infinity en cálculos). El área de mayor riesgo es la carrera async en la hidratación de borradores y la secuencia de pasos en _guardar viaje (sin transacción atómica), que puede dejar datos parciales en Firestore ante fallos de red. Deuda técnica notable: primitivos duplicados (\_Linea, \_Seccion, \_FlechaMes) en tres archivos distintos, y la retrocompatibilidad con el array vigencias combinado genera acumulación redundante. Estado de salud: BUENO para producción actual; los bugs críticos son de baja frecuencia pero con impacto de datos alto cuando ocurren.

### Mejoras

| Mejora | Categoría | Impacto | Esfuerzo |
|---|---|---|---|
| Atomizar _guardar con idempotencia de remito | robustez | alto | medio |
| Guard de mounted en _hidratarDesdeBorrador antes de mutar _tramos | robustez | medio | bajo |
| Memoizar _montosCalc entre builds | rendimiento | medio | bajo |
| Extraer primitivos duplicados a shared/widgets | mantenibilidad | medio | bajo |
| Advertir al operador sobre cambios sin guardar al salir del form de viaje | ux | medio | medio |
| TTL automático para borradores de operadores dados de baja | datos | bajo | bajo |
| Label de comisión preciso en resumen de viaje mixto | ux | bajo | bajo |
| Filtrar adelantos eliminados en LiquidacionTotales | robustez | medio | bajo |

- **Atomizar _guardar con idempotencia de remito:** Guardar el viajeId en estado local (o en el borrador) antes de iniciar el upload de remitos. Si la operación falla a mitad, ofrecer al operador 'Completar guardado' que retoma desde el viaje ya creado: sube remitos faltantes y asocia adelantos sin crear un segundo doc. Alternativamente, hacer el upload a Storage ANTES de crear el viaje en Firestore para que la URL ya exista al momento de escribir el doc.
- **Guard de mounted en _hidratarDesdeBorrador antes de mutar _tramos:** En logistica_viaje_form_screen.dart, mover el check 'if (!mounted) return' ANTES de la mutación de _tramos, no solo antes del setState. Opcionalmente, reemplazar la mutación directa por un patrón de copia: construir los nuevos tramos en una variable local, luego asignar atómicamente solo si mounted. Así los TramoEditState nunca se 'escapan' si el widget se destruyó.
- **Memoizar _montosCalc entre builds:** El getter _montosCalc en logistica_viaje_form_screen.dart llama calcularTodoMultiTramo en cada build (incluyendo los triggers por keystroke en campos de texto). Guardar el resultado en una variable _montosCache y invalidarla solo cuando cambia algún campo que afecta el cálculo (kg, tarifa, fechaCarga, modo fijo/pct). Reduce el work por frame en viajes con 4+ tramos.
- **Extraer primitivos duplicados a shared/widgets:** _Linea aparece en logistica_viaje_form_widgets.dart y logistica_viaje_detalle_screen.dart. _Seccion aparece en logistica_tarifa_form_screen.dart y logistica_viaje_detalle_screen.dart. _FlechaMes aparece en logistica_liquidacion_screen.dart y logistica_viajes_lista_screen.dart. Mover a lib/shared/widgets/ o a lib/features/logistica/widgets/ como componentes exportados. Elimina 3 fuentes de drift.
- **Advertir al operador sobre cambios sin guardar al salir del form de viaje:** El form de viaje no tiene un WillPopScope/PopScope que detecte si hay cambios pendientes (campos modificados vs. el borrador/viaje original). Comparar estado actual contra snapshot al cargar; si hay delta, mostrar un dialog '¿Querés descartar los cambios?' antes de hacer pop. El borrador auto-save mitiga el riesgo pero el operador puede no saber que sus últimos cambios se salvaron.
- **TTL automático para borradores de operadores dados de baja:** La colección BORRADORES_VIAJE no tiene TTL ni cleanup. Un operador dado de baja deja su borrador en la colección para siempre. Agregar un campo 'creadoEn' (ya presente en la mayoría de los borradores) y una Cloud Function o Firestore TTL policy que elimine docs con más de 30 días. Alternativamente, limpiar en el login del operador si el borrador es >30 días.
- **Label de comisión preciso en resumen de viaje mixto:** En _SeccionResumen de logistica_viaje_form_secciones.dart, cuando comisionChoferPct == 18 Y hay tramos con monto fijo, cambiar el label a 'Liquidación chofer (mixta)' y agregar un tooltip o línea de detalle '(X tramos a porcentaje, Y tramos a monto fijo)'. Así el operador entiende exactamente cómo se calcula la liquidación.
- **Filtrar adelantos eliminados en LiquidacionTotales:** LiquidacionTotales.de (liquidacion_totales.dart) asume que el caller ya filtró los adelantos eliminados, pero ni logistica_liquidacion_screen.dart ni logistica_viaje_detalle_screen.dart documentan explícitamente ese contrato. Mover el filtro por !a.eliminado dentro de LiquidacionTotales.de para que sea defensivo. El costo es mínimo (una iteración extra) y elimina el riesgo de adelantos eliminados inflando el neto.

### Ideas de features que esta área habilita

- Rutas frecuentes sugeridas al agregar un nuevo tramo: al abrir el picker de tarifa, mostrar en la parte superior las 3 tarifas más usadas por el mismo chofer en los últimos 90 días (query sobre VIAJES_LOGISTICA agrupado por tarifa_snapshot.tarifaId). Reduce el tiempo de carga de viajes recurrentes (ej. los mismos circuitos Profertil–Bahía).
- Alerta automática por viaje estancado en EN_CURSO: si un viaje tiene más de N días sin transición a CONCLUIDO, enviar un WhatsApp al supervisor con resumen del viaje (chofer, ruta, fecha carga). Implementable como Cloud Scheduler diario que consulta VIAJES_LOGISTICA con estado=EN_CURSO y fechaCarga < hoy-N.
- Exportación PDF del detalle de viaje: desde la pantalla de detalle, generar un PDF con los datos del viaje (tramos, montos, gastos, remito embebido) para compartir con el cliente o el chofer via WhatsApp. Reutiliza el patrón de pdf_printer.dart ya existente en adelantos.
- Vista calendario mensual de viajes por chofer: en logistica_viajes_lista_screen, agregar un toggle 'Vista calendario' que muestre un grid de días con badges por chofer indicando cantidad de viajes. Útil para detectar solapamientos o choferes sin actividad.
- Validación de solapamiento de fechas entre tramos del mismo viaje: si dos tramos tienen fechaDescarga y fechaCarga que se solapan (un tramo termina después de que empieza el siguiente), mostrar un warning suave en _SeccionResumen. Actualmente es posible cargar tramos con fechas inconsistentes sin ningún feedback.

### Deuda técnica

- _Linea, _Seccion, _FlechaMes duplicados entre logistica_viaje_form_widgets.dart, logistica_viaje_detalle_screen.dart, logistica_tarifa_form_screen.dart y logistica_liquidacion_screen.dart. Tres archivos con copy-paste silencioso que divergen con el tiempo.
- _displayUbicacionConEmpresa y _stripParentesis duplicados en TarifaLogistica y TarifaSnapshot — comentario 'modelo autocontenido' justifica la decisión, pero crea riesgo de que las reglas de display diverjan entre el modelo de tarifa y el snapshot incrustado en el viaje.
- Campo vigencias combinado escrito de vuelta en cada actualización de tarifa (vigenciasCombinadas()) para compatibilidad con clientes <2026-06-11. El array crece indefinidamente: cada nuevo precio agrega entradas en AMBOS formatos (split real/chofer + combinado). Requiere un script de migración + fecha de corte para eliminar el write-back.
- Campos legacy adelantoMonto / adelantoFecha / adelantoObservacion en el modelo Viaje nunca removidos — se mencionan en fromMap como compatibilidad histórica pero no hay schedule de cleanup.
- El doc ID de borrador usa patrón string concatenado (${operadorDni}_${viajeIdOriginal}) sin hash ni escape, lo que puede romperse si el DNI o el viajeId contienen el carácter _ (en la práctica los DNIs son numéricos, pero es un contrato frágil no documentado como invariante).
- logistica_adelantos_screen.dart importa dart:typed_data (Uint8List) pero la lógica de bytes de recibo vive en RecibosAdelantoService — el import sugiere que hubo código de preview de recibo inline que fue removido sin limpiar el import.
- _SeccionChofer en logistica_viaje_form_secciones.dart abre un StreamBuilder sobre EMPLEADOS completo sin ningún límite. Con el padrón actual de ~50 empleados es trivial; si la empresa crece o si el mismo servicio se reusa en un tenant más grande, se convierte en una query costosa sin índice de paginación.
- BorradoresViajeService reconstruye el estado de TextEditingControllers desde TramoViaje.fromMap al cargar el borrador, pero las fechas de gastos dentro de cada tramo se guardan como Timestamp en Firestore y se reconstruyen como DateTime. No hay test que verifique que la serialización/deserialización de gastos con fecha preserve el valor exacto (zona horaria ART vs UTC en el round-trip).


## vehiculos — 19 archivos leídos

El módulo de vehículos está bien estructurado: separación clara de concerns (repository, manager, actions, provider), lógica de mantenimiento centralizada en AppMantenimiento, prioridad MANUAL > API documentada y aplicada consistentemente en la pantalla de mantenimiento. Se detectaron 3 bugs reales: uno silencioso que rompe el gráfico de km/día y la tabla de consumo mensual en la pantalla de detalle de mantenimiento (tipo Timestamp vs String en TELEMETRIA_HISTORICO), una inconsistencia de cálculo entre la pantalla de detalle de mantenimiento del sheet de la lista y la pantalla de mantenimiento preventivo cuando existe INTERVALO_SERVICE_KM personalizado, y una race condition de baja severidad en la evaluación del estado de mantenimiento post-sync. La deuda técnica principal es el comentario invertido sobre la prioridad de fuentes de serviceDistance. La pantalla del chofer (Mi Equipo) es sólida, con buen manejo de conexión lenta y casts defensivos.

### Mejoras

| Mejora | Categoría | Impacto | Esfuerzo |
|---|---|---|---|
| Comentario invertido en admin_mantenimiento_widgets.dart: dice API > MANUAL pero el código hace MANUAL > API | mantenibilidad | bajo | bajo |
| El circuit breaker de VolvoApiService es por instancia: cada pantalla que instancia VolvoApiService() directo no comparte estado | robustez | medio | medio |
| Snapshot de telemetría usa DateTime.now() del dispositivo cliente, no ART | robustez | bajo | bajo |
| La limpieza del cache _lastSync en VehiculoProvider elimina los 100 primeros, no los más viejos | mantenibilidad | bajo | bajo |
| Alta de vehículo: el form acepta BIVUELCO y TANQUE con validación de año mínimo 2015, pero la flota real puede tener enganches más viejos | ux | bajo | bajo |
| Staleness check de telemetría en Mi Equipo usa solo ULTIMA_LECTURA_COMBUSTIBLE; si la unidad solo reporta odómetro, el hint no aparece | ux | medio | bajo |

- **Comentario invertido en admin_mantenimiento_widgets.dart: dice API > MANUAL pero el código hace MANUAL > API:** La línea 12 del archivo dice '(API > MANUAL > NINGUNO)' en el bloque de comentario de encabezado, pero el código real en _resolverServiceDistance (línea 48-63) aplica MANUAL > API > NINGUNO. El comentario engaña al próximo desarrollador que lo lea. Cambiar a '(MANUAL > API > NINGUNO)' para que coincida con la implementación real y con la justificación documentada en el código (líneas 32-47).
- **El circuit breaker de VolvoApiService es por instancia: cada pantalla que instancia VolvoApiService() directo no comparte estado:** VolvoApiService se instancia con 'new VolvoApiService()' en múltiples lugares: _AccionesVehiculoMenu._forzarSyncVolvo (admin_vehiculos_lista_widgets.dart:410), AdminVehiculoFormScreen._sincronizarConVolvo (admin_vehiculo_form_screen.dart:395), DiagnosticoVolvoScreen (diagnostico_volvo_screen.dart:55). Cada instancia tiene su propio _consecutive401. Si las credenciales Volvo expirar, el circuit breaker abre en la instancia usada por el sync automático (a través del provider), pero las instancias ad-hoc en las pantallas siguen enviando requests fallidos. Considerar singleton o inyección via provider para que el circuit breaker sea global.
- **Snapshot de telemetría usa DateTime.now() del dispositivo cliente, no ART:** guardarSnapshotsDiarios en vehiculo_repository.dart construye fechaTxt con DateTime.now() (línea 225-228). Si esta función se llama desde un dispositivo configurado en otra zona horaria (o desde una CF en UTC), el ID del doc y la fecha del snapshot quedarían mal alineados con los días ART. Dado que hoy solo se llama desde el cliente Flutter (Windows ART), el riesgo es bajo pero la función debería usar una fecha en TZ ART explícita para ser robusta. Usar AppFormatters.aIsoFechaLocal o calcular el día ART con DateTime.now().toLocal() (ya funciona en Windows ART) y documentarlo.
- **La limpieza del cache _lastSync en VehiculoProvider elimina los 100 primeros, no los más viejos:** vehiculo_provider.dart líneas 87-91: cuando _lastSync supera 500 entradas, borra las primeras 100 keys que devuelve .keys.take(100). Los Map de Dart no garantizan orden de inserción estable, pero en la práctica los iteran en orden de inserción — lo que significa que se borran las entradas MÁS VIEJAS (inserción más temprana), que es el comportamiento deseado. Sin embargo, si la implementación interna cambiara, podría eliminar entradas recientes. Para seguridad y claridad: mantener una lista auxiliar ordenada por timestamp o documentar la asunción de orden de Map.
- **Alta de vehículo: el form acepta BIVUELCO y TANQUE con validación de año mínimo 2015, pero la flota real puede tener enganches más viejos:** admin_vehiculo_alta_screen.dart línea 403: la validación isAnio rechaza años < 2015 ('Solo se admiten unidades modelo 2015 en adelante'). Esto aplica a todos los tipos incluyendo enganches (bateas, tolvas) que pueden ser más viejos. El admin no puede dar de alta un enganche fabricado en 2010 aunque sea operativo. Considerar aplicar el límite 2015 solo a TRACTORES (que son todos Volvo nuevos) y un rango más amplio para enganches (ej. 1995+).
- **Staleness check de telemetría en Mi Equipo usa solo ULTIMA_LECTURA_COMBUSTIBLE; si la unidad solo reporta odómetro, el hint no aparece:** user_mi_equipo_widgets.dart línea 464: el hint de 'Sin datos hace X días' se basa exclusivamente en data['ULTIMA_LECTURA_COMBUSTIBLE']. Si la unidad solo tiene KM_ACTUAL (sin combustible reportado), el chofer ve el odómetro pero no sabe si está desactualizado. Considerar también ULTIMA_SINCRO del doc vehiculo (que es el timestamp de cualquier sync, incluyendo los que solo actualizan KM_ACTUAL) para mostrar el hint de antigüedad en todos los casos.

### Ideas de features que esta área habilita

- Alerta proactiva al chofer por WhatsApp cuando su unidad tiene combustible < 20% o AdBlue < 15%: los datos ya viven en VEHICULOS (NIVEL_COMBUSTIBLE, NIVEL_ADBLUE actualizados por el poller) y hay infraestructura de alertas Volvo existente que podría extenderse con un destinatario 'chofer asignado'.
- Dashboard de eficiencia de flota: con los snapshots diarios de TELEMETRIA_HISTORICO (km + litros acumulados por unidad) ya existe la data para calcular y rankear el l/100km por tractor en el último mes. La pantalla de mantenimiento podría incluir una pestaña de 'Eficiencia' con ranking de consumo, útil para detectar tractores con problemas mecánicos (consumo anómalo).
- Historial de vencimientos: cada vez que el admin carga una fecha de RTO o Seguro, se podría guardar un log en una subcolección VEHICULOS/{patente}/vencimientos_historial. Permitiría ver cuándo venció y cuándo se renovó cada papel, útil para auditorías de la empresa.
- Notificación push al admin cuando el odómetro de un tractor sube más de un umbral (ej. 500 km en un día) desde el snapshot diario: detecta km absurdos por reset de odómetro o error del API antes de que afecten los cálculos de mantenimiento y gomería.

### Deuda técnica

- El comentario de encabezado de admin_mantenimiento_widgets.dart dice 'API > MANUAL > NINGUNO' pero el código implementa 'MANUAL > API > NINGUNO' — contradice la lógica real.
- VolvoApiService se instancia con 'new VolvoApiService()' en 3 puntos distintos de las pantallas, sin inyección de dependencias. El circuit breaker y el estado de auth no se comparten entre esas instancias y la instancia del provider.
- La función guardarSnapshotsDiarios es un método del VehiculoRepository (cliente Flutter), pero conceptualmente es una operación de escritura masiva que debería vivir en una Cloud Function — si se llama desde múltiples clientes a la vez, el mismo batch se ejecuta N veces (idempotente pero ineficiente).
- El campo 'fecha' en TELEMETRIA_HISTORICO es un Timestamp (escrito por guardarSnapshotsDiarios) pero hay código cliente que asume que es un String ISO. No hay schema enforcement — si otra CF u otro camino escribe el campo como String, el orderBy Firestore fallaría por tipo inconsistente.
- La pantalla de diagnóstico Volvo (DiagnosticoVolvoScreen) duplica parte de la lógica de parsing de _analizar() que ya existe en VolvoApiService._parseStatus. Si Volvo cambia el schema del response, habría que actualizar dos lugares.


## gomeria-checklist — 21 archivos leídos

El área gomeria-checklist-revisions es el módulo más elaborado y reciente del sistema. Gomería tiene un diseño sólido: modelo por posición (no serializado), locks optimistas sin runTransaction, semáforo de desgaste, conteo a ciegas, y rotaciones con swap. El checklist está bien resuelto para modo offline. Revisiones tiene lógica de seguridad robusta (whitelist de campos, planificarAprobacion pura testeable). El estado de salud general es bueno, pero hay un bug de deuda seria en gomería (kmUnidadAlMontar nunca se persiste al montar) que invalida el semáforo para todos los tractores con montajes nuevos, un storage leak en rechazo de revisiones, y un problema de escalabilidad latente en el stock (full-scan sin límite en colección que crece ilimitadamente).

### Mejoras

| Mejora | Categoría | Impacto | Esfuerzo |
|---|---|---|---|
| Leer kmActualTractor antes de montar y persistirlo | robustez | alto | bajo |
| Unificar aprobación de documentos en RevisionService y eliminar _aprobarDocumento | mantenibilidad | alto | bajo |
| Mantener un doc de stock agregado en Firestore en lugar de calcular en cliente | escalabilidad | medio | medio |
| Paralizar las lecturas de _kmEnganche | rendimiento | medio | bajo |
| Agregar navegación directa a la pantalla de gomería desde la card del chofer en checklist | ux | medio | bajo |
| Guardar snapshot de la etiqueta del conteo con el modelo etiqueta completo en compararConteoVsStock | datos | bajo | bajo |

- **Leer kmActualTractor antes de montar y persistirlo:** En _montar() de gomeria_v2_unidad_screen.dart, antes de llamar a _service.montar(), llamar a _service.kmCierreRetiro equivalente o exponer un método _service.kmActualTractor(unidadId) y pasarlo como kmUnidadAlMontar. Para enganches no hay odómetro propio, dejar null como hoy. Esto activa el semáforo de desgaste para todos los tractores con montajes futuros.
- **Unificar aprobación de documentos en RevisionService y eliminar _aprobarDocumento:** Eliminar el método _aprobarDocumento() del screen y hacer que _procesarDecision(context, true) para no-cambio-equipo llame a RevisionService.finalizarRevision(aprobado: true, datos: data). El servicio ya tiene la lógica correcta (planificarAprobacion, whitelist de campos, audit). De paso, el rechazo también debe ir por RevisionService.finalizarRevision(aprobado: false) para que borre el Storage.
- **Mantener un doc de stock agregado en Firestore en lugar de calcular en cliente:** Crear un doc GOMERIA_STOCK_ACTUAL/{modeloId_vida} con campo cantidad, actualizado por Cloud Function en cada write a GOMERIA_STOCK_MOVIMIENTOS (trigger onWrite). stockActual() y streamStock() pasan a leer esa colección pequeña (<50 docs para la flota actual) en lugar de la colección de movimientos que crece sin límite. stockDisponible() también mejora: una sola lectura en lugar de query filtrada.
- **Paralizar las lecturas de _kmEnganche:** En kmRecorridoPorPosicion(), reemplazar el loop for-await serial sobre montajes por Future.wait(montajesActivos.map(m => _kmEnganche(...))). Reduce el tiempo de carga de un enganche de N*tiempo_por_posicion a tiempo_de_la_posicion_más_lenta. Misma mejora posible en _kmEnganche internamente: paralelizar las lecturas de las duplas.
- **Agregar navegación directa a la pantalla de gomería desde la card del chofer en checklist:** El operador que hace el checklist de neumáticos (sección NEUMATICOS, 6 ítems) frecuentemente querrá ver el estado del montaje en gomería. Agregar un botón 'Ver en Gomería' en el header del checklist (o en la sección NEUMATICOS) que navegue directamente a GomeriaV2UnidadScreen con la patente del checklist.
- **Guardar snapshot de la etiqueta del conteo con el modelo etiqueta completo en compararConteoVsStock:** La función compararConteoVsStock usa etiqueta[m] ??= l.modeloEtiqueta, lo que prioriza la etiqueta del stock sobre la del conteo. Si el modelo fue renombrado entre el conteo y la revisión, el admin ve el nombre nuevo, no el que vio el operador cuando contó. Considerar persistir la etiqueta del modelo en el conteo (ya está en LineaConteo.modeloEtiqueta) y usarla siempre en la pantalla de revisión para mostrar consistencia con el momento del conteo.

### Ideas de features que esta área habilita

- Alerta automática por cubiertas críticas: un cron diario (o trigger en onWrite de GOMERIA_MONTAJES) que calcula el % de vida de cada posición activa y envía un resumen WhatsApp al supervisor con las cubiertas en NivelDesgaste.critico. Ya existe el patrón de resúmenes diarios (resumenes_diarios.ts) y toda la lógica de cálculo es pura y testeable.
- Historial de costo por km de cubierta: cuando se cierra un montaje con kmRecorridos > 0, registrar el costo estimado (precio unitario del modelo × 1) / kmRecorridos en un campo 'costo_por_km'. Alimenta un ranking de modelos más rentables que Vecchi puede usar para decidir qué marcas comprar en la próxima licitación.
- Integración checklist-gomería: al completar la sección NEUMATICOS del checklist con REG o MAL en algún ítem, auto-crear una tarea pendiente en gomería vinculada a la posición afectada. El gomero la ve al abrir esa unidad sin tener que esperar al supervisor.
- Conteo periódico sugerido: si pasaron más de N días desde el último conteo revisado, mostrar un banner en el hub de gomería para el rol GOMERIA. El dato ya está en GOMERIA_CONTEOS, solo hay que consultar el más reciente.

### Deuda técnica

- MontajesService._kmEnganche está DUPLICADO verbatim respecto de GomeriaService (comentario en la línea 718 lo reconoce). Debe unificarse cuando se borre el servicio viejo.
- GomeriaService (modelo viejo serializado) coexiste con MontajesService. El comentario 'Coexiste con GomeriaService hasta migrar' lleva semanas. Mantener dos servicios con lógica solapada aumenta el riesgo de divergencia silenciosa.
- _colorNivel está DUPLICADO: existe en gomeria_v2_unidad_screen.dart (línea 72) y en esquema_unidad_v2_view.dart (línea 112). Debería vivir en un helper compartido del feature o en nivel_desgaste.dart.
- La pantalla admin_gomeria_marcas_modelos_screen.dart accede a FirebaseFirestore.instance directamente en los builds de los StreamBuilder (en lugar de inyectar el db como en los servicios). Inconsistente con el patrón del resto del módulo y dificulta los tests.
- El campo 'TRAC2_*' en los códigos de posición del eje neumático del tractor fue intencionalentamente conservado para no romper referencias históricas, pero su nombre es engañoso (TRAC2 apunta a arrastre). Un comentario en código lo explica, pero datos en Firestore y queries externas que filtren por prefijo 'TRAC' pueden malinterpretar el tipo de eje.
- ChecklistData usa Map<String, List<String>> estático con strings numerados ('1. GUARDABARROS'). No hay modelo tipado para los ítems del checklist ni validación de que los índices sean únicos o consecutivos. Si se edita el mapa, es fácil crear ítems duplicados o desordenados sin que el compilador lo detecte.


## personal — 18 archivos leídos

El área de Personal/Asignaciones cubre legajos de empleados (CRUD + soft-delete), documentos laborales por empresa empleadora (docId=CUIT), asignaciones temporales inmutables chofer↔tractor y tractor↔enganche con registro de odómetro Sitrack. La arquitectura es sólida: servicios centralizados, mutex de operación sobre Firestore para evitar duplicados, manejo explícito del bug de `runTransaction` en Windows, audit log sistemático, y un modelo snapshot que permite reconstruir quién manejaba qué en cualquier fecha del pasado. Los principales riesgos son un potential crash por cast directo de Timestamp en `TramoIButton.fromDoc`, la omisión de un gate de capability en el botón "Resetear contraseña" (visible a todos los roles), y queries N+1 en el cruce chofer→tractor→enganche. El estado de salud general es bueno.

### Mejoras

| Mejora | Categoría | Impacto | Esfuerzo |
|---|---|---|---|
| Paralelizar lookups de Sitrack en ChoferActividadService | rendimiento | medio | bajo |
| Agregar capability 'resetearContrasenaEmpleado' y gatear el botón | ux | bajo | bajo |
| Completar descripciones de GOMERIA y SEG_HIGIENE en el form de alta | ux | bajo | bajo |
| Null-safety en TramoIButton.fromDoc para campos Timestamp | robustez | medio | bajo |
| Paginar enganchesLlevadosPorChofer para choferes con historial largo | escalabilidad | bajo | bajo |
| Mostrar ÁREA actual en la tarjeta de baja (panel inactivos) | ux | bajo | bajo |
| Agregar índice compuesto en SITRACK_IBUTTONS_HISTORICO para filtros combinados | robustez | alto | bajo |
| Emitir alerta WhatsApp si el cascade de ASIGNACIONES_ENGANCHE falla silenciosamente | mantenibilidad | medio | medio |

- **Paralelizar lookups de Sitrack en ChoferActividadService:** En el loop de asignaciones activas (líneas 206-243 de chofer_actividad_service.dart), acumular todas las patentes activas con odómetro inicial en un Map y resolverlas todas con `Future.wait([...snapSvc.obtener(p)])` antes del loop de cómputo. Reduce la latencia de O(N * RTT_Sitrack) a O(RTT_Sitrack) para el caso de múltiples asignaciones activas.
- **Agregar capability 'resetearContrasenaEmpleado' y gatear el botón:** En capabilities.dart agregar `resetearContrasenaEmpleado` al set de SUPERVISOR y ADMIN. En `_BotonBajaReactivarEmpleado.build` envolver el botón 'Resetear contraseña' con `if (Capabilities.can(PrefsService.rol, Capability.resetearContrasenaEmpleado))`. Mantiene la validación server-side como segunda capa, pero la UI deja de mostrar opciones que el rol no puede ejecutar.
- **Completar descripciones de GOMERIA y SEG_HIGIENE en el form de alta:** En `_RoleSelector._descripcion` de admin_personal_form_screen.dart agregar casos para `AppRoles.gomeria` ('Operador de cubiertas y gomería') y `AppRoles.segHigiene` ('Seguridad e Higiene — monitoreo de conducta'). Sin ellos el dropdown muestra sublínea vacía para esos dos roles.
- **Null-safety en TramoIButton.fromDoc para campos Timestamp:** Reemplazar los casts directos `(m['desde'] as Timestamp).toDate()` y `(m['hasta'] as Timestamp).toDate()` por `(m['desde'] as Timestamp?)?.toDate() ?? DateTime.now()` y equivalente, o bien hacer fail-safe en el stream con `.handleError` para no romper la UI completa por un doc malformado.
- **Paginar enganchesLlevadosPorChofer para choferes con historial largo:** En `asignacion_enganche_service.dart`, `enganchesLlevadosPorChofer` hace una query `get()` sin límite por cada tractor del chofer. Agregar `.limit(100)` a la query de ASIGNACIONES_ENGANCHE por tractor (línea 418) y documentar el límite. Para Vecchi el historial es corto (<50 tractores), pero el límite explícito evita lecturas no acotadas si la colección crece.
- **Mostrar ÁREA actual en la tarjeta de baja (panel inactivos):** El panel de empleados inactivos (`_GrupoPersonal.inactivos`) no muestra ningún dato de área o motivo de baja en la fila de lista `_FilaPersona`. Agregar el motivo de baja (data['BAJA_MOTIVO']) como segunda línea visible en la fila sería útil para que el admin identifique si el inactivo fue un despido, vacaciones largas, etc., sin necesidad de abrir la ficha.
- **Agregar índice compuesto en SITRACK_IBUTTONS_HISTORICO para filtros combinados:** HistoricoIButtonService.streamPorRango puede combinar filtro por `desde` (range) + `patente` o `chofer_dni` (equality). Sin índice compuesto `(patente, desde)` y `(chofer_dni, desde)` en Firestore, la query falla en producción. Verificar que esos índices existan en firestore.indexes.json y agregarlos si no.
- **Emitir alerta WhatsApp si el cascade de ASIGNACIONES_ENGANCHE falla silenciosamente:** En asignacion_vehiculo_service.dart, el bloque del paso 9 (cascade enganche) solo hace `AppLogger.recordError` si falla. En producción eso puede pasar desapercibido durante días. Dado que el sistema ya tiene canal de alertas Telegram, considerar añadir un aviso de alerta (vía la misma función de notificación de la PC dedicada) cuando el cascade falle, para que Santiago pueda reconciliar manualmente sin esperar a que alguien lo note en la auditoría.

### Ideas de features que esta área habilita

- Panel de alertas de vencimientos por empresa: ya se tiene el dato de VENCIMIENTO_POLIZA_ART y VENCIMIENTO_FORMULARIO_931 por CUIT, y todos los empleados tienen EMPRESA_CUIT denormalizado. Con eso se puede construir una vista 'Vencimientos críticos por empresa' que muestre cuántos empleados quedan afectados cuando vence una póliza ART, sin ninguna lectura adicional.
- Tablero de rotación de tractores: con ASIGNACIONES_VEHICULO se tiene el historial completo de quién manejó qué unidad y por cuántos días. Un gráfico de Gantt o tabla pivot 'tractor × chofer × semana' permitiría visualizar patrones de rotación, identificar tractores muy usados por un solo chofer (riesgo de descanso de unidad) o períodos de alta disponibilidad.
- Resumen de km por chofer exportable: el tablero ChoferActividadScreen ya calcula km por período. Agregar un botón 'Exportar CSV' con la lista de todos los choferes activos y sus km en el período seleccionado sería útil para la liquidación o para enviar a Molina/supervisor sin entrar al sistema.
- Historial de cambios de empresa empleadora: cuando un empleado cambia de empresa (EmpleadoActions.dato con campo 'EMPRESA'), ese cambio no queda en ningún log temporal más allá del AuditLog genérico. Con un subcolección HISTORIAL_EMPRESA en cada empleado se podría trazar el período laboral por empresa (útil para ART proporcionales y cartas de presentación).
- Alerta automática de documentos de empresa por vencer: ya existe VencimientoBadge en la pantalla de empresas empleadoras. Con un cron diario que consulte EMPRESAS_EMPLEADORAS y compare las fechas de vencimiento contra hoy, se podría enviar un WhatsApp de alerta a Santiago o Molina cuando la Póliza ART de alguna empresa esté a menos de 30 días de vencer, sin que nadie tenga que entrar a la pantalla a mirar.

### Deuda técnica

- admin_personal_form_screen.dart `_RoleSelector._descripcion`: switch incompleto — no tiene cases para AppRoles.gomeria ni AppRoles.segHigiene (retorna '' para ellos). Añadir cuando se tenga un minuto.
- TramoIButton.fromDoc: casts de Timestamp sin null-safety. El resto del codebase usa el patrón `(x as Timestamp?)?.toDate()` — alinear.
- El botón 'Resetear contraseña' no está gateado por capability. El patrón correcto del resto del archivo (puedeBaja, asignarRolAdmin) no se aplicó acá.
- HistoricoIButtonService.streamPorRango: no tiene índices documentados en código ni en firestore.indexes.json para las combinaciones filtradas. El módulo de auditoría old quedó sin uso (ver comentario en admin_auditoria_asignaciones_screen.dart) pero la colección SITRACK_IBUTTONS_HISTORICO sigue siendo escrita por la CF y el servicio sigue vivo.
- enganchesLlevadosPorChofer hace 1 query a Firestore por cada asignación de tractor (N queries sin límite). El número actual de asignaciones es bajo, pero no hay un `limit()` explícito como guardrail.
- El form de alta (admin_personal_form_screen.dart) no envía notificación por WhatsApp ni crea el usuario en Firebase Auth. La autenticación usa login por DNI vía Cloud Function que emite custom token — no hay un paso explícito de 'provisionado de acceso' documentado en el código del form, queda como responsabilidad implícita del admin.


## icm-eco — 14 archivos leídos

El área cubre el módulo ICM (7 archivos: service, 5 pantallas) y el módulo Eco-Driving/Volvo (7 archivos: modelo, service, 2 utilidades, 2 widgets, 2 pantallas). El ICM oficial está bien diseñado: el invariante YPF (totales sin modificar, exclusiones solo en la vista) está correctamente implementado en todos los callers. La lógica de ranking, severidad y comparativas mes-a-mes es robusta. El eco-driving tiene buena separación modelo/service/UI. El área más débil es el stream sin paginación de `VOLVO_ALERTAS` en el mapa, que crece ilimitadamente en producción. Sin errores de plata, sin race conditions, sin dispose faltantes. Deuda técnica menor: duplicación de clases auxiliares entre pantallas ICM y algunas queries de eco-driving sin límite explícito.

### Mejoras

| Mejora | Categoría | Impacto | Esfuerzo |
|---|---|---|---|
| Agregar .limit() al stream de VOLVO_ALERTAS en el mapa | rendimiento | alto | bajo |
| Mover instanciación de servicios fuera de build() en ScoreDrilldownSheet | rendimiento | medio | bajo |
| Consolidar la lógica de _colorSeveridad duplicada entre pantallas ICM | mantenibilidad | bajo | bajo |
| Consolidar el widget _ChipPeriodo/_Chip duplicado entre pantallas ICM | mantenibilidad | bajo | bajo |
| Agregar índice compuesto en Firestore para queries eco-driving | robustez | alto | bajo |
| Mostrar el período real en _DetalleChofer cuando se cae al mes anterior | ux | medio | bajo |
| Indicar cuándo el hub ICM cayó al mes anterior por falta de datos | ux | medio | bajo |

- **Agregar .limit() al stream de VOLVO_ALERTAS en el mapa:** En `admin_mapa_volvo_screen.dart` línea 117, agregar `.limit(2000)` (o el valor acordado) antes de `.snapshots()`. Complementariamente, mostrar en la toolbar cuando el resultado está truncado ('Mostrando los últimos 2000 eventos'). Para el rango de 90 días agregar paginación o convertir a `Future.get()` con un botón de refresco explícito en lugar de un stream en vivo.
- **Mover instanciación de servicios fuera de build() en ScoreDrilldownSheet:** Convertir `ScoreDrilldownSheet` de `StatelessWidget` a `StatefulWidget` e instanciar `EcoDrivingService` y `AsignacionVehiculoService` en `initState()`. Alternativamente, recibirlos como parámetros del constructor. Esto elimina los re-subscribe Firestore en cada rebuild del sheet.
- **Consolidar la lógica de _colorSeveridad duplicada entre pantallas ICM:** La función `_colorSeveridad(BuildContext, String)` con el mismo switch se duplica en `icm_ranking_screen.dart` (como método de instancia de `_FilaChofer`), `icm_reporte_semanal_screen.dart` (función libre), e `icm_detalle_chofer_screen.dart` (función libre). Moverla a `icm_oficial_service.dart` o a un archivo `icm_colors.dart` compartido, y reemplazar las tres copias con un import. Reduce el riesgo de que las 3 copias diverjan.
- **Consolidar el widget _ChipPeriodo/_Chip duplicado entre pantallas ICM:** El widget pill de selección de período se implementa de forma casi idéntica en `icm_ranking_screen.dart`, `icm_mapa_calor_screen.dart` e `icm_reporte_semanal_screen.dart`. Extraer a un widget compartido `IcmChipPeriodo` en `lib/features/icm/widgets/`. Reduce ~90 líneas de código duplicado.
- **Agregar índice compuesto en Firestore para queries eco-driving:** Los streams `streamFleetEntreFechas`, `streamPorVehiculoEntreFechas` y `streamHistorialPorPatente` en `eco_driving_service.dart` combinan filtro de igualdad (`es_fleet` o `patente`) con filtro de rango (`fecha_ts`) y `orderBy`. Firestore requiere un índice compuesto para estas queries. Si no está creado, el SDK cae a una excepción con un link de creación en dev, pero en prod puede silenciar el error. Verificar que los 3 índices compuestos existen en `firestore.indexes.json`.
- **Mostrar el período real en _DetalleChofer cuando se cae al mes anterior:** En `icm_detalle_chofer_screen.dart` línea 141, cuando `esActual == false` el header muestra el label del mes anterior con el sufijo '· último con datos'. La comparativa `_ComparativaMeses` muestra la diferencia entre actual (null) y anterior, y retorna `SizedBox.shrink()` correctamente. Sin embargo, la sección 'Infracciones', 'Recorrido' y 'Detalle de infracciones' muestran datos del mes anterior sin indicar de qué mes son (se pierde el contexto visual del período). Agregar un `AppBadge` o nota de período en cada sección para evitar confusión.
- **Indicar cuándo el hub ICM cayó al mes anterior por falta de datos:** En `icm_hub_service.dart` líneas 124–149, cuando el mes en curso no tiene actividad se cae al mes anterior. El `periodoLabel` lo refleja, pero el `KpiIcm.anterior` se pone en 0 (comparativa forzada a 0). El resultado es que el hub puede mostrar una variación vs el mes previo del mes anterior, no del mes en curso. Si el estado 'sin actividad a inicio de mes' es común, considerar mostrar un indicador explícito ('Mostrando mes anterior por falta de datos del mes en curso') en lugar de solo el label del período.

### Ideas de features que esta área habilita

- Tendencia ICM por chofer individual: el detalle de chofer ya carga 2 períodos mensuales. Con un selector de 'últimos 6 meses' y un micro-gráfico de línea del ICM mensual (mismo sparkline que el eco-driving), el operador puede ver si el chofer mejoró o empeoró de forma consistente — dato que hoy no existe en ninguna pantalla y que el management pedirá para premios anuales.
- Alertas proactivas ICM: cruzar el ranking semanal (ICM_OFICIAL_SEMANAL, ya existe la colección) contra el mensual y enviar un WhatsApp al supervisor cuando un chofer que tenía severidad 'bajo' sube a 'alto' en la semana en curso. Los datos están, solo falta el trigger en la Cloud Function del cron semanal.
- Desglose de infracciones por tipo en el reporte mensual de flota: el doc ICM_OFICIAL ya incluye las infracciones individuales embebidas por chofer. Agregando en el reporte una tabla con los top 5 tipos de infracción de TODA la flota (suma de `infraccion` agrupada), el operador ve los patrones sistémicos (ej. 'el 60% de las infracciones son frenadas bruscas en un tramo específico') sin abrir cada chofer.
- Score eco-driving por chofer (no solo por vehículo): la API de Volvo entrega scores por vehículo, pero cruzando con el historial de asignaciones (ya disponible en `AsignacionVehiculoService`) se puede calcular el score atribuible a cada chofer para el rango seleccionado. Esto habilita un ranking de eco-driving análogo al ranking ICM.
- Mapa de calor eco-driving a partir de VOLVO_ALERTAS OVERSPEED + ICM infracciones de velocidad: combinar los hotspots del ICM con los OVERSPEED del mapa Volvo en una sola vista de 'tramos peligrosos de la flota'. Los datos ya existen en dos colecciones; solo falta la pantalla de visualización unificada.

### Deuda técnica

- La función `_colorSeveridad(BuildContext, String)` está copiada 3 veces en las pantallas ICM con lógica idéntica — riesgo de divergencia silenciosa si cambia el criterio de coloreo.
- El widget pill de período (_ChipPeriodo / _Chip) está implementado en 3 pantallas ICM y una vez más en el mapa Volvo, con diferencias menores de padding y borderRadius — candidato a widget compartido.
- La clase `_StatGrid` + `_StatCell` están duplicadas entre `icm_reporte_semanal_screen.dart` y `icm_detalle_chofer_screen.dart` (mismo código, mismo nombre). Deberían vivir en un archivo compartido.
- La clase `_BarraFiltros` / `_BarraPeriodo` y su `_ChipPeriodo` también están duplicadas entre las 3 pantallas ICM. Son candidatos a un único widget parametrizable.
- El `EcoDrivingService` en `score_drilldown_sheet.dart` se instancia en `build()` en lugar de ser pasado como parámetro o creado en `initState()` — pattern contrario al resto de la app.
- La ruta/archivo se llama `icm_reporte_semanal_screen.dart` pero el contenido es un reporte mensual — confusión histórica documentada en el código pero que complica la navegación del repo.
- Los índices compuestos Firestore para las 3 queries de eco-driving (es_fleet+fecha_ts, patente+fecha_ts) no están explícitamente verificados en el código Flutter — dependen de que el scraper/deploy los haya creado correctamente.


## reportes-vencimientos — 22 archivos leídos

El área de reportes-vencimientos cubre dos dominios: (1) generación de Excel en cuatro reportes (Flota, Consumo, ICM, Checklists) con un helper compartido de XML post-procesado para AutoFilter + DataValidation, y (2) pantallas de auditoría de vencimientos por entidad (personal, tractores, enganches, calendario, vista chofer). El código está en buen estado general: las fórmulas de consumo L/100km son correctas, el parche ZIP/XML para AutoFilter es sólido, el manejo de fechas usa helpers centralizados con TZ ART. No hay runTransaction en código Windows-bound. Se detectaron tres bugs reales de severidad media/alta y varias mejoras accionables.

### Mejoras

| Mejora | Categoría | Impacto | Esfuerzo |
|---|---|---|---|
| Ampliar rango A1:Z10000 del autoFilter cuando el reporte ICM tenga más de 26 columnas | robustez | bajo | bajo |
| Snapshot con fecha inválida (dias==null) no pinta dot en el calendario de vencimientos | ux | medio | bajo |
| El reporte de Consumo usa DateTime.now() para el default del rango (sin TZ ART explícita) | robustez | bajo | bajo |
| Rango de histórico ampliado en reporte de Consumo puede exceder cuota Firestore | rendimiento | bajo | bajo |
| report_save_helper.dart: writeAsBytesSync después de que saveFile ya escribió el archivo | mantenibilidad | bajo | bajo |
| Auditorías de vencimientos cargan TODA la colección EMPLEADOS/VEHICULOS sin paginación | escalabilidad | bajo | medio |
| Reporte ICM: nombre de archivo usa DateTime.now() sin TZ ART para el timestamp del nombre | ux | bajo | bajo |

- **Ampliar rango A1:Z10000 del autoFilter cuando el reporte ICM tenga más de 26 columnas:** El comentario en _inyectarAutoFilter (excel_utils.dart:229) ya advierte que el rango A1:Z10000 se rompe con > 26 columnas. Las hojas CHOFERES del ICM tienen 14 cols y RESUMEN tiene 2, pero si en el futuro se agrega columnas (p.ej. LICENCIA, EMPRESA), la columna AA en adelante queda sin filtro en silencio. Parametrizar el rango calculando el número real de columnas de la hoja en aplicarAutoFilterAlXlsx, o al menos ampliar a AMJ1048576 (máximo OOXML).
- **Snapshot con fecha inválida (dias==null) no pinta dot en el calendario de vencimientos:** En _construirMapa (admin_vencimientos_calendario_screen.dart:92), los items de empleados con fecha inválida son descartados por tryParseFecha y nunca entran al mapa del calendario. Las listas planas de auditoría sí los muestran (incluyen dias==null explícitamente). Resultado: el admin ve 2 vencimientos corruptos en la lista pero 0 dots en el calendario ese día — inconsistencia que puede hacer que pase por alto datos rotos. Solución: cuando tryParseFecha falla, agregar el item al día de hoy (o a una lista separada de 'sin fecha') para que el calendario muestre un dot rojo.
- **El reporte de Consumo usa DateTime.now() para el default del rango (sin TZ ART explícita):** En mostrarOpcionesYGenerar (report_consumo.dart:90), el rango default 'desde = DateTime(hoy.year, hoy.month, 1)' usa DateTime.now() que en un Windows con TZ configurada en UTC u otra zona puede devolver un mes diferente al ART. El admin en Buenos Aires a las 00:30 con TZ=UTC vería el mes anterior como default. Solución: usar tz.TZDateTime.now(tz.local) del paquete timezone (ya importado en notification_service.dart) o al menos documentar el supuesto.
- **Rango de histórico ampliado en reporte de Consumo puede exceder cuota Firestore:** La query de TELEMETRIA_HISTORICO amplía 30 días hacia atrás del 'desde' elegido (report_consumo.dart:285: desdeAmpliado = desde.subtract(Duration(days: 30))). Si el admin pide 'enero 2024' el query trae desde diciembre 2023 + 1 día después de hasta. Con flota de 20 tractores × ~365 días = ~7300 docs por año, ampliarlo 30 días extra agrega ~600 reads extra por cada reporte. No es crítico hoy, pero al crecer el histórico (retención infinita, colección crece) puede notarse. Considerar reducir el buffer a 7 días (la sync puede fallar a lo sumo un fin de semana largo) o memoizar snapshots de inicio/fin por patente.
- **report_save_helper.dart: writeAsBytesSync después de que saveFile ya escribió el archivo:** En la rama Windows (report_save_helper.dart:105-107), se verifica si el archivo existe Y su longitud es 0 antes de escribir. Pero FilePicker.saveFile() en 11.x con bytes ya escribe el archivo en el path elegido; la condición `!File(path).existsSync() || File(path).lengthSync() == 0` es defensiva correcta pero incluye un race: otro proceso puede crear el archivo entre existsSync y lengthSync. No es un bug crítico pero la doble-escritura potencial si el picker falla a mitad es ruido. Simplificar a escribir siempre con writeAsBytesSync sin condición (idempotente para xlsx).
- **Auditorías de vencimientos cargan TODA la colección EMPLEADOS/VEHICULOS sin paginación:** Las tres pantallas de auditoría (choferes, chasis, acoplados) y el calendario usan snapshots() sin limit() sobre EMPLEADOS y VEHICULOS. Con la flota actual (~50 choferes, ~30 vehículos) es trivial. Si la empresa crece o se migra data histórica de otras empresas, estas queries descargan miles de docs en cada apertura. Considerar un límite de 200 docs o un índice compuesto por ROL+ACTIVO para choferes.
- **Reporte ICM: nombre de archivo usa DateTime.now() sin TZ ART para el timestamp del nombre:** En _ejecutarGeneracion (report_icm.dart:150), el nombre del archivo usa intl.DateFormat('yyyy-MM-dd_HHmm').format(DateTime.now()). En Windows admin con TZ=UTC el timestamp en el nombre puede mostrar la hora UTC (3 horas antes que ART). No afecta el contenido del Excel, pero un archivo generado a las 01:00 ART llevaría timestamp del día anterior en su nombre. Usar AppFormatters.aIsoFechaLocal(DateTime.now()) + hora local para consistencia.

### Ideas de features que esta área habilita

- Exportar el calendario de vencimientos a PDF/Excel: ya existe toda la estructura del mapa fecha→items en admin_vencimientos_calendario_screen.dart. Con un botón 'Exportar mes' se podría generar un Excel con columnas Fecha | Entidad | Tipo Doc | Días Restantes, filtrando el mes visible. Los datos ya están en memoria.
- Alertas WhatsApp proactivas para vencimientos del administrador: el bot ya envía avisos al chofer vía WhatsApp (aviso_builder.js). Con los mismos datos del calendario (toda la flota + personal), el cron de las 8:00 podría enviar al admin un resumen de 'vencen esta semana' igual que ya hace con jornadas y conductas. Los datos necesarios ya están en Firestore.
- Reporte de tendencia de consumo mensual: el TELEMETRIA_HISTORICO ya acumula datos por patente y día. Con ese histórico se puede armar un gráfico de barras por mes (en Unicode, como el ranking actual) que muestre si el consumo de la flota está subiendo o bajando. Los datos ya existen.
- Exportar vencimientos próximos como agenda ICS: el calendario de vencimientos ya tiene fecha + título por evento. Generando un archivo .ics (formato iCalendar, texto plano) el admin podría importar todos los vencimientos de la flota a Google Calendar o Outlook con un clic.

### Deuda técnica

- excel_utils.dart: _inyectarDataValidation y _inyectarAutoFilter se llaman en pasadas separadas sobre el ZIP — si configurarConsultaYOcultarHojas se llama antes de aplicarAutoFilterAlXlsx, el ZIP se decodifica y recodifica dos veces. Unificar en una sola pasada sobre el archive para la planilla de viajes.
- report_consumo.dart: _fechaMinHistoricoCache y _fechaMinHistoricoFuture son static, lo que significa que si la colección crece y se agrega data vieja (backfill manual), el cache queda obsoleto por toda la sesión. Agregar un TTL o un botón 'actualizar' en el dialog.
- admin_vencimientos_calendario_screen.dart: _construirMapa se llama en el build() directamente (sin memoización explícita entre renders). Con StreamBuilder nested, si el outer stream emite y el inner aún no tiene data (o viceversa), _construirMapa recibe el snapshot viejo del otro y recalcula el mapa completo. Un ValueNotifier/useMemoized evitaría los recálculos innecesarios.
- La lógica de construir items de vencimiento está duplicada entre admin_vencimientos_choferes_screen.dart (for con AppDocsEmpleado.etiquetas) y admin_vencimientos_calendario_screen.dart (mismo for). Si se agrega un tipo de doc a AppDocsEmpleado.etiquetas, solo el calendario lo recoge automáticamente por el forEntry; la pantalla de choferes también lo recoge, pero la lógica duplicada es deuda de mantenimiento.
- VencimientoEditorSheet._guardar() no invalida ni borra la revisión pendiente (REVISIONES) si el admin edita directamente el vencimiento sin pasar por el flujo de aprobación. El doc REVISIONES puede quedar huérfano en Firestore — 'PENDIENTE' para siempre — si el admin actualiza el vencimiento manualmente desde la auditoría. Agregar limpieza de revisiones pendientes del mismo campo al guardar.


## jornadas-flutter — 17 archivos leídos

El área cubre tres módulos: registro de jornada v3 (pantalla chofer + vista admin con gráfico velocidad/tiempo y selector de rango combinado), histórico de jornadas v2 (pantalla admin con gráfico fl_chart + tramos/paradas), y el panel de WhatsApp/agente IA (cola, historial, bandeja ambiguos, dashboard del agente conversacional). El código es prolijo, sigue el patrón bento-Núcleo, respeta los helpers de formato AR, y los streams están correctamente manejados (sin subscriptions sin dispose porque son StreamBuilders). El estado general de salud es bueno, con un bug crítico de null-safety en el modelo JornadaDia (v2) que puede crashear la pantalla de jornada del chofer en producción, y un par de issues menores en el combinado v3 y el historial WhatsApp.

### Mejoras

| Mejora | Categoría | Impacto | Esfuerzo |
|---|---|---|---|
| Completar null-safety en JornadaDia, TramoManejo y Parada | robustez | alto | bajo |
| Bloquear ejecución de consulta historial WhatsApp cuando hay >1 filtro server-side | robustez | medio | bajo |
| Corregir descansoPrevioSeg en _combinarRegistros | ux | medio | bajo |
| Guardar el intervaloX del gráfico con un mínimo de 1ms | robustez | bajo | bajo |
| Extraer y reutilizar el selector de chofer duplicado | mantenibilidad | medio | medio |
| Rango del picker admin-registro limitado a datos disponibles, no a 365 días | ux | bajo | bajo |
| Paginación real en AdminAgenteConversacionesScreen para periodos largos | datos | medio | medio |

- **Completar null-safety en JornadaDia, TramoManejo y Parada:** Reemplazar todos los casts `(m['x'] as Timestamp).toDate()` por `(m['x'] as Timestamp?)?.toDate() ?? DateTime.fromMillisecondsSinceEpoch(0)` en jornada_dia.dart, igual que el patrón del modelo hermano registro_jornada.dart. Afecta inicio/fin en JornadaDia (l.81-82), desde/hasta en TramoManejo (l.119-120), y desde/hasta en Parada (l.154-155).
- **Bloquear ejecución de consulta historial WhatsApp cuando hay >1 filtro server-side:** En admin_whatsapp_historico_screen.dart, en lugar de solo mostrar el warning cuando `_filtrosServerActivos > 1`, deshabilitar el botón de búsqueda y desactivar los chips de estado si ya hay un filtro de DNI u origen activo (y vice-versa). Alternativa: crear los índices compuestos faltantes en firestore.indexes.json para las combinaciones frecuentes (ej. estado + destinatario_id + registrado_en).
- **Corregir descansoPrevioSeg en _combinarRegistros:** En admin_registro_jornada_screen.dart función `_combinarRegistros`, para `descansoPrevioSeg` buscar el valor del turno con `descansoInsuficiente == true` (el que tiene el gap problemático), o en su defecto el del último turno del rango (el descanso más reciente es el más relevante para el operador). El campo `descansoPrevioSeg` se usa exclusivamente para el label del badge, por lo que el cambio no afecta la lógica de flags.
- **Guardar el intervaloX del gráfico con un mínimo de 1ms:** Antes de pasar `interval: intervaloX` a fl_chart en jornada_dia_screen.dart y registro_jornada_detalle_screen.dart, aplicar `max(1.0, intervaloX)` para evitar interval=0 con series donde todos los timestamps son iguales.
- **Extraer y reutilizar el selector de chofer duplicado:** JornadaDiaScreen y AdminRegistroJornadaScreen tienen código de selector de chofer casi idéntico (~100 LOC cada uno: _cargarChoferes, bottom sheet con StatefulBuilder y buscador, _ChoferOpt). Extraer a un widget compartido `ChoferSelectorSheet` en lib/shared/widgets/ reduciendo duplicación y garantizando que mejoras futuras (ej. paginación, foto de perfil) se apliquen en ambas pantallas.
- **Rango del picker admin-registro limitado a datos disponibles, no a 365 días:** En JornadaDiaScreen, el DateRangePicker tiene `firstDate: hoy.subtract(365d)` aunque VOLVO_JORNADAS_HISTORICO puede tener docs más o menos antiguos. AdminRegistroJornadaScreen limita correctamente al rango de los datos cargados (firstDate/lastDate = más viejo/más nuevo del listado). Alinear JornadaDiaScreen para respetar la misma restricción, o agregar una llamada inicial a `JornadaHistoricoService.fechasDisponibles()` para deshabilitar fechas vacías en el picker.
- **Paginación real en AdminAgenteConversacionesScreen para periodos largos:** El stream de AGENTE_CONVERSACIONES tiene un limit fijo de 250 docs. Si se selecciona ventana de 30 días y el agente tiene >250 conversaciones, los KPIs (tasa de éxito, tools más usadas) serán incorrectos porque se calculan solo sobre los 250 más recientes. Considerar pasar el rango de fechas como filtro server-side (`where('creado_en', >=, corte)`) en lugar de filtrar client-side con `filtrarPorDias`, así el limit de 250 no corta el rango elegido.

### Ideas de features que esta área habilita

- Exportar el registro de jornada v3 de un chofer como PDF o CSV directamente desde AdminRegistroJornadaScreen: los datos (manejo neto, pausas, bloques, flags) ya están precomputados y son ideales para un informe de compliance semanal/mensual que hoy se hace manualmente.
- Agregar un heat-map calendario en AdminRegistroJornadaScreen: una grilla mensual donde cada celda (día) se colorea por nivel de riesgo (jornada excedida rojo, bloque excedido naranja, normal verde, sin actividad gris). Con los docs de REGISTRO_JORNADAS ya disponibles, el render es client-side sin queries extra.
- Pestaña 'Comparar choferes' en jornada histórica: dado que el servicio ya soporta rangos arbitrarios, una vista side-by-side de dos choferes en el mismo período permitiría detectar diferencias de patrón (uno siempre manejando de noche, otro con pausas cortas crónicas).
- Alerta proactiva desde el dashboard del agente: si `tasaExitoPct` cae debajo del umbral de warning (85%) en el rango de 24h, mostrar un badge rojo en la entrada del menú admin 'Agente IA', similar al patrón de alertas Volvo. Los datos ya están en el stream.
- En la bandeja de ambiguos (AdminBotBandejaScreen), agregar preview de la imagen adjunta inline (thumbnail 76px ya existe) con un tap que abra el visor nativo en lugar de requerir ir a AppFileThumbnail — facilitaría procesar la bandeja en móvil.
- Vista de 'top choferes por horas de manejo' sobre REGISTRO_JORNADAS: el admin hoy tiene que revisar chofer por chofer para comparar. Una query de los últimos 7/30 días con sum(manejoNetoSeg) agrupada por choferDni (calculable client-side sobre los docs ya cargados para la flota de 50) daría ranking directo de riesgo.

### Deuda técnica

- jornada_dia.dart (v2 historico) y registro_jornada.dart (v3) son modelos paralelos para datos muy similares (tramos, paradas, serie velocidad, KPIs de manejo). A medida que v3 gane adopción completa, considerar deprecar formalmente la colección VOLVO_JORNADAS_HISTORICO y consolidar en REGISTRO_JORNADAS para eliminar la duplicación de servicios, modelos y pantallas.
- Los helpers de formateo de hora/fecha (_hm, _hmDur, _fmtHoraCorta, _fmtHoraSegun, _fmtFechaLarga) están duplicados entre jornada_dia_screen.dart, registro_jornada_detalle_screen.dart y registro_jornada_card.dart. Deberían consolidarse en AppFormatters o en un archivo de helpers compartido de jornadas.
- El selector de chofer (bottom sheet con buscador) está copiado en AdminRegistroJornadaScreen y JornadaDiaScreen con ~100 LOC de diferencia mínima. Extraer a widget compartido.
- AgenteConversacionesService.filtrarPorDias usa DateTime.now() para el corte temporal, lo que hace que el límite del rango cambie silenciosamente con el tiempo en una sesión larga. Si el admin tiene la pantalla abierta varios minutos, chats que entraban en '7 días' hace un rato pueden desaparecer. Considerar capturar el timestamp de inicio del stream y usarlo como referencia fija.
- Las callables HTTPS (procesarJornadaHoyChofer y procesarJornadaHoyChoferV3) están hardcodeadas a 'us-central1'. Si Firebase migra o se añade una segunda región, hay que cambiar en dos lugares. Centralizar la URL base en AppConstants.


## paneles-admin — 22 archivos leídos

El área paneles-admin cubre autenticación, navegación del shell admin, dashboard en vivo, gestión de bot/WhatsApp, vista ejecutiva, administración RRHH (vacaciones, discrepancias) y la home multi-rol. El estado general es sólido: la arquitectura RBAC está bien aplicada, los streams tienen dispose() correcto en casi todos los casos, y el código de cálculos de dinero y liquidación está fuera de este módulo. Se encontraron dos bugs de media severidad en admin_shell.dart (StreamController que se filtra y mutación de estado en build) y un bug de media severidad de UX en la pantalla de vacaciones (año por defecto hardcodeado). Los problemas de TZ son de baja severidad porque en producción los dispositivos están configurados en ART. La deuda técnica más llamativa es el archivo de 2232 líneas admin_estado_bot_widgets.dart.

### Mejoras

| Mejora | Categoría | Impacto | Esfuerzo |
|---|---|---|---|
| Refactorizar _IconoMas a StatefulWidget | robustez | medio | bajo |
| Limitar query de VOLVO_ALERTAS con .limit() server-side antes de paginar en cliente | rendimiento | medio | bajo |
| Dividir admin_estado_bot_widgets.dart (2232 líneas) en módulos temáticos | mantenibilidad | medio | medio |
| Normalizar cálculos de 'días hasta vencimiento' a ART con DateUtils.dateOnly | robustez | bajo | bajo |
| Mostrar feedback explicativo cuando SUPERVISOR intenta operar el kill-switch | ux | bajo | bajo |
| Cache del FutureBuilder de vista ejecutiva con AutomaticKeepAliveClientMixin | rendimiento | bajo | bajo |
| Paginación server-side en _svc.stream() de ReportesDiscrepanciaScreen | escalabilidad | bajo | medio |

- **Refactorizar _IconoMas a StatefulWidget:** Mover el StreamController y las suscripciones de Revisiones+Mantenimiento a initState()/dispose() de un StatefulWidget. Esto elimina el leak y hace el código más idiomático Flutter. La lógica del stream ya está bien encapsulada en _hayPendientes(); solo hay que moverla al ciclo de vida correcto.
- **Limitar query de VOLVO_ALERTAS con .limit() server-side antes de paginar en cliente:** admin_volvo_alertas_screen.dart descarga todos los docs del rango de fechas seleccionado y luego pagina en cliente (30/página). Para un día con muchas alertas (varios vehículos Volvo con múltiples eventos) esto puede ser cientos de documentos en una sola lectura. Agregar .limit(300) o similar al query base, y mostrar un aviso de 'mostrando primeros N resultados' si se alcanza el límite. Esto ahorra lecturas de Firestore y reduce tiempo de carga.
- **Dividir admin_estado_bot_widgets.dart (2232 líneas) en módulos temáticos:** El archivo contiene widgets muy distintos: dashboard general, kill-switch, cierre de reclamos, pausa de canales, sparkline de mensajes enviados, historial de conversaciones. Extraer cada sección a su propio archivo en lib/features/admin_dashboard/widgets/bot/ sigue el patrón ya aplicado en el split de functions/index.ts. Mejora navegabilidad y tiempo de análisis de compilación incremental.
- **Normalizar cálculos de 'días hasta vencimiento' a ART con DateUtils.dateOnly:** Crear un helper centralizado en AppFormatters o una extensión de DateTime que reciba un Timestamp, lo convierta a ART (tz package, America/Argentina/Buenos_Aires) y devuelva solo la fecha. Usar ese helper en _LineaEstado, _TileVencimientos y cualquier otro lugar donde se calcule diferencia de días con Timestamps de Firestore. Esto asegura consistencia en dispositivos con zona incorrecta o en tests.
- **Mostrar feedback explicativo cuando SUPERVISOR intenta operar el kill-switch:** En _ToggleKillSwitch, verificar el rol del usuario antes de mostrar el control o agregar un guard que muestre un mensaje 'Solo ADMIN puede cambiar este parámetro' en lugar del error de Firestore. Alternativamente, ocultar el toggle para SUPERVISOR usando Capabilities.can() en el build del widget, consistente con el patrón usado en el resto del panel.
- **Cache del FutureBuilder de vista ejecutiva con AutomaticKeepAliveClientMixin:** VistaEjecutivaService.cargar() lanza 4 queries en paralelo cada vez que la tab de vista ejecutiva entra en foco (la pantalla se reconstruye al navegar por el shell). Agregar AutomaticKeepAliveClientMixin en la pantalla de vista ejecutiva o mantener el Future en el estado del shell evita re-fetches innecesarios en navegación frecuente.
- **Paginación server-side en _svc.stream() de ReportesDiscrepanciaScreen:** El stream de RECLAMOS_DISCREPANCIA descarga todos los documentos sin límite. Si en el tiempo crece a cientos de registros (muchos choferes reclamando), el tiempo de carga y el costo de lecturas aumenta linealmente. Agregar un .limit(100) al stream y un botón 'cargar más' o paginación por cursor para el historial.

### Ideas de features que esta área habilita

- El dashboard de bot (admin_estado_bot_screen.dart) ya tiene sparkline de mensajes enviados y estado de salud. Con el historial de WHATSAPP_HISTORICO disponible se podría agregar un heatmap semanal por chofer (quién interactúa más, quién nunca abre el bot) para detectar choferes que no adoptan el canal.
- La pantalla de discrepancias (_revisar) permite al revisor anotar 'cierto / no coincide'. Agregar un tercer estado 'escalado' con campo de destinatario habilitaría un flujo de ticket liviano: el revisor escala discrepancias que requieren corrección en Sitrack o en el back-end, con notificación WhatsApp al responsable.
- VacacionesCalendarioScreen tiene una vista Gantt por mes. Extender el rango a 'vista anual' (12 meses en scroll horizontal) permitiría al admin ver solapamientos de vacaciones entre choferes en un vistazo, útil para planificación de cobertura operativa.
- La vista ejecutiva ya calcula eficiencia de combustible (L/100km actual vs anterior). Cruzar ese dato con el ranking ICM por chofer permitiría identificar si los choferes con peor ICM también tienen peor consumo, habilitando una conversación de coaching basada en datos duros.
- El kill-switch del bot tiene historial de cambios (auditLog implícito por los writes a BOT_CONTROL/main). Mostrar en la pantalla de estado del bot un log de los últimos 5 activaciones/desactivaciones con timestamp y usuario que lo hizo daría trazabilidad operativa inmediata.

### Deuda técnica

- admin_estado_bot_widgets.dart tiene 2232 líneas con 6+ responsabilidades distintas — candidato #1 a split temático por módulo.
- _currentIndex mutable directo en admin_shell.dart build() es un antipatrón Flutter que el linter no atrapa porque no usa setState; debe resolverse antes de migrar a Flutter 4.x donde los asserts de build() se endurecen.
- La pantalla AdminVacacionesScreen y VacacionesCalendarioScreen duplican la lógica de carga de empleados (StreamBuilder<List<Empleado>> vs FutureBuilder) sin compartir un repositorio común; unificar en un EmployeeRepository reduciría la divergencia de exclusión de tanqueros.
- main_panel.dart contiene lógica de negocio de 'estado de documento' (_resolverEstado, _resumirProximos) inline en el widget; debería vivir en un service o en el modelo DocumentoLaboral para ser testeable en aislamiento.
- Los FutureBuilder en admin_destinatarios_notificacion_screen.dart y admin_vacaciones_screen.dart no tienen mecanismo de retry explícito ante errores de red — muestran el error pero el usuario debe salir y volver a entrar para reintentar.
- No hay tests de widget ni de integración para ninguna pantalla de este módulo; la lógica de cálculo de días (vencimientos, vacaciones LCT) solo se puede testear actualmente en producción.


## mapa-zonas-cachatore-ui — 16 archivos leídos

El área cubre tres módulos: (1) mapa de flota en vivo (SITRACK_POSICIONES + recorrido histórico SITRACK_EVENTOS), (2) ABM de geocercas de descarga YPF (círculo/polígono) con su pantalla de cola en vivo e histórico, y (3) la UI del sniper de turnos YPF "cachatore" (objetivos, estado del bot, wizard de alta/reagendar). El código es en general sólido: el stream del mapa está correctamente cacheado en initState, los recursos (MapController, ScrollController, Timer, StreamSubscription) se liberan en dispose, las queries Firestore tienen índices compuestos declarados, y los estados de carga/error están bien manejados. Se encontró un bug real de parseo en la entrada de vértices del polígono, un stream sin límite defensivo en el histórico de descargas, y algunas deudas técnicas menores. No hay cálculos de plata, races sobre transacciones, ni fugas de contexto graves.

### Mejoras

| Mejora | Categoría | Impacto | Esfuerzo |
|---|---|---|---|
| Reemplazar stream por get() one-shot en _DescargasDelRango | rendimiento | medio | bajo |
| Normalizar unicode minus en _parsearVertices | robustez | alto | bajo |
| Separar el stream de cola en vivo del histórico en _DescargasDelRango | rendimiento | bajo | bajo |
| Reemplazar AppColors.surface2 hardcoded por context.colors.surface2 en bottomSheets del cachatore | mantenibilidad | bajo | bajo |
| Limite de 5000 puntos en RecorridoService trunca el extremo MÁS NUEVO del rango | ux | medio | medio |
| Índice de SITRACK_EVENTOS faltante avisa error poco descriptivo al usuario | ux | bajo | bajo |
| El modo rango del recorrido histórico no valida que 'hasta' no esté en el futuro | ux | bajo | bajo |
| La sección 'Zonas' en _SelectorZona muestra estadiaMinMin como 'count' del chip | ux | bajo | bajo |

- **Reemplazar stream por get() one-shot en _DescargasDelRango:** Convertir `_DescargasDelRango` de `StatelessWidget` a `StatefulWidget` con el mismo patrón que `_KpisZona`: Future cacheado en `initState` + `didUpdateWidget` que lo recalcula cuando `slug`, `desde` o `hasta` cambian. Eliminar `.snapshots()` y reemplazar por `.get()` one-shot con el mismo límite de 500. Agregar un botón 'Actualizar' o un pull-to-refresh. Ahorra lecturas de Firestore y elimina rebuilds constantes cuando cambian docs del rango.
- **Normalizar unicode minus en _parsearVertices:** Antes de llamar a `double.tryParse`, agregar `.replaceAll('−', '-')` sobre cada parte (o sobre la línea completa antes de splitear). Esto cubre el carácter U+2212 que usan Google Maps y muchos sistemas de coordenadas. También conviene mostrar un SnackBar de advertencia si alguna línea tenía 2+ tokens pero lat o lng resultó null, para que el operador sepa que el punto fue ignorado.
- **Separar el stream de cola en vivo del histórico en _DescargasDelRango:** Actualmente el StreamBuilder de la cola en vivo (sin límite, siempre 'ahora') está anidado dentro del builder del stream de zonas, lo que causa que el header Hero y la sección KPIs se rebuilden cada vez que la cola cambia. Extraer el stream de cola a su propio StreamBuilder raíz separado (manteniendo el patrón actual) o memoizar la cola con un stream cacheado en `initState` como se hizo en el mapa de flota.
- **Reemplazar AppColors.surface2 hardcoded por context.colors.surface2 en bottomSheets del cachatore:** En `_abrirWizard` (línea 883) y `_abrirMenu` (línea 763) se usa `AppColors.surface2` static const como `backgroundColor` del `showModalBottomSheet`. Esto ignora el tema dinámico. Cambiar a `context.colors.surface2` usando el mismo patrón del resto de la app. Aplicar también a los `AlertDialog` que usan `AppColors.surface2` directamente.
- **Limite de 5000 puntos en RecorridoService trunca el extremo MÁS NUEVO del rango:** Con `orderBy('report_date')` ascendente y `limit(5000)`, si el rango tiene más de 5000 eventos se pierden los eventos MÁS RECIENTES (los del final del rango). Esto invierte la intuición del usuario: pide 'últimas 48h' y no ve el final del recorrido. La solución es documentar más claramente este comportamiento en la UI (ej. 'Mostrando los primeros 5000 puntos del rango') o cambiar a un enfoque paginado que priorice los últimos eventos.
- **Índice de SITRACK_EVENTOS faltante avisa error poco descriptivo al usuario:** En `_cargarRecorrido` el catch detecta `failed-precondition` y muestra 'El índice del recorrido se está creando'. Sin embargo, al mismo tiempo el `_recorrido` y `_recorridoPatente` NO se limpiaron (pueden quedar con datos de un pedido anterior). Agregar `setState(() => _limpiarRecorridoState())` antes de mostrar el SnackBar de error para que el mapa no quede mostrando un recorrido stale de otra patente.
- **El modo rango del recorrido histórico no valida que 'hasta' no esté en el futuro:** En `_WizardSheetState._elegir` para la sección de recorrido, `lastDate: DateTime.now()` del DatePicker evita fechas futuras, pero el `showTimePicker` no tiene esta restricción. Si el usuario elige HOY como fecha de fin y una hora futura como hora de fin, la query incluye un rango que termina en el futuro, lo cual es técnicamente válido pero confuso. Agregar una validación: si la fecha elegida es hoy y la hora elegida es futura, limitar `_hasta` a `DateTime.now()`.
- **La sección 'Zonas' en _SelectorZona muestra estadiaMinMin como 'count' del chip:** En `_SelectorZona`, `AppFilterChip(count: z.estadiaMinMin)` muestra la estadía mínima en minutos como el contador del chip. Eso confunde: el usuario ve '5' al lado del nombre de la zona y no entiende qué significa. Cambiar a `count: null` y mostrar la estadía como subtítulo o tooltip.

### Ideas de features que esta área habilita

- Recorrido histórico con color por velocidad: en el PolylineLayer del mapa de flota, segmentar la polyline por rangos de velocidad (verde < 60 km/h, naranja 60-90, rojo > 90) usando los datos de `velocidad` que ya tiene `PuntoRecorrido`. El dato ya está disponible sin ninguna query adicional.
- Heatmap de actividad en geocercas: dado que ZONA_DESCARGA_HISTORICO acumula todas las entradas/salidas con timestamp y patente, se podría agregar una vista de 'actividad por hora del día' (histograma) que muestre en qué franjas horarias se concentran las descargas. Útil para planificar despacho.
- Alerta de unidad detenida demasiado tiempo en zona: si una unidad lleva más de N minutos en la cola de descarga sin salir, emitir una alerta push al admin (ya existe el canal de alertas WhatsApp). El dato de `minDentro` ya se calcula en `_FilaCola`.
- Exportar recorrido histórico a GPX/KML: el `RecorridoService` ya devuelve lat/lng/fecha/velocidad para un rango — con un botón 'Exportar' se podría generar un archivo descargable desde la pantalla del mapa.
- Dashboard de cobertura del cachatore: mostrar cuántos choferes del total habilitado (colección EMPLEADOS/ROL=CHOFER) están en el cachatore vs. cuántos no. El stream de empleados ya se usa en el paso 0 del wizard.

### Deuda técnica

- lib/features/cachatore/screens/cachatore_hub_screen.dart: los `showModalBottomSheet` y `AlertDialog` usan `AppColors.surface2` y `AppColors.textSecondary` como constantes estáticas en vez de tokens del tema (context.colors). Afecta a _abrirWizard, _abrirMenu, _NotaFalla y varios ListTiles.
- lib/features/fleet_map/screens/admin_mapa_flota_screen.dart línea 267: el check `if (!mounted) return -1` en el catch de `_cargarRecorrido` debe preceder al uso del messenger, no seguirlo. Actualmente puede mostrar un SnackBar tras desmonte (inofensivo pero incorrecto).
- lib/features/zonas_descarga/screens/admin_descargas_screen.dart: `_DescargasDelRango` como StreamBuilder permanente es inconsistente con el patrón one-shot de `_KpisZona` (corregido en auditoría previa). Unificar al mismo patrón para reducir lecturas Firestore.
- lib/features/cachatore/screens/cachatore_hub_screen.dart: `_CabeceraEstado` anida 3 StreamBuilders (estado, objetivos, turnos) lo que crea 3 suscripciones Firestore independientes. Idealmente se combinarían con `Rx.combineLatest3` o un único provider para mantener consistencia, aunque con ~50 choferes el impacto es bajo.
- lib/features/zonas_descarga/screens/admin_zonas_descarga_screen.dart: el mapa editor (`_MapaEditor`) en el form de zona no tiene `onMapReady` equivalente al del mapa de flota; si los datos del centro llegan antes de que el mapa esté listo, los tiles pueden quedar grises hasta mover a mano.
- lib/features/fleet_map/screens/admin_mapa_flota_screen.dart: `RecorridoService` es una clase con solo métodos estáticos y un constructor privado `._()` — podría ser simplemente un conjunto de top-level functions, o una clase instanciable para facilitar el testing.


## nucleo-core — 32 archivos leídos

El área nucleo-core es la más sólida y mejor documentada del proyecto. La base de arranque (main.dart) tiene una arquitectura de inits defensivos bien pensada: initSeguro envuelve cada servicio en try/catch, Sentry tiene filtros anti-noise multicapa, Firebase usa workarounds documentados para Windows, y el AuthGuard implementa correctamente el grace period para evitar el race condition del startup en Windows. AppFormatters es correcto para los casos de uso habituales, con el bug histórico del carry UTC-vs-local ya fixeado. Las capabilities RBAC están bien modeladas con herencia limpia. No hay runTransaction en código cliente. El principal hallazgo real (media) es que el StreamSubscription de NotificationService en _LogisticaAppState.initState nunca se cancela, lo que puede generar comportamiento anómalo al cerrar el controller. El resto son mejoras y deuda técnica de baja prioridad.

### Mejoras

| Mejora | Categoría | Impacto | Esfuerzo |
|---|---|---|---|
| Guardar y cancelar el StreamSubscription de notificaciones en _LogisticaAppState | robustez | medio | bajo |
| Convertir RoleGuard a StatefulWidget para estabilizar los Futures del FutureBuilder | robustez | bajo | bajo |
| StorageService: agregar timeout al getDownloadURL | robustez | bajo | bajo |
| Conectar AppLogger con Sentry en plataformas sin Crashlytics (Windows/Web) | mantenibilidad | medio | bajo |
| Extraer _Version a un archivo compartido entre los dos update services | mantenibilidad | bajo | bajo |
| Agregar soporte defensivo de Timestamp a _parseUniversalDate | robustez | bajo | bajo |
| Centralizar appVersion leyendo de PackageInfo en vez de hardcodear el string | mantenibilidad | bajo | bajo |
| Grace period de AuthGuard diferenciado por plataforma | ux | bajo | bajo |

- **Guardar y cancelar el StreamSubscription de notificaciones en _LogisticaAppState:** En lib/main.dart declarar 'StreamSubscription<String?>? _notifSub;', asignar el resultado de .listen() en initState, y cancelarlo en dispose(). NotificationService.dispose() puede seguir llamandose también para cerrar el controller.
- **Convertir RoleGuard a StatefulWidget para estabilizar los Futures del FutureBuilder:** Mover la creación de user.getIdTokenResult() y la query de Firestore a variables de estado inicializadas en initState(). Así FutureBuilder siempre ve el mismo Future y no provoca rebuilds espurios ni flashes del spinner en pantallas con animaciones.
- **StorageService: agregar timeout al getDownloadURL:** En lib/core/services/storage_service.dart, el .timeout(30s) solo protege el putData. El getDownloadURL posterior no tiene timeout: si Firebase acepta el upload pero la red cae justo antes, la función puede colgar indefinidamente. Agregar .timeout(const Duration(seconds: 10)) al getDownloadURL.
- **Conectar AppLogger con Sentry en plataformas sin Crashlytics (Windows/Web):** En lib/core/services/app_logger.dart, cuando _crashlyticsDisponible == false, los errores solo van a debugPrint que es silencioso en release. Sentry ya está inicializado en main.dart para todas las plataformas. Agregar una llamada a Sentry.captureException(error, stackTrace: stack) en recordError() cuando !_crashlyticsDisponible, para que los crashes de Windows desktop lleguen al dashboard.
- **Extraer _Version a un archivo compartido entre los dos update services:** La clase _Version está duplicada prácticamente idéntica en lib/core/services/windows_update_service.dart y lib/core/services/android_update_service.dart. Extraerla a lib/core/services/version_comparator.dart reduce el riesgo de divergencia silenciosa si se cambia el formato del tag de release.
- **Agregar soporte defensivo de Timestamp a _parseUniversalDate:** En lib/shared/utils/formatters.dart, agregar 'if (fecha is Timestamp) return fecha.toDate();' como primer case después del null-check. Costo: una importación y una línea. Blinda contra cualquier campo de fecha que llegue como Timestamp por error de la console de Firebase o una migración futura.
- **Centralizar appVersion leyendo de PackageInfo en vez de hardcodear el string:** AppTexts.appVersion = 'v 1.2.33' (app_constants.dart línea 154) debe actualizarse manualmente en cada release y puede quedar desincronizado. Reemplazarlo por una lectura en runtime de PackageInfo.fromPlatform() (ya usado en Sentry y WindowsUpdateService), cacheada en un FutureProvider o en PrefsService.init(). Esto elimina la deuda de actualizar el string.
- **Grace period de AuthGuard diferenciado por plataforma:** El grace period de 1500ms está hardcodeado en lib/shared/widgets/guards/auth_guard.dart. En iOS/Android la restauración de sesión suele ser <200ms; en Windows puede llegar a 1500ms. Con un valor de 500ms en móvil el chofer vería el spinner de forma mucho más breve. Implementación: 'final graceDuration = Platform.isWindows ? 1500 : 500;'

### Ideas de features que esta área habilita

- Pantalla de diagnóstico de permisos: dado que el RBAC ya está completamente modelado en Capabilities, una pantalla de solo lectura 'Mis permisos' (accesible desde el menú admin) podría mostrar qué capabilities tiene el usuario logueado. Útil cuando se introduce un rol nuevo y el admin necesita verificar que las capabilities están correctas antes de darle acceso a alguien.
- Notificaciones push para cambios de rol: el ciclo de verificación de sesión revocada (cada 30 min en AuthGuard + al resume) ya detecta revocaciones. Se podría complementar enviando una FCM push específica al device cuando el admin cambia el rol de un empleado, para que el guard revalide inmediatamente en vez de esperar hasta 30 min.
- Métricas de arranque: el bootstrap de main.dart tarda un tiempo que no se mide. Instrumentar con DateTime.now() antes/después de cada initSeguro y enviar como Sentry breadcrumbs daría datos reales de cuánto tarda la app en cada plataforma sin costo de implementación significativo.
- Exportar lista de capabilities por rol desde la app: dado que Capabilities._resolved ya tiene toda la matriz en memoria, un endpoint admin-only (o una sección de depuración) que serialice esa matriz a JSON permitiría auditar externamente qué puede hacer cada rol sin tener que leer el código.

### Deuda técnica

- lib/core/theme/platform_chrome.dart contiene una clase DesktopWindow vacía (líneas 102-104) que es dead code: solo tiene un constructor privado, quedó como placeholder del refactor Núcleo sin uso.
- Las rutas legacy adminVolvoAlertas y adminEcoDriving (app_router.dart líneas 323-341) siguen presentes sin fecha de remoción, marcadas como 'mantener por compat unos releases' desde 2026-05-15.
- AppTexts.appVersion = 'v 1.2.33' (app_constants.dart línea 154) queda desincronizado del semver real del pubspec y debe actualizarse manualmente en cada release.
- Los comentarios del helper PowerShell embebido en windows_update_service.dart (líneas 351-556) contienen acentos y ñ aunque el encabezado del script dice 'ASCII puro'. Si alguna vez se extrae y ejecuta directamente como .ps1 con encoding incorrecto puede fallar.
- La colección AppCollections.volvoJornadasHistorico está nombrada 'VOLVO_JORNADAS_HISTORICO' (app_constants.dart línea 481) pero su contenido viene de SITRACK_EVENTOS (Sitrack GPS), no de Volvo Connect, lo cual es confuso al buscar la fuente de datos.
- ExcluidosService y ChoferesService usan estado estático de clase para el caché. En tests paralelos o con reinits de Firebase estos caches no se invalidan automáticamente. El resetCacheParaTests() mitiga esto pero requiere que cada test lo llame explícitamente.


## nucleo-shared — 47 archivos leídos

lib/shared/ es el design system y la capa de utilidades compartidas de la app. Cubre ~47 archivos: widgets Núcleo (AppScaffold, AppCard, AppButton, AppStat, AppDataTable, AppDetailSheet, AppFilterChip, AppBadge, AppServiceCard, AppMapMarker, skeletons, estados vacíos/error/carga, guards de auth y rol), formatters AR (miles, montos, fechas, DNI, CUIL, teléfono), helpers (OCR, PDF printer, hashing bcrypt+sha256, responsive grid) y constantes (colores, mapa). Estado general: muy saludable. La capa está bien abstraída, con retrocompat cuidada, buena gestión de ciclo de vida en la mayoría de los widgets, y cobertura de casos borde (TZ, cursor en formatters, etc.). Hay un par de contratos frágiles detectados y deuda por la duplicación de DatoEditable* en el feature de Personal que la propia codebase reconoce pero aún no consolidó.

### Mejoras

| Mejora | Categoría | Impacto | Esfuerzo |
|---|---|---|---|
| Consolidar las clases privadas _DatoEditableTexto/_DatoEditableEnum de admin_personal_lista_widgets | mantenibilidad | bajo | bajo |
| Exportar dato_editable.dart y fecha_dialog.dart desde app_widgets.dart | mantenibilidad | bajo | bajo |
| Documentar contrato de AppListPage: stream sin paginación solo es seguro para colecciones acotadas | robustez | medio | bajo |
| AppDetailSheet: exponer un factory .showWithScroll que recibe directamente un Widget (sin ScrollController) | ux | medio | bajo |
| AppConfirmDialog: agregar validación assert al call-site de contenido custom | robustez | bajo | bajo |
| RoleGuard: convertir a StatefulWidget para cachear los Futures | rendimiento | medio | bajo |
| AppSparkline: usar listEquals para shouldRepaint | rendimiento | bajo | bajo |
| CuitInputFormatter: cursor siempre al final impide edición intermedia | ux | bajo | medio |

- **Consolidar las clases privadas _DatoEditableTexto/_DatoEditableEnum de admin_personal_lista_widgets:** lib/features/employees/screens/admin_personal_lista_widgets.dart (líneas 563 y 739) tiene copias privadas de DatoEditableTexto y DatoEditableEnum que vivieron antes de que se creara el shared. El comentario en dato_editable.dart ya documenta la deuda. Migrar esos call-sites a los widgets públicos de lib/shared/widgets/dato_editable.dart y eliminar las copias. No hay diferencias de comportamiento que impidan el drop-in.
- **Exportar dato_editable.dart y fecha_dialog.dart desde app_widgets.dart:** El barrel file lib/shared/widgets/app_widgets.dart no exporta dato_editable.dart (DatoEditableTexto/Miles/Enum/EnumExtensible) ni fecha_dialog.dart (pickFecha). Los callers tienen que importarlos manualmente por path. Agregar ambos al barrel para que el patrón de importación sea uniforme con el resto del design system.
- **Documentar contrato de AppListPage: stream sin paginación solo es seguro para colecciones acotadas:** AppListPage descarga todos los docs del QuerySnapshot en memoria y los filtra en cliente (línea 117-129). Es correcto para colecciones de tamaño fijo (EMPLEADOS ~60, VEHICULOS ~30), pero si alguien lo reutiliza para SITRACK_EVENTOS o LOGISTICA_VIAJES (colecciones que crecen ilimitado) el filtro en cliente se convierte en una descarga masiva. Agregar un comentario docstring explícito advirtiendo que NO es apto para colecciones >500 documentos, y considerar un parámetro `maxItems` como guard.
- **AppDetailSheet: exponer un factory .showWithScroll que recibe directamente un Widget (sin ScrollController):** El contrato actual de AppDetailSheet.show() obliga al caller a aceptar el ScrollController y asignarlo al ListView. 35 call-sites de showModalBottomSheet en features que no usan AppDetailSheet indican que muchos callers prefieren pasar solo el contenido. Agregar AppDetailSheet.showSimple(context, title, child) que internamente envuelve en SingleChildScrollView con el scrollController del DraggableScrollableSheet. Reduce la fricción de adopción.
- **AppConfirmDialog: agregar validación assert al call-site de contenido custom:** La validación `assert(message != null || content != null)` solo corre en debug. En release si ambos son null, `message!` en línea 91 lanza un LateInitializationError/NPE en prod. Cambiar el widget a requerir exactamente uno de los dos con un parámetro union o validar y devolver gracefully.
- **RoleGuard: convertir a StatefulWidget para cachear los Futures:** Mover la creación de los dos FutureBuilder futures (getIdTokenResult y el .get() de Firestore) a initState/didUpdateWidget de un StatefulWidget. Así el FutureBuilder nunca recrea el Future en rebuilds del padre, eliminando lecturas Firestore repetidas. El guard debería re-evaluar solo si cambia el user de Firebase Auth, lo que se puede detectar con un StreamSubscription a authStateChanges en initState.
- **AppSparkline: usar listEquals para shouldRepaint:** En _SparkPainter.shouldRepaint (app_stat.dart línea 201), reemplazar `old.data != data` por `!listEquals(old.data, data)` (de foundation.dart). Previene repaints innecesarios cuando el caller pasa listas literals iguales en cada build.
- **CuitInputFormatter: cursor siempre al final impide edición intermedia:** CuitInputFormatter.formatEditUpdate siempre posiciona el cursor al final (comentado como intencional). Esto es un friction point si el admin quiere corregir dígitos intermedios de un CUIL ya cargado (por ejemplo, cambiar el dígito verificador). Implementar la misma estrategia de cursor por conteo de dígitos que ya tienen FechaInputFormatter y _MilesInputFormatter.

### Ideas de features que esta área habilita

- DatoEditableFecha: agregar una variante del patrón DatoEditable* específica para fechas, que internamente use pickFecha() y muestre el valor formateado con AppFormatters.formatearFecha. Hoy todos los campos de fecha editables en las fichas tienen su propia lógica ad-hoc; este widget centralizaría el patrón.
- AppListPage con paginación cursor-based: agregar un modo `paginated: true` que cargue los primeros N docs y ofrezca un botón 'cargar más' usando startAfterDocument. Habilita adoptar AppListPage también en LOGISTICA_VIAJES y SITRACK_EVENTOS sin riesgo de descarga masiva.
- AppDataTable con ordenamiento por columna: el widget ya tiene la estructura de columnas bien definida. Agregar `sortColumn`/`sortAscending` opcionales y un callback `onSort` que el caller pueda usar para reordenar los datos. El header de columna mostraría un ícono de flecha. Altamente útil en reportes de ICM, liquidaciones y jornadas.
- AppServiceCard con LiveBadge animado: agregar a _StatusPill una animación de pulso (AnimationController repeat) cuando `status.glow == true` (estado OK de un servicio live). El dot verde del bot o de Sitrack 'respiraria' visualmente, dando feedback de actividad en tiempo real sin polling adicional.
- AppFilterChip con badge de conteo animado: cuando `count` cambia (por stream update), animar el número con un pequeño fade-in/scale para que el admin vea que la lista se actualizó sin tener que leer el número completo. El AppFilterChip ya expone `count` como parámetro, solo hay que envolver el Text en AnimatedSwitcher.

### Deuda técnica

- Las clases privadas _DatoEditableTexto y _DatoEditableEnum en lib/features/employees/screens/admin_personal_lista_widgets.dart son duplicados del shared que no se consolidaron todavía (reconocido en el docstring de dato_editable.dart). Eliminar cuando se valide que el shared es drop-in.
- app_widgets.dart no exporta dato_editable.dart ni fecha_dialog.dart, obligando a imports por path en los call-sites.
- MenuCard (lib/shared/widgets/menu_card.dart) no usa el design system Núcleo (no usa AppCard, AppColors via context.colors, ni AppType): tiene sus propios colores hardcodeados y border radius fijo. Candidato a migrar al refactor visual Núcleo.
- AppCard tiene 5 parámetros de compat 2026-05-24 (margin, borderColor, highlighted, tier, borderRadius). El shim está bien documentado pero acumula superficie de API. Limpiar cuando los call-sites estén migrados.
- AppButton tiene dos sets de parámetros en paralelo (kind/variant, full/expand, loading/isLoading) por retrocompat. Idem: limpiar cuando los ~259 call-sites migren.
- formatearKilometraje (lib/shared/utils/formatters.dart:14) es una función legacy distinta de formatearMiles que usa otra estrategia interna. Unificar o documentar explícitamente por qué coexisten (el primer formato termina en coma decimal, el segundo no).
- AppLoadingDialog.hide() llama navigator.canPop() antes de pop(), lo que es correcto, pero si el dialog fue cerrado por otro medio (ej. el usuario apretó Back) el canPop() devuelve true para otra ruta y popea la pantalla incorrecta. Solución robusta: usar un GlobalKey para el dialog o una variable booleana interna.


## fx-jornadas — 8 archivos leídos

El área de jornadas es el núcleo de seguridad del sistema: el v2 avisa en vivo y alimenta flags de infracciones al supervisor, el v3 genera el registro auditaable a posteriori, y el cron cierre_reportes_jornada (activado hace 2 días y con primera corrida hoy) cierra reclamos automáticamente contra el GPS. El código es maduro, muy bien comentado y con lógica pura extensamente testeable. Los flujos críticos (tick v2, reconstrucción v3, resúmenes diarios) tienen guards, idempotencia y fail-safes sólidos. Se identificaron 5 bugs reales: uno crítico (cierreActivo falla silencioso), dos altos (calculo incorrecto de fechaAyer para el resumen a Molina, falta de idempotencia en cerrarReportesJornadaDiario), y dos medios (boundary GPS truncado a 23:59:59, ventana de reciencia usada con timestamp de reclamos antiguos). La deuda técnica principal es que el batch v3 está dormido y el resumen de Molina usa v3 sin verificar que el batch corrió.

### Mejoras

| Mejora | Categoría | Impacto | Esfuerzo |
|---|---|---|---|
| Guard: verificar que el batch v3 corrió antes de armar el resumen a Molina | robustez | alto | bajo |
| Usar medianoche ART explícita en armarResumenJornadasV3Diario para calcular 'ayer' | robustez | medio | bajo |
| Agregar idempotencia diaria a cerrarReportesJornadaDiario | robustez | alto | bajo |
| Corregir boundary de eventosGpsDelDia a medianoche del día siguiente | robustez | medio | bajo |
| Paginación defensiva en la query de reclamos pendientes del cron de cierre | escalabilidad | medio | bajo |
| procesarVentanaUnChofer lee TODOS los eventos del día antes de filtrar por DNI | rendimiento | medio | medio |
| Limitar la ventana de 'reciencia' en v3ConfirmaPausa a reclamos recientes | robustez | medio | bajo |
| El cron cerrarReportesJornadaDiario no tiene timeoutSeconds definido | robustez | alto | bajo |

- **Guard: verificar que el batch v3 corrió antes de armar el resumen a Molina:** armarResumenJornadasV3Diario (jornadas_v3_batch.ts:603) lee REGISTRO_JORNADAS para 'ayer'. Si el cron registrarJornadasV3Diario falló o el flag batchActivo estaba off, la colección está vacía y el resumen dice 'Sin incidencias' — falso positivo para Molina. Agregar un check: si snap.empty Y batchActivo es false, encolar un mensaje de advertencia 'Registro v3 de ayer no disponible (batch apagado) — datos de infracciones no procesados'. Esto evita que Molina piense que todos los choferes cumplieron cuando en realidad el sistema no corrió.
- **Usar medianoche ART explícita en armarResumenJornadasV3Diario para calcular 'ayer':** Reemplazar `fechaArt(Date.now() - 24 * 60 * 60 * 1000)` por el mismo patrón usado en jornadas_v2 (línea 1750-1754): calcular la fecha ART de ahora, restar 1 día, parsear con offset -03:00 explícito. Esto hace el cálculo robusto ante retardos del cron y consistente con el resto del codebase.
- **Agregar idempotencia diaria a cerrarReportesJornadaDiario:** Agregar adquirirIdempotenciaDiaria + liberarLockConReintentos al cron cerrarReportesJornadaDiario, con docId 'cierre_reportes_jornada_{hoyKey}' en AVISOS_AUTOMATICOS_HISTORICO. Seguir el mismo patrón que resumenBotDiario: adquirir antes del procesamiento, liberar en finally si exitoCron=false. Esto previene el double-trigger de GCP.
- **Corregir boundary de eventosGpsDelDia a medianoche del día siguiente:** Cambiar `new Date(fechaArt + 'T23:59:59-03:00')` por `new Date(fechaArtSiguiente + 'T00:00:00-03:00')` y usar `where('report_date', '<', ...)` (exclusive upper bound), donde fechaArtSiguiente = día siguiente en ART. Usar el mismo helper medianocheArt ya existente en jornadas_v3_batch.ts.
- **Paginación defensiva en la query de reclamos pendientes del cron de cierre:** cerrarReportesJornadaDiario carga todos los REPORTES_DISCREPANCIA con estado='pendiente' sin limit. Si se acumulan reclamos no procesados (p.ej. batch v3 apagado por varios días), una sola corrida puede intentar procesar cientos de docs con múltiples Firestore reads por reclamo, superando el timeout de la Cloud Function (no tiene timeoutSeconds definido — hereda el default de 60s). Agregar .limit(100) y loguear cuando se alcanza, o definir timeoutSeconds: 300 explícito.
- **procesarVentanaUnChofer lee TODOS los eventos del día antes de filtrar por DNI:** procesarVentanaUnChofer (jornadas_v3_batch.ts:301) descarga toda la colección SITRACK_EVENTOS del rango (varios miles de docs) y filtra en memoria por driver_dni. Considerando que resumenConductaManejoDiario pone un limit de 50K para el mismo rango, esto puede causar 504 en la callable de 120s para un día con alta actividad. Agregar un índice compuesto Firestore en (driver_dni, report_date) y usar la query directa. El comentario dice 'evita el índice compuesto' — evaluar si el índice ya existe o crearlo.
- **Limitar la ventana de 'reciencia' en v3ConfirmaPausa a reclamos recientes:** En v3ConfirmaPausa, la rama de reciencia (`reciente = cand.find(p.finMs >= reporteMs - 90min)`) puede matchear pausas incorrectas para reclamos procesados días después de ser creados. Agregar un guard: si reporteMs tiene más de 4 horas de antigüedad respecto al inicio del turno v3, saltar la rama de reciencia y confiar solo en la coincidencia por hora explícita. Esto evita falsos CIERTO.
- **El cron cerrarReportesJornadaDiario no tiene timeoutSeconds definido:** El onSchedule de cerrarReportesJornadaDiario (cierre_reportes_jornada.ts:277) no define timeoutSeconds ni memory, heredando los defaults (60s / 256MB). Dado que hace N reads de REGISTRO_JORNADAS + SITRACK_EVENTOS por reclamo (serial, no batch), con 20 reclamos pendientes fácilmente supera 60s. Agregar timeoutSeconds: 300, memory: '512MiB' como el cron de paradas_reportadas.

### Ideas de features que esta área habilita

- Dashboard de 'reclamos de jornada' para el admin: ya existe REPORTES_DISCREPANCIA con veredicto, nota_revision, pausasV3 y eventosGPS cargados por el cron. Una pantalla admin podría mostrar el historial completo de reclamos de cada chofer (cuántos CIERTO vs NO_CIERTO) y detectar choferes que sistemáticamente reclaman pausas que el GPS contradice — señal de evasión del sistema.
- Score de confianza de reclamos: el campo confianza del registro v3 (alta/media/baja) ya existe por turno. Exponerlo al lado del veredicto del cierre automático en la pantalla de reportes del admin ayudaría a priorizar revisiones manuales — un reclamo con confianza=baja merece más atención humana que uno con alta.
- Notificación proactiva al chofer cuando su parada reportada (PARADAS_REPORTADAS) es confirmada por v3: el cron de paradas_reportadas.ts ya persiste el veredicto 'confirmada_v3', pero no le avisa al chofer. Un WhatsApp 'Tu parada de las HH:MM quedó registrada' cerraría el loop y reforzaría el uso de la herramienta por parte del chofer.
- Resumen semanal de jornadas a Molina desde REGISTRO_JORNADAS v3: los datos por turno ya están (manejoNetoSeg, bloquesExcedidos, recorridoKm, confianza). Un cron semanal (lunes 08:00) con el histograma de infracciones de la semana pasada sería más útil operativamente que el resumen diario para identificar patrones por chofer.
- Alerta temprana si el batch v3 no escribió datos: si a las 07:00 ART el cron de paradas reportadas corre y REGISTRO_JORNADAS para ayer está vacío (batch falló o flag off), ya hay señal de problema. Encolar un WhatsApp al admin 'el registro de jornadas v3 de ayer está vacío — verificar el cron registrarJornadasV3Diario' aprovecha infraestructura existente.

### Deuda técnica

- jornadas_v3_batch está DORMIDO (no exportado desde index.ts, protegido por flag) pero resumenExcesosJornadaDiario ya usa armarResumenJornadasV3Diario como fuente oficial. Si el flag está off o el batch falló, Molina recibe 'Sin incidencias' silenciosamente. La transición Paso 4 completó pero la red de seguridad (fallback al v2) quedó comentada como rollback manual.
- armarResumenJornadasDiario (v2, jornadas_v2.ts:1742) sigue existiendo como función exportada pero ya no la llama ningún cron activo — es un fallback de rollback documentado en comentario pero sin un mecanismo de activación automática si el v3 falla. Candidata a limpieza cuando el v3 sea estable.
- La función descansoPrevioCumplido (jornadas_v2.ts:516) corre una query Firestore por cada chofer que maneja en veda nocturna (00:00-06:00 ART) con manejo < 2h. En una corrida de madrugada con 10 choferes en esa franja eso son 10 queries extra. Candidata a pre-cargar en batch al inicio del tick.
- La colección JORNADAS usa jornada_fin_ts == null para indicar 'abierta', pero Firestore no indexa los nulos. Las queries where('jornada_fin_ts', '==', null) en cargarJornadaAbierta no pueden usar un índice compuesto con chofer_dni — son full scans en la subcolección por chofer. Con 50 choferes y jornadas históricas acumuladas esto se degradará.
- El tick del vigilador v2 (tickVigiladorJornada) ejecuta await entrada.ref.set()/update() + await encolarAvisoXxx() en serie por chofer, dentro del loop. Con 50 choferes son hasta 150+ escrituras seriales. El patrón de batched writes (WriteBatch) reduciría la latencia del tick de minutos a segundos, reduciendo el riesgo de que un tick tarde más que el intervalo del cron.
- La lógica de decisión de movimiento en el tick (decidirManejando + analizarEventosDetencion) usa Date.now() dos veces separadas (líneas 1487 y 1493) en lugar de capturar ahora una sola vez. En la práctica la diferencia es submilisegundos pero introduce inconsistencia teórica en los cálculos de edad de datos.
- jornada_historico.ts reconstruye las jornadas con un algoritmo propio (velocidad sostenida > 15 km/h, sin usar los event_ids de Sitrack) mientras que v3 usa los event_ids (contacto OFF, detenido, etc.) que son más precisos. Los dos módulos coexisten y producen resultados distintos para el mismo turno — la UI muestra ambos sin documentar claramente cuál es la fuente canónica.
- eventosGpsDelDia en cierre_reportes_jornada.ts carga TODOS los eventos del chofer en el día (puede ser cientos) en memoria para analizarGpsVentana que solo necesita los eventos de una franja de 30-60 minutos. Agregar los filtros report_date >= t0 - margen y report_date <= t1 + margen directamente en la query Firestore ahorraría reads y memoria.


## fx-integraciones — 9 archivos leídos

El área cubre 9 archivos que integran Sitrack (GPS/iButton), Volvo Connect (alertas/telemetría/scores/estado en vivo) y las zonas de descarga (geocercas + histórico). El código es sólido en su estructura general: locks anti-duplicación en todos los crons, retry con backoff en las llamadas externas, idempotencia en escrituras críticas, TTL en colecciones que crecen, y separación limpia entre parseo puro (testeable) y I/O. Los bugs encontrados son de mediana/baja severidad en la escala real actual pero con vectores de crecimiento claros: el más crítico es el batch sin límite en zonas_descarga que puede romperse al configurar más zonas, y el fan-out de writes individuales en historico_ibuttons que bajo backfill genera cientos de requests paralelos no batched. La cobertura de alertas Volvo y el routing de seguridad (bypass DAS/LKS/AEBS) están bien implementados. Estado general: saludable con deuda técnica acotada.

### Mejoras

| Mejora | Categoría | Impacto | Esfuerzo |
|---|---|---|---|
| Agregar flush por chunks al batch de zonaDescargaPoller | robustez | alto | bajo |
| Convertir persistirTramo a batch en historico_ibuttons | robustez | medio | bajo |
| Actualizar cursor Volvo aunque no haya alertas nuevas | robustez | bajo | bajo |
| Añadir índice compuesto en SITRACK_EVENTOS para la query de cobertura en vivo | rendimiento | medio | bajo |
| Separar sitrackPosicionPoller del drift-detection en un subtask evitable | mantenibilidad | bajo | bajo |
| Limitar la query full-scan de SITRACK_POSICIONES en zonaDescargaPoller | rendimiento | bajo | bajo |
| Alertar cuando el cron de zonaDescargaPoller detecta 0 unidades recientes | robustez | medio | bajo |
| Usar fetchConReintentos en telemetriaSnapshotScheduled (reemplazar loop manual) | mantenibilidad | bajo | bajo |
| Agregar lock al backfillDescargasDiario para evitar doble ejecución | robustez | bajo | bajo |

- **Agregar flush por chunks al batch de zonaDescargaPoller:** Reemplazar el batch único con el mismo patrón de `sitrackEventosPoller`: mantener un contador `opsEnBatch` y hacer `await batch.commit(); batch = db.batch(); opsEnBatch = 0` cada vez que se acerque a 490 ops. El arreglo es de ~15 líneas siguiendo el código ya existente en el mismo repo (sitrack.ts línea 779).
- **Convertir persistirTramo a batch en historico_ibuttons:** Reemplazar `await Promise.all(tramos.map(persistirTramo))` por el mismo patrón que `persistirDescargas` en historico_descargas.ts: agrupar en chunks de 400 con `db.batch()`. Esto reduce las conexiones paralelas a Firestore y hace el backfill más robusto. La función `persistirTramo` puede desaparecer; la lógica se inline en `procesarRango`.
- **Actualizar cursor Volvo aunque no haya alertas nuevas:** En `volvoAlertasPoller`, si el run completa sin error HTTP pero `nuevoServerDateTime` es null (API no devolvió el campo), persistir igual `ultimo_exito_at` y `ultimo_recibidos: 0` sin tocar `ultimo_request_server_datetime`. Así el health cursor registra el éxito del tick aunque el cursor de tiempo no avance. Opcionalmente se puede generar el starttime con `new Date().toISOString()` como fallback defensivo cuando serverTs está ausente.
- **Añadir índice compuesto en SITRACK_EVENTOS para la query de cobertura en vivo:** La query `SITRACK_EVENTOS.where('report_date','>=',desdeEv).get()` en zonas_descarga.ts se ejecuta cada 5 minutos sobre una colección que crece a 3-5K docs/día. Con 90 días de retención son ~350K docs. Agregar en firestore.indexes.json un índice sobre `report_date` (ASCENDING) para SITRACK_EVENTOS (actualmente solo hay fieldOverride para `expira_en` TTL). Sin índice Firestore puede usar el single-field index pero con escaneado más costoso; el índice explícito también habilita paginación si en el futuro se necesita.
- **Separar sitrackPosicionPoller del drift-detection en un subtask evitable:** Actualmente en cada tick de 5 min el poller carga TODAS las ASIGNACIONES_VEHICULO (~30 docs) para hacer drift detection. Si el batch de SITRACK_POSICIONES fallara después del write, el lock liberado haría otro tick sin el drift. Extraer el drift-detection a un helper separado con su propio try/catch (ya tiene uno parcial) y hacer que un fallo de la query de asignaciones simplemente skipe el drift pero logee la métrica, separando claramente las dos responsabilidades.
- **Limitar la query full-scan de SITRACK_POSICIONES en zonaDescargaPoller:** `db.collection('SITRACK_POSICIONES').get()` trae TODOS los docs sin filtro (hoy ~55, pero crece con la flota). Agregar `.where('report_date', '>=', Timestamp.fromMillis(limiteMs))` evita traer docs de unidades sin datos recientes (aunque el filtro posterior los descarte igual, la query Firestore lee menos). Requiere el índice single-field en `report_date` que ya necesita SITRACK_POSICIONES para el mapa de flota.
- **Alertar cuando el cron de zonaDescargaPoller detecta 0 unidades recientes:** Si `posiciones.length === 0` después del filtro de 4h, el poller termina silencioso (no escribe nada, no alerta). Esto puede ocurrir si sitrackPosicionPoller dejó de funcionar. Agregar un log de nivel WARN o escribir en META/zona_descarga_cursor un flag `sin_unidades_recientes: true` para que el dashboard de salud lo detecte.
- **Usar fetchConReintentos en telemetriaSnapshotScheduled (reemplazar loop manual):** `telemetriaSnapshotScheduled` implementa su propio loop de reintentos con `while (intentos < maxIntentos)` y `await new Promise(setTimeout)`. El helper `fetchConReintentos` de comun.ts hace exactamente lo mismo y fue creado post-split para unificar este patrón. Reemplazar el loop manual por una llamada a `fetchConReintentos` reduce LOC y centraliza el comportamiento de retry.
- **Agregar lock al backfillDescargasDiario para evitar doble ejecución:** `backfillDescargasDiario` (cron 04:30 ART) no tiene lock. Si GCP dispara dos invocaciones simultáneas (at-least-once), ambas corren `limpiarHistoricoDescargasRango` + `procesarRangoDescargas` sobre el mismo día. El segundo corre sobre un histórico vacío (el primero ya borró y reconstruyó), produciendo un segundo set de writes redundantes. El riesgo es bajo pero el patrón `adquirirLockTick` ya está disponible y los otros crons del mismo horario (08:00) todos lo usan.

### Ideas de features que esta área habilita

- Zona de descarga con chofer: el histórico ya registra `chofer_dni` y `chofer_nombre` en cada descarga. Con eso se puede armar un KPI de 'descargas por chofer por semana' — útil para detectar quiénes hacen más turnos en YPF y como input para liquidación de viajes (cruce automático descarga ↔ viaje del día).
- Score Volvo diario visible por chofer: `VOLVO_SCORES_DIARIOS` ya tiene el score de eco-conducción por patente con 17+ sub-scores. Se puede mostrar al chofer en 'Mi equipo' su score de ayer (total + los 3 peores sub-scores) como feedback inmediato, sin revelar datos de otros — ya hay toda la infra de RBAC y la pantalla de detalle de vehículo.
- Historial de iButtons como fuente de verdad para multas: `SITRACK_IBUTTONS_HISTORICO` registra quién manejó qué patente y cuándo. Agregar en el módulo de multas (si existe o cuando se cree) un lookup automático por patente+fecha para pre-llenar el chofer responsable, en lugar de que el admin lo seleccione a mano.
- Tell-tales persistentes: detectar testigos en VOLVO_ESTADO que llevan N días en RED/YELLOW consecutivos (comparando contra el día anterior) y enviar una alerta adicional a Emmanuel tipo 'EBS del acoplado lleva 3 días en rojo en AG890AL sin cierre'. El estado actual ya se repite cada día en el parte, pero una alerta de escalada por persistencia tiene más urgencia.
- Mapa de calor de descargas por zona: con `ZONA_DESCARGA_HISTORICO` acumulando entrada_ts + duracion_min + patente, se puede armar una pantalla de 'KPIs de la zona' que muestre el ranking de unidades con más tiempo en planta, el promedio de espera por zona por día de la semana, y las horas pico — datos que Vecchi puede usar para negociar turnos con YPF.
- Drift de chofer como insumo para asignaciones: cuando `SITRACK_POSICIONES` detecta `drift_tipo=CHOFER_DISTINTO` (el iButton reporta DNI diferente al asignado en el sistema), sugerir al admin actualizar la asignación directamente desde la pantalla del mapa con un tap, en vez de ir a Asignaciones → nuevo registro.

### Deuda técnica

- zonas_descarga.ts: el comentario inline sobre 'reentradas espurias' (línea 34) documenta que descargas cortas con salida y vuelta en <2 min generan 2 entradas en el histórico. El workaround (look-back al último doc del histórico antes de archivar) está descrito pero no implementado.
- historico_ibuttons.ts: la query `SITRACK_EVENTOS.where('report_date','>=').where('report_date','<')` carga la colección entera del rango sin paginación. Con 90 días de TTL y 3-5K eventos/día, un backfill de 60 días puede intentar cargar ~270K docs en una sola query (límite de memoria del callable: 1GiB, hoy alcanza pero es un techo frágil).
- volvo_estado.ts: el comment 'engineSpeed casi nunca viene (3/53)' y 'peso_eje 0/53' documentan que la gran mayoría de la flota no transmite esos campos. El parser es defensivo pero hay campos en `EstadoVolvo` que siempre van a ser null para Vecchi — candidatos a ser eliminados o marcados como 'no disponible en cuenta ws41629' para no generar expectativas falsas.
- sitrack.ts: la variante de mensajes anti-baneo del aviso CHOFER_NO_IDENTIFICADO usa `rrPick` (round-robin en memoria de la instancia Cloud Run). El counter se reinicia en cold start — en producción con el cron de 5 min la instancia se mantiene caliente, pero si hay scaling o restart, el counter vuelve a 0 y puede repetir la variante 0 para varios choferes en la misma rafaga.
- volvo.ts: `ETIQUETAS_TIPO_ALERTA` y `ETIQUETA_BYPASS` son mapas inline en el módulo. El mismo mapeo tipo→etiqueta existe (parcialmente) en el cliente Flutter. Si Volvo agrega tipos nuevos, hay que actualizar en 2 lugares. Candidato a moverse a un JSON compartido o a un doc Firestore de configuración.
- telemetria.ts: `fechaMidnight` se calcula como `Date.UTC(year, month-1, day, 3, 0, 0)` (03:00 UTC = 00:00 ART). Correcto, pero el comentario dice 'Buenos Aires es UTC-3 sin DST' — validar que esto sigue siendo la justificación si Argentina alguna vez reimplementa DST (lo hizo hasta 2008).


## fx-plataforma — 12 archivos leídos

El área fx-plataforma cubre 12 archivos TypeScript que forman el núcleo de las Cloud Functions: setup/configuración global, autenticación con bcrypt + rate limiting, audit log, estadísticas del dashboard, limpieza de colecciones, exclusiones dinámicas de choferes/testers, canales pausados y la alerta externa por Telegram para caídas del bot. El código está bien estructurado, con buena separación de responsabilidades post-split. La seguridad del login es sólida (bcrypt, rate limit por DNI e IP con transacciones atómicas, anti-enumeración). El bot-health watchdog tiene una máquina de estados pura y testeable. Los principales problemas encontrados son: (1) el `renombrarEmpleadoDni` tiene una cascada incompleta que omite colecciones más nuevas del sistema; (2) la misma función no paginea el query previo al batch para colecciones grandes; (3) cinco colecciones nuevas no están en el backup semanal automático; (4) el path de cuenta inactiva en login tiene un info leak menor.

### Mejoras

| Mejora | Categoría | Impacto | Esfuerzo |
|---|---|---|---|
| Paginar el query previo al batch en renombrarEmpleadoDni | robustez | medio | bajo |
| Agregar las colecciones nuevas al backup y al cascade de renombrarEmpleadoDni | datos | alto | bajo |
| Unificar el mensaje de cuenta inactiva con el mensaje genérico | seguridad | bajo | bajo |
| Agregar callable de force-refresh para STATS/dashboard | ux | bajo | bajo |
| Cache de canales_pausados: stale infinito en caso de error Firestore | robustez | bajo | bajo |
| Exportar helper esExcluido desde excluidos.ts — ya existe, asegurar uso consistente | mantenibilidad | bajo | bajo |

- **Paginar el query previo al batch en renombrarEmpleadoDni:** En `actualizarReferencias`, reemplazar el `.get()` ilimitado por un loop con `.limit(500).get()`, procesar el batch, y repetir usando `startAfter(lastDoc)` hasta que el snapshot venga vacío. Esto acota el uso de memoria y la duración de cada operación, evitando el timeout en colecciones grandes como SITRACK_EVENTOS. Alternativamente, agregar `.limit(5000)` con un log de advertencia si `snap.size === 5000` (señal de que se necesita una segunda corrida).
- **Agregar las colecciones nuevas al backup y al cascade de renombrarEmpleadoDni:** En `mantenimiento.ts`, agregar a `collectionIds`: `ZONA_DESCARGA_HISTORICO`, `REGISTRO_JORNADAS`, `PARADAS_REPORTADAS`, `REPORTES_DISCREPANCIA`, `VOLVO_JORNADAS_HISTORICO`. En `auth.ts`, agregar `actualizarReferencias('ZONA_DESCARGA_HISTORICO', 'chofer_dni')`, `actualizarReferencias('REGISTRO_JORNADAS', 'chofer_dni')`, `actualizarReferencias('PARADAS_REPORTADAS', 'chofer_dni')`, `actualizarReferencias('REPORTES_DISCREPANCIA', 'chofer_dni')`. Para REGISTRO_JORNADAS el docId es `{dni}_{fecha}` — además del campo `chofer_dni`, hay que renombrar el doc id, lo cual `actualizarReferencias` no maneja (solo actualiza el campo). Documentar este caso edge como known limitation o agregar manejo especial.
- **Unificar el mensaje de cuenta inactiva con el mensaje genérico:** En `loginConDni`, reemplazar `'Usuario inactivo. Contacte a administración.'` por `'Usuario o contraseña incorrectos.'` (mismo string que DNI-no-existe). Agregar en el mismo bloque `await registrarIntentoFallidoIp(ipHash)` para que las pruebas de DNIs inactivos tampoco sean gratuitas. El logger interno sigue discriminando `[login] cuenta inactiva` para diagnóstico sin exponer el detalle al cliente.
- **Agregar callable de force-refresh para STATS/dashboard:** El comentario en `dashboard_stats.ts` línea 186 menciona `recomputeDashboardStats` como 'scheduled + callable de force-refresh (futuro)'. Implementar un `onCall` que permita al admin refrescar los KPIs manualmente desde el panel sin esperar 30 min. Reutiliza directamente `_statsRecomputeDashboard()` ya exportada. Solo ADMIN/SUPERVISOR pueden invocarlo.
- **Cache de canales_pausados: stale infinito en caso de error Firestore:** En `canales_pausados.ts`, cuando la lectura de Firestore falla, el catch devuelve `_cache ?? {}`. Si `_cache` es `null` (primera llamada), devuelve `{}` pero NO actualiza `_cacheExpiraMs`. La próxima llamada vuelve a intentar Firestore porque el cache expiró, lo cual es correcto. Pero si el cache tenía datos previos válidos (`_cache !== null`) y Firestore falla, devuelve los datos viejos sin actualizar `_cacheExpiraMs` — la próxima llamada (inmediata) vuelve a Firestore y así en cada tick del resumen. En un escenario de Firestore degradado con muchos crons activos, esto causa N reads fallidas por ciclo. Fijar: en el catch, si `_cache !== null`, también actualizar `_cacheExpiraMs = Date.now() + TTL_MS` para absorber el fallo hasta el próximo ciclo.
- **Exportar helper esExcluido desde excluidos.ts — ya existe, asegurar uso consistente:** El helper `esExcluido` ya está exportado pero varios callers lo usan con acceso directo a `excluidos.dnis.has()` y `excluidos.patentes.has()` en lugar de la función. Normalizar los callers para que usen `esExcluido` reduce la probabilidad de olvidar la normalización a uppercase de la patente (el helper lo hace, el acceso directo no).

### Ideas de features que esta área habilita

- Callable `auditLogRead` con paginación: los datos de `AUDITORIA_ACCIONES` ya existen pero no hay un endpoint server-side para consultarlos con filtros (admin, acción, entidad, rango de fechas). Un callable paginado permitiría exportar la bitácora completa desde el panel admin sin otorgar acceso de lectura directo a la colección.
- Dashboard de anomalías de login: `LOGIN_ATTEMPTS` y `LOGIN_ATTEMPTS_IP` acumulan datos de intentos fallidos pero nadie los lee ni los reporta. Una función diaria (o callable) podría agregar los top-N DNIs e IPs con más intentos fallidos del día y enviar un resumen a Santiago, convirtiendo los datos de seguridad en inteligencia accionable.
- Purga automática de colecciones auxiliares: `LOGIN_ATTEMPTS`, `LOGIN_ATTEMPTS_IP` y `PASS_CHANGE_ATTEMPTS` se crean cuando hay intentos fallidos pero no se limpian cuando expiran. Con el tiempo pueden acumular miles de docs de atacantes que ya no están activos. Un TTL field (como el que ya tiene `COLA_WHATSAPP`) o una purga periódica similar a `purgarColaWhatsappAntigua` mantendría esas colecciones limpias.
- Canal de recuperación en `canales_pausados`: el doc `META/canales_pausados` ya permite pausar canales con fecha de expiración automática, pero cuando expiran no hay notificación al admin que los pausó. Podría extenderse `procesarSilenciadosExpirados` o crear un cron similar que al expirar una pausa loguee el evento y opcionalmente avise al admin.
- Métrica de cobertura del backup: el cron `backupFirestoreScheduled` loguea el inicio y el nombre de la operación, pero no hay forma de saber a posteriori qué colecciones se exportaron realmente ni su tamaño. Agregar una CF que lea el estado de la operación (via `gcloud firestore operations list`) unas horas después del backup y persista el resultado (collection count, total bytes) en `STATS/ultimo_backup` haría el estado de los backups visible desde el panel admin.

### Deuda técnica

- renombrarEmpleadoDni no es idempotente: si timeout entre `refNuevo.set()` y `refViejo.delete()`, la segunda invocación falla con `ALREADY_EXISTS` en el doc nuevo. No hay mecanismo de recovery ni documentación del estado parcial.
- La lista `collectionIds` del backup y la lista de cascada de `renombrarEmpleadoDni` son dos inventarios manuales de colecciones que divergen con cada feature nueva. El patrón se ha roto ya dos veces según los comentarios del código.
- El doc `STATS/dashboard` puede quedar stale hasta 30 min y no hay forma de saber desde el cliente si los datos son frescos o si el cron falló. El campo `actualizado_en` existe pero el cliente no lo muestra ni avisa si está muy viejo.
- Los módulos `canales_pausados.ts` y `comun.ts` tienen caches module-level separados con TTL distinto (5 min ambos) y sin mecanismo de invalidación en producción. Si se necesita propagar un cambio urgente, hay que esperar el TTL.
- La función `actualizarReferencias` en `renombrarEmpleadoDni` no maneja colecciones donde el docId codifica el DNI (ej: `REGISTRO_JORNADAS` con docId `{dni}_{fecha}`). El campo `chofer_dni` se actualiza pero el docId queda con el DNI viejo, lo que rompe queries por docId.
- El helper `hashId` fue movido de `auth.ts` a `comun.ts` en 2026-06-10, pero el JSDoc en `auth.ts` (línea 1063) dice que fue movido; lo sigue importando desde `./comun`. Está funcionalmente correcto pero la deuda de documentación interna podría confundir a quien lea auth.ts en frío.


## bot-nucleo — 10 archivos leídos

El núcleo del bot WhatsApp (10 archivos en whatsapp-bot/src/) es en general robusto: la anti-auto-respuesta de 3 capas funciona correctamente, el RBAC por herramienta usa `persona.dni` resuelto por identidad (no por input del usuario), el shutdown graceful y la deduplicación de la cola están bien implementados, y el agente Gemini tiene el thinkingBudget:0 configurado. Los bugs encontrados son operativos reales: un doble-offset de timezone en las descargas históricas (el error más grave), un mapa de confirmaciones de adelanto que crece sin límite en sesiones largas, una consulta full-scan sin filtro server-side en adelantos emitidos, y la ausencia de `agente_pedir_llamada` en la whitelist de mensajes time-sensitive. La deuda técnica es manejable y no hay vulnerabilidades de inyección de rol detectadas.

### Mejoras

| Mejora | Categoría | Impacto | Esfuerzo |
|---|---|---|---|
| Agregar `agente_pedir_llamada` a ORIGENES_TIME_SENSITIVE | robustez | alto | bajo |
| Corregir timezone en `horaArt` de `_toolDescargasHistorico` | datos | alto | bajo |
| Agregar janitor de `_adelantosPendientes` al `_sweepTimer` | robustez | medio | bajo |
| Agregar filtro server-side por fecha en `_toolAdelantosEmitidos` | rendimiento | medio | bajo |
| Reemplazar `wmic` por PowerShell en `_matarChromesHuerfanos` | robustez | medio | bajo |
| Usar `_getEmpleadosDocs` en `_toolListarEmpleadosPorRol` | rendimiento | bajo | bajo |
| Exponer métricas de tamaño de Maps internos en el health heartbeat | mantenibilidad | bajo | bajo |
| Consolidar las dos funciones helper de hora ART en un único helper compartido | mantenibilidad | medio | bajo |

- **Agregar `agente_pedir_llamada` a ORIGENES_TIME_SENSITIVE:** En `humano.js` agregar `'agente_pedir_llamada'` al Set ORIGENES_TIME_SENSITIVE junto a `'agente_registrar_parada'`. Esto garantiza que la solicitud de llamada al encargado generada por el agente llegue en tiempo real, independientemente del horario laboral.
- **Corregir timezone en `horaArt` de `_toolDescargasHistorico`:** Reemplazar la lambda `horaArt` en agente.js línea 2116-2121 para que use `ts.toDate().getHours()` y `.getMinutes()` aprovechando el TZ del proceso (como lo hace `_horaArtDeTs`), eliminando el desplazamiento manual de -3h que produce double-offset.
- **Agregar janitor de `_adelantosPendientes` al `_sweepTimer`:** En agente.js, dentro del callback del `_sweepTimer` (líneas 181-191), agregar un loop sobre `_adelantosPendientes` que elimine entradas cuyo `ts` sea más antiguo que 5 minutos (igual TTL que el lazy-expiry en paso 2). Una línea adicional en el barrido existente.
- **Agregar filtro server-side por fecha en `_toolAdelantosEmitidos`:** Antes del `.get()` en `_toolAdelantosEmitidos`, construir un Firestore Timestamp para el inicio del período (hoy o mes según `periodo`) y agregar `.where('creado_en', '>=', limiteTs)`. Esto convierte el full-scan en una query acotada, reduciendo costo de lectura y latencia.
- **Reemplazar `wmic` por PowerShell en `_matarChromesHuerfanos`:** En whatsapp.js, reemplazar el comando `wmic process where ...` por `Get-Process -Name chrome,chromium | Where-Object { ... } | Stop-Process -Force` usando el mismo patrón PowerShell que ya usa `matarProcesosChromiumZombi` en index.js. Eliminar así la dependencia de wmic deprecated.
- **Usar `_getEmpleadosDocs` en `_toolListarEmpleadosPorRol`:** Reemplazar la query directa en `_toolListarEmpleadosPorRol` por una llamada a `_getEmpleadosDocs(db)` seguida de `.filter(e => e.ROL === rol && e.ACTIVO !== false)`. Esto reutiliza el cache de 5 minutos y evita reads redundantes en conversaciones activas.
- **Exponer métricas de tamaño de Maps internos en el health heartbeat:** En health.js o en el heartbeat de index.js, incluir el tamaño de `_adelantosPendientes`, `_histPorClave`, `_rlPorClave` e `_idsPropios` en el documento BOT_HEALTH/main. Permite detectar desde el dashboard si algún Map crece anormalmente sin necesidad de acceso SSH.
- **Consolidar las dos funciones helper de hora ART en un único helper compartido:** Existen `_horaArtDeTs` (correcto, usa .toDate().getHours()) y la lambda `horaArt` (incorrecta) en archivos/funciones distintas. Extraer `_horaArtDeTs` a un módulo compartido (o a la misma sección utils de agente.js) y eliminar la lambda local para que todos los formateos de hora usen la misma implementación.

### Ideas de features que esta área habilita

- Notificación proactiva al encargado cuando un adelanto lleva más de 48h en estado PENDIENTE (sin aprobar ni rechazar): la colección ya tiene `creado_en` y `estado`, solo falta un cron o trigger que genere el aviso vía la cola.
- Dashboard de salud conversacional: los Maps `_histPorClave`, `_rlPorClave`, `_adelantosPendientes` e `_idsPropios` ya tienen toda la info para un panel admin en Flutter que muestre choferes activos en conversación, rate-limit alcanzado, y adelantos en confirmación pendiente — en tiempo real vía BOT_HEALTH.
- Respuesta fuera de horario con ETA: cuando un mensaje queda encolado por horario laboral, el bot podría responder automáticamente al chofer con 'Tu mensaje fue recibido, el encargado lo verá a partir de las 08:00' — index.js ya sabe que el mensaje fue silenciado, solo falta el ACK de vuelta.
- Historial de confirmaciones de adelanto: cada paso-1 y paso-2 del flujo `_toolCrearAdelanto` podría escribir un evento en una subcolección de auditoría, permitiendo trazar quién inició y confirmó cada adelanto desde el agente, independientemente del documento final en ADELANTOS_CHOFER.

### Deuda técnica

- El `_sweepTimer` barre `_histPorClave` y `_rlPorClave` pero no `_adelantosPendientes`: el patrón de sweep no es consistente entre todos los Maps con TTL.
- `_toolDescargasHistorico` tiene su propia lambda `horaArt` duplicando (incorrectamente) la lógica de `_horaArtDeTs`: dos implementaciones del mismo helper con comportamientos distintos conviviendo en el mismo archivo.
- `CONTACTOS_POR_AREA` en agente.js (líneas 755-761) tiene DNIs hardcodeados en el código fuente: si un encargado cambia, requiere despliegue de código en lugar de un update en Firestore.
- `_contarCola()` en health.js descarga documentos completos de PENDIENTE para filtrar `proximoIntentoEn` en memoria, en lugar de usar una query acotada o una aggregation query: con cola grande genera reads innecesarios en cada heartbeat.
- La función `matarProcesosChromiumZombi` en index.js y `_matarChromesHuerfanos` en whatsapp.js son variantes del mismo comportamiento con implementaciones tecnológicamente distintas (PowerShell vs wmic): deberían unificarse en whatsapp.js con la versión PowerShell.
- No hay límite de tamaño en `_adelantosPendientes` (a diferencia de `_idsPropios` que tiene cap de 2000 entradas): podría crecer sin cota teórica en escenarios de alta concurrencia.
- El campo `pausado_hasta` de control.js se interpreta en UTC implícito (comparado con `Date.now()`) mientras toda la app trabaja en ART: no hay bug activo porque la comparación es epoch vs epoch, pero la semántica no está documentada y confunde al leer los valores en Firestore desde el panel admin.


## bot-features — 28 archivos leídos

El área cubre los builders de mensajes WhatsApp (vencimientos, service, alertas Volvo), el agrupador de cola, los crons internos de avisos automáticos, comandos admin por chat, mapa de destinatarios, extracción de fechas y feriados AR. El código está en muy buen estado: arquitectura limpia, idempotencia sólida con doc-IDs determinísticos, manejo de TZ centralizado en fechas.js, validaciones defensivas en la mayoría de los flujos, y comentarios de auditoría exhaustivos. Se identificaron 4 hallazgos reales (ninguno crítico de plata/datos), 2 de ellos de severidad media y 2 bajos, más oportunidades de mejora concretas.

### Mejoras

| Mejora | Categoría | Impacto | Esfuerzo |
|---|---|---|---|
| Consolidar _primerNombreDe con resolverNombreSaludo de aviso_builder | mantenibilidad | medio | bajo |
| Agregar log.warn en canales_pausados cuando hasta_iso no es parseable | robustez | medio | bajo |
| Eliminar variables telefono muertas en cron.js (líneas 337 y 403) | mantenibilidad | bajo | bajo |
| Agregar feriados 2028 a feriados_ar.js antes de que expire la cobertura actual | robustez | bajo | bajo |
| Reemplazar aIsoYMD de fecha_extractor.js con la de fechas.js | mantenibilidad | bajo | bajo |
| Agregar log de advertencia cuando ORIGENES_AGRUPABLES en agrupador.js procesa un origen inesperado | robustez | bajo | bajo |
| Dedup del mapa ETIQUETAS_TIPO duplicado entre agrupador.js y aviso_alertas_volvo_builder.js | mantenibilidad | bajo | bajo |
| El resumen de vencimientos próximos a Giagante excluye los ya vencidos (dias < 0) | ux | medio | medio |

- **Consolidar _primerNombreDe con resolverNombreSaludo de aviso_builder:** commands.js tiene su propia _primerNombreDe (privada, usa partes[0]). aviso_builder.js tiene resolverNombreSaludo (pública, usa partes[1] correctamente, respeta APODO). Importar y usar resolverNombreSaludo en commands.js elimina la duplicación y el bug del apellido de una sola vez.
- **Agregar log.warn en canales_pausados cuando hasta_iso no es parseable:** En estaCanalPausado(), si Date.parse(hasta) devuelve NaN, agregar log.warn('[canales_pausados] canal <key>: hasta_iso no parseable (raw=<valor>). Canal queda pausado indefinidamente.') antes de return true. Así el admin detecta el dato corrupto en los logs del bot sin tener que esperar a que alguien reporte silencio en WhatsApp.
- **Eliminar variables telefono muertas en cron.js (líneas 337 y 403):** Borrar 'const telefono = String(data.TELEFONO)' (línea 337) y 'const telefono = String(chofer.data.TELEFONO)' (línea 403) ya que ninguna se usa. Reduce ruido y evita confusión en refactors futuros.
- **Agregar feriados 2028 a feriados_ar.js antes de que expire la cobertura actual:** El módulo cubre 2026–2027. Los feriados móviles (Carnaval, Viernes Santo, San Martín) requieren cálculo manual. La app estará en producción en 2028 — si nadie los agrega a tiempo, el bot enviará avisos en días feriados (aunque el tráfico de WhatsApp los fines de semana largos puede causar fricciones con anti-spam). Agregar un comentario TODO con fecha límite (ej. 'agregar antes de 2027-12-01') y una alerta en el log si new Date().getFullYear() > 2027.
- **Reemplazar aIsoYMD de fecha_extractor.js con la de fechas.js:** aIsoYMD en fecha_extractor.js no maneja Timestamps de Firestore y duplica la lógica ya centralizada en fechas.js (aIsoLocal). Reemplazar la implementación por un wrapper que llame a require('./fechas').aIsoLocal, o importar aIsoLocal directamente en message_handler donde se usa. Esto cubre el caso borde de Timestamps sin cambios de interfaz.
- **Agregar log de advertencia cuando ORIGENES_AGRUPABLES en agrupador.js procesa un origen inesperado:** En planificarEnvioAgrupado() el else final llama a _armarMensajeMantenimientoAgrupado pero ese caso ya no debería ocurrir (mantenimiento se removió de ORIGENES_AGRUPABLES en 2026-05-22). Si por algún bug de Cloud Function se encola un origen desconocido en el set, el mensaje de 'alertas de mantenimiento agrupadas' se mandaría silenciosamente a quien sea. Agregar un log.warn('[agrupador] origen inesperado: <origen>. Usando fallback mantenimiento') para que el caso sea visible.
- **Dedup del mapa ETIQUETAS_TIPO duplicado entre agrupador.js y aviso_alertas_volvo_builder.js:** ETIQUETAS_TIPO está definido idénticamente en agrupador.js (líneas 53-82) y aviso_alertas_volvo_builder.js (líneas 30-57). Cualquier tipo Volvo nuevo que se agregue a uno debe agregarse manualmente al otro. Mover el mapa a un módulo compartido (ej. src/volvo_tipos.js) exportado por ambos.
- **El resumen de vencimientos próximos a Giagante excluye los ya vencidos (dias < 0):** El cron filtra dias < 0 para el reporte consolidado a Giagante (cron.js líneas 889, 911). Esto significa que un papel ya vencido de un chofer NO aparece en el resumen diario de Giagante — solo recibe aviso el chofer directamente. Giagante no ve el contexto de quién tiene papeles ya vencidos. Considerar incluirlos con una sección separada 'VENCIDOS' al final del mensaje (misma data que ya se calcula para el chofer). Impacto medio: hoy Giagante puede no saber que hay papeles vencidos sin leer la app.

### Ideas de features que esta área habilita

- Digest semanal de seguridad para Molina/SEG_HIGIENE: el builder aviso_alertas_volvo_builder ya arma el resumen diario de eventos HIGH. Con la misma estructura se puede armar un resumen SEMANAL con tendencias (chofer con más eventos acumulados, tipo de alerta más frecuente, unidad con más incidentes), usando los datos de VOLVO_ALERTAS. Los datos ya existen — solo falta un nuevo builder y un cron semanal.
- Notificación proactiva al chofer cuando expira un silencio: el cron procesarSilenciadosExpirados (mencionado en commands.js) ya existe en Cloud Functions. Si está implementado, el bot puede avisarle al chofer 'tus notificaciones del vigilador están activas de nuevo' automáticamente al expirar el silencio — hoy ese aviso solo sale si el admin usa /desilenciar antes del vencimiento. Completar el ciclo mejora la UX del chofer.
- Comando /historial DNI (admin) que muestre los últimos 5 avisos enviados al chofer desde WHATSAPP_HISTORICO: el módulo firestore.js ya implementa WHATSAPP_HISTORICO con TTL 30 días. Un comando de diagnóstico que liste origen/fecha/estado de los últimos mensajes enviados ayudaría a resolver reclamos de 'no recibí el aviso' sin tener que ir a la app.
- Alertas de performance del cron: si stats.errores > 0 al final de _runOnce, encolar un aviso al admin (tel de ADMIN_PHONES[0]) con el detalle de los errores. Actualmente los errores solo van al log de la PC dedicada — si nadie mira el log, los avisos perdidos pasan desapercibidos.

### Deuda técnica

- EMPRESA_DOCS_ADMIN_DNI en .env está obsoleta desde 2026-05-18 (unificado en el cron de Giagante). Comentario en cron.js lo indica pero la variable puede seguir seteada generando confusión. Documentar en el .env.example que está deprecada.
- ALERTAS_RESUMEN_DESTINATARIO_DNI quedó obsoleta para el resumen de mantenimiento (movido a CF en 2026-05-22). Mismo cleanup pendiente que la anterior.
- yaSeEnvioServiceMaxUrgencia en historico.js: la función no es llamada desde cron.js (que usa el patrón de doc-ID determinístico desde el refactor 2026-05-18). Verificar si algún caller aún la usa o si puede removerse junto con el comentario '// quedan obsoletos para este flujo'.
- Las funciones yaSeEnvioServiceDiario / prepararRegistroServiceDiario mencionadas como obsoletas en historico.js (comentario líneas 238-245) ya no están en el archivo, pero el módulo exporta hist.yaSeEnvio que aún se usa para vencimientos individuales. El comentario es confuso: aclarar qué quedó y qué se removió.
- purgar_avisos_expirados.js está documentado como 'correr una sola vez' post-deploy TTL (2026-05-08) pero sigue en scripts/. Podría archivarse o convertirse en un script de mantenimiento periódico si se detecta que el bot estuvo caído > TTL.
- backfill_jornada_v3.js usa process.env.GOOGLE_APPLICATION_CREDENTIALS para inyectar credenciales al módulo deployado en lugar de initializeApp propio. Este patrón es frágil si el módulo ya inicializó Firebase en algún import transitivo — si aparece un error 'app already initialized', hay que revisarlo.
- Los 8 scripts de investigación/auditoría jornada_v3 (investigar, comparar, catalogo, verificar, dump, validar, auditar, flag, backfill, cerrar) tienen hardcodeados DNIs reales (26129762, 22987952) y patentes de choferes de Vecchi. Si el repo se abre o se sube a un fork, esos datos quedan expuestos. Considerar mover los casos a un archivo de config ignorado por .gitignore.


## python-servicios — 25 archivos leídos

El área python-servicios cubre el sniper de turnos YPF (vigia.py + orquestador.py + iturnos.py + nube.py + choferes.py) y los scrapers de sincronización (sync_icm.py con parser Sitrack, sync_taller.py con parser Volvo). El código está bien documentado, con post-mortems explícitos de bugs anteriores y una batería de tests unitarios sólida para la lógica pura. La arquitectura del vigía es robusta: backoff progresivo ante Cloudflare, detección de workers huérfanos, scanner con chofer-sin-turno, idempotencia ante crashes. Las principales debilidades son: un bug de comparación de tipos que inutiliza el TTL de limpieza de chequeos one-shot, dos archivos abiertos sin context manager en los scrapers, y un riesgo real de superar el límite de 1 MB por documento en ICM en meses intensos de infracciones.

### Mejoras

| Mejora | Categoría | Impacto | Esfuerzo |
|---|---|---|---|
| Extraer el fix DatetimeWithNanoseconds a un helper reutilizable | robustez | medio | bajo |
| Reducir TTL de chequeos de 120s a 30s o aumentarlo a 10 min | ux | medio | bajo |
| Persistir el flag turno_conseguido en Firestore para sobrevivir reinicios | robustez | medio | medio |
| Migrar infracciones ICM a subcolección para escalar más allá de 1 MB | escalabilidad | alto | medio |
| Añadir timeout explícito a page.evaluate() en sync_icm.py y sync_taller.py | robustez | medio | bajo |
| Loguear el grant de Sitrack con longitud para detectar sesión inválida | mantenibilidad | medio | bajo |
| Alertar por WhatsApp/Telegram si sync_icm falla el commit | mantenibilidad | alto | medio |
| Verificar que storage_state.json no filtre credenciales en el repo | seguridad | alto | bajo |

- **Extraer el fix DatetimeWithNanoseconds a un helper reutilizable:** El patrón de normalizar DatetimeWithNanoseconds a datetime tz-aware aparece en tres lugares distintos (flushear_avisos_encargado, listar_chequeos_resueltos_viejos con el bug, y potencialmente en código nuevo). Crear un helper _ts_utc(ts) -> datetime en nube.py que haga: 'return ts if ts.tzinfo else ts.replace(tzinfo=timezone.utc)'. Usarlo en todos los sites de comparación de timestamps para evitar que el patrón buggy reaparezca.
- **Reducir TTL de chequeos de 120s a 30s o aumentarlo a 10 min:** El TTL actual de CHEQUEO_TTL_SEG = 120 s da a la UI solo 2 minutos para leer el resultado y borrarlo. Si el operador hace el chequeo y la pantalla tarda en mostrar el resultado (latencia de Firestore + Cloudflare), puede que el bot ya haya limpiado el doc cuando la UI lo quiere leer. 10 minutos serían más seguros sin cambiar la experiencia. Además, en sincronizar_targets el operador recién pide el chequeo → el bot lo procesa en hasta un ciclo completo (8 s de REFRESH_CONFIG_SEG + el chequeo en sí 3-8 s) → la UI puede tardar otros segundos en recibir el snapshot. 10 min es más seguro.
- **Persistir el flag turno_conseguido en Firestore para sobrevivir reinicios:** El post-mortem del corte de luz 2026-05-28 (CELIZ + VOGEL) se resolvió con el guard de fecha pasada en sincronizar_targets. Pero si un chofer tiene fecha=None (cualquier fecha), al reiniciar el bot pierde turno_conseguido=True y vuelve a intentar reservarle. mis_turnos() al chequear inicial lo resuelve, pero si el check falla (Cloudflare) el chofer vuelve a estado 'buscando' con turno activo. Solución: en refrescar_estado, cuando se detecta que ya tiene turno, escribir un campo turno_conseguido=true en CACHATORE_OBJETIVOS/{dni}. Al inicializar un Target en sincronizar_targets, leer ese campo para restaurar el flag sin necesidad de una llamada a iTurnos.
- **Migrar infracciones ICM a subcolección para escalar más allá de 1 MB:** ICM_OFICIAL/{periodo} actualmente embebe el array infracciones[] de cada chofer en el doc principal. La migración a ICM_OFICIAL/{periodo}/choferes/{dni} con infracciones como subcollection elimina el riesgo de límite de 1 MB y permite queries por chofer. El app ya lee doc completo; habría que actualizar el listener para traer la subcolección. Bajo riesgo si se hace en paralelo (escribir ambas estructuras y migrar la lectura de la app primero). Impacto: desbloquea crecer la flota sin miedo al límite.
- **Añadir timeout explícito a page.evaluate() en sync_icm.py y sync_taller.py:** Los fetch in-page de get_ranking_data, get_top_infractions, get_infractions y del taller Volvo no tienen timeout en el page.evaluate(). Playwright aplica su default (30 s) pero si el fetch de Sitrack/Volvo queda en pending (problema de red, WAF colgado), puede bloquear el script indefinidamente. Añadir timeout explícito: page.set_default_timeout(25000) antes de los evaluate, o pasarlo por la señal de abort en el fetch JS (AbortController con setTimeout 20 s). Protege especialmente la corrida nocturna de la Scheduled Task.
- **Loguear el grant de Sitrack con longitud para detectar sesión inválida:** Si _extraer_client_grant falla (timeout, sesión caída), devuelve CLIENT_ID_DEFAULT y grant=''. Los fetch posteriores de get_ranking_data con grant='' devuelven datos vacíos (raw_driver vacío) y sync_icm imprime 'mensual vino vacío — abortando'. El problema es silencioso durante días si nadie ve el log. Añadir: if not grant: print('ALERTA: grant vacío — sesión probablemente caída; borrar storage_state.json y reintentar'); return 1 antes del fetch.
- **Alertar por WhatsApp/Telegram si sync_icm falla el commit:** sync_icm.py y sync_taller.py corren como Scheduled Task y su salida solo va al log de la tarea. Si falla la sesión Playwright, el commit no se hace y los datos de ICM/taller quedan desactualizados silenciosamente (la app muestra datos del período anterior sin aviso). Añadir al final de main() un bloque que, si args.commit y no hubo COMMIT OK, encole un aviso por COLA_WHATSAPP (reusando el patrón de nube.py/encolar_whatsapp) al responsable técnico. El módulo nube.py ya está disponible en el mismo virtualenv.
- **Verificar que storage_state.json no filtre credenciales en el repo:** storage_state.json guarda cookies y localStorage de la sesión de Playwright (Sitrack y Volvo Connect). Si accidentalmente se commitea, expone las credenciales de sesión. Verificar que ambos archivos (sitrack_sync/storage_state.json y volvo_sync/storage_state.json) estén en .gitignore junto a claves.json. Si no están, agregarlos.

### Ideas de features que esta área habilita

- Historial de turnos YPF por chofer: cada vez que el vigía reserva/reagenda/cancela un turno, ya encola el aviso con el 'cuando'. Con un log simple en Firestore (CACHATORE_HISTORIAL/{dni}/eventos[]) se podría mostrar en la app cuántos turnos sacó el bot por chofer en el mes, a qué franjas, y cuántas cancelaciones hubo — útil para detectar patrones (chofer que cancela mucho, franja que nunca consigue, etc.).
- Panel de salud del vigía en la pantalla Cachatore de la app: CACHATORE_ESTADO/bot ya tiene el campo salud {scanner_ok, fallos_scanner, hilos_huerfanos, sin_vigilar} escrito en cada latido pero la UI hoy no lo muestra. Exponerlo como un widget colapsable de 'Estado técnico' en la pantalla Cachatore daría al operador visibilidad de Cloudflare bloqueando o workers colgados sin tener que esperar el WhatsApp de alerta.
- Reagendar automático post-drop: cuando el vigía saca un turno de madrugada para un chofer que no pidió esa franja (porque era el único disponible en el drop), el operador luego activa 'reagendar' a mano. Se podría agregar una franja preferida vs franja de fallback en el objetivo: el bot saca lo que haya en el drop pero activa el reagendar automáticamente si el turno no cayó en la franja preferida.
- Reporte semanal de ICM por WhatsApp al encargado: sync_icm.py ya trae ICM_OFICIAL_SEMANAL con el ranking de la semana cerrada. Un Cloud Function o el mismo vigía podría enviar el top-3 peor y top-3 mejor al encargado de seguridad cada martes (cuando se congela la semana anterior), usando el mismo patrón de nube.py/encolar_whatsapp. Los datos ya están en Firestore — solo falta el trigger.
- Dashboard de disponibilidad de iTurnos: el vigía escanea la agenda cada ~5 s y sabe cuántos huecos libres hay y en qué franjas. Guardando ese snapshot en Firestore (CACHATORE_ESTADO/agenda cada N minutos) se podría mostrar en la app una mini-agenda histórica de disponibilidad — útil para que el operador sepa en qué franja suele haber más huecos y priorice las asignaciones antes del drop.

### Deuda técnica

- orquestador.py es código legacy que el vigía latente (vigia.py) reemplaza funcionalmente. Debería marcarse como deprecated con un comentario prominente o eliminarse para evitar que alguien lo use en producción creyendo que tiene las mismas protecciones anti-doble-reserva que vigia.py.
- claves.json tiene un diseño _comun + por-DNI que implica que todos los choferes de una misma empresa usan la misma clave de iTurnos. Si algún chofer cambia su clave individual, rompe el bot sin aviso hasta que alguien note el login_fallo. La verificar_logins.py detecta esto pero corre manual. Un chequeo periódico automatizado (diario, antes del drop) que alerte por WhatsApp si algún chofer falla el login sería más robusto.
- La PC dedicada usa NSSM como gestor de servicios pero el auto-update (git pull + restart) se implementó con una Scheduled Task de Windows, no con NSSM. Esta mezcla de dos sistemas de gestión complica el diagnóstico: estado_dedicada.ps1 tiene que consultar ambos. Migrar el auto-update a un servicio NSSM separado unificaría la gestión.
- sync_icm.py y sync_taller.py tienen sus propias copias de _db() con la misma lógica de inicialización de firebase_admin. Este patrón ya existe en choferes.py y debería centralizarse en un módulo compartido (db_admin.py) para evitar divergencias futuras.
- Los tests de vigia.py y iturnos.py corren contra mocks y no tienen runner automático integrado al CI/CD del repo (solo se mencionan en comentarios como 'correr con el venv'). Dado que hay tests de lógica pura de alto valor (franjas, semanas, fecha-pasada), deberían ejecutarse en el pre-commit hook o en un workflow de GitHub Actions igual que los tests de Flutter y Functions.
- diagnosticar_reagendar.py imprime directamente con print() en lugar del helper log() de vigia.py. Si alguna vez se integra a un flujo automatizado, el output no tendrá el formato de fecha [dd/mm HH:MM:SS] TAG y no será parseable por ver_logs_vigia.ps1.
- En iturnos.py, las constantes CAMPO_PATENTE, CAMPO_DNI, CAMPO_EMPRESA hardcodean IDs internos de la agenda YPF en iTurnos (campo[4767], campo[4768], campo[5293]). El código en reservar() ya arrastra todos los hidden fields del form (robusto a cambios), pero estos IDs se usan también para pisar los valores específicos del chofer. Si YPF reconfigura el form (cambia los IDs), la reserva fallaría silenciosamente con motivo 'revisar'. Añadir una verificación de que al menos los campos campo[PATENTE] y campo[DNI] están presentes en el form antes del POST.


## infra-config — 37 archivos leídos

Infraestructura sólida con una postura de seguridad muy cuidada: las Firestore Rules son extensas, bien documentadas y cierran vectores de escalada (ROL/CONTRASEÑA vía update directo, whitelist de campos en REVISIONES, ownership por DNI). Storage Rules también bien hardened post-auditoría 2026-05-17/30. El modelo de auth con custom claims es correcto y económico. El instalador Windows per-user resuelve el bug histórico de permisos. Sin embargo, hay un bug crítico de permisos: la colección AGENTE_CONVERSACIONES — escrita por el bot vía Admin SDK y leída por Flutter — no tiene ninguna rule en firestore.rules, por lo que cae al catch-all `if false` y todo read del dashboard del agente falla con permission-denied. Además hay un índice compuesto faltante en firestore.indexes.json para una query de 3 campos en GOMERIA_MONTAJES que ya está en producción. Las dependencias están razonablemente actualizadas; la pineación de firebase_storage en 13.0.4 es correcta y documentada. El hosting público carece de headers de seguridad HTTP (X-Frame-Options, X-Content-Type-Options, CSP) que serían convenientes aunque el sitio es estático e informativo. El installer/VERSION.txt desactualizado en el repo es cosmético (build_installer.ps1 lo sobreescribe al compilar).

### Mejoras

| Mejora | Categoría | Impacto | Esfuerzo |
|---|---|---|---|
| Agregar regla Firestore para AGENTE_CONVERSACIONES | seguridad | alto | bajo |
| Agregar índice compuesto unidad_id + posicion + hasta en GOMERIA_MONTAJES | robustez | alto | bajo |
| Agregar security headers HTTP al hosting de Firebase (public/ y web/) | seguridad | medio | bajo |
| Agregar Cache-Control explícito al hosting para flutter_bootstrap.js y assets | ux | medio | bajo |
| Mover hash de contraseña a subcolección EMPLEADOS/{dni}/credenciales/main | seguridad | medio | alto |
| Agregar índice TTL y fieldOverride para AGENTE_CONVERSACIONES en firestore.indexes.json | escalabilidad | medio | bajo |
| Corregir CompanyName y LegalCopyright en windows/runner/Runner.rc | mantenibilidad | bajo | bajo |
| Automatizar chequeo de VERSION.txt en el pipeline de release | mantenibilidad | bajo | bajo |
| Agregar rule para AGENTE_CONVERSACIONES en storage.rules si se suben adjuntos | seguridad | bajo | bajo |

- **Agregar regla Firestore para AGENTE_CONVERSACIONES:** Agregar en firestore.rules un bloque `match /AGENTE_CONVERSACIONES/{doc}` con `allow read: if isAdminOrSupervisor();` y `allow write: if false;` (el bot escribe por Admin SDK). Ubicarlo junto a BOT_HEALTH/BOT_EVENTOS. Agregar también TTL fieldOverride en firestore.indexes.json para el campo expira_en si el bot lo setea (consultar agente.js línea 3015 para verificar).
- **Agregar índice compuesto unidad_id + posicion + hasta en GOMERIA_MONTAJES:** En firestore.indexes.json agregar el índice: { collectionGroup: 'GOMERIA_MONTAJES', queryScope: 'COLLECTION', fields: [{fieldPath: 'unidad_id', order: 'ASCENDING'}, {fieldPath: 'posicion', order: 'ASCENDING'}, {fieldPath: 'hasta', order: 'ASCENDING'}] }. Deployar con `firebase deploy --only firestore:indexes`.
- **Agregar security headers HTTP al hosting de Firebase (public/ y web/):** En el bloque `hosting` de firebase.json agregar headers para todas las rutas: X-Frame-Options: SAMEORIGIN, X-Content-Type-Options: nosniff, Referrer-Policy: strict-origin-when-cross-origin. Para la web app Flutter (/sistema/) agregar también Content-Security-Policy básica que limite frame-ancestors y object-src. Formato: `"headers": [{"source": "**", "headers": [{"key": "X-Frame-Options", "value": "SAMEORIGIN"},...]}]`
- **Agregar Cache-Control explícito al hosting para flutter_bootstrap.js y assets:** En firebase.json agregar header `Cache-Control: no-cache` para `flutter_bootstrap.js` y `main.dart.js` (los nombres que genera Flutter web). Sin esto Firebase Hosting sirve estos archivos con caché del CDN que puede causar que los usuarios vean versiones viejas de la app web post-deploy. Para assets estáticos con hash (como `*.dart.js` con fingerprint) usar `max-age=31536000, immutable`.
- **Mover hash de contraseña a subcolección EMPLEADOS/{dni}/credenciales/main:** Como documenta el comment en firestore.rules línea 114-118: el campo CONTRASEÑA (hash bcrypt) está en el doc raíz de EMPLEADOS, que el chofer puede leer. Firestore no soporta field-level security. La mitigación correcta es mover el campo a `EMPLEADOS/{dni}/credenciales/main` con `allow read: if false` (Cloud Functions leen con Admin SDK). Requiere migración de datos + actualizar loginConDni + cambiarContraseñaChofer en functions/src/.
- **Agregar índice TTL y fieldOverride para AGENTE_CONVERSACIONES en firestore.indexes.json:** El bot setea TTL en docs de AGENTE_CONVERSACIONES (60 días según el comentario del service). Agregar el fieldOverride en firestore.indexes.json para el campo expira_en igual que se hace para WHATSAPP_HISTORICO (líneas 467-475 del índices). Sin esto Firestore no expira los docs automáticamente y la colección crece sin límite.
- **Corregir CompanyName y LegalCopyright en windows/runner/Runner.rc:** Reemplazar `VALUE "CompanyName", "com.example"` por `VALUE "CompanyName", "Coopertrans / Vecchi"` y ajustar LegalCopyright análogamente. Usar escape Unicode para la ó si es necesario (como ya hace `M\xF3vil` en la misma línea 93). Esto actualiza los metadatos visibles en Propiedades del exe en Windows Explorer.
- **Automatizar chequeo de VERSION.txt en el pipeline de release:** En release_app.ps1 o bump_version.ps1 agregar un paso que sincronice installer/VERSION.txt con la versión actual de pubspec.yaml. Actualmente build_installer.ps1 lo hace, pero si el instalador no se compila (solo se distribuye el .zip), el archivo queda desactualizado en el repo. Un `Set-Content installer/VERSION.txt $version` de 1 línea en bump_version.ps1 lo resuelve.
- **Agregar rule para AGENTE_CONVERSACIONES en storage.rules si se suben adjuntos:** Hoy el agente solo persiste texto en Firestore. Si en el futuro se agregan adjuntos multimedia (imágenes de comprobantes enviadas por WhatsApp al agente), Storage Rules no cubre ningún path para el agente. Anticipar el path `AGENTE_MEDIA/{archivo}` con `allow read: if isAdminOrSupervisor(); allow write: if false;` antes de que el bot empiece a subir.

### Ideas de features que esta área habilita

- Historial de errores del agente IA exportable: AGENTE_CONVERSACIONES ya persiste el campo `error` y `es_fallback`. Con un índice compuesto `es_fallback + creado_en` se puede armar un panel de diagnóstico que agrupa errores recurrentes por tipo (rate_limit, sin_texto, safety_block) y muestra tendencias semanales — sin dato nuevo, solo explotar lo que ya se guarda.
- Dashboard de coverage de versiones Windows en campo: el launcher escribe en GitHub Releases qué versión tiene cada PC. Con un script que lea la API de GitHub Releases + compare contra el tag más nuevo se puede saber cuántas PCs están desactualizadas y cuánto tiempo llevan así — útil para priorizar push de actualizaciones críticas.
- Regla de integridad cross-colección en rules: ahora que ASIGNACIONES_VEHICULO tiene una rule de create que valida `hasta == null`, se podría agregar un check adicional que use `get()` para verificar que el `vehiculo_id` exista en VEHICULOS antes de crear la asignación — evita asignaciones huérfanas si alguien borra el vehiculo por error desde Firestore Console.
- Índice de TTL para AGENTE_CONVERSACIONES y política de retención configurable: hoy no hay fieldOverride para el campo expira_en de esa colección. Al agregarlo se puede exponer la retención configurable (30/60/90 días) desde el panel de Estado del Bot — los datos ya existen, solo falta el mecanismo de expiración y la UI de configuración.
- Audit log de deploys de rules/indexes: firebase.json solo tiene predeploy para functions (lint + build). Agregar un hook postdeploy que registre en AUDITORIA_ACCIONES (vía Admin SDK + gcloud) qué versión de rules se deployó y quién la deployó. Útil si alguna regla abre acceso inadvertidamente y hay que rastrear cuándo ocurrió.

### Deuda técnica

- installer/VERSION.txt en el repo no se sincroniza automáticamente con pubspec.yaml al hacer bump — queda stale entre releases si no se corre build_installer.ps1.
- NSLocationAlwaysAndWhenInUseUsageDescription en iOS Info.plist sobrepromete permisos: fue agregado para silenciar ITMS-90683 pero contradice la política de privacidad pública que dice 'no accede al GPS en background'.
- CompanyName y LegalCopyright en windows/runner/Runner.rc siguen con el valor de scaffold 'com.example' desde la creación del proyecto Flutter.
- La migración del hash CONTRASEÑA a subcolección con read:false (documentada en firestore.rules línea 114-118 como 'MITIGACION FUTURA') lleva varias semanas pendiente — es el único campo sensible que un chofer autenticado puede bajar de su propio doc.
- whatsapp-bot no tiene engine node pineado a una versión exacta: especifica '>=18' lo que puede causar comportamiento distinto entre el NSSM en la PC dedicada (Node 18/20/22) y cualquier entorno de test. Las Cloud Functions sí están pineadas a node 22.
- La colección AGENTE_CONVERSACIONES no tiene fieldOverride de TTL en firestore.indexes.json aunque el bot setea un campo expira_en — los docs nunca expiran automáticamente y la colección crece sin límite.
- firebase.json hosting no define headers HTTP para el sitio público (public/) ni para la web app Flutter (/sistema/) — faltan X-Frame-Options, X-Content-Type-Options y Cache-Control para flutter_bootstrap.js.
- El índice GOMERIA_MONTAJES en firestore.indexes.json solo cubre 2 campos (unidad_id + hasta) mientras el código usa una query de 3 campos en el flujo de instalar/rotar — falta el índice de 3 campos incluyendo posicion.


## tests-cobertura — 69 archivos leídos

El proyecto tiene cobertura de test en tres capas: Flutter (33 archivos), bot WhatsApp Node.js (16 archivos), y scripts Python de sincronización (4 archivos). La capa Flutter es madura — cubre cálculos de dinero, RBAC, gomería, asignaciones con mutex, tarifas versionadas y generación de Excel end-to-end con calidad alta. El bot tiene cobertura amplia de la lógica de identidad, formateo, alertas Volvo, agrupación, agente Gemini (tools por rol, dedup, P0.1/P0.4), y los scrapers Python cubren la lógica pura de iTurnos/ICM con casos de borde reales. El hueco crítico y único es la capa de Cloud Functions TypeScript: no existe ni un solo test — todo el backend (vigilador de jornada v2/v3, descargas, drift, Sitrack, resúmenes diarios, alertas Volvo, colas WhatsApp, ICM oficial, rules de Firestore) corre completamente sin cobertura.

### Mejoras

| Mejora | Categoría | Impacto | Esfuerzo |
|---|---|---|---|
| Añadir tests de Cloud Functions con firebase-functions-test | robustez | alto | alto |
| Tests de Firestore Security Rules con @firebase/rules-unit-testing | seguridad | alto | medio |
| Tests del módulo de jornada v3 — umbrales y pausa encubierta | robustez | alto | medio |
| Tests del routing de alertas Volvo (volvo.ts) | robustez | alto | medio |
| Añadir test del drift de chofer — 3 tipos + fallback por nombre | robustez | medio | bajo |
| Extender tests del agente para rol SUPERVISOR | seguridad | medio | bajo |
| Test de reconciliación del '9' móvil en commands._resolverChoferPorTelefono | robustez | medio | bajo |
| Test del idempotencia de resúmenes diarios (resumenes_diarios.ts) | robustez | medio | medio |
| Añadir tests del cálculo de liquidación multi-moneda para POR_TONELADA con gastos | datos | medio | bajo |
| Añadir test de widget_test.dart con algo real | mantenibilidad | bajo | bajo |

- **Añadir tests de Cloud Functions con firebase-functions-test:** Crear functions/src/__tests__/ con al menos: (1) jornadas_v3.ts — umbrales 15min/500m/4h/7h/8h/12h, pausa encubierta, corte de turno; (2) descargas.ts — geocercas círculo/polígono, estadía mínima 5min, ventana 4h; (3) volvo.ts — routing de alertas (blacklist AdBlue/tell-tale, bypass DAS/LKS/AEBS, throttle 6h); (4) resumenes_diarios.ts — idempotencia y descarte por bot caído. Usar @firebase/functions-test con mocks de Firestore, sin emulador.
- **Tests de Firestore Security Rules con @firebase/rules-unit-testing:** Cubrir al menos: (1) CHOFER solo puede leer sus propios documentos en JORNADAS/ADELANTOS_CHOFER; (2) GOMERIA no puede leer EMPLEADOS; (3) unauthenticated no puede leer nada; (4) ADMIN puede escribir en EMPLEADOS. Usar el emulador local solo para la suite de rules. Integrar en el CI previo al deploy de rules.
- **Tests del módulo de jornada v3 — umbrales y pausa encubierta:** Extraer la lógica pura de detección de pausa encubierta (quietud >15min + desplazamiento <500m) y corte de turno (>12h manejo) a funciones puras en jornadas_v3.ts, luego testear con fixtures de eventos de posición. Especialmente el caso borde de 'pausa encubierta a las 11h45' que activa el cierre por cuota y pausa simultáneamente.
- **Tests del routing de alertas Volvo (volvo.ts):** Testear con mocks: (1) alerta HIGH al chofer; (2) alerta AdBlue va a mantenimiento (blacklist); (3) alerta DAS va a Molina con throttle 6h; (4) segunda alerta DAS dentro de 6h se descarta; (5) alerta con patente en EXCLUIDOS no se envía. Lógica crítica para no molestar a choferes con alertas de sistema.
- **Añadir test del drift de chofer — 3 tipos + fallback por nombre:** Extraer _detectarDrift a función pura y testear: (1) iButton coincide → sin drift; (2) iButton distinto → tipo IBUTTON; (3) sin iButton, chofer asignado distinto → tipo ASIGNACION; (4) fallback a nombre cuando no hay iButton ni asignación. Caso especialmente crítico: chofer SIN iButton que sale como otro chofer.
- **Extender tests del agente para rol SUPERVISOR:** En agente.test.js agregar: (1) SUPERVISOR tiene tools de ADMIN salvo las 5 exclusivas; (2) SUPERVISOR puede crear_adelanto; (3) rol null/desconocido → tools vacías o solo de consulta. Cubre el gap identificado en _toolsGemini para SUPERVISOR.
- **Test de reconciliación del '9' móvil en commands._resolverChoferPorTelefono:** Añadir en commands_identidad.test.js: teléfono Firestore con '9' (5492915...) vs ID entrante sin '9' (542915...) → resuelve correctamente. Espejo exacto del fix B3 ya cubierto en message_handler pero ausente en commands.
- **Test del idempotencia de resúmenes diarios (resumenes_diarios.ts):** El módulo tiene lógica de 'no re-enviar si ya se envió hoy' vía HISTORIAL_AVISOS. Sin tests, un bug en esa lógica mandaría duplicados diarios a todos los destinatarios. Testear con mock de Firestore que el segundo dispatch del día no genera una entrada nueva en COLA_WHATSAPP.
- **Añadir tests del cálculo de liquidación multi-moneda para POR_TONELADA con gastos:** calculos_viaje_test.dart cubre POR_TONELADA en calcularMontosBrutos pero no combina POR_TONELADA + gastos + multi-tramo + montoFijoChofer en calcularTodo. El caso real (viaje YPF con carga de 28TN + gastos de 4 tramos) puede acumular error de redondeo distinto al esperado por la regla de múltiplo-de-5 por tramo.
- **Añadir test de widget_test.dart con algo real:** El archivo test/widget_test.dart contiene solo '2+2=4'. No aporta ninguna cobertura. Reemplazarlo con un widget test real (por ejemplo, que AppFormatters.formatearMonto(0) no genera overflow en Text widget) o eliminarlo para no generar falsa sensación de cobertura.

### Ideas de features que esta área habilita

- Los tests del agente de WhatsApp ya mockean toda la lógica de tools por rol. Con esa infraestructura se podría generar automáticamente un 'documento de contrato' de las tools disponibles por rol (nombre, parámetros, descripción) a partir del resultado real de _toolsGemini() — útil para onboarding de nuevos operadores y para auditar permisos sin leer código.
- Los tests de cachatore/test_iturnos.py cubren parseo real de HTML de iTurnos con fixtures. Esa capa de parseo podría exponerse como un endpoint interno de 'diagnóstico de disponibilidad' (cuántos slots libres hay ahora mismo por franja) visible en el panel admin, sin cambiar el scraper ni el sniper.
- Los tests de sitrack_sync/test_parser.py usan fixture real de ICM de AB927WN con 5 visitas. Esa data normalizada (normalizar_servicios) ya incluye es_service y km por visita — es suficiente para calcular el intervalo real de service de cada unidad y mostrarlo en la pantalla de mantenimiento como 'último service hace N km' con la fecha, sin consultar Volvo Connect.
- Los tests de gomería tienen cobertura completa del stock por movimiento y conteo a ciegas. Con esa base es directo agregar un test de 'alerta de stock bajo' (SKU con stock <= 1) que valide el threshold antes de que se muestre en la UI — y el test mismo documenta cuándo se dispara la alerta.

### Deuda técnica

- Cloud Functions TypeScript sin ningún test (cero archivos en functions/src/__tests__/): toda la lógica de backend — vigilador de jornada v2/v3, descargas, drift, resúmenes diarios, alertas Volvo, cola WhatsApp — es deuda de cobertura crítica.
- Firestore Security Rules sin tests automatizados: la auditoría 2026-05-30 ya encontró 5 fixes de seguridad; sin suite de rules-unit-testing cualquier regresión es silenciosa.
- test/widget_test.dart contiene solo 'expect(2 + 2, 4)': placeholder que ocupa un slot en el runner sin aportar cobertura. Debe reemplazarse o eliminarse.
- Las suites del agente (agente.test.js, agente_loop.test.js) usan db mocks escritos a mano con lógica de colecciones duplicada en cada describe. Refactorizar a un factory de db-mock compartido reduciría el mantenimiento y evitaría que tests pasen por un mock incorrecto.
- Los tests de Python (test_vigia.py, test_iturnos.py) no están integrados en ningún CI: solo corren con el venv local del cachatore. Un runner de GitHub Actions o similar debería ejecutarlos en cada push a la rama main.
- El módulo de geocercas de descargas (zonas_descarga.ts) no tiene ningún test en ninguna capa a pesar de ser crítico para la facturación (si una geocerca falla, las descargas no se registran). La lógica de haversine + polígono es extraíble como función pura.
- La lógica de cálculo de días de vacaciones LCT (vacaciones_calculo_test.dart) no cubre el caso de empleado con más de 20 años donde el escalón de 35 días aplica — el test va hasta exactamente 20 años pero no testea 20 años + 1 día ni 25 años.
- Los tests de asignacion_vehiculo_test.dart y asignacion_enganche_test.dart no cubren el service layer (transacciones con mutex), solo el modelo. La lógica de mutex ya tiene sus propios tests (asignacion_mutex_test.dart), pero el service completo (cargar asignación activa + crear nueva + cerrar anterior) queda sin cobertura integrada.


## docs-onboarding — 19 archivos leídos

The docs-onboarding area covers README.md (root overview), RUNBOOK.md (operational incidents), ESTADO_PROYECTO.md (session log / handoff), MANUAL_USUARIO.md (user guide), PENDIENTES.md (active backlog), DEMO_CHECKLIST.md (demo flows), POLITICA_PRIVACIDAD.md (privacy policy), and a docs/ folder with 12 specialized guides. The documentation is generally thorough for a single-developer project and a second developer could partially onboard, but several files have drifted significantly from the actual codebase: MANUAL_USUARIO.md is missing roughly 10 production modules, README.md's feature list and crons catalog are stale by ~1 month, RUNBOOK.md has outdated test counts, and SITRACK_DEPLOY.md references the wrong GCP region. The most severe problem is POLITICA_PRIVACIDAD.md: it contains a factually false claim that vehicle location is NOT tracked continuously, when in reality SITRACK_POSICIONES is polled every 5 minutes; it also omits work-hour reconstruction (REGISTRO_JORNADAS), WhatsApp conversation storage processed by Gemini AI (AGENTE_CONVERSACIONES), and iButton identification data. This is a legal and App Store compliance risk. The handoff/ directory contains only icon assets (no architecture diagram or data model). There is no Firestore schema document anywhere in the repo.

### Mejoras

| Mejora | Categoría | Impacto | Esfuerzo |
|---|---|---|---|
| Actualizar POLITICA_PRIVACIDAD.md para reflejar todos los datos realmente recolectados | seguridad | alto | bajo |
| Crear SCHEMA_FIRESTORE.md con el mapa de colecciones y sus campos principales | mantenibilidad | alto | medio |
| Actualizar README.md: features list (16→24), crons catalog, y marcar secciones con fecha | mantenibilidad | medio | bajo |
| Expandir MANUAL_USUARIO.md para cubrir los ~10 módulos de producción no documentados | ux | medio | medio |
| Actualizar RUNBOOK.md: conteos de tests y descripción del pipeline CI | mantenibilidad | medio | bajo |
| Crear diagrama de integración (architecture diagram) en docs/ | mantenibilidad | alto | medio |
| Corregir SITRACK_DEPLOY.md: región us-central1 → southamerica-east1 | robustez | medio | bajo |
| DEMO_CHECKLIST.md: agregar flows para ICM, Eco-Driving, Logística/liquidación y Agente WhatsApp | ux | medio | bajo |
| Rotación o remoción de credenciales Sitrack en docs/EMAIL_SITRACK_API.md | seguridad | alto | bajo |
| SETUP_PC_DEDICADA_BOT.md: corregir Node 18 → Node 22 en el paso 1 | mantenibilidad | bajo | bajo |

- **Actualizar POLITICA_PRIVACIDAD.md para reflejar todos los datos realmente recolectados:** Reescribir la sección 3 para declarar explícitamente: (a) rastreo GPS continuo de vehículos vía Sitrack cada 5 min (SITRACK_POSICIONES + SITRACK_EVENTOS); (b) datos de jornada laboral (horas de manejo, pausas con timestamps, velocidad — REGISTRO_JORNADAS); (c) historial de conversaciones WhatsApp procesadas por Gemini AI (AGENTE_CONVERSACIONES), citando a Google como proveedor de IA; (d) datos de identificación por iButton (HISTORICO_IBUTTONS). Corregir la afirmación falsa de la línea 59. Actualizar el 'última actualización' a la fecha real. Agregar sección de proveedores externos (Google Firebase, Google Maps, Sitrack S.A., Sentry).
- **Crear SCHEMA_FIRESTORE.md con el mapa de colecciones y sus campos principales:** Crear docs/SCHEMA_FIRESTORE.md que liste las ~25 colecciones principales (EMPLEADOS, VEHICULOS, VIAJES, JORNADAS_V3/REGISTRO_JORNADAS, SITRACK_POSICIONES, SITRACK_EVENTOS, VOLVO_ESTADO, AGENTE_CONVERSACIONES, RECLAMOS, CUBIERTAS, MANTENIMIENTO, VACACIONES, ADELANTOS, EMPRESAS_EMPLEADORAS, STATS, etc.) con: docId convention (DNI, Patente, auto-id), campos clave y sus tipos, TTL si aplica, quién escribe (app/CF/scraper). Este es el documento de onboarding más crítico que falta: un segundo desarrollador no puede entender el modelo de datos solo leyendo el código Dart/TS.
- **Actualizar README.md: features list (16→24), crons catalog, y marcar secciones con fecha:** Actualizar la lista de lib/features/ para incluir los 8 módulos faltantes. Actualizar la sección de Cloud Functions/crons para agregar las funciones deployadas entre mayo-junio 2026. Corregir procesarSilenciadosExpirados de '1h' a '10 min'. Agregar un campo 'última revisión' por sección o un encabezado único con la versión actual (1.2.28) para que sea evidente cuándo se desincronizó.
- **Expandir MANUAL_USUARIO.md para cubrir los ~10 módulos de producción no documentados:** Agregar secciones para: ICM ranking (cómo interpretar el número, quién puede verlo), Registro de jornadas v3 / Mi Jornada (qué muestra la UI, cómo interpretar alertas), Vacaciones (cálculo LCT, import Excel), Mapa de flota con recorrido histórico, Descargas/zonas YPF, Vista ejecutiva, Agente conversacional WhatsApp (qué puede pedir el chofer, límites del agente), Cachatore (para quién aplica y cómo funciona el sniper). Actualmente un chofer nuevo o un supervisor no puede saber que estas funciones existen solo leyendo el manual.
- **Actualizar RUNBOOK.md: conteos de tests y descripción del pipeline CI:** Reemplazar '275 tests cliente (al 2026-05-13)' por '458 Flutter + 294 functions + 262 bot (al 2026-06-10)'. Actualizar la descripción del job de CI para Flutter (no '67 tests'). Agregar nota sobre los 3 jobs paralelos (Flutter / functions / bot) y sus duraciones aproximadas. Mientras se esté en el RUNBOOK, también vale actualizar la referencia a 'última actualización' de la tabla de contactos que tiene 4 celdas vacías (teléfono Santiago, contacto Vecchi, contacto Volvo Connect, número WhatsApp del bot).
- **Crear diagrama de integración (architecture diagram) en docs/:** Crear docs/ARQUITECTURA.md (o un SVG/PNG en handoff/) con un diagrama de las integraciones del sistema: app Flutter (Android/iOS/Windows/web) → Firebase Auth/Firestore/Storage → Cloud Functions → Sitrack API → Volvo Connect API → WhatsApp bot (PC dedicada, NSSM) → Gemini AI → Sentry. Incluir los crons de Cloud Scheduler y los scrapers Python de la PC dedicada. Sin este diagrama un desarrollador tardará horas en reconstruir mentalmente cómo fluye la información.
- **Corregir SITRACK_DEPLOY.md: región us-central1 → southamerica-east1:** Reemplazar todos los --location=us-central1 en los comandos gcloud scheduler por --location=southamerica-east1. Agregar una nota al inicio del archivo indicando que esta guía es histórica (ya deployado) pero útil para recrear los jobs en caso de migración o desastre. El error de región causaría que los jobs nuevos se creen en la región incorrecta, sin errores visibles, y las funciones de SA nunca los dispararían.
- **DEMO_CHECKLIST.md: agregar flows para ICM, Eco-Driving, Logística/liquidación y Agente WhatsApp:** Agregar secciones de demo para: (1) ICM ranking — verificar que el número coincide con el portal Sitrack, probar cierre de período; (2) Eco-Driving/Scores — mostrar ranking chofer; (3) Logística multi-tramo — crear viaje, liquidar, generar PDF; (4) Agente WhatsApp — comando de chofer, tool call visible en dashboard; (5) Mapa de flota con recorrido histórico (nuevo desde 2026-06-10). Estos módulos son los más diferenciadores del producto y no tienen script de demo.
- **Rotación o remoción de credenciales Sitrack en docs/EMAIL_SITRACK_API.md:** El usuario ws41629VecchiSRL está expuesto en el historial git. Evaluar: (a) si la contraseña asociada ya fue rotada; (b) si es posible remover el commit del historial con git filter-branch o BFG (aunque el historial en GitHub ya esté publicado, la eliminación del futuro es mejor que no hacer nada); (c) como mínimo, agregar una nota visible en el archivo que las credenciales reales NO deben ser incluidas en el template y que deben obtenerse desde el vault de Drive.
- **SETUP_PC_DEDICADA_BOT.md: corregir Node 18 → Node 22 en el paso 1:** Reemplazar 'Node.js 18 LTS o superior' por 'Node.js 22 LTS' en la sección de instalación manual. Verificar también que el script instalar_todo.ps1 referencia la versión correcta de nvm/node. Consistencia con SETUP_PC_DESARROLLO.md y el runtime de Cloud Functions.

### Ideas de features que esta área habilita

- Generar el SCHEMA_FIRESTORE.md automáticamente desde código: existe un archivo AppCollections con los nombres de todas las colecciones; un script que liste los colecciones + extraiga los typedef/model Dart podría producir un schema de referencia actualizado en cada release.
- Agregar un test de 'freshness' al pipeline CI que compruebe que la versión en README.md coincida con pubspec.yaml, y que el conteo de lib/features/ en README coincida con el directorio real — fallaría en cada release si el README no se actualiza.
- El MANUAL_USUARIO.md podría convertirse en un PDF generado automáticamente y publicarse en la página de soporte (cooper-trans.com.ar/app/manual) para que choferes nuevos tengan acceso offline, aprovechando el mismo pipeline de Firebase Hosting ya activo.
- Dado que ESTADO_PROYECTO.md tiene una laguna de 3 semanas (2026-05-22 a 2026-06-10), podría automatizarse un 'estado semanal' generado por Claude con los commits de la semana, evitando que el doc vuelva a quedar stale cuando la actividad es alta.

### Deuda técnica

- POLITICA_PRIVACIDAD.md no se actualiza con cada feature nueva que recolecta datos — no hay proceso (checklist, test, hook) que obligue a revisarla al agregar una colección nueva de Firestore.
- No existe ningún documento de Firestore schema en el repositorio: el modelo de datos completo vive implícitamente disperso entre modelos Dart, types TypeScript, y Firestore security rules.
- handoff/ no cumple su función de onboarding: solo contiene assets de iconos, no hay diagrama de arquitectura, ni decisiones de diseño, ni runbook de 'primer día'.
- RUNBOOK.md sección 'Contactos clave' tiene 4 celdas con TODO sin completar (teléfono Santiago, contacto Vecchi, contacto técnico Volvo Connect, número bot WhatsApp) — la información más crítica en un incidente mayor.
- ESTADO_PROYECTO.md tiene una laguna documentada de ~20 días de actividad intensa (2026-05-22 a 2026-06-10) que incluye el go-live en Play Store, App Store iOS, update in-app Windows, y vigilador v3 completo — el período más importante del proyecto no tiene sesiones registradas en el handoff doc.
- docs/EMAIL_SITRACK_API.md documenta una credencial de servicio web en el historial git y no existe un proceso de rotación periódica de esas credenciales.
- DEMO_CHECKLIST.md no cubre los módulos más diferenciadores del producto (ICM, agente conversacional, logística multi-tramo), lo que limita su uso en demostraciones a stakeholders o en auditorías de aceptación.
- SETUP_IOS_RELEASE.md describe un flujo de release manual con Transporter que ya fue reemplazado en la práctica por Xcode Cloud, pero el documento no refleja el workflow actual (Xcode Cloud trigger manual + ci_post_clone.sh).


---

# 5. Análisis estratégicos completos

## Producto — features nuevas

**Visión:** El sistema ya captura más datos operativos que muchos TMS comerciales (GPS cada 5 min, telemetría Volvo con combustible/AdBlue/horas, ICM oficial, geocercas YPF, liquidación completa con tarifas duales), pero casi todo fluye en una sola dirección: se captura y se mira en pantallas de admin. El valor no explotado está en tres movimientos: cruzar finanzas con operación (costo real por km, margen por tarifa — hoy se liquida sin saber cuánto cuesta mover cada tractor), convertir datos pasivos en alertas que valen plata directa (robo de gasoil, descargas sin facturar, demoras en planta), y abrir los datos hacia afuera — chofer, dador de carga y gerencia — que es exactamente lo que Samsara, Motive y Fleetio cobran por unidad/mes. Con los crons de Functions, la cola WhatsApp idempotente y los patrones de UI ya maduros, la mayoría de estas features son "un cron + una pantalla" para un solo dev. La selección prioriza efecto demostrable ante la empresa: cada propuesta produce un número de plata o un artefacto que la gerencia recibe sin pedirlo. Si hay que elegir tres para el próximo trimestre: rentabilidad por tarifa, alerta de robo de gasoil y el cazador de viajes sin facturar — las tres de esfuerzo bajo y con retorno medible en pesos el primer mes.

### Ranking de rentabilidad por tarifa y dador de carga

| Impacto | Esfuerzo | Horizonte |
|---|---|---|
| Alto | Bajo | Corto plazo |

- **Qué es:** Pantalla de margen bruto: por cada tarifa/cliente, ingresos (montoVecchi), costo chofer (montoChofer), comisión del dador y gastos, con ranking de rutas más y menos rentables y tendencia mensual.
- **Por qué:** Los datos ya están COMPLETOS en VIAJES_LOGISTICA (montoVecchi, montoChofer, gastosTotal) y en las tarifas (porcentajeComisionDador/montoFijoDador); hoy nadie ve qué ruta deja plata y cuál se hace por inercia. Una tarifa pricada 5% abajo del costo en una ruta que se repite 10 veces/mes son millones de pesos al año; esta pantalla es munición concreta para renegociar. Es lo primero que un gerente quiere ver y sale casi gratis.
- **Cómo:** (1) Service Dart que agrega VIAJES_LOGISTICA CONCLUIDOS del período por tarifa_snapshot.tarifaId: margen = montoVecchi − montoChofer − comisión dador − gastos. (2) Pantalla admin con el patrón cards-filtro ya definido + drill-down por tarifa con sparkline de margen mensual (patrón eco-driving). (3) Export Excel reutilizando el helper de reportes existente. Gate por capability ADMIN. Todo client-side, sin functions nuevas.

### Alerta de robo de gasoil (caída de nivel con unidad parada)

| Impacto | Esfuerzo | Horizonte |
|---|---|---|
| Alto | Bajo | Corto plazo |

- **Qué es:** Detector que compara los snapshots de NIVEL_COMBUSTIBLE (poller cada 5 min ya activo) y dispara WhatsApp inmediato si el nivel cae más de ~6% con la unidad quieta según SITRACK_POSICIONES, con hora, ubicación y link al mapa.
- **Por qué:** Samsara vende exactamente esto como feature estrella (alerta configurable de caída >5%, samsara.com) y la industria estima que 5-10% del combustible anual se pierde en robo/desvío. En una flota que vive del gasoil, un solo evento detectado (200 L ≈ $250-300 mil a precios actuales) paga el desarrollo; un robo atrapado in fraganti es la anécdota que recorre toda la empresa y luce el sistema como ninguna otra feature.
- **Cómo:** (1) Cron CF cada 10 min (o extensión del poller Volvo existente) que compara el último nivel contra el anterior por patente; si delta < −6% y la posición no se movió (haversine ya existe en zonas_descarga.ts), encola aviso en COLA_WHATSAPP a admin + Molina. (2) Exigir 2 lecturas consecutivas en baja para filtrar falsos positivos por pendiente/balanceo. (3) Cooldown por patente y umbral configurable en un doc META. Respetar el mapa de destinatarios antes de tocar routing.

### Cazador de viajes sin facturar (conciliación descargas ↔ viajes)

| Impacto | Esfuerzo | Horizonte |
|---|---|---|
| Alto | Bajo | Corto plazo |

- **Qué es:** Cron semanal que cruza ZONA_DESCARGA_HISTORICO contra VIAJES_LOGISTICA por patente+fecha y lista descargas reales registradas por GPS que NO tienen viaje cargado en logística (y el inverso: viajes EN_CURSO cuya descarga GPS ya pasó hace días), con bandeja de revisión en el panel.
- **Por qué:** Ángulo complementario al P1 del roadmap: P1 pre-carga viajes desde geocercas; esto AUDITA lo que igual se escapó. Cada descarga sin viaje es un viaje potencialmente no facturado al dador o no liquidado al chofer: recuperar UNO por mes ya supera con holgura el costo de desarrollo. Cierra el loop financiero del dato GPS que ya se captura solo.
- **Cómo:** (1) CF semanal que por cada doc de ZONA_DESCARGA_HISTORICO busca un viaje con misma patente y fechaDescarga ±1 día (denormalizar patente en el viaje si falta + índice compuesto); lo no matcheado va a una colección CONCILIACION_PENDIENTE. (2) Resumen WhatsApp al admin '3 descargas sin viaje esta semana' con el patrón de resumenes_diarios.ts (idempotencia por doc-ID determinístico). (3) Mini-bandeja en el panel admin para marcar resuelto/ignorar, mismo patrón que la bandeja de ambiguos del bot.

### Reporte de estadía en plantas YPF (detention a la argentina)

| Impacto | Esfuerzo | Horizonte |
|---|---|---|
| Alto | Bajo | Corto plazo |

- **Qué es:** Tablero + reporte mensual de cuánto tiempo pasa la flota dentro de cada geocerca de descarga: espera promedio por planta, por día de semana y franja horaria, ranking de unidades retenidas, y alerta en vivo si una unidad supera N minutos en cola sin salir.
- **Por qué:** ZONA_DESCARGA_HISTORICO ya acumula entrada/salida/duración por patente: es el 'Detention Report' que venden Samsara y Motive (la FMCSA estima ~US$300M/año perdidos por detention solo en EEUU). Horas de flota paradas en planta = viajes que no se hacen. Un PDF mensual 'su planta retuvo X horas de flota' es un argumento durísimo que la gerencia puede poner sobre la mesa de YPF para negociar turnos y estadías.
- **Cómo:** (1) Pantalla Flutter 'KPIs de planta' sobre ZONA_DESCARGA_HISTORICO: histograma de actividad por hora, promedio de espera por zona, top unidades — todo client-side con datos ya persistidos. (2) Cron CF de alerta en vivo: entrada_ts > N min sin salida → WhatsApp al admin (el cálculo minDentro ya existe en la UI de cola). (3) Export Excel/PDF mensual con los helpers de reportes existentes.

### Costo real por km por unidad (TCO de flota)

| Impacto | Esfuerzo | Horizonte |
|---|---|---|
| Alto | Medio | Medio plazo |

- **Qué es:** Tablero que calcula el $/km verdadero de cada tractor mes a mes: combustible (litros de TELEMETRIA_HISTORICO × precio gasoil configurable), cubiertas (costo prorrateado por km desde GOMERIA_MONTAJES), mantenimiento y comisión chofer (VIAJES_LOGISTICA). Ranking de unidades caras vs baratas contra el ingreso por km de sus tarifas.
- **Por qué:** Es LA métrica por la que Fleetio/Geotab cobran (cost per mile / TCO, fleetio.com): hoy Vecchi negocia tarifas sin saber el costo real por km de cada unidad. Permite detectar tarifas quebradas, justificar aumentos con números y decidir con datos cuándo renovar un tractor viejo (consumo + mantenimiento crecientes). Junto con el ranking de rentabilidad convierte el sistema en herramienta de pricing, no solo de operación.
- **Cómo:** (1) Prerequisito barato: fix del bug Timestamp vs String en TELEMETRIA_HISTORICO y del kmUnidadAlMontar de gomería (ambos ya ubicados por la auditoría). (2) Cron mensual CF que agrega por patente y escribe COSTOS_FLOTA/{patente_YYYYMM}; precio del litro editable en un doc CONFIG desde el panel. (3) Pantalla 'Costos' con AppDataTable + ranking + export Excel. (4) Cruce con $/km de ingreso por tarifa para pintar margen por unidad.

### Informe ejecutivo mensual automático a gerencia

| Impacto | Esfuerzo | Horizonte |
|---|---|---|
| Alto | Medio | Corto plazo |

- **Qué es:** El día 1 a las 08:00 la gerencia recibe por WhatsApp, sin pedir nada, un resumen generado solo: facturación y margen del mes, viajes concluidos, km de flota, l/100km, ICM de flota, eventos de seguridad Volvo, vencimientos a 30 días y cubiertas críticas, con comparativa contra el mes anterior. Primera versión texto WhatsApp, luego PDF de 1-2 páginas.
- **Por qué:** Es la feature de 'lucirse' por excelencia: convierte todo el trabajo invisible del sistema en un artefacto tangible que circula entre directivos cada mes (un TMS comercial cobra esto por unidad/mes). Ahorra además las horas de Excel de fin de mes y posiciona a Santiago como quien le pone números al negocio, no solo al software.
- **Cómo:** (1) CF mensual que reutiliza agregaciones ya existentes: margen (propuesta de rentabilidad), eficiencia de la vista ejecutiva, cierre ICM_OFICIAL, VOLVO_ALERTAS, calendario de vencimientos, semáforo de gomería. (2) v1: mensaje WhatsApp estructurado vía COLA_WHATSAPP a Molina + quien se defina (revisar el mapa de alertas/destinatarios antes). (3) v2: PDF con pdfkit en Functions o el patrón pdf_printer de adelantos, subido a Storage y enviado como link. Idempotencia por doc-ID mensual.

### Link de seguimiento en vivo para el dador de carga

| Impacto | Esfuerzo | Horizonte |
|---|---|---|
| Alto | Medio | Medio plazo |

- **Qué es:** 'Live Share' criollo: desde el detalle de un viaje, el admin genera un link público con token y vencimiento que muestra en una página web la posición actual de la unidad, el estado del viaje y una ETA aproximada a destino, sin login.
- **Por qué:** Es la feature de cara al cliente de todos los TMS grandes (Samsara Live Sharing, kb.samsara.com). Cada llamada de '¿dónde está el camión?' son minutos del operador; con el link el dador se autogestiona. De cara a gerencia es la demo perfecta: Vecchi dándole a YPF/dadores la visibilidad de un courier — diferencial comercial directo frente a transportistas competidores en la próxima licitación.
- **Cómo:** (1) CF HTTP trackingPublico que valida un token (doc TRACKING_LINKS con viajeId, patente, expiración) y devuelve JSON con la última SITRACK_POSICIONES + estado del viaje — Firestore queda cerrado, todo pasa por la CF. (2) Página estática en Hosting (HTML+JS+Leaflet, mismos tiles del mapa actual) que pollea cada 60 s, servida como cooper-trans.com.ar/t/{token}. (3) Botón 'Compartir seguimiento' en el detalle del viaje que crea el token y copia el link. ETA simple: haversine a la geocerca destino / velocidad promedio reciente.

### Ficha 360 del chofer (scorecard multi-fuente)

| Impacto | Esfuerzo | Horizonte |
|---|---|---|
| Alto | Medio | Medio plazo |

- **Qué es:** Ficha mensual por chofer que unifica en una sola nota lo que hoy vive en 4 módulos: ICM oficial, eco-driving Volvo atribuido por asignación (cruce ASIGNACIONES_VEHICULO × VOLVO_SCORES_DIARIOS), cumplimiento de jornada v3 (bloques/jornadas excedidas) y veracidad de reclamos (veredictos CIERTO/NO_CIERTO de REPORTES_DISCREPANCIA), con tendencia de 6 meses.
- **Por qué:** Ángulo distinto del V1 del roadmap (V1 = tablero de seguridad Volvo): esta es la ficha multi-fuente que el esquema de premios/castigos pendiente necesita como insumo — un número defendible por chofer, imposible de discutir porque GPS, Volvo e YPF dicen lo mismo. Los driver scorecards son EL producto de Samsara/Motive para bajar siniestralidad; acá además define quién recibe el tractor nuevo y el premio anual con datos en vez de percepción.
- **Cómo:** (1) Cron mensual CF que escribe SCORECARD_CHOFER/{dni_YYYYMM}: ICM del cierre mensual, score eco ponderado por días de asignación, contadores de REGISTRO_JORNADAS, ratio de reclamos confirmados. Pesos configurables en doc CONFIG. (2) Reutilizar la exclusión audited-safe del ICM para tanqueros/testers. (3) Pantalla ranking + drill-down con sparkline 6 meses (patrón ya existente en eco-driving) + export Excel para la reunión de premios.

### 'Tu mes' por WhatsApp: resumen de liquidación al chofer

| Impacto | Esfuerzo | Horizonte |
|---|---|---|
| Medio | Bajo | Corto plazo |

- **Qué es:** El día 1 de cada mes cada chofer recibe por WhatsApp su resumen: viajes concluidos, km, monto a cobrar acumulado (montoChoferRedondeado), adelantos descontados y neto estimado. Más una tool del agente IA ('¿cuánto llevo este mes?') para consultarlo on-demand.
- **Por qué:** Transparencia de pago = menos idas y vueltas con el operador (con ~50 choferes, cada duda de liquidación es un mensaje al admin: horas al mes) y menos conflicto al momento del pago porque el chofer vio los números antes. Motive lo vende como driver-pay transparency; acá sale casi gratis porque la liquidación ya está calculada y el canal WhatsApp con cola e idempotencia ya existe. Además empuja la adopción del bot.
- **Cómo:** (1) Cron CF mensual que agrega VIAJES_LOGISTICA + ADELANTOS_CHOFER por DNI y encola un mensaje por chofer en COLA_WHATSAPP (patrón resumenes_diarios, doc-ID determinístico). (2) Nueva tool del agente mi_liquidacion_mes para rol CHOFER usando persona.dni resuelto por identidad (como las 30 tools existentes; actualizar el doc Cerebro del agente). (3) Disclaimer 'estimado, sujeto a cierre' para no comprometer a contabilidad.

### Papeles del camión y del chofer en el bolsillo

| Impacto | Esfuerzo | Horizonte |
|---|---|---|
| Medio | Bajo | Corto plazo |

- **Qué es:** Pantalla 'Mis papeles' en la app del chofer + tool del bot 'mandame los papeles': RTO, seguro y cédula del tractor y enganche asignados, póliza ART y F.931 de su empresa empleadora (EMPRESAS_EMPLEADORAS), listos para mostrar o descargar en un control de ruta.
- **Por qué:** Transporte de combustibles = controles permanentes (CNRT, caminera); un chofer demorado por un papel que no encuentra es un viaje demorado y una multa posible. Los PDFs ya viven en Storage y la cadena chofer→tractor→enganche→empresa ya se resuelve en el sistema. Es valor diario para los 50 choferes — la feature que hace que la app se abra todos los días — y elimina los 'pasame el seguro de la chata' al admin.
- **Cómo:** (1) Pantalla rol CHOFER que resuelve la asignación vigente (AsignacionVehiculoService existente), lista docs del tractor + enganche + empresa con VencimientoBadge, y abre PDFs con el patrón dio + PdfViewer.data ya resuelto para iOS. (2) Tool del agente mis_papeles que reenvía los PDFs como media de WhatsApp o links firmados de Storage. (3) Warning visible si algún documento está vencido para que el chofer avise antes del control.

### Vigía de consumo anómalo (salud mecánica por l/100km)

| Impacto | Esfuerzo | Horizonte |
|---|---|---|
| Medio | Bajo | Corto plazo |

- **Qué es:** Cron que calcula el l/100km móvil de 7 días por tractor desde TELEMETRIA_HISTORICO y alerta al canal de mantenimiento cuando una unidad se desvía >15% de su propia línea base de 60 días, dos días consecutivos.
- **Por qué:** Un tractor que pasa de 35 a 41 l/100km quema ~6 L extra cada 100 km: a 8.000 km/mes son ~480 L/mes desperdiciados por unidad, y casi siempre es síntoma mecánico (filtros, inyectores, fugas) detectable ANTES del service. Geotab/Fleetio venden el fuel-economy monitoring como módulo aparte; acá la serie diaria ya existe. Ángulo distinto del % ralentí del roadmap (V2): esto compara la eficiencia en movimiento contra el patrón histórico propio de cada unidad.
- **Cómo:** (1) Prerequisito compartido con TCO: fix del bug Timestamp vs String en TELEMETRIA_HISTORICO. (2) CF diaria que computa ventanas 7d/60d por patente y, si hay desvío sostenido, encola WhatsApp por el mismo routing de mantenimiento que ya usan AdBlue/tell-tales (blacklist Volvo). (3) Persistir el l/100km semanal en STATS para alimentar una pestaña 'Eficiencia' con ranking en la pantalla de mantenimiento.

### Km reales vs km tarifados (desvíos y km en vacío)

| Impacto | Esfuerzo | Horizonte |
|---|---|---|
| Medio | Medio | Medio plazo |

- **Qué es:** Por cada viaje concluido, comparar los km reales recorridos por GPS/odómetro entre carga y descarga contra los km de la tarifa, flageando desvíos >X%. KPI mensual de km en vacío por tractor (km totales de la unidad − km atribuidos a viajes).
- **Por qué:** Si la tarifa paga 600 km y el recorrido real son 680, Vecchi pierde margen silenciosamente en cada repetición (o hay desvíos no declarados); al revés, km en vacío altos señalan mala asignación de viajes. Es el 'route adherence' de Samsara aplicado a lo que importa acá: el costo. Alimenta la retarificación con datos reales y le da denominador exacto al $/km del TCO.
- **Cómo:** (1) CF on-write (viaje pasa a CONCLUIDO) que toma fechaCarga/fechaDescarga + patente, suma km desde SITRACK_EVENTOS o delta de odómetro de TELEMETRIA_HISTORICO, y persiste kmReales en el doc del viaje. (2) Columna 'desvío %' + card-filtro 'Desviados' en la lista de viajes (patrón cards-filtro admin). (3) Cron mensual de km en vacío por unidad que alimenta el informe ejecutivo.

### Proyección de recambio y compra de cubiertas

| Impacto | Esfuerzo | Horizonte |
|---|---|---|
| Medio | Medio | Medio plazo |

- **Qué es:** Con el desgaste por posición (semáforo de gomería) y el ritmo real de km/día de cada unidad (TELEMETRIA_HISTORICO), proyectar la fecha estimada de recambio de cada cubierta y un agregado de compras: 'en los próximos 60 días vas a necesitar ~N cubiertas de medida/marca X'.
- **Por qué:** Las cubiertas son de los primeros costos de la flota y hoy la compra es reactiva (se cambia cuando está crítica). Anticipar el volumen permite comprar por lote con mejor precio y evita camiones parados por falta de stock. Le da al módulo de gomería ya construido una salida gerencial (presupuesto proyectado de cubiertas) que luce en una reunión de directorio, y se complementa con el costo-por-km de cubierta que la auditoría ya identificó como dato calculable.
- **Cómo:** (1) Prerequisito: fix del bug kmUnidadAlMontar (ya ubicado por la auditoría) para que el desgaste tenga km reales. (2) CF semanal: por montaje activo, vida restante km ÷ km/día promedio de la unidad = fecha estimada de recambio → GOMERIA_PROYECCION. (3) Card en el hub de gomería + lista de compras sugerida con export Excel + línea en el informe ejecutivo mensual.

### Huella de carbono por viaje y por dador (CO2)

| Impacto | Esfuerzo | Horizonte |
|---|---|---|
| Bajo | Bajo | Largo plazo |

- **Qué es:** Cálculo automático de kg de CO2 por viaje, cliente y mes a partir de los litros consumidos (litros × 2,68 kg CO2/L de gasoil), con una línea en el informe ejecutivo y un 'Anexo de emisiones' exportable por dador de carga.
- **Por qué:** Los dadores grandes (YPF primero) ya reportan emisiones Scope 3 y tarde o temprano se lo van a exigir a sus transportistas; tenerlo ANTES de que lo pidan posiciona a Vecchi como transportista premium en una licitación — Geotab y Samsara venden sustainability reports como módulo pago. Costo casi nulo: es una multiplicación sobre datos que ya existen una vez armada la cañería de consumo del TCO.
- **Cómo:** (1) Sumar al cron de costos/eficiencia el cálculo litros × factor de emisión por patente y mes. (2) Atribución a viajes prorrateando por kmReales (propuesta de km reales) o por días de asignación. (3) Columna CO2 en el reporte Excel de consumo existente + export 'Anexo de emisiones por dador' desde la pantalla de rentabilidad.


## Escalabilidad y arquitectura

**Visión:** La base es más sana de lo que el miedo a 'Firebase a escala' sugiere: Functions v2 sobre Node 22, PITR y delete-protection ya activos (verificado con gcloud), cola de WhatsApp desacoplada del bot, agregados STATS precalculados y TTL en las colecciones top. Corrí el censo real (scripts/stats_colecciones.js): 61 colecciones raíz, ~197.600 docs, donde el 70% es SITRACK_EVENTOS (139.488) ya en régimen estacionario gracias a su TTL de 90 días — a escala de 50 choferes y ~55 unidades, Firestore sobra por años. Los riesgos reales son cuatro y ninguno pide re-plataformar: lectores sin límite sobre colecciones que sí crecen (el mapa eco-driving streamea VOLVO_ALERTAS entera: 35.775 docs hoy, ~10× cuando su TTL de 12 meses entre en régimen), una decena de históricas nuevas sin política de retención escrita, la PC dedicada como único camino de salida de WhatsApp, y derivados de negocio (jornadas, ICM, descargas) que dependen de eventos crudos que expiran a los 90 días sin archivo frío. La respuesta correcta para un solo dev es disciplina barata — límites, retención declarada, rollups, failover de canal y un restore ensayado — que además produce frases demostrables ante gerencia ('podemos volver la base a cualquier minuto de la última semana'). Para multi-empresa, el camino es aislamiento físico proyecto-por-cliente con kit de provisioning, no tenancy en rules: con datos de transportistas competidoras, un bug de filtrado sería fatal y la auditoría de seguridad se duplicaría.

### Regla de oro: toda query histórica con límite o rango (+ fix del mapa Volvo)

| Impacto | Esfuerzo | Horizonte |
|---|---|---|
| Alto | Medio | Corto plazo |

- **Qué es:** Barrida única sobre los lectores de colecciones históricas: (1) el stream del mapa eco-driving sobre VOLVO_ALERTAS pasa a rango de fecha + .limit(); (2) los históricos que hoy usan snapshots() (ej. histórico de descargas) pasan a get() one-shot con pull-to-refresh; (3) AppListPage gana un modo paginated con cursor (startAfterDocument + botón 'cargar más') y se adopta en VIAJES_LOGISTICA, WHATSAPP_HISTORICO y GOMERIA_MONTAJES.
- **Por qué:** Es EL ítem de costo/performance accionable hoy. VOLVO_ALERTAS tiene 35.775 docs (censo 2026-06-12) y su TTL es de 12 meses: cuando entre en régimen va a rondar los 300K. Abrir el mapa hoy ya cuesta ~36K lecturas; en régimen serían ~300K por apertura — con 10-20 aperturas diarias son millones de reads/mes (primeros dólares reales que crecen lineales) y, peor para la demo, segundos de spinner y memoria en el cliente. En Windows con persistencia OFF cada reapertura paga la colección completa de nuevo.
- **Cómo:** 1) Mapa: where('creado_en','>=', hoy-7d) + limit(2000) en el stream (la pantalla de lista admin_volvo_alertas_screen.dart ya filtra por día — replicar ese criterio en el mapa de lib/features/eco_driving/). 2) AppListPage (lib/shared/): parámetro paginated:true con cursor, una sola implementación para todas las listas. 3) Convertir streams de históricos a get() one-shot. 4) Dejar escrita la regla en el doc de shared: query a colección con TTL/histórica sin limit ni rango no pasa review. Verificable con un grep de snapshots() sobre colecciones históricas.

### Política de retención unificada + TTLs faltantes

| Impacto | Esfuerzo | Horizonte |
|---|---|---|
| Alto | Bajo | Corto plazo |

- **Qué es:** Una tabla colección → retención → razón (RETENCION.md de una página) y completar los fieldOverrides TTL que faltan. Hoy solo 5 colecciones tienen TTL (SITRACK_EVENTOS 90d, VOLVO_ALERTAS 12m, TELEMETRIA_HISTORICO 18m, COLA/WHATSAPP_HISTORICO). Quedan sin política: SITRACK_IBUTTONS_HISTORICO (6.968 docs y subiendo), AGENTE_CONVERSACIONES (sin TTL y sin rule — ya flaggeado), ZONA_DESCARGA_HISTORICO, AVISOS_AUTOMATICOS_HISTORICO, AUDITORIA_ACCIONES, BOT_EVENTOS/BOT_ACUSES, LOGIN_ATTEMPTS*/PASS_CHANGE_ATTEMPTS. Y declarar explícitamente SIN TTL las de compliance/plata: REGISTRO_JORNADAS, JORNADAS, ICM_OFICIAL*, VIAJES_LOGISTICA, ADELANTOS_CHOFER.
- **Por qué:** El censo da 61 colecciones raíz y ~197.600 docs: chico, pero una decena de históricas crece sin política escrita. Decidir retención 'cuando duela' sale caro dos veces: borrar tarde se cobra (deletes + storage + backups más gordos) y borrar mal es irreversible con usuarios reales en stores. Con TTL nativo el costo de mantenimiento es cero (no hay cron de purga que mantener).
- **Cómo:** El patrón ya existe en el repo: writes que setean expira_en (sitrack.ts:691, telemetria.ts:259) + fieldOverride en firestore.indexes.json. Pasos: 1) replicar expira_en en historico_ibuttons.ts, zonas_descarga.ts, audit.ts y en _loggear() de whatsapp-bot/src/agente.js (24 meses razonable para operativas, 90d para login attempts); 2) backfill con script Node en scripts/ (mismo esqueleto multi-PC que stats_colecciones.js); 3) fieldOverrides + deploy de firestore solo (ojo bug del --only combinado: 2 comandos); 4) RETENCION.md con la tabla, una línea por colección.

### Archivo frío mensual de eventos crudos a GCS (antes de que el TTL los borre)

| Impacto | Esfuerzo | Horizonte |
|---|---|---|
| Alto | Bajo | Corto plazo |

- **Qué es:** Cron mensual que exporta el mes cerrado de SITRACK_EVENTOS (y opcionalmente VOLVO_ALERTAS) a JSONL comprimido en un bucket GCS clase ARCHIVE, antes de que el TTL de 90 días los elimine. Firestore queda liviano; la historia cruda queda re-procesable para siempre.
- **Por qué:** Hay una dependencia arquitectónica sutil: jornadas v3, ICM, descargas y el recorrido histórico del mapa derivan TODOS de SITRACK_EVENTOS, que expira a los 90 días. Los derivados se materializan, pero el crudo es la única prueba re-derivable: disputa laboral por una jornada de hace 8 meses, auditoría YPF, o un bug en el v3 que obligue a recalcular. El backup semanal NO cubre esto (lifecycle de 30 días en el bucket). Costo: storage ARCHIVE ≈ USD 0,0012/GB/mes — el año entero de eventos cuesta centavos. Para una transportista de combustibles, 'tenemos el GPS crudo de cualquier día auditable' es un argumento fuerte ante gerencia.
- **Cómo:** Nueva function onSchedule (día 3 de cada mes, 04:00 ART) en functions/src: query paginada de SITRACK_EVENTOS por rango del mes cerrado → stream a gs://coopertrans-movil-archivo/SITRACK_EVENTOS/AAAA-MM.jsonl.gz usando el bucket del Admin SDK + zlib nativo de Node (cero dependencias nuevas). Persistir conteo y bytes en STATS/archivo para verificación. Script de re-importación filtrada en scripts/ para el día que haga falta. Crear el bucket con clase ARCHIVE y sin lifecycle de borrado.

### DR redondo: lista de backup al día + restore ensayado + verificación automática

| Impacto | Esfuerzo | Horizonte |
|---|---|---|
| Alto | Bajo | Corto plazo |

- **Qué es:** Cerrar las tres puntas flojas del disaster recovery: (a) sumar al collectionIds del backup semanal las colecciones nuevas que faltan (GOMERIA_MONTAJES/POSICIONES_ACTIVAS/CONTEOS, REGISTRO_JORNADAS, AGENTE_CONVERSACIONES, VOLVO_JORNADAS_HISTORICO, PARADAS_REPORTADAS, VACACIONES), (b) hacer UNA VEZ un restore real cronometrado a un proyecto staging y documentarlo en RUNBOOK.md, (c) function post-backup que verifica que el export terminó OK y persiste STATS/ultimo_backup (+ Telegram si falló).
- **Por qué:** Lo caro ya está pago — lo verifiqué con gcloud: PITR ENABLED y delete protection ENABLED en southamerica-east1, backup semanal corriendo. Pero un backup que omite las colecciones de gomería y jornadas (compliance) y que jamás se restauró es una promesa, no un plan. Con esto el RPO queda defendible ante gerencia con una frase: 'podemos volver la base a cualquier minuto de la última semana, y lo ensayamos: tarda N minutos'. Esfuerzo de horas, no de días.
- **Cómo:** 1) Editar la lista explícita en functions/src/mantenimiento.ts:130 cotejándola contra el censo de 61 colecciones (criterio: todo lo que no sea derivable/efímero entra). 2) Drill: gcloud firestore import del export más reciente a un proyecto coopertrans-staging + smoke test de la app apuntando ahí con --dart-define; anotar tiempos en RUNBOOK. 3) onSchedule domingo 09:00 que consulta el estado de la operación de export y escribe STATS/ultimo_backup {ok, colecciones, bytes}; si falla, enviarTelegram() que ya existe en bot_alerta_externa.ts.

### Failover Telegram para avisos críticos cuando el bot está caído

| Impacto | Esfuerzo | Horizonte |
|---|---|---|
| Alto | Bajo | Corto plazo |

- **Qué es:** Cron en Cloud Functions que, si BOT_HEALTH lleva >30 min stale (bot caído), toma de COLA_WHATSAPP los avisos PENDIENTES de orígenes críticos (bypass seguridad DAS/LKS/AEBS, jornada, adelantos) que están por expirar y los reenvía por Telegram a Santiago con el destinatario y texto originales, marcándolos con fallback_telegram:true para no duplicar cuando el bot vuelva.
- **Por qué:** La PC dedicada es el único camino de salida de WhatsApp (SPOF asumido y con mitigaciones organizacionales descartadas — esto es 100% técnico). Hoy, si el bot cae un sábado, el watchdog avisa que murió pero los avisos time-sensitive expiran por TTL y se PIERDEN: el sistema te cuenta que perdió mensajes de seguridad, no los salva. Esto degrada una caída de horas a una molestia. Reuso casi total: es la mejora de resiliencia más barata disponible.
- **Cómo:** Todo el andamiaje existe: BOT_HEALTH + máquina de incidentes pura en bot_alerta_externa.ts, enviarTelegram() ya exportado con secrets configurados, y cada doc de cola ya trae expira_en y origen. Nueva function cada 10 min: si hay incidente activo → query COLA_WHATSAPP estado PENDIENTE + origen en lista crítica + expira_en < now+30min → enviarTelegram con prefijo [FALLBACK — bot caído] + 'para: {nombre} ({telefono})' → update del doc. El consumer del bot ya descarta expirados al reconectar, así que no hay doble envío.

### Censo de colecciones automático + presupuesto GCP con alerta

| Impacto | Esfuerzo | Horizonte |
|---|---|---|
| Medio | Bajo | Corto plazo |

- **Qué es:** Convertir scripts/stats_colecciones.js (creado ayer, lo corrí: 61 colecciones, 197.649 docs) en un cron mensual cloud que guarda STATS/censo_AAAA_MM, compara contra el mes anterior y avisa por WhatsApp/Telegram si una colección creció >40% o apareció una nueva sin TTL declarado. Más un budget alert de GCP (ej. USD 25/mes).
- **Por qué:** Con un solo dev, el modo de falla de costos en Firestore no es el crecimiento orgánico (hoy son centavos) sino el accidente silencioso: un poller en loop, write amplification de un trigger, una query nueva sin límite. Esto lo detecta en días, no en la factura de fin de mes. Y es demostrable ante gerencia: 'el sistema se audita solo el tamaño y el gasto todos los meses'. El censo entero cuesta ~200 reads (aggregate count = 1 read por 1000 docs).
- **Cómo:** 1) Portar el loop de listCollections()+count() a una onSchedule mensual en functions (el código ya está escrito en el script). 2) Diff contra el censo anterior + cruce contra la tabla de RETENCION.md (colección sin política = warning). 3) Aviso vía encolarWhatsApp o enviarTelegram, ambos existentes. 4) gcloud billing budgets create con notificación al mail. Medio día de trabajo.

### Subcolección para documentos que engordan: ICM primero (límite 1 MiB)

| Impacto | Esfuerzo | Horizonte |
|---|---|---|
| Alto | Medio | Medio plazo |

- **Qué es:** Mover las infracciones embebidas de ICM_OFICIAL/{mes} a una subcolección ICM_OFICIAL/{mes}/infracciones/{id}, dejando en el doc padre totales, ranking y severidad por chofer. Después, mismo patrón para el array combinado de vigencias de TARIFAS_LOGISTICA que acumula redundante.
- **Por qué:** Firestore tiene un límite duro de 1 MiB por documento y la auditoría de los scrapers ya midió riesgo real de superarlo en meses intensos de infracciones. Si revienta, el sync de ICM falla exactamente el mes con más datos — y con usuarios reales en App Store/Play no se parchea en caliente (forward-compat: las versiones viejas de la app tienen que seguir leyendo). Migrar hoy son 2 documentos; en un año pueden ser decenas con clientes apuntando a ellos.
- **Cómo:** 1) sitrack_sync/sync_icm.py escribe infracciones a la subcolección y un resumen agregado en el padre (el doc padre mantiene los campos que el ranking ya lee → las pantallas actuales no se rompen). 2) icm_oficial_service.dart trae el detalle on-demand en el drilldown por chofer (query where dni == X sobre la subcolección). 3) Script one-shot que migra los 2 docs ICM_OFICIAL actuales. 4) Los cierres inmutables (ICM_OFICIAL_CIERRE*) no se tocan. Dual-read una versión por los clientes viejos.

### Rollups mensuales precalculados (extender el patrón STATS a series)

| Impacto | Esfuerzo | Horizonte |
|---|---|---|
| Alto | Medio | Medio plazo |

- **Qué es:** Colección AGREGADOS con un doc por dominio y mes (volvo_2026-06, descargas_2026-06, jornadas_2026-06, consumo_2026-06) mantenido por un cron diario incremental: alertas por chofer/tipo, descargas por zona/franja horaria, horas de manejo por chofer, km+litros por unidad. Las pantallas de tendencias leen 12 docs en lugar de escanear miles.
- **Por qué:** Todos los dashboards del roadmap y de la auditoría (tendencia ICM 6 meses, heatmap de descargas, ranking l/100km, digest semanal de seguridad) hoy obligarían a full-scans repetidos sobre colecciones que justamente queremos mantener con TTL. Con rollups: costo de lectura FIJO e independiente del crecimiento, gráficos de 12 meses que abren instantáneos (efecto demo fuerte), y además habilita acortar TTLs crudos sin perder las curvas — la historia condensada vive en el agregado. Es la pieza que hace sostenibles a la mitad de las ideas de las otras áreas.
- **Cómo:** functions/src/dashboard_stats.ts ya implementa el patrón (STATS/dashboard precalculado). Nuevo agregados.ts con onSchedule 03:00 ART que upsertea el mes corriente con merge (idempotente, re-corrible): estructura plana {porChofer: {dni: {total, porTipo}}, porZona: {...}}. Tope de tamaño controlado (50 choferes × pocos campos << 1 MiB). Los widgets fl_chart y sparklines existentes consumen el doc directo. Empezar por UN dominio (Volvo) y clonar.

### Modo ruta: offline-first sistemático para el chofer

| Impacto | Esfuerzo | Horizonte |
|---|---|---|
| Alto | Medio | Medio plazo |

- **Qué es:** Garantizar que las pantallas que el chofer usa en ruta (Mi Equipo, checklist, registro de jornada, recibos de adelantos, vencimientos, reporte de paradas) muestren datos cacheados y encolen escrituras sin señal, con banner honesto de conectividad. No es agregar una librería: es sistematizar lo que ya funciona a medias.
- **Por qué:** Choferes de combustible pasan horas en rutas sin 4G; la primera vez que el checklist 'no carga' en medio del campo, dejan de confiar en la app — y la adopción del canal es lo que la gerencia mira. La base ya está: Firestore móvil persiste por default (solo Windows lo tiene OFF por el workaround) y el checklist ya implementa write con timeout offline (lib/features/checklist/screens/user_checklist_form_screen.dart:167). Falta cerrar los huecos: Storage no cachea PDFs, nada se precarga proactivamente, y no hay feedback de 'estás offline'.
- **Cómo:** 1) Warm-up post-login del chofer: get() de su VEHICULOS/{patente}, sus vencimientos y últimos 5 ADELANTOS_CHOFER para poblar el cache antes de salir a ruta. 2) Recibos PDF: descargar a path_provider con dio y abrir local-first (mismo patrón ya documentado para pdfrx en iOS). 3) connectivity_plus + banner 'sin señal — mostrando datos guardados' en AppScaffold para rol CHOFER. 4) Extender el patrón write-con-timeout del checklist a paradas reportadas y reclamos de jornada. 5) Matriz de prueba en modo avión documentada en DEMO_CHECKLIST.md.

### Spike WhatsApp Business Cloud API solo para salientes críticos

| Impacto | Esfuerzo | Horizonte |
|---|---|---|
| Medio | Medio | Medio plazo |

- **Qué es:** Prueba acotada (1-2 días) de la Cloud API oficial de Meta con un número NUEVO: 3 plantillas utility pre-aprobadas (alerta de seguridad, jornada, vencimiento crítico) enviadas directamente desde Cloud Functions, sin PC dedicada en el medio. Termina en una decisión documentada con costos medidos, no en una migración.
- **Por qué:** Es el único camino para que ningún aviso crítico dependa de la dedicada: whatsapp-web.js no es migrable a cloud sin riesgo serio de ban, y el cachatore ancla la PC igual (necesita IP residencial contra Cloudflare de iTurnos) — así que 'migrar el bot a cloud' completo es la respuesta equivocada. La Cloud API cobra por conversación utility (centavos de USD en AR): para decenas de avisos críticos al mes es plata chica, y el agente conversacional + el grueso del tráfico siguen gratis en el bot actual. Escalona con el failover Telegram: Telegram salva mensajes en caídas; esto saca a los críticos de la PC para siempre.
- **Cómo:** 1) Cuenta WABA en Meta Business con número nuevo (el actual NO se toca: pasarlo a Cloud API mata la sesión de whatsapp-web.js). 2) Registrar 3 plantillas utility. 3) Helper enviarWhatsappCloud() en functions con fetch nativo (sin SDK, mismo estilo que agente.js con Gemini). 4) Piloto: enrutar solo el bypass de seguridad (DAS/LKS/AEBS → Molina) por este canal 1 mes; medir entregabilidad y costo real; decidir ampliar o archivar con números en la mano.

### White-label vendible: proyecto Firebase por cliente + kit de provisioning

| Impacto | Esfuerzo | Horizonte |
|---|---|---|
| Alto | Alto | Largo plazo |

- **Qué es:** Camino arquitectónico para vender el sistema a otras transportistas: cada cliente = SU proyecto Firebase aislado (mismas rules, functions, app), levantado por un script de provisioning en horas. Branding y configuración parametrizados; NADA de tenant_id en la base actual.
- **Por qué:** La alternativa (multi-tenancy en una sola DB) exigiría reescribir las rules y los 53 índices con empresa_id, re-auditar toda la seguridad, y un solo bug filtraría datos ENTRE COMPETIDORAS — inasumible para un dev solo. Proyecto-por-cliente da aislamiento físico total, blast radius cero (un cliente roto no toca a Vecchi), facturación GCP separada por cliente (cada uno paga su consumo, margen transparente), y el free tier arranca de cero en cada proyecto. Para Santiago además es la jugada de carrera: pasa de 'hice una app para Vecchi' a 'tengo un producto deployable'.
- **Cómo:** Por fases y SOLO con un interesado real (la demo actual ya alcanza para vender): 1) Extraer lo hardcodeado a config: branding (paleta/logo) vía --dart-define + flavor; destinatarios WhatsApp ya viven en Firestore (comun.ts los cachea) — bien; credenciales Sitrack/Volvo/YPF como secrets por proyecto (cada cliente trae SUS cuentas). 2) Script provision_cliente.ps1: gcloud projects create → habilitar APIs → firebase deploy rules e indexes y functions (comandos separados por el bug del --only combinado) → seed de catálogos → TTLs → PITR + delete protection. 3) App: flavor por cliente (applicationId propio) — más simple que multi-tenant runtime con Firebase.initializeApp(options:). 4) Bot: instancia NSSM por cliente con su número y sesión en la dedicada (aguanta 2-3; después una mini-PC o VM por cliente). 5) Checklist de lo que NO se transfiere solo: geocercas, números, feriados ya cubiertos por config.


## Herramientas y automatización

**Visión:** El tooling está mejor de lo que el brief asume: ya hay CI de 3 stacks en GitHub Actions (ci.yml con Flutter analyze+test, bot y functions), backup semanal cloud-side, watchdog del bot con Telegram fuera de banda y ~1000 tests. Los huecos reales son de segunda generación: cosas que fallan EN SILENCIO. El backup tiene lista de colecciones hardcodeada que ya quedó desactualizada (5 colecciones afuera), los crons de negocio corren a ciegas (la auditoría encontró 3 fallas silenciosas), los tests Python del cachatore/scrapers no corren en ningún CI, no hay tests de rules pese a que un bug de rules ya llegó a prod (AGENTE_CONVERSACIONES), los secretos viven en archivos locales + Drive personal con el repo PÚBLICO en GitHub al lado, y no hay alertas de presupuesto GCP. La estrategia para un dev solo: automatizar la detección de lo silencioso reusando canales que ya existen (Telegram, COLA_WHATSAPP, Actions gratis en repo público) antes que sumar herramientas nuevas; casi todo lo propuesto cuesta US$0-2/mes y se apoya en piezas ya escritas (stats_colecciones.js, bot_alerta_externa.ts, BOT_HEALTH).

### Cerrar los huecos del CI existente: job Python + higiene de secretos + protección de main

| Impacto | Esfuerzo | Horizonte |
|---|---|---|
| Alto | Bajo | Corto plazo |

- **Qué es:** Sumar al ci.yml actual un 4º job que corra los tests Python hoy huérfanos (cachatore/test_vigia.py, test_iturnos.py, sitrack_sync/test_parser.py, volvo_sync/test_parser.py), un job gitleaks, activar Secret Scanning + Push Protection de GitHub y un ruleset que bloquee force-push/delete en main.
- **Por qué:** El CI valida Flutter/bot/functions pero el sniper de turnos YPF y los parsers ICM/Volvo no se testean en ningún pipeline: una regresión entra silenciosa a la PC dedicada vía auto-update cada 5 min. Y el repo es PÚBLICO con serviceAccountKey.json y claves.json a centímetros del working tree: un git add mal hecho publica las llaves de producción al mundo; Push Protection lo bloquea antes del push. Costo US$0 (Actions ilimitadas en repo público, features de seguridad gratis en públicos). Riesgo cubierto: leak de credenciales con exposición inmediata + regresión del cachatore sin red.
- **Cómo:** (1) Materializar requirements.txt en cachatore/, sitrack_sync/ y volvo_sync/ (hoy no existen — además mejora la reproducibilidad multi-PC); (2) job en ci.yml: setup-python 3.12 + pip install + pytest sobre las 3 carpetas; (3) job con gitleaks/gitleaks-action@v2; (4) GitHub Settings→Code security: Secret scanning + Push protection (2 clics); (5) Settings→Rules: ruleset sobre main con block force pushes + restrict deletions. Medio día total.

### Registro de deploys + detector de drift repo↔producción

| Impacto | Esfuerzo | Horizonte |
|---|---|---|
| Medio | Bajo | Corto plazo |

- **Qué es:** Cada firebase deploy escribe en Firestore (META/deploys) el commit SHA, target y hostname; un workflow scheduled diario compara ese SHA contra origin/main y avisa por Telegram si hay commits en functions/ o firestore.rules sin deployar hace más de 24 h.
- **Por qué:** El deploy es manual por decisión consciente (documentada en ci.yml) y Santiago trabaja desde 2 PCs: el modo de fallo real es 'pusheé desde casa pero no deployé' o 'deployé desde la PC con código viejo'. Prod y repo divergen sin que nadie lo note hasta que un fix 'no anda' — horas de debugging fantasma. También materializa el audit log de deploys que pidió la auditoría infra-config. El gotcha conocido de --only a,b (deploya solo el primero en silencio) se vuelve visible porque el registro es por target.
- **Cómo:** (1) postdeploy hook en firebase.json que corre node scripts/registrar_deploy.js (Admin SDK con el patrón scripts/_lib/firebase_creds ya existente) escribiendo {sha, fecha, target, hostname}; (2) workflow drift.yml con schedule diario: lee el doc con una SA read-only en secrets, compara contra git log -1 --format=%H -- functions/ firestore.rules; si difiere >24 h, llama al webhook de Telegram (reusar bot_alerta_externa) o falla el run para que GitHub mande mail. 3-4 horas.

### Backups v2: PITR + censo anti-drift de colecciones + simulacro de restore

| Impacto | Esfuerzo | Horizonte |
|---|---|---|
| Alto | Bajo | Corto plazo |

- **Qué es:** Activar Point-in-Time Recovery de Firestore (recupera a cualquier minuto de los últimos 7 días), pasar el export de semanal a diario, agregar un check automático que compare la lista hardcodeada de collectionIds del backup contra db.listCollections() real (alerta si una colección nueva quedó afuera), y hacer UNA vez un simulacro de restore cronometrado documentado en RUNBOOK.
- **Por qué:** El modo de fallo ya ocurrió: la auditoría encontró 5 colecciones nuevas FUERA del backup — el comentario del código dice 'cualquier colección nueva debe sumarse acá' y no se sumaron. Además el RPO actual es 7 días: un cascade buggy (renombrarEmpleadoDni incompleto, también señalado) o un borrado desde Console puede costar una semana de liquidaciones. PITR baja el RPO a 1 minuto por ~US$0.18/GiB-mes (DB chica: centavos); exports diarios con lifecycle 30 días ≈ US$1-2/mes. Y un backup jamás restaurado no es un backup: el drill convierte 'creemos que hay backup' en 'sabemos restaurar en N minutos' — argumento de oro ante la gerencia para un sistema que liquida plata.
- **Cómo:** (1) gcloud firestore databases update --enable-pitr; (2) cambiar schedule de backupFirestoreScheduled a '0 6 * * *'; (3) dentro del mismo cron, antes del export: listCollections() vs collectionIds → faltantes no whitelisteados = alerta Telegram (la lógica de censo ya está escrita en scripts/stats_colecciones.js, es portarla a la function); (4) drill semestral: gcloud firestore import del último export a un proyecto demo gratuito o al emulador (emulators:start --import), cronometrar y documentar en la sección DR del RUNBOOK. Medio día + 2-3 h de drill.

### Alertas de presupuesto y consumo GCP/Firebase

| Impacto | Esfuerzo | Horizonte |
|---|---|---|
| Medio | Bajo | Corto plazo |

- **Qué es:** Budget de GCP Billing con alertas a 50/90/100% del presupuesto mensual + umbral de lecturas/escrituras Firestore diarias (vía Cloud Monitoring o embebido gratis en el verificador de crons de la propuesta 5).
- **Por qué:** Hoy un loop en un cron, una query full-scan nueva (la auditoría encontró varias sin límite) o un retry storm convierte el plan Blaze en una factura de cientos de dólares que se descubre a fin de mes — el incidente Firebase clásico que en foros termina en US$1000+. El budget alert es gratis y tarda 10 minutos; la detección intradía cuesta ~US$1.50/condición-mes con el pricing 2026 de Monitoring, o US$0 si el cron verificador propio lee la métrica de read_count y alerta por el canal existente.
- **Cómo:** (1) Console Billing→Budgets: presupuesto mensual (p.ej. US$50) con thresholds 50/90/100 a santiagocoopertrans@gmail.com; (2) opcional: topic Pub/Sub del budget → function chica que manda Telegram (canal ya armado); (3) para intradía: condición de Monitoring sobre firestore.googleapis.com/document/read_count, o leer esa métrica con la client library desde el cronWatchdog y alertar si supera N×promedio. 1-2 horas.

### "Cron de los crons": heartbeats por cron crítico + verificador con alerta

| Impacto | Esfuerzo | Horizonte |
|---|---|---|
| Alto | Medio | Corto plazo |

- **Qué es:** Cada cron de Cloud Functions (cierre de reclamos 08:00, batch jornadas v3, resúmenes diarios, pollers, backup) escribe un latido en CRON_HEALTH/{id} con ultimo_ok/ultimo_error; una function verificadora (cada 6 h) chequea staleness contra la frecuencia esperada de cada uno y avisa por WhatsApp al admin + Telegram si alguno no corrió o viene fallando.
- **Por qué:** Es el hueco que la auditoría repite en TRES áreas: 'cierreActivo falla silencioso', 'alerta temprana si el batch v3 no escribió datos', 'si stats.errores>0 nadie lo ve'. El patrón ya existe para el bot (BOT_HEALTH + watchdog + Telegram fuera de banda) pero los ~12 crons de negocio corren a ciegas — y el cierre automático de reclamos tuvo su primera corrida HOY: si falla mañana, reclamos de choferes quedan sin responder y nadie se entera. Costo de reconstruir días de datos no procesados (jornadas, descargas, ICM) >> 1 día de implementación. Además deja el sistema 'enterprise-grade' demostrable: panel de salud de todos los procesos automáticos.
- **Cómo:** (1) Helper latido(id, ok, detalle) en functions/src/comun.ts (write merge, costo despreciable); (2) una línea al final del try y del catch de cada cron (~12 archivos tocados); (3) function cronWatchdog onSchedule cada 6 h con mapa {id: maxStalenessHoras} → si stale o error reciente, encolar en COLA_WHATSAPP + Telegram vía bot_alerta_externa.ts; (4) test de la lógica pura de staleness (patrón ganador ya establecido); (5) opcional después: pintar CRON_HEALTH con AppServiceCard en el panel admin de estado del sistema. 1 día.

### Dead-man's switch externo para la PC dedicada (Healthchecks.io)

| Impacto | Esfuerzo | Horizonte |
|---|---|---|
| Medio | Bajo | Corto plazo |

- **Qué es:** Cuenta gratuita de Healthchecks.io (20 checks): cada servicio NSSM de la dedicada (bot, cachatore-vigia, scrapers, tarea de auto-update) pingea su URL al completar cada loop; si un check no pingea en el período esperado, Healthchecks manda mail/Telegram — desde infraestructura ajena a Firebase y a la propia PC.
- **Por qué:** El watchdog actual (CF lee BOT_HEALTH → Telegram) cubre el bot, pero depende de que Cloud Functions, Firestore y el propio watchdog estén sanos, y no cubre los scrapers ni el auto-update (si el git pull se rompe, la dedicada corre código viejo indefinidamente sin síntomas). Un dead-man's switch de tercero es la red bajo la red: corte de luz largo, disco lleno, NSSM en crash-loop, Tailscale caído. El bot es la cara del sistema ante los 50 choferes: un fin de semana caído sin aviso es el peor escenario reputacional. Costo US$0, una tarde de trabajo.
- **Cómo:** (1) Crear 4-6 checks con períodos acordes (bot 10 min, vigia 10 min, scrapers según su frecuencia, auto-update 30 min); (2) agregar al final de cada loop/tarea un fetch (Node) o Invoke-RestMethod (PowerShell) a https://hc-ping.com/<uuid> — 1 línea por servicio, fire-and-forget con try/catch; (3) canales de notificación: email + la integración Telegram nativa de Healthchecks apuntando al bot ya configurado; (4) documentar los UUIDs en el runbook de la dedicada y en Secret Manager.

### Renovate + Dependabot alerts para las 4 superficies de dependencias

| Impacto | Esfuerzo | Horizonte |
|---|---|---|
| Medio | Bajo | Corto plazo |

- **Qué es:** Activar Dependabot security alerts (gratis) y la app Mend Renovate con config que agrupa actualizaciones en un PR mensual por stack — pub (Flutter), npm (functions y bot), pip (Python) — respetando los pins conocidos del proyecto.
- **Por qué:** Cuatro ecosistemas con deps sensibles (whatsapp-web.js se rompe cuando WhatsApp cambia el DOM, firebase-admin, plugins Firebase de Flutter) y hoy se actualizan cuando Santiago se acuerda: o big-bang doloroso cada 6 meses, o CVEs sin enterarse en el bot que maneja datos de 50 empleados. Con el CI existente cada PR de Renovate llega pre-validado por los ~1000 tests: mergear es 1 clic informado. Costo US$0.
- **Cómo:** (1) Settings→Code security: Dependabot alerts ON; (2) instalar la GitHub App de Renovate (gratis); (3) renovate.json: schedule mensual, groupName por stack, packageRules con ignore de firebase_storage >13.0.4 (pin Windows C2039 documentado) y majors de cloud_firestore (bugs Windows conocidos) y de Flutter SDK (pineado 3.44.0 en ci.yml a propósito); (4) requiere los requirements.txt de la propuesta 1 para cubrir Python. SIN auto-merge: revisar a mano con el semáforo del CI. 2-3 horas.

### Cobertura de tests medida y visible en el CI

| Impacto | Esfuerzo | Horizonte |
|---|---|---|
| Medio | Bajo | Corto plazo |

- **Qué es:** Agregar medición de cobertura a los jobs existentes: flutter test --coverage, node --test --experimental-test-coverage (nativo en Node 22, cero dependencias nuevas) para bot y functions, pytest --cov para Python; resumen por stack en el job summary de Actions + lcov como artifact.
- **Por qué:** Hay ~1000 tests pero nadie sabe qué % del código CRÍTICO cubren ni si el número sube o baja — la auditoría detectó el desbalance (backend de jornadas/alertas en functions casi sin cobertura vs Flutter maduro). Medir convierte 'habría que testear más' en 'volvo.ts 0%, calculos_viaje 95%' y habilita el ratchet (nunca bajar del último número). También es un KPI mostrable a gerencia: 'el sistema que liquida los viajes tiene X% de cobertura automática'. Gratis, sin servicios externos (y Codecov sería gratis igual por ser repo público).
- **Cómo:** (1) Job Flutter: flutter test --coverage + script de 10 líneas que resume lcov.info en GITHUB_STEP_SUMMARY; (2) bot y functions: node --test --experimental-test-coverage --test-reporter=lcov --test-reporter-destination=cov.lcov además del reporter normal; (3) pytest --cov=. --cov-report=term en el job Python nuevo; (4) upload-artifact de los lcov; opcional: badge en README con dynamic-badges-action. Medio día.

### Suite de integración sobre Firebase Emulator: tests de rules + ensayo de crons con seed real

| Impacto | Esfuerzo | Horizonte |
|---|---|---|
| Alto | Medio | Medio plazo |

- **Qué es:** Infraestructura de tests de integración: firebase emulators:exec en CI con (a) tests de firestore.rules usando @firebase/rules-unit-testing y (b) capacidad de sembrar el emulador con un export real del backup (emulators:start --import) para ensayar crons críticos contra data realista sin tocar producción.
- **Por qué:** El bug de AGENTE_CONVERSACIONES (colección sin regla → todo el dashboard del agente con permission-denied EN PROD) lo atrapaba un test de rules de 10 líneas antes del deploy. Y los crons de plata/jornada hoy solo se prueban contra prod: el cierre automático de reclamos se estrenó directo con choferes reales. Es LA infraestructura que falta para atacar el hueco #1 de la auditoría de tests (functions sin cobertura de integración y rules sin tests), con sinergia directa: el seed usa el mismo export de la propuesta 3 y de paso valida el backup. Gratis.
- **Cómo:** (1) firebase.json: sección emulators (firestore, auth, storage); (2) functions/test_rules/ con @firebase/rules-unit-testing: casos chofer-no-lee-DNI-ajeno, SUPERVISOR vs ADMIN, y un test generado desde AppCollections que falle si una colección usada por la app no matchea ninguna regla (anti-regresión del bug del agente); (3) npm run test:rules = firebase emulators:exec --only firestore 'node --test test_rules/'; (4) job CI con cache del emulador; (5) para crons: gsutil cp del export → import al emulador → ejecutar la función con FIRESTORE_EMULATOR_HOST seteado. Nota: el pin firebase_storage 13.0.4 de Windows no afecta nada de esto (es del plugin C++ de Flutter, no del emulador). 1-2 días.

### GCP Secret Manager como fuente única de secretos + bootstrap multi-PC

| Impacto | Esfuerzo | Horizonte |
|---|---|---|
| Alto | Medio | Medio plazo |

- **Qué es:** Migrar claves.json, serviceAccountKey.json, .env del bot y credenciales de scrapers a Secret Manager; un scripts/bootstrap_secretos.ps1 que arma cualquier PC nueva con un comando; defineSecret en functions v2 para tokens de terceros; la copia en Google Drive se elimina (o queda solo cifrada con age como respaldo offline).
- **Por qué:** Hoy la fuente de verdad de TODAS las llaves de producción es archivos sueltos + un Drive personal: una sesión de Google comprometida regala la base entera de la empresa, sin registro de acceso ni rotación. Con Secret Manager hay IAM + audit log de cada lectura, versionado para rotar sin drama, y el flujo multi-PC real de Santiago (casa/oficina/dedicada) pasa de 'copiar archivos del Drive a mano' a 1 comando con gcloud auth. Costo: ~10-15 secretos ≈ US$0.5-1/mes (las primeras 6 versiones activas son gratis). Complementa la propuesta 1: aquella cubre el push accidental, esta el almacenamiento y la distribución.
- **Cómo:** (1) gcloud secrets create por unidad lógica (bot-env, sa-key, sitrack-creds, volvo-creds, ftp-web); (2) bootstrap_secretos.ps1: loop de gcloud secrets versions access latest --secret=X > ruta destino, respetando el layout actual que los scripts ya esperan (_lib/firebase_creds sigue funcionando igual); (3) en functions: defineSecret para el token de Telegram y APIs externas en vez de config plana; (4) la dedicada ya tiene credenciales gcloud — agregar el bootstrap al arranque o correrlo manual tras rotaciones; (5) validar todo y recién entonces borrar las copias de Drive. 1-2 días, migrable de a un secreto por vez sin big-bang.

### IA de guardia: review post-push de módulos sensibles + estado semanal automático

| Impacto | Esfuerzo | Horizonte |
|---|---|---|
| Medio | Medio | Medio plazo |

- **Qué es:** Dos workflows con Claude en GitHub Actions: (a) en cada push a main que toque functions/src, lib/features/logistica o firestore.rules, un job corre claude -p con prompt de revisión enfocada SOLO en bugs graves de plata/permisos/datos y comenta el commit únicamente si encuentra algo; (b) un scheduled de lunes 08:00 que resume los commits de la semana y lo appendea a ESTADO_PROYECTO.md con commit automático.
- **Por qué:** Santiago pushea directo a main sin segundo par de ojos (bus factor 1, y el proyecto define su continuidad laboral): un revisor asíncrono que solo habla ante severidad alta es el punto medio realista entre 'nada' y 'PRs que un dev solo nunca va a abrir'. Y ESTADO_PROYECTO.md ya tuvo una laguna de 3 semanas justo en el período de más actividad — la auditoría docs-onboarding pidió exactamente este auto-resumen; es el documento de handoff si mañana otro tiene que tomar el sistema. Costo: con CLAUDE_CODE_OAUTH_TOKEN de la suscripción existente, US$0 extra; vía API estimado US$5-15/mes según volumen de pushes (el resumen semanal solo: <US$1/mes).
- **Cómo:** (1) Workflow con anthropics/claude-code-action@v1 (o claude CLI pelado), paths filter sobre los módulos sensibles, prompt acotado tipo 'diff de este push: reportá SOLO bugs de severidad alta en dinero/permisos/datos; si no hay, respondé OK' → gh api repos/.../commits/{sha}/comments si hay hallazgos; (2) workflow cron semanal: git log --since='7 days' --stat → claude -p 'resumí en el formato de ESTADO_PROYECTO.md' → append + push con [skip ci] (y excepción en el ruleset para el bot). Empezar solo con (b) para calibrar tono y costo, sumar (a) después. 1 día.

### SCHEMA_FIRESTORE.md autogenerado desde la base real + checks de frescura de docs

| Impacto | Esfuerzo | Horizonte |
|---|---|---|
| Medio | Bajo | Corto plazo |

- **Qué es:** Extender el scripts/stats_colecciones.js recién escrito (censo de colecciones + conteos, read-only) para que además samplee 2-3 docs por colección e infiera campos y tipos, cruce con firestore.indexes.json, y emita docs/SCHEMA_FIRESTORE.md; corre mensual por workflow (o como paso post-release). Más un check de CI que falle si la versión del README difiere de pubspec.yaml.
- **Por qué:** No existe mapa de colecciones en ningún lado del repo — hallazgo de impacto alto de la auditoría de docs y EL documento que cualquier dev (o Claude) nuevo necesita primero: con bus factor 1, es seguro de vida del proyecto. Escribirlo a mano garantiza que quede stale; generado desde producción real nunca miente y de paso alimenta decisiones de TTL/costos (para eso nació el censo). La semilla ya está commiteada — el esfuerzo incremental es chico. El check README-vs-pubspec son 5 líneas y mata el drift de versión ya detectado.
- **Cómo:** (1) Extender stats_colecciones.js: por colección .limit(3).get() → unión de keys con tipo inferido (Timestamp/string/number/map/array) marcando opcionales, + conteo del censo + índices de firestore.indexes.json + flag 'usada por la app' cruzando con AppCollections de lib/; (2) emitir markdown con una tabla por colección y fecha de generación; (3) workflow mensual con SA read-only en secrets que corre el script y commitea solo si hay diff (alternativa cloud-first preferida sobre atarlo a una PC); (4) en ci.yml: step que greppea la versión en README.md y la compara con pubspec.yaml → exit 1 si difieren. Medio día a 1 día.

### Sentry en el bot Node: visibilidad de errores no-fatales de la dedicada

| Impacto | Esfuerzo | Horizonte |
|---|---|---|
| Medio | Bajo | Corto plazo |

- **Qué es:** Integrar @sentry/node en el bot de WhatsApp (mismo proyecto Sentry y cuota de 5K eventos/mes ya gestionada), con sampleo y beforeSend agresivos al estilo del cliente Flutter, capturando las excepciones que hoy solo van al log local: fallos de tools del agente Gemini, errores del cron interno de avisos, rechazos de envío.
- **Por qué:** La auditoría de bot-features lo dijo textual: 'los errores solo van al log de la PC dedicada — si nadie mira el log, los avisos perdidos pasan desapercibidos'. El watchdog detecta bot MUERTO pero no bot DEGRADADO (30% de envíos fallando, una tool del agente rota tras un cambio de Gemini, avisos de vencimiento que no salen). Sentry agrupa, deduplica y avisa por mail con stack trace, diagnosticable desde cualquier PC sin RDP a la dedicada — clave en el flujo multi-PC. Costo US$0 dentro de la cuota free ya filtrada.
- **Cómo:** (1) npm i @sentry/node en whatsapp-bot; (2) Sentry.init en src/index.js con el DSN del proyecto existente, sampleRate bajo para no-fatales y beforeSend que filtre el ruido esperable de whatsapp-web.js (desconexiones, Protocol error al reiniciar Chrome); (3) Sentry.captureException en los catch de message_handler.js, agente.js y cron.js que hoy solo logean; (4) tags plataforma:bot y release = SHA corto del git pull del auto-update, para correlacionar errores con la versión desplegada en la dedicada. 2-3 horas.


## Experiencia de usuario

**Visión:** El sistema tiene un design system maduro (Núcleo: AppScaffold/AppStates/skeletons, command palette Ctrl+K, banner de conexión lenta, borradores auto-guardados) — nivel raro de pulido para un solo dev. El desequilibrio UX está en tres frentes: (1) el chofer es consumidor pasivo — ve papeles y jornada, pero lo que más le importa (cuánto cobra, sus adelantos, su recibo) no existe en la app y termina en llamadas al encargado o al bot; (2) el loop aviso→acción está cortado: WhatsApp avisa pero no abre la app (sin deep links, sin FCM), así que cada aviso exige navegar a mano; (3) en desktop, el operador único carga viajes recurrentes desde cero y navega 15 secciones sin atajos de acción. Además, el theme oscuro (#050505) es el peor caso para leer al sol arriba del camión, y la app no maneja textScaler para choferes mayores. La base técnica para resolver casi todo ya existe: es cuestión de cerrar loops, no de construir infraestructura nueva.

### Portal del chofer: "Mis viajes y mi plata"

| Impacto | Esfuerzo | Horizonte |
|---|---|---|
| Alto | Medio | Corto plazo |

- **Qué es:** Pantalla read-only en el home del chofer con sus viajes del mes (monto chofer por tramo, estado liquidado/pendiente), sus adelantos con recibo PDF descargable, y el total estimado de la quincena/mes. Mismo patrón que "Mi jornada" (transparencia de datos propios).
- **Por qué:** Hoy el chofer NO ve nada de su liquidación en la app (verificado: user_mi_perfil_screen no tiene adelantos/recibos; solo el bot responde consultas). Con ~50 choferes preguntando 'cuánto me toca' 1-2 veces/mes al encargado (~5 min c/u), son 5-8 h/mes de interrupciones que desaparecen. Es además el feature con más impacto de adopción: le da al chofer una razón para abrir la app todas las semanas, y ante gerencia demuestra transparencia salarial (menos conflictos de liquidación).
- **Cómo:** 1) Nueva pantalla lib/features/logistica/screens/user_mis_viajes_screen.dart calcada del patrón mi_jornada_screen.dart (AppScaffold + StreamBuilder + AppStates). 2) Query VIAJES_LOGISTICA where choferDni==dni, orderBy fechaCarga desc, limit 50 + índice compuesto. 3) Rule Firestore read-own por DNI (mismo patrón que REGISTRO_JORNADAS ya tiene). 4) Adelantos: ADELANTOS_CHOFER ya tiene el recibo PDF en Storage — render con preview_screen + pdfrx (en móvil descargar con dio y PdfViewer.data, según el pin conocido). 5) Decisión de negocio a validar con Santiago: mostrar montos solo de viajes CONCLUIDOS, con badge 'estimado' hasta que liquidado=true, para no generar reclamos sobre especulaciones. Tile nuevo en main_panel.dart gateado a AppRoles.tieneVehiculo.

### Bandeja "Hoy" accionable en el dashboard admin

| Impacto | Esfuerzo | Horizonte |
|---|---|---|
| Alto | Medio | Corto plazo |

- **Qué es:** Franja superior del panel admin con los pendientes operativos cross-módulo que requieren acción humana: reclamos de jornada sin revisar, adelantos PENDIENTES >48h, bandeja de ambiguos del bot, revisiones de documentos, alertas Volvo HIGH del día, viajes EN_CURSO estancados >N días y primer viaje del mes sin liquidar. Cada card navega directo a la pantalla que resuelve.
- **Por qué:** El dashboard actual muestra KPIs (espejo) pero no dice QUÉ hacer hoy (cockpit). Con 15 secciones en el shell, los pendientes quedan enterrados: un adelanto sin aprobar o un reclamo de jornada olvidado se descubre tarde. Para un único operador, la bandeja única es la diferencia entre revisar 7 pantallas cada mañana y revisar 1. Es además LA pantalla para mostrar a gerencia: 'el sistema me dice cada mañana qué está pendiente y nada se pierde'.
- **Cómo:** Todo es data existente: REPORTES_DISCREPANCIA (pendientes), ADELANTOS_CHOFER (estado PENDIENTE + creado_en), bandeja ambiguos del bot, REVISIONES, VOLVO_ALERTAS, VIAJES_LOGISTICA (EN_CURSO + fechaCarga; CONCLUIDO + liquidado=false del mes anterior). Implementar como fila de cards-filtro en admin_panel_screen.dart siguiendo el patrón aprobado de cards-filtro admin (los KPIs SON el filtro), cada una con count en vivo (streams con limit) y onTap → Navigator a la sección. Ocultar cards en cero para que la franja sea corta. Fase 2 opcional: badge agregado en el tile 'Panel de control' del home.

### Carga de viaje en 30 segundos: duplicar viaje + tarifas frecuentes

| Impacto | Esfuerzo | Horizonte |
|---|---|---|
| Alto | Bajo | Corto plazo |

- **Qué es:** Acción 'Duplicar' en la lista/detalle de viajes que pre-carga un viaje nuevo con chofer, unidad, tramos y tarifas del original (fechas vacías, remito vacío); más, en el alta, al elegir chofer, sugerir su último circuito ('¿Repetir Profertil–B.Blanca, 2 tramos?') y mostrar sus 3 tarifas más usadas arriba del picker.
- **Por qué:** Cargar un viaje multi-tramo es el flujo más frecuente del back-office y hoy arranca SIEMPRE de cero (form de 6 secciones, verificado en logistica_viaje_form_screen.dart). Los viajes de combustible son circuitos repetitivos: si el 60-70% repite ruta, duplicar ahorra 3-4 min por viaje → con ~80-100 viajes/mes son 4-6 h/mes del operador, y baja errores de selección de tarifa (que pegan directo en la liquidación).
- **Cómo:** 1) En logistica_viajes_lista_screen y el detalle: acción 'Duplicar' que abre LogisticaViajeFormScreen con un constructor nuevo (viajeOrigen) — los tramos ya viven como snapshots en el doc, es hidratar _tramos desde ahí re-resolviendo la tarifa vigente por tarifaId (NO copiar montos viejos: recalcular con la vigencia actual, el form ya lo hace). 2) En _abrirSelectorTarifa (logistica_viaje_form_tarifa_picker.dart): sección 'Frecuentes de este chofer' con query one-shot a VIAJES_LOGISTICA últimos 90 días agrupada client-side por tarifa_snapshot.tarifaId. 3) Cuidado con el borrador auto-guardado: duplicar debe pisar el borrador 'nuevo' explícitamente (confirmación si había uno).

### Deep links: del aviso de WhatsApp a la pantalla exacta en 1 tap

| Impacto | Esfuerzo | Horizonte |
|---|---|---|
| Alto | Medio | Medio plazo |

- **Qué es:** App Links (Android) + Universal Links (iOS) sobre el dominio ya activo: cada aviso del bot termina con un link tipo cooper-trans.com.ar/app/ir/vencimientos que abre la app directo en la pantalla pertinente (vencimiento → Mis vencimientos; jornada cerrada → Mi jornada; adelanto acreditado → recibo; revisión aprobada → Mi perfil).
- **Por qué:** Hoy el aviso de WhatsApp dice 'entrá a la app a verlo' y el chofer (algunos con poca soltura digital) tiene que encontrar la app, loguearse y navegar — muchos no lo hacen y vuelven a preguntar por WhatsApp. Cerrar el loop aviso→acción en 1 tap multiplica el valor de TODO el sistema de avisos ya construido (vencimientos, jornadas, adelantos, turnos YPF) sin tocar su lógica. Verificado: hoy no hay ningún intent-filter VIEW en el AndroidManifest ni paquete de deep links en pubspec.
- **Cómo:** 1) Servir /.well-known/assetlinks.json y apple-app-site-association desde Firebase Hosting (cooper-trans.com.ar ya está en el proyecto). 2) Paquete app_links + intent-filter autoVerify en AndroidManifest + Associated Domains en el entitlement iOS (Xcode Cloud ya firma). 3) Router: mapear /app/ir/{destino} a AppRoutes existentes, con guard de sesión (si no está logueado, login → redirect). 4) Bot: en aviso_builder.js agregar el link según origen del aviso (tabla origen→destino, 20 líneas). 5) Fallback: la misma URL sirve una página estática 'Abrí la app / descargala' para PCs o teléfonos sin la app (la landing /app ya existe).

### Push FCM selectivo + matriz de canales (push vs WhatsApp)

| Impacto | Esfuerzo | Horizonte |
|---|---|---|
| Alto | Alto | Medio plazo |

- **Qué es:** Incorporar firebase_messaging SOLO para eventos puntuales time-sensitive: turno YPF conseguido/reagendado (cachatore), cambio de rol/sesión, y failover de avisos críticos cuando el bot está caído. WhatsApp queda como canal conversacional y de resúmenes. Documentar la matriz evento→canal para que cada feature nueva no re-decida ad-hoc.
- **Por qué:** Todo el sistema de avisos depende de UNA PC dedicada 24/7 (bus factor #1 reconocido): si el bot cae, hoy solo Santiago se entera (Telegram), y los choferes quedan ciegos. El push da un canal de respaldo institucional que no depende de esa PC, llega aunque WhatsApp esté silenciado, y combinado con deep links abre la app en la pantalla correcta. Para el turno del cachatore (drop race con minutos de ventana), push es objetivamente el canal correcto: la latencia de la cola WhatsApp puede costar el turno informado tarde.
- **Cómo:** 1) firebase_messaging en pubspec + token por dispositivo en EMPLEADOS/{dni}/dispositivos (limpieza de tokens muertos en el cron diario). 2) Helper enviarPush() en functions/comun importable por cachatore-nube, jornadas y el watchdog del bot (la máquina de estados de bot-health ya detecta caída → ahí se re-rutean los críticos). 3) iOS: APNs key en la cuenta Apple ya activa. 4) Notificación con payload de ruta → reusa el router de deep links (propuesta anterior). 5) Regla de diseño escrita en docs/: push = evento puntual urgente que abre pantalla; WhatsApp = conversación, confirmaciones y resúmenes; ambos = crítico. Hacerlo DESPUÉS de deep links para que cada push aterrice bien.

### Modo offline percibido: "guardado en tu teléfono" en vez de spinner

| Impacto | Esfuerzo | Horizonte |
|---|---|---|
| Alto | Medio | Corto plazo |

- **Qué es:** Sistematizar la experiencia sin señal del chofer: banner global 'Sin conexión — mostrando datos guardados' en el shell del chofer (connectivity_plus), y en las escrituras (checklist, reportar parada) confirmación optimista inmediata con estado 'Guardado en el teléfono — se envía cuando haya señal' + indicador de pendientes, en vez de await que cuelga el botón.
- **Por qué:** El chofer en ruta CON señal intermitente es el caso de uso central, no el borde. Firestore ya encola writes offline y tiene persistencia local en móvil — el problema es que la UI no lo cuenta: un await que no resuelve se percibe como 'la app no anda' y el chofer reintenta o abandona (checklist a medias, paradas sin reportar). Decir la verdad ('quedó guardado, se manda solo') convierte la misma capacidad técnica en confianza. El AppOfflineBanner existente cubre lecturas lentas por stream; falta el caso write y el estado global.
- **Cómo:** 1) connectivity_plus + wrapper en el shell del chofer que muestra el banner global (reusar el estilo slim 28px de AppOfflineBanner). 2) En user_checklist_form_screen y reporte de paradas: no esperar el write para confirmar — write sin await + UI optimista con badge 'pendiente de envío' que se limpia cuando el snapshot confirma (snapshot.metadata.hasPendingWrites, API ya disponible). 3) Patrón documentado en lib/shared (OfflineAwareSubmit) para reusar en futuros forms del chofer. 4) Verificar que las pantallas de consulta del chofer (vencimientos, jornada, mi equipo) rendericen cache antes que spinner (Firestore lo da gratis si no se fuerza Source.server).

### Accesibilidad chofer: letra del sistema, targets 48dp y legibilidad al sol

| Impacto | Esfuerzo | Horizonte |
|---|---|---|
| Medio | Medio | Medio plazo |

- **Qué es:** Pasada de accesibilidad sobre las 6 pantallas del chofer: respetar el tamaño de letra del sistema hasta 1.3× sin overflow, targets táctiles mínimos de 48dp, y una opción 'modo exterior' de alto contraste claro (manteniendo el brand cobalto) para uso al sol arriba del camión.
- **Por qué:** Choferes de edad variada, algunos con presbicia, configuran letra grande en Android — y la app hoy no maneja textScaler en ningún lado (verificado: cero matches de textScaler/textScaleFactor en lib/), o sea que escala sin control y puede romper layouts, o peor, alguien lo clampa a 1.0 y los deja sin su letra. Además el theme es oscuro puro (#050505, verificado en app_colors.dart): con sol directo y reflejos, fondo oscuro es el peor caso de legibilidad — y estos usuarios consultan la app EN el camión. Accesibilidad acá no es checkbox: es adopción real del 20-30% de la nómina con menos soltura visual/digital.
- **Cómo:** 1) MaterialApp.builder con textScaler clamp(1.0, 1.3) + auditar overflow corriendo la app a 1.3 (las 9 reglas anti-overflow ya existentes ayudan; arreglar lo que explote). 2) Subir AppType.label/monoSm en pantallas chofer donde quedó <13px efectivos. 3) Verificar targets: tiles del main_panel ya son generosos; revisar iconos 14px y rows tappeables de mis_vencimientos. 4) 'Modo exterior': ColorScheme claro derivado de la paleta cobalto existente, toggle en Mi perfil, SOLO shell chofer — NO tocar el brand aprobado sin validación de Santiago, presentarlo como opción de accesibilidad. 5) Validar contraste WCAG AA (4.5:1) de textSecondary/textMuted sobre surface en ambos modos.

### Onboarding por rol + "Novedades" sin release

| Impacto | Esfuerzo | Horizonte |
|---|---|---|
| Medio | Bajo | Corto plazo |

- **Qué es:** Overlay de primer login por rol (máximo 3 coach marks sobre los tiles reales: 'Acá ves tus papeles', 'Acá tu jornada', 'Cualquier duda, escribile al bot') y una card 'Novedades' que aparece una sola vez cuando cambia la versión, con contenido editable desde Firestore (sin release).
- **Por qué:** Hay usuarios reales en stores públicos y releases frecuentes (1.2.x con cadencia alta): cada feature nueva del chofer hoy se comunica por WhatsApp o no se comunica, y los choferes con poca soltura digital no exploran solos. Un onboarding de 3 pasos baja las consultas de soporte post-release (que caen todas en Santiago, el único operador) y sube el descubrimiento de features que ya costaron desarrollo (Mi jornada, revisiones de documentos). Costo mínimo, beneficio recurrente en cada release.
- **Cómo:** 1) Flag en PrefsService (onboarding_visto_v1 por rol); overlay propio con Stack + posiciones de los tiles del main_panel (sin package: 3 tooltips secuenciales con scrim). 2) Card de novedades: doc META/NOVEDADES en Firestore {version, titulo, lineas[], rol_destino} — al abrir el home, si version > la última vista (PrefsService), mostrar AppCard descartable arriba de los tiles. Editable desde Firestore Console o una pantallita admin después. 3) Para gomería (tablet compartida): el onboarding se dispara por dispositivo, no por usuario.

### El prompt del bot deja de ser decorativo: 1 tap → WhatsApp con borrador

| Impacto | Esfuerzo | Horizonte |
|---|---|---|
| Medio | Bajo | Corto plazo |

- **Qué es:** Convertir la tira _AiPrompt del home del chofer ('Preguntale al bot…') en un botón real: tap → abre WhatsApp al número del bot con el mensaje pre-cargado, y la sugerencia rota según el estado real del chofer (si tiene vencimiento próximo sugiere '¿cuándo vence mi licencia?'; si tiene adelanto pendiente, '¿cómo va mi adelanto?').
- **Por qué:** El widget ya existe y siembra la idea, pero hoy no hace nada (verificado: main_panel.dart línea ~700, comentario 'decorativo por ahora'). Es el quick win más barato del backlog: convierte el home en la puerta de entrada al canal de soporte que más invirtieron (agente Gemini con 30 tools), sube el uso del agente — y cada consulta resuelta por el bot es una interrupción menos al encargado. Además alimenta el dashboard del agente con más volumen, que es la métrica que luce ante gerencia.
- **Cómo:** 1) url_launcher ya está en pubspec: launchUrl('https://wa.me/<numero_bot>?text=<sugerencia>') con mode externalApplication. 2) Número del bot desde una constante o doc META (no hardcodear, ya hay patrón de config en Firestore). 3) Sugerencia contextual: _LineaEstado ya calcula el estado (vencido / próximo / en revisión) — reusar ese resultado para elegir el texto del borrador. 4) Fallback Windows/web: copiar el número al portapapeles con snackbar. Medio día de trabajo.

### Command palette 2.0: acciones, secciones y viajes (Ctrl+K para todo)

| Impacto | Esfuerzo | Horizonte |
|---|---|---|
| Medio | Bajo | Corto plazo |

- **Qué es:** Extender el palette existente (hoy solo salta a chofer/vehículo/revisión) con: navegación a las 15 secciones del shell ('> Logística'), acciones rápidas ('Nuevo viaje', 'Nuevo adelanto', 'Exportar planilla del mes'), búsqueda de viajes recientes (por chofer/destino/remito) y tarifas. Más atajos Ctrl+1..9 para las secciones más usadas del shell.
- **Por qué:** Santiago opera la app desktop todo el día: con 15 secciones en el NavigationRail (verificado en admin_shell.dart), cada cambio de contexto son 2-4 clicks + scroll de lista. El palette ya existe y tiene el patrón resuelto (one-shot get + filtro local) — extenderlo es barato y el efecto compuesto es grande: 30-50 navegaciones diarias × varios segundos = 15-20 min/día recuperados para el único operador. La búsqueda de viajes por remito además resuelve el caso real 'me llaman por el remito X' sin entrar a Logística y filtrar.
- **Cómo:** 1) En command_palette.dart agregar tipos de _PaletteItem: seccion (lee las _ShellSection del admin_shell, respetando capabilities), accion (callbacks a las altas: Ctrl+N de cada pantalla ya existe, es exponer lo mismo), viaje (query one-shot últimos 200 VIAJES_LOGISTICA: chofer + destino + nro remito como keywords) y tarifa. 2) Prefijo '>' filtra solo acciones/secciones (convención VS Code que ya conoce). 3) Ctrl+1..9 en CommandPaletteShortcut del shell mapeando a _seccionesVisibles[i]. 4) Mostrar el shortcut hint en el tooltip del rail.

### Atajos de ícono (app shortcuts) y widget de home-screen del chofer

| Impacto | Esfuerzo | Horizonte |
|---|---|---|
| Medio | Medio | Medio plazo |

- **Qué es:** Fase 1: long-press del ícono de la app (Android shortcuts / iOS quick actions) con 'Mi jornada', 'Mis vencimientos', 'Mi unidad'. Fase 2: widget de pantalla de inicio Android con el próximo vencimiento + resumen de la jornada de ayer, leído del último snapshot local (funciona sin señal).
- **Por qué:** Para el chofer, cada toque cuenta: el shortcut ahorra abrir la app y navegar (3-4 toques → 1 long-press) en las dos consultas más frecuentes. El widget va más lejos: el chofer ve 'Licencia vence en 12 días' sin abrir nada — es presencia permanente de la app en el teléfono y refuerza el cumplimiento documental que la empresa necesita (menos choferes parados por papeles vencidos, que cuestan viajes no hechos). Es además un feature 'visible' que luce en una demo a gerencia.
- **Cómo:** Fase 1: package quick_actions (~1 día): registrar 3 shortcuts que setean la ruta inicial post-login (integra con el router de deep links si ya está). Fase 2: package home_widget (Android primero): la app, al abrir o al recibir el aviso diario, persiste en el storage compartido del widget el próximo vencimiento + jornada de ayer (datos que ya calcula _TileVencimientos y Mi jornada); el widget nativo (RemoteViews simple, 2 líneas de texto + color de estado) los pinta. Sin red propia, sin backend nuevo. iOS WidgetKit queda para después (más caro, requiere target Swift).

### Estados de error y vacíos accionables en toda la app

| Impacto | Esfuerzo | Horizonte |
|---|---|---|
| Medio | Bajo | Corto plazo |

- **Qué es:** Pasada de consistencia sobre AppErrorState/AppEmptyState: todo error de carga con botón 'Reintentar' (el widget ya lo soporta, muchos callers no lo pasan), y los estados vacíos de pantallas operativas con CTA directa ('Cargar primer viaje', 'Crear adelanto') en vez de solo texto.
- **Por qué:** AppErrorState ya tiene onRetry opcional (verificado en app_states.dart línea 98) pero pantallas como Mi jornada muestran 'Probá de nuevo en un rato' SIN botón (mi_jornada_screen.dart línea 31): para un chofer con señal intermitente, eso es un callejón sin salida — su única salida es matar la app y volver a entrar. Es exactamente el usuario que menos herramientas tiene para autorescatarse. El costo de arreglo es trivial y el beneficio es percepción de robustez en el peor momento (cuando algo falló).
- **Cómo:** 1) Grep de AppErrorState( en lib/ y agregar onRetry en cada caller (en StreamBuilder: setState que recrea el stream; en FutureBuilder: re-trigger del future). Empezar por las 6 pantallas chofer. 2) AppEmptyState: agregar parámetro opcional action (AppButton) y usarlo en listas operativas admin (viajes, adelantos, tarifas) apuntando a la alta correspondiente — misma acción que el Ctrl+N ya registrado. 3) Regla en el doc del design system: 'ningún error terminal sin salida; ningún vacío operativo sin siguiente paso'. Medio día + revisión.

### Gomería kiosk: confirmación con resumen + deshacer de 10 segundos

| Impacto | Esfuerzo | Horizonte |
|---|---|---|
| Medio | Medio | Medio plazo |

- **Qué es:** En la tablet compartida de gomería: tras montar/retirar/rotar una cubierta, confirmación grande con el resumen de lo hecho ('Montaste BRIDGESTONE nueva en posición 3 de AB123CD') + snackbar 'Deshacer' de 10s que revierte la operación; y selector liviano de 'quién está operando' al entrar al hub para atribución.
- **Por qué:** Tablet compartida + dedos con guantes + operario no técnico = el escenario con más errores de toque de toda la app. Un montaje en la posición equivocada hoy se arregla con llamada a Santiago y cirugía manual en Firestore (su tiempo, otra vez). El deshacer inmediato convierte el error de dedo de 'ticket de soporte' a 'autocorrección de 2 segundos'. La atribución por operario además da trazabilidad que hoy no existe en el taller (quién montó qué), gratis para auditorías.
- **Cómo:** 1) Tras cada acción de montaje/retiro en el hub gomería: snackbar persistente 10s con acción 'Deshacer' que ejecuta el write inverso (los writes ya son secuenciales sin transacción por el bug Windows conocido; guard: solo permitir deshacer si no hubo otro write posterior en esa posición — check de timestamp del doc antes de revertir). 2) Confirmación con AppConfirmDialog mostrando el resumen ANTES de ejecutar en acciones destructivas (retiro definitivo), y resumen post-acción en las normales. 3) Selector de operario: lista de empleados del área al abrir el hub (PrefsService del dispositivo recuerda el último), campo operario en los docs de GOMERIA_MONTAJES/movimientos. Coordinar con la validación visual del módulo que ya está pendiente.

