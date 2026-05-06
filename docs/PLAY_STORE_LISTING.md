# Play Store Listing — Coopertrans Móvil

Drafts listos para pegar en Google Play Console cuando crees la app.

---

## 1. Datos básicos

| Campo | Valor |
|---|---|
| **App name** | `Coopertrans Móvil` |
| **Default language** | Español (es-AR) |
| **Tipo de app** | App (no Game) |
| **Es gratis o de pago** | Free |
| **Categoría sugerida** | Business |
| **Tags secundarios** | Productividad, Empresa |

## 2. Descripción corta (80 caracteres máx)

```
Gestión de flota y documentos para personal de Vecchi/Coopertrans Móvil
```
*(70 caracteres)*

### Alternativas

```
App interna de Vecchi para gestionar flota, papeles y vencimientos
```
*(67 caracteres)*

```
Gestión interna de flota, choferes y vencimientos de Vecchi/Coopertrans
```
*(72 caracteres)*

## 3. Descripción larga (4000 caracteres máx)

```
Coopertrans Móvil es la aplicación interna de gestión de flota de Vecchi / Sucesión Vecchi, empresa de transporte con sede en Bahía Blanca, Argentina.

⚠️ Esta aplicación es de uso EXCLUSIVO para el personal autorizado de la empresa. El acceso requiere credenciales (DNI + contraseña) provistas por la administración. La app no está disponible para el público general.

🚛 ¿Qué hace la app?

PARA EL PERSONAL:
• Consultá el estado de tus papeles laborales (licencia, ART, preocupacional, manejo defensivo, F.931, seguro de vida, sindicato).
• Recibí avisos automáticos por WhatsApp cuando un papel está por vencer.
• Subí fotos o PDFs de tus comprobantes renovados — el administrador los aprueba desde la app.
• Si sos chofer, completá el checklist mensual de tu unidad asignada.

PARA LA ADMINISTRACIÓN:
• Gestión completa del personal: alta, edición, asignación de roles y áreas, control de vencimientos.
• Gestión de la flota: tractores y enganches, con sus vencimientos (RTO, seguro, extintores) y mantenimiento preventivo.
• Búsqueda global Ctrl+K para encontrar empleados, vehículos y trámites en segundos.
• Auditoría de acciones administrativas con registro de autor, fecha y hora.
• Calendario mensual de vencimientos y panel de prioridades.
• Reportes Excel: flota, novedades de checklist, consumo de combustible.
• Bot WhatsApp automatizado que avisa a los choferes y agrupa los mensajes para evitar spam.

🚙 INTEGRACIÓN VOLVO CONNECT:
Para tractores Volvo de la flota, la app trae en tiempo real:
• Kilometraje, combustible y autonomía.
• Alertas de seguridad (exceso de velocidad, ralentí, distancia entre vehículos).
• Eventos PTO (descargas).
• Scores de eco-driving por chofer y por flota.
• Mapa de eventos georeferenciados con heatmap.

📊 MÓDULO GOMERÍA:
Sistema completo de gestión de cubiertas: alta unitaria o por lote, instalación, retiro, rotación, recapado, control de presión y profundidad de banda. Con alertas automáticas cuando una cubierta supera el 80% de vida útil consumida.

🔒 PRIVACIDAD Y SEGURIDAD:
• Comunicaciones cifradas con el servidor (HTTPS / TLS).
• Datos almacenados en Firebase (Google) con cifrado en reposo, en servidores de la región sa-east1 (Brasil).
• Credenciales guardadas en el almacén seguro nativo del dispositivo.
• Auditoría completa de acciones administrativas.
• Cumplimiento con la Ley argentina N.º 25.326 de Protección de los Datos Personales.

📌 La política de privacidad completa está disponible en https://coopertrans-movil.web.app/privacidad

Versión actual: 1.0.0+7
Plataformas: Android, iOS y escritorio (Windows).
Soporte: santiagocoopertrans@gmail.com
```
*(~2700 caracteres aprox)*

## 4. Data Safety form (cuestionario de Play Console)

Cuando Play Console te pregunte "¿Tu app recolecta o comparte datos personales?", respondé **Sí** y completá lo siguiente:

### 4.1 Preguntas de overview

| Pregunta | Respuesta |
|---|---|
| ¿La app recolecta o comparte tipos de datos personales? | **Sí** |
| ¿Todos los datos recolectados están cifrados en tránsito? | **Sí** |
| ¿Los usuarios pueden pedir que sus datos sean borrados? | **Sí** (vía solicitud por email a santiagocoopertrans@gmail.com) |

### 4.2 Tipos de datos que se recolectan

Marcar **collected** y desmarcar **shared** en todos (Firebase es procesador, no controlador independiente). Para cada uno declarar el propósito:

#### Personal Info
| Tipo | Propósito | Recolección |
|---|---|---|
| **Name** | Account management, App functionality, Communications | Required |
| **Email address** | Account management, Communications | Optional |
| **User IDs** (DNI usado como ID interno) | Account management, App functionality | Required |
| **Phone number** | Communications (avisos WhatsApp) | Required |
| **Other info** (fecha nacimiento, apodo) | Personalization, App functionality | Optional |

#### Photos and videos
| Tipo | Propósito | Recolección |
|---|---|---|
| **Photos** (comprobantes de papeles renovados) | App functionality | Optional (depende del flujo) |

#### Files and docs
| Tipo | Propósito | Recolección |
|---|---|---|
| **Files and docs** (PDFs de comprobantes) | App functionality | Optional |

#### App activity
| Tipo | Propósito | Recolección |
|---|---|---|
| **App interactions** (auditoría de acciones admin) | Analytics, App functionality | Required |
| **Other user-generated content** (checklists mensuales) | App functionality | Optional |

#### App info and performance
| Tipo | Propósito | Recolección |
|---|---|---|
| **Crash logs** (Crashlytics + Sentry) | Analytics, App functionality | Required |
| **Diagnostics** (performance) | Analytics | Required |

#### Device or other IDs
| Tipo | Propósito | Recolección |
|---|---|---|
| **Device or other IDs** (Firebase Installations / Crashlytics device ID) | Analytics, App functionality | Required |

### 4.3 Datos que NO se recolectan (importante declarar)

NO marcar:
- Location (precise / approximate) — la app NO accede a la ubicación del teléfono del empleado.
- Audio, Music, Voice recordings.
- Health and fitness.
- Financial info.
- Contacts.
- Calendar events.
- SMS / Call logs.
- Web browsing history.
- Installed apps.

### 4.4 Política de retención y eliminación

- Encriptación en tránsito: ✅ Sí (HTTPS/TLS).
- Los usuarios pueden solicitar la eliminación: ✅ Sí.
- Mecanismo de solicitud: email a santiagocoopertrans@gmail.com (URL a incluir en el form: `https://coopertrans-movil.web.app/privacidad#7-tus-derechos`).

## 5. Content Rating (cuestionario IARC)

Cuando llenes el cuestionario, todas las respuestas son **No**:
- ¿Hay violencia? No
- ¿Hay contenido sexual? No
- ¿Hay lenguaje ofensivo? No
- ¿Hay sustancias controladas? No
- ¿Apuestas o juegos de azar? No
- ¿Compras con dinero real? No
- ¿Comparte ubicación con otros usuarios? No
- ¿Permite comunicación entre usuarios? No (los avisos del bot van solo del sistema al chofer, no entre usuarios)
- ¿La app es solo para audiencia digital? No

→ Resultado esperado: **Everyone (Para todo público)** o equivalente local.

## 6. Target audience and content

| Pregunta | Respuesta |
|---|---|
| ¿La app está dirigida a niños? | **No** |
| Rango de edad objetivo | 18+ (todos los usuarios son empleados adultos) |

## 7. Ads

| Pregunta | Respuesta |
|---|---|
| ¿La app contiene anuncios? | **No** |

## 8. Distribución (Closed Testing)

| Pregunta | Respuesta |
|---|---|
| ¿Países? | Argentina (suficiente — la empresa solo opera en AR) |
| ¿Track? | Closed Testing |
| ¿Cómo se gestiona la lista de testers? | Por email — vamos a sumar los empleados manualmente |

## 9. Materiales gráficos requeridos (vos los preparás)

| Tipo | Tamaño | Formato | Notas |
|---|---|---|---|
| **Icon** | 512×512 px | PNG (32-bit, sin transparencia en bordes) | Reutilizar el logo CoopertransLogo del rebrand. |
| **Feature graphic** | 1024×500 px | PNG o JPG | Banner que aparece arriba de la ficha. Texto opcional, evitar texto chico. |
| **Screenshots Android phone** | min 320 px en lado corto, max 3840 px | PNG o JPG | 2 a 8 capturas. Idealmente: pantalla de login, panel admin, ficha de chofer, módulo flota, alguna del bot/calendario. |
| **Screenshots Android tablet** (opcional) | similar al phone pero formato tablet | PNG o JPG | Si tenés capturas en tablet, mejor. Sino, omití. |

## 10. URL de política de privacidad

```
https://coopertrans-movil.web.app/privacidad
```

(Esta URL queda activa cuando deployes Firebase Hosting con `firebase deploy --only hosting`.)
