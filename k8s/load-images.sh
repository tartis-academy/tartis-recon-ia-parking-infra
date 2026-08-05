#!/usr/bin/env bash
#
# Mete en minikube las imagenes que ya construye Compose, reetiquetadas a
# parking/<servicio>:demo. Los Deployment usan imagePullPolicy: IfNotPresent,
# asi que sin este paso se quedan en ErrImagePull (no hay registry externo).
#
# Uso:
#   ./load-images.sh            reetiqueta y carga las 5 + postgres + rabbitmq
#   ./load-images.sh --build    reconstruye antes con Compose

set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.."

SERVICES=(vehicle spot tariff ticket stay)
BASE_IMAGES=(postgres:15.18-alpine rabbitmq:4-management quay.io/keycloak/keycloak:26.7.0 kong:3.9)
COMPOSE_PROJECT="tartis-recon-ia-parking-infra"
COMPOSE_FILES=(-f docker-compose.yml -f docker-compose.demo.yml)
PROFILE="${MINIKUBE_PROFILE:-parking}"

BUILD=false
[ "${1:-}" = "--build" ] && BUILD=true

command -v minikube >/dev/null 2>&1 || { echo "minikube no esta en el PATH." >&2; exit 1; }
minikube status -p "$PROFILE" >/dev/null 2>&1 || { echo "El cluster '$PROFILE' no esta arrancado (minikube start -p $PROFILE)." >&2; exit 1; }

for svc in "${SERVICES[@]}"; do
  src="${COMPOSE_PROJECT}-${svc}-service:latest"
  dst="parking/${svc}-service:demo"

  if [ "$BUILD" = true ] || ! docker image inspect "$src" >/dev/null 2>&1; then
    echo "==> construyendo ${svc}-service con Compose"
    docker compose "${COMPOSE_FILES[@]}" build "${svc}-service"
  fi

  echo "==> ${src} -> ${dst}"
  docker tag "$src" "$dst"
  minikube image load -p "$PROFILE" "$dst"
done

for img in "${BASE_IMAGES[@]}"; do
  # Cargar desde el daemon local en vez de dejar que el nodo tire del registry:
  # mas rapido y la demo no depende de tener red.
  docker image inspect "$img" >/dev/null 2>&1 || docker pull "$img"
  echo "==> ${img}"
  minikube image load -p "$PROFILE" "$img"
done

echo "Listo. Imagenes en el nodo:"
minikube image ls -p "$PROFILE" | grep -E "parking/|postgres|rabbitmq|keycloak|kong" | sort
