#!/usr/bin/env bash
#
# Helper compartido de los scripts de demo: saca un access token de Keycloak y
# lo renueva solo. Se usa con `source`, no se ejecuta directamente.
#
# Desde GW-07 los microservicios ya no publican puerto de host: la unica
# entrada es Kong (:8000, rutas /api/v1/...), y Kong exige JWT en las 7 rutas.
# Cualquier script que toque la API necesita por tanto un token real.
#
# Variables que respeta (todas con default para el stack local):
#   KONG_URL           http://localhost:8000
#   KEYCLOAK_URL       http://localhost:8180
#   KEYCLOAK_REALM     parking
#   KEYCLOAK_CLIENT    parking-frontend
#   DEMO_USER          admin.test
#   DEMO_PASSWORD      Admin.123!
#
# Uso:
#   source "$(dirname "$0")/lib/demo-auth.sh"
#   curl -H "$(auth_header)" "$KONG_URL/api/v1/spots"

KONG_URL="${KONG_URL:-http://localhost:8000}"
KEYCLOAK_URL="${KEYCLOAK_URL:-http://localhost:8180}"
KEYCLOAK_REALM="${KEYCLOAK_REALM:-parking}"
KEYCLOAK_CLIENT="${KEYCLOAK_CLIENT:-parking-frontend}"
DEMO_USER="${DEMO_USER:-admin.test}"
DEMO_PASSWORD="${DEMO_PASSWORD:-Admin.123!}"

_TOKEN=""
_TOKEN_AT=0
# Se rellena con el expires_in que devuelve Keycloak, menos un margen. No se
# hardcodea: si alguien baja el lifespan del realm por debajo del margen fijo
# vuelven los 401 intermitentes que este helper existe para evitar.
_TOKEN_TTL=0
_TOKEN_MARGEN=60

_fetch_token() {
  local response
  response=$(curl -s -X POST \
    "$KEYCLOAK_URL/realms/$KEYCLOAK_REALM/protocol/openid-connect/token" \
    -d "client_id=$KEYCLOAK_CLIENT" \
    -d "username=$DEMO_USER" \
    -d "password=$DEMO_PASSWORD" \
    -d "grant_type=password") || {
      echo "ERROR: no se pudo contactar con Keycloak en $KEYCLOAK_URL" >&2
      echo "       Levanta la plataforma: ./setup.sh" >&2
      return 1
    }

  # Se lee tambien expires_in para no hardcodear cuando renovar.
  local parsed
  parsed=$(printf '%s' "$response" \
    | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("access_token",""),d.get("expires_in",300))')

  _TOKEN="${parsed%% *}"
  local expires="${parsed##* }"

  if [ -z "$_TOKEN" ]; then
    echo "ERROR: Keycloak no devolvio access_token para '$DEMO_USER'." >&2
    echo "       Respuesta: $response" >&2
    return 1
  fi

  # Margen para no cortar por los pelos en un script largo: un
  # checkin-traffic.sh con COUNT alto pasa de 5 minutos sin despeinarse y, sin
  # esto, la segunda mitad de la tanda fallaria con 401 y pareceria un bug de
  # la aplicacion. Si el lifespan fuera menor que el margen, se renueva a la
  # mitad en vez de en cada peticion.
  if [ "$expires" -gt $((_TOKEN_MARGEN * 2)) ]; then
    _TOKEN_TTL=$((expires - _TOKEN_MARGEN))
  else
    _TOKEN_TTL=$((expires / 2))
  fi

  _TOKEN_AT=$(date +%s)
}

# Imprime la cabecera lista para pasar a curl, renovando el token si toca.
#
# Devuelve 1 si no hay token. Importante capturarlo en una variable antes de
# usarlo:  token=$(auth_header) || exit 1
# Si se llama en linea (curl -H "$(auth_header)"), un fallo produce una
# cabecera VACIA y set -e no corta, porque es un argumento y no una
# asignacion: el script seguiria lanzando peticiones sin token y reportaria
# los 401 como si fueran de la API.
auth_header() {
  local now
  now=$(date +%s)
  if [ -z "$_TOKEN" ] || [ $((now - _TOKEN_AT)) -ge "$_TOKEN_TTL" ]; then
    _fetch_token || return 1
  fi
  printf 'Authorization: Bearer %s' "$_TOKEN"
}

# Falla pronto y con un mensaje util si falta algo del entorno o Kong no esta.
require_kong() {
  if ! command -v python3 >/dev/null 2>&1; then
    # Sin esto, el 2>/dev/null de _fetch_token se traga el "command not found"
    # y el mensaje de error acaba culpando a Keycloak.
    echo "ERROR: hace falta python3 para leer la respuesta de Keycloak." >&2
    return 1
  fi

  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' "$KONG_URL/api/v1/spots" 2>/dev/null || echo 000)
  if [ "$code" = "000" ]; then
    echo "ERROR: Kong no responde en $KONG_URL." >&2
    echo "       Levanta el stack: ./setup.sh -f" >&2
    return 1
  fi
}
