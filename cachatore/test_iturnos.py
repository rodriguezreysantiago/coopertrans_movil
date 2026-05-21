"""Tests de las funciones PURAS de iturnos.py (sin red): franjas, comodín
'cualquier horario' y el guard de slots futuros. Lockean el feature 2026-05-20.

Correr con el venv del cachatore (trae curl_cffi/bs4 que iturnos importa):
    cachatore\\venv\\Scripts\\python.exe -m unittest discover -s cachatore -p "test_*.py"
    # o directo:
    cd cachatore; venv\\Scripts\\python.exe test_iturnos.py
"""
import unittest
from datetime import datetime
from unittest import mock

import iturnos


class TestHoraEnFranja(unittest.TestCase):
    def test_madrugada_bordes(self):
        self.assertTrue(iturnos.hora_en_franja("00:00", "madrugada"))
        self.assertTrue(iturnos.hora_en_franja("05:30", "madrugada"))
        self.assertFalse(iturnos.hora_en_franja("05:31", "madrugada"))
        self.assertFalse(iturnos.hora_en_franja("06:00", "madrugada"))

    def test_noche_bordes(self):
        self.assertTrue(iturnos.hora_en_franja("18:00", "noche"))
        self.assertTrue(iturnos.hora_en_franja("23:30", "noche"))
        self.assertFalse(iturnos.hora_en_franja("17:59", "noche"))

    def test_cualquiera_acepta_cualquier_hora(self):
        for h in ("00:00", "07:15", "12:34", "23:59"):
            self.assertTrue(iturnos.hora_en_franja(h, "cualquiera"))


class TestFranjaValida(unittest.TestCase):
    def test_las_cuatro_franjas_y_comodin(self):
        for f in ("madrugada", "manana", "tarde", "noche", "cualquiera"):
            self.assertTrue(iturnos.franja_valida(f))

    def test_invalidas(self):
        for f in ("", "tardecita", "any", None):
            self.assertFalse(iturnos.franja_valida(f))


class TestSlotEsFuturo(unittest.TestCase):
    AHORA = datetime(2026, 5, 20, 15, 0)

    def _slot(self, iso):
        return {"iso": iso}

    def test_pasado_mismo_dia(self):
        self.assertFalse(iturnos.slot_es_futuro(self._slot("2026-05-20T14:00"), self.AHORA))

    def test_futuro_mismo_dia(self):
        self.assertTrue(iturnos.slot_es_futuro(self._slot("2026-05-20T16:00"), self.AHORA))

    def test_fecha_futura(self):
        self.assertTrue(iturnos.slot_es_futuro(self._slot("2026-05-21T06:00"), self.AHORA))

    def test_fecha_pasada(self):
        self.assertFalse(iturnos.slot_es_futuro(self._slot("2026-05-19T23:00"), self.AHORA))

    def test_exactamente_ahora_no_es_futuro(self):
        # Estrictamente mayor: el slot que cae justo en `ahora` no sirve.
        self.assertFalse(iturnos.slot_es_futuro(self._slot("2026-05-20T15:00"), self.AHORA))

    def test_iso_invalido_no_descarta(self):
        # Si no parsea, preferimos intentar (no perder un slot por un parseo raro).
        self.assertTrue(iturnos.slot_es_futuro(self._slot("basura"), self.AHORA))
        self.assertTrue(iturnos.slot_es_futuro({}, self.AHORA))


class TestSlotsEnFranjaConComodin(unittest.TestCase):
    def test_cualquiera_devuelve_todos(self):
        slots = [
            {"hora": "03:00", "iso": "2026-05-20T03:00"},
            {"hora": "14:00", "iso": "2026-05-20T14:00"},
            {"hora": "21:00", "iso": "2026-05-20T21:00"},
        ]
        self.assertEqual(iturnos.slots_en_franja(slots, "cualquiera"), slots)

    def test_franja_acotada_filtra(self):
        slots = [
            {"hora": "03:00", "iso": "2026-05-20T03:00"},
            {"hora": "14:00", "iso": "2026-05-20T14:00"},
        ]
        soloTarde = iturnos.slots_en_franja(slots, "tarde")
        self.assertEqual([s["hora"] for s in soloTarde], ["14:00"])


class TestFechaIsoDeCuando(unittest.TestCase):
    def test_formato_iturnos(self):
        self.assertEqual(
            iturnos.fecha_iso_de_cuando("Viernes 22 May 2026 10:00 hs."),
            "2026-05-22")
        self.assertEqual(
            iturnos.fecha_iso_de_cuando("Jueves 21 May 2026 19:30 hs."),
            "2026-05-21")

    def test_mes_completo_y_otros(self):
        self.assertEqual(iturnos.fecha_iso_de_cuando("5 Enero 2026"), "2026-01-05")
        self.assertEqual(iturnos.fecha_iso_de_cuando("1 Dic 2025 08:00"), "2025-12-01")

    def test_no_parsea(self):
        self.assertIsNone(iturnos.fecha_iso_de_cuando(""))
        self.assertIsNone(iturnos.fecha_iso_de_cuando(None))
        self.assertIsNone(iturnos.fecha_iso_de_cuando("ayer a la tarde"))


class TestTurnoEnObjetivo(unittest.TestCase):
    CUANDO = "Viernes 22 May 2026 10:00 hs."

    def test_franja_y_fecha_ok(self):
        self.assertTrue(iturnos.turno_en_objetivo(
            "10:00", self.CUANDO, "manana", "2026-05-22"))

    def test_fecha_distinta_no_matchea(self):
        self.assertFalse(iturnos.turno_en_objetivo(
            "10:00", self.CUANDO, "manana", "2026-05-23"))

    def test_sin_fecha_objetivo_solo_franja(self):
        self.assertTrue(iturnos.turno_en_objetivo(
            "10:00", self.CUANDO, "manana", None))

    def test_franja_distinta_no_matchea(self):
        self.assertFalse(iturnos.turno_en_objetivo(
            "14:00", self.CUANDO, "manana", "2026-05-22"))

    def test_sin_hora_no_matchea(self):
        self.assertFalse(iturnos.turno_en_objetivo(
            None, self.CUANDO, "manana", None))

    def test_fecha_objetivo_pero_cuando_inparseable_es_conservador(self):
        # No se puede confirmar la fecha -> NO cancela (False).
        self.assertFalse(iturnos.turno_en_objetivo(
            "10:00", "horario raro", "manana", "2026-05-22"))


class TestParsearSlotsReagendar(unittest.TestCase):
    """El calendario de reagendar muestra la SEMANA entera. Cada slot tiene que
    traer su `fecha`/`iso` (del href /editar/{ISO}) para no reagendar al día
    equivocado. Lockea el fix 2026-05-21 (verificado en vivo con Oscar Glez)."""

    HTML = (
        '<div class="calendario">'
        '<a class="btn btn-light" href="#">Horarios</a>'
        '<a class="btn btn-outline-success" '
        'href="https://agendas.iturnos.com/c/x/a/y/reagendar/editar/2026-05-22T09:00">09:00</a>'
        '<a class="btn btn-outline-success" '
        'href="https://agendas.iturnos.com/c/x/a/y/reagendar/editar/2026-05-22T14:00">14:00</a>'
        '<a class="btn btn-outline-success" '
        'href="https://agendas.iturnos.com/c/x/a/y/reagendar/editar/2026-05-23T10:00">10:00</a>'
        '<button class="btn btn-dark">11:00</button>'
        '</div>'
    )

    def test_extrae_fecha_iso_hora(self):
        slots = iturnos.parsear_slots_reagendar(self.HTML)
        self.assertEqual(len(slots), 3)
        primero = slots[0]
        self.assertEqual(primero["hora"], "09:00")
        self.assertEqual(primero["fecha"], "2026-05-22")
        self.assertEqual(primero["iso"], "2026-05-22T09:00")
        self.assertTrue(primero["url"].endswith("/editar/2026-05-22T09:00"))

    def test_ignora_boton_horarios_y_ocupados(self):
        horas = [s["hora"] for s in iturnos.parsear_slots_reagendar(self.HTML)]
        self.assertNotIn("Horarios", horas)  # el <a href="#">
        self.assertNotIn("11:00", horas)      # el <button> ocupado

    def test_distintos_dias_traen_distinta_fecha(self):
        fechas = {s["fecha"] for s in iturnos.parsear_slots_reagendar(self.HTML)}
        self.assertEqual(fechas, {"2026-05-22", "2026-05-23"})

    def test_href_sin_iso_no_rompe(self):
        # btn-outline-success cuyo href no matchea /editar/{ISO}: fecha/iso None.
        html = '<a class="btn-outline-success" href="/algo/raro">08:00</a>'
        slots = iturnos.parsear_slots_reagendar(html)
        self.assertEqual(len(slots), 1)
        self.assertEqual(slots[0]["hora"], "08:00")
        self.assertIsNone(slots[0]["fecha"])
        self.assertIsNone(slots[0]["iso"])


class TestCancelar(unittest.TestCase):
    """cancelar(uuid): GET /misiturnos por el _token + POST a
    /misiturnos/cancelar/{uuid}; verifica con mis_turnos que el turno ya no esté.
    Lockea el flujo verificado en vivo 2026-05-21 (form #formCancelar POST)."""

    def _cli(self, html):
        cli = iturnos.IturnosClient()
        cli.s = mock.MagicMock()
        cli.s.get.return_value.text = html
        return cli

    def test_postea_con_token_y_confirma(self):
        cli = self._cli('<form id="formCancelar" method="POST">'
                        '<input name="_token" value="TOK123"></form>')
        cli.s.post.return_value.status_code = 302
        with mock.patch.object(cli, "mis_turnos", return_value=[]):
            r = cli.cancelar("UUID-1")
        self.assertTrue(r["ok"])
        url = cli.s.post.call_args.args[0]
        self.assertTrue(url.endswith("/misiturnos/cancelar/UUID-1"))
        self.assertEqual(cli.s.post.call_args.kwargs["data"]["_token"], "TOK123")

    def test_usa_meta_csrf_si_no_hay_form(self):
        cli = self._cli('<meta name="csrf-token" content="METATOK">')
        cli.s.post.return_value.status_code = 200
        with mock.patch.object(cli, "mis_turnos", return_value=[]):
            r = cli.cancelar("UUID-9")
        self.assertTrue(r["ok"])
        self.assertEqual(cli.s.post.call_args.kwargs["data"]["_token"], "METATOK")

    def test_sin_token_no_postea(self):
        cli = self._cli("<html>sin token</html>")
        r = cli.cancelar("UUID-1")
        self.assertFalse(r["ok"])
        self.assertEqual(r["motivo"], "sin_token")
        cli.s.post.assert_not_called()

    def test_si_el_turno_sigue_es_fallo(self):
        cli = self._cli('<meta name="csrf-token" content="M">')
        cli.s.post.return_value.status_code = 200
        with mock.patch.object(cli, "mis_turnos", return_value=[{"uuid": "UUID-1"}]):
            r = cli.cancelar("UUID-1")
        self.assertFalse(r["ok"])   # sigue apareciendo → no se canceló
        self.assertTrue(r["sigue"])


if __name__ == "__main__":
    unittest.main()
