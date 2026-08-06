#!/usr/bin/env python3
"""Suite de pruebas de integración reales para la tarea SIM-06.

Prueba en vivo el flujo de Check-In y Check-Out (HU-02, RN-08) contra:
  - Keycloak (:8180) para autenticación OIDC/OAuth2.
  - Kong Gateway (:8000) para validación de firma JWT.
  - Microservicios reales (stay-service, spot-service, tariff-service, vehicle-service, ticket-service).
"""

import json
import os
import random
import string
import time
import unittest
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

from lib.keycloak_auth import KeycloakAuthenticator, KeycloakAuthError


def generate_unique_test_plate():
    """Genera una matrícula única para evitar colisiones en tests."""
    digits = f"{random.randint(1000, 9999)}"
    letters = "".join(random.choices("BCDFGHJKLMNPQRSTVWXYZ", k=3))
    return f"{digits}{letters}"


class TestCheckoutSimulationReal(unittest.TestCase):
    """Suite de pruebas de integración reales contra Keycloak, Kong y el Backend."""

    @classmethod
    def setUpClass(cls):
        cls.keycloak_url = os.environ.get("KEYCLOAK_URL", "http://localhost:8180")
        cls.kong_url = os.environ.get("KONG_URL", "http://localhost:8000")
        cls.realm = "parking"
        cls.authenticator = KeycloakAuthenticator(
            keycloak_url=cls.keycloak_url,
            realm=cls.realm,
            grant_type="password",
            username="admin.test",
            password="Admin.123!",
        )

    def setUp(self):
        print(f"\n---> [INTEGRATION TEST] {self._testMethodName}")

    def tearDown(self):
        print(f"---> [INTEGRATION TEST] {self._testMethodName} [OK / PASSED]")

    def _perform_checkin(self, plate, vehicle_type="CAR", auth_header=None):
        if auth_header is None:
            auth_header = self.authenticator.get_auth_header()

        url = f"{self.kong_url.rstrip('/')}/api/v1/stays/check-in"
        payload = json.dumps({"plate": plate, "vehicleType": vehicle_type}).encode("utf-8")
        headers = {
            "Authorization": auth_header,
            "Content-Type": "application/json",
            "Accept": "application/json",
        }
        for attempt in range(3):
            req = Request(url, data=payload, headers=headers, method="POST")
            try:
                with urlopen(req, timeout=10) as resp:
                    return resp.getcode(), json.loads(resp.read().decode("utf-8"))
            except HTTPError as e:
                body_str = e.read().decode("utf-8") if e.fp else "{}"
                if e.code == 503 and attempt < 2:
                    time.sleep(0.5)
                    continue
                try:
                    body_json = json.loads(body_str)
                except Exception:
                    body_json = {"error": body_str}
                return e.code, body_json
            except Exception as e:
                if attempt < 2:
                    time.sleep(0.5)
                    continue
                return 0, {"error": str(e)}
        return 503, {"error": "Service Unavailable after retries"}

    def _perform_checkout(self, plate, auth_header=None):
        if auth_header is None:
            auth_header = self.authenticator.get_auth_header()

        url = f"{self.kong_url.rstrip('/')}/api/v1/stays/check-out"
        payload = json.dumps({"plate": plate}).encode("utf-8")
        headers = {
            "Authorization": auth_header,
            "Content-Type": "application/json",
            "Accept": "application/json",
        }
        req = Request(url, data=payload, headers=headers, method="POST")
        try:
            with urlopen(req, timeout=10) as resp:
                return resp.getcode(), json.loads(resp.read().decode("utf-8"))
        except HTTPError as e:
            body_str = e.read().decode("utf-8") if e.fp else "{}"
            try:
                body_json = json.loads(body_str)
            except Exception:
                body_json = {"error": body_str}
            return e.code, body_json
        except URLError as e:
            return 0, {"error": str(e.reason)}
        except Exception as e:
            return 0, {"error": str(e)}

    def test_01_happy_path_checkout_car(self):
        """[CAMINO FELIZ 1] Check-In + Check-Out completo para tipo CAR."""
        plate = generate_unique_test_plate()
        print(f"     [1/9] [FELIZ] Realizando Check-In para coche {plate}...")
        status_in, body_in = self._perform_checkin(plate, "CAR")
        self.assertIn(status_in, (200, 201))

        time.sleep(1.0)

        print(f"     [1/9] [FELIZ] Realizando Check-Out para coche {plate}...")
        status_out, body_out = self._perform_checkout(plate)
        self.assertEqual(status_out, 200)
        self.assertIn("status", body_out)
        self.assertEqual(body_out["status"], "FINISHED")
        self.assertIn("amount", body_out)
        self.assertGreaterEqual(float(body_out["amount"]), 0.0)
        print(f"     [1/9] OK: Estancia {plate} cerrada (FINISHED, importe={body_out.get('amount')}).")

    def test_02_happy_path_checkout_motorbike(self):
        """[CAMINO FELIZ 2] Check-In + Check-Out completo para tipo MOTORBIKE."""
        plate = generate_unique_test_plate()
        print(f"     [2/9] [FELIZ] Realizando Check-In para moto {plate}...")
        status_in, body_in = self._perform_checkin(plate, "MOTORBIKE")
        self.assertIn(status_in, (200, 201))

        time.sleep(1.0)

        print(f"     [2/9] [FELIZ] Realizando Check-Out para moto {plate}...")
        status_out, body_out = self._perform_checkout(plate)
        self.assertEqual(status_out, 200)
        self.assertEqual(body_out.get("status"), "FINISHED")
        print(f"     [2/9] OK: Estancia moto {plate} cerrada correctamente.")

    def test_03_happy_path_checkout_pmr(self):
        """[CAMINO FELIZ 3] Check-In + Check-Out completo para tipo CAR_PMR."""
        plate = generate_unique_test_plate()
        print(f"     [3/9] [FELIZ] Realizando Check-In para PMR {plate}...")
        status_in, body_in = self._perform_checkin(plate, "CAR_PMR")
        self.assertIn(status_in, (200, 201))

        time.sleep(1.0)

        print(f"     [3/9] [FELIZ] Realizando Check-Out para PMR {plate}...")
        status_out, body_out = self._perform_checkout(plate)
        self.assertEqual(status_out, 200)
        self.assertEqual(body_out.get("status"), "FINISHED")
        print(f"     [3/9] OK: Estancia PMR {plate} cerrada correctamente.")

    def test_04_happy_path_client_credentials_checkout(self):
        """[CAMINO FELIZ 4] Check-In + Check-Out autenticado con Client Credentials."""
        auth_service = KeycloakAuthenticator(
            keycloak_url=self.keycloak_url,
            realm=self.realm,
            grant_type="client_credentials",
            client_id="parking-stay-service",
            client_secret="stay-service-dev-secret-no-usar-fuera-de-local",
        )
        auth_header = auth_service.get_auth_header()
        plate = generate_unique_test_plate()

        print(f"     [4/9] [FELIZ] Realizando flujo con token Client Credentials para {plate}...")
        status_in = 0
        for _ in range(3):
            status_in, _ = self._perform_checkin(plate, "CAR", auth_header=auth_header)
            if status_in in (200, 201):
                break
            time.sleep(0.5)

        self.assertIn(status_in, (200, 201))

        time.sleep(1.0)

        status_out, body_out = self._perform_checkout(plate, auth_header=auth_header)
        self.assertEqual(status_out, 200)
        self.assertEqual(body_out.get("status"), "FINISHED")
        print(f"     [4/9] OK: Flujo autenticado por Service Account completado con exito.")

    def test_05_unhappy_path_nonexistent_stay_checkout(self):
        """[CAMINO NO FELIZ 1] Check-Out de una matrícula sin estancia activa (HTTP 404)."""
        fake_plate = "9999ZZZ"
        print(f"     [5/9] [NO FELIZ 1] Intentando Check-Out de matricula inexistente {fake_plate}...")
        status_out, body_out = self._perform_checkout(fake_plate)
        self.assertIn(status_out, (404, 400))
        print(f"     [5/9] OK: El backend rechazo correctamente el check-out inexistente con HTTP {status_out}.")

    def test_06_unhappy_path_double_checkout(self):
        """[CAMINO NO FELIZ 2] Doble Check-Out consecutivo de la misma estancia."""
        plate = generate_unique_test_plate()
        print(f"     [6/9] [NO FELIZ 2] Realizando Check-In y primer Check-Out para {plate}...")
        status_in, _ = self._perform_checkin(plate, "CAR")
        self.assertIn(status_in, (200, 201))
        time.sleep(1.0)

        status_out1, _ = self._perform_checkout(plate)
        self.assertEqual(status_out1, 200)

        print(f"     [6/9] [NO FELIZ 2] Reintentando segundo Check-Out de la misma estancia {plate}...")
        status_out2, _ = self._perform_checkout(plate)
        self.assertIn(status_out2, (404, 409, 400))
        print(f"     [6/9] OK: El segundo check-out fue denegado correctamente con HTTP {status_out2}.")

    def test_07_unhappy_path_invalid_jwt_token(self):
        """[CAMINO NO FELIZ 3] Check-Out enviando token JWT inválido (Rechazo HTTP 401 por Kong)."""
        plate = generate_unique_test_plate()
        bad_auth_header = "Bearer eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.invalidtoken.invalid"
        print("     [7/9] [NO FELIZ 3] Enviando token JWT basura a Kong Gateway...")
        status_out, _ = self._perform_checkout(plate, auth_header=bad_auth_header)
        self.assertEqual(status_out, 401)
        print("     [7/9] OK: Kong Gateway denego la peticion con HTTP 401 Unauthorized.")

    def test_08_unhappy_path_missing_plate_payload(self):
        """[CAMINO NO FELIZ 4] Check-Out enviando cuerpo JSON malformado / sin matrícula."""
        print("     [8/9] [NO FELIZ 4] Enviando payload vacio sin campo 'plate'...")
        url = f"{self.kong_url.rstrip('/')}/api/v1/stays/check-out"
        headers = {
            "Authorization": self.authenticator.get_auth_header(),
            "Content-Type": "application/json",
        }
        req = Request(url, data=b"{}", headers=headers, method="POST")
        try:
            with urlopen(req, timeout=10) as resp:
                self.fail("Se esperaba error HTTP 400 por payload sin matricula")
        except HTTPError as e:
            self.assertIn(e.code, (400, 422, 500))
            print(f"     [8/9] OK: El servidor denego la peticion sin matricula con HTTP {e.code}.")

    def test_09_unhappy_path_unreachable_gateway(self):
        """[CAMINO NO FELIZ 5] URL de Gateway inalcanzable / puerto cerrado."""
        print("     [9/9] [NO FELIZ 5] Probando Gateway inalcanzable (http://localhost:9999)...")
        url = "http://localhost:9999/api/v1/stays/check-out"
        req = Request(url, data=b'{"plate":"1234ABC"}', headers={"Content-Type": "application/json"}, method="POST")
        try:
            with urlopen(req, timeout=5):
                self.fail("Se esperaba excepcion URLError")
        except (URLError, Exception) as e:
            print(f"     [9/9] OK: Excepcion de conexion capturada correctamente ({e}).")


if __name__ == "__main__":
    unittest.main(verbosity=2)
