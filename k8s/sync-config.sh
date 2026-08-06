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

# Devuelve 0 si el ConfigMap ya tenia exactamente ese contenido. Reiniciar Kong
# y Keycloak en cada ejecucion corta las sesiones abiertas y los port-forward,
# asi que solo se hace cuando la configuracion ha cambiado de verdad.
sync_configmap() {
  local name="$1" key="$2" file="$3" actual
  # El punto de la clave hay que escaparlo en el jsonpath, pero no en --from-file.
  actual="$(kubectl -n "$NS" get configmap "$name" -o jsonpath="{.data.${key//./\\.}}" 2>/dev/null || true)"
  kubectl create configmap "$name" --namespace "$NS" \
    --from-file="$key=$file" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  [ "$actual" = "$(cat "$file")" ]
}

cambios=()
sync_configmap kong-declarative kong.yml kong/kong.yml || cambios+=(kong)
sync_configmap keycloak-realm realm-export.json keycloak/realm-export.dev-only.json || cambios+=(keycloak)

if [ "${#cambios[@]}" -eq 0 ]; then
  echo "ConfigMaps ya sincronizados, sin reinicios."
  exit 0
fi

# Los ConfigMap montados como volumen no reinician el pod solos, y Kong lee su
# configuracion declarativa una unica vez al arrancar.
for dep in "${cambios[@]}"; do
  if kubectl -n "$NS" get deployment "$dep" >/dev/null 2>&1; then
    kubectl -n "$NS" rollout restart deployment "$dep"
    kubectl -n "$NS" rollout status deployment "$dep" --timeout=300s
  fi
done
