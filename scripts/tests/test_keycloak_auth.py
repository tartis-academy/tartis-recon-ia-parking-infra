#!/usr/bin/env python3
"""Pruebas de integración REALES contra Keycloak y Kong Gateway (Caminos Felices y No Felices)."""

import json
import os
import sys
import unittest
from urllib.error import HTTPError
from urllib.request import Request, urlopen

# Soporte explícito para ejecuciones vía 'python3 -m unittest discover'
SCRIPTS_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
if SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, SCRIPTS_DIR)

from lib.keycloak_auth import KeycloakAuthenticator, KeycloakAuthError


def parse_jwt_payload(jwt_str):
    """Auxiliar para decodificar el payload JSON de un token JWT real (sin validar firma)."""
    import base64
    parts = jwt_str.split(".")
    if len(parts) != 3:
        return {}
    payload_b64 = parts[1]
    padding = "=" * (4 - len(payload_b64) % 4)
    decoded_bytes = base64.b64decode(payload_b64 + padding)
    return json.loads(decoded_bytes.decode("utf-8"))


class TestKeycloakIntegrationReal(unittest.TestCase):

    def setUp(self):
        self.keycloak_url = os.environ.get("KEYCLOAK_URL", "http://localhost:8180")
        self.kong_url = os.environ.get("KONG_URL", "http://localhost:8000")
        self.realm = os.environ.get("KEYCLOAK_REALM", "parking")
        print(f"\n---> [INTEGRATION TEST] {self._testMethodName}")

    def tearDown(self):
        print(f"---> [INTEGRATION TEST] {self._testMethodName} [OK / PASSED]")

    # =========================================================================
    # CAMINOS FELICES (HAPPY PATHS)
    # =========================================================================

    def test_01_happy_path_password_grant_admin(self):
        """[CAMINO FELIZ 1] Autenticación exitosa de admin.test (Password Grant)."""
        print("     [1/9] [FELIZ] Solicitando token real a Keycloak para admin.test...")
        auth = KeycloakAuthenticator(
            keycloak_url=self.keycloak_url,
            realm=self.realm,
            grant_type="password",
            client_id="parking-frontend",
            username="admin.test",
            password="Admin.123!",
        )

        token = auth.get_access_token()
        self.assertIsNotNone(token)
        self.assertTrue(token.startswith("ey"))
        payload = parse_jwt_payload(token)
        self.assertEqual(payload.get("preferred_username"), "admin.test")
        self.assertIn("ADMIN", payload.get("realm_access", {}).get("roles", []))
        print("     [1/9] OK: Token emitido correctamente para admin.test con rol ADMIN.")

    def test_02_happy_path_password_grant_operario(self):
        """[CAMINO FELIZ 2] Autenticación exitosa de operario.test (Password Grant)."""
        print("     [2/9] [FELIZ] Solicitando token real a Keycloak para operario.test...")
        auth = KeycloakAuthenticator(
            keycloak_url=self.keycloak_url,
            realm=self.realm,
            grant_type="password",
            client_id="parking-frontend",
            username="operario.test",
            password="Operario.123!",
        )

        token = auth.get_access_token()
        self.assertIsNotNone(token)
        payload = parse_jwt_payload(token)
        self.assertEqual(payload.get("preferred_username"), "operario.test")
        self.assertIn("OPERARIO", payload.get("realm_access", {}).get("roles", []))
        print("     [2/9] OK: Token emitido correctamente para operario.test con rol OPERARIO.")

    def test_03_happy_path_client_credentials_grant(self):
        """[CAMINO FELIZ 3] Autenticación exitosa con Client Credentials (parking-stay-service)."""
        print("     [3/9] [FELIZ] Solicitando token real con Client Credentials (parking-stay-service)...")
        auth = KeycloakAuthenticator(
            keycloak_url=self.keycloak_url,
            realm=self.realm,
            grant_type="client_credentials",
            client_id="parking-stay-service",
            client_secret="stay-service-dev-secret-no-usar-fuera-de-local",
        )

        token = auth.get_access_token()
        self.assertIsNotNone(token)
        payload = parse_jwt_payload(token)
        self.assertEqual(payload.get("azp"), "parking-stay-service")
        print("     [3/9] OK: Token de service account emitido correctamente.")

    def test_04_happy_path_token_auto_renewal(self):
        """[CAMINO FELIZ 4] Auto-renovación de token al solicitar forzadamente refresco."""
        print("     [4/9] [FELIZ] Solicitando token inicial y forzando renovacion contra Keycloak...")
        auth = KeycloakAuthenticator(
            keycloak_url=self.keycloak_url,
            realm=self.realm,
            grant_type="password",
            username="admin.test",
            password="Admin.123!",
        )

        token_inicial = auth.get_access_token()
        token_renovado = auth.get_access_token(force_refresh=True)
        self.assertIsNotNone(token_renovado)
        payload1 = parse_jwt_payload(token_inicial)
        payload2 = parse_jwt_payload(token_renovado)
        self.assertEqual(payload1.get("sub"), payload2.get("sub"))
        print("     [4/9] OK: Token renovado en vivo transparente contra Keycloak.")

    # =========================================================================
    # CAMINOS NO FELICES (UNHAPPY PATHS / CASOS DE ERROR)
    # =========================================================================

    def test_05_unhappy_path_invalid_password(self):
        """[CAMINO NO FELIZ 1] Password incorrecto en Password Grant (HTTP 400/401 de Keycloak)."""
        print("     [5/9] [NO FELIZ 1] Probando contraseña incorrecta en Keycloak...")
        auth = KeycloakAuthenticator(
            keycloak_url=self.keycloak_url,
            realm=self.realm,
            grant_type="password",
            username="admin.test",
            password="ContrasenaErronea123!",
        )
        with self.assertRaises(KeycloakAuthError):
            auth.fetch_token()
        print("     [5/9] OK: Keycloak denego el acceso por contraseña incorrecta y la excepción fue capturada.")

    def test_06_unhappy_path_invalid_client_secret(self):
        """[CAMINO NO FELIZ 2] Client Secret incorrecto en Client Credentials Grant."""
        print("     [6/9] [NO FELIZ 2] Probando client_secret incorrecto en Keycloak...")
        auth = KeycloakAuthenticator(
            keycloak_url=self.keycloak_url,
            realm=self.realm,
            grant_type="client_credentials",
            client_id="parking-stay-service",
            client_secret="secreto_invalido_incorrecto",
        )
        with self.assertRaises(KeycloakAuthError):
            auth.fetch_token()
        print("     [6/9] OK: Keycloak denego el acceso por secreto invalido y la excepción fue capturada.")

    def test_07_unhappy_path_unreachable_keycloak_url(self):
        """[CAMINO NO FELIZ 3] URL de Keycloak inalcanzable / puerto cerrado."""
        print("     [7/9] [NO FELIZ 3] Probando puerto inalcanzable (http://localhost:9999)...")
        auth = KeycloakAuthenticator(
            keycloak_url="http://localhost:9999",
            realm=self.realm,
            grant_type="password",
            username="admin.test",
            password="Admin.123!",
            timeout=2,
        )
        with self.assertRaises(KeycloakAuthError):
            auth.fetch_token()
        print("     [7/9] OK: Error de conexión inalcanzable capturado correctamente.")

    def test_08_unhappy_path_nonexistent_realm(self):
        """[CAMINO NO FELIZ 4] Realm de Keycloak inexistente (HTTP 404)."""
        print("     [8/9] [NO FELIZ 4] Probando realm inexistente en Keycloak ('realm_falso_123')...")
        auth = KeycloakAuthenticator(
            keycloak_url=self.keycloak_url,
            realm="realm_falso_123",
            grant_type="password",
            username="admin.test",
            password="Admin.123!",
        )
        with self.assertRaises(KeycloakAuthError):
            auth.fetch_token()
        print("     [8/9] OK: Keycloak devolvio 404 para realm inexistente y fue capturado.")

    def test_09_unhappy_path_kong_rejects_invalid_jwt(self):
        """[CAMINO NO FELIZ 5] Rechazo de token JWT inválido por Kong Gateway (HTTP 401)."""
        print("     [9/9] [NO FELIZ 5] Enviando token JWT basura a Kong Gateway (http://localhost:8000/api/v1/spots)...")
        bad_token_url = f"{self.kong_url.rstrip('/')}/api/v1/spots"
        req = Request(
            bad_token_url,
            headers={"Authorization": "Bearer token_jwt_completamente_invalido_123"},
            method="GET",
        )
        with self.assertRaises(HTTPError) as ctx:
            urlopen(req)
        
        self.assertEqual(ctx.exception.code, 401)
        print("     [9/9] OK: Kong Gateway denegó la petición con HTTP 401 Unauthorized por token JWT invalido.")


if __name__ == "__main__":
    unittest.main()
