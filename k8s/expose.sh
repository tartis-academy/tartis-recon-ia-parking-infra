#!/usr/bin/env bash
#
# Publica en el host los dos unicos puertos que el navegador necesita: Kong
# (8000) y Keycloak (8180). El resto del stack -- shell, los 2 MFEs y los 5
# microservicios -- se alcanza a traves de Kong, no se expone nada mas.
#
# Los puertos son los MISMOS que usa Compose a proposito: el `iss` de los
# tokens, los redirect-uri del realm y el CORS de kong.yml estan fijados a
# localhost:8000 / localhost:8180. Por eso los dos stacks son excluyentes:
# hay que parar Compose (./demo-stack.sh down) antes de exponer el cluster.
#
# Uso:
#   ./expose.sh              expone 8000 y 8180 (bloquea hasta Ctrl-C)
#   KONG_PORT=18000 KEYCLOAK_PORT=18180 ./expose.sh    puertos alternativos

set -euo pipefail

NS=parking
KONG_PORT="${KONG_PORT:-8000}"
KEYCLOAK_PORT="${KEYCLOAK_PORT:-8180}"

for p in "$KONG_PORT" "$KEYCLOAK_PORT"; do
  if (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null; then
    echo "El puerto $p ya esta ocupado. Si es el stack de Compose: ./demo-stack.sh down" >&2
    exit 1
  fi
done

cleanup() { kill 0 2>/dev/null || true; }
trap cleanup EXIT INT TERM

kubectl -n "$NS" port-forward service/kong "$KONG_PORT:8000" >/dev/null &
kubectl -n "$NS" port-forward service/keycloak "$KEYCLOAK_PORT:8080" >/dev/null &

cat <<EOF
Stack expuesto (Ctrl-C para parar):

  Shell             http://localhost:$KONG_PORT/
  API via Kong      http://localhost:$KONG_PORT/api/v1/...
  Keycloak          http://localhost:$KEYCLOAK_PORT/

EOF

wait
