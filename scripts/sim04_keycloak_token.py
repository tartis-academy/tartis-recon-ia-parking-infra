#!/usr/bin/env python3
"""Obtención y auto-renovación de tokens JWT de Keycloak (Tarea SIM-04).

Soporta:
  - Password Grant (grant_type=password)
  - Client Credentials Grant (grant_type=client_credentials)
  - Obtencion directa de token por consola
  - Simulación de peticiones continuas con auto-renovación de token ante caducidad (TTL)
"""

import argparse
import json
import logging
import random
import string
import sys
import time
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

from lib.keycloak_auth import KeycloakAuthenticator, KeycloakAuthError

logging.basicConfig(
    level=logging.INFO,
    format="[%(asctime)s] %(levelname)s: %(message)s",
    datefmt="%H:%M:%S",
)
logger = logging.getLogger("sim04_keycloak_token")

VEHICLE_TYPES = ["CAR", "CAR", "CAR", "MOTORBIKE", "CAR_PMR"]


def generate_random_plate():
    """Genera una matrícula aleatoria estilo español (ej. 1234ABC)."""
    digits = f"{random.randint(0, 9999):04d}"
    letters = "".join(random.choices(string.ascii_uppercase, k=3))
    return f"{digits}{letters}"


def check_kong_availability(kong_url, timeout=5):
    """Verifica si Kong responde en la URL especificada."""
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


def run_traffic_simulation(authenticator, args):
    """Ejecuta simulación de llamadas continuous con renovación automática del token."""
    kong_url = args.kong_url.rstrip("/")

    logger.info("Comprobando disponibilidad de Kong Gateway en %s...", kong_url)
    if not check_kong_availability(kong_url):
        logger.error("ERROR: Kong no esta disponible en %s.", kong_url)
        logger.error("       Levanta la plataforma ejecutando: ./setup.sh")
        return 1

    if args.plates:
        plates = args.plates
    else:
        plates = [generate_random_plate() for _ in range(args.count)]

    logger.info(
        "Iniciando %d llamadas contra %s/api/v1/stays/check-in (delays: %d-%ds)...",
        len(plates),
        kong_url,
        args.min_delay,
        args.max_delay,
    )

    ok_count = 0
    fail_count = 0

    for i, plate in enumerate(plates, 1):
        vehicle_type = random.choice(VEHICLE_TYPES)

        try:
            was_expired = authenticator.is_token_expired()
            auth_header = authenticator.get_auth_header()
            if was_expired:
                logger.info(
                    "--> Token renovado automaticamente por expiracion (TTL transcurrido)."
                )
        except KeycloakAuthError as e:
            logger.error("Fallo al renovar el token en la iteracion %d: %s", i, e)
            fail_count += 1
            break

        checkin_url = f"{kong_url}/api/v1/stays/check-in"
        payload = json.dumps({"plate": plate, "vehicleType": vehicle_type}).encode(
            "utf-8"
        )
        headers = {
            "Authorization": auth_header,
            "Content-Type": "application/json",
            "Accept": "application/json",
        }

        req = Request(checkin_url, data=payload, headers=headers, method="POST")

        try:
            with urlopen(req, timeout=10) as resp:
                status_code = resp.getcode()
                body = resp.read().decode("utf-8")
                if status_code in (200, 201):
                    ok_count += 1
                    logger.info(
                        "[%d/%d] OK   %s (%s) -> HTTP %d",
                        i,
                        len(plates),
                        plate,
                        vehicle_type,
                        status_code,
                    )
                else:
                    fail_count += 1
                    logger.warning(
                        "[%d/%d] FAIL %s (%s) -> HTTP %d %s",
                        i,
                        len(plates),
                        plate,
                        vehicle_type,
                        status_code,
                        body,
                    )
        except HTTPError as e:
            fail_count += 1
            err_body = ""
            try:
                err_body = e.read().decode("utf-8")
            except Exception:
                pass
            logger.error(
                "[%d/%d] FAIL %s (%s) -> HTTP %d %s",
                i,
                len(plates),
                plate,
                vehicle_type,
                e.code,
                err_body,
            )
        except Exception as e:
            fail_count += 1
            logger.error(
                "[%d/%d] ERROR %s (%s) -> Excepcion: %s",
                i,
                len(plates),
                plate,
                vehicle_type,
                e,
            )

        if i < len(plates):
            delay = random.uniform(args.min_delay, args.max_delay)
            time.sleep(delay)

    logger.info(
        "==> Resultado: %d OK, %d Fallidos de %d totales",
        ok_count,
        fail_count,
        len(plates),
    )
    if fail_count > 0 and ok_count == 0:
        logger.warning(
            "AVISO: 0 exitos. Comprueba que hay tarifas activas y plazas libres: ./scripts/seed-demo-data.sh"
        )
        return 1
    return 0


def main():
    parser = argparse.ArgumentParser(
        description="SIM-04: Obtención de token de Keycloak y prueba de auto-renovación en llamadas a microservicios.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
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
        help="Client ID de Keycloak (default: parking-frontend para password, parking-stay-service para client_credentials)",
    )
    parser.add_argument(
        "--client-secret",
        help="Client Secret de Keycloak (requerido para client_credentials)",
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
        "--token-only",
        action="store_true",
        help="Solo obtener e imprimir el token JWT / cabecera Authorization sin ejecutar trafico",
    )
    parser.add_argument(
        "--kong-url",
        default="http://localhost:8000",
        help="URL base de Kong Gateway (para simulación de llamadas)",
    )
    parser.add_argument(
        "--count",
        type=int,
        default=20,
        help="Numero de llamadas/check-ins a simular para probar auto-renovacion",
    )
    parser.add_argument(
        "--min-delay",
        type=float,
        default=1.0,
        help="Retardo minimo en segundos entre peticiones",
    )
    parser.add_argument(
        "--max-delay",
        type=float,
        default=3.0,
        help="Retardo maximo en segundos entre peticiones",
    )
    parser.add_argument(
        "--margin-seconds",
        type=int,
        default=60,
        help="Margen de seguridad en segundos para anticipar la renovacion del token",
    )
    parser.add_argument(
        "--plates",
        nargs="+",
        help="Lista opcional de matriculas especificas a procesar",
    )
    parser.add_argument(
        "-v", "--verbose",
        action="store_true",
        help="Activar modo verbose / debug",
    )

    args = parser.parse_args()

    if args.verbose:
        logging.getLogger().setLevel(logging.DEBUG)

    # Configurar autenticador
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

    # Si no se pidio --token-only, ejecutar simulación de tráfico para probar la auto-renovación
    sys.exit(run_traffic_simulation(authenticator, args))


if __name__ == "__main__":
    main()
