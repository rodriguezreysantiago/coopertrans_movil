"""Tests de ciclo_latente: el bloque de REAGENDAR (y su auto-cancel) tiene que
correr AUNQUE la agenda no tenga slots libres.

Lockea el fix 2026-05-21: había un `return` temprano por "sin libres" que se
comía el reagendar/auto-cancel cuando la agenda estaba sin huecos (lo normal
fuera del drop). Síntoma real: VILLARREAL quedaba "buscando reagendar" para
siempre aunque su turno YA estuviera en la franja+fecha pedida.

Correr con el venv del cachatore (trae curl_cffi/bs4 que iturnos importa):
    cachatore\\venv\\Scripts\\python.exe -m unittest test_vigia
"""
import unittest
from datetime import datetime, timedelta
from unittest import mock

import vigia

# Agenda SIN turnos libres (el caso normal fuera del drop de las 10:30).
_AGENDA_VACIA = "<html><body>No hay turnos disponibles</body></html>"


def _target_reagendar(fecha, franja, turno_hora, turno_cuando):
    ch = {"dni": "123", "nombre": "VILLARREAL CRISTIAN IVAN",
          "email": "x@y.com", "clave": "k", "patente": "AB123CD"}
    t = vigia.Target(ch, fecha=fecha, franja=franja, reagendar=True)
    t.tiene_turno = True
    t.uuid = "uuid-1"
    t.reagendar_hecho = False
    t.turno_hora = turno_hora
    t.turno_cuando = turno_cuando
    return t


def _target_pendiente(dni, nombre, fecha, franja, tiene_turno=False):
    ch = {"dni": dni, "nombre": nombre, "email": f"{dni}@y.com",
          "clave": "k", "patente": "AB123CD"}
    t = vigia.Target(ch, fecha=fecha, franja=franja, reagendar=False)
    t.tiene_turno = tiene_turno
    return t


class TestCicloLatenteReagendarSinLibres(unittest.TestCase):
    def setUp(self):
        # cli falso: la agenda existe pero no tiene huecos libres.
        self.cli = mock.MagicMock()
        self.cli.abrir_agenda.return_value = _AGENDA_VACIA
        for p in (
            mock.patch.object(vigia, "ensure_scanner", return_value=self.cli),
            mock.patch.object(vigia, "log"),                # sin I/O de logs
            mock.patch.object(vigia, "_ESCRIBIR_ESTADO", True),
        ):
            p.start()
            self.addCleanup(p.stop)
        self.m_nube = mock.patch.object(vigia, "nube").start()
        self.addCleanup(mock.patch.stopall)

    def test_turno_ya_en_objetivo_cancela_reagendar_aunque_no_haya_libres(self):
        # Turno "Viernes 22 May 2026 10:00" YA cae en manana (06:00-11:30) + 22-05.
        t = _target_reagendar("2026-05-22", "manana", "10:00",
                              "Viernes 22 May 2026 10:00 hs.")
        vigia.ciclo_latente({t.dni: t}, dry=False)
        # Auto-cancel: apaga el flag en RAM y lo persiste (la UI vuelve a verde).
        self.m_nube.cancelar_reagendar.assert_called_once_with("123")
        self.assertFalse(t.reagendar)
        self.assertTrue(t.reagendar_hecho)

    def test_turno_fuera_de_franja_no_cancela(self):
        # Turno 21:30 (noche) con objetivo manana -> NO cancelar (sigue buscando).
        t = _target_reagendar("2026-05-22", "manana", "21:30",
                              "Viernes 22 May 2026 21:30 hs.")
        # Que no intente el reagendar real por red: login "falla" -> continue.
        with mock.patch.object(vigia, "asegurar_login", return_value=False):
            vigia.ciclo_latente({t.dni: t}, dry=False)
        self.m_nube.cancelar_reagendar.assert_not_called()
        self.assertTrue(t.reagendar)
        self.assertFalse(t.reagendar_hecho)

    def test_reserva_a_pendiente_cuando_el_scanner_ve_un_hueco(self):
        # El scanner ve un hueco de madrugada A FUTURO; VOGEL (madrugada) lo
        # toma (dry). Fecha RELATIVA (mañana 05:00) para que slot_es_futuro no
        # lo descarte según la hora a la que corra el test — antes hardcodeaba
        # 2026-05-22T02:00, un time-bomb que fallaba pasado ese instante.
        manana = (datetime.now() + timedelta(days=1)).strftime("%Y-%m-%d")
        iso = f"{manana}T05:00"
        self.cli.abrir_agenda.return_value = (
            '<a class="btn btn-outline-success" href="https://agendas.iturnos.com'
            f'/c/x/a/y/reservar/{iso}">05:00</a>')
        t = _target_pendiente("999", "VOGEL", manana, "madrugada")
        with mock.patch.object(vigia, "asegurar_login", return_value=True):
            vigia.ciclo_latente({t.dni: t}, dry=True)
        # en dry, intentar_reservar marca tiene_turno=True (no postea de verdad).
        self.assertTrue(t.tiene_turno)


class TestEnsureScannerEligePendiente(unittest.TestCase):
    """El scanner DEBE loguearse como un chofer SIN turno (iTurnos muestra
    disponibilidad por usuario). Lockea el fix 2026-05-21."""

    def setUp(self):
        mock.patch.object(vigia, "log").start()
        self.addCleanup(mock.patch.stopall)
        vigia._scanner.update(cli=None, logueado=False, dni=None)
        self.addCleanup(vigia._scanner.update, cli=None, logueado=False, dni=None)

    def test_elige_un_chofer_sin_turno_no_el_primero(self):
        con = _target_pendiente("111", "CON", None, "cualquiera", tiene_turno=True)
        sin = _target_pendiente("222", "SIN", None, "cualquiera", tiene_turno=False)
        fake = mock.MagicMock(); fake.login.return_value = True
        with mock.patch.object(vigia.iturnos, "IturnosClient", return_value=fake):
            cli = vigia.ensure_scanner({"111": con, "222": sin})  # 111 va primero
        self.assertIs(cli, fake)
        fake.login.assert_called_once_with("222@y.com", "k")   # logueó al SIN turno
        self.assertEqual(vigia._scanner["dni"], "222")

    def test_sin_pendientes_devuelve_None_y_no_loguea(self):
        con = _target_pendiente("111", "CON", None, "cualquiera", tiene_turno=True)
        with mock.patch.object(vigia.iturnos, "IturnosClient") as Mk:
            cli = vigia.ensure_scanner({"111": con})
        self.assertIsNone(cli)
        Mk.assert_not_called()
        self.assertIsNone(vigia._scanner["dni"])

    def test_re_loguea_si_el_scanner_cacheado_saco_turno(self):
        # El scanner cacheado era 222; ahora 222 tiene turno → re-elige a 333.
        vigia._scanner.update(cli=mock.MagicMock(), logueado=True, dni="222")
        con = _target_pendiente("222", "EX", None, "cualquiera", tiene_turno=True)
        sin = _target_pendiente("333", "NUEVO", None, "cualquiera", tiene_turno=False)
        fake = mock.MagicMock(); fake.login.return_value = True
        with mock.patch.object(vigia.iturnos, "IturnosClient", return_value=fake):
            vigia.ensure_scanner({"222": con, "333": sin})
        fake.login.assert_called_once_with("333@y.com", "k")
        self.assertEqual(vigia._scanner["dni"], "333")


class TestCicloLatenteBusquedaVisible(unittest.TestCase):
    """Con un chofer SIN turno y la agenda sin huecos, el ciclo tiene que
    LOGUEAR que sigue buscando — sino entre latidos (60 s) el barrido de ~5 s
    quedaba mudo y 'parecía colgado'. Lockea el fix 2026-05-22."""

    def setUp(self):
        self.cli = mock.MagicMock()
        self.cli.abrir_agenda.return_value = _AGENDA_VACIA
        self.m_log = mock.patch.object(vigia, "log").start()
        mock.patch.object(vigia, "ensure_scanner", return_value=self.cli).start()
        self.addCleanup(mock.patch.stopall)
        vigia._ultimo_log_busqueda = 0.0  # arrancar sin throttle en cada test
        self.addCleanup(setattr, vigia, "_ultimo_log_busqueda", 0.0)

    def test_loguea_busqueda_cuando_agenda_vacia(self):
        t = _target_pendiente("999", "VOGEL", None, "cualquiera")
        vigia.ciclo_latente({t.dni: t}, dry=True)
        logs = str(self.m_log.call_args_list)
        self.assertIn("buscando turno", logs)
        self.assertIn("VOGEL", logs)

    def test_no_loguea_busqueda_si_todos_tienen_turno(self):
        # Nadie sin turno -> no hay a quién buscarle -> nada de "buscando".
        t = _target_pendiente("111", "CON", None, "cualquiera", tiene_turno=True)
        vigia.ciclo_latente({t.dni: t}, dry=True)
        self.assertNotIn("buscando turno", str(self.m_log.call_args_list))

    def test_throttle_no_inunda(self):
        # Dos ciclos seguidos: el throttle deja pasar el primero y corta el 2do.
        t = _target_pendiente("999", "VOGEL", None, "cualquiera")
        vigia.ciclo_latente({t.dni: t}, dry=True)
        n1 = sum("buscando turno" in str(c) for c in self.m_log.call_args_list)
        vigia.ciclo_latente({t.dni: t}, dry=True)
        n2 = sum("buscando turno" in str(c) for c in self.m_log.call_args_list)
        self.assertEqual(n1, 1)
        self.assertEqual(n2, 1)  # el 2do ciclo NO agregó otra línea (throttled)


class TestFechaObjetivoPasada(unittest.TestCase):
    """Guard contra objetivos colgados con fecha pasada (post-mortem corte
    de luz 2026-05-28, CELIZ + VOGEL stuck en 'buscando' loop infinito).
    """

    def test_none_no_es_pasada(self):
        # null = "cualquier fecha" → nunca cerrar ciclo.
        self.assertFalse(vigia.fecha_objetivo_pasada(None))
        self.assertFalse(vigia.fecha_objetivo_pasada(""))

    def test_hoy_manana_no_son_pasadas(self):
        # Las palabras se re-resuelven cada día → nunca cerrar.
        for v in ("hoy", "HOY", "today", "manana", "mañana", "tomorrow"):
            self.assertFalse(vigia.fecha_objetivo_pasada(v),
                             f"esperaba False para {v!r}")

    def test_fecha_futura_no_es_pasada(self):
        futuro = (datetime.now() + timedelta(days=3)).strftime("%Y-%m-%d")
        self.assertFalse(vigia.fecha_objetivo_pasada(futuro))

    def test_fecha_hoy_no_es_pasada(self):
        # Hoy exacto → no cerrar (el chofer puede tener turno más tarde).
        hoy = datetime.now().strftime("%Y-%m-%d")
        self.assertFalse(vigia.fecha_objetivo_pasada(hoy))

    def test_fecha_ayer_es_pasada(self):
        ayer = (datetime.now() - timedelta(days=1)).strftime("%Y-%m-%d")
        self.assertTrue(vigia.fecha_objetivo_pasada(ayer))

    def test_fecha_vieja_es_pasada(self):
        self.assertTrue(vigia.fecha_objetivo_pasada("2020-01-01"))

    def test_string_basura_no_rompe(self):
        # Defensivo: si llega algo que no parsea como fecha (típico ej:
        # un valor mal seteado en Firestore), no romper — devolver False
        # y dejar el objetivo vivo (el admin lo limpia a mano).
        # NOTA: la comparación de strings en Python sí ordena ("blabla"
        # > "2026-..."), así que el guard de fallback igual da False
        # porque la "fecha" no es < hoy en ese orden alfabético.
        self.assertFalse(vigia.fecha_objetivo_pasada("blabla"))


class TestMensajeAgrupadoEncargado(unittest.TestCase):
    """Tests para `nube._armar_mensaje_agrupado_encargado` — la función pura
    que arma el texto que recibe Errazu cuando el drop de las 10:30 genera
    7-10 turnos al hilo. Lockea el formato.

    Importa `nube` desde el módulo `cachatore.nube`. Como `nube.py` tiene
    side effects al importar (lee claves.json), parcheamos lo mínimo."""

    @classmethod
    def setUpClass(cls):
        # Importar nube SIN disparar init de Firebase (no hay cred en CI).
        with mock.patch.object(
            __import__("firebase_admin"), "initialize_app", return_value=None):
            cls.nube = __import__("nube")

    def _item(self, nombre, dni, cuando, evento="reservado"):
        return {
            "chofer_dni": dni,
            "chofer_nombre": nombre,
            "cuando": cuando,
            "evento": evento,
        }

    def test_un_solo_aviso_va_formato_individual(self):
        # 1 item → mensaje individual (mismo que el de antes del cambio).
        msg = self.nube._armar_mensaje_agrupado_encargado([
            self._item("PEREZ JUAN", "12345678", "Viernes 22 May 2026 10:00"),
        ])
        self.assertEqual(
            msg, "Turno YPF — PEREZ JUAN (DNI 12345678): Viernes 22 May 2026 10:00.")

    def test_un_solo_aviso_reagendado(self):
        msg = self.nube._armar_mensaje_agrupado_encargado([
            self._item("PEREZ JUAN", "12345678", "Sábado 23 May 11:00", "reagendado"),
        ])
        self.assertIn("REPROGRAMADO", msg)
        self.assertIn("PEREZ JUAN", msg)

    def test_un_solo_aviso_cancelado(self):
        msg = self.nube._armar_mensaje_agrupado_encargado([
            self._item("PEREZ JUAN", "12345678", "Sábado 23 May 11:00", "cancelado"),
        ])
        self.assertIn("CANCELADO", msg)

    def test_dos_o_mas_va_agrupado_con_header(self):
        msg = self.nube._armar_mensaje_agrupado_encargado([
            self._item("PEREZ JUAN", "12345678", "Viernes 22 May 10:00"),
            self._item("LOPEZ MARIA", "23456789", "Viernes 22 May 11:30"),
            self._item("RUIZ PEDRO", "34567890", "Viernes 22 May 13:00"),
        ])
        # Header con count
        self.assertIn("Cachatore — 3 turnos procesados", msg)
        # Bloque "Nuevos (3)"
        self.assertIn("Nuevos (3)", msg)
        # Los 3 nombres
        self.assertIn("PEREZ JUAN", msg)
        self.assertIn("LOPEZ MARIA", msg)
        self.assertIn("RUIZ PEDRO", msg)

    def test_mix_de_eventos_separa_por_bloque(self):
        msg = self.nube._armar_mensaje_agrupado_encargado([
            self._item("A B", "1", "X", "reservado"),
            self._item("C D", "2", "Y", "reagendado"),
            self._item("E F", "3", "Z", "cancelado"),
        ])
        self.assertIn("Nuevos (1)", msg)
        self.assertIn("Reprogramados (1)", msg)
        self.assertIn("Cancelados (1)", msg)
        # Header total
        self.assertIn("3 turnos procesados", msg)

    def test_orden_alfabetico_por_nombre(self):
        # Aunque vengan desordenados, salen ABC dentro de cada bloque.
        msg = self.nube._armar_mensaje_agrupado_encargado([
            self._item("ZARATE M", "3", "X"),
            self._item("ALVAREZ J", "1", "Y"),
            self._item("MORALES P", "2", "Z"),
        ])
        idx_a = msg.index("ALVAREZ")
        idx_m = msg.index("MORALES")
        idx_z = msg.index("ZARATE")
        self.assertLess(idx_a, idx_m)
        self.assertLess(idx_m, idx_z)

    def test_evento_invalido_se_trata_como_reservado(self):
        # Si llega un evento desconocido, fallback a "reservado" para no
        # tirar nada al usuario.
        msg = self.nube._armar_mensaje_agrupado_encargado([
            self._item("X Y", "1", "Z", "evento_raro"),
            self._item("A B", "2", "C", "reservado"),
        ])
        self.assertIn("Nuevos (2)", msg)


class TestSemanasAEscanear(unittest.TestCase):
    """semanas_a_escanear: qué semanas de la agenda mira el scanner.

    Lockea el fix 2026-05-30: el scanner solo leía la semana actual (abrir_agenda
    sin ?d=) y NO tomaba los turnos que aparecían en la semana siguiente. Ahora
    barre la semana actual + la(s) semana(s) de las fechas pedidas."""

    # Sábado 30-may-2026 (la semana ISO es lun 25-may → dom 31-may; la siguiente
    # arranca el lun 01-jun). Fijo para que el test no dependa de la fecha real.
    HOY = datetime(2026, 5, 30).date()

    def _p(self, fecha):
        return _target_pendiente("1", "X", fecha, "manana")

    def test_sin_pendientes_solo_semana_actual(self):
        self.assertEqual(vigia.semanas_a_escanear([], hoy=self.HOY), [None])

    def test_fecha_cualquiera_suma_proximas_dos_semanas(self):
        anclas = vigia.semanas_a_escanear([self._p(None)], hoy=self.HOY)
        self.assertEqual(anclas[0], None)            # semana actual
        self.assertIn("2026-06-01", anclas)          # lunes de la semana +7
        self.assertIn("2026-06-08", anclas)          # lunes de la semana +14
        self.assertEqual(len(anclas), 3)

    def test_fecha_puntual_semana_siguiente(self):
        # 03-jun-2026 (miércoles) → su lunes es 01-jun.
        anclas = vigia.semanas_a_escanear([self._p("2026-06-03")], hoy=self.HOY)
        self.assertEqual(anclas, [None, "2026-06-01"])

    def test_fecha_de_esta_semana_no_agrega_ancla(self):
        # 30-may cae en la semana actual → solo [None] (sin ?d=).
        anclas = vigia.semanas_a_escanear([self._p("2026-05-30")], hoy=self.HOY)
        self.assertEqual(anclas, [None])

    def test_fecha_pasada_se_ignora(self):
        anclas = vigia.semanas_a_escanear([self._p("2026-05-01")], hoy=self.HOY)
        self.assertEqual(anclas, [None])

    def test_dedup_misma_semana(self):
        # Dos fechas de la misma semana (01-jun) → una sola ancla.
        ps = [self._p("2026-06-02"), self._p("2026-06-04")]
        anclas = vigia.semanas_a_escanear(ps, hoy=self.HOY)
        self.assertEqual(anclas, [None, "2026-06-01"])

    def test_cap_max_semanas(self):
        ps = [self._p("2026-06-03"), self._p("2026-06-10"), self._p("2026-06-17"),
              self._p("2026-06-24"), self._p("2026-07-01")]
        anclas = vigia.semanas_a_escanear(ps, hoy=self.HOY, max_semanas=3)
        self.assertEqual(len(anclas), 3)


if __name__ == "__main__":
    unittest.main()
