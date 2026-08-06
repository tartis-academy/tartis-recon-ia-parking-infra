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

# Compat con la sintaxis posicional anterior (./setup.sh full|down|clean|up):
# getopts para en el primer argumento que no empiece por '-' y lo deja sin
# mirar, así que sin esto "./setup.sh down" arrancaba el entorno en vez de
# pararlo, en silencio.
case "${1:-}" in
  full)  MODE="full";  MODE_FLAGS=$((MODE_FLAGS + 1)); shift ;;
  down)  MODE="down";  MODE_FLAGS=$((MODE_FLAGS + 1)); shift ;;
  clean) MODE="clean"; MODE_FLAGS=$((MODE_FLAGS + 1)); shift ;;
  up)    shift ;;
esac

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

# Entre comillas simples: 'source .env' (mas abajo) trata el valor como texto
# literal. Sin esto, una password con espacios rompe el source, y una con
# $(...) se ejecutaria como comando.
quote_for_env() {
  local escaped="${1//\'/\'\"\'\"\'}"
  printf "'%s'" "$escaped"
}

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

  local esc_pass; esc_pass="$(sed_escape "$(quote_for_env "$pass")")"
  for key in $PASSWORD_KEYS; do
    sed -i "s|^${key}=.*|${key}=${esc_pass}|" .env
  done

  echo
  echo "  ${YELLOW}${BOLD}Apunta esta contrasena, la necesitaras para pgAdmin/Keycloak/RabbitMQ:${OFF}"
  echo "  ${BOLD}${pass}${OFF}"
  echo
}

# Anade a un .env que ya existe las claves que se hayan incorporado despues a
# .env.example.
#
# No pisar el .env del usuario es lo correcto, pero tiene un efecto colateral:
# quien ya tenia el fichero (o sea, todo el que ejecuto setup alguna vez) no
# se entera nunca de una variable nueva, y re-lanzar setup.sh tampoco se la
# anade. Se vio con STAY_CLIENT_SECRET: en stay-service no tiene valor por
# defecto a proposito, asi que su ausencia no degrada nada, tumba el arranque
# del contenedor entero.
#
# Solo anade lo que falta. Nunca modifica ni reordena lo que ya hay.
backfill_env() {
  [ -f .env.example ] || return 0

  local missing=() key

  # La clave es lo anterior al primer '=', asi que un valor que lleve '='
  # dentro no confunde. Las lineas comentadas no empiezan por letra, se caen
  # solas del patron.
  while IFS= read -r key; do
    if ! grep -qE "^[[:space:]]*${key}=" .env; then
      missing+=("$key")
    fi
  done < <(sed -nE 's/^([A-Za-z_][A-Za-z0-9_]*)=.*/\1/p' .env.example)

  if [ "${#missing[@]}" -eq 0 ]; then
    ok "Sin variables nuevas en .env.example."
    return 0
  fi

  # Si .env no termina en salto de linea, la primera clave que anadamos se
  # pegaria al final de la ultima linea existente.
  if [ -s .env ] && [ -n "$(tail -c1 .env)" ]; then
    printf '\n' >> .env
  fi

  {
    printf '\n# Anadidas por setup.sh (%s) desde .env.example.\n' "$(date +%Y-%m-%d)"
    for key in "${missing[@]}"; do
      grep -m1 -E "^${key}=" .env.example
    done
  } >> .env

  warn "Anadidas ${#missing[@]} variables nuevas a .env: ${missing[*]}"

  # Entran con el valor de .env.example, no con la contrasena que el usuario
  # eligiera en su dia: ask_master_password solo corre al crear el fichero.
  # Si alguna es de las de password, avisar en vez de dejarlo pasar en
  # silencio y que luego el contenedor no autentique.
  local pass_key
  for key in "${missing[@]}"; do
    for pass_key in $PASSWORD_KEYS; do
      if [ "$key" = "$pass_key" ]; then
        warn "$key ha entrado con el valor por defecto de .env.example, revisala."
      fi
    done
  done
}

info "Fichero .env"
if [ -f .env ]; then
  ok ".env ya existe, no lo toco."
  backfill_env
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

# Si el contenedor ya existe (volumen ya creado), POSTGRES_USER/PASSWORD del
# compose no se reaplican - solo valen al crear el volumen. Cambiar la
# password en .env con el volumen ya ahi deja al contenedor con la vieja, y
# los servicios fallarian con "password authentication failed" sin pista.
#
# Ojo: -h 127.0.0.1 NO sirve para esto - el pg_hba.conf de esta imagen trata
# 127.0.0.1/32 como 'trust' (sin comprobar password), igual que el socket
# unix. Hay que conectar por la IP real del contenedor en la red Docker, que
# cae en la regla 'host all all all scram-sha-256' y si exige la password.
check_pg_credentials() {
  local container="$1" user="$2" db="$3" password="$4" ip
  docker inspect "$container" >/dev/null 2>&1 || return 0
  ip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$container")"
  [ -n "$ip" ] || return 0
  docker exec -e PGPASSWORD="$password" "$container" \
    psql -h "$ip" -U "$user" -d "$db" -q -tAc "select 1" >/dev/null 2>&1 \
    || die "$container ya existe con otras credenciales que las del .env
        (el volumen se creo con otras). Para aplicar las nuevas hay que
        recrearlo (BORRA DATOS): ./setup.sh -c && ./setup.sh"
}

info "Credenciales contra volumenes existentes"
check_pg_credentials parking-dev-postgres "${DB_USER:-}" "${DB_NAME:-}" "${DB_PASSWORD:-}"
check_pg_credentials parking-keycloak-db "${KEYCLOAK_DB_USER:-}" "${KEYCLOAK_DB_NAME:-keycloak}" "${KEYCLOAK_DB_PASSWORD:-}"
ok "Coinciden (o los contenedores todavia no existen)."

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

# Sin 'local -n' (nameref, bash >= 4.3) a proposito: macOS trae bash 3.2 de
# serie y el shebang es 'env bash', no bash de Homebrew.
wait_running_containers() {
  local names
  names="$("$@" ps --format '{{.Name}}' 2>/dev/null)"
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
  wait_running_containers "${COMPOSE_DEV[@]}"
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
  wait_running_containers "${COMPOSE_FULL[@]}"
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
