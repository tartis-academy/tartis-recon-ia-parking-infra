#!/usr/bin/env bash
#
# Deja la BD de DEV lista para trabajar sin tocar nada a mano:
#
#   1. levanta SOLO el Postgres compartido (sin pgAdmin),
#   2. asegura los 5 schemas (vehicle, spot, tariff, ticket, stay),
#   3. escribe las credenciales DB_* en el .env de cada microservicio.
#
# El paso 3 es el que ahorra el trabajo manual: los application-dev.properties
# de los 5 servicios leen ${DB_HOST}/${DB_PORT}/${DB_NAME}/${DB_USER}/
# ${DB_PASSWORD}, y su application.properties importa el .env del modulo
# (spring.config.import=optional:file:.env[.properties]). Generando ese .env
# no hay que tocar ningun fichero versionado: el servicio arranca apuntando a
# este Postgres aunque cambies la contrasena o el puerto en el .env de infra.
#
# Detalle: Obsidian Tartis-Recon-IA.
#
#   ./dev-db.sh          levanta el Postgres y sincroniza los .env
#   ./dev-db.sh sync     solo sincroniza los .env (no toca contenedores)
#   ./dev-db.sh down     para el Postgres (mantiene los datos)
#   ./dev-db.sh clean    para el Postgres y BORRA los datos
#
# Para levantar ademas pgAdmin: ./setup.sh
#
# Los repos de los microservicios se buscan como hermanos de este repo. Si los
# tienes en otro sitio: PARKING_ROOT=/ruta/a/los/repos ./dev-db.sh
#
set -euo pipefail

# Ejecutarse siempre desde la raiz del repo, se lance desde donde se lance.
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NETWORK="parking-shared"
CONTAINER="parking-dev-postgres"
SERVICE="postgres-dev"
VOLUME_NAME="parking-dev-postgres-data"
SERVICES="vehicle spot tariff ticket stay"
ROOT="${PARKING_ROOT:-$(cd .. && pwd)}"

# Marcadores del bloque que genera este script dentro del .env de cada
# servicio. Todo lo que haya fuera de ellos (p.ej. las VEHICLE_DB_* del
# Postgres dedicado) se respeta tal cual.
MARK_START="# >>> tartis dev-db (generado por infra/dev-db.sh, no editar) >>>"
MARK_END="# <<< tartis dev-db <<<"

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

ACTION="${1:-up}"
case "$ACTION" in
  up|sync|down|clean) ;;
  *) die "Opcion desconocida: '$1'. Usa: up | sync | down | clean" ;;
esac

# --- Parar / limpiar --------------------------------------------------------

if [ "$ACTION" = "down" ] || [ "$ACTION" = "clean" ]; then
  info "Parando $CONTAINER"
  docker compose -f docker-compose.yml -f docker-compose.dev.yml rm -sf "$SERVICE" >/dev/null 2>&1 || true
  ok "Parado (pgAdmin sigue como estaba)."

  if [ "$ACTION" = "clean" ]; then
    # 'docker compose down -v' borraria tambien el volumen de pgAdmin,
    # asi que quitamos solo el volumen de datos de este Postgres.
    VOL="$(docker volume ls -q --filter "name=${VOLUME_NAME}$" | head -n1)"
    if [ -n "$VOL" ]; then
      docker volume rm "$VOL" >/dev/null
      warn "Datos de la BD borrados ($VOL)."
    else
      warn "No habia volumen de datos que borrar."
    fi
  fi
  exit 0
fi

# --- 1. Fichero .env de infra -----------------------------------------------

info "Fichero .env de infra"
if [ -f .env ]; then
  ok ".env ya existe, no lo toco."
elif [ -f .env.example ]; then
  cp .env.example .env
  ok ".env creado desde .env.example."
  warn "Lleva contrasenas 'change.me'. Cambialas si esto no es tu portatil."
else
  die "Falta .env.example"
fi

# Leemos el valor sin ejecutar el fichero (un .env no es un script). Nos
# quedamos con la ultima aparicion de la clave, que es la que gana en compose.
env_value() {
  local key="$1" default="${2:-}" value
  value="$(sed -n "s/^[[:space:]]*${key}=//p" .env | tail -n1)"
  value="${value%$'\r'}"                        # ficheros guardados en CRLF
  value="${value%\"}"; value="${value#\"}"      # comillas alrededor del valor
  value="${value%\'}"; value="${value#\'}"
  [ -n "$value" ] && printf '%s' "$value" || printf '%s' "$default"
}

DB_NAME="$(env_value DB_NAME parking_dev)"
DB_USER="$(env_value DB_USER parking_dev)"
DB_PASSWORD="$(env_value DB_PASSWORD change.me)"
DB_PORT="$(env_value DB_PORT 5432)"

[ -n "$DB_PASSWORD" ] || die "DB_PASSWORD esta vacio en .env."

# El .env del servicio lo parsea Spring como .properties, donde '\' escapa al
# caracter siguiente: una contrasena con backslash llegaria distinta a Spring.
case "$DB_PASSWORD" in
  *\\*) warn "DB_PASSWORD lleva '\\'; Spring lo interpreta como escape. Evitalo." ;;
esac

# --- 2. Red compartida ------------------------------------------------------

if [ "$ACTION" = "up" ]; then
  info "Red compartida '$NETWORK'"
  if docker network inspect "$NETWORK" >/dev/null 2>&1; then
    ok "Ya existe."
  else
    docker network create "$NETWORK" >/dev/null
    ok "Creada."
  fi

  # --- 3. Levantar solo el Postgres -----------------------------------------

  info "Postgres compartido de dev"
  docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d "$SERVICE"

  printf "  ...  esperando a %s " "$CONTAINER"
  WAITED=0
  while :; do
    STATE="$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}nohealth{{end}}' "$CONTAINER" 2>/dev/null || echo "missing")"
    case "$STATE" in
      healthy)  echo; ok "$CONTAINER healthy (${WAITED}s)"; break ;;
      nohealth) echo; ok "$CONTAINER arrancado (sin healthcheck)"; break ;;
      missing)  echo; die "$CONTAINER no existe. Mira: docker compose logs $SERVICE" ;;
    esac
    [ "$WAITED" -ge 60 ] && { echo; die "$CONTAINER sigue sin estar healthy tras ${WAITED}s. Mira: docker logs $CONTAINER"; }
    printf "."
    sleep 2; WAITED=$((WAITED + 2))
  done

  # --- 4. Credenciales reales del contenedor --------------------------------

  # POSTGRES_USER/PASSWORD del compose solo se aplican al CREAR el volumen de
  # datos. Si alguien cambia DB_PASSWORD en el .env con el volumen ya creado,
  # el contenedor sigue con la contrasena vieja y los servicios fallarian con
  # "password authentication failed" sin pista de por que. Lo detectamos aqui.
  # Ojo: -h 127.0.0.1 NO sirve - el pg_hba.conf de esta imagen trata
  # 127.0.0.1/32 como 'trust' (no comprueba password), igual que el socket
  # unix. Hay que conectar por la IP real del contenedor en la red Docker,
  # que cae en la regla 'host all all all scram-sha-256' y si la exige.
  info "Credenciales del contenedor"
  CONTAINER_IP="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$CONTAINER")"
  if [ -z "$CONTAINER_IP" ]; then
    warn "No se pudo resolver la IP de $CONTAINER, me salto la comprobacion."
  elif docker exec -e PGPASSWORD="$DB_PASSWORD" "$CONTAINER" \
       psql -h "$CONTAINER_IP" -U "$DB_USER" -d "$DB_NAME" -q -tAc "select 1" >/dev/null 2>&1; then
    ok "Coinciden con el .env."
  else
    die "El Postgres no acepta DB_USER/DB_PASSWORD del .env: el volumen de datos
        se creo con otras credenciales. Para aplicarlas hay que recrearlo (BORRA
        LOS DATOS DE DEV):  ./dev-db.sh clean && ./dev-db.sh"
  fi

  # --- 5. Schemas -----------------------------------------------------------

  # init-dev-schemas.sql solo lo ejecuta Postgres al crear el volumen: si el
  # volumen ya existia de antes (o se anade un schema nuevo), no se aplica.
  # Es idempotente (CREATE SCHEMA IF NOT EXISTS), asi que lo lanzamos siempre.
  info "Schemas de los microservicios"
  docker exec -i -e PGOPTIONS="--client-min-messages=warning" "$CONTAINER" \
    psql -v ON_ERROR_STOP=1 -q -U "$DB_USER" -d "$DB_NAME" \
    < init-dev-schemas.sql \
    || die "No se pudieron crear los schemas. Mira: docker logs $CONTAINER"
  ok "vehicle, spot, tariff, ticket, stay listos."
fi

# --- 6. Sincronizar el .env de cada microservicio ---------------------------

info "Credenciales en los .env de los microservicios"

FOUND=0
MISSING=""

for NAME in $SERVICES; do
  # Glob en vez de ruta fija: los repos de servicio son '...-ai-...' y este es
  # '...-ia-...', y el nombre del repo puede variar.
  MODULE=""
  for CANDIDATE in "$ROOT"/*"${NAME}Service"/backend/"${NAME}-service"; do
    [ -f "$CANDIDATE/pom.xml" ] && { MODULE="$CANDIDATE"; break; }
  done

  if [ -z "$MODULE" ]; then
    MISSING="$MISSING $NAME"
    continue
  fi

  FOUND=$((FOUND + 1))
  TARGET="$MODULE/.env"

  # Reescribimos solo nuestro bloque; el resto del fichero se queda igual.
  TMP="$(mktemp)"
  if [ -f "$TARGET" ]; then
    awk -v s="$MARK_START" -v e="$MARK_END" '
      $0 == s { skip = 1; next }
      $0 == e { skip = 0; next }
      !skip   { print }
    ' "$TARGET" > "$TMP"
    # Sin linea en blanco final duplicada si el bloque estaba al final.
    while [ -s "$TMP" ] && [ -z "$(tail -n1 "$TMP")" ]; do
      sed -i '$ d' "$TMP"
    done
    [ -s "$TMP" ] && printf '\n' >> "$TMP"
  fi

  {
    echo "$MARK_START"
    echo "# Postgres compartido de dev: lo levanta infra/dev-db.sh y lo leen"
    echo "# los application-dev.properties de este servicio."
    echo "DB_HOST=localhost"
    echo "DB_PORT=${DB_PORT}"
    echo "DB_NAME=${DB_NAME}"
    echo "DB_USER=${DB_USER}"
    echo "DB_PASSWORD=${DB_PASSWORD}"
    echo "$MARK_END"
  } >> "$TMP"

  if [ -f "$TARGET" ] && cmp -s "$TMP" "$TARGET"; then
    rm -f "$TMP"
    ok "$NAME  ya estaba al dia"
  else
    mv "$TMP" "$TARGET"
    chmod 600 "$TARGET"
    ok "$NAME  ${TARGET#$ROOT/}"
  fi

  # Un .env con credenciales no deberia acabar en git.
  if git -C "$MODULE" rev-parse --git-dir >/dev/null 2>&1; then
    git -C "$MODULE" check-ignore -q .env 2>/dev/null \
      || warn "$NAME: .env NO esta en .gitignore. Anadelo antes de commitear."
  fi
done

[ "$FOUND" -gt 0 ] || die "No encontre ningun repo de microservicio en '$ROOT'. Usa PARKING_ROOT=/ruta ./dev-db.sh"
[ -n "$MISSING" ] && warn "Sin repo clonado en '$ROOT':$MISSING"

# --- 7. Resumen -------------------------------------------------------------

echo
if [ "$ACTION" = "sync" ]; then
  info "${GREEN}Ficheros .env sincronizados${OFF}"
else
  info "${GREEN}BD de dev lista${OFF}"
fi

cat <<EOF

  Postgres    localhost:${DB_PORT}  ·  ${DB_NAME}  ·  usuario ${DB_USER}
  Schemas     vehicle, spot, tariff, ticket, stay

  Los ${FOUND} servicios encontrados ya tienen sus credenciales en el .env del
  modulo: arrancalos sin configurar nada.

    cd <repo-servicio>/backend/<x>-service && ./mvnw spring-boot:run

  Si cambias el .env de infra, vuelve a lanzar:  ./dev-db.sh sync
  pgAdmin:  ./setup.sh
  Parar:  ./dev-db.sh down      Parar y borrar datos:  ./dev-db.sh clean
EOF
