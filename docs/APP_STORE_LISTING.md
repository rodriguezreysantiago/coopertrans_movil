# App Store Connect Listing — Coopertrans Móvil

Drafts listos para pegar en App Store Connect. Mirror de
`PLAY_STORE_LISTING.md` adaptado al formato Apple.

**Última actualización:** 2026-05-18 (release 1.0.57+60).

---

## 1. App Information

| Campo | Valor | Nota |
|---|---|---|
| **Name** | `Coopertrans Móvil` | Mismo que Play Store. Max 30 chars. |
| **Subtitle** | `Gestión de flota Vecchi` | Max 30 chars. Aparece debajo del nombre en App Store. Pensado para diferenciar sin repetir el nombre. |
| **Bundle ID** | `com.coopertrans.movil` | El del Xcode project. NO cambiar. |
| **SKU** | `COOPERTRANS-MOVIL-001` | Free-form interno Apple. Cualquier string único sirve. |
| **Primary Category** | `Business` | Mismo que Play Store. |
| **Secondary Category** | `Productivity` | Opcional. |
| **Content Rights** | `No, it does not contain, show, or access third-party content` | No usamos contenido de terceros con copyright. **Datos de APIs (Volvo, Sitrack) NO cuentan como "contenido"** — son datos comerciales operativos de Vecchi vía contratos con proveedores. Las marcas Volvo/Sitrack aparecen solo como texto (uso nominativo permitido), no como logos embebidos. |
| **Age Rating** | `4+` | Ver §5 — todas las respuestas del cuestionario son "None". |
| **Default Language** | `Spanish (Mexico)` | Apple ofrece `es-MX` o `es-ES` — no hay `es-AR` separado. Elegir MX (más cercano al rioplatense que ES). |

### Localizations adicionales
**Skip por ahora.** Toda la app está en español. Si más adelante se quiere agregar inglés/portugués, se suma como localización adicional sin tocar la default.

---

## 2. Pricing and Availability

| Campo | Valor |
|---|---|
| **Price Schedule** | Free |
| **Availability** | Argentina solamente (la empresa opera solo acá) |
| **Pre-orders** | No |
| **Volume Purchase Program** | No |

> **Nota:** si más adelante operás en Uruguay/Chile/Paraguay, podés sumar países sin re-aprobar la app — solo se actualiza la disponibilidad.

---

## 3. App Privacy

Apple es más detallista que Google. La estructura es:
1. ¿Recolectás datos? → **Sí**
2. Para cada tipo de dato: marcar **collected**, declarar **propósitos**, indicar si está **linked to user identity** y si se usa para **tracking**.
3. NO usamos tracking (no enviamos IDFA, no compartimos con redes ads).

### 3.1 Resumen de respuestas iniciales

| Pregunta | Respuesta |
|---|---|
| Does this app collect data? | **Yes** |
| Is the data linked to the user's identity? | **Yes** (la mayoría sí — login DNI vinculado) |
| Is the data used for tracking? | **No** |

### 3.2 Tipos de datos a declarar

Para cada uno: marcar **collected** + el propósito + linked + NO tracking.

#### Contact Info
| Tipo | Linked | Propósito | Notas |
|---|---|---|---|
| **Name** | Yes | App Functionality, Customer Support | Nombre del empleado, requerido para identificarlo. |
| **Email Address** | Yes | App Functionality, Customer Support | Solo si el empleado lo cargó (opcional). |
| **Phone Number** | Yes | App Functionality | Para que el bot WhatsApp le mande avisos. |
| **Other User Contact Info** | Yes | App Functionality | Apodo, fecha nacimiento — opcionales. |

#### Identifiers
| Tipo | Linked | Propósito | Notas |
|---|---|---|---|
| **User ID** | Yes | App Functionality | DNI usado como uid de Firebase Auth. |
| **Device ID** | Yes | App Functionality, Analytics | Firebase Installations ID / Crashlytics. **NO IDFA.** |

#### User Content
| Tipo | Linked | Propósito | Notas |
|---|---|---|---|
| **Photos or Videos** | Yes | App Functionality | Comprobantes de papeles renovados (licencia, ART, etc.). |
| **Other User Content** | Yes | App Functionality | Checklists mensuales, observaciones de viajes. |

#### Usage Data
| Tipo | Linked | Propósito | Notas |
|---|---|---|---|
| **Product Interaction** | Yes | App Functionality, Analytics | Auditoría de acciones admin (quién hizo qué). |

#### Diagnostics
| Tipo | Linked | Propósito | Notas |
|---|---|---|---|
| **Crash Data** | Yes | App Functionality, Analytics | Firebase Crashlytics + Sentry. |
| **Performance Data** | Yes | Analytics | Performance monitoring. |

### 3.3 Tipos que NO recolectamos (importante — no marcar)

- **Location** (Precise / Coarse): NO. La app NO accede al GPS del teléfono del empleado.
- **Health & Fitness**: NO.
- **Financial Info**: NO.
- **Sensitive Info**: NO.
- **Contacts**: NO (la app NO lee la libreta de contactos).
- **Search History**: NO.
- **Browsing History**: NO.
- **Audio**: NO.
- **Gameplay Content**: NO.
- **Purchases**: NO (la app es 100% interna, no hay compras).
- **Customer Support** (independiente): NO (los mensajes con la oficina van por WhatsApp fuera de la app).
- **Other Data Types**: NO.

### 3.4 Privacy Policy URL

```
https://coopertrans-movil.web.app/privacidad
```

(Misma URL que Play Store. Activa via Firebase Hosting.)

---

## 4. Version Information (por cada release)

### 4.1 What's New in This Version

Para la versión actual `1.0.57+60`:

```
• Mejoras de estabilidad en el módulo de viajes.
• Tooltips en acciones rápidas (limpiar búsqueda, cambiar visibilidad).
• Buscador libre en lista de viajes.
• Atajo Ctrl+S para guardar formularios (Windows desktop).
• Fixes menores en mantenimiento y gomería.
```

Para releases futuros — describir cambios visibles para el usuario, no commits internos. Si la versión es un fix de bug interno sin impacto visible, alcanza con `"Mejoras de estabilidad y correcciones menores."`

### 4.2 Promotional Text (opcional, 170 chars max)

Texto que aparece DESTACADO arriba de la descripción y se puede cambiar sin pasar por review.

```
Aplicación interna de Vecchi Transportes para gestión de flota, papeles laborales, mantenimiento preventivo y telemetría Volvo. Acceso solo con credenciales.
```
*(170 chars exactos)*

### 4.3 Description (4000 chars max)

Misma que Play Store, con ajustes mínimos por formato. Pegá esto:

```
Coopertrans Móvil es la aplicación interna de gestión de flota de Vecchi / Sucesión Vecchi, empresa de transporte con sede en Bahía Blanca, Argentina.

ATENCIÓN: Esta aplicación es de uso EXCLUSIVO para el personal autorizado de la empresa. El acceso requiere credenciales (DNI + contraseña) provistas por la administración. La app no está disponible para el público general.

¿QUÉ HACE LA APP?

PARA EL PERSONAL:
• Consulta del estado de papeles laborales (licencia, ART, preocupacional, manejo defensivo, F.931, seguro de vida, sindicato).
• Avisos automáticos por WhatsApp cuando un papel está por vencer.
• Subida de fotos o PDFs de comprobantes renovados — el administrador los aprueba desde la app.
• Para choferes: checklist mensual de la unidad asignada.

PARA LA ADMINISTRACIÓN:
• Gestión completa del personal: alta, edición, asignación de roles y áreas, control de vencimientos.
• Gestión de la flota: tractores y enganches, con sus vencimientos (RTO, seguro, extintores) y mantenimiento preventivo.
• Búsqueda global para encontrar empleados, vehículos y trámites en segundos.
• Auditoría de acciones administrativas con registro de autor, fecha y hora.
• Calendario mensual de vencimientos y panel de prioridades.
• Reportes Excel: flota, novedades de checklist, consumo de combustible, liquidación de viajes.
• Bot WhatsApp automatizado que avisa a los choferes y agrupa los mensajes para evitar spam.

INTEGRACIÓN VOLVO CONNECT:
Para tractores Volvo de la flota, la app trae en tiempo real:
• Kilometraje, combustible y autonomía.
• Alertas de seguridad (exceso de velocidad, ralentí, distancia entre vehículos).
• Eventos PTO (descargas).
• Scores de eco-driving por chofer y por flota.
• Mapa de eventos georeferenciados con heatmap.

MÓDULO GOMERÍA:
Sistema completo de gestión de cubiertas: alta unitaria o por lote, instalación, retiro, rotación, recapado, control de presión y profundidad de banda. Con alertas automáticas cuando una cubierta supera el 80% de vida útil consumida.

MÓDULO LOGÍSTICA:
Gestión de viajes con tarifas, kilometraje, gastos extraordinarios, liquidación al chofer y comprobantes de adelantos.

PRIVACIDAD Y SEGURIDAD:
• Comunicaciones cifradas con el servidor (HTTPS / TLS).
• Datos almacenados en Firebase (Google) con cifrado en reposo, en servidores de la región sa-east1 (Brasil).
• Credenciales guardadas en el almacén seguro nativo del dispositivo (iOS Keychain).
• Auditoría completa de acciones administrativas.
• Cumplimiento con la Ley argentina N.° 25.326 de Protección de los Datos Personales.

La política de privacidad completa está disponible en https://coopertrans-movil.web.app/privacidad

Soporte: santiagocoopertrans@gmail.com
```
*(~3000 chars)*

> **Nota Apple:** evita emojis al inicio de cada bullet — Apple los penaliza visualmente. Usé "•" liso en lugar de 🚛/📊/🔒 del Play Store listing.

### 4.4 Keywords (100 chars total, separados por coma SIN espacios)

```
flota,vencimientos,choferes,gomeria,volvo,sitrack,vecchi,coopertrans,transporte,bahia blanca
```
*(100 chars exactos — Apple rankea por estas palabras. NO repetir el nombre de la app, ya está indexado aparte.)*

### 4.5 Support URL

```
https://coopertrans-movil.web.app/soporte
```

(Página de soporte real creada 2026-05-29 — `public/soporte.html`, con contacto + FAQ;
responde HTTP 200. Antes se usaba `/eliminar-cuenta` como placeholder. Apple verifica
que la URL cargue, así que tiene que existir el rewrite en `firebase.json`.)

### 4.6 Marketing URL (opcional)

```
https://coopertrans-movil.web.app/
```

O dejar vacío.

### 4.7 Copyright

```
© 2026 Vecchi Transportes
```

---

## 5. Age Rating (cuestionario)

Cuando llenes "Age Rating Information", todas las respuestas son **None** o **No** según el wording, y el rating final debería dar **4+**.

### Frecuencia de contenido (None en todos)

| Categoría | Respuesta |
|---|---|
| Cartoon or Fantasy Violence | None |
| Realistic Violence | None |
| Prolonged Graphic or Sadistic Realistic Violence | None |
| Profanity or Crude Humor | None |
| Mature/Suggestive Themes | None |
| Horror/Fear Themes | None |
| Medical/Treatment Information | None |
| Alcohol, Tobacco, or Drug Use or References | None |
| Simulated Gambling | None |
| Sexual Content or Nudity | None |
| Graphic Sexual Content or Nudity | None |
| Contests | None |

### Controles dentro de la app (No en todos)

| Categoría | Respuesta | Defensa si Apple cuestiona |
|---|---|---|
| Controles parentales | No | App para empleados adultos. |
| Verificación de edad garantizada | No | Login por DNI + contraseña, no por edad. |

### Capacidades (No en todos)

| Categoría | Respuesta | Defensa si Apple cuestiona |
|---|---|---|
| Acceso web no restringido | No | Sin WebView open. `url_launcher` solo abre URLs predefinidas (privacy/delete-account), no permite al usuario navegar. |
| Contenido generado por usuarios | No | Los PDFs/fotos que sube el empleado son flujo de verificación interno (admin aprueba/rechaza). NO hay feed, perfil público, comentarios ni distribución entre usuarios. |
| Mensajería y chat | No | NO hay user-to-user messaging en la app. Las notificaciones del bot WhatsApp son sistema→usuario por canal externo, no entre usuarios. |
| Publicidad | No | Sin ads. |
| Made for Kids | No | Audiencia 18+, empleados. |

→ Resultado esperado: **4+**.

### Notes for Reviewer si rechazan por UGC o mensajería

Si Apple cuestiona "Contenido generado por usuarios":
> User-uploaded files (PDFs, images of renewed work documents) are part of an internal verification workflow. The administrator reviews each upload and approves or rejects it. The files are NOT distributed to other users, there is no feed, no public profile, no comments, no social interaction.

Si Apple cuestiona "Mensajería y chat":
> The app does NOT include any user-to-user messaging. System-generated notifications about document expirations are sent via WhatsApp (external channel), but this is one-way: from server to user. No user can send a message to another user from within the app.

---

## 6. App Review Information ⚠️ CRÍTICO

Esta sección es la que Apple usa para revisar la app. **Si el reviewer no puede loguearse, REJECTAN el binary.**

### 6.1 Sign-in required

| Campo | Valor |
|---|---|
| **Sign-in required** | **Yes** |
| **Username** | (DNI del usuario demo — ver §6.2) |
| **Password** | (contraseña del usuario demo) |

### 6.2 Crear el usuario demo para Apple

Antes de submitear, crear un empleado en EMPLEADOS con:
- DNI: `00000001` (o algún DNI free que no se cruce con un real)
- NOMBRE: `Apple Reviewer`
- ROL: `ADMIN` (para que vea todas las pantallas)
- TELEFONO: `-` (sin teléfono, así no se le mandan WhatsApp al bot)
- CONTRASEÑA: una pass simple (ej. `Apple2026Demo!`)
- ACTIVO: true

**Después de la aprobación**, podés mantenerlo o dejar de usarlo. Si lo dejás, asegurate de que sigue funcionando — Apple a veces re-revisa.

### 6.3 Contact Information

| Campo | Valor |
|---|---|
| First Name | Santiago |
| Last Name | Rodriguez Rey |
| Phone | +54 9 291 XXXX-XXXX (tu celular) |
| Email | santiagocoopertrans@gmail.com |

### 6.4 Notes for reviewer

Pegá esto — explicale el contexto a Apple para evitar rechazos:

```
This is an internal business application for Vecchi Transportes, a transport company based in Bahía Blanca, Argentina. It is not intended for public download.

LOGIN: use the demo account credentials provided above (DNI + password). The demo account has admin role so you can see all screens.

The app integrates with:
- Firebase (Authentication, Firestore, Storage, Cloud Functions)
- Volvo Connect API (vehicle telemetry, only used internally by admins for fleet visibility)
- Sitrack API (GPS tracking, only consumed server-side)

It does NOT:
- Track user location via GPS
- Use ATT (App Tracking Transparency) — no IDFA collection
- Show ads
- Allow in-app purchases
- Communicate between users (all chat is between the system and the user via WhatsApp)

The WhatsApp integration runs server-side; the app itself does not send messages to other users. It only displays the queue status of system-generated messages.

If you encounter any issue or need clarification, please contact santiagocoopertrans@gmail.com.
```

---

## 7. Screenshots (mandatorio)

Apple exige screenshots para AL MENOS un tamaño por familia de devices que soportes. Si el build target incluye iPhone y iPad, necesitás un set por cada uno.

| Device | Tamaño | Mín / Recomendado | Notas |
|---|---|---|---|
| **iPhone 6.7" (display)** | **1290×2796 px** | 3 mín, 10 max | OBLIGATORIO para iPhone. Cubre iPhone 15 Pro Max y similares. |
| **iPhone 6.5" (display)** | 1284×2778 px | opcional | Apple genera el de 6.5" automáticamente desde el de 6.7" si lo dejás vacío. |
| **iPad 13" (display)** | 2064×2752 px | OBLIGATORIO si soportás iPad | Solo si el build incluye iPad. |
| **iPad 12.9" (gen 6)** | 2048×2732 px | opcional | Idem — auto-generado. |

### Sugerencias de qué capturar (5-7 screenshots por device)

1. Login con el logo del rebrand.
2. Panel admin con tiles de módulos.
3. Lista de personal con avatares.
4. Ficha de chofer con vencimientos.
5. Lista de viajes / liquidación.
6. Mapa de eventos Volvo con heatmap.
7. Módulo gomería con esquema visual de la unidad.

**Tip:** correr el app en Xcode con simulator iPhone 15 Pro Max → Cmd+S para screenshot. Output 1290×2796 nativo.

---

## 8. App Icon

Ya está embebido en el bundle iOS (`Runner/Assets.xcassets/AppIcon.appiconset/`). Apple lo lee de ahí — **no se sube por separado** en App Store Connect (a diferencia de Play Store que sí pide el 512×512).

Verificá que el ícono de 1024×1024 esté sin transparencia (Apple lo rechaza si tiene canal alpha).

---

## 9. TestFlight Information (para External Testing)

Si vas a sumar testers externos via TestFlight, completar:

### 9.1 Beta App Description

```
App interna de gestión de flota de Vecchi Transportes. Solo personal autorizado.

Acceso con DNI + contraseña provistos por la administración.
```

### 9.2 Beta App Feedback Email

```
santiagocoopertrans@gmail.com
```

### 9.3 Marketing URL (TestFlight)

Opcional. Si querés:
```
https://coopertrans-movil.web.app/
```

### 9.4 License Agreement

**Primera opción:** ir a **App Information** → sección "License Agreement" → elegir **"Apple's Standard License Agreement"**. Eso aplica el EULA por default sin que tengas que escribir nada.

**Si Apple te obliga a llenar un EULA custom**, pegá este texto en el campo "Contrato de licencia":

```
CONTRATO DE LICENCIA DE USUARIO FINAL — COOPERTRANS MÓVIL

1. ALCANCE
Esta aplicación es propiedad exclusiva de Vecchi / Sucesión Vecchi (en adelante "la Empresa") y está destinada al uso interno de su personal autorizado. El acceso a la aplicación requiere credenciales (DNI y contraseña) provistas por la administración de la Empresa.

2. USO PERMITIDO
El usuario se compromete a utilizar la aplicación exclusivamente para fines laborales relacionados con sus funciones dentro de la Empresa. Queda prohibido:
- Compartir credenciales con terceros.
- Acceder a información de otros empleados o vehículos sin autorización.
- Usar la aplicación con fines no autorizados por la Empresa.
- Realizar ingeniería inversa, descompilar o intentar acceder al código fuente.

3. PROPIEDAD INTELECTUAL
Todo el contenido, diseño, código y datos contenidos en la aplicación son propiedad exclusiva de la Empresa o de sus licenciantes (incluidos proveedores de telemetría con contratos vigentes). Su reproducción o distribución no autorizada está prohibida.

4. DATOS PERSONALES
El tratamiento de datos personales por parte de la aplicación se rige por la política de privacidad disponible en https://coopertrans-movil.web.app/privacidad, en cumplimiento con la Ley argentina N.° 25.326 de Protección de los Datos Personales.

5. LIMITACIÓN DE RESPONSABILIDAD
La Empresa proporciona la aplicación "tal cual" y no garantiza disponibilidad ininterrumpida ni la exactitud absoluta de los datos. La Empresa no será responsable por daños derivados del uso o imposibilidad de uso de la aplicación más allá de lo establecido en el contrato laboral del usuario.

6. TERMINACIÓN
La Empresa puede revocar el acceso del usuario a la aplicación en cualquier momento, especialmente ante el cese de la relación laboral o el incumplimiento de este contrato.

7. JURISDICCIÓN
Este contrato se rige por las leyes de la República Argentina. Cualquier controversia se someterá a los tribunales ordinarios de Bahía Blanca, Provincia de Buenos Aires.

8. CONTACTO
Consultas o reclamos: santiagocoopertrans@gmail.com

Versión 1.0 — Mayo 2026.
```

### 9.5 Test Information (para reviewer de TestFlight si vas a "External Testing" con > 10 testers)

Igual que §6 (Sign-in info + Notes for reviewer). Si Apple ve que la app pide login, va a pedir credenciales aunque solo sea TestFlight.

---

## 10. Distribución

| Pregunta | Respuesta |
|---|---|
| **Release** | Manual (vos decidís cuándo se publica después de la aprobación) |
| **Phased release** | Off (la app es interna, no necesita rollout gradual al público) |
| **Countries** | Argentina |
| **Mode** | **Unlisted** (recomendado) o Public según prefieras |

> **Unlisted vs Public:**
> - Unlisted: la app NO aparece en búsquedas del App Store, solo accesible por link directo. Ideal para apps internas.
> - Public: aparece en búsquedas. Si alguien busca "coopertrans" o "flota argentina", puede caer ahí.
>
> Para una app de uso interno con login restringido, **Unlisted es lo lógico** — Apple lo aprueba más rápido porque no compite con apps públicas.

Para configurar Unlisted: después de la aprobación, abrí un ticket en "Contact Us" → "Distribution" → "Request Unlisted App Distribution".

---

## 11. Checklist final antes de submit

- [ ] Bundle ID `com.coopertrans.movil` ya registrado en App Store Connect.
- [ ] Build #11+ subido vía Xcode Cloud y visible en "TestFlight → Builds".
- [ ] Build seleccionado en "App Store → 1.0.57 Prepare for Submission".
- [ ] Privacy Policy URL responde HTTP 200 (`https://coopertrans-movil.web.app/privacidad`).
- [ ] Support URL responde HTTP 200.
- [ ] Usuario demo `00000001` creado en EMPLEADOS con rol ADMIN.
- [ ] Credenciales del demo cargadas en "App Review Information → Sign-in required".
- [ ] Notes for Reviewer pegadas con el texto de §6.4.
- [ ] Mínimo 3 screenshots iPhone 6.7" cargados.
- [ ] (Si soportás iPad) Mínimo 3 screenshots iPad 13".
- [ ] App Privacy completado con TODOS los tipos de §3.2.
- [ ] Age Rating dio 4+.
- [ ] Pricing = Free.
- [ ] Availability = Argentina.
- [ ] Copyright = `© 2026 Vecchi Transportes`.
- [ ] What's New escrito (no dejar vacío, Apple lo penaliza).
- [ ] Promotional Text opcional pero recomendado.
- [ ] Keywords no contienen palabras del nombre.

---

## 12. Tiempos esperados

| Hito | Tiempo típico |
|---|---|
| Submit → "Waiting for Review" | inmediato |
| "Waiting for Review" → "In Review" | 24-48 hs |
| "In Review" → "Approved" o "Rejected" | 2-6 hs |
| Rejection → resubmit (si necesario) | mismo día |
| Approved → "Available on App Store" | inmediato (si Manual Release: cuando vos lo apruebes) |

Total: **48-72 hs** desde el submit hasta la app live, si no hay rechazos.

### Rechazos comunes a evitar

1. **Demo account no funciona** → más frecuente. Probá vos el login con las credenciales del §6.1 ANTES de submit.
2. **App vacía / sin funcionalidad** porque el reviewer no entiende qué hacer → cubierto en Notes for Reviewer (§6.4).
3. **Privacy policy URL caída** → verificá que carga.
4. **Screenshots no muestran la app real** → no usar mockups, solo capturas reales del simulator.
5. **Icon con transparencia** → render flat sin alpha.

---

## 13. Post-aprobación

1. **Marcar la app como Unlisted** (ticket en App Store Connect, §10).
2. **Invitar a empleados clave** (admins, supervisores) via TestFlight primero para validar.
3. **Quitar el banner "Etapa de prueba"** del bot WhatsApp cuando confirmes que está estable en producción real.
4. **Versionado**: cada nuevo build sube a `1.0.X+Y` — el `Y` es el build number obligatorio único por upload (Xcode Cloud lo autoincrementa).

---

**Mantener este doc sincronizado** con cambios en el listing — si actualizás copy, screenshots o el ícono, dejar la versión en el header (§inicial del archivo).
