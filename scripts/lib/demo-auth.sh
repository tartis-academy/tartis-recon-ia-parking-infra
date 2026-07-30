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
# El realm usa el lifespan por defecto de Keycloak (300s). Se renueva a los 240
# para no cortar por los pelos en un script largo: un checkin-traffic.sh con
# COUNT alto pasa de 5 minutos sin despeinarse y, sin esto, la segunda mitad de
# la tanda fallaria con 401 y pareceria un bug de la aplicacion.
_TOKEN_TTL=240

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

  _TOKEN=$(printf '%s' "$response" \
    | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null)

  if [ -z "$_TOKEN" ]; then
    echo "ERROR: Keycloak no devolvio access_token para '$DEMO_USER'." >&2
    echo "       Respuesta: $response" >&2
    return 1
  fi
  _TOKEN_AT=$(date +%s)
}

# Imprime la cabecera lista para pasar a curl, renovando el token si toca.
auth_header() {
  local now
  now=$(date +%s)
  if [ -z "$_TOKEN" ] || [ $((now - _TOKEN_AT)) -ge "$_TOKEN_TTL" ]; then
    _fetch_token || return 1
  fi
  printf 'Authorization: Bearer %s' "$_TOKEN"
}

# Falla pronto y con un mensaje util si Kong no esta delante.
require_kong() {
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' "$KONG_URL/api/v1/spots" 2>/dev/null || echo 000)
  if [ "$code" = "000" ]; then
    echo "ERROR: Kong no responde en $KONG_URL." >&2
    echo "       Levanta el stack: ./setup.sh full" >&2
    return 1
  fi
}
