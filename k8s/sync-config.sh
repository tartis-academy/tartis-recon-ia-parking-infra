#!/usr/bin/env bash
#
# Crea los dos ConfigMap de configuracion a partir de sus ficheros canonicos:
# kong/kong.yml y keycloak/realm-export.dev-only.json. No estan en el
# kustomization porque kustomize no deja generar desde rutas por encima de su
# raiz, y duplicar los ficheros dentro de k8s/ acabaria en drift.
#
# Hay que ejecutarlo antes del primer `kubectl apply -k k8s/` y cada vez que
# cambie alguno de los dos ficheros.

set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.."

NS=parking

kubectl get namespace "$NS" >/dev/null 2>&1 || kubectl create namespace "$NS"

kubectl create configmap kong-declarative \
  --namespace "$NS" \
  --from-file=kong.yml=kong/kong.yml \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create configmap keycloak-realm \
  --namespace "$NS" \
  --from-file=realm-export.json=keycloak/realm-export.dev-only.json \
  --dry-run=client -o yaml | kubectl apply -f -

# Los ConfigMap montados como volumen no reinician el pod solos, y Kong lee su
# configuracion declarativa una unica vez al arrancar.
for dep in kong keycloak; do
  if kubectl -n "$NS" get deployment "$dep" >/dev/null 2>&1; then
    kubectl -n "$NS" rollout restart deployment "$dep"
  fi
done
