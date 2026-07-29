#!/usr/bin/env python3
"""Valida invariantes de seguridad del plugin jwt en kong.yml.

Uso: python3 scripts/ci/validate_kong.py [ruta a kong.yml]

Pensado para correr igual en CI (.github/workflows/validate-infra.yml) y en
local, sin copiar bloques de Python sueltos en YAML.
"""

import sys

import yaml

# EventSource (SSE-08, endpoint pendiente de stay-service) no puede mandar
# cabeceras custom, asi que esa ruta necesita aceptar el token por query
# string a proposito. Si el nombre real de la ruta al implementarla es
# distinto, actualizar este set (y solo este set) en el mismo PR.
SSE_ROUTES = {"stay-service-events-route"}


def _jwt_plugins(config):
    return [
        (route["name"], plugin)
        for service in config.get("services", [])
        for route in service.get("routes", [])
        for plugin in route.get("plugins", [])
        if plugin["name"] == "jwt"
    ]


def check_all_routes_have_jwt(config):
    missing = [
        route["name"]
        for service in config.get("services", [])
        for route in service.get("routes", [])
        if "jwt" not in [p["name"] for p in route.get("plugins", [])]
    ]
    if missing:
        return "Rutas sin plugin jwt: " + ", ".join(missing)
    return None


def check_uri_param_names(config):
    bad = [
        name
        for name, plugin in _jwt_plugins(config)
        if name not in SSE_ROUTES
        and plugin.get("config", {}).get("uri_param_names") != []
    ]
    if bad:
        return (
            "Rutas con jwt sin uri_param_names: [] (aceptan el token por "
            "query string, ademas de por cabecera): " + ", ".join(bad)
        )
    return None


def check_claims_to_verify(config):
    bad = [
        name
        for name, plugin in _jwt_plugins(config)
        if "exp" not in plugin.get("config", {}).get("claims_to_verify", [])
    ]
    if bad:
        return (
            'Rutas con jwt sin claims_to_verify: ["exp"] (aceptan tokens '
            "caducados en silencio): " + ", ".join(bad)
        )
    return None


def check_cookie_names(config):
    bad = [
        name
        for name, plugin in _jwt_plugins(config)
        if plugin.get("config", {}).get("cookie_names")
    ]
    if bad:
        return (
            "Rutas con jwt y cookie_names no vacio (mismo vector que la "
            "query string, mas riesgo de CSRF): " + ", ".join(bad)
        )
    return None


CHECKS = [
    check_all_routes_have_jwt,
    check_uri_param_names,
    check_claims_to_verify,
    check_cookie_names,
]


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "kong/kong.yml"
    with open(path) as f:
        config = yaml.safe_load(f)

    errors = [msg for msg in (check(config) for check in CHECKS) if msg]

    if errors:
        for error in errors:
            print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)

    print("OK: kong.yml pasa las validaciones de seguridad del plugin jwt")


if __name__ == "__main__":
    main()
