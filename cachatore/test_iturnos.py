"""Tests de las funciones PURAS de iturnos.py (sin red): franjas, comodín
'cualquier horario' y el guard de slots futuros. Lockean el feature 2026-05-20.

Correr con el venv del cachatore (trae curl_cffi/bs4 que iturnos importa):
    cachatore\\venv\\Scripts\\python.exe -m unittest discover -s cachatore -p "test_*.py"
    # o directo:
    cd cachatore; venv\\Scripts\\python.exe test_iturnos.py
"""
import unittest
from datetime import datetime

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


if __name__ == "__main__":
    unittest.main()
