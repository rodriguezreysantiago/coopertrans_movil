# Estado del proyecto — Coopertrans Móvil

Documento de handoff para retomar trabajo en otra máquina o en una conversación nueva con Claude. Última actualización: **2026-05-29 (Mac)** — **macOS: app ENVIADA A REVIEW de Apple App Store** 🎉 (de "8 builds fallidos sin causa" a en review en 2 sesiones). Resuelta la pantalla negra de arranque (faltaba el settings `macOS` en flutter_local_notifications + Firebase macOS sin configurar), deployment target del Podfile macOS alineado a 11.0 (−86% warnings de build), página de soporte creada para la Support URL de Apple, Flutter local de la Mac alineado a 3.44.0, fix de lint en functions, y listing macOS completo (capturas 2560×1600 con DNI propio borrado, descripción, promo). Detalle en "Sesiones recientes" abajo. _Sesión previa 2026-05-13 (Windows): sesión gigante "Sitrack/Volvo eventos + UX viajes + vigilador jornada v2"._ Auto-save borrador form viaje (BORRADORES_VIAJE) + validación fechas (descarga >= carga, entre tramos) + detección duplicados al guardar. Adelantos: estado pagado/pendiente con resumen PDF de pendientes. Comandos admin nuevos en bot WhatsApp: `/jornada DNI` (estado vigilador), `/silenciar DNI dur [motivo]` (suprime avisos al chofer + aviso al chofer "silenciado por X horas"), `/desilenciar DNI` (revierte). Cron nuevo `procesarSilenciadosExpirados` cada 10 min envía "notificaciones reanudadas" automáticamente. Vigilador jornada v2 con avisos: 3:30h continuo "30 min para parar" (antes 3:45h), 4h "penalizado por falta de descanso obligatorio", 11:30h con cálculo dinámico "frená hasta {hora_min_arranque}" (fórmula `max(6 AM ART próximo, fin+8h)`), 12h wording fuerte "superadas, penalizaciones más graves", **anti-arranque temprano post-12h** (movimiento antes de hora_min_arranque → aviso "descanso insuficiente" + flag al resumen Molina). Atajos teclado Ctrl+N/Ctrl+F en 5 pantallas Logística. **Sitrack `/files/reports` ACTIVADO** (probe 2026-05-13 21:24 → 988 KB con eventos reales). Nuevo cron `sitrackEventosPoller` cada 5 min consume y persiste a `SITRACK_EVENTOS` (event_id + 30 campos por evento, parseStrategy=`comma-wrapped`). Primer ciclo 35 eventos / 29 KB; segundo 13 eventos / 10 KB. Esto destraba 1400+ tipos de evento del catálogo Sitrack — próximas iteraciones: vigilador jornada v3 con eventos 152/153/154/155/960/1015 (sin proxy speed>15), auto-poblar viajes con eventos 200/201/202/852-854, anti-robo combustible 391/859/860, sobrevelocidad efectiva con `speed > cartography_limit_speed`. **Volvo Driver API + Tachograph Files API**: módulos activos en contrato (HTTP 200) pero feeds vacíos — solo 2 de ~50 chofers registrados (Sebas Chavez 2005341950 + Mario Leguizamón 5023636586) y `activities: []` en histórico 7 días. Bloqueo operativo: hay que coordinar con Volvo Argentina activación de transmisión por unidad + alta de los 48 chofers restantes. Volvo Messaging API (HMI camión): 403 — fuera de contrato. **Antes**: **4 releases publicados**: 1.0.43+46 → 1.0.44+47 → 1.0.45+48 → 1.0.46+49. Multi-tramo viajes operativo, fixes Windows críticos (abort runTransaction → Cloud Function callable + impresión directa con Roboto), UI degradada para celus lentos (Mi Perfil/Mi Unidad con fallback), fotos de perfil arregladas (FotoPerfilAvatar errorBuilder + 48 URLs muertas limpiadas), botones eliminar para empresas/ubicaciones/tarifas/viajes con check de referencias, hard-delete viajes en etapa testing, empresas → asignar ubicaciones (lado opuesto N:M), CUIT auto-formato + teléfono +549, mapa tarifas con diagnóstico + tap resalta, pegar link Google Maps en ubicación, buscador en ubicaciones, dashboard "Trámites pendientes" en vivo, bot ventana vencimientos 7→15 días. Sitrack ICM bloqueado: GPS instalados son básicos sin ICAN — pendiente activación de `/files/reports` por Sitrack. **Antes**: Release 1.0.42+45 publicado end-to-end con todas las mejoras del día: AAB en Play Console + GitHub Release Windows + auto-update local + symbols Dart a Sentry. Incluye: fix bug versión login screen (hardcoded 'v2.0.26' → AppTexts.appVersion dinámico), post-commit hook auto-sync memoria del agent a Drive, pre-commit hook anti "TODO" mayúscula en .dart/.ts, AppErrorState en 9 pantallas top, helper computeGridRatio + 24 tests nuevos (15 unit + 9 widget), Sentry filter + tracesSampleRate 0.05, TypeScript downgrade 5.5, 3 tokens nuevos en AppColors, aggregate stats server-side admin_panel, cap visual esquema gomería, formalización modelo bot WhatsApp (oficina primary + casa backup standby Manual on-demand), TTL policies activas en TELEMETRIA_HISTORICO + VOLVO_ALERTAS, gcloud beta + budget USD 10/mes con alertas. Sesión maratónica continuación: 6 mejoras del backlog procesadas (Sentry tracesSampleRate 0.2→0.05 + filter beforeSend, TypeScript downgrade 5.9.3→5.5.4 con typecheck más estricto, helper `computeGridRatio` extraído + 15 tests + refactor 3 hubs, AppErrorState extendido a 7 pantallas con StreamBuilder, migración final Colors.<accent> → AppColors, gcloud beta instalado). `firebase-functions` confirmado YA en latest 7.2.5 — el warning del CLI es engañoso. **Aggregate stats server-side para admin_panel implementado y deployado** (commits `ac7381d` + `3db978c`). Nueva Cloud Function `recomputeDashboardStats` corre cada 5 min y persiste KPIs en `STATS/dashboard` — el cliente lee 1 doc en lugar de 3 colecciones enteras (~177 docs antes). Validado en producción: primer run computó 55 choferes activos / 127 unidades / 9 vencidos en ~1.2s, runs siguientes ~250-400ms. Antes del aggregate stats: **Auditoría sistemática del codebase + 4 paquetes de fixes deployados a producción**. 4 agents auditaron en paralelo (cliente Flutter / core+shared / Cloud Functions / bot WhatsApp) → 85 hallazgos consolidados → 15 fixes reales aplicados + 6 falsos positivos confirmados como "ya estaba bien". 5 Cloud Functions redeployadas. TTL policies activadas en TELEMETRIA_HISTORICO + VOLVO_ALERTAS via gcloud. Bot WhatsApp reiniciado con código nuevo (anti-baneo). 2 proyectos GCP placeholder borrados (DELETE_REQUESTED). Cap visual del esquema Gomería al 65% pantalla (commit `cd77626`).

Sesiones recientes:
- **2026-05-29 (Mac — sesión "macOS destrabado end-to-end: enviado a review de Apple")**. Continuación del frente macOS (venía de 8 builds fallidos). **(1) Pantalla negra al abrir RESUELTA** (commit `c7c1c62`): el Build 49 abría en negro. Causa raíz: `NotificationService.init()` corría sin try/catch en `main()` y `flutter_local_notifications` 21+ tira si falta el settings de la plataforma actual — el `InitializationSettings` pasaba android/iOS/linux/windows pero **NO `macOS`** → `initialize()` reventaba ANTES de `runApp()` → ventana negra (mismo patrón exacto que el bug de Windows ya documentado en ese archivo). Fixes: agregar `macOS:` (reusa el `DarwinInitializationSettings` de iOS) + blindar las inits de arranque (`AppLogger`/`Prefs`/`Notification`/fechas) en try/catch vía helper `initSeguro` + `firebase_options.dart` case macOS (reusa options de iOS — mismo bundle ID = misma app Apple en Firebase; sin esto `Firebase.initializeApp` tiraba `UnsupportedError`). **(2) Deployment target Podfile macOS** (commit `be9999c`): de `platform :osx 10.15` → `11.0` + `post_install` que fuerza todos los pods a 11.0; elimina ~585 warnings de build (576 `ld` de pdfium "built for newer macOS version" + 9 de pods <10.13). Se **versionó el Podfile macOS** (antes untracked → Flutter lo regeneraba en 10.15, perdiendo el fix en Xcode Cloud). **(3) Support URL** (commit `1897091`): Apple exige una Support URL válida y `https://coopertrans-movil.web.app/soporte` daba **404** — creada `public/soporte.html` (branding de privacidad + contacto + FAQ) + rewrite en `firebase.json` + `firebase deploy --only hosting` → HTTP 200. **(4) Listing macOS completado**: 5 capturas crudas procesadas a **2560×1600** exacto con Pillow (la de Inicio tenía el DNI propio de Santiago → eliminado copiando fondo limpio; la de **Descargas DESCARTADA** por exponer DNIs + nombres de OTROS choferes — PII de terceros), texto promocional + descripción (adaptada "iOS Keychain"→"Keychain de macOS"), keywords. **(5) ENVIADA A REVIEW** de Apple App Store 🎉 (build con los fixes validado en TestFlight: abre en login, no negro). **(6) Warnings**: macOS −86% (el resto es ruido de dependencias —Sentry/gRPC/abseil— no accionable), iOS ya alineado (deployment 16.0, `ios/Runner` boilerplate limpio, mismos pods que macOS), Dart limpio (`flutter analyze` 0), functions 0 warnings (commit `7db6cee` arregló un max-len en `comun.ts`). Android pendiente (necesita el Android SDK que está en la PC Windows). **(7) Entorno Mac**: el Flutter local estaba en 3.41.9 (desfasado del pin 3.44.0) → no compilaba el proyecto (`SizeTransition.alignment` es API 3.44) ni dejaba pasar el hook pre-commit; **alineado a 3.44.0** + SPM desactivado (`flutter config --no-enable-swift-package-manager`, igual que el `ci_post_clone` de Xcode Cloud) + Node 26 instalado (brew) para poder analizar functions. **Pendiente macOS**: esperar aprobación de Apple (1-3 días) → publicar (manual). Commits: `c7c1c62`, `be9999c`, `7db6cee`, `1897091`.
- **2026-05-15 (Mac — sesión "iOS pipeline migrado a Xcode Cloud, bloqueado por cuenta nueva")**. Día largo de bring-up iOS desde la MacBook Air Intel. **(1) Setup local iOS funcionó pero falló al subir a TestFlight**: `pod install` + `flutter run` en simulator OK, build IPA local con `release_ios.sh` OK (75 MB), Transporter rechazó con "iOS SDK 26 obligatorio". Apple desde 2026 exige builds con Xcode 26 (que requiere macOS 26 Tahoe = Apple Silicon). MacBook Air 2020 Intel **no puede actualizar** → camino Mac local descartado. **(2) Migración a Xcode Cloud** (CI/CD de Apple, incluido sin costo extra): app registrada en App Store Connect (`com.coopertrans.movil`, SKU `coopertrans-movil-001`), Apple Distribution Cert + Provisioning Profile "Coopertrans Movil App Store" creados manualmente en portal, App Store Connect API Key creada (Admin role, Issuer `2b70dc6f-0859-4830-925f-743881d5cf1c`, Key ID `7K3A7243WL`, .p8 backup en `G:\ClaudeCodeSync\secrets-ios\`), workflow "Build & Upload to TestFlight" configurado con trigger Manual (no auto, para no quemar cuota). **(3) `ios/ci_scripts/ci_post_clone.sh`** creado y refinado: instala Flutter SDK + symlinks `/usr/local/bin/flutter`+`dart`, instala `flutterfire_cli` (sin esto el Build Phase "FlutterFire upload-crashlytics-symbols" falla con "command not found"), `flutter pub get` + `precache --ios` + `pod install`, **bloque opcional Manual Signing** que importa cert .p12 al keychain + instala .mobileprovision si las 3 env vars `IOS_DIST_CERT_P12_BASE64/PASSWORD/PROFILE_BASE64` están seteadas. **(4) 6 builds en Xcode Cloud, todos failed** con mismo error: `Account "Session Proxy Provider": Unable to authenticate with App Store Connect` + `error: exportArchive Communication with Apple failed` + `No profiles for 'com.coopertrans.movil' were found`. Aceptamos acuerdos comerciales pendientes en App Store Connect (paso obligatorio para cuentas nuevas) — no resolvió. La API Key Admin tampoco se está usando (Apple Cloud sigue con Session Proxy Provider interno). Diagnóstico: **cuenta nueva, propagación incompleta del backend Apple** (patrón conocido, suele resolverse 24-72h post-aprobación). **(5) pbxproj revertido a Manual Signing en Release** (`CODE_SIGN_STYLE = Manual` + `PROVISIONING_PROFILE_SPECIFIER = "Coopertrans Movil App Store"` apuntando al profile manual del portal). Debug/Profile siguen Automatic (para `flutter run` simulator local). **(6) Pendiente continuar desde Windows** (Plan A): exportar .p12 desde Keychain Mac (one-time, lo único que necesita la Mac), bajar .mobileprovision desde portal, base64-encodear ambos, subir 3 secret env vars al workflow, disparar build #7 → con cert + profile pre-cargados, xcodebuild NO necesita hablar con Apple. Plan B alternativo: esperar 48-72h y disparar build manual sin tocar nada (puede que Apple haya propagado para entonces). Detalle completo en `PENDIENTES.md` + memoria `project_ios_release.md`. **(7) Lección clave guardada en memoria nueva** `feedback_chequear_hardware_antes_de_setup.md`: chequear hardware (Intel vs Apple Silicon) **antes** de proponer setup local Mac para iOS. Apple cambia requisitos SDK cada año — para cuentas Apple Developer nuevas el camino limpio es **Xcode Cloud desde el día 1**, no Mac local. **(8) Cierre operacional**: Plan A configurado completo y build #7 disparado. (a) `.p12` exportado del Keychain → Drive `secrets-ios/coopertrans_dist.p12` + base64 generado. (b) `.mobileprovision` bajado vía App Store Connect API con script Python (commit incluye `scripts/download_provisioning_profile.py` reusable, args CLI, JWT ES256, lista profiles + descarga el target + genera base64) → Drive + base64. (c) 3 secret env vars en el workflow: `IOS_DIST_CERT_P12_BASE64`, `IOS_DIST_CERT_P12_PASSWORD=coopertrans2026`, `IOS_DIST_PROFILE_BASE64`. (d) Build #7 disparado manualmente. Esperando resultado al cierre. Si OK → mail TestFlight + app instalable. Si falla → logs en App Store Connect + diagnóstico (probablemente propagación cuenta nueva, esperar 48-72h). Backup secrets completo en `G:\ClaudeCodeSync\secrets-ios\` (5 archivos + README detallado). Pipeline queda 100% operable desde Windows post-cierre — Mac sólo necesaria 1 vez al año cuando vence el cert.
- **2026-05-13 (Windows — sesión "Sitrack/Volvo eventos + UX viajes + vigilador jornada v2")**. **(1) UX form viaje (commits `ef5ec91` + `7a7647f`)**: auto-save borrador en colección `BORRADORES_VIAJE/{dni}_{viajeId|nuevo}` con debounce 10s + flush en dispose; al re-entrar al form, dialog "¿Recuperar borrador?" con timestamp y cantidad de tramos. Validación de fechas (warnings, NO bloquean): por tramo `descarga >= carga`, entre tramos `carga(N+1) >= descarga(N)`. Detección de duplicados al guardar (modo alta): query viajes mismo chofer + alguna tarifa en común + ventana 24h → dialog con lista + "REVISAR" / "SÍ, GUARDAR IGUAL". Adelantos: estado pagado/pendiente con `setPagado()` + `marcarPagadosBulk()`, opacidad 3 estados en cards (1.0/0.55/0.40 según pendiente/seleccionado/pagado), check fijo verde para pagados, chip estado tappeable (PENDIENTE naranja / PAGADO verde con fecha). Resumen PDF cambió de "seleccionados" a "**pendientes de pago**" (subtítulo + filename `Adelantos-Pendientes-...pdf`); al imprimir, dialog "¿marcar como pagados?" con bulk update. **(2) Comandos admin bot WhatsApp (commits `2ca42ec` + `11ac875`)**: `/jornada DNI` muestra estado del vigilador (total día / jornada actual con marker "arrancó ayer" si cruzó medianoche / continuo / pausa / avisos enviados / silenciado / hora_min_arranque / patente). `/silenciar DNI dur [motivo]` (Ns/Nm/Nh/Nd, cap 30d) escribe `BOT_SILENCIADOS_CHOFER/{dni}` + encola aviso al chofer "silenciado por X horas, hasta DD/MM HH:MM ART, motivo: X" + responde al admin. `/desilenciar DNI` revierte (si estaba activo, encola "se reanudaron"). Vigilador chequea silenciados al iniciar cada ciclo (1 query, set en memoria, lookup O(1) por chofer) y skipea encolado para silenciados. Nuevo cron `procesarSilenciadosExpirados` cada 10 min detecta `silenciado_hasta <= now`, encola "notificaciones reanudadas" + borra el doc. **(3) Vigilador jornada v2 (commit `cfaf9db`)**: aviso continuo bumpeado de 3:45h → 3:30h ("te quedan 30 min para buscar lugar seguro y descansar mín 15 min"). Nuevo aviso a las 4h continuas: "penalizado por falta de descanso obligatorio" (al chofer + queda en resumen Molina vía flag `pausa_obligatoria_excedida` que ya existía). Aviso 11:30h ahora calcula dinámicamente la hora mínima de arranque con fórmula `max(6 AM ART próximo, fin_jornada + 8h)` y la inserta en el mensaje al chofer. Aviso 12h reformulado: "Superadas las 12 h de conducción diaria — detenerse para evitar penalizaciones más graves". **Anti-arranque temprano post-12h**: cuando se cumple 12h, el doc `JORNADAS_CHOFER` guarda `fin_jornada_at` + `hora_min_arranque_at`. En polls posteriores, si `speed > 15 km/h` y `now < hora_min_arranque`, se encola aviso "descanso insuficiente — no podías arrancar hasta {hora}" + flag `arranque_temprano_excedido` para resumen Molina. Reset al cumplir 8h de pausa limpia todos los flags nuevos. Helper `_calcularHoraMinArranque(finJornada): Date` con math UTC explícito (ART = UTC-3 fijo, sin DST). `/jornada` actualizado con flags nuevos (3:30, 4h-penalizado, 12h-superado, arranque-temprano) + display de hora_min_arranque cuando aplica. Compat retro: lectura del flag viejo `alerta_3_45_continua_enviada` para jornadas en curso al deploy. **(4) Atajos teclado (commit `89ef4c0`)**: nuevo `KeyboardShortcutsScope` widget reusable (`lib/shared/widgets/keyboard_shortcuts.dart`) bindings `Ctrl+N` (callback nuevo) + `Ctrl+F` (foco a search). Aplicado a 5 pantallas Logística: Viajes (Ctrl+N), Adelantos (N+F), Tarifas (N+F), Empresas (N+F por tab), Ubicaciones (N+F). **(5) Sitrack /files/reports (commits `622926e` + `737d196` + `29744e1`)**: probe `sitrack_probar_files_reports.js` confirmó endpoint **ACTIVADO** (200 + 988 KB con eventos reales tipo "Cambio de curso", "Contacto ON" con chofer ACKERMANN HERNAN). Nuevo cron `sitrackEventosPoller` cada 5 min consume `/files/reports`, parseo defensivo (estrategia `comma-wrapped` confirmada en producción), persiste a `SITRACK_EVENTOS/{reportId}` con ~30 campos por evento (event_id + event_name + report_date + asset_id + lat/lng/location + speed + cartography_limit_speed + driver_dni + odometer + hourmeter + ignition + battery + área). Idempotente, batches de 500. Cursor health en `META/sitrack_eventos_cursor`. Primeros ciclos: 35 + 13 eventos. Script `analizar_sitrack_eventos.js --horas 36` analiza ranking por event_id + cobertura por categoría (jornada/viajes/combustible/peligrosa/fatiga MobileEye/mantenimiento/puertas) → recomendación de qué consumidor armar primero. Pendiente correr en 24-48h (anotado en `PENDIENTES.md`). **(6) Probes Volvo (commits `7b76610` + `48b1069`)**: scripts `probar_volvo_driver_api.js` + `probar_volvo_modulos_no_usados.js`. Resultados: **Driver API + Tachograph Files API** activos en contrato pero feeds vacíos (solo 2 chofers registrados, `activities: []` en 7 días, `tachofiles: []` en 90 días). Bloqueo operativo: pedir a Volvo Argentina activar transmisión del feed por unidad + alta de los 48 chofers restantes. **Messaging API (HMI camión)**: 403 — fuera de contrato (cobrarían extra). **(7) Lección clave**: el endpoint `/files/reports` funciona como cola drenable — cada llamada vacía el buffer del lado Sitrack. Si no se consume en 30 días, Sitrack purga. El cron tiene que estar prendido siempre. El primer ~MB del probe se perdió (script no persistía); a partir del cron deployado, todo se persiste. **(8) Lección operativa H — credenciales en chat**: durante la sesión Santiago pegó dos veces credenciales (Volvo `BcLSahu...` y Sitrack `Cooper01`) en el chat para resolver problemas rápido. Quedó documentado el patrón seguro con `Get-Credential` + env vars + `Remove-Item Env:` para futuras pruebas, pero AMBAS hay que rotar (la de Volvo ya rotada). **(9) Fixes lint + firebase.json (commit `cca4b48`)**: backtick→doublequote en aviso arranque temprano + max-len en logger Volvo + `firebase.json` predeploy: `$RESOURCE_DIR` → hardcodeado `functions` para que ande desde PowerShell (Windows convertía a `%X%` que no se expande). Build OK + 275 tests passing + flutter analyze clean. Commits: `ef5ec91`, `7a7647f`, `2ca42ec`, `11ac875`, `89ef4c0`, `cfaf9db`, `cca4b48`, `7b76610`, `48b1069`, `622926e`, `737d196`, `29744e1`, `60c0811`.
- **2026-05-12 (Windows — sesión gigante: 4 releases en cadena)**. **(1) Multi-tramo viajes (1.0.44+47)** commit `7faa948`: refactor mayor, `Viaje.tramos: List<TramoViaje>` reemplaza campos planos. Cada tramo con su tarifa+producto+fechas+kg+remito. Caso real: Bahía → Olavarría → Tres Arroyos en un solo viaje. Compat retro automática (viajes pre-1.0.44 cargan como single-tramo). Form reorganizado: Resumen → Estado → Chofer+Unidad → Adelanto → Gastos → Tramos. LIQUIDACIÓN con desplegable por tramo. `calcularTodoMultiTramo` con 39 tests (272 totales OK). **(2) Fixes Windows críticos (1.0.43+46)**: abort() de `runTransaction` en counter de recibos → Cloud Function callable `asignarNumeroReciboAdelanto` server-side (Admin SDK no tiene el bug); impresión directa al volver el plugin `printing` con `Printing.directPrintPdf` (resuelto el crash anterior con TTFs Roboto reales del repo googlefonts/roboto-2). **(3) UI degradada celus lentos**: signOut+timeout en signInWithCustomToken con mensaje accionable, pre-warm cache del legajo en background, `_PerfilOfflineFallback` después de 10s sin respuesta de Firestore (banner "Conexión lenta" + datos cacheados de Prefs en lugar del "Perfil no encontrado" alarmante). Reportado por Willy López 16969961. **(4) Fix avatares**: 48 de 61 empleados con URL en bucket viejo (`logisticaapp-e539a` 404). Nuevo widget compartido `FotoPerfilAvatar` con `errorBuilder` + script `limpiar_fotos_perfil_bucket_viejo.js` corrido (48 limpiados). **(5) Logística — features (1.0.44 → 1.0.46)**: botones eliminar empresas/ubicaciones/tarifas/viajes con check de referencias y hard-delete de viajes en etapa testing (doble confirmación tipear "ELIMINAR"); empresas → asignar ubicaciones desde el sheet (lado opuesto N:M, removido el selector del lado de ubicación que confundía); CUIT auto-formato XX-XXXXXXXX-X; teléfono renombrado de "Contacto" con prefijo 549 patrón EMPLEADOS.TELEFONO + nombre del contacto separado; mapa de tarifas con tap-resalta-y-centra + botón Diagnóstico que muestra qué tarifas están filtradas y por qué; pegar link Google Maps en ubicación con parser propio (`utils/google_maps_url.dart`); buscador en lista de ubicaciones; sheets refrescan en vivo (StreamBuilder) al agregar productos/ubicaciones; ordenar choferes alfabéticamente en dropdown; producto libre no pierde foco al tipear (`productoLibreCtrl` en state). **(6) Bot WhatsApp**: ventana de resumen vencimientos a Giagante de 7 → 15 días (constante única `DIAS_AVISO_VENCIMIENTO_PROXIMO`). Trámites RTO/seguros/ART en Bahía tardan ~10-14 días, 7 daba poco margen. **(7) Dashboard fix**: "Trámites pendientes" ahora se lee con stream live + fallback al stats agregado, antes había hasta 5 min de delay. **(8) Sitrack ICM bloqueado**: diagnóstico via `scripts/sitrack_listar_eventos.js` confirma que los GPS de la flota son básicos sin ICAN — `/v2/report` solo trae speed+gpsSpeed+cartographyLimitSpeed+driverDocumentNumber. Para ICM serio hay que activar `/files/reports` con polling acumulado. Mail listo para `integraciones.ar@sitrack.com` con la lista de eventId organizada por categoría. **(9) Rules ampliadas**: `delete: if isAdminOrSupervisor()` para EMPRESAS_LOGISTICA, UBICACIONES_LOGISTICA, TARIFAS_LOGISTICA, VIAJES_LOGISTICA. Cuando se pase a producción real volver a `false` para forzar histórico. **(10) Lección operativa G — script de exploración Sitrack**: lee credenciales del Secret Manager + lista eventos distintos del último report + enumera campos ricos disponibles + concluye automáticamente si hay datos para Fase 1 local. **272/272 tests passing** + flutter analyze clean + functions build OK. Commits clave: `7faa948` multi-tramo, `5363447` callable Sitrack, `4662879` print directo, `355843c` FotoPerfilAvatar, `8ee0ef4`+`8964b7b`+`2cb4999`+`2e12a06` deletes, `9fb667d` empresas→ubicaciones, `aa213a9` diagnóstico mapa, `375215c` Google Maps parser, `767a01f` buscador ubicaciones, `f17ad05` nombre contacto, `e81fca9` ventana 15 días, `779278c` dashboard live.
- **2026-05-11 (madrugada+, Windows)** — Release 1.0.42+45 + 4 nice-to-have del backlog. **(1) Pre-commit hook anti "TODO"** (`6f51f0a`): bloquea TODO/FIXME mayúscula en líneas nuevas de .dart/.ts. La lección "D" se disparó 3 veces en 24h ("llenar TODO el alto", etc.) — este hook lo previene en lugar de fixearlo después. Detecta solo líneas nuevas (git diff --cached), los TODO viejos no se tocan. Mensaje claro al rechazar + bypass con `--no-verify` para casos legítimos. **(2) AppErrorState extendido a +2 pantallas** (`6f51f0a`): user_mi_perfil_screen + admin_personal_lista_widgets. Resto de StreamBuilders restantes analizados con criterio: admin_estado_bot widgets (chicos, fallback graceful), vehiculos_lista (sheet con dataInicial fallback), whatsapp_cola widgets (contadores chicos) — NO valen la pena porque error UI gigante en widget chico se vería raro. **(3) Tests de widget para 3 hubs** (`6f51f0a` + `356843a` lint fix): 9 tests del patrón compartido `LayoutBuilder + computeGridRatio + GridView`. Cubren mobile portrait / iPad landscape / desktop / pantalla microscópica (defensa contra NaN). NO testean los screens reales porque tienen StreamBuilders de Firebase y no hay fake_cloud_firestore en deps — se testea el patrón que es lo que rompe en refactors. Total tests: **263**. **(4) Bug versión login + auto-sync memoria a Drive** (`807ee0c`): el login mostraba `'v2.0.26 — Bahía Blanca, Argentina'` hardcoded de 4 versiones atrás, confundía a testers. Reemplazado por `AppTexts.appVersion` dinámico que `bump_version.ps1` mantiene sincronizado. + Post-commit hook agregó bloque de sync automático: detecta el slug del proyecto desde el path absoluto del repo, ubica `~/.claude/projects/$slug/memory/` y espeja a `$DRIVE_PATH/claude-memory/` con `cp -uv`. Resuelve el problema de la memoria del agent que vivía fuera del repo y requería sync manual al final de cada sesión. Validado: hook reporta "1 archivo(s) de memoria sincronizados" cuando se modifica un .md de memoria local. **(5) Release completo 1.0.42+45 end-to-end** (`170ea1d` bump + tag `v1.0.42+45`): primer `release_completo.ps1` exitoso desde el bump del fix de login. 8 pasos sin intervención: bump, commit, build Windows (62.9s), Inno Setup (20.6 MB), git push (sube `807ee0c` + bump), GitHub Release (zip 26.9 MB + .exe), AAB Android (75.9 MB con symbols Dart subidos a Sentry), update local en PC oficina. AAB pendiente de subir manualmente a Play Console. **(6) Lección operativa F — memoria del agent estaba fuera del sync automático**: hasta hoy el hook claudesync solo cubría docs del repo (ESTADO_PROYECTO, RUNBOOK, etc.). La memoria del agent en `~/.claude/projects/` requería sync manual — fácil de olvidar, hoy detectado que las versiones en Drive estaban hasta 7h atrasadas vs local. Resuelto con bloque agregado al post-commit. Cobertura: cualquier edit de memoria que vaya junto a un commit del repo se sincroniza solo. **263/263 tests passing** + flutter analyze clean + functions build OK.
- **2026-05-11 (madrugada, Windows)** — Continuación de auditoría: 6 ítems del backlog procesados. **(1) Sentry optimizado** (`00fda91`): `tracesSampleRate: 0.2 → 0.05` para tener 4× margen al free tier de 5K events/mes con 90+ empleados. Nuevo `beforeSend` filter descarta network glitches transient (failed host lookup, connection refused/closed/timeout) y `CancelledByUserException` del file_picker/image_picker — ruido sin valor de bug real. **(2) TypeScript downgrade** (`00fda91`): `^5.4.0` → `~5.5.4` (último 5.5, dentro del rango supported `<5.6.0` del @typescript-eslint/typescript-estree). El warning de TS no soportado durante deploys desaparece. TS 5.5 es más estricto: hubo que castear `update: Record<string, unknown>` a `{[k: string]: any}` con eslint-disable explícito en index.ts:841 (tx.update espera `UpdateData<T>` con `FieldValue` allowed). Bonus: fix de warning `'_' is defined but never used` en línea 4722 (`catch (_)` → `catch`). **(3) Helper computeGridRatio + 15 tests + refactor 3 hubs** (`00fda91`): la lógica del ratio dinámico estaba duplicada inline en los 3 hubs (Gomería + Logística + main_panel) con leves variaciones. Extraída a `lib/shared/utils/responsive_grid.dart` como función pura testeable. 15 tests cubren: caso típico (mobile/tablet/desktop), clamp (min/max), defensivos (cols=0, rows=0, alto unbounded, spacing consume todo), 3 escenarios reales de hubs en producción. Refactor de los 3 hubs para usar el helper bajó ~40 líneas duplicadas. **(4) AppErrorState extendido a 7 pantallas con StreamBuilder principal** (`600fae7`): antes solo gomeria_stock_screen tenía `snap.hasError` check; ahora también gomeria_unidades_lista, gomeria_recapados (2 builders), gomeria_marcas_modelos (2 builders), gomeria_unidad_detalle (2 builders anidados), gomeria_cubierta_detalle, logistica_viaje_detalle, user_mi_equipo, user_mis_vencimientos. Pantallas DELIBERADAMENTE no tocadas: admin_panel (fromDoc(null) ya hace fallback graceful), admin_empresas_empleadoras (widget chico repetido por empresa, error UI inline raro), banners/contadores/forms internos. Migración incremental sigue para los ~17 archivos restantes. **(5) Migración final Colors.<accent>** (`6cccbef`): la memoria decía "~820 lugares" — al medir hoy eran 5 usos reales en 3 archivos. AppColors recibió 3 tokens nuevos (accentDeepOrange, accentLightGreen, accentLightBlue) que faltaban; los 3 archivos hardcoded migrados. Cero usos hardcoded en lib/. La migración incremental "cada vez que toques un archivo por otro motivo" funcionó mejor de lo que documentamos. **(6) gcloud beta instalado** (acción manual de Santiago como admin): `gcloud components install beta` desde PowerShell as Administrator + interactivo (sin `--quiet` que tira ERROR sobre bundled Python). Ahora disponible: `gcloud beta billing projects describe coopertrans-movil` confirmó billing account `012131-B936BA-6291CB` activo. **(7) firebase-functions verificado en latest 7.2.5**: el warning durante cada deploy "package.json indicates an outdated version of firebase-functions" es engañoso/bug del Firebase CLI — `npm view firebase-functions latest` confirma 7.2.5 = latest. Bumpeo bonus: `@typescript-eslint/{parser,eslint-plugin}` 8.59.1 → 8.59.2 (minor patch). Pendientes deliberados (major upgrades con riesgo de testing): firebase-admin 12→13, bcryptjs 2→3 (crítico, podría romper hashes existentes en EMPLEADOS), eslint 8→9. **254 tests passing** (15 nuevos del responsive_grid). Commits: `600fae7`, `6cccbef`, `00fda91`, `18463c4` + el cierre de docs final.
- **2026-05-10 (madrugada+, Windows)** — Aggregate stats server-side para admin_panel. **Problema atacado**: el dashboard hacía 3 StreamBuilders (EMPLEADOS + VEHICULOS + REVISIONES) y calculaba KPIs O(N×M) client-side en cada snapshot push — funcionaba con flotas chicas pero la deuda escalaba (cada cambio en cualquier doc → recalc completo en cada cliente admin abierto). Era la "DEUDA TECNICA" más vieja del archivo, comentada explícitamente desde sesiones previas. **Solución**: nueva Cloud Function `recomputeDashboardStats` (`schedule: every 5 minutes`) recalcula todo server-side y persiste el agregado en `STATS/dashboard` (campos: `choferes_activos`, `unidades_total`, `unidades_asignadas`, `revisiones_pendientes`, `vencidos`, `proximos_7`, `proximos_30` + metadata `actualizado_en`, `duracion_ms`, `docs_leidos`, `v: 1`). El cliente lee 1 doc; `_Stats.fromDoc()` parsea defensivo con fallback a 0 por si shape cambia. Replica los helpers de Dart en TypeScript (`_statsEsActivo`, `_statsNormalizarRol`, `_statsCalcularDiasRestantes`, `_statsContarFecha`) — drift documentado en comentarios de ambos lados. **Stale máx 5 min**, totalmente aceptable para dashboard administrativo. **Costo**: 3 reads × ~177 docs cada 5 min = ~150k reads/mes, despreciable vs N admins simultáneos haciendo lo mismo client-side. **Rules nuevas**: `STATS/{doc}` con `read: if isAdminOrSupervisor()` + `write: if false` (solo Admin SDK). Commits `ac7381d` (refactor + function nueva) + `3db978c` (fix de 14 ESLint errors: doc comments `///` → `//`, `let yyyy: number, mm: number, dd: number` → 3 statements separados, ternario con `?:` extracción de condición). 239/239 tests passing + functions build OK + flutter analyze clean. **Deploy validado en producción**: primer run computó `{choferes_activos: 55, unidades_total: 127, unidades_asignadas: 106, revisiones_pendientes: 0, vencidos: 9, proximos_7: 4, proximos_30: 13, docs_leidos: 188}` en 1.186s; runs siguientes 248-411ms cada uno. Disparado manualmente vía `gcloud scheduler jobs run firebase-schedule-recomputeDashboardStats-...` para no esperar 5 min.
- **2026-05-10 (madrugada, Windows)** — Sesión de auditoría sistemática end-to-end + fixes deployados. **(1) Auditoría del codebase** con 4 agents en paralelo (lib/features cliente Flutter / lib/core+shared / functions/src Cloud Functions / whatsapp-bot/src Node.js). 85 hallazgos consolidados en 4 paquetes priorizados por impacto. **(2) Cap visual del esquema Gomería** (commit `cd77626`): el `EsquemaUnidadView` usaba `AspectRatio` puro sin cap → en Windows desktop con 1500px ancho × ratio 0.67 enganche = ~2240px alto, imagen gigante que desbordaba el viewport. Fix: envolver en `Center + ConstrainedBox(maxHeight: MediaQuery.size.height * 0.65, maxWidth: 600)`. **(3) Paquete A — Bot WhatsApp anti-baneo** (commit `6d84ca2`): A.1 verificación que el batch atómico encolar+registrar idempotencia ya estaba implementado en cron.js (6 paths usan `prepararRegistro*`); A.2 cleanup defensivo en `whatsapp.js#onMensajeEntrante` para que re-registros no acumulen listeners (hoy se llama 1 vez en bootstrap, defensa contra refactor futuro); A.3 retry transient en `firestore.js#marcarProcesandoSiPendiente` (3 reintentos con backoff 200/500/1000ms para errores DEADLINE_EXCEEDED/UNAVAILABLE — runTransaction ya reintenta conflictos pero no errores de red); A.4 parser real de `/pausar Nh|Nm|Nd|Ns` con auto-reanudación vía campo `pausado_hasta` en BOT_CONTROL (antes la duración se guardaba como string en motivo y la pausa era eterna hasta que admin recordara `/reanudar`). Bonus: fix de test pre-existente en `backup_auth.test.js` (esperaba `'_._.etc_passwd'` pero el sanitizador correctamente devuelve `'___etc_passwd'`). 120/120 tests bot passing. **(4) Paquete B — Robustez Dart core** (commit `3241446`): B.5 verificación que formatters tienen length guards (`formatearDNI`/`CUIL` ya ok); B.6 null-check defensivo en `auto_sync_service.dart:94` reemplazando `as Map<String, dynamic>` por `is! Map`; B.7 sanitización de logs sensibles en `auth_service.dart` (DioException ya no logea URL completa ni response body crudo, solo host + statusCode + error.message); B.8 RegExp como `static final` en hot paths (`digit_only_formatter`, `fecha_input_formatter`, `formatters._milesRegex` — antes se recompilaban en cada keystroke / rebuild). 239/239 tests passing. **(5) Paquete C — Defensas anti drift de costos Firestore** (commit `d68e04d`): C.9 `.limit(5000)` defensivo en 4 queries (VEHICULOS en `telemetriaSnapshotScheduled` + `volvoScoresPoller`, SITRACK_POSICIONES en `resumenDriftsAsignacionesDiario` + `vigiladorJornadaChofer`); C.10 campo `expira_en` en TELEMETRIA_HISTORICO (fecha+18m) y VOLVO_ALERTAS (creado_en+12m) + activación de TTL policies via `gcloud firestore fields ttls update expira_en --collection-group=X --enable-ttl` (ambas en estado ACTIVE — los nuevos docs entrarán al ciclo, los pre-cambio quedan sin TTL); C.11 `.limit(5000)` defensivo en `_empleadosStream` y `_vehiculosStream` del admin_panel. **(6) Paquete D — Calidad / mantenibilidad** (commit `bc4f3c7`): D.12 verificación que `Colors.whiteXX` SÍ son válidos por convención del proyecto (documentado en AppColors.dart, CI lo ignora); D.13 reemplazo de 4 strings literales de ruta por `AppRoutes.*` en main_panel; D.14 env var `ALERTAS_SEG_HIGIENE_DESTINATARIO_DNI` reemplaza el DNI hardcoded `34730329` en cron.js (con fallback al hardcoded para no romper si alguien olvida setearla); D.15 verificación que tests de password_hasher + formatters ya existen; D.16 error handling con `AppErrorState` en gomeria_stock_screen StreamBuilder (helper compartido reusable que ya existía en `app_states.dart`); D.17 verificación que `enforceAppCheck: false` en `auditLogWrite` está intencionalmente porque AppCheck no está activado en cliente. **(7) Lección clave de la auditoría**: ~30% de los hallazgos de los agents fueron falsos positivos (citaron código que YA estaba arreglado o documentado). La auditoría con agents es buena para destapar candidatos pero hay que verificar cada hallazgo contra el código real antes de fixear. **(8) Deploys a producción**: 5 Cloud Functions redeployadas exitosas (`telemetriaSnapshotScheduled`, `volvoScoresPoller`, `volvoAlertasPoller`, `resumenDriftsAsignacionesDiario`, `vigiladorJornadaChofer`). Bot WhatsApp reiniciado, arrancó OK con código nuevo (`PC_ID=oficina`, log `WhatsApp listo para enviar` + heartbeat + cron habilitado). **(9) Cleanup GCP**: 2 proyectos placeholder "My First Project" auto-generados antes de la migración (creados 2026-03-16 y 2026-03-20, completamente vacíos: 0 buckets / sin Firestore / sin Functions / sin App Engine) borrados via `gcloud projects delete` — ambos en estado DELETE_REQUESTED, recuperables hasta ~2026-06-09. Solo queda `coopertrans-movil` ACTIVE (más `logisticaapp-e539a` también en DELETE_REQUESTED desde 2026-05-08). **(10) Lección operativa E — gcloud no detecta automáticamente: instalable desde https://cloud.google.com/sdk/docs/install#windows (default install path: `C:\Program Files (x86)\Google\Cloud SDK\google-cloud-sdk\bin\gcloud.cmd`). Después de instalar hace falta abrir PowerShell NUEVO para que se actualice PATH, o llamar al .cmd con path absoluto. **(11) Path correcto de logs del bot**: la memoria/RUNBOOK decía `bot-out.log` (con guion) pero el real es `bot.out.log` y `bot.err.log` (con punto) en `whatsapp-bot/logs/`.
- **2026-05-10 (PM noche, Windows)** — Sesión de auditoría UI + release responsive. **(1) Bug reportado por Santiago**: en el menú de Gomería, los 4 tiles (UNIDADES / STOCK / RECAPADOS / MARCAS Y MODELOS) no entraban en la pantalla — había que scrollear. Causa: `SingleChildScrollView + GridView shrinkWrap` con `childAspectRatio: 1.1` fijo. **Fix Gomería** (commit `33ef541`): reemplazado por `Padding + Column + Expanded(LayoutBuilder + GridView)` con ratio calculado dinámicamente como `cellWidth / cellHeight` (clamp 0.5..2.0). Las 4 cards llenan TODO el alto disponible — con o sin banner de alertas — sin scroll. El SizedBox(16) separador entre banner y grid se movió adentro del banner como `Padding(bottom: 16)` para no dejar gap visible cuando no hay alertas. **(2) Auditoría sistemática del patrón** en el resto del codebase (6 archivos con GridView): 2 pantallas con el mismo problema, 4 OK. Pantallas con problema fixeadas (commit `4c57c21`): **logística_hub_screen** (5 tiles + banner, ratio 1.05 fijo en mobile portrait → 3 filas obligaba scroll) — mismo patrón con LayoutBuilder + clamp 0.45..2.0 + cálculo de filas según columnas resueltas (`(totalTiles / cols).ceil()`); **main_panel** (panel principal del chofer post-login, 3 botones para chofer / 4 si admin) — antes ratio 1.2 fijo dentro de Expanded → GridView scrolleaba internamente en mobile dejando ver solo 2 botones. Ahora calcula ratio según `_isAdmin` y alto real. Pantallas OK que no necesitaban fix: `admin_panel_screen` ya trabajado con FittedBox externo en sesión 2026-05-09; `sync_dashboard` y `eco_driving` son dashboards scrollables por diseño con varias secciones verticales — el grid es solo una sección entre otras. **(3) Fix typos**: 2 warnings tipo "TODO" reportados por VS Code en los hubs nuevos — eran las palabras "TODO" en mayúsculas dentro de mis comentarios ("llenan TODO el alto disponible") que el linter interpreta como pendientes reales. Cambiados a "todo" minúscula (commit `0527d56`). El analyzer de VS Code requirió "Dart: Restart Analysis Server" para refrescar el cache local. **(4) Release 1.0.40+43 publicado**: primer `release_completo.ps1` end-to-end exitoso del repo. Antes la lección operativa era "no relanzar `release_completo.ps1` a mitad" (sesión 2026-05-10 PM Win cuando falló en `[5/8]` por non-fast-forward). Esta vez no se bumpée a mano antes (ver lección de la sesión PM tarde) y el script corrió los 8 pasos limpios: bump 1.0.39+42 → 1.0.40+43, commit, `flutter build windows --release` (69s), Inno Setup (20.7 MB), `git push` (5 commits acumulados del día), `release_app.ps1` (zip 26.9 MB + .exe 20.7 MB en GitHub Release `v1.0.40+43`), `release_android.ps1 -PlayStore` (AAB 75.9 MB con symbols Dart a Sentry), update local disparado. AAB pendiente de subir manualmente a Play Console por Santiago. **(5) Lección operativa C — `release_completo.ps1` SÍ funciona end-to-end**: cuando se respeta el contrato (no bumpear a mano antes, repo limpio, sin fallar previamente), el wrapper hace los 8 pasos sin intervención. La vez previa que falló (2026-05-10 PM tarde) fue por `non-fast-forward` — origin tenía un commit que local no — y se documentó "no relanzar". Esta sesión confirma que cuando arranca limpio, el script es el camino más corto a producción. **(6) Lección operativa D — TODO en mayúsculas dentro de comentarios**: el linter Dart `todo` flagea cualquier "TODO" mayúscula como pendiente real, sin importar contexto. Evitar palabras como "todo" en mayúscula en comentarios — usar minúscula o sinónimo ("entero", "completo").
- **2026-05-10 (PM tarde, Windows)** — Sesión de cleanup + recuperación de release perdido. **(1) Cleanup worktrees colgados**: limpieza completa de 5 ramas `claude/*` (4 ya en main vía rebase, 1 con commits únicos rebaseados) + 3 worktrees pre-rename de `logistica_app_profesional/` que quedaron prunables + 1 worktree activo `unruffled-newton-e0b7e6` cuyos 10 commits propios estaban rebaseados a main (contenido íntegro ya integrado). Carpetas físicas de los 3 worktrees pre-rename eliminadas (~11 MB de basura). Carpeta del worktree active quedó locked en Windows por proceso del sistema (Defender/indexador) — borrada después de reinicio. **(2) Release perdido recuperado**: la memoria documentaba que el commit del esquema **foto-realista de Gomería** (`594256f`) estaba en main, pero NO lo estaba. Main tenía solo el CustomPainter procedural (`13736e1`) de la sesión Mac (10-may AM), no la versión con renders foto-realistas que Santiago había pedido en la sesión PM. El commit `594256f` quedó huérfano en el reflog cuando borramos la rama `claude/vibrant-antonelli-1ebaf7` durante el cleanup — ningún branch lo referenciaba. Recuperado vía `git rev-parse 594256f` (lo encontró en el reflog) + `git cherry-pick 594256f` (auto-merge de pubspec.yaml, conflictos cero). Hash nuevo: `82c728b`. El commit reemplaza el `EsquemaUnidadView` procedural por imágenes WebP `assets/gomeria/tractor_top.webp` (640×800, 41 KB) + `enganche_top.webp` (533×800, 26 KB) con Stack + Image.asset de fondo + Positioned overlay tappeable: ring color por % vida útil consumida (verde/naranja/rojo) + halo blur 4px sobre cada rueda real, badge "L" pequeño en cohort legacy. Mapas const de coordenadas (%, %) calibrados contra cada render. Hit-area circular vía InkWell + customBorder. **(3) Bump + release 1.0.39+42**: validación pre-bump con `flutter analyze --no-pub` (0 issues, 87s) + `flutter test --no-pub` (239/239 pass). Bump via `bump_version.ps1` sincronizó pubspec.yaml + app_constants.dart + main.cpp. Commit `127b662`. Auto-push del harness subió el bump a origin/main mientras se preparaban los pasos siguientes — el plan A original (revertir local + `release_completo.ps1` desde cero) quedó inviable porque hubiera requerido force-push para destruir el commit ya en remote. Se pasó a plan B manual: `release_android.ps1 -PlayStore` (AAB para Play Console) + `release_app.ps1` (Windows zip + GitHub Release con tag `v1.0.39+42`). AAB subido a Play Console Closed Testing por Santiago. Release notes: "Mejoras visuales en gomería: esquema foto-realista de la unidad, indicador L para cubiertas con datos previos desconocidos. Robustez: checklist diario timeout extendido y mejor reporte de errores." **(4) Lección operativa A — bump manual antes del wrapper**: el `bump_version.ps1` corrido manualmente ANTES de definir el flujo de release inhabilita el wrapper integrado (`release_completo.ps1`) porque el script asume que el bump es parte de su propia secuencia. Si se va a usar el wrapper, NO bumpear a mano antes — dejar que el script lo haga. **(5) Lección operativa B — verificar hashes de la memoria contra el repo**: cuando se borra una rama `claude/*` con commits no mergeados, los commits quedan recuperables vía reflog por 30 días. Si la memoria documenta un hash, vale la pena verificarlo con `git rev-parse <hash>` antes de asumir que está en main — los rebases generan hashes distintos para el mismo contenido y los huérfanos se pierden silenciosamente si no se vuelven a referenciar.
- **2026-05-10 (Mac)** — Sesión de validación iOS + 2 mejoras UI. **(1) Build iOS post-rename validado**: `flutter run -d "iPhone 16 Pro"` corrió OK en simulator (post `flutter clean`, build inicial 42 min, incrementales 50-100s). Side-effect: `pod install` agregó `geolocator_apple` al `Podfile.lock` (faltaba la entrada iOS aunque el plugin estaba en pubspec). **(2) Fix overflow <1 px en KPI cards iOS — fix definitivo** (`2988bbd`): cards "Unidades en flota" y "Vencidos" mostraban "BOTTOM OVERFLOWED BY 0.182/0.682 PIXELS" en iPhone 16 Pro. Iteraciones previas (1.4 → 1.3 → 1.1 ratio + Flexible/FittedBox interno, sesión 2026-05-09) no resolvían: el log de runtime mostró que el Column dentro del Expanded recibía 45.3 px y su contenido medía 45.5 px. **Causa raíz**: `mainAxisSize.min` no permite ceder cuando el parent fuerza `FlexFit.tight`. **Fix definitivo**: envolver TODO el bloque del medio (valor + sublabel) en `Align + FittedBox(scaleDown)` externo. Cuando el contenido natural excede los px disponibles, escala uniformemente todo el bloque (factor ~0.996, imperceptible). Validado: 0 overflows en runtime. **(3) CustomPainter visual de Gomería** (`13736e1`): reemplaza el grid de 3 cards apiladas (`_EjeHeader`+`_GridEje`+`_PosicionTile`, ~295 líneas borradas) por un esquema visual de la unidad desde arriba. Tractor: cabina + chasis vertical + 3 ejes (1 dirección + 2 tracción dual = 10 cubiertas) + quinta rueda con cruz. Enganche: caja + trompa + 3 ejes tracción dual = 12 cubiertas. **Patrones internos distintos** según uso: 3 chevrons (V's) en dirección, 4 tacos alternados izquierda/derecha en tracción. Color de borde + fill semitransparente según % vida útil consumida (verde <80% / naranja 80-99% / rojo ≥100%). Posiciones vacías: stroke discontinuo gris claro. Hit-test reusa el mismo helper `_EsquemaLayout` que pinta. Implementación: `lib/features/gomeria/widgets/esquema_unidad_view.dart` (~500 líneas). Aspect ratio 0.58 tractor / 0.42 enganche. Tap en cubierta abre el mismo dialog que la vista vieja. Imágenes de referencia foto-realistas que mandó Santiago copiadas a `proyecto-docs/gomeria-referencia/`. Validado en simulator iPhone 16 Pro. Pendiente menor: indicador visual de cohort legacy (línea punteada o puntito en esquina) en cubiertas pre-sistema. **(4) iOS — TestFlight bloqueado**: cuenta Apple Developer Individual sigue pendiente de activación al 2026-05-10 (>3 días desde contratación 2026-05-06). Hasta que active: pasos 2-7 del flujo (App ID + Team Xcode + app record + IPA + TestFlight + invitaciones) en standby. Pasos detallados en `project_pendientes_post_migracion.md`. **(5) Cierre**: continuamos en Windows (Mac es lenta para builds Flutter).
- **2026-05-09** — Sesión maratón en 2 frentes. **(1) Módulo VIAJES Logística completo** (commits `c7853fb` backend + `7a18a05` fix kg + `1aca7d0` UI). Backend: nueva colección `VIAJES_LOGISTICA` con `tarifa_snapshot` inmutable, modelos `Viaje` + `EstadoViaje` (PLANEADO / EN_CURSO / COMPLETADO / CANCELADO / POSTERGADO) + `GastoViaje`, `viajes_service.dart` con CRUD + Storage `RemitosViaje/{id}_{ts}.{ext}` (cap 10 MB, image/pdf), `calculos_viaje.dart` con 30 tests passing (POR_VIAJE / POR_TONELADA usando kg DESCARGADOS con fallback a CARGADOS, 18% sobre tarifa_chofer, redondeo múltiplo de 5 descendente solo al chofer, liquidación = redondeado − adelanto + gastos). UI: 3 pantallas (`logistica_viajes_lista_screen` con filtros estado + liquidación + ver borrados, `logistica_viaje_detalle_screen` read-only con secciones agrupadas + acciones, `logistica_viaje_form_screen` 8 secciones con recompute en vivo). Tile VIAJES habilitado en hub con contador en vivo. RBAC admin/supervisor — choferes NO ven (info delicada de sueldos). Decisión Vecchi: estado default `PLANEADO` (puede que no se realice), comprobante de remito NO obligatorio, ambos roles pueden borrar y liquidar. Ver `project_modulo_logistica.md` sección "Módulo Viajes". **(2) Auditoría sistemática prolijidad mobile** — era la queja #1 de admins testers. Pasamos por **~38 archivos UI** con 4 agentes paralelos auditando + aplicación de fixes. Fix CRÍTICO de `login_screen` (`width: 420` hardcoded → `maxWidth: 420`, era overflow garantizado en cualquier mobile <420 dp). Fix bottom bar admin (12 destinos saturados → 4 fijos + "Más" con BottomSheet, puntito rojo si hay pendientes en secciones ocultas). Fix KPI cards admin (ratio 1.4 → 1.3 → 1.1 + Flexible/FittedBox/maxLines en 3 iteraciones). Fix eje dual gomería (1x4 → 2x2 en mobile <480 dp con LayoutBuilder). Fix toolbar mapa flota (5 contadores en scroll horizontal, sumaban >400 dp). Fix tabla sync (scroll horizontal con minWidth 480). Fix telemetría flota (4 Expanded → Wrap responsive). Fix razón social larga ("VECCHI ARIEL Y …") en 4 sites con maxLines:2. Fix eco-driving GridView 4.2 → 3.5. Fix _DateTile IconButtons compactos (visualDensity + padding 6). Fix 38+ Texts dinámicos con maxLines + ellipsis defensivo. Patrón sistemático documentado en `feedback_prolijidad_mobile.md` con 8 reglas obligatorias. Commits: `cdb0fda`, `344fba3`, `d986df8`, `cdb96fd`. **(3) Bump 1.0.37+40 publicado** — release_completo.ps1 falló inicialmente con CMake error por cache stale (rutas absolutas del proyecto viejo `logistica_app_profesional/` post rename de carpeta) — fix con `flutter clean` antes de buildear. Texto release notes para Play Console: novedades (Viajes Logística + mapa flota responsivo) + mejoras (login mobile + bottom bar admin + cards listas).
- **2026-05-07** — Sesión grande de operativa + módulo nuevo. **(1) Reorg alertas WhatsApp**: blacklist mantenimiento al chofer (FUEL/CATALYST/AdBlue/TELL_TALE/sin login Volvo), 8 variantes anti-baneo en eventos manejo, sin dedup diaria en eventos manejo (decisión Vecchi: "es lo que más afecta el índice de manejo"), Volvo HIGH resumen separado a Molina (Seg e Higiene, DNI 34730329, hardcoded en `cron.js`), mantenimiento + service van al Jefe Mant Emmanuel Corchete (DNI 29820141 vía env vars). Throttle 30 min al aviso "pasá el iButton" (antes spameaba cada 5 min) en colección `META_AVISOS_NO_ID`. Resúmenes diarios pasados de 23:55 → 8 AM siguiente día. Commits `03c3228`, `4169c06`, `89eea4e`, `d5e5228`, `e9b3a57`, `aab33ba`, `8c59406`, `2f002ce`, `9e704e2`. **(2) Vigilador de jornada del chofer**: Cloud Function `vigiladorJornadaChofer` cada 5 min lee `SITRACK_POSICIONES`, regla "manejando = speed > 10 km/h" (decisión Vecchi: muchos paran sin apagar el camión), pausa 15 min resetea continuo. Avisos al chofer a 3h45 continuo + 11h30 diario (00:00–23:59 ART). Aviso fin jornada nocturna 23:30 dejado LISTO con flag `AVISO_NOCTURNO_ACTIVO=false`. Resumen diario excesos a Seg e Higiene 8 AM (`resumenExcesosJornadaDiario`). Persistencia en `JORNADAS_CHOFER`. Commit `ef3cde0`. Ver `project_alertas_y_resumenes_whatsapp.md`. **(3) Módulo Logística** (commit `f348272`): nuevo menú LOGÍSTICA en panel admin con catálogos para el futuro planeamiento de viajes. 3 colecciones: `EMPRESAS_LOGISTICA` (CLIENTE / DADOR_TRANSPORTE), `UBICACIONES_LOGISTICA` (puntos físicos con lat/lng opcional), `TARIFAS_LOGISTICA` (rutas con doble precio: tarifa_real + tarifa_chofer + comisión dador variable por carga + flete origen/destino + unidad TN/VIAJE). Capability nueva `verLogistica` (admin/supervisor). Snapshot de nombres en TARIFAS para que renames no rompan reportes. Soft-delete con `activa`, `delete: false` en rules para preservar histórico. Form full-screen con flujo numerado 1→6 + selectores bottom-sheet de empresa/ubicación. Patrón `DatoEditable*` en edición inline. Ver `project_modulo_logistica.md`. **(4) Quota CPU sa-east1**: deploy multi-función falló por pico transitorio de CPU (creando 3 nuevas + actualizando 2 simultáneamente). Re-intento solo de las 2 falladas (`sitrackPosicionPoller` + `loginConDni`) funcionó. Cuota actual 20.000 milli vCPU al 25% — si vuelve a pasar, ajustable a 40.000 desde GCP Console. **(5) Reorden menú admin** (commit `393ed56`): nuevo orden Personal → Flota → Revisiones → Vencimientos → Logística → Gomería → Service → Alertas → (bloque Volvo en sidebar) → Reportes → Sync → Estado Bot. Mismo orden en sidebar y panel central. Bloque Volvo (Eco/Descargas/Mapa) queda intercalado solo en sidebar después de Alertas (mismo bloque conceptual). **(6) Title bar Windows stale**: el string del título de la ventana está hardcoded en `windows/runner/main.cpp` línea 45. Al bumpear manual a 1.0.22 me olvidé de tocarlo → la ventana mostraba "v 1.0.21 (build 23)" mientras FileVersion / AppTexts decían 1.0.22+24. Fix manual (`dc40c49`) + descubrimiento del script `scripts/bump_version.ps1` que actualiza los 3 lugares en uno (pubspec + app_constants + main.cpp) con convención legacy `appVersion = pubspec_patch + 6`. **(7) Bug release_app.ps1 con comillas dobles** (commit `2a81219`): `gh release create --notes "$Notes"` se rompía cuando algún commit del log auto-generado tenía comillas dobles en el subject ("pasá el iButton" → la comilla cierra el arg y "pasá/el/iButton" quedan como filenames sueltos → `no matches found for el`). Fix con `--notes-file` (escribir a temp file). **(8) Bump cosmético 1.0.23+26** (commit `a15c6e5`): después del fix de title bar y reorden, hubo varios re-bumps. Play Console rechazó AAB con `+25` ("Ya se usó el código de la versión 25") → bumpear a `+26` aunque el versionName no cambie. **Regla operativa**: cada upload a Play Console consume el versionCode aunque después se descarte la release; siempre bumpear `+N` por más cosmético que sea. **(9) Empleados con app sideloaded**: descubierto que el celular de Santiago tenía 1.0.0 (Firebase App Distribution legacy) en lugar de la del Play Store. La 1.0.0 sideloaded NO recibe updates de Play Store porque Android la trata como app distinta. Probablemente la mayoría de los 90+ empleados está igual → hay que mandar broadcast con "desinstalá vieja + opt-in URL + instalá desde Play Store". Opt-in URL: `https://play.google.com/apps/testing/com.coopertrans.movil`. Mensaje de WhatsApp pre-armado en la sesión. **Pendiente**: mandar broadcast cuando estabilice 1.0.23+26, decidir migración Closed → Open Testing si la lista de testers se vuelve costosa de mantener. **(10) Docs y memoria actualizados**: README + RUNBOOK + ESTADO_PROYECTO + 7 archivos de memoria (logística + alertas/resúmenes + RBAC + Play Store + pendientes + Android pipeline + ESTADO). Sync automático a Drive vía hook post-commit + sync manual de `claude-memory/` a `G:/Mi unidad/ClaudeCodeSync/proyecto-docs/claude-memory/`.
- **2026-05-06 (nocturna, Mac)** — Sesión de cierre del ciclo iOS y consolidación multi-PC. **(1) Primer `flutter run -d "iPhone 16 Pro"` exitoso** en el simulador del Mac (iPhone 16 Pro, iOS 18.6, Xcode 16.4, Flutter 3.41.9, CocoaPods 1.16.2 con workaround `LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8`). Build inicial tardó ~40 min (Firebase + gRPC + MLKit + Sentry compilando desde cero); builds incrementales serán mucho más rápidos. Logs confirmados: "Firebase conectado correctamente", "Sentry inicializado (env: production)", Hot Reload activo, DevTools disponible. Las líneas `[VOLVO AUTH] Rechazo de auth (1/3)` + `HTTP 401` son esperadas (cliente Volvo intenta auth antes del login). Ruby observado en la Mac fue 2.6.10 (system ruby), no Ruby 4.0 como decía la memoria — el workaround `LANG` igual aplicó por warning de pod sobre encoding UTF-8. **(2) Pre-flight TestFlight** — `ITSAppUsesNonExemptEncryption=false` agregado al `Info.plist` (commit `8017dcf`) para evitar el prompt de export compliance en cada upload. Auditoría de plugins iOS contra `Info.plist`: file_picker, image_picker, mlkit, local_notifications, share_plus, pdfrx están cubiertos con cámara + fotos + photo library add. La app NO usa: ubicación, FaceID, push, micrófono, contactos. No falta ningún permission string para review de Apple. **(3) Setup hooks Mac** — `git config core.hooksPath .githooks` + `git config claudesync.drivepath "/Users/santiagorodriguezrey/Google Drive/Mi unidad/ClaudeCodeSync/proyecto-docs"`. Path en español ("Mi unidad", no "My Drive") porque Drive Desktop respeta el locale del sistema en macOS. Probado: el hook backupea 7 docs a Drive end-to-end. **(4) Bug-fix encontrado en el camino**: `.githooks/post-commit` estaba commiteado **sin bit ejecutable**, así que git lo ignoraba en silencio en cualquier máquina que clonara el repo (warning "hook was ignored because it's not set as executable"). Fix con `chmod +x` + `git update-index --chmod=+x` para registrar el bit en git (commit `938825a`). Ahora el hook corre OK en clones futuros. **(5) Cuenta Apple Developer Individual contratada** ($99/año), esperando activación (~24h al cierre de la sesión). Para 90+ empleados la ruta es **TestFlight External Testing** (no Internal — Internal solo soporta 100 testers que tienen que ser miembros del Apple Developer Team con acceso al portal). External soporta hasta 10.000 testers, no requiere acceso al portal, primera build pasa por "beta review" de Apple (~24h primera vez, mucho más rápido después). Roadmap de retomar (cuando active la cuenta): registrar App ID `com.coopertrans.movil` en Developer Portal → seleccionar Team en Xcode (Signing & Capabilities) → crear app record en App Store Connect → `flutter build ipa --release` → upload via Xcode Organizer → External TestFlight setup → invitar empleados por email/link. Privacy Policy URL ya disponible en `coopertrans-movil.web.app/privacidad`. **Trade-off cuenta Individual vs Organization**: con Individual la app aparece como "by Santiago Rodriguez Rey" en TestFlight; para branding empresarial habría que migrar a Organization (requiere DUNS de Coopertrans, trámite de semanas con Apple). No bloqueante para arrancar.
- **2026-05-06 (PM, Windows)** — Bloque grande de cierre operativo. **(1) Publicación oficial en Google Play** — Closed Testing aprobado por Google. Cuenta `santiagocoopertrans@gmail.com` (Account ID `7015813484350394507`), Developer name `Coopertrans Móvil`, app personal/free, listing completo (icono 512×512 + feature graphic 1024×500 + descripción + data safety + content rating + acceso a apps con cuenta reviewer DNI `90000001`). Política de privacidad y página de eliminación de cuenta hosteadas en Firebase Hosting (`https://coopertrans-movil.web.app/privacidad` y `/eliminar-cuenta`). Los empleados ahora bajan la app desde Play Store **sin warning de "puede ser dañina"**. **(2) Fix permisos chofer** (commit `f17e697`) — los choferes podían loguear pero al cambiar foto de perfil o contraseña recibían "no tiene autorización" porque storage.rules y firestore.rules solo permitían admin/supervisor en `PERFILES/{dni}.jpg` y `EMPLEADOS/{dni}`. Rules ampliadas: chofer puede subir SU foto (regex match `request.auth.uid + '\\..*'`) y actualizar SOLO `ARCHIVO_PERFIL` + `CONTRASEÑA` de su propio doc (con `diff().affectedKeys().hasOnly([...])`). **(3) RBAC: 2 roles nuevos** (commit `4c39396`) — `GOMERIA` (solo módulo Gomería) y `SEG_HIGIENE` (solo tableros Volvo: alertas + eco-driving + descargas + mapa). Capabilities en `lib/core/services/capabilities.dart`. Helpers de rules `puedeOperarGomeria()` (admin/supervisor + GOMERIA) y `puedeVerVolvoTableros()` (admin/supervisor + SEG_HIGIENE) reemplazan a `isAdminOrSupervisor()` en las matches relevantes. Cloud function `actualizarRolEmpleado` ROLES_VALIDOS ampliada. **(4) Branding visual unificado en TODAS las plataformas** (commit `1fe61c7`) — logo VAVG sobre fondo gris claro (#E8EAED) en Android (mipmap-mdpi a xxxhdpi + adaptive icons via `flutter_launcher_icons`), iOS (Assets.xcassets/AppIcon.appiconset), Windows (`app_icon.ico` multi-res 16/32/48/64/128/256), Play Store (icon 512×512 + feature graphic 1024×500 generados con Pillow desde el `.ico` de Windows + recorte limpio del bbox). **(5) Bump a 1.0.1+9** (commit `5f02d97`) — incluye los fixes anteriores. AAB subido y aprobado por Google. Windows release con `release_app.ps1` (zip a GitHub Releases) — los users con `launcher_app.ps1` se actualizan solos al abrir la app. **(6) Bug de checklist sin reproducir** — los choferes reportaron que "no graba las novedades" pero las rules permiten `create: if isSignedIn()` y el código solo hace `.add()`. Hipótesis: sesión expirada o versión vieja. Pendiente reproducir con un caso real. **(7) Auto-update Windows** confirmado — `scripts/launcher_app.ps1` consulta GitHub Releases API, baja zip y reemplaza la instalación al abrir la app (sin esfuerzo del usuario). Fixes server-side deployados en orden separado: `firestore:rules` + `functions:actualizarRolEmpleado` + `storage`. **Pendiente**: build iOS desde Mac (Santiago lo hace cuando agarra esa máquina).
- **2026-05-06 (AM, Mac)** — **iOS preparado para primer build**. Tres commits encadenados (`bc043a2`, `321c5a4`, `bbd68a8`): (1) `project.pbxproj` con `PRODUCT_BUNDLE_IDENTIFIER` corregido `com.coopertrans.logisticaAppProfesional` → `com.coopertrans.movil` (alineado con `GoogleService-Info.plist` y Android `applicationId`), `RunnerTests` también; (2) `Info.plist` ahora con `CFBundleDisplayName="Coopertrans Móvil"`, `CFBundleName="coopertrans_movil"`, y permisos requeridos por `image_picker` + OCR (`NSCameraUsageDescription`, `NSPhotoLibraryUsageDescription`, `NSPhotoLibraryAddUsageDescription`); (3) `IPHONEOS_DEPLOYMENT_TARGET` 13.0 → 16.0 en Runner y forzado en TODOS los pods vía `post_install` del Podfile (necesario porque `cloud_firestore 6.x` y firebase pods modernos exigen ≥14, y abseil/BoringSSL/gRPC/DKImagePicker quedaban en 9-11 generando warnings de Xcode 15+); (4) `Profile.xcconfig` registrado en `pbxproj` (`bc043a2` lo creó pero nunca lo registró, la build config Profile heredaba de Release). `pod install` corrió OK en macOS — `Podfile.lock` (1694 líneas) commiteado. **Pendiente**: probar `flutter run -d "iPhone 16 Pro"` y eventual TestFlight (requiere DEVELOPMENT_TEAM + provisioning profile, ahora vacío). **Workaround pod install Mac**: Ruby 4.0 + CocoaPods 1.16 da `Encoding::CompatibilityError` en `Pod::Config#installation_root` — correr con `LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 pod install`.
- **2026-05-05** — Cuatro bloques: **(1) Bot WhatsApp — alertas Volvo**: fix etiqueta GENERIC en `onAlertaVolvoCreated` — ahora resuelve `detalle_generic.triggerType` contra `ETIQUETAS_TIPO_ALERTA` (antes siempre decía "Evento genérico"); fix agrupador `COLA_WHATSAPP` — índice compuesto Firestore creado (`destinatario_id + origen + estado + encolado_en`), ahora agrupa correctamente mensajes al chofer. **(2) Android release pipeline**: keystore de producción generado (`C:/Users/Colo Logistica/keystores/coopertrans_movil.jks`, alias `coopertrans_key`); `build.gradle.kts` configurado con signing release + `isMinifyEnabled` + `isShrinkResources` + core library desugaring; `proguard-rules.pro` con reglas Flutter/Firebase/ML Kit; `scripts/release_android.ps1` análogo al de Windows (build APK + upload a Firebase App Distribution en un comando). **Primera versión distribuida**: v1.0.0+7 en Firebase App Distribution, grupo `testers`. **(3) Fixes bugs**: `storage.rules` — agregado path `VEHICULOS/{patente}/**` (mayúsculas) que faltaba → resuelve "user unauthorized" al subir comprobantes de RTO/Seguro desde panel admin. `cron.js calcularDiasRestantes` — ahora reconoce formato `DD/MM/YYYY` además de ISO, evita que `new Date()` invierta mes/día (bug reportado en AF598QK RTO 03/10/2026). **(4) Pendientes de deploy** (no deployados aún): `firebase deploy --only functions:onAlertaVolvoCreated` + `functions:onAlertaVolvoMantenimientoCreated`; `firebase deploy --only storage`; `nssm restart whatsapp-bot`.
- **2026-05-04 (desde Mac)** — Soporte plataforma iOS: `flutter create --platforms=ios .` generó la carpeta `ios/` completa (commit `7c1a9f7`). `GoogleService-Info.plist` descargado desde Firebase Console y configurado (commit `f85144c`): `BUNDLE_ID=com.coopertrans.movil`, `PROJECT_ID=coopertrans-movil`. ⚠️ **Pendiente antes del primer build real**: el `project.pbxproj` quedó con `PRODUCT_BUNDLE_IDENTIFIER = com.coopertrans.logisticaAppProfesional` (default Flutter) — hay que cambiarlo a `com.coopertrans.movil` (en Xcode: Target Runner → Signing & Capabilities → Bundle Identifier). Versión actual: `1.0.0+7`.
- **2026-05-04 (sesión larga)** — Revisión profunda de **Módulo Gomería** tras testing de Santiago donde el alta crasheaba con `abort()` C++. Bloque (1) revisión exhaustiva: 8 fases de mejora — fixes críticos (rules `motivo_retiro`, `puedeRecaparse` mintiendo a UI, `unidad_tipo` enmascarando errores), UX visual de unidades (tile con marca/modelo/% vida útil consumida, KM_ACTUAL en cabecera, geometría dual con gap), pantalla detalle de cubierta + búsqueda + filtros por estado, recapados con tabs En Proceso / Histórico + catálogo `CUBIERTAS_PROVEEDORES`, alertas en hub (≥80% vida útil), unicidad transaccional con docs de control (`CUBIERTAS_POSICIONES_ACTIVAS`, `CUBIERTAS_ACTIVAS`), feature **Rotar cubiertas** (mover/swap dentro de unidad), costo de cubierta + edición inline de modelo + presión/banda + registrar control. Bloque (2) **descubrimiento causa raíz Windows**: el bug de "Lost connection / abort()" NO era del plugin "en general" sino específicamente de `runTransaction` con cierta combinación de operaciones (reads + writes mixtos, especialmente con `tx.set` + `SetOptions(merge: true)` o `FieldValue.serverTimestamp()` adentro). Refactor completo del `GomeriaService`: las 7 transactions (crearCubierta, instalar, retirar, descartar, mandarARecapar, recibirDeRecapado, rotar) reemplazadas por `.get()` simples + writes secuenciales con cleanup best-effort. Unicidad ahora la garantizan rules `allow update: if false` sobre los locks. Bloque (3) **alta en lote**: nuevo método `crearCubiertasEnLote(cantidad: 1..500)` con barra de progreso para flotas grandes. Tests 65/65, analyzer global limpio. Ver sección 6.16.
- **2026-05-01 (sesión larga)** — Continuación del trabajo del 30-abril. Tres bloques: **(1) imports bulk de datos** desde Excel a Firestore via 2 scripts Python idempotentes con `--dry-run`/`--apply`: `importar_servicios_y_matafuegos.py` (56 patentes con KM/fecha de último service + matafuegos cabina/exterior) e `importar_apodos.py` (53 choferes con APODO; matching exacto + fallback starts-with normalizado Unicode para SCHRÖDER/IBAÑEZ). Snapshot Excel se incluye y se borra al final una vez aplicado. **(2) fixes UI**: la ficha de detalle del vehículo en Gestión de Flota tenía los vencimientos hardcoded a RTO+Seguro — ahora itera `AppVencimientos.forTipo()` y los TRACTORES muestran los 4 vencimientos (extintores incluidos). Los chips del header de MANTENIMIENTO PREVENTIVO (Vencidos/Urgentes/Programar/Falta poco/OK) son clickeables y filtran la lista por estado, conteos siguen globales, tap-toggle limpia el filtro. Sidebar admin y panel central de "Accesos rápidos" unificados (mismo orden y mismos nombres cortos: Revisiones/Flota/Service/Personal/Vencimientos/Reportes/Sync/Estado Bot). **(3) auditoría profunda con 2 agentes paralelos** (cliente Flutter + backend Functions/bot/rules) que produjo plan de 4 fases ejecutado completo — ver sección 6.10. `flutter analyze` y `flutter test` (25 tests) pasan limpios al cierre.
- **2026-04-29 (madrugada+)** — Bot WhatsApp Fase 2/3 endurecido: avisos automáticos de service preventivo (sumado al cron del bot Node.js, 4 niveles igual que la pantalla cliente: 5000/2500/1000/0 km), recordatorios diarios de vencidos (papeles + service) — el id del histórico incluye fecha del día así se reenvía hasta regularización con copy escalado por días/km transcurridos. **Plan B activo** (`uptimeData.serviceDistance` no viene del API por restricción de paquete Volvo): la pantalla y el bot calculan `serviceDistance` desde `(ULTIMO_SERVICE_KM + 50.000) − KM_ACTUAL` cuando falta el dato del API; el cliente puede registrar "service hecho" desde la card con un tap. Ticket abierto a Volvo para activar el bloque UPTIME en la cuenta. **Bot Node.js refactor crítico**: cambiado `onSnapshot` (gRPC stream) por polling con `get()` cada 15s — el stream gRPC se caía cada ~2 min en redes con NAT/firewall agresivo cortando conexiones idle. Solución mucho más resiliente, latencia despreciable. Polling tolera errores transientes sin romper el ciclo.
- **2026-04-29 (madrugada)** — Mantenimiento preventivo (roadmap Volvo, ~1 día): nueva pantalla `admin_mantenimiento_screen` que ordena tractores por urgencia de service (5 estados: OK / Falta poco / Programar / Urgente / Vencido). Parseo de `serviceDistance` agregado a `VolvoTelemetria` + persistencia en `VEHICULOS.SERVICE_DISTANCE_KM` desde `VehiculoManager` y en `TELEMETRIA_HISTORICO` desde la scheduled function. Campos manuales `ULTIMO_SERVICE_KM` + `ULTIMO_SERVICE_FECHA` editables desde la ficha del tractor (form admin). Notificación local con idempotencia en `MANTENIMIENTOS_AVISADOS/{patente}` cuando un tractor cruza el umbral a VENCIDO. Constants centralizadas en `AppMantenimiento` (umbrales 5000/2500/1000/0). Pendiente: deploy de `firestore.rules` (sumó match para `MANTENIMIENTOS_AVISADOS`).
- **2026-04-29 (medianoche)** — `flutter_secure_storage` para `PrefsService`: migrados `dni`/`nombre`/`rol`/`isLoggedIn`/`lastDni` desde `SharedPreferences` (texto plano) al almacén seguro nativo (DPAPI en Windows, Keychain en iOS, KeyStore + EncryptedSharedPreferences en Android). API pública sigue **sync** (cache en memoria al `init()`) — los 13 call sites no cambian. Migración one-shot idempotente desde SharedPreferences viejo al primer arranque después del upgrade.
- **2026-04-29 (noche tarde)** — `AUDITORIA_ACCIONES` movido al server: nueva Cloud Function callable `auditLogWrite` (Gen2, valida rol ADMIN del JWT + whitelist de acciones/entidades + límite 10KB en `detalles`). `AuditLogService` cliente reescrito para llamar al callable via Dio + Bearer ID token (mismo patrón que `loginConDni`/`volvoProxy`, fire-and-forget). Rule de `AUDITORIA_ACCIONES` cerrada a `read: if isAdmin(); write: if false`. **Deployado y operativo** (functions + rules + IAM `allUsers` invoker en Cloud Run). Probado: edición de chofer registra correctamente con `admin_dni`/`admin_nombre` tomados del JWT.
- **2026-04-29 (noche)** — refactor `admin_personal_lista_screen.dart`: extracción de `_Actualizar` (clase namespace) → `lib/features/employees/services/empleado_actions.dart` como `EmpleadoActions`. Archivo lista pasa de 1295 a 727 líneas. `flutter analyze` limpio. Workaround del bug del sandbox (null bytes residuales tras Edit grande) aplicado vía `python3 + rstrip(b'\x00')`.
- **2026-04-29 (PM tarde)** — branch `feature/firebase-auth`: setup Cloud Functions + `loginConDni` callable + adaptación de `AuthService` + `AuthGuard` con doble check + cierre real de `firestore.rules`/`storage.rules` con `request.auth.uid` y `isAdmin()` por custom claim.
- **2026-04-29 (PM)** — revisión profunda del estado real tras pull, completado este documento con módulos no documentados (bot WhatsApp, audit log, OCR, calendario).
- **2026-04-29 (mañana)** — auditoría de seguridad: rotación de key Firebase, limpieza git history, fixes en bot Node.js (sanitización path, match estricto teléfono, backoff exponencial, grace shutdown), `firestore.rules` + `storage.rules` publicadas.
- **2026-04-28 (PM/noche)** — refactor cross-platform + sprints 1-8: UX/calidad + dashboard + reporte consumo con histórico + bot de WhatsApp Fase 1-3.
- **2026-04-28 (mañana)** — auditoría inicial (`AUDITORIA_2026-04-28.md`).

---

## 1. Qué es la app

App Flutter multiplataforma (Android / iOS / Web / Windows) para gestión de flota de la empresa de transporte **Vecchi / Sucesión Vecchi**, en Bahía Blanca. Maneja:

- **Personal** (choferes y administrativos), con sus papeles vencibles (licencia, **preocupacional**, ART, manejo defensivo, F.931, seguro de vida, sindicato).
- **Flota**: tractores y enganches (BATEAS, TOLVAS, BIVUELCOS, TANQUES, ACOPLADOS legacy), con sus vencimientos (RTO, Seguro, Extintor Cabina, Extintor Exterior — los 2 extintores solo para tractores). Foto del vehículo opcional.
- **Checklists mensuales** del chofer sobre tractor y enganche.
- **Sistema de revisiones**: el chofer sube fecha + comprobante de un trámite renovado, el admin aprueba/rechaza desde "Revisiones Pendientes".
- **Auditoría de vencimientos** (60 días): admin ve qué documentos están por vencer ordenados por urgencia, con badge de color, y desde ahí puede mandarle WhatsApp pre-armado (Click-to-Chat) al chofer. También vista de **calendario mensual**.
- **Bot WhatsApp automatizado** (proyecto Node.js externo, escucha la cola en Firestore): el admin encola → el bot envía con anti-throttle → el chofer responde con foto del comprobante → el bot intenta asociarlo automáticamente, y si no puede, lo deja en una bandeja para que el admin lo despache.
- **Reportes Excel**: flota, novedades de checklist y consumo (con histórico real si disponible).
- **Integración Volvo Connect** para los tractores Volvo: trae odómetro, % combustible, autonomía estimada en km. Sincronización automática cada 60 segundos vía `AutoSyncService`. Snapshot diario a `TELEMETRIA_HISTORICO` para el reporte de consumo.
- **Búsqueda global Ctrl+K** estilo VS Code para encontrar choferes / unidades / trámites.

## 2. Tech stack

- **Flutter 3.x** + Dart 3.0+
- **Firebase**: Firestore (datos), Storage (archivos), Crashlytics (errores en mobile), Cloud Messaging (no usado aún).
- **State management**: `provider` con `ProxyProvider`/`ChangeNotifierProxyProvider` cadenas.
- **HTTP**: `dio` (a Volvo Connect API).
- **Auth**: Firebase Auth con custom token. La Cloud Function `loginConDni` (en `functions/src/index.ts`) recibe DNI+password, valida server-side contra `EMPLEADOS` (bcrypt o SHA-256 legacy con migración silenciosa) y emite un custom token con `uid = DNI` y custom claims `{ rol, nombre }`. El cliente hace `signInWithCustomToken(token)`.
- **Calendario**: `table_calendar: ^3.1.x`.
- **OCR**: `google_mlkit_text_recognition` on-device (Android/iOS solamente).
- **Otros**: `excel`, `intl`, `flutter_local_notifications`, `image_picker`, `file_picker`, `pdfrx`, `share_plus`, `url_launcher`, `crypto`/`bcrypt`, `timezone`, `path_provider`, `shared_preferences`, `ffi`/`win32` (transitivas Windows).
- **Plataformas activas**: Windows desktop (admin desde la oficina), Android (choferes vía Play Store Closed Testing) e iOS (primer `flutter run` en simulador iPhone 16 Pro confirmado 2026-05-06: bundle `com.coopertrans.movil`, deployment target 16.0, Info.plist completo con cámara/fotos/photo library add + `ITSAppUsesNonExemptEncryption=false`, pods 57 instalados, Firebase + Sentry inicializan OK; falta `DEVELOPMENT_TEAM` + provisioning para TestFlight, esperando activación cuenta Apple Developer Individual ~24h). Web compila pero los reportes Excel se desactivan ahí (toca `dart:io`).
- **Bot WhatsApp**: proyecto Node.js separado en `whatsapp-bot/` con `firebase-admin`, lee/escribe Firestore vía Admin SDK (bypasea las rules).

## 3. Arquitectura

```
coopertrans_movil/
├── lib/
│   ├── core/
│   │   ├── constants/
│   │   │   ├── app_constants.dart          # Rutas, colecciones, roles, tipos vehículo
│   │   │   └── vencimientos_config.dart    # Specs de vencimientos por tipo
│   │   ├── services/
│   │   │   ├── app_logger.dart             # Logger central (Crashlytics en mobile)
│   │   │   ├── audit_log_service.dart      # Bitácora AUDITORIA_ACCIONES
│   │   │   ├── auto_sync_service.dart      # Cron Volvo (Provider singleton)
│   │   │   ├── notification_service.dart
│   │   │   ├── prefs_service.dart          # SharedPreferences (sesión)
│   │   │   └── storage_service.dart        # Subida a Storage (cross-platform)
│   │   └── theme/app_theme.dart
│   ├── features/
│   │   ├── admin_dashboard/                # Panel admin + shell con Ctrl+K
│   │   ├── auth/                           # Login (DNI + bcrypt)
│   │   ├── checklist/                      # Checklists mensuales
│   │   ├── employees/                      # Personal
│   │   ├── expirations/                    # Vencimientos + auditoría + calendario
│   │   ├── home/                           # Panel principal post-login
│   │   ├── reports/                        # Reportes Excel (flota / checklist / consumo)
│   │   ├── revisions/                      # Sistema de revisión admin/chofer
│   │   ├── sync_dashboard/                 # Observabilidad del AutoSync Volvo
│   │   ├── vehicles/                       # Flota + diagnóstico Volvo
│   │   └── whatsapp_bot/                   # Cola y bandeja del bot Node.js
│   ├── routing/app_router.dart
│   ├── shared/
│   │   ├── constants/app_colors.dart       # Paleta semántica
│   │   ├── utils/
│   │   │   ├── app_feedback.dart           # SnackBars semánticos
│   │   │   ├── digit_only_formatter.dart
│   │   │   ├── fecha_input_formatter.dart  # DD/MM/AAAA
│   │   │   ├── formatters.dart             # AppFormatters (fechas, CUIL, KM, días)
│   │   │   ├── ocr_service.dart            # ML Kit on-device
│   │   │   ├── password_hasher.dart        # Bcrypt + SHA-256 dual
│   │   │   ├── upper_case_formatter.dart
│   │   │   └── whatsapp_helper.dart        # wa.me click-to-chat
│   │   └── widgets/
│   │       ├── app_*                       # AppCard, AppListPage, AppScaffold...
│   │       ├── app_confirm_dialog.dart     # Confirmaciones (modo destructivo)
│   │       ├── app_loading_dialog.dart     # Modal "cargando..."
│   │       ├── command_palette.dart        # Búsqueda Ctrl+K
│   │       ├── fecha_dialog.dart           # pickFecha(...)
│   │       └── guards/                     # AuthGuard, RoleGuard, AdminGuard
│   ├── firebase_options.dart
│   └── main.dart                           # Provider tree completo
├── whatsapp-bot/                           # PROYECTO NODE.JS SEPARADO
│   ├── src/
│   ├── package.json
│   └── README.md
├── scripts/                                # Scripts Python (migraciones, carga inicial)
├── firestore.rules                         # Reglas de seguridad Firestore
├── storage.rules                           # Reglas de seguridad Storage
├── firebase.json
├── serviceAccountKey.json                  # NO en git — admin SDK (scripts y bot)
├── pubspec.yaml
├── ESTADO_PROYECTO.md                      # ESTE archivo
└── AUDITORIA_2026-04-28.md
```

**Patrón Volvo**: `VolvoApiService` → `VehiculoRepository` → `VehiculoManager` → `VehiculoProvider` (todos en provider tree de `main.dart` con `ProxyProvider2`).

**Patrón bot WhatsApp**: `[App Flutter]` escribe a `Firestore: COLA_WHATSAPP` → `[Bot Node.js]` con Admin SDK escucha cambios → procesa con anti-throttle → manda WhatsApp → si el chofer responde con comprobante, el bot intenta auto-asociarlo o lo deja en `RESPUESTAS_BOT_AMBIGUAS` para que el admin despache desde la bandeja.

## 4. Convenciones importantes (NO romper)

### Datos
- **Nombres de choferes**: campo `NOMBRE` con formato `APELLIDO NOMBRE SEGUNDO_NOMBRE`. El saludo siempre toma `partes[1]` (nombre real). Si solo hay un token, saludo genérico.
- **DNIs**: `String` sin guiones/espacios. `documentId` en `EMPLEADOS`.
- **Patentes**: `String` mayúscula. `documentId` en `VEHICULOS`.
- **Teléfonos**: helper `WhatsAppHelper._normalizarNumeroAr` acepta varios formatos AR (con/sin 0, con/sin 15, con/sin +54).
- **Fechas en Firestore**: `Timestamp` (nuevo) o `String` ISO (legacy). Helper `_parseDate` en cada modelo.
- **Campos de vencimiento**: convención `VENCIMIENTO_<NOMBRE>` y `ARCHIVO_<NOMBRE>`. El sistema de revisiones depende de esto (`replaceAll('VENCIMIENTO_', 'ARCHIVO_')`).

### Centralizaciones (sumar tipos nuevos solo en estas listas)
- **Tipos de vehículo**: `AppTiposVehiculo` en `app_constants.dart`.
- **Vencimientos por tipo**: `AppVencimientos.tractor` y `.enganche` en `vencimientos_config.dart`.
- **Roles**: `ADMIN` y `USUARIO` (no "CHOFER").
- **Rutas**: `AppRoutes` en `app_constants.dart`, no hardcodear strings.
- **Colores semánticos**: `AppColors.success/error/warning/info/...`. **NO** hardcodear `Colors.greenAccent`. Para colores del tema usar `Theme.of(context)`.

### UI/UX
- **Inputs de fecha**: SIEMPRE `pickFecha(...)` (`shared/widgets/fecha_dialog.dart`). NO usar `showDatePicker` (cliente lo odia).
- **SnackBars**: SIEMPRE `AppFeedback.success/error/warning/info(context, msg)`. Para post-await: `successOn(messenger, msg)`.
- **Loading modal**: `AppLoadingDialog.show(context, mensaje?)` / `AppLoadingDialog.hide(navigator)`.
- **Confirmaciones**: `AppConfirmDialog.show(...)` con `destructive: true` para acciones de riesgo.
- **Inputs numéricos**: agregar `DigitOnlyFormatter` en `inputFormatters` además de `keyboardType` (cubre paste y desktop).
- **Búsqueda**: `Ctrl+K` (Cmd+K en Mac) abre `CommandPalette`. Para abrir detalles desde otros features usar `abrirDetalleChofer(context, dni)` o `abrirDetalleVehiculo(context, patente, data)`.

### Logging y auditoría
- **Errores**: `AppLogger.recordError(error, stack, reason: ..., fatal: false)`. En mobile va a Crashlytics; en desktop solo `debugPrint`.
- **Logs de info**: `AppLogger.log(mensaje)` reemplaza `debugPrint` esparcidos.
- **Acciones admin**: `AuditLog.registrar(accion: ..., entidad: ..., entidadId: ..., detalles: {...})`. Es fire-and-forget; nunca bloquea.

## 5. Decisiones técnicas con su razón

| Decisión | Por qué |
|---|---|
| Firebase Auth con **custom token** (no email/password) | Los choferes no tienen email cargado pero sí DNI+password. La function valida server-side y emite un JWT con `uid = DNI` y rol como custom claim — `request.auth.uid` en las rules es el DNI directo |
| **Rol como custom claim** en el JWT (no en cada regla) | Evita una lectura extra de Firestore por cada regla evaluada. Si admin cambia el rol de un user, ese user mantiene el claim viejo hasta el próximo login (~1 hora máx). Aceptable |
| Cloud Function en Node.js | Consistencia con el bot WhatsApp, mismo runtime y mismo `firebase-admin` |
| Firestore queries con `orderBy` en cliente para `AVISOS_VENCIMIENTOS` | Evitar fricción del índice compuesto que Firestore pediría crear manualmente |
| `AutoSyncService` en provider tree | Su lifecycle (start/stop) lo maneja Provider, no el state del root widget |
| Volvo Connect via `additionalContent=VOLVOGROUPSNAPSHOT` | Sin ese flag el response NO trae `fuelLevel` ni `estimatedDistanceToEmpty` |
| `estimatedDistanceToEmpty` lo busca en `snapshotData.volvoGroupSnapshot` | El path real para diésel; los `chargingStatusInfo` son para EVs |
| Bot WhatsApp en Node.js separado, no Twilio | Se monta en un servidor del cliente con `whatsapp-web.js`. Costo cero, pero requiere mantener una sesión QR escaneada y un proceso vivo |
| Click-to-Chat (`wa.me`) para avisos manuales del admin | Complementa al bot: cuando el admin quiere mandar algo puntual sin pasar por la cola |
| `StorageService` con `Uint8List` + `putData` | `dart:io.File` no funciona en Web. El refactor hace los uploads cross-platform |
| Reportes Excel con guard de `kIsWeb` | El package `excel` toca `dart:io` para guardar; en Web mostraría error. Se muestra snackbar |
| OCR opcional con propiedad `soportado` | ML Kit solo Android/iOS. En Web/Windows el botón "Detectar fecha" se oculta |
| Campo "Preocupacional" tanto en UI como en Firestore | Migración completa hecha el 2026-04-28 vía `scripts/migrar_psicofisico_a_preocupacional.py` |

## 6. Lo que ya está hecho

### 6.1 Auditoría inicial (28 abril mañana)
Reporte: `AUDITORIA_2026-04-28.md`. Resueltos: credenciales Volvo hardcodeadas, `secrets.json` confirmado fuera de git, `mounted` checks en formularios, `unawaited` en lugares clave.

### 6.2 Refactor cross-platform + features Volvo (28 abril PM)
- Telemetría Volvo en pantalla del chofer y admin (odómetro, % combustible con barra, autonomía km).
- Panel diagnóstico Volvo (botón 🐛 en ficha del vehículo): muestra request, status, JSON crudo, análisis de campos críticos (✓/✗).
- Sync Dashboard ampliado: eventos por unidad (último 50), histórico de ciclos (último 15), botón "ejecutar ahora", motivos de skip detallados.
- Tipos de vehículo: BIVUELCO, TANQUE.
- Vencimientos nuevos en tractores: Extintor Cabina, Extintor Exterior.
- MAIL y TELÉFONO editables en gestión de personal y visibles en mi perfil.
- Foto/PDF reemplazable desde admin para los papeles del chofer (sin pasar por flujo de revisión).
- Botón "Avisar por WhatsApp" en cada vencimiento en auditoría con mensaje pre-armado según días restantes.
- Historial de avisos por vencimiento (`AVISOS_VENCIMIENTOS`) con bloque colapsable en el editor.
- Reporte Checklist abre Excel directo en Windows.
- Calendario reemplazado por input DD/MM/AAAA con validación inline.
- **Migración total `Psicofísico` → `Preocupacional`** en código y Firestore vía script Python idempotente.
- **Refactor cross-platform de uploads**: `StorageService.subirArchivo` con `Uint8List` + `putData`. Todos los callers actualizados. App compila y corre en Web sin crashear en flujos de subida.
- Reportes Excel con guard de Web.
- Permisos Android 13+: `POST_NOTIFICATIONS`, `CAMERA`, `<uses-feature>` opcional.

### 6.3 Sprints 1-3 de UX/calidad (28 abril PM)
- **Sprint 1**: `AppConfirmDialog` + confirmaciones destructivas en DESVINCULAR equipo y RECHAZAR revisión. Auditoría de feedback en todos los `update`/`set`/`delete` del admin.
- **Sprint 2**: `AppFeedback` (SnackBars semánticos), `AppLoadingDialog`, `DigitOnlyFormatter`. 46 SnackBars dispersos migrados, 2 loadings ad-hoc consolidados, `keyboardType: emailAddress` en mail.
- **Sprint 3**: pulido visual ("Nuevo Legajo" → "Nuevo chofer", tooltips en FABs, iconografía vencimientos unificada a `Icons.event_note`), `AppColors` centralizada.

### 6.4 Sprint 4 — Quick wins de productividad (28 abril PM)
- **Foto del vehículo**: campo `ARCHIVO_FOTO` en VEHICULOS. Avatar circular en `_VehiculoCard`. Bloque "Cambiar foto" en form de edición.
- **Búsqueda Ctrl+K**: `CommandPalette` indexa choferes + vehículos + revisiones con fetch one-shot, filtro local. Atajo en `admin_shell.dart` + IconButton en AppBar. Funciones `abrirDetalleChofer/Vehiculo/Revision` para uso desde otros features.
- **Calendario de vencimientos**: pantalla `admin_vencimientos_calendario_screen.dart` con `table_calendar`. Vista mensual con dots por urgencia (rojo ≤7 días, naranja 8-30, verde >30). Tap en día muestra lista; tap en ítem abre `VencimientoEditorSheet`.

### 6.5 Sprints 5-8 (28 abril noche) — Bot de WhatsApp y reporte de consumo
- **Reporte de consumo Excel** (`report_consumo.dart`): dialog para rango de fechas + columnas. Estrategia dual: si hay snapshots en `TELEMETRIA_HISTORICO` calcula consumo REAL del período; si no, fallback a `accumulatedData.totalFuelConsumption` y marca "(acum.)". Dos hojas: DETALLE + RANKING (top 10 con barras Unicode).
- **Snapshot diario de telemetría**: el AutoSync escribe a `TELEMETRIA_HISTORICO` (en futuro debería migrar al bot/Cloud Function).
- **Bot WhatsApp Fase 1**: encolar avisos manuales del admin a `COLA_WHATSAPP`. Bot Node.js procesa con anti-throttle. Pantalla `admin_whatsapp_cola_screen.dart` para ver estado (PENDIENTE/PROCESANDO/ENVIADO/ERROR) y reintentar/eliminar.
- **Bot WhatsApp Fase 2**: avisos automáticos por vencimientos. El bot programa los envíos según días restantes (30/15/7/1/0/-X) con idempotencia (colección `AVISOS_AUTOMATICOS_HISTORICO`).
- **Bot WhatsApp Fase 3**: bandeja de respuestas ambiguas (`admin_bot_bandeja_screen.dart`). Cuando el chofer manda foto sin contexto claro, el bot la deja con OCR ya aplicado y el admin elige a qué papel asociarla → se convierte en revisión.

### 6.6 Auditoría de seguridad (29 abril mañana)
- **Rotación de key Firebase**: la `private_key_id` anterior se revocó. Nuevo `serviceAccountKey.json` distribuido fuera de git.
- **Limpieza git history**: borrados commits viejos que tenían secretos hardcodeados con `git filter-repo`. Force-push al remoto (por eso la divergencia que tuvimos).
- **Firestore.rules + Storage.rules**: publicadas. Dejan abiertas las colecciones operacionales (read/write) porque la app no usa Firebase Auth, pero bloquean específicamente:
  - `AVISOS_AUTOMATICOS_HISTORICO` (write false — solo bot via Admin SDK).
  - `RESPUESTAS_BOT_AMBIGUAS` (write false — solo bot).
  - `RESPUESTAS_BOT/{archivo}` en Storage (write false — solo bot sube fotos recibidas).
  - Fallback `match /{document=**} { allow read, write: if false; }` para cualquier colección NO listada → si agregás una nueva sin sumarla a las rules, se rompe.
- **Fixes en bot Node.js**: sanitización de path (evita `../`), match estricto de teléfono, backoff exponencial en reintentos, grace shutdown (espera mensajes en vuelo antes de cerrar).
- **`AppConfirmDialog`** migrado a `AppColors` (antes hardcodeaba colores).

### 6.7 Servicios de logging y auditoría (28 abril PM)
- **`AppLogger`** en `lib/core/services/app_logger.dart`: `init()` engancha `FlutterError.onError` y `PlatformDispatcher.onError`. `log()`, `recordError()` con destino según plataforma (Crashlytics en mobile, debugPrint en desktop/web).
- **`AuditLogService`** en `lib/core/services/audit_log_service.dart`: enum `AuditAccion` con 12 casos (crear/editar chofer/vehículo, asignar/desvincular equipo, aprobar/rechazar revisión, cambiar foto, reemplazar papel). Escribe a `AUDITORIA_ACCIONES` con admin DNI/nombre, timestamp, detalles. Fire-and-forget — si falla, no bloquea.

### 6.8 OCR para detectar fechas (Sprint bot)
- **`OcrService`** en `lib/shared/utils/ocr_service.dart`: `detectarFecha(path)` con Google ML Kit on-device. Regex para `DD/MM/YYYY`, `DD-MM-YYYY`, `DD.MM.YYYY`. Devuelve la fecha más lejana en el futuro (asume que el último vencimiento es el de renovación). Property `soportado` para ocultar UI en Web/Windows.

### 6.9 Sesión 30 abril 2026 — Cleanup, RBAC, robustez del bot

#### 6.9.1 Cleanup app
- Eliminado el botón "AVISAR POR WHATSAPP" + dependencias muertas (~970 líneas): `whatsapp_helper.dart`, `aviso_vencimiento_service.dart`, `aviso_vencimiento_builder.dart`, `_HistorialAvisos` widget, test asociado. La app ya no encolaba mensajes manualmente — todo pasa por el bot Node.js.
- Colección `AVISOS_VENCIMIENTOS` borrada de Firestore (13 docs huérfanos).

#### 6.9.2 Pantalla "Estado del Bot"
- Bot escribe `BOT_HEALTH/main` cada 60s con: estado del cliente WA, cola actual, último ciclo del cron, último mensaje, errores recientes (ring buffer 10), config, info del proceso (versión, pid, uptime).
- Pantalla `lib/features/admin_dashboard/screens/admin_estado_bot_screen.dart` con StreamBuilder + refresh cada 5s. Banner verde/amarillo/rojo según último heartbeat (>2min sin heartbeat = bot caído). 6 cards con datos en vivo. Tile nuevo en `admin_panel`.
- Module `whatsapp-bot/src/health.js`: `iniciar()`, `setEstadoCliente()`, `registrarEnvio()`, `registrarError()`, `registrarCicloCron()`. Hooks integrados en `index.js`, `whatsapp.js`, `cron.js`.

#### 6.9.3 Robustez del bot Node.js
- **Reintentos con backoff**: clasificación de errores transitorios vs definitivos (timeout/ECONN*/session closed → transitorio). Default: 30s, 2min, 10min de backoff. Después de MAX_RETRIES=3 fallos, escala a ERROR. Field nuevo `proximoIntentoEn` en COLA_WHATSAPP que el polling respeta. Helper `marcarReintento()` en firestore.js.
- **Watchdog del evento `READY`**: bug conocido de wwebjs (issue #5758) donde tras `authenticated` el `ready` nunca llega por A/B testing de WhatsApp Web 2.3000.x. Si pasa READY_TIMEOUT_SEC=90s sin ready, mata el cliente y reinicializa (sin reescaneo de QR). Después de MAX_READY_TIMEOUTS=3 timeouts seguidos, exit 1 → supervisor reinicia el proceso. Validado en producción: primer arranque cae en el bug, watchdog dispara a los 90s, segundo intento llega a ready en 1s.
- **`webVersionCache: 'remote'`** apuntando a `wppconnect-team/wa-version` para usar siempre versión estable de WhatsApp Web (bypaseando el A/B testing problemático).
- **Upgrade `whatsapp-web.js` 1.27.0 → 1.34.6** (en producción local quedó 1.34.7).

#### 6.9.4 Campo APODO
- Nuevo campo opcional `apodo` en EMPLEADOS. Resuelve casos donde el algoritmo de "segundo token" del NOMBRE falla (dos apellidos, segundo nombre como "Carlos" en "PEREZ JUAN CARLOS").
- Modelo `Empleado`: campo `apodo` (String?) opcional. Form de alta y editor del detalle lo incluyen.
- Saludo del panel admin lee `EMPLEADOS/{dni}.APODO` lazy una vez; si está, prevalece sobre el algoritmo.
- Bot Node.js: `aviso_builder.resolverNombreSaludo(empleadoData)` prioriza APODO sobre `extraerPrimerNombre(NOMBRE)`. 3 call sites en cron.js usan el helper.
- **Fix bonus**: el form decía "Nombre y apellido completo" pero el algoritmo asume "APELLIDO NOMBRE". Cambiado a "Apellido(s) y nombre(s)" — el malentendido inducía a admins a cargar choferes con orden invertido y rompía la extracción.

#### 6.9.5 Sistema RBAC: 4 roles + 5 áreas + capabilities
**Roles** (definen QUÉ puede hacer cada usuario):
- `CHOFER`: empleado de manejo con vehículo asignado. Ve sus vencimientos personales + su unidad.
- `PLANTA`: empleado sin vehículo (planta, taller, gomería, administración). Solo ve sus vencimientos.
- `SUPERVISOR`: mando medio. Gestiona personal/flota/vencimientos/revisiones/bot. NO puede crear admins ni cambiar roles.
- `ADMIN`: control total. Crear admins, cambiar roles, auditoría, sync dashboard.

**Áreas** (define DÓNDE trabaja la persona, descriptivo):
- `MANEJO`, `ADMINISTRACION`, `PLANTA`, `TALLER`, `GOMERIA`.

**Componentes**:
- `lib/core/constants/app_constants.dart`: `AppRoles` con 4 roles + helpers `tieneVehiculo()`, `normalizar()` (legacy USUARIO → CHOFER). `AppAreas` con 5 áreas + `defaultParaRol()`.
- `lib/core/services/capabilities.dart` (nuevo): enum `Capability` con 17 acciones gateadas. `Capabilities.can(rol, cap)` chequea permisos. ADMIN hereda todo de SUPERVISOR + capabilities exclusivas.
- `lib/shared/widgets/guards/role_guard.dart`: parámetro nuevo `requiredCapability` (preferido sobre `requiredRole`).
- `lib/routing/app_router.dart`: `_protegerAdmin()` ahora usa `Capability.verPanelAdmin` (deja pasar ADMIN y SUPERVISOR). Nuevo `_protegerSoloAdmin()` para rutas reservadas a ADMIN (ej. SyncDashboard).
- `lib/features/admin_dashboard/screens/admin_panel_screen.dart`: tiles condicionales según capability del usuario logueado.
- `lib/features/employees/screens/admin_personal_form_screen.dart`: dropdowns ROL (4 opciones con descripción + ícono) y ÁREA (5 opciones). Mensaje cambió de "Chofer creado" a "Empleado creado".
- `lib/features/employees/screens/admin_personal_lista_screen.dart`: chip de área en card cuando el rol no es CHOFER, lógica `mostrarFlota = (area == MANEJO)`. `_RolBadge` con colores por rol. `_DatoEditableEnum` para editar ROL/ÁREA.
- Cloud Function nueva `actualizarRolEmpleado` (callable, solo ADMIN): actualiza ROL/ÁREA + refresca custom claim del usuario afectado + libera VEHICULO/ENGANCHE en EMPLEADOS si pasa de CHOFER a otra cosa, Y marca esas patentes como `ESTADO=LIBRE` en VEHICULOS.
- Cloud Function `loginConDni` actualizada: normaliza ROL legacy USUARIO/USER → CHOFER, agrega claim `area`.
- `firestore.rules`: helpers nuevos `isSupervisor()`, `isAdminOrSupervisor()`. 8 reglas migradas a usar el combinado para que SUPERVISOR pueda gestionar.
- Migración aplicada con `scripts/migrar_roles.js` (idempotente, --dry-run + --apply): 57 empleados normalizados a CHOFER+MANEJO o ADMIN+ADMINISTRACION.

#### 6.9.6 Robustez operativa del bot (parte 2)
- **Kill-switch**: nuevo `whatsapp-bot/src/control.js`. Toggle en la pantalla "Estado del Bot" (admin only) escribe `BOT_CONTROL/main.pausado=true|false`. El bot lo lee con cache TTL 10s antes de procesar cada item de la cola. Si está pausado, deja los docs en PENDIENTE para retomar al reanudar. Rule: read isAdminOrSupervisor, write isAdmin.
- **Anti-baneo: variantes de texto**: `aviso_builder.js` ahora tiene 2-3 variantes por nivel de urgencia. `_pick(arr)` elige una random. Choferes que vencen en el mismo día con la misma urgencia ya no reciben mensajes idénticos.
- **Throttle por chofer**: `cron.js` pre-carga un Map<telefono, count> de avisos encolados HOY al inicio de cada ciclo. Antes de cada add chequea `yaSuperoTope()` y salta si ya alcanzó `MAX_AVISOS_POR_CHOFER_DIA=2`. Helper `_inicioDelDia()` para definir "hoy".
- **Modo dry-run**: `BOT_DRY_RUN=true` hace que `whatsapp.enviarMensaje()` devuelva un id sintético sin tocar el cliente real. Util para testing sin spammear choferes.
- **Comandos admin por WhatsApp**: nuevo `whatsapp-bot/src/commands.js`. Mandando al propio número del bot un mensaje `/estado`, `/pausar [dur]`, `/reanudar`, `/forzar-cron`, `/ayuda` desde un teléfono en la whitelist `ADMIN_PHONES`. Útil para operar desde el celular cuando estás afuera de la PC. Cron exporta `forzarRunOnce()` para `/forzar-cron`.

### 6.10 Sesión 1-mayo 2026 — Imports bulk + fixes UI + auditoría profunda + plan 4 fases

#### 6.10.1 Imports bulk de datos desde Excel → Firestore
- **`scripts/importar_servicios_y_matafuegos.py`** (uso único, snapshot Excel removido tras aplicar). Mapeo: `KM ULTIMO SERVICE` → `ULTIMO_SERVICE_KM` (num); `FECHA ULTIMO` → `ULTIMO_SERVICE_FECHA` (string ISO); `MATAFUEGO CHASIS` → `VENCIMIENTO_EXTINTOR_EXTERIOR`; `MATAFUEGO CABINA` → `VENCIMIENTO_EXTINTOR_CABINA`. Reglas: patente ausente skipea+reporta, celda vacía no toca campo existente, sobreescribe valores previos, idempotente, warnings de fechas futuras > 30d. **56 patentes actualizadas**.
- **`scripts/importar_apodos.py`** (uso único, snapshot Excel removido). Matching exacto por `NOMBRE` normalizado (Unicode NFD + uppercase + strip, así `SCHRÖDER`=`SCHRODER` y `IBAÑEZ`=`IBANEZ`). Fallback starts-with si hay un único candidato (caso `VICTOR RAUL` → `VICTOR RAUL JESUS`). Detecta header CHOFER/NOMBRE/APELLIDO/APODO. **53 choferes con APODO seteado**, 2 no encontrados (no estaban dados de alta aún).

#### 6.10.2 Fixes UI
- **Ficha admin del vehículo (extintores no se veían)**: `admin_vehiculos_lista_screen.dart` tenía los vencimientos hardcoded a RTO + Póliza Seguro. Reemplazado por `for (final spec in AppVencimientos.forTipo(data['TIPO']))` → los TRACTORES ahora muestran los 4 vencimientos (Extintor Cabina/Exterior incluidos), los enganches siguen mostrando 2. Mismo patrón bug que se arreglaría después en Fase 2 con `AppDocsEmpleado`.
- **Chips clickeables en MANTENIMIENTO PREVENTIVO**: `admin_mantenimiento_screen.dart` tenía los chips del header (Vencidos/Urgentes/Programar/Falta poco/OK) como solo visualizadores de conteos. Ahora cada uno es clickeable: tap filtra la lista a ese estado, tap mismo chip lo deselecciona, tap a otro cambia el filtro. Chip activo se resalta (fondo + borde + label en bold blanco). Conteos siguen globales (calculados sobre `sorted`, no sobre `filtrados`) para que el admin sepa cuántos hay en cada estado y pueda saltar de uno a otro. Search por texto se aplica encadenado al filtro de estado.
- **Unificación sidebar admin + panel central**: tenían ordenes y nombres distintos (sidebar decía "Service", panel "MANTENIMIENTO PREVENTIVO"; "Sync" vs "SYNC OBSERVABILITY"; etc). Confundía. Sumamos `Estado Bot` al sidebar como destino #9 y reordenamos+renombramos los tiles del panel para coincidir 1-a-1 con el sidebar: `Revisiones / Flota / Service / Personal / Vencimientos / Reportes / Sync / Estado Bot`. Capabilities preservadas en cada tile.

#### 6.10.3 Auditoría profunda con 2 agentes paralelos
Después de los fixes UI, lanzamos 2 agentes en paralelo para revisión estructural:
- **Agente cliente Flutter**: bugs latentes, listas hardcoded vs config centralizada, convenciones rotas, dead code, capabilities mal aplicadas, streams sin dispose. 11 findings.
- **Agente backend** (Functions + bot + rules): race conditions, idempotencia, validaciones faltantes, secrets, manejo de errores, observabilidad, gaps de seguridad. 21 findings.

De los 32 findings totales, deduplicados a un plan de **17 items en 4 fases** ordenados por severidad y costo. Falsos positivos descartados (los mismatches de `MANTENIMIENTOS_AVISADOS` y `BOT_CONTROL` tenían rules ya alineadas con la intención).

#### 6.10.4 Plan de 4 fases ejecutado completo

**Fase 1 — Bugs latentes / seguridad**
- **#1+#2 [rbac]**: capabilities `cambiarRolEmpleado` y `asignarRolAdmin` que estaban definidas en el enum pero NO se chequeaban en UI ahora se aplican. En `admin_personal_lista_screen.dart` el dropdown ROL filtra la opción "Admin" si el usuario no tiene `asignarRolAdmin`, y queda no-editable (icono atenuado, sin onTap) si no tiene `cambiarRolEmpleado` (sumamos `editable: bool = true` a `_DatoEditableEnum`). En `admin_personal_form_screen.dart` el `_RoleSelector` filtra `AppRoles.todos` para esconder ADMIN. Sidebar admin (`admin_shell.dart`) ahora filtra `_sections` por `requiredCapability` igual que el panel central — SUPERVISOR ya no ve el destino "Sync" (es solo de ADMIN). Clamp defensivo del `_currentIndex` por si el rol cambia mid-session.
- **#3 [functions/security]**: rate limit del login con check dentro de la transacción. Antes había `chequearBloqueoActivo` (un `get()` suelto previo) + `registrarIntentoFallido` (transacción) en pasos separados — ventana de race con fuzzing concurrente. Ahora `registrarIntentoFallido` devuelve un objeto `ResultadoIntentoFallido { intentos, bloqueadoMinRestantes }` que reporta el bloqueo atómicamente desde la misma transacción. El chequeo previo sigue como optimización para no quemar bcrypt cuando ya está bloqueado.
- **#4 [bot/security]**: whitelist de extensiones (`['jpg','png','pdf']`) en `whatsapp-bot/src/message_handler.js`. Antes el fallback `'bin'` dejaba pasar cualquier mimetype falsificado a Storage. Stickers webp se rechazan.
- **#5 [bot/cron]**: idempotencia robusta del service preventivo. Nueva función `historico.yaSeEnvioServiceMaxUrgencia` que para SERVICE itera la urgencia actual hacia las MAYORES y chequea si alguna ya fue notificada (incluido prefix-query Firestore para `service_vencido` que tiene fecha del día en la key). Evita el rebote cuando el admin edita `ULTIMO_SERVICE_KM` por error y la urgencia baja sin que el service realmente se hizo. Constante `ORDEN_URGENCIAS_SERVICE = ['service_atencion', 'service_programar', 'service_urgente', 'service_vencido']`.
- **#6 [rules]**: `RESPUESTAS_BOT_AMBIGUAS` separada en `read+delete: isAdminOrSupervisor` y `create+update: false`. Antes permitía cualquier write con isAdminOrSupervisor; ahora solo el bot via Admin SDK puede crear, y admin/supervisor solo descartan o convierten a revisión (delete). Verificado contra el cliente: `admin_bot_bandeja_screen.dart` solo hace `.delete()` y `batch.delete()`.

**Fase 2 — Limpieza estructural**
- **#7 [refactor]**: nueva clase `AppDocsEmpleado` en `vencimientos_config.dart` con `etiquetas` (Map<String, String> de los 7 documentos del empleado). Antes había 4 copias del mismo mapa con nombres distintos (`_docsEmpleado` x2, `_documentosAuditados`, `_docsAgendables`) en pantallas distintas — mismo patrón bug que los extintores. Migrados: `admin_panel_screen`, `admin_vencimientos_calendario_screen`, `admin_vencimientos_choferes_screen`, `user_mis_vencimientos_screen`. Net −19 líneas reales.
- **#8 [ui]**: sweep de colors hardcoded a `AppColors.success/error/warning/info` (semánticos) y `AppColors.accentGreen` (decorativos). Migrados 26 call sites en 3 archivos: `notification_service.dart` (5 — los 3 canales de notificación nativa: vencimientos→warning, mantenimiento→error, nueva revisión→success), `admin_estado_bot_screen.dart` (17 — switch _Salud, alertas pendientes/errores, toggle pausado, kill-switch), `command_palette.dart` (4). Otros archivos con migración incremental cuando se toquen.
- **#9 [parsing]**: `AppFormatters.tryParseFecha(dynamic)` público (alias del privado `_parseUniversalDate`) que acepta múltiples formatos (ISO, DD-MM-YYYY, DD/MM/YYYY, DateTime nativo). Migrados 9 call sites en 6 pantallas (`vencimiento_editor_sheet`, `empleado_actions`, `user_mis_vencimientos`, `admin_vencimientos_calendario` x2, `admin_mantenimiento`, `admin_vehiculo_form` x2). Beneficio extra: arregla bug de timezone donde `30/05` aparecía como `29/05` en zonas UTC-3 (`tryParseFecha` construye `DateTime` local explicit, no UTC midnight).
- **#10 [storage]**: `storage.rules` de `REVISIONES` ahora valida `request.resource.contentType.matches('image/.*|application/pdf')` y `size < 10 MB`. Antes admitía cualquier mimetype, lo que permitía subir `.exe` enmascarados. Los mismatches que detectaba la auditoría en Firestore (`MANTENIMIENTOS_AVISADOS`, `BOT_CONTROL`) resultaron falsos positivos: las rules ya estaban alineadas con la intención documentada.

**Fase 3 — Performance + observabilidad**
- **#11 [bot/perf]**: cache en memoria con TTL configurable (default 5min) para `_resolverChofer` en `message_handler.js`. Antes leía toda `EMPLEADOS` por mensaje entrante (~57 reads cada uno; con 100 mensajes/día eran ~5700 reads). Ahora ~57 reads cada TTL. Configurable vía `EMPLEADOS_CACHE_TTL_MS` env.
- **#12 [bot/tz]**: `process.env.TZ = process.env.BOT_TIMEZONE || 'America/Argentina/Buenos_Aires'` al **top** de `index.js`, antes de cualquier `require()` que dependa de fechas (cron, historico, calcularDiasRestantes). Configurable vía `BOT_TIMEZONE`. Previene desfase de 1 día si el bot se migra a Cloud Run región UTC.
- **#13 [functions/perf]**: `telemetriaSnapshotScheduled` timeout `120s → 45s`. Las invocaciones reales nunca pasan de 20s; los 75s extra eran costo innecesario.
- **#14 [functions/security]**: validación `VIN_REGEX = /^[A-Z0-9]{17}$/` en `volvoProxy` antes de forwardear (cases `telemetria` y `kilometraje`). Antes solo chequeaba no-vacío; un VIN malformado se mandaba a Volvo y comía timeout completo.

**Fase 4 — Drift / nice-to-have**
- **#15 [.gitattributes]**: nuevo archivo `.gitattributes` en la raíz que normaliza line-endings: LF para texto, CRLF solo para `*.ps1`/`*.bat`/`*.cmd`, binarios untouched. Después `git add --renormalize .` para fijar todo el repo. Antes el drift LF/CRLF mezclaba cambios reales con EOL changes en cada commit — nos mordió varias veces durante esta misma sesión. **Recomendado en Windows**: `git config --global core.autocrlf input`.
- **#16 [imports muertos]**: los 2 candidatos del handoff (`selectNotificationStream` en `notification_service.dart`, `intl` en `admin_bot_bandeja_screen.dart`) resultaron falsos positivos. Ambos sí se usan: el stream lo escucha `main.dart:137` para navegar al tap de notificación, y `intl` lo usa `DateFormat('dd/MM HH:mm').format(...)` en línea 234. `flutter analyze` global confirma 0 issues.
- **#17 [refactor AlertDialog en empleado_actions]**: NO ejecutado en esta sesión. Es un cambio más grande de UX (extraer el dialog ad-hoc de asignación de equipo a una pantalla o BottomSheet) y no es urgente. Queda para futura iteración.

#### 6.10.5 Validaciones de cierre
- `flutter analyze` (todo el proyecto): **0 issues**.
- `flutter test`: **25/25 tests pasan**.
- `tsc --noEmit` en `functions/`: limpio.
- `node --check` en archivos modificados del bot: limpio.

#### 6.10.6 Deploys requeridos al cierre
- **Cloud Functions**: `firebase deploy --only functions:loginConDni,functions:telemetriaSnapshotScheduled,functions:volvoProxy`.
- **Firestore rules**: `firebase deploy --only firestore:rules`.
- **Storage rules**: `firebase deploy --only storage`.
- **Bot Node.js**: reiniciar el proceso (Ctrl+C + `node src/index.js`) para que tome whitelist + idempotencia service + cache empleados + TZ env var.

### 6.11 Sesión 1-mayo 2026 (PM/noche) — Bot panel + NSSM multi-PC + TZ hardening + feriados + service consolidado a Emmanuel + setup operativo

Sesión muy larga, varios bloques temáticos. Todo pusheado a `origin/main`.

#### 6.11.1 Mejoras al panel del bot en la app (commit `a1da6bc`)
- **`admin_whatsapp_cola_screen.dart`**: chips clickeables en la fila de contadores (PENDIENTES/PROCESANDO/ENVIADOS/ERROR) con toggle del filtro, igual patrón que mantenimiento. Tap en cualquier item abre un BottomSheet `_DetalleColaSheet` con detalle completo: mensaje sin truncar (selectable), lista de papeles agrupados con estado humano ("vencido hace 3d"), línea de tiempo (encolado/enviado/próximo reintento), metadata (origen/destinatario/admin/ID copiable), error completo monoespaciado. Nuevo badge cyan `_BadgeAgrupado` (📎 Nx) junto al estado cuando `items_agrupados.length > 0`. La pantalla acepta `initialFilter` opcional para deep-link.
- **`admin_estado_bot_screen.dart`**: cada fila de `_CardCola` (Pendientes/En proceso/Reintentando/Con error) ahora navega a la cola filtrada por ese estado vía `MaterialPageRoute` (las rutas `AdminWhatsAppColaScreen` siguen huérfanas en `app_router.dart`, decisión: push directo es lo más simple). `_BloqueDatos` ganó `mostrarChevron` (hint "TOCAR PARA VER" en header). `_Fila` acepta `onTap` opcional → InkWell + chevron sutil.
- **Sección 12 ESTADO_PROYECTO**: agregada nota sobre lockfile residual en `.git/` tras comandos del sandbox + workaround PowerShell + regla preventiva para Claude.

#### 6.11.2 NSSM modo manual + check anti-doble-bot multi-PC (commits `8c45374` y `0c0403d`)
Permite tener el bot instalado en 2 PCs (casa + oficina) sin que ambas procesen la cola al mismo tiempo (mensajes duplicados → riesgo de baneo de WhatsApp).
- **`instalar_servicio.ps1`**: `SERVICE_AUTO_START` → `SERVICE_DEMAND_START` (modo manual). Path derivado de `$PSScriptRoot` (no más hardcoded). No arranca el servicio al terminar la instalación. ASCII-only (sin acentos/emojis) para evitar problemas de encoding cuando PowerShell lee `.ps1` como ANSI.
- **`start_bot.ps1` / `stop_bot.ps1`** (nuevos): `start` hace git pull + npm install + `nssm start` (aborta si hay cambios sin commitear). `stop` hace `nssm stop` con espera ordenada hasta 90s respetando el grace period del bot. Auto-elevación UAC vía `Test-IsAdmin` + `Start-Process -Verb RunAs` cuando no se está como admin.
- **`src/index.js`**: constante `PC_ID = process.env.BOT_PC_ID || os.hostname() || 'desconocida'`. Función `_verificarNoHayOtraInstancia(db)` que se ejecuta antes de `wa.inicializar()`. Lee `BOT_HEALTH/main`: si `ultimoHeartbeat < UMBRAL_OTRA_INSTANCIA_SEG` (default 150s) Y `pcId` remoto ≠ propio, aborta con mensaje claro. Bypass via `FORCE_START=true`.
- **`src/health.js`**: campo `pcId: PC_ID` en el doc de heartbeat.
- **`.env.example`**: sección con `BOT_PC_ID`, `FORCE_START`, `UMBRAL_OTRA_INSTANCIA_SEG`.

#### 6.11.3 Fix bug timezone (commit `8a29a1a`)
Choferes recibían avisos por WhatsApp con fechas 1 día menos (ej. licencia que vence 30/05 aparecía como 29/05). Datos en Firestore correctos; bug en formateo del bot y en cómo se guardaban algunas fechas desde la app.

**Causa**: cuando un campo `VENCIMIENTO_X` en Firestore es un Timestamp con hora UTC midnight (caso típico de migraciones desde Python o JS con `new Date('YYYY-MM-DD')`), `getDate()` en TZ ART (UTC-3) devuelve el día anterior porque la medianoche UTC = 21h del día anterior local.

**Fix bot**: nuevo `whatsapp-bot/src/fechas.js` con helpers `aIsoLocal` y `aDdMmYyyyLocal` que normalizan cualquier formato (string ISO, Date, Timestamp Firestore con `toDate()`, JSON con `_seconds`) a `YYYY-MM-DD` seguro. Detecta si el Date es "fecha calendario" (UTC midnight exacto) o "momento real" (con hora) y elige componentes UTC vs locales según corresponda. Cableado en `cron.js` (normaliza al leer `VENCIMIENTO_X`) y `aviso_builder.js` (`formatearFecha` delega al helper).

**Fix app**: nuevo `AppFormatters.aIsoFechaLocal(DateTime)` en `lib/shared/utils/formatters.dart` que devuelve `YYYY-MM-DD` con componentes locales (blindado contra DateTime UTC). Migrados 7 call sites que usaban `.toString().split(' ').first` o `.toIso8601String().split('T').first`:
- `notification_service.dart` (idempotencia "una notif por día")
- `empleado_actions.dart`, `vencimiento_editor_sheet.dart` ×2, `admin_mantenimiento_screen.dart` ×2, `admin_vehiculo_form_screen.dart` ×2: serialización de fecha de pickFecha → string para Firestore
- `admin_panel_screen.dart`: `fechaHoy` del header

#### 6.11.4 Auto-config NSSM con icacls + PUPPETEER_CACHE_DIR (commit `8a29a1a`)
Antes el `instalar_servicio.ps1` instalaba el servicio pero hacía falta laburo manual adicional para que arrancara: dar permisos a LocalSystem sobre la carpeta del bot y de puppeteer (icacls), y setear `PUPPETEER_CACHE_DIR` para que Chrome se encontrara. Sin estos pasos el servicio crasheaba con error 1326 o "Could not find Chrome".

Ahora el script:
- Detecta el `repoRoot` y la cache de puppeteer (`$env:USERPROFILE\.cache\puppeteer`).
- Setea `AppEnvironmentExtra=PUPPETEER_CACHE_DIR=...` en NSSM.
- Aplica `icacls /grant 'NT AUTHORITY\SYSTEM:(OI)(CI)F' /T` sobre repo y cache.
- Avisa si la cache no existe y guía al usuario a correr `node src/index.js` una vez para que puppeteer baje Chrome.

#### 6.11.5 Logs verbose silenciados (commit `8a29a1a`)
6 `debugPrint` redundantes con el Sync Dashboard, comentados (no borrados):
- `[VOLVO AUTH] Auth recuperada` (volvo_api_service.dart:242)
- `[VOLVO TELE] Respuesta 200 pero sin datos utiles` (:363)
- `{patente} sin datos validos` (vehiculo_manager.dart:134)
- `AutoSync ciclo cerrado: procesados=N` (auto_sync_service.dart:159)
- `Cache Volvo cargada: N unidades` (vehiculo_manager.dart, bootstrap)
- `Provider inicializado` (vehiculo_provider.dart, bootstrap)

Mantengo activos los logs de problemas reales (rechazo auth, circuit breaker, HTTP no-2xx, errores cargando cache, errores de sync).

#### 6.11.6 Feriados nacionales ARG (commit `7fed8da`)
El bot ya no envía mensajes en feriados nacionales obligatorios (igual que ya no manda sábados/domingos). Los mensajes pendientes quedan en `PENDIENTE` y se procesan automáticamente en el próximo día hábil.
- Nuevo `whatsapp-bot/src/feriados_ar.js` con lista hardcoded de feriados nacionales obligatorios para 2026 y 2027 (sin puentes turísticos, solo los obligatorios).
- Helpers `esFeriado(date)` y `descripcionFeriado(date)`.
- `humano.js` `enHorarioHabil()` chequea feriado además de fin de semana. Nueva función `feriadoHoy()` para logs.
- **Mantenimiento anual**: actualizar `feriados_ar.js` cada par de años (comentario al top del archivo lo recuerda).

#### 6.11.7 Service preventivo consolidado a 1 destinatario (commit `7fed8da`)
Antes el aviso de service de cada tractor se enviaba al chofer asignado. Ahora va UN solo mensaje por día al encargado del área de mantenimiento (Emmanuel Corchete, DNI 29820141), con el listado completo de tractores que requieren atención.

- Nueva env var `SERVICE_DESTINATARIO_DNI=29820141` en `.env.example`.
- Nuevo `avisoService.buildResumenDiario({apodo, tractores})` que construye el mensaje consolidado con iconos por urgencia (🔴 vencido / 🟠 urgente / 🟡 programar / 🟢 atención) y orden de severidad descendente. Si no hay tractores, manda mensaje "todo en orden" para confirmar que el cron corrió.
- `cron.js` sección 3 refactorizada: en vez de `_addItem(chofer, ...)` por cada tractor, recolecta en lista `tractoresConUrgencia`. Después del loop "por chofer", bloque dedicado encola UN solo mensaje a Emmanuel en `COLA_WHATSAPP` con `items_agrupados` poblado.
- Idempotencia diaria: nuevas funciones `yaSeEnvioServiceDiario` y `registrarServiceDiario` en `historico.js`. Si por la tarde un tractor cruza un nuevo umbral, NO se manda hasta el día siguiente (decisión aceptada: "unos km de más no son tan grave").
- Saludo usa el `APODO` de Emmanuel via `aviso.resolverNombreSaludo` (mismo patrón que choferes). Su apodo es "EMMA".

#### 6.11.8 Script verificar_destinatario_service.js (commit `206da8b`)
Herramienta de validación para corroborar que el destinatario del aviso de service esté correctamente cargado:
- Lee `SERVICE_DESTINATARIO_DNI` del `.env`.
- Verifica que el documento `EMPLEADOS/{DNI}` exista, tenga TELEFONO válido y APODO o NOMBRE.
- Imprime preview de los tractores con urgencia que recibiría HOY.
- Sin envío real, solo lectura. Útil al configurar el bot en una PC nueva.

Validado el 1-mayo: Emmanuel existe, teléfono `5492914072695`, apodo "EMMA", rol ADMIN. 4 tractores con urgencia detectados (1 VENCIDO, 1 URGENTE, 2 ATENCIÓN).

#### 6.11.9 Logger formato local DD-MM-AAAA HH:MM:SS (commit `b0d0532`)
Antes los timestamps del logger eran ISO con sufijo Z (UTC). Ej: `2026-05-01T19:23:05.512Z`. El admin tenía que restar 3 horas en la cabeza para entender cuándo pasó cada cosa.

Ahora el logger usa formato AR familiar `[DD-MM-AAAA HH:MM:SS]` con componentes locales del proceso (que ya está en TZ ART por `process.env.TZ`). Ej: `[01-05-2026 16:23:05]`.

#### 6.11.10 Setup operativo Windows (no commiteable, hecho en la PC casa)
Estos pasos son del lado del operador, no del repo:
- NSSM 2.24 instalado en `C:\nssm\`. Servicio `CoopertransMovilBot` creado en modo `SERVICE_DEMAND_START` corriendo como `LocalSystem`.
- `whatsapp-bot/.env` cargado con `BOT_PC_ID=casa`, `SERVICE_DESTINATARIO_DNI=29820141`, `AUTO_AVISOS_ENABLED=true`.
- `icacls` aplicados sobre `C:\Users\santi\logistica_app_profesional\` y `C:\Users\santi\.cache\puppeteer\` para que `LocalSystem` pueda leer.
- `PUPPETEER_CACHE_DIR=C:\Users\santi\.cache\puppeteer` configurado en NSSM via `AppEnvironmentExtra`.
- Sesión de WhatsApp escaneada bajo contexto LocalSystem (importante para que NSSM la pueda leer en restarts).
- Backup de `.wwebjs_auth/` guardado en `C:\Users\santi\Backups\bot_wwebjs_auth_*`.

#### 6.11.11 Calvario operativo del 1-mayo PM (lección aprendida)
La sesión wwebjs se "quemó" porque mezclamos: bot manual del user `santi` + servicio NSSM como `LocalSystem` corriendo en paralelo. Resultado: 4 sesiones autenticadas simultáneas peleándose, WhatsApp Web tira a varias. Después la sesión persistida quedó con propietario mezclado y el `Remove-Item` no podía borrarla (acceso denegado por archivos creados por SYSTEM).

**Solución que funcionó**: reiniciar la PC entera + borrar `.wwebjs_auth` desde PowerShell-Admin + arrancar el servicio + escanear QR fresco bajo contexto LocalSystem.

**Reglas para la próxima vez** (anotadas también en sec. 12):
- NUNCA correr `node src/index.js` a mano si el servicio NSSM está activo. Una sesión a la vez.
- El servicio crea/escribe archivos como `LocalSystem`. Para borrar `.wwebjs_auth` siempre desde PowerShell-Admin.
- Si la sesión se rompe (loops infinitos de "Esperando WhatsApp listo... 1/3"), el remedio es: stop service → borrar `.wwebjs_auth` → start service → escanear QR fresco. NO mezclar approaches.
- Backup de `.wwebjs_auth/` a otra ubicación tras escanear QR limpio. Restauración: stop → borrar → copiar backup → start.

#### 6.11.12 Validaciones de cierre
- `flutter analyze` (toda la app): **0 issues**.
- `flutter test`: **25/25 tests pasan**.
- `node --check` en bot: limpio en `index.js`, `health.js`, `cron.js`, `aviso_builder.js`, `aviso_service_builder.js`, `humano.js`, `feriados_ar.js`, `historico.js`, `logger.js`.
- Tests del helper de feriados: 7 casos cubiertos (2026 + 2027 + no-feriado + fuera de rango), todos OK.
- Tests del helper `aDdMmYyyyLocal`: 6 formatos (string ISO, ISO con T y Z, Date local, Date UTC midnight, Timestamp con `toDate`, Timestamp con `seconds`), todos devuelven 30/05/2026 correcto.
- Tests del builder `buildResumenDiario`: caso 0 tractores (msj OK) y caso N tractores (msj ordenado por severidad).
- Bot operativo como servicio NSSM, sesión vinculada, cron HABILITADO. Lunes hábil próximo (4-mayo) recibirá Emmanuel el primer mensaje consolidado con 4 tractores.

#### 6.11.13 Commits del día (todos pusheados)
| Commit | Resumen |
|---|---|
| `a1da6bc` | feat(bot): items_agrupados visibles + detalle completo + deep-link desde dashboard |
| `8c45374` | feat(bot): NSSM modo manual + check anti-doble-bot para flujo multi-PC |
| `0c0403d` | fix(bot): start_bot/stop_bot con auto-elevacion UAC via Test-IsAdmin |
| `8a29a1a` | fix(tz) + chore(logs+nssm): blindar fechas + auto-config NSSM + silenciar logs |
| `7fed8da` | feat(bot): feriados nacionales + service preventivo consolidado a Emmanuel |
| `206da8b` | chore(bot): script verificar_destinatario_service para chequear setup de Emmanuel |
| `b0d0532` | fix(bot): logger usa formato local DD-MM-AAAA HH:MM:SS |

### 6.12 Sesión 2-mayo 2026 — Migración Functions a sa-east1 + Volvo Alerts Fase 1a

#### 6.12.1 Migración de Cloud Functions us-central1 → southamerica-east1 (commit `c56cbf7`)

Las 5 Functions del proyecto vivían en `us-central1` mientras que Firestore estaba en `southamerica-east1` desde el inicio del proyecto. Cada read/write desde una function pagaba ~150ms de latencia inter-region. Aprovechando que la app está en etapa de testeo (nadie la tiene instalada todavía), se hizo la migración completa sin cuidar backward-compat:

- `setGlobalOptions({ region: "southamerica-east1" })` en `functions/src/index.ts`.
- 4 URLs hardcoded actualizadas en cliente Flutter (todas usan Dio HTTPS directo, no `cloud_functions` plugin):
  - `lib/features/auth/services/auth_service.dart` (loginConDni).
  - `lib/core/services/audit_log_service.dart` (auditLogWrite).
  - `lib/features/employees/services/empleado_actions.dart` (actualizarRolEmpleado).
  - `lib/features/vehicles/services/volvo_api_service.dart` (volvoProxy).
- Deploy con `N` a la pregunta de Firebase sobre borrar las viejas — para validar smoke test antes de borrar.
- IAM `allUsers Cloud Run Invoker` reaplicado a las 4 callables públicas en sa-east1 (Gen2 lo pierde en cada deploy).
- Smoke test OK: login + acción auditable + sync Volvo + cambiar rol.
- 5 functions viejas borradas con `gcloud functions delete --region=us-central1 --quiet`.

**Gotcha encontrado**: en el primer deploy multi-function en una región nueva, una function (`loginConDni`) falló con `NAME_UNKNOWN: Repository "gcf-artifacts" not found` (race en la creación del repo Artifact Registry). Reintento simple con `--only functions:loginConDni` resolvió. Documentado en RUNBOOK §"Migrar Cloud Functions de region".

#### 6.12.2 Volvo Vehicle Alerts — Fase 1a backend (commit `42dacea`)

Implementada la primera fase del roadmap de integración con Volvo Vehicle Alerts API:

- **`volvoAlertasPoller`** — scheduled function `every 5 minutes` en sa-east1 que pollea `/alert/vehiclealerts` con paginación (`moreDataAvailableLink`), cursor en `META/volvo_alertas_cursor` con `requestServerDateTime`, cold start desde "ahora −1h".
- **Modelo `VOLVO_ALERTAS/{vin}_{createdMs}_{tipo}`** — docId composite e idempotente. Naming castellano (`tipo`/`severidad`/`creado_en`/`patente`/`detalle_<subtipo>`/`atendida`/etc.). Cross-ref VIN→patente con `customerVehicleName` y fallback a tabla `VEHICULOS`.
- **Estrategia anti-pisoneo**: `getAll` batch antes de escribir → solo crea los nuevos, NO pisa campos de gestión (`atendida`, `atendida_por`, `atendida_en`) seteados por el admin desde el tablero.
- **Reglas Firestore**: `VOLVO_ALERTAS` read+update=admin/supervisor, create+delete=`if false` (solo Admin SDK). `META/{doc=**}` read+write=`if false`.
- Build + lint + 46/46 tests OK. Deploy a sa-east1 OK. Cloud Scheduler job `firebase-schedule-volvoAlertasPoller-southamerica-east1` activo con `every 5 minutes`.

**Pendiente (Fase 1b)**: tablero "Alertas" en sidebar admin Flutter consumiendo `VOLVO_ALERTAS` + filtros + marcar como atendida via `auditLogWrite`. Pre-requisito antes de codear: volcar `firestore.indexes.json` cuando aparezca el primer error de query compuesta en consola.

**Bloqueado por decisiones de Santiago para Fases 2-5** (no Fase 1b): PTO operativo S/N, enforce identificación chofer S/N, Scores API spec.

#### 6.12.3 Commits del día
| Commit | Resumen |
|---|---|
| `c56cbf7` | feat(infra): migrar Cloud Functions a southamerica-east1 |
| `42dacea` | feat(volvo-alerts): poller scheduled + reglas Firestore (Fase 1a) |

### 6.13 Sesión 2-mayo 2026 (PM/noche) — Volvo Alerts Fase 1b/2 + bot hardening + rebrand + reportes

Continuación maratónica de la sesión del 2-mayo. Cierre de Volvo Alerts hasta Fase 2, auditoría profunda del bot WhatsApp, rebrand completo y rediseño de los 3 reportes Excel.

#### 6.13.1 Volvo Vehicle Alerts — Fase 1b cliente (commits `2cd362a`, `ad5a1d7`, `7f6779f`)

Tablero "Alertas" en sidebar admin Flutter consumiendo `VOLVO_ALERTAS`:
- `lib/features/admin_dashboard/screens/admin_volvo_alertas_screen.dart` con stream + toggle "solo pendientes" + filter por patente/tipo + "Marcar atendida".
- `Capability.verAlertasVolvo` (admin + supervisor) en `capabilities.dart`.
- `AppCollections.volvoAlertas` en `app_constants.dart`.
- `AuditAccion.marcarAlertaVolvoAtendida` en `audit_log_service.dart`.
- Whitelist server: `MARCAR_ALERTA_VOLVO_ATENDIDA` + entidad `VOLVO_ALERTAS` agregadas a `auditLogWrite`.
- Backend: `volvoAlertasPoller` ahora setea `atendida: false` en docs nuevos.
- `AdminShell._ShellSection` "Alertas" con badge `where('atendida', isEqualTo: false)`.
- Ruta `AppRoutes.adminVolvoAlertas` registrada en `app_router.dart`.
- Tile "ALERTAS" en `admin_panel_screen.dart` accesos rápidos (entre SERVICE y PERSONAL).
- Fix overflow del rail con 10 secciones: wrap del NavigationRail en `SingleChildScrollView` + `IntrinsicHeight`.

#### 6.13.2 Volvo Vehicle Alerts — Fase 2 (commit `26f1dfa`)

Notificación al chofer (HIGH realtime) + resumen diario al admin:
- `onAlertaVolvoCreated` Cloud Function trigger en `functions/src/index.ts` — `onDocumentCreated('VOLVO_ALERTAS/{alertId}')` que filtra HIGH, busca chofer por `EMPLEADOS where VEHICULO == patente`, y encola en `COLA_WHATSAPP`. El bot procesa la cola respetando horarios laborales (no dispara fuera de horario).
- Resumen diario en el cron del bot Node.js (`whatsapp-bot/src/cron.js`): replica del patrón existente `SERVICE_DESTINATARIO_DNI` → `ALERTAS_RESUMEN_DESTINATARIO_DNI` (Santiago, DNI 35244439). Nuevo builder `aviso_alertas_volvo_builder.js` con `buildResumenDiario` que agrupa eventos HIGH 24h por chofer + patente + tipo. Idempotencia diaria con `historico.yaSeEnvioAlertasResumen`. Si no hubo HIGH en 24h, no se manda nada (silencio = nada que reportar).
- Mapa de tipos a etiquetas legibles (`DISTANCE_ALERT` → "Cerca del vehículo de adelante", etc.) duplicado entre cliente Flutter y server (Cloud Function + bot).

#### 6.13.3 Settings.json del proyecto: reducir permission prompts (commit `9f896f6`)

Crear `.claude/settings.json` (commited) con:
- `defaultMode: "acceptEdits"` → Edit/Write no piden confirmación.
- Allowlist amplio para Bash de uso rutinario (git no destructivo, npm/flutter, gcloud read-only, firebase logs/use).
- `ask:` para destructivo en prod (`git push`, `firebase deploy`, `gcloud delete`, `rm -rf`).
- `.gitignore` ajustado: `.claude/*` + `!.claude/settings.json` para que se sincronice entre las 2 PCs vía git.

#### 6.13.4 Bot WhatsApp — auditoría profunda + 12 fixes (commit `afe2732`)

Resuelve el síntoma reportado por Santiago: "se cuelga al iniciar, hay que reejecutar mucho". Fixes en 8 archivos del bot:

**Críticos (causa raíz del cuelgue)**:
- `whatsapp.js`: `client.initialize()` ahora con try/catch + reintentos (antes si fallaba el initialize antes de `authenticated`, el watchdog nunca arrancaba → cuelgue silencioso). Confirmado en logs: el watchdog disparó el 02/05 a las 13:30, reinicializó y se recuperó solo (antes esto era el bug que requería reejecutar manual).
- `whatsapp.js`: si la reinicialización dentro del watchdog también falla, re-arrancar el watchdog.
- `index.js`: `_verificarNoHayOtraInstancia()` ahora con transacción atómica sobre `BOT_HEALTH/main` (antes había race window de ~100ms en que dos PCs podían pasar el check ambas → mensajes duplicados → riesgo de baneo).
- `index.js`: si `_despacharFalloEnvio()` falla, cortar `procesarSiguiente()` y esperar al próximo polling (5s mínimo) en vez de loop apretado martillando Firestore.

**Altos**:
- `index.js`: timeout de 10s + guard contra overlap en `pollearCola()` con helper `_withTimeout`.
- `firestore.js`: `marcarProcesandoSiPendiente()` transaccional para evitar race con multi-PC.

**Medios**:
- `health.js`: heartbeat serializado con flag (evita pisones si Firestore tarda).
- `cron.js`: `setTimeout` recursivo en lugar de `setInterval` para que el siguiente ciclo arranque DESPUÉS del anterior, sin brechas.
- `control.js`: TTL cache pausa 10s → 2s + `invalidarCache()`.
- `firestore.js`: campo `historial_errores` con `arrayUnion` para preservar traza de reintentos.
- `message_handler.js`: TTL cache empleados 5min → 1min + `invalidarCacheEmpleados()`.

**Bajo**:
- `historico.js`: `limpiarObsoletos()` implementado (era TODO) — borra hasta 500 docs > 90 días por ciclo del cron.

#### 6.13.5 Rebrand "S.M.A.R.T. Logística" → "Coopertrans Móvil" (commits `941293b`, `8e1063d`)

Renombrado en strings visibles + servicio Windows + docs:
- 3 builders del bot (`aviso_builder.js`, `aviso_alertas_volvo_builder.js`, `aviso_service_builder.js`): firma de mensajes WhatsApp.
- `start_bot.ps1`: banner CLI.
- `instalar_servicio.ps1`: `DisplayName` del servicio NSSM.
- `package.json` + `package-lock.json`: name + description.
- `README.md`: título.
- Servicio Windows: `SmartLogisticaBot` → `CoopertransMovilBot` en los 3 scripts ps1, requiere reinstall manual (nssm remove + instalar_servicio.ps1) — Santiago lo hizo en su PC. Pendiente repetir en la otra PC (oficina).

#### 6.13.6 Reporte de Consumo — fixes profundos (commits varios)

Bug original reportado: "no me está generando el consumo en litros los camiones en el reporte". Cadena de fixes:

- **Endpoint correcto**: `traerDatosFlota()` (operation `flota` → `/vehicle/vehicles` solo metadata) → `traerEstadosFlota()` (operation `estadosFlota` → `/vehiclestatuses` con `accumulatedData.totalFuelConsumption`).
- **Período = 0 ahora válido**: antes el código rechazaba diferencias de 0 km/L y caía al fallback acumulado (que también estaba en 0 por el bug del endpoint). Ahora "vehículo parado en sábado" se reporta como 0 (período) correctamente.
- **Filtro `TIPO == TRACTOR`**: las 67 unidades sin motor (BATEA + TOLVA) inflaban el reporte con 50%+ de filas en cero ruido visual.
- **Métrica km/L → L/100km**: cambio de unidad estándar (las flotas argentinas hablan L/100km, no km/L).
- **UI dialog**: `showDateRangePicker` scrolleable (no `showDatePicker` secuenciales), sin checkboxes de columnas, solo el botón de calendario.
- **Excel**: 3 filas de info eliminadas (cabecera en fila 0), AutoFilter inyectado via parche XML del .xlsx (la lib `excel` 4.0.6 no expone API y `syncfusion_flutter_xlsio` requiere licencia paga), formato AR `1.234.567,89` forzado con format code `[$-2C0A]#,##0.00`, auto-fit calculado manual respetando el largo del título, columnas finalizadas: `PATENTE | MODELO | LITROS | KILOMETROS | PROMEDIO | ULTIMA SINCRONIZACION`, ranking por L/100km descendente con TODA la flota (no top 10), columna `MODELO` (sin marca) en ranking.
- **Bug de ULTIMA SINCRONIZACION vacía**: `triggerTimestamp`/`samplingTime` (campos del endpoint legacy) → `createdDateTime`/`receivedDateTime` (campos del endpoint nuevo).

#### 6.13.7 Reporte de Flota — rediseño completo (commit `85e0d55`)

Reescrito desde cero con enfoque correcto: estado general de flota, vencimientos, services. NO combustible (eso es del reporte de Consumo).

Columnas finales (14):
```
PATENTE | TIPO | MODELO | EMPRESA | CHOFER ASIGNADO | KM ACTUAL |
VENC. RTO | VENC. SEGURO | VENC. EXT. CABINA | VENC. EXT. EXTERIOR |
ULTIMO SERVICE (FECHA) | ULTIMO SERVICE (KM) | PROX. SERVICE EN (KM) |
ESTADO SERVICE
```

Coloreo automático según urgencia:
- Vencimientos: rojo si vencido, naranja ≤7d, amarillo ≤30d.
- ESTADO SERVICE: rojo VENCIDO, naranja URGENTE, amarillo PROGRAMAR, verde claro ATENCION.

Incluye toda la flota (tractores + enganches), tractores arriba. CHOFER ASIGNADO se obtiene cruzando con `EMPLEADOS where ROL=CHOFER` para ignorar el campo VEHICULO con basura legacy en supervisores/admins. PROX SERVICE prefiere `serviceDistance` del API Volvo, fallback al cálculo manual `ULTIMO_SERVICE_KM + 50000 - KM_ACTUAL`. Class renombrada `ReportGenerator` → `ReportFlotaService`.

#### 6.13.8 Reporte de Checklist — refactor (commit `85e0d55`)

- `DOMINIO` → `PATENTE` (consistente con resto del proyecto).
- Sin checkboxes (las 7 columnas son siempre necesarias).
- Estado coloreado: rojo MAL, naranja REG.
- AutoFilter + autofit + branding Coopertrans Móvil.

#### 6.13.9 `excel_utils.dart` — helpers compartidos (commit `85e0d55`)

`lib/features/reports/services/excel_utils.dart` extraído para no duplicar entre los 3 reportes:
- `aplicarAutoFilterAlXlsx`: parche XML del .xlsx que inyecta `<autoFilter>` en cada hoja después de `</sheetData>`. Workaround a que la lib `excel` 4.0.6 no expone esa API.
- `autoFitColumnas`: cálculo manual del ancho como `max(largo_título, max_largo_celda) + 2 chars padding`. Necesario porque `setColumnAutoFit` de la lib solo flagea sin calcular.
- `formatoAR` / `formatoARSinDecimales`: format codes `[$-2C0A]#,##0.xx` que fuerzan locale es-AR independiente de la PC del lector.

#### 6.13.10 Investigación de librerías Excel (no commit, decisión documentada)

Auditamos alternativas a `excel: ^4.0.6` para soporte de AutoFilter nativo. Conclusión:
- `syncfusion_flutter_xlsio`: única alternativa Dart pure con AutoFilter nativo + charts + conditional formatting. Pero **requiere Community License** que Vecchi no califica (>10 empleados típicos en transporte de larga distancia) → costo ~$995 USD/dev/año.
- `excel_community` (fork): tampoco soporta AutoFilter.
- Generar OOXML a mano: scope brutal, no vale la pena.

Decisión: quedarse con `excel: ^4.0.6` + parche XML para AutoFilter. Si en el futuro Vecchi crece y queremos charts nativos, reevaluar Syncfusion.

#### 6.13.11 Reporte de bug operacional: TELEMETRIA_HISTORICO solo tiene 4 días

Confusión de Santiago al ver "958 km en un mes" en el reporte: el cron `telemetriaSnapshotScheduled` solo guarda snapshots desde el 29/4 (4 días al cierre de la sesión). Para rangos mayores el reporte se limita a los días disponibles. Pendiente: agregar warning en el dialog cuando el rango pedido excede el histórico disponible (mejora futura).

#### 6.13.12 Commits del día (segunda tanda)
| Commit | Resumen |
|---|---|
| `2cd362a` | feat(volvo-alerts): tablero Alertas en sidebar admin (Fase 1b) |
| `ad5a1d7` | fix(admin-shell): rail scrolleable cuando no entran todas las secciones |
| `7f6779f` | feat(admin-panel): tile 'Alertas' en accesos rápidos + ruta /admin_volvo_alertas |
| `26f1dfa` | feat(volvo-alerts): Fase 2 — notificación al chofer (HIGH) + resumen diario al admin |
| `9f896f6` | chore(claude-code): allowlist + acceptEdits para reducir prompts |
| `afe2732` | fix(bot): hardening de robustez — auditoría completa (críticos + altos + medios + 1 bajo) |
| `941293b` | chore(bot): rebrand 'S.M.A.R.T. Logística' → 'Coopertrans Móvil' |
| `8e1063d` | chore(bot): rebrand servicio Windows 'SmartLogisticaBot' → 'CoopertransMovilBot' |
| `dc41ffa` | feat(reportes/consumo): AutoFilter automático al abrir el .xlsx (workaround OOXML) |
| `7ba7ec6` | ux(reportes/consumo): quitar columnas que no aportan al análisis de combustible |
| `71af2c0` | fix(reportes/consumo): leer createdDateTime/receivedDateTime del endpoint correcto |
| `a4d8282` | ux(reportes/consumo): unidades explícitas en cabeceras + menos decimales |
| `dbae4d4` | ux(reportes/consumo): dialog simplificado — solo calendario, sin checkboxes ni presets |
| `80083d1` | ux(reportes/consumo): formato argentino 1.234.567,89 en celdas numéricas |
| `bb735eb` | ux(reportes/consumo): auto-fit de columnas al contenido |
| `812c3a5` | ux(reportes/consumo): auto-fit calculado manual respetando largo del título |
| `aca2593` | ux(reportes/consumo): renombrar columnas a LITROS / KILOMETROS / PROMEDIO en ese orden |
| `504274e` | ux(reportes/consumo/ranking): columna 'MARCA / MODELO' → 'MODELO' (sin marca) |
| `85e0d55` | feat(reportes): rediseño completo de Flota + Checklist + util compartido |

### 6.14 Sesión 2-mayo 2026 (madrugada) — Roadmap Volvo Alerts COMPLETO + 3 capas de upgrades + DR + filtros de roles

Sesión maratónica de cierre del roadmap Volvo Alerts (Fases 3, 4 y 5) + features estructurales + upgrade integral del stack + disaster recovery automatizado. Cuando arrancó el día solo estaban Fases 1-2 vivas; al final, las 8 sub-fases en producción + UI completa.

#### 6.14.1 Sistema histórico chofer↔vehículo (commit `9a74621`)

Nueva colección `ASIGNACIONES_VEHICULO` con timeline inmutable de quién manejó qué patente cuándo. Resuelve casos de uso reales:
- Multas tardías (llega multa de hace 6 meses → se sabe quién manejaba ese día).
- Atribución de eventos Volvo del pasado (no atribuir a "chofer actual").
- Disputas (sin log, palabra contra palabra).
- Base para módulo de planeamiento de viajes futuro.

Implementación:
- Modelo `AsignacionVehiculo` (`lib/features/asignaciones/models/`).
- Servicio centralizado `AsignacionVehiculoService` con `cambiarAsignacion()` transactional + `obtenerChoferEnFecha(vehiculoId, fecha)` + streams para UI.
- Reglas Firestore: read admin/supervisor, create/update validados, delete prohibido (append-only).
- 9 unit tests del modelo (parsing + esActiva + diasDuracion).
- Reemplazos: `EmpleadoActions.unidad()` (ficha personal) y `RevisionService.finalizarRevision()` (aprobación de cambio de unidad) ahora pasan por el servicio.
- Pantalla "Historial de asignaciones" en la ficha del vehículo.
- **`volvoAlertasPoller` actualizado**: cuando crea un doc en `VOLVO_ALERTAS`, hace lookup contra el log y snapshotea `chofer_dni` + `chofer_nombre` en el evento. Eso da atribución inmutable al chofer del momento, sin necesidad de tarjeta del tachógrafo.
- Migración inicial one-shot `scripts/migrar_asignaciones_iniciales.js` → 54 docs sembrados desde `EMPLEADOS.VEHICULO`.
- Bonus: arreglado un mini-bug pre-existente donde dos choferes podían apuntar a la misma patente.

#### 6.14.2 "Solo CHOFER cuenta como conductor" (commit `a52948d`)

Regla operativa nueva: admins/supervisores/planta NO manejan, NO deben aparecer en cálculos de manejo, reportes de flota, rankings, ni notificaciones automáticas. Defensa en 3 capas:

1. **PREVENTIVO** — `AsignacionVehiculoService` rechaza con `StateError` si el empleado destino no es `ROL == CHOFER`. Lee `EMPLEADOS` antes de la transaction. Desvincular siempre se permite (para limpiar datos sucios anteriores).
2. **DEFENSIVO Flutter** (filtros in-memory por `AppRoles.tieneVehiculo`):
   - `admin_panel_screen.dart`: KPIs "choferes activos" y "vencimientos próximos" ignoran no-choferes (antes contaba 57, ahora 54).
   - `admin_vencimientos_choferes_screen.dart` y `admin_vencimientos_calendario_screen.dart`: filtran no-choferes.
3. **DEFENSIVO Bot Node** (filtros en `whatsapp-bot/src/`):
   - `cron.js`: el cron de vencimientos ya no carga admins en `empleadosByDni` ni los mapea como dueños de patentes. Resultado: cero WhatsApps a no-choferes.
   - `message_handler.js`: cache de `_resolverChofer` (matching teléfono → empleado) ahora solo guarda choferes. Si un admin escribe al bot, no se "asocia" como respuesta de chofer.

Auditoría completa de queries a `EMPLEADOS` con agente paralelo. Los hits restantes son legítimos (ficha individual, perfil propio, gestión administrativa que SÍ debe ver TODOS).

Script de limpieza `scripts/limpiar_admins_del_log.js`: para cada empleado con `ROL != CHOFER` y `VEHICULO != '-'`, borra sus docs de `ASIGNACIONES_VEHICULO`, setea `EMPLEADOS.VEHICULO = '-'` y libera `VEHICULOS.ESTADO`. Ya corrido en producción — limpió la asignación de SANTIAGO→AI162YT que la migración inicial había sembrado por error.

#### 6.14.3 Cleanup post-migración (commit `d42eb6f`)

Cierre de tareas pendientes desde la migración del proyecto a `coopertrans-movil`:
- `scripts/backup_firestore.ps1`: actualizado a `--project=coopertrans-movil` + `gs://coopertrans-movil-backups`. Sumadas 4 colecciones nuevas al export (ASIGNACIONES_VEHICULO, VOLVO_ALERTAS, META, CHECKLISTS) → 16 colecciones totales.
- `RUNBOOK.md`: 8 menciones a `logisticaapp-e539a` reemplazadas.
- `ESTADO_PROYECTO.md` y `scripts/migrar_roles.js`: idem.
- Sweep final: cero referencias a `logisticaapp-e539a` / `logisticaapp-backups` en *.md, *.ps1, *.dart, *.ts, *.js, *.json del repo.

#### 6.14.4 Capa 1 — `firebase-functions 7` + `@typescript-eslint 8` (commit `9ad0c66`)

Silencia los 2 warnings que aparecían en cada `firebase deploy`:
1. "package.json indicates an outdated version of firebase-functions"
2. "WARNING: TypeScript 5.9.3 not officially supported by @typescript-eslint"

Bumps:
- `firebase-functions` ^6.0.1 → ^7.2.5 (mayor)
- `@typescript-eslint/parser` ^7.0.0 → ^8.59.1
- `@typescript-eslint/eslint-plugin` ^7.0.0 → ^8.59.1

**Cero líneas de código modificadas** — la API pública de v7 es retrocompat con v6 en todo lo que usamos (`defineSecret`, `onSchedule`, `onDocumentCreated`, `onCall`, `HttpsError`, `logger`, `setGlobalOptions`).

#### 6.14.5 Backup automático Firestore — Cloud Scheduler diario + lifecycle (commit `3897239`)

Mejora estructural del bus factor:
- **Cloud Scheduler** `firestore-backup-diario` ya estaba activo (descubierto durante la sesión) — corre todos los días a las 03:00 ART, llama al endpoint REST de Firestore export hacia `gs://coopertrans-movil-backups`. Independiente de qué PC esté prendida.
- **Lifecycle policy nueva** del bucket: borra exports >30 días automáticamente. `matchesPrefix` con años (2026-, 2027-, ...) excluye el snapshot `pre-migration-2026-05-01_2259/` (salvaguarda histórica).
- Archivo versionado en repo: `scripts/lifecycle_backups.json`.
- Documentación en `RUNBOOK.md` sección "Backup Firestore → Retención automática".
- Costo: ~3 centavos USD/mes.

#### 6.14.6 Capa 2 — Flutter ecosystem completo (commits `c46dacd` + `649a7e5` + `59e4704`)

Upgrade ordenado en 3 etapas validadas con analyzer + tests entre cada una.

**Etapa 🟢 patches** (cero código tocado): `cupertino_icons` 1.0.8→1.0.9, `image_picker` 1.1.2→1.2.2, `google_mlkit_text_recognition` 0.13.1→0.15.1.

**Etapa 🟡 Firebase ecosystem** (cero código tocado, API retrocompat): `firebase_core` 3→4, `cloud_firestore` 5→6, `firebase_auth` 5→6, `firebase_storage` 12→13, `firebase_crashlytics` 4→5.

**Etapa 🔴 UI plugins** (con breaking changes que requirieron fixes):
- `file_picker` 8→11: `FilePicker.platform.pickFiles(...)` → `FilePicker.pickFiles(...)`. 5 sitios fixeados.
- `share_plus` 7→12 (NO 13 por conflicto win32): `Share.shareXFiles(...)` → `SharePlus.instance.share(ShareParams(...))`. 3 sitios.
- `flutter_local_notifications` 17→21: TODA la API pasó a named params (initialize, show, zonedSchedule). Removido `uiLocalNotificationDateInterpretation`. 1 archivo (`notification_service.dart`).
- `flutter_secure_storage` 9→10: el flag `encryptedSharedPreferences` está deprecado (Jetpack Security en sunset). Constructor sin parámetros — el plugin migra automático.
- `timezone` 0.9→0.11.

Bonus side effects positivos: el package `js` (discontinued upstream) ya no aparece como dep, `flutter_secure_storage_macos` sale del lock.

**Hotfix 1** (commit `649a7e5`): `firebase_storage 13.1.0+` rompe el build Windows con `error C2039: "UseEmulator"`. PR flutterfire #18030 introdujo una llamada a un método del firebase-cpp-sdk que SOLO existe en main, no en releases publicadas. Versiones rotas: 13.1.0, 13.2.0, 13.3.0. Pin EXACT a `13.0.4` (sin caret) — última versión Windows-safe, compatible con `firebase_core 4.5.0`. Trade-off: perdemos `useStorageEmulator()` en Windows (que tampoco funciona en 13.1+, es no-op real). Memoria nueva `feedback_firebase_storage_windows_pin.md` para no caer de nuevo.

**Hotfix 2** (commit `59e4704`): `flutter_local_notifications 21` ahora EXIGE `WindowsInitializationSettings` cuando target incluye Windows desktop. Sin él, `initialize()` tira `Invalid argument(s): Windows settings must be set when targeting Windows platform` y la app crashea silenciosamente en release mode (subsystem windowed se traga la excepción). Configurado: appName "Coopertrans Móvil", appUserModelId "Coopertrans.Movil.Logistica", guid estable.

#### 6.14.7 Capa 3 — Bot WhatsApp deps (commits `52534c5` + `f79c8a5`)

Resultó mucho más liviana de lo previsto: las deps realmente delicadas (`whatsapp-web.js 1.34.7` + `puppeteer 24.38.0`) ya estaban al día. Solo bumps de SDK estables:
- `dotenv` ^16.4.5 → ^17.4.2
- `firebase-admin` ^12.6.0 → ^13.8.0

Cero código tocado, 54/54 tests pass.

Después: silenciado el splash de dotenv 17 con `{ quiet: true }` en los 4 lugares donde se carga (`whatsapp-bot/src/index.js` + 3 scripts one-shot) — eliminado el ruido `◇ injected env (15) from .env...` de los logs operativos.

#### 6.14.8 Volvo Scores API: probe + Fase 3 (Eco-Driving + Descargas) (commits `8c0a0f7`, `364755d`, `06a32f4`, `71a71f0`)

**Probe** (`scripts/probar_volvo_scores_api.js`): one-shot que confirmó HTTP 200 sobre `/score/scores` — Vecchi tiene activado el pack Scores en su contrato Volvo Connect. Datos reales del 1° de mayo (feriado, 28 vehículos operaron):
```
total                : 77.17    decente
anticipation         : 61.71    ⚠️ DÉBIL — choferes no leen el tráfico
braking              : 95.96    fuerte (artefacto operativo)
coasting             : 50       mediocre
engineAndGearUtil.   : 89.7
idling               : 32.57    🔴 MAL — plata tirada
overspeed            : 71.82
cruiseControl        : 94.55    fuerte
```
Operación acumulada flota: 124 mil km, 32.9 L/100km, 88.7 ton CO2, **utilización 23.34%** (valida el case del módulo de planeamiento de viajes futuro — mucha capacidad ociosa).

**Fase 3a — Backend** `volvoScoresPoller`: Cloud Function programada `0 4 * * *` ART. Llama a `/score/scores?starttime=ayer&stoptime=ayer&contentFilter=FLEET,VEHICLES`. Persiste en `VOLVO_SCORES_DIARIOS` con docId composite `{patente}_{YYYY-MM-DD}` y `_FLEET_{YYYY-MM-DD}`. Idempotente, reusa secrets `VOLVO_USERNAME/PASSWORD`. Constante `AppCollections.volvoScoresDiarios`. Reglas Firestore: read admin/supervisor, write false.

**Fase 3b — UI Eco-Driving**: feature `lib/features/eco_driving/`:
- Modelo `VolvoScoreDiario` con helpers de unidades (km, L/100km, horas).
- Servicio con 3 streams + `RankingVehiculo.desdeDocs()` que agrupa por patente y promedia.
- Pantalla `AdminEcoDrivingScreen`: resumen flota + ranking por vehículo + filtro temporal popup.
- Bottom sheet `score_drilldown_sheet.dart`: evolución diaria + sub-scores promediados + cruce con asignaciones históricas para mostrar quién manejó cada día.
- Sidebar admin: sección "Eco-Driving" 🌿 con `Capability.verAlertasVolvo`.

**Fase 3c — UI Descargas (PTO)** (`AdminDescargasPtoScreen`): lista de eventos `tipo == 'PTO'` con filtros (rango temporal + chip por patente in-memory). Cada card: patente + chofer (snapshot del log) + detalle del PTO + coords clickeables que abren Google Maps externo. Sidebar: sección "Descargas" 🚛.

**Hotfix índices Firestore**: las queries combinan `where + orderBy` y necesitaban índices compuestos. `firestore.indexes.json` nuevo con 3 índices: `(es_fleet, fecha_ts)` + `(patente, fecha_ts)` para Scores + `(tipo, creado_en)` para PTO. Deploys con `firebase deploy --only firestore:indexes`.

#### 6.14.9 Fase 4 — Mantenimiento predictivo (commits `8fa14ad` + `89eb5aa`)

Trigger nuevo `onAlertaVolvoMantenimientoCreated`. Separado del de Fase 2 (responsabilidades distintas). Filtra por tipos:
- `FUEL`, `CATALYST`
- `GENERIC` con sub-tipo `TELL_TALE`, `ADBLUELEVEL_LOW`, `WITHOUT_ADBLUE`

Encola WhatsApp en `COLA_WHATSAPP` al jefe de mantenimiento (DNI 35244439, hardcoded). Mensaje rico: patente + alerta legible + severidad con emoji semafórico + hora ART + chofer al volante (snapshot del log) + link a Maps con coords. Respeta horario hábil del bot — alerta del sábado 23:00 llega lunes 8 AM, antes de que el camión salga.

Sin dedupe por (tipo, patente) en v1: con ~7 eventos de mantenimiento en 13 días reales, el volumen es muy bajo. Si aparece spam, agregar dedupe.

**Test E2E validado** con `scripts/probar_alerta_mantenimiento.js`: crea doc dummy en `VOLVO_ALERTAS`, espera 8s al trigger, verifica que se encoló en `COLA_WHATSAPP`. Confirmado: trigger dispara correctamente, mensaje se forma bien.

#### 6.14.10 Fase 5 — Mapa de eventos georreferenciados (commit `71207c9`)

Pantalla `AdminMapaVolvoScreen` con OpenStreetMap (vía `flutter_map: ^8.3.0` + `latlong2: ^0.9.1` — pin a 0.9 porque flutter_map 8 lo requiere). Tiles públicos de OSM, sin API key, atribución incluida (TOS).

Diseño:
- Centro inicial Bahía Blanca, zoom 8.
- Pins coloreados por severidad: rojo HIGH, amarillo MEDIUM, verde LOW, gris atendidas.
- Filtros chips horizontales: tipo + patente (combinados in-memory).
- Sin GPS válido → evento se descarta del mapa (cuenta en header como "X sin GPS").
- Tap en pin → bottom sheet `EventoVolvoDetalleSheet` con detalle + botón "Marcar atendida" (mismo flow que el tablero, audit log con `origen: 'mapa'`).

Sidebar admin: sección "Mapa" 🗺️ con misma capability.

#### 6.14.11 Operaciones de producción ejecutadas

- Rotación VOLVO_PASSWORD (versión 1 destruida en Secret Manager, 3 funciones tomaron versión 2 automático).
- 5 deploys de Cloud Functions sin warnings.
- Bucket `gs://coopertrans-movil-backups` + Cloud Scheduler diario 03:00 ART + lifecycle 30d.
- 4 índices compuestos Firestore creados y `READY`.
- Bot WhatsApp reiniciado 3 veces sin perder sesión QR.
- App Flutter buildeada en Windows release + smoke test exitoso (login + reportes Excel + carga archivos + nuevas pantallas Eco-Driving / Descargas / Mapa).
- Migración inicial `ASIGNACIONES_VEHICULO`: 54 docs sembrados.
- Limpieza admins del log: borrada la asignación SANTIAGO→AI162YT (1 doc).
- Test E2E del trigger de mantenimiento: doc dummy creado, encolado verificado, dummy borrado.

#### 6.14.12 Commits del día (tercera tanda)
| Commit | Resumen |
|---|---|
| `9a74621` | feat(asignaciones): log temporal chofer↔vehículo + integración con Volvo Alerts |
| `a52948d` | feat(roles): solo CHOFER cuenta como conductor — preventivo + defensivo |
| `d42eb6f` | chore(post-migration): completar rebrand coopertrans-movil en docs y scripts |
| `9ad0c66` | chore(functions): upgrade firebase-functions 6→7 + @typescript-eslint 7→8 |
| `3897239` | chore(backups): lifecycle policy del bucket — retención 30 días automática |
| `c46dacd` | chore(deps): Capa 2 — Flutter ecosystem upgrade |
| `649a7e5` | fix(deps): pin firebase_storage a 13.0.4 (workaround bug Windows) |
| `59e4704` | fix(notifications): WindowsInitializationSettings requerido por flutter_local_notifications 21 |
| `52534c5` | chore(bot): upgrade dotenv 16→17 + firebase-admin 12→13 |
| `f79c8a5` | chore(bot): silenciar splash de dotenv 17 con quiet:true |
| `8c0a0f7` | chore(scripts): probe one-shot Volvo Scores API |
| `364755d` | feat(eco-driving): Fase 3 — Scores API + Eco-Driving + Descargas PTO |
| `06a32f4` | fix(firestore): índices compuestos para queries de Eco-Driving |
| `71a71f0` | fix(firestore): índice (tipo, creado_en) para pantalla Descargas PTO |
| `8fa14ad` | feat(volvo): Fase 4 — onAlertaVolvoMantenimientoCreated |
| `89eb5aa` | chore(scripts): probe end-to-end del trigger mantenimiento |
| `71207c9` | feat(volvo): Fase 5 — Mapa de eventos georreferenciados (OpenStreetMap) |
| `a66d78f` | docs(estado-proyecto): sección 6.14 — sesión completa 2-mayo madrugada |
| `b372e40` | chore(decommission): script de auditoría + checklist en RUNBOOK para bajar logisticaapp-e539a |

#### 6.14.13 Estado del roadmap Volvo Alerts al cierre

| Fase | Implementación | Estado |
|---|---|---|
| 1a — Backend poller alertas (cada 5 min) | `volvoAlertasPoller` | ✅ live |
| 1b — Tablero "Alertas" del admin | `AdminVolvoAlertasScreen` | ✅ live |
| 2 — Notif WhatsApp HIGH al chofer | `onAlertaVolvoCreated` | ✅ live |
| 3a — Backend Scores diario | `volvoScoresPoller` | ✅ live |
| 3b — Pantalla Eco-Driving (resumen + ranking + drilldown) | `AdminEcoDrivingScreen` | ✅ live |
| 3c — Pantalla Descargas (PTO) | `AdminDescargasPtoScreen` | ✅ live |
| 4 — Mantenimiento predictivo (WhatsApp al jefe) | `onAlertaVolvoMantenimientoCreated` | ✅ live + E2E test |
| 5 — Mapa de eventos georreferenciados | `AdminMapaVolvoScreen` | ✅ live |

#### 6.14.14 Preparación del decommission del proyecto legacy (commit `b372e40`)

Cierre operativo del día con la PREPARACIÓN para bajar `logisticaapp-e539a` cuando se cumpla la ventana de validación (≥ 30 días desde la migración = ≥ 2026-06-02).

**Script de auditoría** `scripts/auditar_referencias_proyecto_viejo.ps1`:
- Sweep grep recursivo del repo buscando 6 patrones que indicarían código apuntando al proyecto viejo: `logisticaapp-e539a`, `gs://logisticaapp-backups`, `logisticaapp.firebasestorage.app`, `logisticaapp.appspot.com`, `us-central1-logisticaapp`, `southamerica-east1-logisticaapp`.
- Excluye carpetas auto-generadas (`node_modules`, `.git`, `.dart_tool`, `build`, `.claude`, `.firebase`, etc.) operando sobre rutas RELATIVAS al CWD (no full paths) — gotcha resuelto: cuando se corre desde un worktree dentro de `.claude/worktrees/`, una exclusión de `.claude\` aplicada a full path se autoexcluye y descarta TODO el repo.
- Distingue hits "histórico OK" (en `ESTADO_PROYECTO.md`, `RUNBOOK.md` y el propio script — donde son referencias documentadas, no código activo) de hits "código activo" (todo lo demás).
- Exit 0 si solo hay hits históricos → seguro proceder. Exit 1 si hay hits activos → revisar primero.
- **Validado en producción**: 18 matches encontrados (12 en logisticaapp-e539a, 4 en gs://logisticaapp-backups, 2 en URLs), **TODOS en archivos históricos esperados, 0 en código activo**.

**Sección nueva en RUNBOOK.md** "Decommission del proyecto legacy" con:
- 3 condiciones para proceder (tiempo + validación operativa + script limpio).
- Checklist de 8 ítems pre-decommission, incluido un backup final "por las dudas" del proyecto viejo antes de bajarlo.
- Comando final con 2 opciones:
   - **A) Bajar a Spark plan** (recomendado primero): conservador, gratis pero limitado, mantiene la DB accesible read-only por las dudas. Solo desde Console web.
   - **B) Borrar el proyecto entero**: `gcloud projects delete logisticaapp-e539a`. Definitivo, pero hay grace period de 30 días desde Console.
- Recomendación: A primero, después de otros 30 días sin actividad → B.

**Cuándo usar el script**:
- Antes del decommission real (≥ 2026-06-02).
- Cuando un cambio reciente pueda haber introducido referencias residuales sin querer.

Resultado: a partir del 2026-06-02 Santiago tiene todo el pensamiento hecho — solo ejecutar el checklist.

### 6.15 Sesión 2026-05-03 — Rebrand cosmético + cierre de la auditoría de fechas + swap del backup

Sesión nocturna corta enfocada en **cosmética** y **limpieza**. Sin features nuevas. Cinco commits a main (todos ff-only desde el worktree `claude/sad-liskov-f3bfd8`):

| Commit | Qué hace |
|---|---|
| `3ea91d5` | feat(brand): remake cosmético Coopertrans Móvil + cierre del rebrand |
| `59ee9e0` | docs: sacar `secrets.json` desactualizado del flujo de arranque |
| `950b2d2` | chore(brand): unificar fondo en gradient + borrar `fondo_login.jpg` + fix `.env.example` bot |
| `edd40e7` | feat(backup): backup automático cloud-side de Firestore (semanal) |
| `a4b33b9` | refactor(formatters): `formatearFechaHora` + último `.toIso8601String()` saneado |

#### 6.15.1 Identidad visual nueva (`3ea91d5`, `950b2d2`)

Coopertrans no tenía paleta de marca histórica — Santiago fue contratado para renovar. Se diseñó identidad nueva desde cero:

- **Paleta brand**: `AppColors.brand = #0EA5E9` (sky-500, azul cobalto) + `brandSoft` + `brandDark` para gradients. Convivencia limpia con la guard de CI que prohíbe nuevos `Colors.<accent>` directos.
- **Logo tipográfico** (sin glifo, escalable): widget `CoopertransLogo` con 3 tamaños (XL/M/S). Lockup: "Coopertrans" en blanco bold + " Móvil" en `AppColors.brand`.
- **SplashScreen** nueva (`/splash` como `initialRoute`): logo XL + spinner + tagline "GESTIÓN DE FLOTA · COOPERTRANS" sobre gradient brandDark → background. 1.5s y salta a `/home`.
- **Login rediseñado**: gradient en lugar de la foto `fondo_login.jpg` histórica, logo XL al tope, botón primario en brand color.
- **Mini-logo en AppBar** de TODAS las pantallas (`AppScaffold` + `AdminShell`): logo S + separador vertical + título de pantalla, alineado a la izquierda con `centerTitle: false`. Mantiene back button de Material y compatibilidad con `leading` custom.
- **Foto histórica `fondo_login.jpg` borrada**: ya no se usaba en ninguna pantalla. Las 2 que faltaban (AppScaffold y AdminShell) pasaron al mismo gradient del login para coherencia visual.

Cierre completo del rebrand "S.M.A.R.T. Logística" → "Coopertrans Móvil":

- **6 strings Dart**: `AppTexts.appName`, `AppTexts.tagline` (constante nueva), main_panel, admin_panel, admin_vencimientos_menu, login_screen.
- **7 metadata Windows runner**: título de ventana en `main.cpp`, FileDescription/InternalName/OriginalFilename/ProductName en `Runner.rc`, project + BINARY_NAME en `CMakeLists.txt`. **Rename del binario `logistica_app_profesional.exe` → `coopertrans_movil.exe`** — requirió `flutter clean` la primera vez para regenerar CMake cache (gotcha conocido).
- **9 docs/configs**: README, RUNBOOK, MANUAL_USUARIO, ESTADO_PROYECTO header, firestore.rules, storage.rules, .gitattributes, .gitignore, functions/package.json description, functions/src/index.ts header.
- **Footer del WhatsApp del bot** (user-facing real, requiere deploy de functions): "_Sistema S.M.A.R.T. Logística — Mensaje automático._" → "_Coopertrans Móvil — Mensaje automático._".
- **`whatsapp-bot/.env.example`**: `FIREBASE_PROJECT_ID=logisticaapp-e539a` (apuntaba al proyecto viejo) → `coopertrans-movil`. Si alguien arranca el bot desde cero ahora pega contra el proyecto correcto.
- ~~**NO se renombró** el package Dart (`logistica_app_profesional` en pubspec.yaml + imports `package:`)~~ → revertido el 2026-05-08 (commit `22b6825`): el package Dart se renombró a `coopertrans_movil` y todos los `import 'package:logistica_app_profesional/...'` pasaron a `import 'package:coopertrans_movil/...'`.

Detalle del brand en memoria: `feedback_brand_visual.md`.

#### 6.15.2 `secrets.json` sacado del flujo de docs (`59ee9e0`)

Las credenciales Volvo viven en Secret Manager + cliente vía `volvoProxy` desde 2026-04-29. README/RUNBOOK/ESTADO_PROYECTO/whatsapp-bot/* seguían describiendo el flujo viejo de `--dart-define-from-file=secrets.json` que ya no existía. Limpieza:

- README arranque: comando limpio `flutter run -d windows` + nota explicativa de dónde viven ahora las credenciales.
- ESTADO_PROYECTO: 5 secciones reescritas (estructura, setup, comandos útiles, tabla credenciales, gotchas operativos).
- RUNBOOK: tabla de credenciales sin la fila obsoleta + nota explicativa.
- `secrets.example.json` borrado (template ya no aplica).
- `.gitignore` mantiene `secrets.json` ignorado por defensa en profundidad.

#### 6.15.3 Backup automático Firestore — swap del sistema

**Importante**: hubo confusión en la primera mitad de la sesión porque la memoria local estaba desactualizada. El sistema **ya tenía** un Cloud Scheduler `firestore-backup-diario` corriendo desde el 2026-05-02. La sesión 03 implementó una **Cloud Function nueva** (`backupFirestoreScheduled`) por error, pensando que el backup no existía. Una vez detectado, Santiago decidió migrar al patrón scheduler-via-Function (versionable + frecuencia menor suficiente) en vez de tener ambos:

- **Sistema viejo (2026-05-02)**: Cloud Scheduler `firestore-backup-diario` con cron `0 3 * * *` ART, llamando al endpoint REST de Firestore export. **A borrar manualmente**: `gcloud scheduler jobs delete firestore-backup-diario --location=southamerica-east1 --project=coopertrans-movil`.
- **Sistema nuevo (commit `edd40e7`)**: Cloud Function `backupFirestoreScheduled` en `functions/src/index.ts` con `onSchedule("0 6 * * 0", America/Argentina/Buenos_Aires)` — domingos 06:00 ART. Usa `FirestoreAdminClient.exportDocuments` (long-running operation; la function termina apenas dispara el job, el export real corre en background en GCP). Output: `gs://coopertrans-movil-backups/auto-{YYYY-MM-DD}_{HHMM}/` con 17 colecciones operativas. Mismo bucket + mismo Object Lifecycle 30d que el sistema viejo (no hay que recrear nada del lado bucket).
- **Sección `Restaurar Firestore desde backup (disaster recovery)` nueva en RUNBOOK** con pasos para restaurar una colección puntual sin clobberar el resto.

Lección aprendida: la memoria del proyecto desactualizada hace proyectar trabajo que ya está hecho. Esta sesión cerró con un sync bidireccional explícito local ↔ Drive de todas las memorias para evitar repetirlo.

#### 6.15.4 Auditoría sistemática DD-MM-AAAA en cliente Flutter (`a4b33b9`)

Cierra el item "auditoría de fechas" pendiente desde el rebrand del 2026-05-02. Resultado del grep exhaustivo en `lib/**/*.dart`:

| Patrón buscado | Hits | Reales bugs |
|---|---|---|
| `.toIso8601String()` | 2 | **1** (sync_dashboard:309 — debug map) |
| `.toString()` de DateTime | 6 | 0 (todas checks defensivas sobre `dynamic`) |
| `DateFormat(...)` | 16 | 0 (todos formato AR: `dd/MM/yyyy`, `dd/MM HH:mm`) |

El código ya estaba sano. Cambios mínimos:
- `AppFormatters.formatearFechaHora(DateTime?)` — helper nuevo que devuelve `DD/MM/YYYY HH:mm:ss` en hora local (con conversión automática de UTC). Reemplazo seguro de `.toIso8601String()` para display.
- `SyncDashboardProvider.snapshot()`: usa el nuevo helper. Único hit real eliminado.

Deuda DRY conocida (NO bug): los 16 `DateFormat` dispersos podrían centralizarse en `AppFormatters`. Cuando se toque cada archivo por otro motivo, aprovechar para migrar.

#### 6.15.5 Memoria sincronizada bidireccional

Detección post-sesión: la memoria local en `C:\Users\santi\.claude\projects\...` divergía respecto a `G:/Mi unidad/ClaudeCodeSync/memory/` (single source of truth multi-PC). Drive tenía 5 entries que faltaban en local + el roadmap Volvo más actualizado; local tenía la nueva memoria de brand visual + correcciones del 2026-05-03 que faltaban en Drive. Sync bidireccional ejecutado, MEMORY.md mergeado, ambos lados quedaron al día.

### 6.16 Sesión 2026-05-04 — Revisión profunda Gomería + causa raíz crash Windows + alta en lote

Sesión larga de 8 horas con dos descubrimientos clave: el módulo Gomería tenía bugs operativos ocultos (rules + UX) que bloqueaban testing real, Y la causa del crash Windows que estaba documentada como "bug del plugin C++" era en realidad **`runTransaction` con cierta combinación de operaciones** — el resto de la app que usa Firestore intensivamente (alertas Volvo, telemetría, descargas, vencimientos) no rompía porque NO usaba ese patrón.

#### 6.16.1 Bugs críticos pre-existentes en gomería

Encontrados auditando el código antes de testear:

- **Rule `motivo_retiro` rebotaba el retiro entero** (`firestore.rules:408`): el `hasOnly` del update path en `CUBIERTAS_INSTALADAS` no incluía `motivo_retiro`, así que cualquier retiro con motivo escrito tiraba PERMISSION_DENIED y rolaba la transacción. Sin motivo andaba; con motivo no.
- **`Cubierta.puedeRecaparse` retornaba true para INSTALADA** pero el service rechazaba si no estaba EN_DEPOSITO. UI ofrecía cubiertas que después fallaban al guardar.
- **`CubiertaInstalada.fromMap` caía a TRACTOR por default** si `unidad_tipo` venía corrupto en Firestore — enmascaraba bugs de escritura. Reemplazado por `throw StateError` explícito.
- **Rules CUBIERTAS** sin validación de `creado_por_dni == auth.uid` (autoría falsificable).
- **`META/cubiertas_counter`** con regla `allow read, write: if isAdminOrSupervisor()` — un set manual o un bug de cliente podía romper la secuencia de códigos para siempre. Cerrada a `proximo == resource.data.proximo + 1` monotónico.

#### 6.16.2 Bloque UX masivo (8 fases)

- **Tile de posición ocupada** ahora muestra marca/modelo + vida (NUEVA/V2/V3...) + barra de % de vida útil consumida (verde/ámbar/rojo). El operador a 1m de distancia identifica la cubierta de un vistazo.
- **Cabecera del detalle de unidad** muestra `KM_ACTUAL` del tractor (info clave para decidir cambios sin ir a Flota).
- **Geometría dual**: gap entre INT|INT en los ejes de tracción para reflejar el espacio físico del eje.
- **Lista de unidades**: filtro `whereIn` server-side (antes bajaba toda la colección VEHICULOS).
- **Pantalla nueva detalle de cubierta** (`/admin_gomeria_cubierta`): historial completo de instalaciones + recapados + costo por km calculado.
- **Stock con búsqueda** por código (`CUB-XXXX`) y modelo + filtros completos por estado (TODAS / DEPÓSITO / INSTALADAS / EN_RECAPADO / DESCARTADAS).
- **Recapados** con tabs EN PROCESO / HISTÓRICO + resumen mensual (total, recibidas, descartadas, costo total).
- **Catálogo `CUBIERTAS_PROVEEDORES`** con dropdown extensible (selector + opción "+ nuevo proveedor" inline). Termina con typos en reportes.
- **Banner alertas en hub**: cubiertas instaladas que pasaron 80% de vida útil estimada (rojo si pasaron 100%). Tap → bottom sheet con detalle, navegable a la unidad.
- **Acción Rotar** en `_PosicionOcupadaDialog`: mover cubierta a otra posición de la misma unidad (vacía o swap).
- **Edición inline de modelo** (bottom sheet con `DatoEditable*` alineado al pattern de Personal/Flota).
- **Registrar control** (presión PSI + profundidad de banda mm) sobre la cubierta instalada.
- **Costo de cubierta**: `precio_compra` opcional en alta + cálculo automático de costo por km en detalle.

#### 6.16.3 Causa raíz crash Windows: `runTransaction` mal soportado por plugin C++

Santiago reportó que después de subir el stack Firebase a 6.3.0+ la app NI ABRÍA en Windows (regresión más grave). Revertido al 6.1.3 anterior. Pero el crash original "Lost connection" en gomería seguía. Diagnóstico fino:

- **Síntoma exacto**: al apretar GUARDAR en "Nueva cubierta", spinner gira y luego aparece **popup modal de Visual C++ Runtime: "Debug Error! abort() has been called"**. Crash nativo NO catcheable desde Dart.
- **Auditoría de patrones**: el resto de la app usa `runTransaction` también (asignaciones chofer↔vehículo, enganche↔tractor) pero con tx que solo hacen `tx.update`. Gomería era el único lugar con `tx.set` + `SetOptions(merge: true)` + `FieldValue.serverTimestamp()` dentro de la tx — combinación que dispara el bug del plugin.
- **Solución consolidada**: refactor de las 7 operaciones del `GomeriaService` para NO USAR runTransaction. Patrón aplicado:
  - Lecturas con `.get()` simples (paralelas con `Future.wait` cuando se puede).
  - Validaciones en cliente.
  - Writes secuenciales individuales.
  - Críticos primero (cerrar log, crear log); secundarios al final con `try/catch` que loguea a Crashlytics y continúa.
  - **Unicidad** que antes garantizaba la tx → ahora la garantizan rules `allow update: if false` sobre los docs de lock (`CUBIERTAS_POSICIONES_ACTIVAS` indexado por `{patente}__{POSICION}`, `CUBIERTAS_ACTIVAS` indexado por `cubierta_id`). Un `set` sobre un lock que ya existe rebota con permission-denied → race-safe sin tx.
  - Cleanup best-effort con `unawaited(...delete())` cuando una operación intermedia falla.

**Trade-off vs versión transaccional original**: si una operación falla mid-way (ej. red caída entre dos writes), queda estado parcial. Probabilidad práctica baja con un solo supervisor + red estable; los logs siguen siendo la fuente de verdad y un job de cleanup futuro puede reconciliar. Aceptable para destrabar Windows.

**Confirmado funcionando** end-to-end por Santiago: alta unitaria, alta en lote, instalar, retirar, rotar, mandar a recapar, recibir, descartar.

#### 6.16.4 Alta de cubiertas en lote (1 a 500)

A pedido explícito de Santiago: "cargar de a 1 con 120+ unidades es una locura". Vecchi compra cubiertas en lotes de 50/100/200 idénticas (mismo modelo, mismo precio, mismo lote del proveedor) y darlas de alta una por una era inviable.

- Service: `crearCubiertasEnLote(modeloId, cantidad: 1..500, ...)` reusa `crearCubierta` en serie. Serial porque la rule monotónica del counter rebotaría altas paralelas. Acepta callback `onProgreso(creadas, total)` para feedback de UI.
- UI: campo "Cantidad" en el dialog (default 1). Si > 1, el botón cambia a "CREAR N CUBIERTAS" + barra de progreso linear con "Creando X de Y…". Al terminar, snackbar muestra `✓ CUB-0010 a CUB-0050 (41 cubiertas) creadas`.
- Si una creación intermedia falla, el error muestra "Error tras crear X de Y" — el supervisor reintenta con la cantidad restante.
- Cap 500 por lote para evitar bloqueos de UI con números irrazonables.

#### 6.16.5 Schema y rules nuevos

Colecciones nuevas (todas con rules deployadas):
- `CUBIERTAS_POSICIONES_ACTIVAS/{patente}__{POSICION}` — lock de unicidad de posición. `allow update: if false`.
- `CUBIERTAS_ACTIVAS/{cubierta_id}` — lock de unicidad de cubierta. `allow update: if false`.
- `CUBIERTAS_PROVEEDORES/{auto}` — catálogo de proveedores de recapado. CRUD ABM por admin/supervisor.

Cambios sobre rules existentes:
- `CUBIERTAS_INSTALADAS` update path ampliado para incluir `motivo_retiro` + flow nuevo "registrar lectura" (presión + banda) sin cerrar el log.
- `META/cubiertas_counter` cerrado a increment monotónico.
- `CUBIERTAS` create con validación `creado_por_dni == auth.uid`.

Índices nuevos: `CUBIERTAS_RECAPADOS (cubierta_id ASC, fecha_envio DESC)` para historial por cubierta.

#### 6.16.6 Memoria actualizada

Re-escrita `feedback_windows_cloud_firestore_bugs.md` con la causa raíz correcta: el bug NO es del plugin "en general", es específicamente de `runTransaction` con cierta combinación de ops. Regla práctica nueva: **NO USAR `runTransaction` en código nuevo si la app correrá en Windows** — usar writes secuenciales con rules de unicidad sobre docs de control.

`project_modulo_gomeria.md` actualizada con el estado final post-refactor (7 colecciones totales contando los locks, 65 tests, todas las operaciones operativas).

### 6.17 Sesión 2026-05-08 — Empresas Empleadoras + watchdog diario + filtros del bot + carga masiva de ubicaciones

#### 6.17.1 Toggle vista satelital en mapas
Botón flotante top-right que alterna callejero (Carto Voyager) ↔ satélite (Mapbox Satellite v9). Útil para identificar puntos rurales por aspecto físico (silos, galpones, accesos a campo) cuando el callejero no tiene detalle suficiente. Aplicado en 3 mapas: `UbicacionMapPicker`, `LogisticaMapaTarifasScreen`, `AdminMapaVolvoScreen`. Solo aparece si hay token Mapbox configurado. Constantes nuevas en `MapConstants.tileSatelliteUrl` + `attributionSatelite`. Commits `b38991f`, `6d160ec`.

#### 6.17.2 Empresas Empleadoras — 4 docs comunes por razón social
Sistema nuevo: 4 documentos laborales que ANTES se cargaban empleado por empleado, ahora se cargan UNA SOLA VEZ por empresa empleadora y todos los empleados de esa razón social los ven en MIS VENCIMIENTOS (read-only, ícono lock).

**Docs**: Póliza ART, Formulario 931, SCVO (rotulado "Seguro de Vida" para el chofer), Libre deuda sindical.

**Modelo**: colección `EMPRESAS_EMPLEADORAS` con docId = CUIT (parseado del campo `EMPRESA` que ya guarda cada legajo). Catálogo hardcoded en `AppEmpresasEmpleadoras.catalogo` con las 2 razones sociales actuales (Vecchi Ariel + Sucesión Vecchi Carlos). Storage path `EMPRESAS_EMPLEADORAS/{cuit}/{campoUrl}_{ts}.{ext}`.

**UI**: pantalla admin nueva `/admin_empresas_empleadoras` (tile dentro del menú VENCIMIENTOS, no en el panel principal — se movió para no saturar). Tarjeta por empresa con 4 filas editables (fecha + archivo PDF). Capability `verVencimientos`.

**Limpieza**: la sección "Seguros y aportes" del legajo del empleado se eliminó. `AppDocsEmpleado.etiquetas` (en `vencimientos_config.dart`) y `DOCS_EMPLEADO` (en `whatsapp-bot/src/cron.js`) ya no incluyen ART/F.931/Seguro Vida/Sindicato — el bot no manda WhatsApp al chofer por estos docs (decisión Vecchi: el chofer no puede hacer nada al respecto, sería ruido).

Commits `35967e1`, `87d6b4f`, `f5efaf1`, `84d9ed9`, `2aa09e7`. Detalle en `project_empresas_empleadoras.md`.

#### 6.17.3 Filtros y nuevos resúmenes del bot WhatsApp
- **ADBLUE fuera del resumen Seg e Higiene**: `ADBLUELEVEL_LOW` y `WITHOUT_ADBLUE` quedan EXCLUIDOS del resumen Volvo HIGH a Molina (son temas mecánicos del taller, no de seguridad). Siguen entrando al resumen mantenimiento de Emmanuel. Constante `TIPOS_EXCLUIDOS_SEG_HIGIENE` en `cron.js`. Commit `72ee6f2`.
- **Resumen vencimientos próximos a Giagante**: cron nuevo `cron_vencimientos_proximos_diario` en bot. Consolida diariamente todo lo que vence en próximos 7 días en 3 universos (legajo de cada chofer + papeles de cada unidad + 4 docs por empresa empleadora) y manda 1 WhatsApp al encargado de documentación. Destinatario configurable por env var `DOCUMENTACION_DESTINATARIO_DNI` (default operativo: 26456455 = Giagante Guillermo). Si no hay nada que vence, no manda mensaje. 8 tests nuevos (108 totales en el bot). Commits `1569fe3`, `3b7dfb2`.

#### 6.17.4 Watchdog del bot — caída inmediata → resumen diario 8 AM
ANTES `botHealthWatchdog` mandaba WhatsApp **inmediato** al detectar que el bot estaba sin heartbeat. Problema: el cron corre cada 15 min, así que el aviso podía llegar mucho después de la caída — cuando capaz ya recuperó. Genera ruido y fuerza a chequear cuando no hace falta.

Cambio:
- `botHealthWatchdog` ya NO encola WhatsApp. Solo registra eventos en la nueva colección `BOT_EVENTOS` (tipo: `caida` con `minutosSinHeartbeat`, `recuperado` con `duracionMin` total estimada).
- Cron nuevo `resumenBotDiario` corre 8 AM ART, lee `BOT_EVENTOS` últimas 24h, arma resumen consolidado (caídas + recuperaciones + tiempo total caído) y manda 1 WhatsApp a Santiago. Si no hubo eventos, silencio.
- Idempotencia diaria via `AVISOS_AUTOMATICOS_HISTORICO`.
- Firestore rule nueva para `BOT_EVENTOS` (read admin/supervisor, write false — solo Admin SDK).

Commits `d17fad0`, `7586725`. Pendiente deploy de las 2 funciones.

#### 6.17.5 Carga masiva de 47 ubicaciones de la lista de Maps
Santiago tenía una lista colaborativa de Google Maps con 47 destinos de carga/descarga. Las listas nuevas de Maps (`maps.app.goo.gl`) NO se exportan via Takeout, ni se pueden scrapear (Chrome MCP rechaza `google.com` por privacy, computer-use enmascara browsers). Único camino operativo: el user pegó las URLs `/maps/place/...` una por una y el parser sacó las coordenadas precisas de los pares `!3d!4d`. CSV guardado en `scripts/ubicaciones_logistica.csv` (47 filas con localidad/provincia inferidas por contexto), cargadas con el script existente `importar_ubicaciones_logistica.py` (idempotente por nombre). Las ubicaciones quedaron sin empresa asociada — Santiago las completa después en la app. Commit `164899a`.

#### 6.17.6 Versión publicada
**1.0.31+34 publicada en Windows** (release_completo.ps1 desde la PowerShell de Santiago — el script falla si lo dispara el sandbox de Claude Code por loopback IOException de Java/Gradle, pero corre OK desde la PowerShell del user). AAB Android lo subió Santiago manualmente a Play Console. Después de la sesión la versión visible es 1.0.39+ — Santiago corrió release_completo varias veces durante el día con ajustes.

Lección documentada en `project_pendientes_post_migracion.md`: para releases siempre pasarle el comando a Santiago, NO disparar yo en background.

#### 6.17.7 Memoria + docs
Actualizados: `MEMORY.md` (index), `project_alertas_y_resumenes_whatsapp.md` (filtro ADBLUE + cron Giagante + watchdog daily), `project_pendientes_post_migracion.md` (cierre de la sesión + lecciones aprendidas), `ESTADO_PROYECTO.md` (esta sección). Nuevo: `project_empresas_empleadoras.md`. Sync automático a Drive vía claudesync hook.

### 6.18 Decommission del proyecto legacy `logisticaapp-e539a` — 2026-05-08

Ejecutado vía Firebase / GCP Console (Shut down) **25 días antes** de la ventana de validación sugerida (≥ 2026-06-02). Decisión explícita del owner: la data viva ya está en `coopertrans-movil` desde la migración 2026-05-02 y la app + bot + cron llevan 6 días operando contra el proyecto nuevo sin observaciones — no había necesidad evidente de mantener la red de seguridad.

**Sin backup final del proyecto viejo** (decisión explícita — ya está todo replicado en el proyecto nuevo).

El proyecto quedó en estado `DELETE_REQUESTED` con grace period de 30 días: **recuperable hasta ~2026-06-07** desde [GCP Console → IAM & Admin → Manage Resources → "Show deleted resources"](https://console.cloud.google.com/cloud-resource-manager). Pasada esa fecha, **irrecuperable**.

**Auditoría previa OK**: `auditar_referencias_proyecto_viejo.ps1` salió con 0 hits en código activo (28 hits en archivos históricos esperados — README/RUNBOOK/script de auditoría / commits viejos).

**Bucket de backups del proyecto viejo** (`gs://logisticaapp-backups`): se borra automáticamente con el proyecto cuando termine el grace period.

`RUNBOOK.md` sección "Decommission del proyecto legacy" marcada como DECOMMISSIONED — queda como referencia histórica del procedimiento.

`project_pendientes_post_migracion.md` actualizado para sacar el ítem del roadmap.

## 7. Pendientes / roadmap

### Migración Firebase Auth (branch `feature/firebase-auth`) — ✅ COMPLETADA 2026-04-29
- ✅ Cloud Function `loginConDni` callable Gen2 deployada en southamerica-east1 (Node.js 20 + bcrypt server-side). Migrada desde us-central1 el 2026-05-02 para colocar Functions en el mismo DC que Firestore.
- ✅ `AuthService` llama vía **HTTPS directo con Dio** (no `cloud_functions` plugin) porque ese plugin no tiene implementación nativa para Windows desktop. El protocolo callable (`{"data": ...}` request, `{"result": ...}` response) se maneja a mano.
- ✅ `AuthGuard` con doble check (PrefsService + FirebaseAuth.currentUser).
- ✅ `firestore.rules` y `storage.rules` reescritas con `isAdmin()` por custom claim — DEPLOYADAS.
- ✅ Probado en producción: admin login + chofer login + migración silenciosa SHA-256→bcrypt.

**Gotchas críticos encontrados durante el deploy** (anotar para próximas funciones Gen2):

1. **Cloud Build SA permissions**: en proyectos Firebase post-abril 2024, la SA por default `<PROJECT_NUMBER>-compute@developer.gserviceaccount.com` no recibe permisos automáticos. Hay que asignarle como mínimo: `Cloud Functions Developer`, `Cloud Run Admin`, `Service Account User`, `Cloud Build Service Account`, y `Editor` (o roles equivalentes más finos).
2. **`allUsers` invoker**: las Functions Gen2 NO son invocables públicamente por default (a diferencia de Gen1). Para callables públicos como `loginConDni`, hay que agregar `allUsers` con rol **`Cloud Run Invoker`** en Cloud Run permissions (no en la pantalla de Functions, no aparece "Cloud Functions Invoker" — Gen2 corre sobre Cloud Run).
3. **`signBlob` permission para `createCustomToken`**: la SA de runtime necesita el rol **`Service Account Token Creator`** **sobre sí misma**. Sin esto, `auth.createCustomToken()` falla con `iam.serviceAccounts.signBlob denied`.
4. **`cloud_functions` Dart package no soporta Windows**: si se agrega y se importa, tira `Unable to establish connection on channel: dev.flutter.pigeon.cloud_functions_platform_interface.CloudFunctionsHostApi.call`. Solución: llamar la function por HTTPS plano con Dio respetando el protocolo callable.

### Hardening de seguridad — ✅ COMPLETADO 2026-04-29 PM
1. ✅ **Rate limiting** en login: 5 intentos fallidos consecutivos → bloqueo 5 min. Implementado en `loginConDni` con colección `LOGIN_ATTEMPTS/{dniHash}` (clave hasheada para no exponer DNI). Reset automático al login OK. Rule: `write: if false`.
2. ✅ **Volvo credentials → Secret Manager** + Cloud Function `volvoProxy` (callable, requiere admin auth). El cliente Flutter llama al proxy por HTTPS con Bearer ID-token; el proxy valida `request.auth.token.rol === 'ADMIN'`, agrega Basic Auth Volvo y forwardea. Operaciones: `flota`, `telemetria`, `kilometraje`, `estadosFlota`. Secrets seteados con `firebase functions:secrets:set VOLVO_USERNAME/VOLVO_PASSWORD`.
3. ✅ **TELEMETRIA_HISTORICO movido al server**: `telemetriaSnapshotScheduled` corre cada 6h, llama `/vehicle/vehiclestatuses?latestOnly=true` (NO `/vehicle/vehicles` — bug latente del original que no traía telemetría real), escribe doc idempotente por `{patente}_{YYYY-MM-DD}` con `engineTotalFuelUsed/1000` (mL→L) y `hrTotalVehicleDistance/1000` (m→km). Rule: `write: if false`.
4. ✅ **Cloud Functions runtime → Node.js 22** (Node 20 deprecation = 2026-04-30, decommission = 2026-10-30). Bumpeado en `firebase.json` y `functions/package.json`.
5. ✅ **Auto-login + recordar último DNI**: `PrefsService.lastDni` sobrevive al logout para precargar el campo. `AuthGuard` reescrito como StatefulWidget con grace period de 1.5s (Firebase Auth en Windows desktop emite `null` primero y el user persistido ~500-1500ms después; sin grace period, el guard bouncea al login antes de tiempo). `_PassField`/`_DniField` usan `autofocus: true` idiomático (no `requestFocus` desde initState que dispara assertion `RenderBox was not laid out` en Windows).

### Roadmap medio plazo pendiente
1. ✅ **Refactor `admin_personal_lista_screen.dart`** — COMPLETADO 2026-04-29 noche. `_Actualizar` extraído a `lib/features/employees/services/empleado_actions.dart` como `EmpleadoActions`. Archivo lista pasa de 1295 a 727 líneas (-568). API pública preservada (`dato`/`fotoPerfil`/`documento`/`unidad`). `flutter analyze` limpio. El enum `_FuenteArchivoChofer` quedó privado al archivo nuevo. Convive con `EmpleadoService` (CRUD puro de Firestore, otra capa).
2. ✅ **`flutter_secure_storage`** — COMPLETADO 2026-04-29 medianoche. `PrefsService` migrado a `flutter_secure_storage: ^9.2.2` con cache en memoria para preservar API sync. Migración one-shot idempotente desde SharedPreferences viejo (limpia las claves al copiar). Backend nativo por plataforma (DPAPI/Keychain/KeyStore). Pendiente: `flutter pub get` + `flutter analyze` + probar login/logout en Windows.
3. ✅ **Mover `AUDITORIA_ACCIONES` al server** — COMPLETADO Y DEPLOYADO 2026-04-29 noche tarde. Cloud Function callable `auditLogWrite` (Gen2 en `functions/src/index.ts`). Cliente reescrito en `lib/core/services/audit_log_service.dart` para llamar via Dio + Bearer ID token. Rule cerrada a `write: if false`. Whitelist server-side de 11 acciones permitidas + 3 entidades. `admin_dni`/`admin_nombre` se toman del JWT (no del cliente, así no se pueden falsificar). **Pendiente único**: agregar `allUsers` Cloud Run Invoker al servicio `auditlogwrite` para que clientes Flutter puedan invocarlo:
   ```powershell
   gcloud run services add-iam-policy-binding auditlogwrite `
     --region=southamerica-east1 --member="allUsers" --role="roles/run.invoker"
   ```
   (Sin esto la app va a recibir 403 al intentar auditar acciones.)

### Roadmap largo plazo (Volvo)
- **Anti-robo nocturno**: `wheelBasedSpeed > 0` fuera de horario operativo + push notification al admin. Requiere FCM real (hoy solo local notifications).
- ✅ **Mantenimiento preventivo** — COMPLETADO 2026-04-29 madrugada. Ver sección "Sesiones recientes" arriba. La feature usa `serviceDistance` que viene en el endpoint `/vehicle/vehiclestatuses` estándar (no requirió endpoint VDDS específico). Pantalla en `lib/features/vehicles/screens/admin_mantenimiento_screen.dart`. Tile en `admin_panel_screen.dart`. Rule `MANTENIMIENTOS_AVISADOS` agregada.
- **Alertas de conducción** (descanso, conducción continua excedida) — requiere taquógrafo digital activo en los camiones.

### Decisiones del backlog (sin urgencia)
- Reemplazar `AVISOS_VENCIMIENTOS.streamHistorial` server-side con índice compuesto si llega a haber miles de avisos.
- Migrar `notification_service` a FCM (push real) cuando se sumen choferes con la app móvil.

## 8. Setup en una máquina nueva

### Pre-requisitos
- Flutter SDK 3.0+
- Python 3.10+ (solo para scripts de migración)
- Cuenta Firebase del proyecto `coopertrans-movil`
- Editor: VS Code con extensiones Dart + Flutter

### Pasos
```powershell
# 1. Clonar
git clone <url-del-repo> coopertrans_movil
cd coopertrans_movil

# 2. Recrear `serviceAccountKey.json` (NO está en git) si vas a correr
#    scripts/admin o el bot. Copiarlo desde Bitwarden / Drive privado.
#    Las credenciales Volvo NO se cargan localmente: viven en Secret
#    Manager y el cliente las consume vía la Cloud Function `volvoProxy`.

# 3. Instalar dependencias Flutter
flutter pub get

# 4. (Opcional) Para scripts Python
pip install firebase-admin

# 5. Correr la app (Windows)
flutter run -d windows
# (en VS Code F5 ya tiene la config lista en .vscode/launch.json)
```

| Archivo | Para qué | Cómo |
|---|---|---|
| `serviceAccountKey.json` | Admin SDK Firebase para scripts y bot | Generar en Firebase Console → Project Settings → Service accounts → Generate new private key. |

> Las credenciales Volvo Connect (`VOLVO_USERNAME`/`VOLVO_PASSWORD`) ya **NO** se cargan vía `secrets.json` desde 2026-04-29: viven en Secret Manager de GCP y el cliente Flutter las consume vía la Cloud Function `volvoProxy`.

## 9. Cómo retomar contexto en Claude / Cowork

Cowork no sincroniza historial entre desktops. Para una conversación nueva (otra máquina, o nuevo Claude), pegale al iniciar:

> Hola Claude. Vengo trabajando en una app Flutter de gestión de flota llamada **coopertrans_movil** (Coopertrans Móvil, empresa Vecchi en Bahía Blanca). Antes de empezar, leé `ESTADO_PROYECTO.md` y `AUDITORIA_2026-04-28.md` que están en la raíz del repo — ahí tenés el contexto completo: arquitectura, convenciones, lo que está hecho, lo que queda pendiente y las decisiones tomadas con sus razones. Trabajamos siguiendo esas convenciones (input de fecha DD/MM/AAAA con `pickFecha`, listas centralizadas en `AppVencimientos` y `AppTiposVehiculo`, mensajes con firma "_mensaje automático del sistema_", `AppFeedback` para SnackBars, `AppLoadingDialog` para loadings, `AppConfirmDialog` para confirmaciones, `AppColors` en lugar de hardcodear, etc). El próximo paso pendiente es <X>. ¿Listo para arrancar?

Reemplazá `<X>` con lo que quieras hacer ese día.

## 10. Comandos útiles

```powershell
# Correr la app en debug
flutter run -d windows

# Build de release Windows
flutter build windows --release

# Análisis estático
flutter analyze

# Migración Firestore (idempotente, soporta --dry-run)
python scripts/migrar_psicofisico_a_preocupacional.py --dry-run

# Bajar/subir cambios entre máquinas
git pull                           # antes de empezar
git add . ; git commit -m "..."    # cuando termines
git push

# Si la rama divergió por history rewrite (force push) en otra máquina:
git fetch origin
git branch backup-pre-reset
git reset --hard origin/main
git clean -fd
flutter pub get

# Ver últimos commits
git log --oneline -10
```

## 11. Notas operativas que no son obvias

- **El bot Node.js es un proceso vivo separado**: si nadie lo levanta en un servidor, los mensajes de la cola **NO se envían**. La app sola no manda WhatsApp automático — solo encola. Click-to-Chat (`wa.me`) sí funciona porque abre WhatsApp del admin.
- **Tres gotchas conocidos al setup del bot Node.js** (descubiertos 2026-04-29 noche, todos resueltos en código pero igual hay que tener en cuenta):
  1. **Reloj de Windows desincronizado** → tira `UNAUTHENTICATED` en Firestore. Verificar con `w32tm /query /status`. Si el servicio Windows Time no corre, iniciarlo: `Start-Service w32time`, `Set-Service -Name w32time -StartupType Automatic`, `w32tm /resync /force` (PowerShell admin).
  2. **`serviceAccountKey.json` revocado** → mismo error `UNAUTHENTICATED` aunque el JSON parezca válido. La key actual del repo es de la rotación 2026-04-29 mañana. Si en alguna PC quedó una key vieja-vieja, regenerar desde Firebase Console → Project Settings → Service Accounts → Generate new private key.
  3. **Stream gRPC se cae cada ~2 min** en redes con NAT agresivo. El bot ya está hecho con polling (no `onSnapshot`) para evitarlo, pero si en el futuro alguien revierte a streams, atención.
- **Las pantallas del bot WhatsApp no están en `app_router.dart`**: el agente sospecha que se acceden desde un menú interno del `admin_shell` o por feature flag. Si querés agregarlas al menú principal, hay que registrar las rutas y sumar tiles en `admin_panel_screen.dart`.
- **Si Volvo rota el password en su portal**: actualizarlo en Secret Manager (GCP del proyecto `coopertrans-movil`, secrets `VOLVO_USERNAME`/`VOLVO_PASSWORD`) y redeployar `volvoProxy` para que tome la nueva versión. La app cliente NO necesita rebuild.
- **Si se agrega una colección Firestore nueva**: sumarla a `firestore.rules` ANTES de hacer deploy de la app. El fallback `if false` la cerraría.
- **El primer ciclo del AutoSync corre al instante** al abrir la app (no espera 60 seg). Después cada minuto.
- **Los choferes tienen formato `APELLIDO NOMBRE...`**: el saludo del WhatsApp toma `partes[1]`. Si un legajo viene con ord

## 12. Bugs del sandbox de Cowork (workarounds)

### Síntoma: lectura truncada de archivos grandes

El sandbox Linux de Cowork está montado sobre el filesystem Windows y a
veces queda con una **vista desactualizada** de archivos que se editaron
fuera de la sesión (por VS Code, builds, `flutter pub get`). Síntomas:

- `Read` tool del agent muestra el archivo cortado mid-línea o mid-método.
- `wc -l` desde el sandbox devuelve menos líneas que `Get-Content | Measure-Object -Line` desde PowerShell.
- Edits con el `Edit` tool fallan con "String to replace not found" porque el match no existe en la vista parcial.

### Síntoma: bytes NULL al final del archivo tras un Write

Cuando el agent escribe un archivo más corto que la versión previa,
el `Write` tool a veces no truncar el backing file y queda relleno con
`\x00` al final. El TypeScript/Dart compiler tira *Invalid character*.

### Workarounds que probamos y funcionan

1. **Para reads de archivos > 500 líneas**: usar `python3 -c "with open(...)"` desde Bash. Lee directo del filesystem syscall y suele ver la versión actualizada.
2. **Para writes/edits con riesgo**: usar `python3 << 'EOF' ... EOF` con `read()`/`replace()`/`write()` y al final hacer `data.rstrip(b'\x00').rstrip() + EOL.encode()`. Eso elimina nulos residuales y garantiza un newline final limpio.
3. **Para refactors grandes**: hacelo a mano en VS Code, no le pidas al agent que mueva código entre archivos. El agent puede asistir con instrucciones de qué cortar/pegar.
4. **Verificación periódica**: cuando dudes, pegale `Get-Content archivo.dart | Measure-Object -Line` desde PowerShell y compará con `wc -l` del agent. Si difieren, agarra la vista de PowerShell como autoridad.
5. **Sandbox fresco**: cerrar la conversación de Cowork y abrir una nueva re-monta el filesystem y suele resolver la staleness. Hacerlo entre sesiones grandes (ej. fin de día → mañana siguiente).

### Cómo arrancar una sesión fresca

Al abrir una conversación nueva de Cowork sobre este proyecto:

1. Pedile al agent que ejecute (ejemplo de prompt): *"verificá con python que `lib/features/employees/screens/admin_personal_lista_screen.dart` tiene 1140 líneas en disco. Si es menos, decime y esperamos."*
2. Si el conteo coincide con `Get-Content | Measure-Object -Line`, la vista está fresca y se puede laburar normal.
3. Si difiere, pasale al agent el contenido completo del archivo por chat (vía `Get-Content archivo | Out-Host`) para que opere desde texto explícito en vez de la vista del filesystem.

### Refactor pendiente que se trabó por este bug

- `admin_personal_lista_screen.dart` → extraer `_Actualizar` a `services/empleado_actions.dart`. Ver sección 7. Plan listo, ejecutar en sandbox fresco o a mano.

### Síntoma: lockfile residual en `.git/` tras comandos del sandbox

Cualquier comando git desde el sandbox que toque el index (`git fetch`,
`git pull`, `git add`, etc.) puede dejar `.git/index.lock` o
`.git/objects/maintenance.lock` que el sandbox NO puede borrar después
(Operation not permitted sobre `.git/`). Resultado: el próximo `git add`
desde PowerShell falla con "Another git process seems to be running".

**Workaround**: borrar manual desde PowerShell:

```powershell
Remove-Item .\.git\index.lock -ErrorAction SilentlyContinue
Remove-Item .\.git\objects\maintenance.lock -ErrorAction SilentlyContinue
```

**Regla preventiva para Claude**: desde el sandbox solo correr comandos
git de lectura (`status`, `log`, `diff`, `show`). Si necesita
escribir/sincronizar (fetch, pull, add, etc.), pedírselo al usuario que
lo corra desde PowerShell. Si por algún motivo se ejecuta uno de esos
comandos y aparece la advertencia "unable to unlink ... index.lock",
avisarle al usuario en el mismo mensaje para que limpie antes del
próximo commit.


## 13. Pendientes para próximas sesiones — anotaciones del 2026-04-30 noche

Al cerrar la sesión del 30 de abril, quedaron estos temas en el aire que conviene retomar en la próxima reunión con Claude (idealmente desde un chat nuevo para que el sandbox quede sincronizado limpio).

### 13.1 Validaciones pendientes (importante)
- **⚠️ Verificar el bug de timezone reportado** — ahora con `AppFormatters.tryParseFecha` migrado en 9 call sites (Fase 2 #9), el bug de Victor Raul Jesus (DNI 38303285) debería estar resuelto. Confirmar con el próximo aviso o forzando el cron.
- **⚠️ Validar la agrupación de mensajes**. La lógica está deployada y commiteada (`13da5b2`) pero no se vio funcionar con datos reales. Plan: mandar `/forzar-cron` desde el celular admin al bot, esperar el ciclo, mirar el log buscando líneas como `+ Encolado AGRUPADO: <DNI> (N papeles) → ...`. Si aparece, abrir Firestore y ver el doc en COLA_WHATSAPP — debe tener `origen: 'cron_aviso_agrupado'` y campo `items_agrupados` poblado.
- **Verificar el bug de timezone reportado**. La licencia de VICTOR RAUL JESUS (DNI 38303285) vence el 30/05 pero el bot le mandó "vence el 29/05". El fix de parseo manual `YYYY-MM-DD` ya está deployado en `cron.calcularDiasRestantes` y `aviso_builder.formatearFecha`, pero hay que confirmar en producción que ahora dice 30/05. Mirar el próximo aviso que mande el bot a ese DNI o forzar el cron.

### 13.2 Mejoras al bot pendientes
- **Alerta "chofer no respondió"**. Si un chofer recibió aviso crítico (≤7 días o vencido) y no contestó con comprobante en X días, alerta automática al admin. Implementación: en el cron, además del check de `yaSeEnvio`, agregar un check de "tiene aviso enviado hace > X días sin respuesta". Si sí, encolar mensaje al admin (no al chofer) con el tema. Requiere un campo `respondido` en el histórico que se llene con Fase 3.
- **Habilitar Fase 3 con OCR**. Hoy `AUTO_RESPUESTAS_ENABLED=false`. Cuando lo activemos, el chofer puede mandar foto del comprobante y el bot crea automáticamente la revisión con la fecha extraída por OCR. Antes de activar, agregar OCR de la imagen (Cloud Vision o Tesseract local) — actualmente solo extrae fecha del texto del mensaje, no de la imagen. Implica testing con choferes reales. Ver `whatsapp-bot/src/message_handler.js` y `fecha_extractor.js`.
- **Pantalla del bot mejorada — mostrar items_agrupados**. Cuando se inspecciona un mensaje agrupado en la pantalla "Estado del Bot" o "Cola WhatsApp", mostrar el detalle de qué papeles incluyó (ya está guardado en el doc, falta UI). Sin esto, ves "AGRUPADO" pelado.

### 13.3 App Flutter
- **Pantalla "Mi perfil del chofer"**. Hoy es mínima. Podría tener: foto, vencimientos personales con días restantes, contacto rápido al admin (botón WhatsApp), historial de revisiones del chofer.
- **✅ Sweep de hallazgos sospechosos del code-review** — verificado en sesión 1-mayo (Fase 4 #16). Ambos candidatos eran falsos positivos:
  - `selectNotificationStream` sí se usa: `main.dart:137` lo escucha.
  - `intl` sí se usa: `admin_bot_bandeja_screen.dart:234` con `DateFormat('dd/MM HH:mm').format(...)`. `flutter analyze` global confirma 0 issues.
- **✅ Limpiar el drift del working tree** — resuelto en sesión 1-mayo (Fase 4 #15). Creado `.gitattributes` con LF para texto, CRLF para `*.ps1`/`*.bat`/`*.cmd`, binarios untouched + `git add --renormalize .` aplicado. **Recomendado en Windows**: `git config --global core.autocrlf input`.

### 13.4 Producción / DevOps
- **Deploy NSSM como servicio Windows** en el server dedicado. El script ya está en `whatsapp-bot/scripts/instalar_servicio.ps1` listo para correr cuando termine el ensayo en la PC de programación. Lo deja autostart al boot, auto-restart si crashea, logs rotados.
- **Configurar AUTO_AVISOS_ENABLED en server**: hoy en `.env` está `true` pero conviene revisar antes del deploy en server para no mandar avisos durante setup.

### 13.5 Volvo
- **Anti-robo nocturno**: detectar `wheelBasedSpeed > 0` fuera de horario operativo + push al admin. Requiere FCM real porque hoy solo hay notificaciones locales (que no llegan si el admin no tiene la app abierta). Bloqueado por la pre-condición de FCM.
- **Activar bloque UPTIME** en cuenta Volvo Connect: la API hoy no devuelve `uptimeData.serviceDistance` por restricción del paquete contratado. Hay un ticket abierto a Volvo. Mientras, el bot usa el Plan B (cálculo desde `ULTIMO_SERVICE_KM + 50.000 - KM_ACTUAL`).

### 13.6 Comandos admin por WhatsApp — extensiones futuras
- `/sync` para forzar sincronización Volvo de un tractor específico.
- `/avisos hoy` para ver lista de avisos enviados hoy.
- `/lid` para que el bot responda con tu LID actual (útil cuando reinstalás y se pierde el binding).

---

## 14. Sesión 2026-05-18 PM — auditoría profunda + tests + splits estructurales

Sesión de cierre de día con **6 agentes paralelos del code-review** que revisaron Flutter / Cloud Functions / WhatsApp bot / Firestore Rules+Indexes / CI+DevOps / Tests+Docs+Deps. Output: ~145 findings priorizados. Aplicados los **HIGH y CRITICAL** + parte de los MEDIUM. Total ~20 commits.

### 14.1 🐛 Bug REAL en producción descubierto por test (lo más relevante)

`functions/src/jornadas_v2.ts:horaArt()` devolvía **24** (no 0) para medianoche ART en Node V8 — `Intl.DateTimeFormat('en-CA', { hour12: false })` devuelve `"24"` para medianoche, no `"00"`. La lógica de veda nocturna (`horaActual >= 0 && horaActual < 6`) daba false con 24 → **el chofer que arrancaba 00:00-00:59 ART NO recibía aviso de veda nocturna**. Ventana ciega de 1h/día por al menos 3 refactors del vigilador sin detectarse.

Test descubrió el bug. Fix: `return h === 24 ? 0 : h`. El test queda como regression guard. Commit `a4ab509`.

**Lección**: tests de helpers PUROS valen la pena aunque parezcan triviales — atrapan asunciones que llevan años sin revisarse.

### 14.2 Auditoría aplicada — items HIGH y CRITICAL

**Sentry (4 commits)** — storm de 781 events/h en producción por FAB del Scaffold hit-test mid-transición:
- `38315b1` — Panel km/L → L/100km (métrica AR).
- `ed24c66` — `beforeSend` con 3 capas: drop network glitches + cancelaciones + Flutter framework asserts + rate limiter fingerprint (1/10s).
- `0bd873c` — `SentryNavigatorObserver` para grabar ruta como breadcrumb.
- `201c300` — Release name unificado Windows/Android/iOS via `PackageInfo.fromPlatform()`.

Ver memoria `feedback_sentry_observabilidad.md` para detalle. Plan free de Sentry: filtros custom server-side requieren Team plan ($26/mes), así que los fixes son todos client-side.

**Cliente Flutter — fixes (1 commit)**:
- `f68ecdb` — **Regresión RBAC en CHECKLISTS**: query no filtraba por DNI, el chofer no veía "completado" si OTRO chofer manejaba su patente ese mes (rotación de unidades). + DNI maskeado en 4 logs (asignacion_vehiculo + auth_service).

**WhatsApp bot — fixes (2 commits)**:
- `e499da2` — `/pausar` y `/reanudar` con `serverTimestamp` (eran `new Date()` local — drift si PC desfasa hora) + delay entre chunks 5-15s (antes 2-3s, anti-baneo) + pattern "rate limit" en `_PATRONES_DEFINITIVOS` + cache silenciados (60s TTL, ahorra reads).
- `52c36a9` — TTL **36h** en los 3 resúmenes diarios del bot (`service_diario`, `mantenimiento_diario`, `vencimientos_proximos_diario`). Cierra el gap del fix Fase 2: doc encolado en día X + bot crashea + vuelve días después → ahora consumer dropea por TTL.

**Cloud Functions — fixes (1 commit)**:
- `12fb37a` — Limits defensivos + warn al alcanzar en queries grandes (resumen conducta, ICM semanal, EMPLEADOS).

**Rules + indexes (1 commit)**:
- `0855510` — `BORRADORES_VIAJE` guard de owner (cualquier admin podía pisar borrador de otro operador) + index JORNADAS DESC (descansoPrevioCumplido iba a fallar la primera vez con "needs index") + TTL `expira_en` declarado en `fieldOverrides` para COLA_WHATSAPP.

**Deps + cleanup + CI (3 commits)**:
- `7730393` — `npm audit fix` resuelve CVE HIGH (`fast-xml-builder` en functions) + MODERATE (`ws` transitive en bot).
- `04716d7` — Mover 4 scripts deprecated (apuntaban a JORNADAS_CHOFER legacy) a `scripts/_deprecated/` + borrar logs viejos.
- `0abbeca` — README crons actualizado (de 9 → 16 reales), MANUAL roles de 4 → 6 (faltaban GOMERIA + SEG_HIGIENE), comment outdated en `icm_historico_service.dart`.
- `4361c31` — Pinear Flutter **3.41.7** en `.github/workflows/ci.yml` + `ios/ci_scripts/ci_post_clone.sh` + `.flutter-version` (Build 14 iOS ya falló por esto).

### 14.3 Refactor estructural — splits de archivos gigantes

**`logistica_viaje_form_screen.dart` 2823 LOC → 5 archivos** (commit `95f6c27`):
Patrón `part of` (mismo que `user_mis_vencimientos_widgets.dart`).
- `_screen.dart` (1035 LOC) — state machine principal
- `_tramos.dart` (523 LOC) — `_TramoEditState`, `_TramoCard`, `_DropdownProducto`, `_BotonAgregarTramo`, `_BannerEncadenamiento`
- `_secciones.dart` (575 LOC) — Resumen + Estado + Chofer + Unidad + AdelantoAsociado + UpperCaseFormatter
- `_tarifa_picker.dart` (296 LOC) — modal sheet con buscador
- `_gastos.dart` (248 LOC) — sección gastos por tramo
- `_widgets.dart` (229 LOC) — common widgets (Card, BotonFecha, ResumenTarifa, BotonesGuardar)

**`functions/src/index.ts` 6884 → 3568 LOC (-48%, 50% del split hecho)** (commits `90edd44`, `a6a90f5`, `75f61f1`, `38f4acf`):

Patrón `export *` desde el entry point oficial (TS no tiene `part of`):
- `setup.ts` — initializeApp + setGlobalOptions + db + auth + constants
- `helpers.ts` — `expiraEnMin`, `primerNombre`, `rrPick`, formatos AR (ya existía + drift fix: jornadas_v2 capitaliza nombres ahora + round-robin determinístico anti-baneo)
- `cleanup_y_recibos.ts` — asignarNumeroReciboAdelanto + purgarColaWhatsappAntigua
- `dashboard_stats.ts` — recomputeDashboardStats + helpers
- `mantenimiento.ts` — backup + bot_health + vigilador wrappers
- `sitrack.ts` — 2 pollers
- `resumenes_diarios.ts` — 4 resúmenes 08:00 ART

**Pendiente del split**: `auth.ts` (~1700), `volvo_alertas.ts` (~1900), `volvo_scores.ts` (~400), `telemetria.ts` (~350), auditLogWrite. Ver memoria `project_split_functions_index.md`.

### 14.4 Tests de lógica de negocio crítica (2 commits)

Setup: agregada dev dep `fake_cloud_firestore: ^4.0.0` (in-memory, sin emulator process aparte).

- `a4ab509` — 16 tests TS (jornadas v2: `distanciaMetros` + `horaArt`) + 20 tests Dart (`categorizarIcm` + edge cases + `kTiposInfraccionIcm` drift detection). **+ fix bug horaArt 24→0**.
- `fd28d17` — 15 tests Dart de `IcmCalculator.calcularRanking` flujo completo con `fake_cloud_firestore` (casos felices, edge cases SIN_DATOS, filtros, ordenamiento, lookup).

Estado suite: **flutter test 310/310 ✓ + functions npm test 62/62 ✓**.

**Liquidación NO necesita tests nuevos**: el agente reportó "0 tests" pero la lógica de plata vive en `calculos_viaje.dart` (con ~135 expects en `calculos_viaje_test.dart`), NO en `liquidacion_service.dart` (que es solo I/O a Firestore). Audit miró el archivo equivocado.

**DEFERRED honestamente**: tests del flujo completo de `tickVigiladorJornada` + resúmenes diarios CF requieren `firebase-functions-test` SDK + mock manual de sentinels (Timestamp, FieldValue.serverTimestamp) + estado mutable in-memory. Realísticamente 3-4h de setup ANTES del primer test útil. Ver memoria `project_tests_logica_negocio.md` con plan detallado.

### 14.5 Items deferred por decisión consciente

- **Race ready/destroy en bot whatsapp.js**: complejo, baja probabilidad (race window de ms), monitorear primero.
- **Match sufijo 10 dígitos para `/jornada` chofer**: decisión de negocio (riesgo bajo: alguien con +otra-cosa-mismos-10-dígitos finales podría leer datos de jornada de un chofer). El path admin ya tiene fix exact-match desde 17-may.
- **DNIs hardcoded → META/destinatarios_alertas**: TODO del propio código, esperar cambio real de persona.
- **Code-signing Windows installer**: $80/año recurrente, decisión de gasto.
- **Major bumps Flutter** (sentry 8→9, win32 5→6, fl_chart 0→1): hacer uno por sesión con test post-bump, no todos juntos.

### 14.6 Cómo retomar la próxima sesión

1. `git log --oneline -25` para ver los 20+ commits del 18-may.
2. Leer `project_split_functions_index.md` si vas a continuar el split de Cloud Functions.
3. Leer `project_tests_logica_negocio.md` si vas a sumar tests de flujos completos CF.
4. Leer `feedback_sentry_observabilidad.md` si Sentry vuelve a tener ruido raro.

---

## 15. Sesión 2026-05-19 — vigilador fix + split functions completo + tests CF

Sesión larga sobre un bug real reportado + cierre de dos pendientes
estructurales (split de `index.ts`, tests de flujo CF).

### 15.1 🐛 Bug del día: aviso falso de "12h jornada"

Oscar y César recibieron "Llegás al límite de 12 horas de jornada" sin
avisos progresivos previos. **Causa raíz**: el disparador era
`bloques_completos >= 3`, pero un "bloque" se cuenta con cualquier manejo
previo + pausa de 15+ min. Chofer con pausas frecuentes y cortas → 3
bloques con poco manejo real. Verificado con datos reales (script
`scripts/diagnosticar_jornada_chofer.js`): César tenía 3 bloques con
**7h54 manejo neto** → aviso falso.

**Fix** (`1c9e0af` + `97e9acb` + `bf18767`): avisos por MANEJO NETO
acumulado (`total_manejo_seg + bloque_actual_manejo_seg`):
- 11h neto → heads-up `cuota_proxima` ("ya llevás 11 horas").
- 12h neto → límite firme `cuota` ("12 horas de jornada").

Clarificación Santiago: el límite son **12h de manejo neto** (las paradas
obligatorias de 15 min suceden DENTRO de las 12h, no se restan). Nueva
flag `alerta_cuota_proxima_enviada` en el schema JORNADAS.

### 15.2 Feature: comando `/enviar-jornada <DNI>` (`25c49cb`)

El admin puede mandarle al chofer su estado de jornada (mismo texto que
`/jornada`) sin que el chofer lo pida. Útil para recordar descansos o al
discutir horas. Refactor `_construirTextoJornadaChofer` (pura) reusada.
Si el chofer está silenciado, no encola y avisa. Fix de paso: el origen
`jornada_v2_cuota_proxima` no estaba en ORIGENES_TIME_SENSITIVE.

### 15.3 Split `functions/index.ts` COMPLETADO: 6884 → 45 LOC (-99%)

Completado el split iniciado el 18-may (estaba al 50%). `index.ts` quedó
como ENTRY POINT puro (`import "./setup"` + 11 `export *`). Módulos
nuevos: `auth.ts` (1196), `audit.ts` (256), `comun.ts` (269 — helpers
compartidos: asignaciones + locks + fetch + tipos), `volvo.ts` (1655 —
proxy + alertas + scores + 2 triggers), `telemetria.ts` (310).
Commits `383939c` `8dffd96` `6076075` `e80bfae` `442450c`. Cero cambio de
comportamiento (validado tsc + suite en cada paso). Ver memoria
`project_split_functions_index.md`.

### 15.4 Tests de flujo CF — sacado de "deferred"

NO hizo falta `firebase-functions-test` + emulator. El patrón ganador:
**extraer la lógica pura del I/O** y testear la pura.
- `evaluarTickJornada` (máquina de estados del vigilador, pura) + 21
  tests — incluye REGRESIÓN del bug de César (`acb6c5a`).
- 5 builders de mensajes de resúmenes diarios (puros) + 23 tests
  (`b61375e`).

### 15.5 Otros

- **Descargas PTO** (`b647fc5`): dedup por (patente, ventana 15 min) en
  la pantalla — la PTO toggea on/off en una misma descarga física.
- **Fix mock agrupador** (`cd3e658`): el mock de `agrupador.test.js` no
  tenía orderBy/limit → 9 tests del bot estaban rojos. Bot 129/129.

### 15.6 Estado de las suites

```
flutter test:        310/310 ✓
functions npm test:  148/148 ✓  (104 → +44)
whatsapp-bot test:   129/129 ✓  (120 → +9)
```

### 15.7 Deploys pendientes (Santiago, desde su PC)

`firebase deploy --only functions` (split + fix vigilador + builders) +
verificar rules/indexes del 18-may. Bot se auto-actualiza con el push.
Ver `PENDIENTES.md`.

---

## 16. Sesión 2026-05-20 — Web institucional VAVG + acceso web a la app

Proyecto **nuevo y separado** del repo: remodelación de la web pública del
cliente (`cooper-trans.com.ar`) + se le agregó el **acceso web a la app**. Vive en
`C:\Users\Colo Logistica\web_coopertrans\` (**NO versionado en git todavía**).
Detalle completo en la memoria `project_web_institucional.md`.

### 16.1 Sitio nuevo (marca VAVG)
- El sitio viejo era Flash/PHP (InGraphica). Reemplazado por uno moderno
  (HTML/CSS/JS vanilla, paleta cobalto alineada a la app), responsive, single-page:
  hero (2 Volvo) + empresa (historia/misión/visión/valores) + flota (carga seca +
  líquidos) + ventajas + clientes + acceso al sistema + ubicación + contacto + footer.
- Marca **VAVG** (Vecchi Ariel y Vecchi Graciela SRL). Logo + fotos de flota
  extraídos del **brochure VECCHI** (PyMuPDF + PIL). Logos de clientes a color
  (YPF/Cargill/Profertil/Bunge/Holcim/Boortmalt).
- Dominio y email **se quedan en cooper-trans.com.ar** (`transporte@cooper-trans.com.ar`).
  Sin teléfonos en contacto (solo WhatsApp bot **5492914231504** + email).
- Deploy por **FTP** (credenciales SOLO en `~/Desktop/ftp_datos.txt`). Sitio viejo
  respaldado (`cooper-trans_sitio_viejo_backup_2026-05-19.zip`) y limpiado del server.

### 16.2 Acceso web a la app (`/sistema/`) — sin cambios de lógica
- La app Flutter compila a web tal cual. Único cambio fuente: branding de
  `web/index.html` (título + splash cobalto + listener `flutter-first-frame`),
  commit **`0d940c1`**.
- Login = **mismo DNI + contraseña** (callable `loginConDni` → el framework de
  callables maneja CORS solo + `signInWithCustomToken`). Verificado en vivo.
- Build: `flutter build web --release --base-href /sistema/` **desde PowerShell**
  (git-bash mangle `/sistema/` → `C:/Program Files/Git/sistema/`).

### 16.3 release_completo.ps1 ahora también sube la web (commit `d1a3af3`)
- Nuevo paso **best-effort**: compila web + sube SOLO `/sistema` por FTP. Flag
  `-SkipWeb`. Si la PC no tiene el proyecto web o las credenciales, saltea SIN
  abortar el release de Windows/Android. **Multi-PC**: solo corre donde estén
  `web_coopertrans` + `ftp_datos.txt`.

### 16.4 Pendiente
- Push de `0d940c1` + `d1a3af3` (salen solos en el próximo release, paso 6 = git push).
- Idea: versionar `web_coopertrans` en git local (anti-pérdida, bus-factor).

---

## 17. Sesión 2026-05-21 — Arco Volvo: jornada + módulo de mantenimiento

Plan "todo desde Volvo, ICM se queda en Sitrack". Detalle completo en memoria
`project_volvo_estado_fundacion.md`. Cloud Functions con auto-deploy → ya en vivo.

### 17.1 Jornada → Volvo (fix del bug de paradas no detectadas) — DEPLOYADO
El vigilador medía staleness sobre `consultado_en` (cuándo consultábamos SITRACK,
siempre fresco) → un camión PARADO cuyo último reporte de hace 30 min decía 74 km/h
se contaba como "manejando" y la parada no cerraba el bloque (AG218ZD, AF869ZU).
Fix: función PURA `decidirManejando` (jornadas_v2.ts) que gana la fuente MÁS FRESCA
— Volvo `posicion_ts` real + speed (primario) / SITRACK `report_date` (fallback).
Verificado en vivo. Suite functions 186/186. Commits `0e41465` `d015e80`.

### 17.2 Mantenimiento — parte Emmanuel + service por km + pantalla unificada
- **Parte diario a Emmanuel (#43)**: cron `resumenMantenimientoVehiculosDiario`
  08:00 ART → WhatsApp con advertencias EXACTAS (tell-tales en español, diccionario
  `volvo_telltales.ts`), declara cobertura honesta. DEPLOYADO. Commits `130453d` `8826257`.
- **Service por KM (#44) + historial de taller (#45)**: el dato vive detrás del
  login web de Volvo Connect (no en la API rFMS). Componente NUEVO `volvo_sync/`
  (Python + Playwright, patrón cachatore): login → historial de taller
  (`ecs-workshophistory` GraphQL) → escribe `ULTIMO_SERVICE_KM/FECHA` + historial
  completo en `VEHICULOS_TALLER`. El módulo de mantenimiento ya existente (intervalo
  50k) lo consume. Edición manual del service ELIMINADA (fuente única Volvo).
- **Pantalla de Mantenimiento UNIFICADA**: lista por urgencia → detalle por unidad
  con Service + Advertencias + Telemetría + Historial de taller completo (expandible
  a operaciones). Commits app `fb0f1f3` `9505e27`; backend `a4b3945` `208e563` `cfdcd19`.

### 17.3 Hallazgos que cierran ideas
- **Testigos del tablero = límite de GENERACIÓN del camión**, no de la API/acceso:
  los ~33 camiones viejos (2017-18) no transmiten "Estado actual" a NINGÚN lado
  (confirmado en la web). #43 techo real ~20/53. No es activable.
- **Peso por eje (#46): 0/53 — descartado.**

### 17.4 Pendiente operativo
- **Deploy `volvo_sync` en la PC dedicada** (Playwright + chromium + `claves.json` +
  tarea diaria `python sync_taller.py --commit`) → cierra #44/#45 al 100% automático.
  Hoy corrió 1 vez a mano. Ver PENDIENTES.md.
- **Release de la app** (read-only service + pantalla Mantenimiento unificada).
- **Avisar a Emmanuel** del WhatsApp diario (arranca mañana 8 AM).

---

## 18. Sesión 2026-05-22 (PM) — dedup Emmanuel + auditoría general + F.931 iOS + cachatore

(El mismo día, más temprano, fue el arco ICM OFICIAL de Sitrack + premios/castigos —
ver PENDIENTES.md "2026-05-22 PM (1)/(2)".) Esta sesión: 7 commits `f334604`→`46626c6`.
CF afectadas **deployadas**; los cambios de app van en el **release de hoy**.

### 18.1 Dedup del parte de mantenimiento a Emmanuel (`f334604`, CF deployada)
Emmanuel recibía 2 informes con lo mismo (luces de tablero Volvo). Se **eliminó** el
"Resumen diario — Alertas de mantenimiento" del bot (`cron_mantenimiento_diario` +
builder muerto). El **Parte** de la CF `resumenMantenimientoVehiculosDiario` ahora suma
lo único exclusivo del otro: eventos TPM/TTM/tacógrafo (24 h, con horario).
`ALERTAS_RESUMEN_DESTINATARIO_DNI` quedó obsoleta (el destinatario del Parte es el
constante `MANTENIMIENTO_VEHICULOS_DNI`). functions 196/196 → 197/197 tras la auditoría.

### 18.2 Auditoría general profunda (agentes por subsistema; hallazgos verificados a mano)
1 ALTO + 6 MEDIO arreglados (commits `d1e79ae` CF + `eb3dcb9` app), con tests:
- **[ALTO]** `report_liquidacion.slugSeguro`: `substring(0, raw.length)` sobre el slug ya
  acortado → RangeError, no salía la liquidación (ej. "Vecchi S.R.L."). +7 tests.
- **[MEDIO]** `jornadas_v2`: `bloque_excedido` no se reseteaba por bloque (aviso 4h salía
  1×/jornada). +test regresión. **(CF deployada)**
- **[MEDIO]** RBAC `app_router`: cada ruta admin pide su capability fina (antes
  `verPanelAdmin` genérica → GOMERIA/SEG_HIGIENE abrían pantallas ajenas por deep-link).
- **[MEDIO]** `mantenimiento.ts`: doble "notificaciones reanudadas" si fallaba el delete →
  flag `reanudacion_encolada`. **(CF deployada)**
- **[MEDIO]** `volvo.ts`: `_esAlertaMantenimiento` leía solo `.type` (vacío en 100% de la
  data real; el subtipo GENERIC viene en `triggerType`) → `triggerType ?? type`. **(CF deployada)**
- **[MEDIO]** `cachatore_hub._confirmar` sin try/catch → spinner infinito si fallaba
  Firestore.
- **[MEDIO]** `admin_shell`: ráfaga de avisos de revisiones viejas al abrir (consumía el
  flag con el snapshot de cache) → ignora `isFromCache`.
- **Lo sólido (verificado)**: cálculo de plata (floor5 por tramo + anti-drift), escala ICM
  oficial (menor=mejor), 0 `runTransaction` en lib/, reglas Firestore muy hardened,
  idempotencia de los 5 resúmenes CF, dispose/mounted en UI, secretos Python protegidos.
- **BAJO**: bundle de menores NO hecho (decisión de scope) — ver PENDIENTES.

### 18.3 F.931 no se veía en iOS (`9872c41` → `46626c6`)
"Cartel azul con código" = banner de pdfrx `FPDF_GetLastError=3`. Verificado: data/permiso/
URL OK (el 931 es un PDF real de **18 MB**). pdfrx `PdfViewer.uri` streamea/cachea y falla
con PDFs pesados en iOS. **Fix** en `PreviewScreen`: en móvil se descarga el PDF completo
(dio) y se renderiza in-app desde bytes (`PdfViewer.data`) con spinner de %; web sigue con
`PdfViewer.uri`; "Abrir en el navegador" queda de último recurso. **Validar en TestFlight.**

### 18.4 Cachatore (`1babce3` + `8d9d970`, deploy por auto-update de la PC dedicada)
- **Búsqueda visible** en los logs (throttle 30 s): el barrido latente muestra qué busca y
  qué ve, para que entre latidos no parezca colgado.
- **Aviso de cancelación**: al cancelar un turno, WhatsApp al chofer + al encargado de
  logística (Errazu, 25022800), igual que reservar/reagendar.

### 18.5 Bundle BAJO de la auditoría — CERRADO (commit `b747407`, CF deployada)
Bundle de hallazgos menores cerrado el mismo PM. Validado: functions 197/197 + eslint
limpio + flutter analyze + flutter test 416/416 + bot 128/128. Net **−521 líneas**.

- **CF (deployada)**: `estadoVolvoPoller` con `adquirirLockTick("estado_volvo_poller", 4min)`
  + try/finally — consistencia con los otros 5 pollers; evita doble-tick de GCP
  at-least-once.
- **App (ship en el release)**: `icm_historico_service.dart` → stub deprecado (−170 LOC
  sin usos vivos tras el pivot a `IcmOficialService`); `repartirEnCuotas` docstring honesto
  sobre la cuota 1 (lleva el resto del floor); checklist `_ItemPregunta` Stateless →
  Stateful con `TextEditingController` (el texto de observación ya no "se vacía" al alternar
  BUE↔REG/MAL).
- **Bot (auto-update PC dedicada)**: `commands._resolverChoferPorTelefono` con igualdad
  ESTRICTA canónica AR (sale el `endsWith` heredado del `_esAdmin` viejo); `historico.js`
  −15 helpers obsoletos.
- **Skipped con justificación**: SITRACK_EVENTOS limit cap (ya tiene `logger.warn`), Python
  TZ -3 (AR no DST), dedup del bot por texto (behavior change con riesgo).

### 18.6 Footgun `alertasVolvoDiario` — CERRADO (commit `1c2da83`)
La env var `ALERTAS_RESUMEN_DESTINATARIO_DNI` hace tiempo que no dispara nada (el "Parte
de mantenimiento" lo manda la CF con DNI hardcodeado), pero `health.js` seguía publicando
una regla `alertasVolvoDiario` y la card "Reglas de notificación" del admin la mostraba
como activa — cambiar la env var no reenrutaba nada.

- `health.js`: removida la regla del `reglasNotificacion`. El card pasa de 4 reglas a 3.
- `admin_estado_bot_widgets.dart`: texto de ayuda + doc comment + case de `_etiquetaTipo`
  para `alertasVolvoDiario` — todo eliminado.

### 18.7 Pendiente operativo (no es código)
- **Release de la app** (Santiago): liquidación slug, RBAC fino, cachatore wizard,
  admin_shell, F.931 in-app, checklist controller, doc cleanup. Validar el F.931 en iOS
  con VOGEL post-release.
- **(opcional, lado admin)** Re-subir el F.931 como PDF más liviano para que abra al
  instante; ya funciona pesado.

---

**Cómo retomar (sesión vieja)**: leer secciones 6.9 (cleanup + RBAC del 30-abril), 6.10 (sesión grande del 1-mayo: imports bulk + fixes UI + auditoría profunda + plan 4 fases ejecutado) y 13 (anotaciones del 30-abril noche). El estado del repo es el commit más reciente — `git log --oneline -10`.
