# Stack de parking en Kubernetes (minikube)

Despliegue del stack sobre un cluster local, en paralelo a Compose. **Compose
sigue siendo el camino oficial de la demo**: esto no lo sustituye ni lo toca.

Estado actual (bloque A): los 5 microservicios + sus 5 Postgres + RabbitMQ.
Keycloak, Kong y los 3 frontends siguen solo en Compose.

## Requisitos

- minikube con driver docker, y las imagenes de Compose ya construidas
  (`./demo-stack.sh up` al menos una vez, o `./k8s/load-images.sh --build`).
- ~4 GB libres en la particion donde vive `/var/lib/docker`.

## Arranque

```bash
minikube start -p parking --driver=docker --cpus=8 --memory=10g
./k8s/load-images.sh          # reetiqueta las imagenes de Compose y las mete en el nodo
kubectl apply -k k8s/
kubectl get pods -n parking -w
```

Parar sin perder datos: `minikube stop -p parking`.
Borrar el cluster entero: `minikube delete -p parking`.

## Comprobaciones

```bash
kubectl -n parking exec deploy/vehicle-service -- wget -qO- http://localhost:8080/actuator/health
kubectl -n parking exec deploy/vehicle-db -- psql -U vehicle -d vehicle_db -c "\dt"
kubectl -n parking exec deploy/stay-service -- wget -qO- http://spot-service:8080/actuator/health
```

## Decisiones

- **Los `Service` se llaman igual que los servicios de Compose** (`vehicle-db`,
  `spot-service`, `rabbitmq`, ...). El DNS del cluster resuelve los mismos
  nombres que la red de Docker, asi que `kong.yml`, el `nginx.conf` del frontend
  y los defaults de `application.properties` de stay-service valen sin tocar nada.
- `imagePullPolicy: IfNotPresent` + imagenes cargadas a mano: no hay registry, y
  asi la demo no depende de tener red.
- `startupProbe` en los micros (hasta 3 min) para que el arranque de Spring +
  Flyway no dispare la liveness y deje los pods en bucle de reinicio.
- `JAVA_TOOL_OPTIONS=-XX:MaxRAMPercentage=75` porque la JVM dimensiona el heap
  contra la RAM del nodo, no contra el limit del contenedor.
- Postgres con `PGDATA` en un subdirectorio del volumen: initdb aborta si el
  punto de montaje no esta vacio.
- Probes de RabbitMQ con `timeoutSeconds: 10`: `rabbitmq-diagnostics` levanta una
  VM de Erlang y tarda ~3s, muy por encima del timeout por defecto de 1s.

## Pendiente

- Bloque B: Keycloak (+ su Postgres, realm importado) y Kong DB-less desde
  `kong/kong.yml` como ConfigMap.
- Bloque C: exposicion manteniendo los puertos actuales (8000, 8180, 5173, 5001,
  5002) para no reconstruir los frontends, que hornean las URLs en build time.
- Bloque D: HPA en stay-service, PodDisruptionBudget y guion de la demo.
