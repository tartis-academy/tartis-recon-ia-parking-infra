#!/usr/bin/env bash
#
# Levanta / para el stack completo de DEMO (plataforma Keycloak/RabbitMQ/Kong
# + los 5 microservicios + mfe-entryexit + frontend, cada microservicio con su
# Postgres dedicada) y espera a que todos los healthcheck se pongan en verde
# antes de devolver el control. Combina docker-compose.yml y
# docker-compose.demo.yml con el .env unificado (no .env.demo).
#
# Al terminar siembra datos de demo (50 plazas: 20 CAR, 20 MOTORBIKE, 10
# CAR_PMR, mas una tarifa activa por tipo) con scripts/seed-demo-data.sh, que es
# idempotente: rellena hasta el cupo, no duplica en arranques sucesivos.
#
# Uso:
#   ./demo-stack.sh up              levanta, espera healthchecks y siembra
#   ./demo-stack.sh up --no-seed       igual, sin sembrar datos
#   ./demo-stack.sh up --no-frontend   igual, sin el contenedor del frontend
#   ./demo-stack.sh down            para los contenedores (mantiene datos)
#   ./demo-stack.sh down --clean    para y BORRA los volumenes de datos
#   ./demo-stack.sh status          solo informa del estado actual
#   ./demo-stack.sh restart <servicio>   rebuild + recreate de un servicio suelto
#   ./demo-stack.sh info            puertos/URLs del stack + estado actual
#
set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

COMPOSE_FILES=(-f docker-compose.yml -f docker-compose.demo.yml)
ENV_FILE=".env"
NETWORK="parking-shared"

# Orden con dependencias primero: cada -db antes que su -service, plataforma
# antes que los micros (aunque Compose ya resuelve el grafo solo).
ALL_SERVICES=(keycloak-db keycloak rabbitmq kong
              vehicle-db vehicle-service spot-db spot-service tariff-db tariff-service
              ticket-db ticket-service stay-db stay-service mfe-entryexit mfe-admin frontend)
CONTAINERS=(parking-keycloak-db parking-keycloak parking-rabbitmq parking-kong
            parking-vehicle-db parking-vehicle-service parking-spot-db parking-spot-service
            parking-tariff-db parking-tariff-service parking-ticket-db parking-ticket-service
            parking-stay-db parking-stay-service parking-mfe-entryexit parking-mfe-admin parking-frontend)

if [ -t 1 ]; then
  RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; BOLD=$'\e[1m'; OFF=$'\e[0m'
else
  RED=""; GREEN=""; YELLOW=""; BOLD=""; OFF=""
fi

info() { echo "${BOLD}==>${OFF} $1"; }
ok()   { echo "  ${GREEN}OK${OFF}   $1"; }
warn() { echo "  ${YELLOW}!${OFF}    $1"; }
die()  { echo "  ${RED}ERROR${OFF} $1" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || die "Docker no esta instalado o no esta en el PATH."
docker compose version >/dev/null 2>&1 || die "Necesitas Docker Compose v2 ('docker compose')."
docker info >/dev/null 2>&1 || die "El demonio de Docker no responde. Arranca Docker y reintenta."

wait_healthy() {
  local name="$1" timeout="${2:-120}" waited=0
  printf "  ...  esperando a %s " "$name"
  while [ "$waited" -lt "$timeout" ]; do
    local state
    state="$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}nohealth{{end}}' "$name" 2>/dev/null || echo "missing")"
    case "$state" in
      healthy)  echo; ok "$name healthy (${waited}s)"; return 0 ;;
      nohealth) echo; ok "$name arrancado (sin healthcheck)"; return 0 ;;
      missing)  echo; warn "$name no existe."; return 1 ;;
      unhealthy) : ;; # puede ser transitorio en el primer ciclo, seguir esperando
    esac
    printf "."
    sleep 2; waited=$((waited + 2))
  done
  echo
  warn "$name sigue sin estar healthy tras ${timeout}s. Mira: docker logs $name"
  return 1
}

print_status() {
  info "Estado de los contenedores"
  local args=(-a) c
  for c in "${CONTAINERS[@]}"; do
    args+=(--filter "name=^${c}\$")
  done
  local rows
  rows="$(docker ps "${args[@]}" --format '{{.Names}}\t{{.Status}}')"
  if [ -z "$rows" ]; then
    warn "No hay contenedores del stack de demo levantados."
    return
  fi
  printf 'NAMES\tSTATUS\n%s\n' "$rows" | column -t -s $'\t'
}

cmd_up() {
  local services=("${ALL_SERVICES[@]}")
  local containers=("${CONTAINERS[@]}")
  local seed=1
  local args=() a
  for a in "$@"; do
    if [ "$a" = "--no-seed" ]; then seed=0; else args+=("$a"); fi
  done
  set -- ${args[@]+"${args[@]}"}
  if [ "${1:-}" = "--no-frontend" ]; then
    local filtered=() s
    for s in "${services[@]}"; do
      [ "$s" = "frontend" ] || filtered+=("$s")
    done
    services=("${filtered[@]}")
    filtered=()
    for s in "${containers[@]}"; do
      [ "$s" = "parking-frontend" ] || filtered+=("$s")
    done
    containers=("${filtered[@]}")
    warn "Levantando sin frontend (--no-frontend)."
  fi

  [ -f "$ENV_FILE" ] || die "Falta $ENV_FILE. Copia .env.example -> $ENV_FILE primero."

  info "Red compartida '$NETWORK'"
  if docker network inspect "$NETWORK" >/dev/null 2>&1; then
    ok "Ya existe."
  else
    docker network create "$NETWORK" >/dev/null
    ok "Creada."
  fi

  info "Build + up (${#services[@]} servicios)"
  # shellcheck disable=SC2068
  docker compose "${COMPOSE_FILES[@]}" --env-file "$ENV_FILE" up --build -d ${services[@]}

  info "Esperando healthchecks"
  local failed=0
  for c in "${containers[@]}"; do
    [ -z "$c" ] && continue
    wait_healthy "$c" 120 || failed=1
  done

  echo
  print_status
  echo

  # Sembrar despues de los healthchecks: el seed va por Kong y necesita
  # keycloak, spot-service y tariff-service arriba. Es idempotente, asi que
  # repetirlo en cada `up` no multiplica los datos.
  if [ "$seed" -eq 1 ] && [ "$failed" -eq 0 ]; then
    info "Sembrando datos de demo"
    if ./scripts/seed-demo-data.sh; then
      echo
    else
      warn "El seed fallo. El stack esta arriba; reintenta con ./scripts/seed-demo-data.sh"
      echo
    fi
  elif [ "$seed" -eq 0 ]; then
    warn "Seed omitido (--no-seed)."
    echo
  fi

  if [ "$failed" -eq 0 ]; then
    info "${GREEN}Stack de demo listo${OFF}"
  else
    info "${YELLOW}Stack levantado con avisos${OFF} (revisa los mensajes de arriba)"
  fi
}

cmd_down() {
  local flag=""
  if [ "${1:-}" = "--clean" ]; then
    flag="-v"
    warn "Se van a borrar los volumenes de datos de la demo."
  fi
  info "Parando el stack de demo"
  # shellcheck disable=SC2086
  docker compose "${COMPOSE_FILES[@]}" --env-file "$ENV_FILE" down $flag
  ok "Hecho."
}

cmd_info() {
  if [ -f "$ENV_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
  fi

  info "Puertos y URLs del stack de demo"
  cat <<EOF
  frontend          http://localhost:${FRONTEND_PORT:-8090}
  kong (proxy)      http://localhost:${KONG_PROXY_PORT:-8000}   -> /api/v1/{vehicles,spots,tariffs,tickets,stays}
  kong (admin API)  http://127.0.0.1:${KONG_ADMIN_PORT:-8001}   (solo local)
  keycloak          http://localhost:${KEYCLOAK_PORT:-8180}
  rabbitmq          http://localhost:${RABBITMQ_MGMT_PORT:-15672}
EOF
  echo "  (GW-07: vehicle/spot/tariff/ticket/stay-service no publican puerto propio,"
  echo "   solo son alcanzables via Kong o red interna. mfe-entryexit igual, via Kong."
  echo "   pgAdmin y el Postgres de dev son de docker-compose.dev.yml, no de la demo.)"
  echo
  print_status
}

cmd_restart() {
  local service="${1:-}"
  [ -n "$service" ] || die "Uso: $0 restart <servicio> (ej: ticket-service)"
  info "Rebuild + recreate de '$service'"
  docker compose "${COMPOSE_FILES[@]}" --env-file "$ENV_FILE" up --build -d "$service"
  local container="parking-${service}"
  wait_healthy "$container" 120 || true
}

case "${1:-}" in
  up)      shift; cmd_up "$@" ;;
  down)    shift; cmd_down "${1:-}" ;;
  status)  print_status ;;
  restart) shift; cmd_restart "${1:-}" ;;
  info|-info|--info) cmd_info ;;
  *) die "Uso: $0 {up [--no-frontend] [--no-seed] | down [--clean] | status | restart <servicio> | info}" ;;
esac
