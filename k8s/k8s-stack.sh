#!/usr/bin/env bash
#
# Punto de entrada unico del stack sobre Kubernetes (minikube), con la misma
# interfaz que demo-stack.sh para no tener que aprender dos flujos.
#
# Levanta el cluster si hace falta, carga las imagenes en el nodo, sincroniza
# los ConfigMap desde kong/kong.yml y el realm, aplica k8s/, espera a que todos
# los deployments esten Ready, publica 8000 (Kong) y 8180 (Keycloak) en el host
# y siembra los datos de demo con scripts/seed-demo-data.sh.
#
# A diferencia de expose.sh, los port-forward quedan en segundo plano para que
# `up` devuelva el control: se paran con `down` o con `expose --stop`.
#
# Los dos stacks son EXCLUYENTES: el iss de los tokens, los redirect-uri del
# realm y el CORS de kong.yml estan fijados a localhost:8000 / localhost:8180.
# Hay que parar Compose (./demo-stack.sh down) antes de levantar este.
#
# Uso:
#   ./k8s/k8s-stack.sh up               levanta, espera Ready, expone y siembra
#   ./k8s/k8s-stack.sh up --no-seed     igual, sin sembrar datos
#   ./k8s/k8s-stack.sh up --no-expose   igual, sin publicar puertos en el host
#   ./k8s/k8s-stack.sh down             para el cluster (mantiene datos)
#   ./k8s/k8s-stack.sh down --clean     BORRA el cluster entero
#   ./k8s/k8s-stack.sh status           estado de pods, HPA y port-forwards
#   ./k8s/k8s-stack.sh restart <svc>    rollout restart + espera de un deployment
#   ./k8s/k8s-stack.sh expose [--stop]  publica/para los puertos en el host
#   ./k8s/k8s-stack.sh verify           Newman (RECON-822) contra el cluster
#   ./k8s/k8s-stack.sh info             puertos/URLs + estado actual
#
set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.."

PROFILE="${MINIKUBE_PROFILE:-parking}"
NS=parking
KONG_PORT="${KONG_PORT:-8000}"
KEYCLOAK_PORT="${KEYCLOAK_PORT:-8180}"
PF_DIR="${TMPDIR:-/tmp}/parking-k8s-portforward"

DEPLOYMENTS=(keycloak-db keycloak rabbitmq kong
             vehicle-db vehicle-service spot-db spot-service tariff-db tariff-service
             ticket-db ticket-service stay-db stay-service
             mfe-entryexit mfe-admin frontend)

if [ -t 1 ]; then
  RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; BOLD=$'\e[1m'; OFF=$'\e[0m'
else
  RED=""; GREEN=""; YELLOW=""; BOLD=""; OFF=""
fi

info() { echo "${BOLD}==>${OFF} $1"; }
ok()   { echo "  ${GREEN}OK${OFF}   $1"; }
warn() { echo "  ${YELLOW}!${OFF}    $1"; }
die()  { echo "  ${RED}ERROR${OFF} $1" >&2; exit 1; }

command -v minikube >/dev/null 2>&1 || die "minikube no esta instalado o no esta en el PATH."
command -v kubectl  >/dev/null 2>&1 || die "kubectl no esta instalado o no esta en el PATH."

cluster_running() {
  minikube status -p "$PROFILE" --format '{{.APIServer}}' 2>/dev/null | grep -q Running
}

ensure_cluster() {
  info "Cluster minikube '$PROFILE'"
  if cluster_running; then
    ok "Ya esta arrancado."
    return
  fi
  if minikube profile list -o json 2>/dev/null | grep -q "\"Name\":\"$PROFILE\""; then
    minikube start -p "$PROFILE" >/dev/null
    ok "Arrancado (el estado del cluster se conserva entre paradas)."
  else
    warn "No existe el perfil, creandolo (8 CPU / 10 GB, tarda unos minutos)."
    minikube start -p "$PROFILE" --driver=docker --cpus=8 --memory=10g >/dev/null
    ok "Creado."
  fi
  # El HPA de stay-service no escala sin metricas, y el addon sobrevive a stop/start.
  minikube addons enable metrics-server -p "$PROFILE" >/dev/null 2>&1 || \
    warn "No se pudo habilitar metrics-server: el HPA se quedara en <unknown>."
}

# --- port-forward en segundo plano -------------------------------------------

pf_pid_file() { echo "$PF_DIR/$1.pid"; }

pf_alive() {
  local f; f="$(pf_pid_file "$1")"
  [ -f "$f" ] && kill -0 "$(cat "$f")" 2>/dev/null
}

# Un port-forward se enlaza a un pod concreto: si ese pod se reemplaza (rollout,
# HPA, desalojo) el proceso sigue vivo pero el puerto ya no responde. Por eso no
# basta con mirar el PID.
pf_healthy() {
  pf_alive "$1" && curl -s -o /dev/null --max-time 5 "http://localhost:$2/" 2>/dev/null
}

pf_kill() {
  local f; f="$(pf_pid_file "$1")"
  [ -f "$f" ] || return 0
  kill "$(cat "$f")" 2>/dev/null || true
  rm -f "$f"
}

pf_start() {
  local name="$1" svc="$2" host_port="$3" target="$4"
  mkdir -p "$PF_DIR"
  if pf_healthy "$name" "$host_port"; then
    ok "$name ya expuesto en $host_port."
    return 0
  fi
  if pf_alive "$name"; then
    warn "$name tenia un port-forward muerto (pod reemplazado), rehaciendolo."
    pf_kill "$name"
  fi
  # Un puerto ocupado por otra cosa (tipicamente Compose) tiene que fallar aqui
  # y no dejar un port-forward muerto que parezca vivo.
  if (exec 3<>"/dev/tcp/127.0.0.1/$host_port") 2>/dev/null; then
    warn "El puerto $host_port ya esta ocupado. Si es Compose: ./demo-stack.sh down"
    return 1
  fi
  nohup kubectl -n "$NS" port-forward "service/$svc" "$host_port:$target" \
    >"$PF_DIR/$name.log" 2>&1 &
  echo $! > "$(pf_pid_file "$name")"
  local waited=0
  while [ "$waited" -lt 15 ]; do
    pf_healthy "$name" "$host_port" && { ok "$name expuesto en $host_port."; return 0; }
    sleep 1; waited=$((waited + 1))
  done
  warn "El port-forward de $name no responde. Mira $PF_DIR/$name.log"
  return 1
}

pf_stop() {
  local name
  for name in kong keycloak; do
    pf_kill "$name"
  done
}

cmd_expose() {
  if [ "${1:-}" = "--stop" ]; then
    info "Parando los port-forward"
    pf_stop
    ok "Hecho."
    return
  fi
  info "Publicando puertos en el host"
  local failed=0
  pf_start kong kong "$KONG_PORT" 8000 || failed=1
  pf_start keycloak keycloak "$KEYCLOAK_PORT" 8080 || failed=1
  return "$failed"
}

# --- comandos ----------------------------------------------------------------

wait_ready() {
  local timeout="${1:-300}" d failed=0
  info "Esperando a que los deployments esten Ready (hasta ${timeout}s cada uno)"
  for d in "${DEPLOYMENTS[@]}"; do
    printf "  ...  %s " "$d"
    if kubectl -n "$NS" rollout status "deployment/$d" --timeout="${timeout}s" >/dev/null 2>&1; then
      echo "${GREEN}OK${OFF}"
    else
      echo "${YELLOW}no listo${OFF}"
      warn "kubectl -n $NS describe deployment/$d"
      failed=1
    fi
  done
  return "$failed"
}

print_status() {
  info "Pods"
  kubectl -n "$NS" get pods -o wide --no-headers 2>/dev/null \
    | awk '{printf "  %-34s %-8s %-20s %s\n", $1, $2, $3, $4}' \
    || warn "El cluster no responde."
  echo
  info "HPA"
  kubectl -n "$NS" get hpa --no-headers 2>/dev/null \
    | awk '{printf "  %-16s targets=%-12s replicas=%s\n", $1, $4, $7}' \
    || warn "Sin HPA."
  echo
  info "Puertos publicados en el host"
  local name port
  for name in kong keycloak; do
    [ "$name" = kong ] && port="$KONG_PORT" || port="$KEYCLOAK_PORT"
    if pf_healthy "$name" "$port"; then
      ok "$name responde en $port (PID $(cat "$(pf_pid_file "$name")"))"
    elif pf_alive "$name"; then
      warn "$name tiene el proceso vivo pero el puerto $port NO responde: $0 expose"
    else
      warn "$name NO expuesto. Levantalo con: $0 expose"
    fi
  done
}

cmd_up() {
  local seed=1 expose=1 a
  for a in "$@"; do
    case "$a" in
      --no-seed)   seed=0 ;;
      --no-expose) expose=0 ;;
      *) die "Opcion desconocida de 'up': $a" ;;
    esac
  done

  ensure_cluster

  info "Cargando imagenes en el nodo"
  ./k8s/load-images.sh >/dev/null || die "Fallo load-images.sh. Construye antes con ./demo-stack.sh up."
  ok "Hecho."

  info "Sincronizando ConfigMaps (kong.yml y realm)"
  ./k8s/sync-config.sh >/dev/null
  ok "Hecho."

  info "Aplicando manifiestos"
  kubectl apply -k k8s/ >/dev/null
  ok "Hecho."

  local failed=0
  wait_ready 300 || failed=1
  echo

  if [ "$expose" -eq 1 ]; then
    cmd_expose || failed=1
    echo
  else
    warn "Puertos no publicados (--no-expose)."
    echo
  fi

  # Igual que en Compose: el seed va por Kong con un token real, asi que
  # necesita el port-forward y keycloak/spot/tariff arriba. Es idempotente.
  if [ "$seed" -eq 1 ] && [ "$failed" -eq 0 ] && [ "$expose" -eq 1 ]; then
    info "Sembrando datos de demo"
    if KONG_URL="http://localhost:$KONG_PORT" KEYCLOAK_URL="http://localhost:$KEYCLOAK_PORT" \
       ./scripts/seed-demo-data.sh; then
      echo
    else
      warn "El seed fallo. El stack esta arriba; reintenta con ./scripts/seed-demo-data.sh"
      failed=1
      echo
    fi
  elif [ "$seed" -eq 0 ]; then
    warn "Seed omitido (--no-seed)."
    echo
  fi

  if [ "$failed" -eq 0 ]; then
    info "${GREEN}Stack en Kubernetes listo${OFF}   ->  http://localhost:$KONG_PORT/"
  else
    info "${YELLOW}Stack levantado con avisos${OFF} (revisa los mensajes de arriba)"
  fi
  return "$failed"
}

cmd_down() {
  pf_stop
  if [ "${1:-}" = "--clean" ]; then
    warn "Se va a BORRAR el cluster '$PROFILE' entero, con sus volumenes."
    minikube delete -p "$PROFILE"
    ok "Cluster borrado."
    return
  fi
  info "Parando el cluster '$PROFILE' (los datos se conservan)"
  minikube stop -p "$PROFILE" >/dev/null
  ok "Hecho. Volver a levantarlo: $0 up"
}

cmd_restart() {
  local d="${1:-}"
  [ -n "$d" ] || die "Uso: $0 restart <deployment> (ej: stay-service)"
  kubectl -n "$NS" get "deployment/$d" >/dev/null 2>&1 || die "No existe el deployment '$d' en $NS."
  info "Rollout restart de '$d'"
  kubectl -n "$NS" rollout restart "deployment/$d" >/dev/null
  kubectl -n "$NS" rollout status "deployment/$d" --timeout=300s
}

# RECON-822: la misma coleccion que el equipo usa en Postman, contra el cluster.
# El formato de workspace (arboles de .request.yaml) no lo ejecuta Newman, asi
# que se convierte a JSON v2.1 en un temporal; el YAML sigue siendo la fuente.
cmd_verify() {
  local coleccion="postman/collections/Parking · Kong JWT (GW-08)"
  local entorno="postman/environments/Parking - Kong (dev).environment.yaml"
  local out; out="$(mktemp -d)"
  trap 'rm -rf "$out"' RETURN

  command -v npx >/dev/null 2>&1 || die "Hace falta npx (Node) para ejecutar Newman."
  pf_healthy kong "$KONG_PORT" || die "Kong no responde en $KONG_PORT. Levanta el stack: $0 up"

  info "Generando la coleccion ejecutable"
  ./scripts/postman-export.py "$coleccion" -o "$out/collection.json" >/dev/null
  ./scripts/postman-export.py --env "$entorno" -o "$out/environment.json" >/dev/null
  ok "Hecho."

  info "Newman contra el cluster"
  npx --yes newman run "$out/collection.json" -e "$out/environment.json" --reporters cli
}

cmd_info() {
  info "Puertos y URLs del stack en Kubernetes"
  cat <<EOF
  shell             http://localhost:$KONG_PORT/            (via Kong, igual que en Compose)
  api via Kong      http://localhost:$KONG_PORT/api/v1/{vehicles,spots,tariffs,tickets,stays}
  keycloak          http://localhost:$KEYCLOAK_PORT/
  mfe-entryexit     http://localhost:$KONG_PORT/mfe/entryexit/
  mfe-admin         http://localhost:$KONG_PORT/mfe/admin/

  Solo se publican esos dos puertos: los 5 microservicios, el admin de Kong y
  RabbitMQ no salen al host. Para llegar a ellos, port-forward puntual:
    kubectl -n $NS port-forward service/rabbitmq 15672:15672
EOF
  echo
  print_status
}

case "${1:-}" in
  up)      shift; cmd_up "$@" ;;
  down)    shift; cmd_down "${1:-}" ;;
  status)  print_status ;;
  restart) shift; cmd_restart "${1:-}" ;;
  expose)  shift; cmd_expose "${1:-}" ;;
  verify)  cmd_verify ;;
  info|-info|--info) cmd_info ;;
  *) die "Uso: $0 {up [--no-seed] [--no-expose] | down [--clean] | status | restart <deployment> | expose [--stop] | verify | info}" ;;
esac
