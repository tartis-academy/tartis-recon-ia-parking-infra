#!/usr/bin/env bash
#
# Precondiciones para poder hacer check-in: al menos una tarifa activa y una
# plaza libre por tipo de vehiculo. Sin esto el check-in falla con un error
# de negocio (no hay plaza / no hay tarifa), no es un fallo de la demo.
#
# Va contra Kong con un token real: desde GW-07 los microservicios ya no
# publican puerto de host, y Kong exige JWT en las 7 rutas.
#
# Uso:
#   ./scripts/seed-demo-data.sh
#   SPOTS_PER_TYPE=10 ./scripts/seed-demo-data.sh
#   DEMO_USER=operario.test DEMO_PASSWORD='Operario.123!' ./scripts/seed-demo-data.sh
#
set -euo pipefail

# shellcheck source=lib/demo-auth.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/demo-auth.sh"

SPOTS_PER_TYPE="${SPOTS_PER_TYPE:-5}"
TYPES=(CAR MOTORBIKE CAR_PMR)

if [ -t 1 ]; then
  GREEN=$'\e[32m'; RED=$'\e[31m'; BOLD=$'\e[1m'; OFF=$'\e[0m'
else
  GREEN=""; RED=""; BOLD=""; OFF=""
fi
info() { echo "${BOLD}==>${OFF} $1"; }
ok()   { echo "  ${GREEN}OK${OFF}  $1"; }

require_kong

# Se captura una sola vez y con "|| exit 1": en linea, un fallo de
# auth_header produciria una cabecera vacia sin cortar el script.
AUTH=$(auth_header) || exit 1

# Un 401/403 aqui no es "el dato esta mal", es el token: merece un aviso
# explicito porque en la prueba E2E del 30/07 un 401 disfrazado de error de
# negocio costo un buen rato de diagnostico.
warn_if_auth() {
  case "$1" in
    401) echo "  ${RED}401${OFF} token invalido o caducado (usuario $DEMO_USER)" >&2 ;;
    403) echo "  ${RED}403${OFF} '$DEMO_USER' no tiene rol para esto" >&2 ;;
  esac
}

info "Tarifas activas (via Kong, como $DEMO_USER)"
for type in "${TYPES[@]}"; do
  code=$(curl -s -X POST "$KONG_URL/api/v1/tariffs" \
    -H "$AUTH" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"Demo $type\",\"type\":\"$type\",\"pricePerMinute\":0.05,\"basePrice\":1.0,\"active\":true}" \
    -o /dev/null -w "%{http_code}")
  echo "  $code tariff $type"
  warn_if_auth "$code"
done
ok "hecho"

info "Plazas libres ($SPOTS_PER_TYPE por tipo)"
for type in "${TYPES[@]}"; do
  for _ in $(seq 1 "$SPOTS_PER_TYPE"); do
    code=$(curl -s -X POST "$KONG_URL/api/v1/spots" \
      -H "$AUTH" \
      -H "Content-Type: application/json" \
      -d "{\"type\":\"$type\"}" \
      -o /dev/null -w "%{http_code}")
    printf '%s ' "$code"
    warn_if_auth "$code"
  done
  echo "spot $type x$SPOTS_PER_TYPE"
done
ok "hecho"
