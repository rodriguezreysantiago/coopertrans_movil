// =============================================================================
// DEPRECADO 2026-05-22 — sin usos vivos.
//
// Este service mantenía el "histórico semanal por chofer" calculado con la
// fórmula CESVI propia del cliente. Quedó orfanado tras la migración del
// módulo ICM al pipeline OFICIAL de Sitrack: hoy las pantallas leen
// `IcmOficialService` (lib/features/icm/services/icm_oficial_service.dart)
// que consume `ICM_OFICIAL/{mes}` / `ICM_OFICIAL_SEMANAL/{lunes}` (escala
// invertida — menor = mejor).
//
// El archivo se DEJA VACÍO (con esta nota) en vez de borrarse para no
// romper algún import olvidado en una rama vieja. Si en alguna sesión
// futura confirmás que ningún branch lo importa, se puede borrar entero.
