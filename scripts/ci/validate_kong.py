#!/usr/bin/env python3
"""Valida invariantes de seguridad (GW-03) y de trazabilidad (GW-06) en kong.yml.

Uso: python3 scripts/ci/validate_kong.py [ruta a kong.yml]

Pensado para correr igual en CI (.github/workflows/validate-infra.yml) y en
local, sin copiar bloques de Python sueltos en YAML.

Politica: el plugin jwt se declara SIEMPRE a nivel de route, nunca de service.
Asi una route nueva bajo un service ya protegido no hereda proteccion en
silencio y hay que declararla de forma explicita, que es lo que este validador
puede comprobar.
"""

import sys

import yaml

# EventSource (SSE-08, endpoint pendiente de stay-service) no puede mandar
# cabeceras custom, asi que esa ruta necesita aceptar el token por query
# string a proposito. Si el nombre real de la ruta al implementarla es
# distinto, actualizar este set (y solo este set) en el mismo PR.
SSE_ROUTES = {"stay-service-events-route"}

# GW-06: nombre acordado entre Kong (plugin correlation-id) y los
# microservicios (CorrelationIdFilter). Cambiarlo en un solo lado corta la
# traza sin que falle nada.
CORRELATION_ID_HEADER = "X-Correlation-ID"


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


# ============================================================
# GW-06 — trazabilidad
# ============================================================


def _global_plugin(config, name):
    for plugin in config.get("plugins", []):
        if plugin.get("name") == name:
            return plugin
    return None


def check_correlation_id(config):
    plugin = _global_plugin(config, "correlation-id")
    if plugin is None:
        return (
            "Falta el plugin correlation-id en el bloque plugins global: sin el "
            "no hay forma de unir los logs de Kong con los de los 5 microservicios"
        )

    conf = plugin.get("config", {})

    # Los microservicios leen esta cabecera concreta (CorrelationIdFilter). Si
    # aqui se cambia el nombre y alli no, la traza se corta sin avisar: cada
    # micro generaria su propio id y los logs no se podrian cruzar.
    if conf.get("header_name") != CORRELATION_ID_HEADER:
        return (
            f"correlation-id debe usar header_name: {CORRELATION_ID_HEADER} "
            f"(los microservicios leen esa cabecera); ahora vale "
            f"{conf.get('header_name') or 'el default Kong-Request-ID'}"
        )

    # Por defecto es false. Sin esto el front no recibe la cabecera y el
    # usuario no puede aportar el id al reportar un fallo.
    if conf.get("echo_downstream") is not True:
        return "correlation-id necesita echo_downstream: true para devolver la cabecera al cliente"

    return None


def check_correlation_id_is_exposed_by_cors(config):
    """echo_downstream sin exposed_headers no sirve para el navegador."""
    if _global_plugin(config, "correlation-id") is None:
        return None  # ya lo reporta check_correlation_id

    cors = _global_plugin(config, "cors")
    if cors is None:
        return None  # sin cors no hay restriccion de lectura que salvar

    exposed = cors.get("config", {}).get("exposed_headers") or []
    if CORRELATION_ID_HEADER not in exposed:
        return (
            f"cors debe listar {CORRELATION_ID_HEADER} en exposed_headers: el "
            "navegador recibe la cabecera pero el JavaScript del front no puede "
            "leerla sin Access-Control-Expose-Headers"
        )
    return None


def check_request_logging(config):
    if _global_plugin(config, "file-log") is None:
        return (
            "Falta el plugin file-log en el bloque plugins global: el criterio "
            "de GW-06 pide registro de peticiones"
        )
    return None


def check_sse_route_redacts_query_string(config):
    """
    El serializer de Kong redacta la cabecera Authorization, pero NO la query
    string, y la duplica en request.uri, request.url y request.querystring.

    La ruta SSE es la unica que manda el token en la URL (EventSource no admite
    cabeceras), asi que es la unica donde file-log filtraria el token. Tiene que
    declarar file-log a nivel de route con custom_fields_by_lua tapando los tres
    campos.

    Esta comprobacion no hace nada hasta que SSE-08 exista. Esta escrita ya a
    proposito: cuando alguien anada esa ruta, el CI le recuerda el requisito en
    el momento, en vez de descubrirse en una auditoria posterior.
    """
    required_fields = {"request.uri", "request.url", "request.querystring"}

    for service in config.get("services", []):
        for route in service.get("routes", []):
            if route.get("name") not in SSE_ROUTES:
                continue

            file_log = next(
                (p for p in route.get("plugins", []) if p.get("name") == "file-log"),
                None,
            )
            if file_log is None:
                return (
                    f"la ruta {route.get('name')} manda el token en la query string y "
                    "necesita su propio plugin file-log con custom_fields_by_lua, o el "
                    "token acabara en los logs (el file-log global no lo redacta)"
                )

            custom = (file_log.get("config", {}).get("custom_fields_by_lua") or {}).keys()
            missing = required_fields - set(custom)
            if missing:
                return (
                    f"el file-log de {route.get('name')} no redacta {sorted(missing)}: "
                    "el serializer de Kong mete la query string en esos tres campos"
                )
    return None


CHECKS = [
    check_all_routes_have_jwt,
    check_uri_param_names,
    check_claims_to_verify,
    check_cookie_names,
    check_correlation_id,
    check_correlation_id_is_exposed_by_cors,
    check_request_logging,
    check_sse_route_redacts_query_string,
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

    print("OK: kong.yml pasa las validaciones de seguridad y trazabilidad")


if __name__ == "__main__":
    main()
