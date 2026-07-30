#!/usr/bin/env bash
#
# Generador de trafico de check-in contra stay-service: simula el ritmo de
# entrada de vehiculos para la demo (o para un smoke test reproducible en
# CI). Corre ./scripts/seed-demo-data.sh antes, o no habra plazas/tarifas.
#
# Va contra Kong con un token real (ver scripts/lib/demo-auth.sh), que se
# renueva solo: el lifespan del realm son 300s y una tanda larga los pasa.
#
# Uso:
#   ./scripts/checkin-traffic.sh                    # 20 check-ins, matriculas aleatorias
#   COUNT=50 MIN_DELAY=1 MAX_DELAY=3 ./scripts/checkin-traffic.sh
#   PLATES="1234ABC 5678XYZ 9012DEF" ./scripts/checkin-traffic.sh
#
set -euo pipefail

# shellcheck source=lib/demo-auth.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/demo-auth.sh"

COUNT="${COUNT:-20}"
MIN_DELAY="${MIN_DELAY:-2}"
MAX_DELAY="${MAX_DELAY:-5}"
TYPES=(CAR CAR MOTORBIKE CAR_PMR)  # CAR con mas peso: es lo que mas se siembra

random_plate() {
  printf "%04d%s\n" "$((RANDOM % 10000))" \
    "$(tr -dc 'A-Z' </dev/urandom | head -c3)"
}

ok=0
fail=0

require_kong

if [ -n "${PLATES:-}" ]; then
  read -r -a plates <<<"$PLATES"
else
  plates=()
  for _ in $(seq 1 "$COUNT"); do
    plates+=("$(random_plate)")
  done
fi

echo "==> ${#plates[@]} check-ins contra $KONG_URL/api/v1/stays (delay ${MIN_DELAY}-${MAX_DELAY}s, como $DEMO_USER)"

for plate in "${plates[@]}"; do
  type="${TYPES[$((RANDOM % ${#TYPES[@]}))]}"
  response=$(curl -s -w '\n%{http_code}' -X POST "$KONG_URL/api/v1/stays/check-in" \
    -H "$(auth_header)" \
    -H "Content-Type: application/json" \
    -d "{\"plate\":\"$plate\",\"vehicleType\":\"$type\"}")
  status="${response##*$'\n'}"
  body="${response%$'\n'*}"

  ts="$(date '+%H:%M:%S')"
  if [ "$status" = "201" ]; then
    ok=$((ok + 1))
    echo "[$ts] OK   $plate ($type) -> $status"
  else
    fail=$((fail + 1))
    echo "[$ts] FAIL $plate ($type) -> $status $body"
  fi

  sleep $((RANDOM % (MAX_DELAY - MIN_DELAY + 1) + MIN_DELAY))
done

echo "==> $ok ok, $fail fallidos de ${#plates[@]}"

# El 400 "La matricula no es valida" de stay-service enmascara un 401: stay no
# manda Authorization en sus llamadas salientes a vehicle-service. Es bug de
# stay-service, no de este script ni del token de aqui. Ver la nota E2E del
# 30/07 en el vault y el issue vehicleService#50.
if [ "$fail" -gt 0 ] && [ "$ok" -eq 0 ]; then
  echo "AVISO: 0 exitos. Si el cuerpo dice \"La matricula ... no es valida\", es el" >&2
  echo "       bug conocido de stay-service (no propaga el token), no tu token." >&2
fi
