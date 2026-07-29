#!/usr/bin/env bash
#
# Levanta el entorno local. Detalle: Obsidian Tartis-Recon-IA.
#
set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NETWORK="parking-shared"
COMPOSE_DEV=(docker compose -f docker-compose.yml -f docker-compose.dev.yml)
COMPOSE_FULL=(docker compose -f docker-compose.yml -f docker-compose.demo.yml)
COMPOSE_ALL=(docker compose -f docker-compose.yml -f docker-compose.dev.yml -f docker-compose.demo.yml)
ALL_MICROS="vehicle spot tariff ticket stay"
PASSWORD_KEYS="DB_PASSWORD PGADMIN_PASSWORD KEYCLOAK_DB_PASSWORD KEYCLOAK_ADMIN_PASSWORD RABBITMQ_PASSWORD"

if [ -t 1 ]; then
  RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; CYAN=$'\e[36m'; BOLD=$'\e[1m'; OFF=$'\e[0m'
else
  RED=""; GREEN=""; YELLOW=""; CYAN=""; BOLD=""; OFF=""
fi

info() { echo "${CYAN}${BOLD}==>${OFF} $1"; }
ok()   { echo "  ${GREEN}OK${OFF}   $1"; }
warn() { echo "  ${YELLOW}!${OFF}    $1"; }
die()  { echo "  ${RED}ERROR${OFF} $1" >&2; exit 1; }

usage() {
  cat <<EOF
Uso: ./setup.sh [opciones]

Modos (uno como mucho, por defecto plataforma + BD de dev + pgAdmin):
  -f            stack completo: plataforma + 5 microservicios + frontend
  -d            para los contenedores (mantiene los datos)
  -c            para los contenedores y BORRA los datos

Otras opciones:
  -s <lista>    con -f, levanta solo estos servicios (coma-separados):
                vehicle,spot,tariff,ticket,stay,frontend
                (cada uno arrastra su propia BD y sus dependencias)
  -y            no preguntes contrasena, usa los defaults de .env.example
  -h            esta ayuda

Ejemplos:
  ./setup.sh
  ./setup.sh -f
  ./setup.sh -f -s vehicle,spot
  ./setup.sh -d
  ./setup.sh -c
EOF
}

MODE="up"
MODE_FLAGS=0
SUBSET=""
NONINTERACTIVE=0

while getopts ":fdcs:yh" opt; do
  case "$opt" in
    f) MODE="full"; MODE_FLAGS=$((MODE_FLAGS + 1)) ;;
    d) MODE="down"; MODE_FLAGS=$((MODE_FLAGS + 1)) ;;
    c) MODE="clean"; MODE_FLAGS=$((MODE_FLAGS + 1)) ;;
    s) SUBSET="$OPTARG" ;;
    y) NONINTERACTIVE=1 ;;
    h) usage; exit 0 ;;
    \?) usage; die "Opcion desconocida: -$OPTARG" ;;
    :)  usage; die "-$OPTARG necesita un valor" ;;
  esac
done

[ "$MODE_FLAGS" -le 1 ] || die "Usa como mucho un modo (-f/-d/-c) a la vez."
[ -z "$SUBSET" ] || [ "$MODE" = "full" ] || die "-s solo tiene sentido con -f."

command -v docker >/dev/null 2>&1 || die "Docker no esta instalado o no esta en el PATH."

docker compose version >/dev/null 2>&1 \
  || die "Necesitas Docker Compose v2 ('docker compose', no 'docker-compose')."

docker info >/dev/null 2>&1 \
  || die "El demonio de Docker no responde. Arranca Docker Desktop y reintenta."

if [ "$MODE" = "down" ] || [ "$MODE" = "clean" ]; then
  FLAG=""
  [ "$MODE" = "clean" ] && FLAG="-v"
  info "Parando contenedores"
  "${COMPOSE_ALL[@]}" down $FLAG || true
  [ "$MODE" = "clean" ] && warn "Datos de la BD borrados."
  ok "Hecho."
  exit 0
fi

info "Red compartida '$NETWORK'"
if docker network inspect "$NETWORK" >/dev/null 2>&1; then
  ok "Ya existe."
else
  docker network create "$NETWORK" >/dev/null
  ok "Creada."
fi

# Escapa \, & y | para poder meter la password en un reemplazo sed con
# delimitador '|' sin que reviente si el usuario mete alguno de esos.
sed_escape() { printf '%s' "$1" | sed -e 's/[\&|]/\\&/g'; }

ask_master_password() {
  [ -t 0 ] || return 0
  echo
  read -r -p "  Contrasena propia para Postgres/pgAdmin/Keycloak/RabbitMQ en vez de 'change.me'? [s/N] " REPLY
  case "$REPLY" in
    s|S|si|Si|SI|y|Y) ;;
    *) return 0 ;;
  esac

  local pass="" pass2="" attempts=0
  while :; do
    attempts=$((attempts + 1))
    read -r -s -p "  Contrasena: " pass; echo
    read -r -s -p "  Repite:     " pass2; echo
    [ -n "$pass" ] && [ "$pass" = "$pass2" ] && break
    [ "$attempts" -ge 3 ] && { warn "No coinciden tras 3 intentos, me quedo con 'change.me'."; return 0; }
    warn "No coinciden o esta vacia, prueba otra vez."
  done

  local esc_pass; esc_pass="$(sed_escape "$pass")"
  for key in $PASSWORD_KEYS; do
    sed -i "s|^${key}=.*|${key}=${esc_pass}|" .env
  done

  echo
  echo "  ${YELLOW}${BOLD}Apunta esta contrasena, la necesitaras para pgAdmin/Keycloak/RabbitMQ:${OFF}"
  echo "  ${BOLD}${pass}${OFF}"
  echo
}

info "Fichero .env"
if [ -f .env ]; then
  ok ".env ya existe, no lo toco."
elif [ -f .env.example ]; then
  cp .env.example .env
  ok ".env creado desde .env.example."
  if [ "$NONINTERACTIVE" -eq 1 ]; then
    warn "Lleva contrasenas 'change.me'. Usa sin -y para elegir la tuya."
  else
    ask_master_password
  fi
else
  die "Falta .env.example"
fi
set -a; source .env; set +a

wait_healthy() {
  local name="$1" timeout="$2" waited=0
  printf "  ...  esperando a %s%s%s " "$CYAN" "$name" "$OFF"
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

wait_running_containers() {
  local compose_ref="$1"
  local -n compose_arr="$compose_ref"
  local names
  names="$("${compose_arr[@]}" ps --format '{{.Name}}' 2>/dev/null)"
  [ -n "$names" ] || return 0
  while IFS= read -r name; do
    wait_healthy "$name" 90 || FAILED=1
  done <<< "$names"
}

FAILED=0

if [ "$MODE" = "up" ]; then
  info "Plataforma (Keycloak, Kong, RabbitMQ, Postgres dev, pgAdmin)"
  "${COMPOSE_DEV[@]}" up -d

  info "Esperando a los servicios"
  wait_running_containers COMPOSE_DEV
else
  TARGETS=()
  if [ -n "$SUBSET" ]; then
    TARGETS+=("kong")
    IFS=',' read -ra REQUESTED <<< "$SUBSET"
    for name in "${REQUESTED[@]}"; do
      case "$name" in
        vehicle|spot|tariff|ticket|stay) TARGETS+=("${name}-service") ;;
        frontend) TARGETS+=("frontend") ;;
        *) die "Servicio desconocido en -s: '$name'. Usa: ${ALL_MICROS// /,},frontend" ;;
      esac
    done
    info "Stack parcial (kong + ${REQUESTED[*]})"
  else
    info "Stack completo (plataforma + 5 microservicios + frontend)"
  fi
  "${COMPOSE_FULL[@]}" up -d --build "${TARGETS[@]}"

  info "Esperando a los servicios"
  wait_running_containers COMPOSE_FULL
fi

echo
if [ "$FAILED" -eq 0 ]; then
  info "${GREEN}Entorno listo${OFF}"
else
  info "${YELLOW}Entorno levantado con avisos${OFF} (revisa los mensajes de arriba)"
fi

cat <<EOF

  ${BOLD}Keycloak${OFF}     http://localhost:${KEYCLOAK_PORT:-8180}    (${KEYCLOAK_ADMIN_USER:-admin} / tu .env)
  ${BOLD}RabbitMQ${OFF}     http://localhost:${RABBITMQ_MGMT_PORT:-15672}   (${RABBITMQ_USER:-parking} / tu .env)
  ${BOLD}Kong proxy${OFF}   http://localhost:${KONG_PROXY_PORT:-8000}
  ${BOLD}Kong admin${OFF}   http://localhost:${KONG_ADMIN_PORT:-8001}   (solo 127.0.0.1)
EOF

if [ "$MODE" = "up" ]; then
  cat <<EOF
  ${BOLD}pgAdmin${OFF}      http://localhost:${PGADMIN_PORT:-5050}

  Postgres de dev (schemas: vehicle, spot, tariff, ticket, stay)
    desde tu maquina    localhost:${DB_PORT:-5432}
    desde pgAdmin       parking-dev-postgres:5432
EOF
fi

cat <<EOF

  Parar:   ./setup.sh -d       Parar y borrar datos:  ./setup.sh -c       Ayuda: ./setup.sh -h
EOF

exit "$FAILED"
