#!/usr/bin/env bash
#
# Levanta el entorno local de DEV completo: red compartida, Postgres unico
# (5 schemas), pgAdmin y SonarQube. Detalle: Obsidian Tartis-Recon-IA.
#
# El Postgres DEDICADO de cada microservicio (perfil prod / servicio
# aislado) vive en el repo de ese servicio, con su propio ./setup.sh.
#
#   ./setup.sh          levanta todo
#   ./setup.sh down     para los contenedores (mantiene los datos)
#   ./setup.sh clean    para los contenedores y BORRA los datos
#
set -euo pipefail

# Ejecutarse siempre desde la raiz del repo, se lance desde donde se lance.
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NETWORK="parking-shared"

if [ -t 1 ]; then
  RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; BOLD=$'\e[1m'; OFF=$'\e[0m'
else
  RED=""; GREEN=""; YELLOW=""; BOLD=""; OFF=""
fi

info() { echo "${BOLD}==>${OFF} $1"; }
ok()   { echo "  ${GREEN}OK${OFF}   $1"; }
warn() { echo "  ${YELLOW}!${OFF}    $1"; }
die()  { echo "  ${RED}ERROR${OFF} $1" >&2; exit 1; }

# --- Comprobaciones previas -------------------------------------------------

command -v docker >/dev/null 2>&1 || die "Docker no esta instalado o no esta en el PATH."

docker compose version >/dev/null 2>&1 \
  || die "Necesitas Docker Compose v2 ('docker compose', no 'docker-compose')."

docker info >/dev/null 2>&1 \
  || die "El demonio de Docker no responde. Arranca Docker Desktop y reintenta."

# --- Parar / limpiar --------------------------------------------------------

case "${1:-up}" in
  down|clean)
    FLAG=""
    [ "${1}" = "clean" ] && FLAG="-v"
    info "Parando contenedores"
    docker compose down $FLAG || true
    [ "${1}" = "clean" ] && warn "Datos de la BD borrados."
    ok "Hecho."
    exit 0
    ;;
  up) ;;
  *) die "Opcion desconocida: '$1'. Usa: up | down | clean" ;;
esac

# --- 1. Red compartida ------------------------------------------------------

info "Red compartida '$NETWORK'"
if docker network inspect "$NETWORK" >/dev/null 2>&1; then
  ok "Ya existe."
else
  docker network create "$NETWORK" >/dev/null
  ok "Creada."
fi

# --- 2. Fichero .env --------------------------------------------------------

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

# --- 3. Levantar contenedores -----------------------------------------------

info "Herramientas compartidas (Postgres de dev + pgAdmin + SonarQube)"
docker compose up -d

# --- 4. Esperar a que esten sanos -------------------------------------------

# SonarQube tarda porque levanta un Elasticsearch dentro.
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

info "Esperando a los servicios"
FAILED=0
wait_healthy parking-dev-postgres 60  || FAILED=1
wait_healthy parking-pgadmin      60  || FAILED=1
wait_healthy parking-sonarqube    240 || FAILED=1

# --- 5. Resumen -------------------------------------------------------------

echo
if [ "$FAILED" -eq 0 ]; then
  info "${GREEN}Entorno listo${OFF}"
else
  info "${YELLOW}Entorno levantado con avisos${OFF} (revisa los mensajes de arriba)"
fi

cat <<EOF

  pgAdmin      http://localhost:${PGADMIN_PORT:-5050}
  SonarQube    http://localhost:${SONARQUBE_PORT:-9000}   (admin / admin)

  Postgres de dev (schemas: vehicle, spot, tariff, ticket, stay)
    desde tu maquina    localhost:${DB_PORT:-5432}
    desde pgAdmin       parking-dev-postgres:5432

  Parar:   ./setup.sh down       Parar y borrar datos:  ./setup.sh clean
EOF

exit "$FAILED"
