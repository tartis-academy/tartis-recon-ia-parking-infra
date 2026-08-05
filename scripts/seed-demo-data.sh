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
# Si no se puede contar lo que ya existe, NO se crea nada: no hay unique por tipo
# ni en spots ni en tariffs, asi que sembrar a ciegas duplica en vez de fallar.
# Sale con 1 si algo se quedo sin sembrar, para que demo-stack.sh lo avise.
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

# Se acumulan los tipos que no se pudieron sembrar para salir con 1 y que
# demo-stack.sh avise en vez de dar el seed por bueno.
fallos=0

if [ -t 1 ]; then
  GREEN=$'\e[32m'; RED=$'\e[31m'; YELLOW=$'\e[33m'; BOLD=$'\e[1m'; OFF=$'\e[0m'
else
  GREEN=""; RED=""; YELLOW=""; BOLD=""; OFF=""
fi
info() { echo "${BOLD}==>${OFF} $1"; }
ok()   { echo "  ${GREEN}OK${OFF}  $1"; }
warn() { echo "  ${YELLOW}!${OFF}   $1"; }

require_kong

# Un cupo no numerico o negativo llegaria hasta `seq 1 "$faltan"` o hasta la
# resta cupo-ya y sembraria una cantidad arbitraria.
validar_cupo() {
  case "$2" in
    ''|*[!0-9]*)
      echo "ERROR: $1 debe ser un entero >= 0 (recibido: '$2')" >&2
      return 1
      ;;
  esac
}
validar_cupo SPOTS_CAR "$SPOTS_CAR"
validar_cupo SPOTS_MOTORBIKE "$SPOTS_MOTORBIKE"
validar_cupo SPOTS_CAR_PMR "$SPOTS_CAR_PMR"

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

# Cuenta elementos de una coleccion por el valor de un campo. Hoy spot-service y
# tariff-service devuelven List<T> plana (ResponseEntity<List<...>>, sin
# Pageable), pero se acepta tambien el envoltorio Page de Spring por si alguno
# migra: lo que no se puede es contar media coleccion y creerse el total.
#
# Salida: imprime el conteo y sale con 0. Codigos de error, para que el llamante
# distinga "hay 0" de "no lo se":
#   2  respuesta ilegible o con una forma que no es una coleccion
#   3  respuesta paginada e incompleta (mas de una pagina)
contar_por() {
  python3 -c '
import sys, json
campo, valor = sys.argv[1], sys.argv[2]
solo_activos = len(sys.argv) > 3
try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit(2)
if isinstance(d, dict):
    # Los endpoints de este proyecto no aceptan ?page, asi que si algun dia
    # devuelven mas de una pagina no hay forma de pedir el resto: se aborta.
    if "content" in d and d.get("totalPages", 1) > 1:
        raise SystemExit(3)
    items = d.get("content", d)
else:
    items = d
if not isinstance(items, list):
    raise SystemExit(2)
n = 0
for i in items:
    if not isinstance(i, dict) or i.get(campo) != valor:
        continue
    if solo_activos and not i.get("active", True):
        continue
    n += 1
print(n)
' "$@"
}

motivo_lectura() {
  case "$1" in
    3) echo "la respuesta viene paginada y solo trae la primera pagina" ;;
    *) echo "la respuesta no se pudo leer" ;;
  esac
}

# Devuelve el cuerpo por stdout y 1 si el GET no fue 200. Sin mirar el codigo,
# un 401 de Kong o un 502 llegan a contar_por como un JSON cualquiera y, si su
# forma colase, se contarian como "0 elementos" -> duplicado silencioso.
get_json() {
  local respuesta code
  respuesta=$(curl -s -w '\n%{http_code}' -H "$AUTH" "$KONG_URL$1") || {
    echo "  ${RED}--${OFF}  GET $1: curl no pudo conectar" >&2
    return 1
  }
  code=${respuesta##*$'\n'}
  printf '%s' "${respuesta%$'\n'*}"
  if [ "$code" != "200" ]; then
    echo "  ${RED}$code${OFF} GET $1" >&2
    warn_if_auth "$code"
    return 1
  fi
}

info "Tarifas activas (via Kong, como $DEMO_USER)"
rc=0
tarifas=$(get_json "/api/v1/tariffs") || rc=$?
if [ "$rc" -ne 0 ]; then
  # Mismo criterio que en las plazas: sin lectura fiable no se crea nada. La
  # tabla de tarifas no tiene unique por tipo, asi que crear a ciegas deja
  # varias tarifas activas del mismo tipo y el calculo de precio pasa a
  # depender de cual devuelva primero la BD.
  warn "no se pudo leer el listado de tarifas; se omiten para no duplicar"
  fallos=1
else
  for type in "${TYPES[@]}"; do
    # El contrato desplegado de tariff-service pide name/type/basePrice/
    # pricePerMinute/active, NO lo que documenta su openapi.yml (vehicleType,
    # minimumCharge, courtesyMinutes, tiers). Deriva de contrato conocida.
    rc=0
    ya=$(printf '%s' "$tarifas" | contar_por type "$type" activos) || rc=$?
    if [ "$rc" -ne 0 ]; then
      warn "$(motivo_lectura "$rc"); se omiten las tarifas $type para no duplicar"
      fallos=1
      continue
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
    if [ "$code" = "201" ]; then
      ok "tariff $type creada"
    else
      warn "$code al crear la tarifa $type"
      warn_if_auth "$code"
      fallos=1
    fi
  done
fi

info "Plazas (cupo: CAR=$SPOTS_CAR MOTORBIKE=$SPOTS_MOTORBIKE CAR_PMR=$SPOTS_CAR_PMR)"
rc=0
spots=$(get_json "/api/v1/spots") || rc=$?
if [ "$rc" -ne 0 ]; then
  warn "no se pudo leer el listado de plazas; se omiten para no duplicar"
  fallos=1
else
  for type in "${TYPES[@]}"; do
    cupo=$(cupo_de "$type")
    rc=0
    ya=$(printf '%s' "$spots" | contar_por type "$type") || rc=$?
    if [ "$rc" -ne 0 ]; then
      warn "$(motivo_lectura "$rc"); se omiten las plazas $type para no duplicar"
      fallos=1
      continue
    fi
    faltan=$((cupo - ya))
    if [ "$faltan" -le 0 ]; then
      ok "$type ya tiene $ya/$cupo, no se crea ninguna"
      continue
    fi
    # curl sale con 0 ante un 4xx/5xx, asi que set -e no corta: hay que contar
    # los 201 uno a uno para no reportar un cupo que no se ha alcanzado.
    creadas=0
    for _ in $(seq 1 "$faltan"); do
      code=$(curl -s -X POST "$KONG_URL/api/v1/spots" \
        -H "$AUTH" \
        -H "Content-Type: application/json" \
        -d "{\"type\":\"$type\"}" \
        -o /dev/null -w "%{http_code}")
      if [ "$code" = "201" ]; then
        creadas=$((creadas + 1))
      else
        printf '%s ' "$code"
        warn_if_auth "$code"
      fi
    done
    if [ "$creadas" -eq "$faltan" ]; then
      ok "$type $ya -> $((ya + creadas)) (creadas $creadas)"
    else
      warn "$type $ya -> $((ya + creadas)) (creadas $creadas de $faltan pedidas)"
      fallos=1
    fi
  done
fi

exit "$fallos"
