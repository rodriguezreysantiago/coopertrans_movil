import 'package:flutter/services.dart';

class AppFormatters {
  // ✅ MEJORA PRO: Constructor privado para evitar instanciaciones innecesarias
  AppFormatters._();

  /// RegExp para insertar separadores de miles AR (123.456.789).
  /// Compilada una sola vez — antes se reconstruía en cada llamada a
  /// `formatearKilometraje`/`formatearMiles` (hot path: cards, listas,
  /// rebuilds frecuentes en KPIs).
  static final RegExp _milesRegex = RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))');

  // --- FORMATEAR KILOMETRAJE (1.232.232,0) ---
  static String formatearKilometraje(dynamic valor) {
    if (valor == null || valor == 0 || valor == "0" || valor == "" || valor.toString().toLowerCase() == "nan") return "0,0";

    try {
      String raw = valor.toString().replaceAll(',', '.');
      double numero = double.parse(raw);

      String fixed = numero.toStringAsFixed(1).replaceAll('.', ',');

      List<String> partes = fixed.split(',');
      String entera = partes[0];
      String decimal = partes[1];

      entera = entera.replaceAllMapped(_milesRegex, (Match m) => '${m[1]}.');

      return "$entera,$decimal";
    } catch (e) {
      return "0,0";
    }
  }

  /// Formatea un número con `.` como separador de miles, formato AR:
  /// - `formatearMiles(123456789)` → `"123.456.789"` (entero, sin decimales).
  /// - `formatearMiles(123456789.5, decimales: 2)` → `"123.456.789,50"`.
  /// - `formatearMonto(45000)` → `"45.000,00"` (siempre 2 decimales, plata).
  ///
  /// Usar para km, contadores, lecturas de odómetro — cualquier entero
  /// ≥ 1000 que el operador tenga que leer rápido. Para plata, preferir
  /// `formatearMonto` que fuerza `,00` para consistencia visual.
  ///
  /// Aceptamos `num?` para que el caller no tenga que castear. Null → `"—"`.
  static String formatearMiles(num? valor, {int decimales = 0}) {
    if (valor == null) return '—';
    final negativo = valor < 0;
    final abs = valor.abs();
    final entero = abs.truncate();
    final s = entero.toString();
    final parteEntera = s.replaceAllMapped(_milesRegex, (m) => '${m[1]}.');
    String resultado;
    if (decimales > 0) {
      // toStringAsFixed redondea correctamente y siempre rellena con 0.
      final decStr = abs.toStringAsFixed(decimales).split('.').last;
      resultado = '$parteEntera,$decStr';
    } else {
      resultado = parteEntera;
    }
    return negativo ? '-$resultado' : resultado;
  }

  /// Formato AR para montos en pesos: siempre 2 decimales con `,` y
  /// miles con `.` (`123456.5 → "123.456,50"`, `45000 → "45.000,00"`).
  /// No agrega símbolo `$` — el caller lo prepende si lo necesita
  /// (algunas pantallas usan label "Costo ($)" en vez del símbolo en
  /// el valor).
  static String formatearMonto(num? valor) =>
      formatearMiles(valor, decimales: 2);

  /// `TextInputFormatter` que reformatea el input en vivo a estilo AR
  /// con `.` como separador de miles: el usuario tipea `200000` y ve
  /// `200.000`; sigue escribiendo y ve `2.000.000`. Solo acepta
  /// dígitos — todo otro caracter se descarta.
  ///
  /// Para leer el valor numérico del controller, usar
  /// `parsearMiles(controller.text)` (acepta el string formateado o
  /// uno crudo sin puntos).
  ///
  /// Limitación: no soporta decimales — pensado para enteros (km,
  /// pesos enteros). Si hace falta decimal, agregar variante separada
  /// para no complicar el cursor handling.
  static final TextInputFormatter inputMiles = _MilesInputFormatter();

  /// Parsea un string formateado con `.` (ej. "200.000") a `int`. Si
  /// el string viene sin separadores (ej. "200000") también funciona.
  /// Devuelve `null` si está vacío o no es numérico.
  static int? parsearMiles(String? texto) {
    if (texto == null) return null;
    final limpio = texto.replaceAll('.', '').trim();
    if (limpio.isEmpty) return null;
    return int.tryParse(limpio);
  }

  /// Igual que [inputMiles] pero acepta UNA coma decimal (formato AR de
  /// plata: `123.456.789,00`). Miles con `.`, decimales con `,` (hasta 2).
  /// Para montos en pesos donde hacen falta centavos (tarifas, gastos,
  /// adelantos). El valor se lee con [parsearMonto].
  static final TextInputFormatter inputMilesDecimal =
      _MilesDecimalInputFormatter();

  /// Parsea un monto AR (`"123.456,50"`) a `double`: saca los `.` de miles
  /// y convierte la `,` decimal en `.`. Acepta también enteros sin coma
  /// (`"123.456"` → `123456.0`) y crudos (`"123456,5"`). Devuelve `null` si
  /// está vacío o no es numérico. Complemento de [parsearMiles] cuando hacen
  /// falta decimales.
  static double? parsearMonto(String? texto) {
    if (texto == null) return null;
    final limpio = texto.replaceAll('.', '').replaceAll(',', '.').trim();
    if (limpio.isEmpty) return null;
    return double.tryParse(limpio);
  }

  // --- FORMATEAR DNI (XX.XXX.XXX) ---
  static String formatearDNI(dynamic dni) {
    final String s = dni?.toString().replaceAll(RegExp(r'[^0-9]'), '') ?? "";
    if (s.length < 7 || s.length > 8) return s;
    return s.length == 7 
        ? "${s.substring(0, 1)}.${s.substring(1, 4)}.${s.substring(4)}"
        : "${s.substring(0, 2)}.${s.substring(2, 5)}.${s.substring(5)}";
  }

  // --- FORMATEAR CUIL (XX-XXXXXXXX-X) ---
  static String formatearCUIL(dynamic cuil) {
    final String s = cuil?.toString().replaceAll(RegExp(r'[^0-9]'), '') ?? "";
    if (s.length != 11) return s;
    return "${s.substring(0, 2)}-${s.substring(2, 10)}-${s.substring(10)}";
  }

  // ===========================================================================
  // ✅ MEJORA PRO: HELPER PRIVADO PARA PARSEO UNIVERSAL DE FECHAS
  // ===========================================================================
  static DateTime? _parseUniversalDate(dynamic fecha) {
    if (fecha == null || fecha.toString().isEmpty || fecha == "---" || fecha.toString().toLowerCase() == "nan") {
      return null;
    }
    
    if (fecha is DateTime) return fecha;

    // Usamos tryParse en lugar de parse para no depender de excepciones
    // como flujo de control. Mismo resultado, sin throw + catch.
    try {
      final String stringFecha = fecha.toString();
      final String soloFecha = stringFecha.split('T').first.split(' ').first;
      final String f = soloFecha.replaceAll('/', '-').trim();

      final List<String> partes = f.split('-');
      if (partes.length == 3) {
        if (partes[0].length == 4) {
          // Formato YYYY-MM-DD (ISO).
          //
          // **Bug histórico fixeado**: antes hacíamos `DateTime.tryParse(f)`
          // que en Dart parsea "2026-05-30" como UTC midnight. En zonas
          // negativas (ART = UTC-3), al hacer `.toLocal()` o usar el
          // DateTime en operaciones con DateTime.now() (que es local)
          // el día se "atrasa" — la licencia que vence el 30/05 se
          // mostraba como 29/05.
          //
          // Ahora construimos DateTime local explícito con los
          // componentes manualmente, sin pasar por tryParse.
          final anio = int.tryParse(partes[0]);
          final mes = int.tryParse(partes[1]);
          final dia = int.tryParse(partes[2]);
          if (anio != null && mes != null && dia != null) {
            return DateTime(anio, mes, dia);
          }
          return null;
        }
        // Formato DD-MM-YYYY: parseamos cada componente con tryParse.
        final dia = int.tryParse(partes[0]);
        final mes = int.tryParse(partes[1]);
        final anio = int.tryParse(partes[2]);
        if (dia != null && mes != null && anio != null) {
          return DateTime(anio, mes, dia);
        }
      }
    } catch (_) {
      // Cualquier formato no contemplado → null
    }
    return null;
  }

  /// Alias publico de `_parseUniversalDate`. Util cuando el caller
  /// quiere un `DateTime?` y ya esta usando `AppFormatters` para otras
  /// cosas. Acepta multiples formatos (ISO YYYY-MM-DD, DD-MM-YYYY,
  /// DD/MM/YYYY, DateTime nativo) y devuelve null si no parsea.
  ///
  /// Preferir esto sobre `DateTime.tryParse(s)` directo cuando se
  /// parsean campos `VENCIMIENTO_*` o `ULTIMO_SERVICE_FECHA` cuyo
  /// formato historico puede variar (siempre se guarda ISO desde la
  /// app, pero migraciones viejas o ediciones manuales en console
  /// pudieron dejar DD/MM en la BD).
  static DateTime? tryParseFecha(dynamic fecha) =>
      _parseUniversalDate(fecha);

  /// Devuelve `YYYY-MM-DD` usando los componentes LOCALES del DateTime.
  ///
  /// Reemplazo seguro de los patrones:
  ///   - `dt.toString().split(' ').first` (funciona si dt es local,
  ///     pero rompe si es UTC -- te da el dia anterior en TZ ART).
  ///   - `dt.toIso8601String().split('T').first` (siempre devuelve
  ///     componentes UTC -- entre 21:00 y 23:59 ART te da el dia
  ///     siguiente).
  ///
  /// Uso tipico: convertir el DateTime que devuelve `pickFecha(...)` a
  /// string para guardarlo en Firestore en el campo VENCIMIENTO_*.
  /// Asi no importa si el DateTime es local, UTC o vino de un parse
  /// raro -- siempre se guarda el dia que el admin tipeo.
  static String aIsoFechaLocal(DateTime d) {
    final l = d.isUtc ? d.toLocal() : d;
    String two(int n) => n.toString().padLeft(2, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)}';
  }

  // --- FORMATEAR FECHA (DD/MM/YYYY) ---
  static String formatearFecha(dynamic fecha) {
    final DateTime? parsed = _parseUniversalDate(fecha);

    if (parsed != null) {
      return "${parsed.day.toString().padLeft(2, '0')}/${parsed.month.toString().padLeft(2, '0')}/${parsed.year}";
    }

    // Si no pudo parsear, devuelve lo que ingresó por defecto
    return fecha?.toString() ?? "Sin datos";
  }

  /// Formatea un DateTime como `HH:mm` (default) o `HH:mm:ss` en hora local.
  ///
  /// Útil para mostrar SOLO la hora — para fecha + hora completa usar
  /// [formatearFechaHora]. Si el DateTime es UTC, lo convierte a local
  /// antes de formatear.
  ///
  /// Reemplaza el patrón duplicado `_formatHora` que vivía privado en
  /// pantallas que solo necesitaban formatear hora rápido (ej. timeline
  /// del Sync Dashboard).
  static String formatearHora(DateTime fecha, {bool conSegundos = false}) {
    final l = fecha.isUtc ? fecha.toLocal() : fecha;
    String two(int n) => n.toString().padLeft(2, '0');
    final base = '${two(l.hour)}:${two(l.minute)}';
    return conSegundos ? '$base:${two(l.second)}' : base;
  }

  /// Formatea un DateTime como `DD/MM/YYYY HH:mm:ss` en hora local.
  ///
  /// Reemplazo seguro de `.toIso8601String()` para cualquier display que
  /// le llegue al usuario (logs en pantalla, debug snapshots, etc.). ISO
  /// expone formato técnico (`2026-05-03T23:45:32.123`) que en AR no se
  /// reconoce y obliga al usuario a calcular TZ mentalmente.
  ///
  /// Si el DateTime es UTC, lo convierte a local antes de formatear.
  /// Acepta `null` y devuelve "—" como placeholder consistente con la
  /// UI del resto de la app.
  static String formatearFechaHora(DateTime? fecha) {
    if (fecha == null) return '—';
    final l = fecha.isUtc ? fecha.toLocal() : fecha;
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(l.day)}/${two(l.month)}/${l.year} '
        '${two(l.hour)}:${two(l.minute)}:${two(l.second)}';
  }

  /// `DD/MM/YYYY HH:mm` (sin segundos) en hora local. Útil para
  /// columnas de tabla / detalles donde los segundos son ruido.
  static String formatearFechaHoraSinSegundos(DateTime? fecha) {
    if (fecha == null) return '—';
    final l = fecha.isUtc ? fecha.toLocal() : fecha;
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(l.day)}/${two(l.month)}/${l.year} '
        '${two(l.hour)}:${two(l.minute)}';
  }

  /// `DD/MM HH:mm` (sin año, sin segundos) en hora local. Para timelines,
  /// últimas sincronizaciones, eventos del día. Cuando la fecha es
  /// reciente (mismo año) el año es ruido y este formato deja más
  /// espacio horizontal para otros campos.
  static String formatearFechaHoraCorta(DateTime? fecha) {
    if (fecha == null) return '—';
    final l = fecha.isUtc ? fecha.toLocal() : fecha;
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(l.day)}/${two(l.month)} '
        '${two(l.hour)}:${two(l.minute)}';
  }

  /// `DD/MM` (sin año, sin hora) en hora local. Para chips de fecha
  /// del día corriente o histogramas por día.
  static String formatearFechaCorta(DateTime? fecha) {
    if (fecha == null) return '—';
    final l = fecha.isUtc ? fecha.toLocal() : fecha;
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(l.day)}/${two(l.month)}';
  }

  /// Formatea un DateTime a "Mes YYYY" (ej. "Mayo 2026") en español.
  /// Pensado para encabezados de períodos mensuales (pantalla
  /// LIQUIDACIÓN, reportes mensuales). Devuelve "—" si fecha es null.
  static String formatearMes(DateTime? fecha) {
    if (fecha == null) return '—';
    const meses = [
      'Enero', 'Febrero', 'Marzo', 'Abril', 'Mayo', 'Junio',
      'Julio', 'Agosto', 'Septiembre', 'Octubre', 'Noviembre', 'Diciembre',
    ];
    final l = fecha.isUtc ? fecha.toLocal() : fecha;
    return '${meses[l.month - 1]} ${l.year}';
  }

  // --- CÁLCULO DE DÍAS (PARA EL SEMÁFORO) ---
  //
  // Devuelve `null` cuando no se pudo parsear la fecha (input vacío,
  // null, "---", o string corrupto). Antes devolvía sentinel `999`
  // -- el caller lo interpretaba como "muy lejos en el futuro" y el
  // badge lo pintaba verde "OK", silenciando alarmas cuando un campo
  // VENCIMIENTO_X tenia valor invalido por typo en la consola.
  // Ahora null obliga al caller a tri-state: sin fecha / invalida / valida.
  static int? calcularDiasRestantes(dynamic fecha) {
    final DateTime? fVto = _parseUniversalDate(fecha);
    if (fVto == null) return null;

    final vtoNormalizado = DateTime(fVto.year, fVto.month, fVto.day);
    final ahora = DateTime.now();
    final hoyNormalizado = DateTime(ahora.year, ahora.month, ahora.day);
    return vtoNormalizado.difference(hoyNormalizado).inDays;
  }
}

/// Implementación interna del input formatter expuesto como
/// `AppFormatters.inputMiles`. Mantengo la clase privada al archivo —
/// el caller siempre pasa por el helper estático.
///
/// Estrategia para preservar la posición del cursor: contamos cuántos
/// dígitos había antes del cursor en el texto crudo, reformateamos, y
/// reposicionamos el cursor para que quede después del mismo número
/// de dígitos. Si no se hiciera esto, el cursor "salta" al final cada
/// vez que se inserta un punto.
class _MilesInputFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    // Solo dígitos.
    final soloDigitos = newValue.text.replaceAll(RegExp(r'\D'), '');
    if (soloDigitos.isEmpty) {
      return const TextEditingValue(text: '');
    }
    // Cuántos dígitos hay antes de la posición del cursor en el nuevo
    // texto (ignorando los puntos que quedaron a la izquierda).
    final cursorRaw = newValue.selection.baseOffset.clamp(0, newValue.text.length);
    final digitosAntesCursor = newValue.text
        .substring(0, cursorRaw)
        .replaceAll(RegExp(r'\D'), '')
        .length;

    final reg = RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))');
    final formateado = soloDigitos.replaceAllMapped(reg, (m) => '${m[1]}.');

    // Reposicionar el cursor: avanzar por `formateado` saltando puntos
    // hasta haber pasado `digitosAntesCursor` dígitos.
    var nuevoCursor = 0;
    var contador = 0;
    while (contador < digitosAntesCursor && nuevoCursor < formateado.length) {
      if (formateado[nuevoCursor] != '.') contador++;
      nuevoCursor++;
    }

    return TextEditingValue(
      text: formateado,
      selection: TextSelection.collapsed(offset: nuevoCursor),
    );
  }
}

/// Variante de [_MilesInputFormatter] que admite UNA coma decimal (formato
/// AR de plata: `123.456.789,00`). Expuesto como
/// `AppFormatters.inputMilesDecimal`. Reglas mientras se tipea:
///   - parte entera: separador de miles `.` automático;
///   - una sola `,` para los decimales; las comas extra se ignoran;
///   - máximo 2 dígitos después de la coma (los de más se cortan).
/// Mismo manejo de cursor que el entero, contando "significativos" (dígitos
/// y la coma) y saltando los puntos de miles.
class _MilesDecimalInputFormatter extends TextInputFormatter {
  static const int _maxDecimales = 2;

  static final RegExp _milesReg = RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))');

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    // El usuario NUNCA tipea los separadores de miles (los ponemos nosotros);
    // el unico que tipea es el decimal, y segun teclado/locale/numpad puede
    // venir como ',' o como '.'. La ',' siempre es decimal. La '.' es decimal
    // solo si NO hay ',' y la ULTIMA '.' viene seguida de 0-2 digitos y nada
    // mas (las de miles agrupan de a 3). En ese caso la convertimos a ',' para
    // reusar la logica de abajo. Asi anda igual tipear "1234.50" (numpad/EEUU)
    // que "1234,50" (AR).
    if (!newValue.text.contains(',')) {
      final idx = newValue.text.lastIndexOf('.');
      if (idx >= 0) {
        final cola = newValue.text.substring(idx + 1);
        final colaDigitos = cola.replaceAll(RegExp(r'\D'), '');
        if (cola == colaDigitos && colaDigitos.length <= _maxDecimales) {
          newValue = TextEditingValue(
            text: '${newValue.text.substring(0, idx)},'
                '${newValue.text.substring(idx + 1)}',
            selection: newValue.selection,
          );
        }
      }
    }

    // Solo dígitos y comas; el resto se descarta.
    final crudo = newValue.text.replaceAll(RegExp(r'[^\d,]'), '');
    if (crudo.isEmpty) {
      return const TextEditingValue(text: '');
    }
    // Separar por la PRIMERA coma. Las comas extra se juntan como decimales.
    final tieneComa = crudo.contains(',');
    String enteraDig;
    String decimalDig;
    if (tieneComa) {
      final idx = crudo.indexOf(',');
      enteraDig = crudo.substring(0, idx).replaceAll(',', '');
      decimalDig = crudo.substring(idx + 1).replaceAll(',', '');
      if (decimalDig.length > _maxDecimales) {
        decimalDig = decimalDig.substring(0, _maxDecimales);
      }
    } else {
      enteraDig = crudo;
      decimalDig = '';
    }

    final enteraFmt = enteraDig.isEmpty
        ? ''
        : enteraDig.replaceAllMapped(_milesReg, (m) => '${m[1]}.');
    final formateado = tieneComa ? '$enteraFmt,$decimalDig' : enteraFmt;

    // Cursor: contar significativos (dígitos + coma) antes del cursor en el
    // texto nuevo y reposicionar tras la misma cantidad en el formateado,
    // saltando los puntos de miles.
    final cursorRaw =
        newValue.selection.baseOffset.clamp(0, newValue.text.length);
    final sigAntes = newValue.text
        .substring(0, cursorRaw)
        .replaceAll(RegExp(r'[^\d,]'), '')
        .length;
    var nuevoCursor = 0;
    var contador = 0;
    while (contador < sigAntes && nuevoCursor < formateado.length) {
      if (formateado[nuevoCursor] != '.') contador++;
      nuevoCursor++;
    }

    return TextEditingValue(
      text: formateado,
      selection: TextSelection.collapsed(offset: nuevoCursor),
    );
  }
}
