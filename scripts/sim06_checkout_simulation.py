#!/usr/bin/env python3
"""Punto de entrada principal MAIN para la tarea SIM-06.

Simulación de Check-Out tras un tiempo aleatorio ejerciendo la regla de negocio RN-08
y activando los tres tramos de tarifa (Minuto, Hora y Día).

Permite:
  1. Obtener directamente el token JWT y cabecera Authorization (--token-only).
  2. Ejecutar la suite completa de pruebas de integración reales (--test).
  3. Ejecutar la simulación de tráfico Check-In -> Check-Out con distribución de duraciones (--count N, --distribution).
"""

import argparse
import json
import logging
import os
import random
import string
import sys
import time
import unittest
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

from lib.keycloak_auth import KeycloakAuthenticator, KeycloakAuthError

logging.basicConfig(
    level=logging.INFO,
    format="[%(asctime)s] %(levelname)s: %(message)s",
    datefmt="%H:%M:%S",
)
logger = logging.getLogger("sim06_main")

VEHICLE_TYPES = ["CAR", "CAR", "CAR", "MOTORBIKE", "CAR_PMR"]

# Distribución de tiempos simulados (en minutos) para ejercitar los tres tramos de tarifa (RN-08)
DISTRIBUTION_PRESETS = {
    "minute": (1, 59),       # Tramo 1: Tarifa por minuto (< 1 hora)
    "hour": (60, 1439),      # Tramo 2: Tarifa por horas (1 hora a 24 horas)
    "day": (1440, 4320),     # Tramo 3: Tarifa diaria (> 24 horas)
}


def generate_random_plate():
    """Genera una matrícula aleatoria única (ej. 1234ABC)."""
    digits = f"{random.randint(1000, 9999)}"
    letters = "".join(random.choices("BCDFGHJKLMNPQRSTVWXYZ", k=3))
    return f"{digits}{letters}"


def check_kong_availability(kong_url, timeout=5):
    """Verifica la conectividad con Kong Gateway."""
    url = f"{kong_url.rstrip('/')}/api/v1/spots"
    req = Request(url, method="GET")
    try:
        with urlopen(req, timeout=timeout) as resp:
            return True
    except HTTPError as e:
        if e.code in (401, 403, 200):
            return True
        logger.error("Kong respondio con codigo HTTP %d en %s", e.code, url)
        return False
    except URLError as e:
        logger.error("No se pudo conectar con Kong en %s: %s", kong_url, e.reason)
        return False
    except Exception as e:
        logger.error("Fallo al verificar Kong en %s: %s", kong_url, e)
        return False


import subprocess

def simulate_entry_time_offset(stay_id, duration_minutes):
    """Ajusta la fecha de check_in en PostgreSQL (parking-stay-db) para ejercitar los tramos de tarifa en RN-08."""
    if stay_id:
        sql = f"UPDATE stays SET check_in = NOW() - INTERVAL '{duration_minutes} minutes' WHERE unique_id = '{stay_id}';"
    else:
        sql = f"UPDATE stays SET check_in = NOW() - INTERVAL '{duration_minutes} minutes' WHERE status = 'IN_PROGRESS' AND unique_id = (SELECT unique_id FROM stays WHERE status = 'IN_PROGRESS' ORDER BY check_in DESC LIMIT 1);"

    cmd = [
        "docker", "exec", "parking-stay-db",
        "psql", "-U", "stay", "-d", "stay_db", "-q", "-c", sql
    ]
    try:
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=5)
        return res.returncode == 0
    except Exception as e:
        logger.debug("No se pudo ajustar fecha de entrada en DB: %s", e)
        return False


def get_simulated_duration(distribution_mode):
    """Calcula una duración en minutos y etiqueta el tramo tarifario (RN-08)."""
    if distribution_mode == "mixed":
        chosen_tier = random.choice(["minute", "hour", "day"])
    else:
        chosen_tier = distribution_mode

    min_m, max_m = DISTRIBUTION_PRESETS.get(chosen_tier, (1, 30))
    duration_minutes = random.randint(min_m, max_m)
    return duration_minutes, chosen_tier


def run_checkout_simulation(authenticator, args):
    """Ejecuta la simulación completa de Check-In + Check-Out ejercitando RN-08."""
    kong_url = args.kong_url.rstrip("/")

    logger.info("Comprobando disponibilidad de Kong Gateway en %s...", kong_url)
    if not check_kong_availability(kong_url):
        logger.error("ERROR: Kong Gateway no esta disponible en %s.", kong_url)
        logger.error("       Asegurate de iniciar la infraestructura ejecutando: ./setup.sh")
        return 1

    if args.plates:
        plates = args.plates
    else:
        plates = [generate_random_plate() for _ in range(args.count)]

    logger.info(
        "Iniciando simulación de Check-In y Check-Out para %d vehiculos (Distribución: %s)...",
        len(plates),
        args.distribution.upper(),
    )

    ok_count = 0
    fail_count = 0

    for i, plate in enumerate(plates, 1):
        vehicle_type = random.choice(VEHICLE_TYPES)
        duration_minutes, tier_label = get_simulated_duration(args.distribution)

        try:
            auth_header = authenticator.get_auth_header()
        except KeycloakAuthError as e:
            logger.error("Fallo al renovar/obtener token de Keycloak en iteracion %d: %s", i, e)
            fail_count += 1
            break

        # -------------------------------------------------------------
        # PASO 1: CHECK-IN DE LA ESTANCIA
        # -------------------------------------------------------------
        checkin_url = f"{kong_url}/api/v1/stays/check-in"
        checkin_payload = json.dumps({"plate": plate, "vehicleType": vehicle_type}).encode("utf-8")
        headers = {
            "Authorization": auth_header,
            "Content-Type": "application/json",
            "Accept": "application/json",
        }
        
        status_in = 0
        stay_id = None
        for attempt in range(3):
            checkin_req = Request(checkin_url, data=checkin_payload, headers=headers, method="POST")
            try:
                with urlopen(checkin_req, timeout=10) as resp:
                    status_in = resp.getcode()
                    if status_in in (200, 201):
                        body_in = json.loads(resp.read().decode("utf-8"))
                        stay_id = body_in.get("stayId")
                        break
            except HTTPError as e:
                status_in = e.code
                if e.code == 503 and attempt < 2:
                    time.sleep(0.5)
                    continue
                err_body = e.read().decode("utf-8") if e.fp else ""
                logger.error("[%d/%d] Check-In FAIL %s (%s) -> HTTP %d %s", i, len(plates), plate, vehicle_type, e.code, err_body)
                break
            except Exception as e:
                logger.error("[%d/%d] Check-In ERROR %s -> Excepcion: %s", i, len(plates), plate, e)
                break

        if status_in not in (200, 201):
            fail_count += 1
            continue

        # -------------------------------------------------------------
        # PASO 1.5: APLICAR DESFASE TEMPORAL SIMULADO EN BASE DE DATOS (RN-08)
        # -------------------------------------------------------------
        simulate_entry_time_offset(stay_id, duration_minutes)

        # Simular pausa entre entrada y salida
        delay = random.uniform(args.min_delay, args.max_delay)
        time.sleep(delay)

        # -------------------------------------------------------------
        # PASO 2: CHECK-OUT Y CÁLCULO DE TARIFA (RN-08)
        # -------------------------------------------------------------
        checkout_url = f"{kong_url}/api/v1/stays/check-out"
        checkout_payload = json.dumps({"plate": plate}).encode("utf-8")
        checkout_req = Request(checkout_url, data=checkout_payload, headers=headers, method="POST")

        try:
            with urlopen(checkout_req, timeout=10) as resp:
                status_out = resp.getcode()
                body_str = resp.read().decode("utf-8")
                body = json.loads(body_str)

                if status_out == 200:
                    ok_count += 1
                    amount = body.get("amount", 0.0)
                    total_min = body.get("totalMinutes", duration_minutes)
                    status = body.get("status", "FINISHED")
                    logger.info(
                        "[%d/%d] OK Check-Out %s (%s) | Tramo: %s (%d mins) -> Estado: %s, Importe: %.2f €",
                        i,
                        len(plates),
                        plate,
                        vehicle_type,
                        tier_label.upper(),
                        total_min,
                        status,
                        float(amount),
                    )
                else:
                    fail_count += 1
                    logger.warning("[%d/%d] Check-Out FAIL %s -> HTTP %d %s", i, len(plates), plate, status_out, body_str)
        except HTTPError as e:
            fail_count += 1
            err_body = e.read().decode("utf-8") if e.fp else ""
            logger.error("[%d/%d] Check-Out FAIL %s -> HTTP %d %s", i, len(plates), plate, e.code, err_body)
        except Exception as e:
            fail_count += 1
            logger.error("[%d/%d] Check-Out ERROR %s -> Excepcion: %s", i, len(plates), plate, e)

    logger.info(
        "==> Resultado Simulación SIM-06: %d OK, %d Fallidos de %d totales",
        ok_count,
        fail_count,
        len(plates),
    )
    return 0 if ok_count > 0 or fail_count == 0 else 1


def run_integration_tests():
    """Ejecuta la suite de pruebas de integración cargando test_checkout_simulation.py."""
    logger.info("Ejecutando la suite completa de pruebas de integración reales de Check-Out...")
    tests_dir = os.path.join(os.path.dirname(__file__), "tests")
    sys.path.insert(0, tests_dir)
    try:
        from test_checkout_simulation import TestCheckoutSimulationReal
        suite = unittest.TestLoader().loadTestsFromTestCase(TestCheckoutSimulationReal)
        runner = unittest.TextTestRunner(verbosity=2)
        result = runner.run(suite)
        return 0 if result.wasSuccessful() else 1
    except Exception as e:
        logger.error("Fallo al ejecutar las pruebas de integracion: %s", e)
        return 1


def main():
    parser = argparse.ArgumentParser(
        description="SIM-06: Script principal MAIN para simulación de Check-Out (RN-08, tramos de tarifa) y pruebas de integración.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument(
        "--test",
        action="store_true",
        help="Ejecutar la suite completa de pruebas de integracion reales contra Keycloak, Kong y Backend",
    )
    parser.add_argument(
        "--token-only",
        action="store_true",
        help="Solo obtener e imprimir el token JWT / cabecera Authorization sin ejecutar tráfico ni tests",
    )
    parser.add_argument(
        "--grant-type",
        choices=["password", "client_credentials"],
        default="password",
        help="Grant type para autenticar en Keycloak",
    )
    parser.add_argument(
        "--keycloak-url",
        default="http://localhost:8180",
        help="URL base de Keycloak",
    )
    parser.add_argument(
        "--realm",
        default="parking",
        help="Realm de Keycloak",
    )
    parser.add_argument(
        "--client-id",
        help="Client ID de Keycloak",
    )
    parser.add_argument(
        "--client-secret",
        help="Client Secret de Keycloak",
    )
    parser.add_argument(
        "--user",
        default="admin.test",
        help="Usuario para password grant",
    )
    parser.add_argument(
        "--password",
        default="Admin.123!",
        help="Password para password grant",
    )
    parser.add_argument(
        "--kong-url",
        default="http://localhost:8000",
        help="URL base de Kong Gateway",
    )
    parser.add_argument(
        "--count",
        type=int,
        default=10,
        help="Número de flujos de Check-In + Check-Out a simular",
    )
    parser.add_argument(
        "--distribution",
        choices=["mixed", "minute", "hour", "day"],
        default="mixed",
        help="Distribución de tramos de duración de estancia a ejercitar (RN-08)",
    )
    parser.add_argument(
        "--min-delay",
        type=float,
        default=0.5,
        help="Pausa mínima en segundos entre peticiones",
    )
    parser.add_argument(
        "--max-delay",
        type=float,
        default=1.5,
        help="Pausa máxima en segundos entre peticiones",
    )
    parser.add_argument(
        "--margin-seconds",
        type=int,
        default=60,
        help="Margen de seguridad para auto-renovación del token de Keycloak",
    )
    parser.add_argument(
        "--plates",
        nargs="+",
        help="Lista opcional de matrículas específicas a procesar",
    )
    parser.add_argument(
        "-v", "--verbose",
        action="store_true",
        help="Activar modo verbose / debug",
    )

    args = parser.parse_args()

    if args.verbose:
        logging.getLogger().setLevel(logging.DEBUG)

    # 1. Si se solicita --test, ejecutar suite de tests
    if args.test:
        sys.exit(run_integration_tests())

    # 2. Configurar autenticador
    try:
        authenticator = KeycloakAuthenticator(
            keycloak_url=args.keycloak_url,
            realm=args.realm,
            grant_type=args.grant_type,
            client_id=args.client_id,
            client_secret=args.client_secret,
            username=args.user,
            password=args.password,
            margin_seconds=args.margin_seconds,
        )
        token = authenticator.get_access_token()
    except KeycloakAuthError as e:
        logger.error("Fallo al obtener token de Keycloak: %s", e)
        sys.exit(1)

    if args.token_only:
        print(f"Access Token: {token}")
        print(f"Authorization Header: {authenticator.get_auth_header()}")
        sys.exit(0)

    # 3. Ejecutar simulación de tráfico Check-In -> Check-Out
    sys.exit(run_checkout_simulation(authenticator, args))


if __name__ == "__main__":
    main()
