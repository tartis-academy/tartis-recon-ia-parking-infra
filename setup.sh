#!/usr/bin/env bash
#
# Levanta el entorno local. Detalle: Obsidian Tartis-Recon-IA.
#
#   ./setup.sh          plataforma: Postgres dev, pgAdmin, SonarQube, Keycloak, Kong, RabbitMQ
#   ./setup.sh full     lo anterior + los 5 microservicios y el frontend (docker-compose.demo.yml)
#   ./setup.sh down     para los contenedores (mantiene los datos)
#   ./setup.sh clean    para los contenedores y BORRA los datos
#
set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NETWORK="parking-shared"
COMPOSE=(docker compose -f docker-compose.yml -f docker-compose.demo.yml)

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

docker compose version >/dev/null 2>&1 \
  || die "Necesitas Docker Compose v2 ('docker compose', no 'docker-compose')."

docker info >/dev/null 2>&1 \
  || die "El demonio de Docker no responde. Arranca Docker Desktop y reintenta."

MODE="${1:-up}"

case "$MODE" in
  down|clean)
    FLAG=""
    [ "$MODE" = "clean" ] && FLAG="-v"
    info "Parando contenedores"
    "${COMPOSE[@]}" down $FLAG || true
    [ "$MODE" = "clean" ] && warn "Datos de la BD borrados."
    ok "Hecho."
    exit 0
    ;;
  up|full) ;;
  *) die "Opcion desconocida: '$1'. Usa: up | full | down | clean" ;;
esac

info "Red compartida '$NETWORK'"
if docker network inspect "$NETWORK" >/dev/null 2>&1; then
  ok "Ya existe."
else
  docker network create "$NETWORK" >/dev/null
  ok "Creada."
fi

info "Fichero .env"
if [ -f .env ]; then
  ok ".env ya existe, no lo toco."
elif [ -f .env.example ]; then
  cp .env.example .env
  ok ".env creado desde .env.example."
  warn "Lleva contrasenas 'change.me'. Cambialas si esto no es tu portatil."
else
  die "Falta .env.example"
fi
set -a; source .env; set +a

wait_healthy() {
  local name="$1" timeout="$2" waited=0
  printf "  ...  esperando a %s " "$name"
  while [ "$waited" -lt "$timeout" ]; do
    local state
    state="$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}nohealth{{end}}' "$name" 2>/dev/null || echo "missing")"
    case "$state" in
      healthy)  echo; ok "$name healthy (${waited}s)"; return 0 ;;
      nohealth) echo; ok "$name arrancado (sin healthcheck)"; return 0 ;;
      missing)  echo; warn "$name no existe."; return 1 ;;
    esac
    printf "."
    sleep 2; waited=$((waited + 2))
  done
  echo
  warn "$name sigue sin estar healthy tras ${timeout}s. Mira: docker logs $name"
  return 1
}

FAILED=0

if [ "$MODE" = "up" ]; then
  info "Plataforma (Postgres dev, pgAdmin, SonarQube, Keycloak, Kong, RabbitMQ)"
  docker compose -f docker-compose.yml up -d

  info "Esperando a los servicios"
  wait_healthy parking-dev-postgres 60  || FAILED=1
  wait_healthy parking-pgadmin      60  || FAILED=1
  wait_healthy parking-keycloak-db  60  || FAILED=1
  wait_healthy parking-keycloak     90  || FAILED=1
  wait_healthy parking-rabbitmq     60  || FAILED=1
  wait_healthy parking-kong         30  || FAILED=1
  wait_healthy parking-sonarqube    240 || FAILED=1
else
  info "Stack completo (plataforma + 5 microservicios + frontend)"
  "${COMPOSE[@]}" up -d --build

  info "Esperando a los servicios"
  wait_healthy parking-dev-postgres     60  || FAILED=1
  wait_healthy parking-pgadmin          60  || FAILED=1
  wait_healthy parking-keycloak-db      60  || FAILED=1
  wait_healthy parking-keycloak         90  || FAILED=1
  wait_healthy parking-rabbitmq         60  || FAILED=1
  wait_healthy parking-kong             30  || FAILED=1
  wait_healthy parking-vehicle-db       60  || FAILED=1
  wait_healthy parking-vehicle-service  60  || FAILED=1
  wait_healthy parking-spot-db          60  || FAILED=1
  wait_healthy parking-spot-service     60  || FAILED=1
  wait_healthy parking-tariff-db        60  || FAILED=1
  wait_healthy parking-tariff-service   60  || FAILED=1
  wait_healthy parking-ticket-db        60  || FAILED=1
  wait_healthy parking-ticket-service   60  || FAILED=1
  wait_healthy parking-stay-db          60  || FAILED=1
  wait_healthy parking-stay-service     60  || FAILED=1
  wait_healthy parking-sonarqube        240 || FAILED=1
fi

echo
if [ "$FAILED" -eq 0 ]; then
  info "${GREEN}Entorno listo${OFF}"
else
  info "${YELLOW}Entorno levantado con avisos${OFF} (revisa los mensajes de arriba)"
fi

cat <<EOF

  pgAdmin      http://localhost:${PGADMIN_PORT:-5050}
  SonarQube    http://localhost:${SONARQUBE_PORT:-9000}   (admin / admin)
  Keycloak     http://localhost:${KEYCLOAK_PORT:-8180}    (${KEYCLOAK_ADMIN_USER:-admin} / tu .env)
  RabbitMQ     http://localhost:${RABBITMQ_MGMT_PORT:-15672}   (${RABBITMQ_USER:-parking} / tu .env)
  Kong proxy   http://localhost:${KONG_PROXY_PORT:-8000}
  Kong admin   http://localhost:${KONG_ADMIN_PORT:-8001}   (solo 127.0.0.1)

  Postgres de dev (schemas: vehicle, spot, tariff, ticket, stay)
    desde tu maquina    localhost:${DB_PORT:-5432}
    desde pgAdmin       parking-dev-postgres:5432

  Parar:   ./setup.sh down       Parar y borrar datos:  ./setup.sh clean
EOF

exit "$FAILED"
