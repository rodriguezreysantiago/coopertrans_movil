# Sitrack — pasos de deploy (Fase 1: mapa flota en vivo)

Esta es la guía operativa para activar la integración de Sitrack en
producción. Solo se hace una vez.

## 1. Configurar secrets en Google Cloud Secret Manager

Las credenciales del usuario web service de Sitrack viven en Secret
Manager (no en el código, no en variables de entorno expuestas). La
Cloud Function `sitrackPosicionPoller` las lee al arrancar.

```bash
firebase functions:secrets:set SITRACK_USERNAME
# Cuando te pida el valor, pegá: ws41629VecchiSRL

firebase functions:secrets:set SITRACK_PASSWORD
# Cuando te pida el valor, pegá: Cooper01
```

Verificá que quedaron creados:

```bash
firebase functions:secrets:access SITRACK_USERNAME
firebase functions:secrets:access SITRACK_PASSWORD
```

> **Si más adelante rotás las credenciales** en el portal Sitrack,
> volvé a correr `secrets:set` con los nuevos valores y redeployá la
> función para que tome la versión nueva.

## 2. Deploy de la Cloud Function

```bash
firebase deploy --only functions:sitrackPosicionPoller
```

La función queda agendada para correr cada 5 min. Si querés forzar el
primer run sin esperar, ejecutala una vez a mano:

```bash
gcloud scheduler jobs run firebase-schedule-sitrackPosicionPoller \
  --location=us-central1
```

(El nombre exacto del job puede variar — listalos primero con
`gcloud scheduler jobs list --location=us-central1`.)

## 3. Deploy de las Firestore rules

Cambios nuevos en `firestore.rules` para la colección `SITRACK_POSICIONES`.

```bash
firebase deploy --only firestore:rules
```

> **Importante**: NO combinar con `--only firestore:rules,functions:X`
> en un solo comando — `firebase` deploya solo el primer filtro y
> silenciosamente ignora el segundo (memoria del proyecto).

## 4. Validar que está corriendo

A los 5-10 min del deploy:

```bash
# 1) Logs de la función
firebase functions:log --only sitrackPosicionPoller --lines 30
# Esperás ver: "[sitrackPosicionPoller] OK { recibidos: ~55, escritos: ~55, descartados: 0..N }"

# 2) Cursor de health
# En la consola de Firestore, abrir META/sitrack_posicion_cursor →
# debería tener `ultimo_exito_at` reciente.

# 3) Colección poblada
# En Firestore, abrir SITRACK_POSICIONES → debería tener ~55 docs
# (uno por patente).
```

## 5. Acceso desde la app

En el admin shell aparece un nuevo tab **"Flota"** entre "Mapa" y
"Personal". Visible para roles ADMIN, SUPERVISOR y SEG_HIGIENE
(misma capability que tableros Volvo).

## Costos esperados

- **1 invocación cada 5 min** = 288 runs/día = ~8.640/mes.
- **~55 unidades por run** = ~15.800 lecturas a Sitrack/día.
- **~55 writes a Firestore por run** (con merge) = ~15.800 writes/día.
- Plan Sitrack: el endpoint `/v2/report` no tiene cuota explícita
  documentada. Si el día de mañana se complican, se baja la frecuencia
  a cada 10 min sin perder valor (la flota no se mueve tanto).

## Próximos pasos

- **Fase 2**: hooks en `AsignacionVehiculoService` y gomería para
  snapshot de odómetro.
- **Fase 3**: cross-check chofer↔vehículo (DNI Sitrack vs
  AsignacionVehiculo activa) + pantalla de drift.
- **Fase 4** (opcional): activar `/files/reports` por mail a Sitrack
  (ver `docs/EMAIL_SITRACK_API.md`).
