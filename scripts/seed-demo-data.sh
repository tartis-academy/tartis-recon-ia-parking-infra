#!/usr/bin/env bash
#
# Precondiciones para poder hacer check-in: al menos una tarifa activa y una
# plaza libre por tipo de vehiculo. Sin esto el check-in falla con un error
# de negocio (no hay plaza / no hay tarifa), no es un fallo de la demo.
#
# Uso:
#   ./scripts/seed-demo-data.sh
#   SPOTS_PER_TYPE=10 ./scripts/seed-demo-data.sh
#
set -euo pipefail

BASE_URL_VEHICLE="${BASE_URL_VEHICLE:-http://localhost:8080}"
BASE_URL_SPOT="${BASE_URL_SPOT:-http://localhost:8081}"
BASE_URL_TARIFF="${BASE_URL_TARIFF:-http://localhost:8082}"
SPOTS_PER_TYPE="${SPOTS_PER_TYPE:-5}"
TYPES=(CAR MOTORBIKE CAR_PMR)

if [ -t 1 ]; then
  GREEN=$'\e[32m'; BOLD=$'\e[1m'; OFF=$'\e[0m'
else
  GREEN=""; BOLD=""; OFF=""
fi
info() { echo "${BOLD}==>${OFF} $1"; }
ok()   { echo "  ${GREEN}OK${OFF}  $1"; }

info "Tarifas activas"
for type in "${TYPES[@]}"; do
  curl -s -X POST "$BASE_URL_TARIFF/v1/tariffs" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"Demo $type\",\"type\":\"$type\",\"pricePerMinute\":0.05,\"basePrice\":1.0,\"active\":true}" \
    -o /dev/null -w "  %{http_code} tariff $type\n"
done
ok "hecho"

info "Plazas libres ($SPOTS_PER_TYPE por tipo)"
for type in "${TYPES[@]}"; do
  for _ in $(seq 1 "$SPOTS_PER_TYPE"); do
    curl -s -X POST "$BASE_URL_SPOT/v1/spots" \
      -H "Content-Type: application/json" \
      -d "{\"type\":\"$type\"}" \
      -o /dev/null -w "%{http_code} "
  done
  echo "spot $type x$SPOTS_PER_TYPE"
done
ok "hecho"
