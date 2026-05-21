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


if __name__ == "__main__":
    unittest.main()
