#!/usr/bin/env bash
#
# Precondiciones para poder hacer check-in: al menos una tarifa activa y una
# plaza libre por tipo de vehiculo. Sin esto el check-in falla con un error
# de negocio (no hay plaza / no hay tarifa), no es un fallo de la demo.
#
# Va contra Kong con un token real: desde GW-07 los microservicios ya no
# publican puerto de host, y Kong exige JWT en las 7 rutas.
#
# IDEMPOTENTE: cuenta lo que ya hay y crea solo lo que falta hasta el cupo, asi
# que lo llama demo-stack.sh en cada `up` sin multiplicar los datos. Las BD son
# volumenes persistentes: sin esto, cada arranque anadiria otras 50 plazas.
#
# Uso:
#   ./scripts/seed-demo-data.sh
#   SPOTS_CAR=40 ./scripts/seed-demo-data.sh
#   DEMO_USER=operario.test DEMO_PASSWORD='Operario.123!' ./scripts/seed-demo-data.sh
#
set -euo pipefail

# shellcheck source=lib/demo-auth.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/demo-auth.sh"

SPOTS_CAR="${SPOTS_CAR:-20}"
SPOTS_MOTORBIKE="${SPOTS_MOTORBIKE:-20}"
SPOTS_CAR_PMR="${SPOTS_CAR_PMR:-10}"
TYPES=(CAR MOTORBIKE CAR_PMR)

if [ -t 1 ]; then
  GREEN=$'\e[32m'; RED=$'\e[31m'; YELLOW=$'\e[33m'; BOLD=$'\e[1m'; OFF=$'\e[0m'
else
  GREEN=""; RED=""; YELLOW=""; BOLD=""; OFF=""
fi
info() { echo "${BOLD}==>${OFF} $1"; }
ok()   { echo "  ${GREEN}OK${OFF}  $1"; }
warn() { echo "  ${YELLOW}!${OFF}   $1"; }

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

cupo_de() {
  case "$1" in
    CAR)       echo "$SPOTS_CAR" ;;
    MOTORBIKE) echo "$SPOTS_MOTORBIKE" ;;
    CAR_PMR)   echo "$SPOTS_CAR_PMR" ;;
  esac
}

# Cuenta elementos de una coleccion por el valor de un campo. Acepta tanto la
# lista plana de spot-service como el objeto paginado de tariff-service: los dos
# formatos conviven en el proyecto y el script se usa contra ambos.
contar_por() {
  python3 -c '
import sys, json
campo, valor = sys.argv[1], sys.argv[2]
solo_activos = len(sys.argv) > 3
try:
    d = json.load(sys.stdin)
except Exception:
    print(-1); raise SystemExit
items = d.get("content", d) if isinstance(d, dict) else d
if not isinstance(items, list):
    print(-1); raise SystemExit
n = 0
for i in items:
    if i.get(campo) != valor:
        continue
    if solo_activos and not i.get("active", True):
        continue
    n += 1
print(n)
' "$@"
}

get_json() {
  curl -s -H "$AUTH" "$KONG_URL$1"
}

info "Tarifas activas (via Kong, como $DEMO_USER)"
tarifas=$(get_json "/api/v1/tariffs")
for type in "${TYPES[@]}"; do
  # El contrato desplegado de tariff-service pide name/type/basePrice/
  # pricePerMinute/active, NO lo que documenta su openapi.yml (vehicleType,
  # minimumCharge, courtesyMinutes, tiers). Deriva de contrato conocida.
  ya=$(printf '%s' "$tarifas" | contar_por type "$type" activos)
  if [ "$ya" -lt 0 ]; then
    warn "no se pudo leer el listado de tarifas; se intenta crear igualmente"
    ya=0
  fi
  if [ "$ya" -gt 0 ]; then
    ok "$type ya tiene $ya tarifa(s) activa(s), no se toca"
    continue
  fi
  code=$(curl -s -X POST "$KONG_URL/api/v1/tariffs" \
    -H "$AUTH" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"Demo $type\",\"type\":\"$type\",\"pricePerMinute\":0.05,\"basePrice\":1.0,\"active\":true}" \
    -o /dev/null -w "%{http_code}")
  echo "  $code tariff $type creada"
  warn_if_auth "$code"
done

info "Plazas (cupo: CAR=$SPOTS_CAR MOTORBIKE=$SPOTS_MOTORBIKE CAR_PMR=$SPOTS_CAR_PMR)"
spots=$(get_json "/api/v1/spots")
for type in "${TYPES[@]}"; do
  cupo=$(cupo_de "$type")
  ya=$(printf '%s' "$spots" | contar_por type "$type")
  if [ "$ya" -lt 0 ]; then
    warn "no se pudo leer el listado de plazas; se omite $type para no duplicar"
    continue
  fi
  faltan=$((cupo - ya))
  if [ "$faltan" -le 0 ]; then
    ok "$type ya tiene $ya/$cupo, no se crea ninguna"
    continue
  fi
  for _ in $(seq 1 "$faltan"); do
    code=$(curl -s -X POST "$KONG_URL/api/v1/spots" \
      -H "$AUTH" \
      -H "Content-Type: application/json" \
      -d "{\"type\":\"$type\"}" \
      -o /dev/null -w "%{http_code}")
    if [ "$code" != "201" ]; then
      printf '%s ' "$code"
      warn_if_auth "$code"
    fi
  done
  ok "$type $ya -> $cupo (creadas $faltan)"
done
