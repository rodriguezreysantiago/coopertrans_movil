# Política de Privacidad — Coopertrans Móvil

**Última actualización:** 2026-06-12

## 1. Quién es el responsable del tratamiento de tus datos

Esta aplicación ("Coopertrans Móvil") es una herramienta interna de gestión de flota desarrollada para uso exclusivo del personal de **Vecchi / Sucesión Vecchi**, empresa de transporte con domicilio en Bahía Blanca, Provincia de Buenos Aires, Argentina.

El tratamiento de datos personales realizado por la aplicación se rige por la **Ley argentina N.º 25.326 de Protección de los Datos Personales** y normativa concordante.

**Contacto para consultas relativas a esta política:**
- Email: santiagocoopertrans@gmail.com

## 2. Quiénes pueden usar esta aplicación

La aplicación está dirigida exclusivamente a empleados, contratistas y personal autorizado de Vecchi mayores de 18 años. **No es una aplicación de uso público.** El acceso requiere credenciales (DNI + contraseña) provistas por la administración de la empresa.

## 3. Qué datos personales recolectamos

### 3.1 Datos provistos por la administración de Vecchi al alta del empleado

- **DNI** (utilizado como identificador único y como usuario de inicio de sesión).
- **Nombre y apellido completos.**
- **Apodo** (opcional, para personalización de mensajes).
- **Teléfono móvil** (para envío automatizado de avisos por WhatsApp).
- **Correo electrónico** (opcional).
- **Fecha de nacimiento** (opcional).
- **Rol y área de trabajo** dentro de la empresa.

### 3.2 Documentos vencibles asociados al empleado

Fechas de vencimiento y comprobantes (foto o PDF) de:

- Licencia de conducir.
- Examen preocupacional / psicofísico.
- ART (Aseguradora de Riesgos del Trabajo).
- Curso de manejo defensivo.
- Formulario F.931 (AFIP).
- Seguro de vida.
- Sindicato.

Los comprobantes son cargados por el propio empleado o por la administración a través de la aplicación.

### 3.3 Datos asociados al vehículo asignado al empleado (si aplica)

Para empleados con rol de chofer:

- Patente del vehículo asignado y del enganche/acoplado.
- Historial de asignaciones chofer ↔ vehículo.
- Checklists mensuales completados por el chofer.

### 3.4 Datos de telemetría de los vehículos Volvo de la flota

La aplicación se integra con la API oficial de **Volvo Connect** y recibe, por cada tractor Volvo de la empresa:

- Kilometraje (odómetro).
- Nivel y consumo de combustible.
- Alertas de seguridad y conducción (exceso de velocidad, idling, distancia entre vehículos, eventos PTO, etc.).
- Coordenadas GPS asociadas a cada evento de alerta (esta integración en particular no rastrea en forma continua: envía solo el punto donde se generó cada alerta — el rastreo satelital continuo de la flota se describe en la sección 3.5).
- Scores de eco-driving agregados por vehículo y por flota.

**Estos datos provienen del vehículo, no del teléfono personal del empleado.**

### 3.5 Rastreo satelital de la flota (Sitrack)

Los vehículos de la flota tienen instalado un equipo de rastreo satelital provisto por **Sitrack**. A través de su API oficial, la aplicación recibe y almacena:

- **Posición GPS de cada vehículo, actualizada aproximadamente cada 5 minutos.** Se conserva la última posición conocida de cada unidad para el mapa de flota en vivo.
- **Eventos del vehículo** con fecha, hora y coordenadas: encendido/apagado, movimiento y detención, velocidad, identificación del conductor por llave electrónica (iButton) y entradas/salidas de zonas operativas (por ejemplo, plantas de carga y descarga). Estos eventos se conservan por **90 días** y luego se eliminan automáticamente.

**El rastreo es del vehículo (equipo satelital instalado en la unidad), no del teléfono del empleado.** Se utiliza para la operación de la flota: ubicación de unidades, gestión de cargas y descargas, seguridad vial y los fines descriptos en las secciones 3.6 y 3.7.

### 3.6 Registro de jornada de manejo

A partir de los datos del rastreo satelital, el sistema reconstruye la **jornada de manejo** de cada chofer: horas de conducción, pausas y descansos, kilómetros recorridos y velocidades registradas. Esta información se utiliza para promover el cumplimiento de los descansos, la seguridad vial y la gestión operativa. El propio chofer puede consultar su jornada en la aplicación, y puede reportar discrepancias si considera que un registro no refleja lo que ocurrió. Los registros de jornada se conservan como documentación laboral.

### 3.7 Identificación del conductor (llave iButton)

Cada conductor se identifica en el vehículo mediante una llave electrónica personal (iButton). El sistema guarda el **historial de qué conductor condujo qué unidad y en qué períodos**, para la correcta atribución de la conducción (por ejemplo, ante infracciones de tránsito, incidentes o evaluaciones de manejo).

### 3.8 Asistente automático de WhatsApp (con inteligencia artificial)

La empresa ofrece un número de WhatsApp atendido por un asistente automático. Si le escribís:

- Tu consulta y la respuesta generada se procesan mediante **Google Gemini** (servicio de inteligencia artificial de Google).
- Se guarda un registro de la conversación (tu DNI, teléfono, la consulta y la respuesta) por **60 días**, con fines de auditoría y mejora del servicio; luego se elimina automáticamente.
- Los avisos automáticos que el sistema te envía por WhatsApp (vencimientos, jornada, turnos, etc.) también quedan registrados temporalmente (**30 días**) para evitar duplicados y verificar entregas.

### 3.9 Datos generados por el uso de la aplicación

- **Auditoría de acciones administrativas:** registro de qué administrador editó qué dato y cuándo (DNI del admin, acción, entidad, fecha y hora).
- **Reportes de errores y rendimiento:** la aplicación utiliza Firebase Crashlytics y Sentry para identificar errores técnicos. Estos reportes pueden incluir información del dispositivo (modelo, sistema operativo, versión de la app) pero no contenido personal.

## 4. Para qué usamos tus datos

| Finalidad | Datos utilizados |
|---|---|
| Autenticación y control de acceso | DNI, contraseña, rol |
| Mostrarte tu información personal y la de tus papeles | Datos personales, vencimientos, comprobantes |
| Avisarte cuando un papel está por vencer | Teléfono (vía WhatsApp), nombre, apodo |
| Gestión de flota (admin) | Todos los datos del personal |
| Asociar eventos de telemetría con el chofer al volante en ese momento | DNI del chofer + historial de asignaciones e iButton |
| Ubicar la flota en tiempo real y gestionar la operación (cargas, descargas, turnos) | Posiciones y eventos GPS del vehículo |
| Reconstruir jornadas de manejo y promover descansos y seguridad vial | Eventos GPS del vehículo + identificación iButton |
| Evaluar la conducta de manejo (índices y scores de conducción) | Eventos GPS + telemetría Volvo + identificación del conductor |
| Responder tus consultas por WhatsApp | Conversación con el asistente (procesada con IA) |
| Generar reportes operativos (consumo, kilometraje, scores) | Telemetría Volvo + asignaciones |
| Mejorar la calidad técnica de la app | Reportes de errores anonimizados |

**No utilizamos los datos para publicidad, perfilado externo a la empresa, ni los vendemos a terceros.**

## 5. Con quién se comparten tus datos

Los datos se almacenan y procesan a través de los siguientes proveedores de servicios, que actúan como **encargados del tratamiento** bajo instrucción de Vecchi:

| Proveedor | Servicio | Datos involucrados |
|---|---|---|
| **Google Firebase** (Google LLC) | Base de datos (Firestore), almacenamiento de archivos (Storage), autenticación, funciones serverless, reportes de errores (Crashlytics) | Todos los datos personales y operativos |
| **Sentry** (Functional Software, Inc.) | Reportes de errores adicionales | Información técnica del dispositivo y stack traces |
| **Volvo Group Connected Solutions** | API oficial de telemetría de tractores | Datos de los vehículos Volvo (no datos personales del empleado) |
| **Sitrack** | Plataforma de rastreo satelital de la flota | Posiciones, eventos GPS e identificación por iButton de los vehículos |
| **Google Gemini** (Google LLC) | Procesamiento de las consultas al asistente de WhatsApp | Texto de tu consulta y la respuesta generada |
| **WhatsApp** (Meta Platforms, Inc.) | Canal de envío de avisos automáticos y del asistente | Número de teléfono y contenido del mensaje |
| **OpenStreetMap** | Imágenes de los mapas que se muestran en la app | Ninguno personal — solo la zona del mapa visualizada |

Los servidores de Firebase utilizados están alojados en la región **southamerica-east1 (San Pablo, Brasil)**.

**No compartimos datos con anunciantes, brokers de datos ni redes sociales.**

## 6. Por cuánto tiempo guardamos los datos

- Mientras el empleado mantiene relación laboral activa con Vecchi, sus datos se conservan para el funcionamiento operativo de la empresa.
- Si el empleado deja la empresa, los datos pueden conservarse por un plazo razonable adicional para cumplir obligaciones laborales, contables y fiscales (típicamente hasta diez años, según la normativa argentina aplicable).
- **Plazos automáticos de eliminación** de los datos operativos de mayor volumen:
  - Eventos GPS del vehículo (Sitrack): **90 días**.
  - Alertas de telemetría Volvo: **12 meses**.
  - Snapshots diarios de odómetro y combustible: **18 meses**.
  - Conversaciones con el asistente de WhatsApp: **60 días**.
  - Registro de mensajes de WhatsApp enviados: **30 días**.
- Los registros de jornada de manejo y los reportes operativos consolidados se conservan como documentación laboral y de gestión.
- Backups automáticos se conservan por **30 días** y se borran automáticamente.

## 7. Tus derechos

De acuerdo con la Ley N.º 25.326, tenés derecho a:

- **Acceso:** conocer qué datos personales tenemos sobre vos.
- **Rectificación:** corregir datos inexactos o desactualizados.
- **Actualización:** actualizar datos con tu consentimiento.
- **Supresión:** solicitar la baja de datos cuando ya no resulten necesarios o pertinentes.
- **Oposición:** oponerte al tratamiento por motivos fundados, salvo que el tratamiento sea necesario para el cumplimiento de obligaciones laborales o legales.

Para ejercer estos derechos, escribinos a **santiagocoopertrans@gmail.com** indicando tu nombre completo y DNI. Te responderemos en un plazo máximo de **10 días corridos**.

También podés presentar reclamos ante la **Agencia de Acceso a la Información Pública (AAIP)**, autoridad de control de la Ley N.º 25.326 en Argentina.

## 8. Cómo protegemos tus datos

- **Comunicaciones cifradas:** todas las comunicaciones entre la app y los servidores se realizan sobre HTTPS / TLS.
- **Almacenamiento cifrado:** Firebase encripta los datos en reposo.
- **Almacenamiento local cifrado:** las credenciales y la sesión del usuario se guardan en el almacén seguro nativo del dispositivo (DPAPI en Windows, KeyStore en Android, Keychain en iOS).
- **Control de acceso por rol:** solo administradores autorizados pueden ver y modificar datos del personal.
- **Auditoría:** toda acción administrativa relevante queda registrada con autor, fecha y hora.
- **Backups automáticos:** los datos se respaldan periódicamente para evitar pérdida.

## 9. Permisos del dispositivo solicitados por la aplicación

| Permiso | Por qué lo pedimos |
|---|---|
| **Cámara** | Para que puedas tomar fotos de comprobantes (RTO, seguro, licencia, etc.) y subirlos a tu legajo. |
| **Galería / Almacenamiento de imágenes** | Para que puedas seleccionar comprobantes ya guardados en tu teléfono. |
| **Notificaciones** | Para alertarte cuando un papel está por vencer o cuando un trámite tuyo es aprobado/rechazado. |
| **Ubicación (opcional)** | Solo se usa si un usuario administrativo toca "Usar mi ubicación" para marcar un punto en el mapa al cargar ubicaciones de logística. No se usa para rastrear el teléfono del empleado y no corre en segundo plano. |
| **Internet** | Para sincronizar tu información con los servidores de la empresa. |

**La aplicación no accede a tus contactos, micrófono, ni a tus archivos personales fuera de los que vos elegís compartir.** La ubicación del teléfono solo se usa en la acción opcional descripta arriba — el rastreo de la flota proviene del equipo satelital instalado en el vehículo, no de tu teléfono.

## 10. Datos de menores de edad

La aplicación no está dirigida ni se utiliza con menores de 18 años. No recolectamos información de menores de manera intencional.

## 11. Cambios en esta política

Podemos actualizar esta política para reflejar cambios en la aplicación o en la normativa aplicable. Cuando lo hagamos, actualizaremos la fecha de "Última actualización" al inicio del documento. Si los cambios son significativos, también notificaremos a los usuarios a través de la aplicación.

## 12. Ley aplicable y jurisdicción

Esta política se rige por la legislación de la **República Argentina**, en particular la **Ley N.º 25.326 de Protección de los Datos Personales** y su reglamentación. Para cualquier controversia se establece la competencia de los tribunales ordinarios de la ciudad de Bahía Blanca, Provincia de Buenos Aires.

---

**Vecchi / Sucesión Vecchi — Coopertrans Móvil**
Bahía Blanca, Provincia de Buenos Aires, Argentina
