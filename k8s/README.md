# Stack de parking en Kubernetes (minikube)

Despliegue del stack sobre un cluster local, en paralelo a Compose. **Compose
sigue siendo el camino oficial de la demo**: esto no lo sustituye ni lo toca.

Estado actual: el stack completo, los mismos 17 componentes que levanta
`demo-stack.sh`. Verificado E2E contra el cluster el 2026-08-06 (ver
[Verificacion](#verificacion)). El HPA existe pero se aplica aparte, ver el
[guion de resiliencia](#guion-de-resiliencia-para-la-demo).

> [!warning] Los dos stacks son excluyentes
> `iss`, `redirect-uri` del realm y CORS de `kong.yml` estan fijados a
> `localhost:8000` / `localhost:8180`. Hay que parar Compose (`./demo-stack.sh
> down`) antes de exponer el cluster en esos puertos.

## Requisitos

- minikube con driver docker, y las imagenes de Compose ya construidas
  (`./demo-stack.sh up` al menos una vez, o `./k8s/load-images.sh --build`).
- ~4 GB libres en la particion donde vive `/var/lib/docker`.

## Arranque

Con Compose parado (`./demo-stack.sh down`), un solo comando:

```bash
./k8s/k8s-stack.sh up         # cluster + imagenes + manifiestos + puertos + seed
```

Tiene la misma interfaz que `demo-stack.sh` y es idempotente, asi que repetirlo
no reinicia nada que no haya cambiado:

| Comando | Que hace |
|---|---|
| `up [--no-seed] [--no-expose]` | Levanta todo y no devuelve el control hasta que esta Ready |
| `down [--clean]` | Para el cluster (con `--clean`, lo borra entero) |
| `status` | Pods, HPA y estado real de los puertos publicados |
| `restart <deployment>` | `rollout restart` + espera |
| `expose [--stop]` | Publica/para 8000 y 8180 en el host |
| `verify` | Newman contra el cluster (RECON-822) |
| `info` | Tabla de puertos y URLs + estado |

A mano, si se prefiere paso a paso:

```bash
minikube start -p parking --driver=docker --cpus=8 --memory=10g
./k8s/load-images.sh          # reetiqueta las imagenes de Compose y las mete en el nodo
./k8s/sync-config.sh          # ConfigMaps desde kong/kong.yml y keycloak/realm-export.dev-only.json
kubectl apply -k k8s/
./k8s/expose.sh               # 8000 y 8180, bloquea hasta Ctrl-C (k8s-stack.sh los deja en segundo plano)
```

`sync-config.sh` hay que repetirlo cada vez que cambie `kong/kong.yml` o el
realm: son la fuente de verdad y no se copian dentro de `k8s/`. Solo reinicia
Kong o Keycloak si el contenido ha cambiado de verdad.

Solo se exponen esos dos puertos: el shell, los 2 MFEs y los 5 microservicios
se alcanzan a traves de Kong.

| URL | Que es |
|---|---|
| `http://localhost:8000/` | Shell (Module Federation carga los MFEs por ruta relativa) |
| `http://localhost:8000/api/v1/...` | API a traves del gateway |
| `http://localhost:8180/` | Keycloak |

### NodePort fijos (para llegar desde otra maquina)

`kong` y `keycloak` son `NodePort` en el manifiesto, con puerto fijo. Es lo que
permite alcanzarlos desde fuera del Linux **sin depender de ningun proceso en el
host**: `kubectl port-forward` se enlaza a un pod, no al Service, y un ciclo de
reinicio lo deja sordo a mitad de demo.

| Servicio | NodePort | Notas |
|---|---|---|
| kong (proxy) | `30800` | |
| keycloak | `30818` | |
| rabbitmq (management) | `31567` | UI de colas. AMQP (5672) se queda dentro |
| kubernetes-dashboard | `30900` | Addon; el `Service` se parchea a mano, no esta en `k8s/` |

Tunel SSH desde Windows contra la IP del nodo (`minikube ip -p parking`):

```powershell
ssh -L 8000:192.168.49.2:30800 -L 8180:192.168.49.2:30818 -L 30900:192.168.49.2:30900 -L 31567:192.168.49.2:31567 roddy@192.168.1.34
```

Mapear a `localhost:8000` / `localhost:8180` en el lado de Windows **no es
opcional**: el `iss` de los tokens, los `redirect-uri` del realm y el CORS de
`kong.yml` estan fijados a esos dos origenes.

Addons que conviene tener activos: `metrics-server` (habilita `kubectl top` y el
HPA) y `dashboard`.

```bash
minikube addons enable metrics-server -p parking
minikube addons enable dashboard -p parking
kubectl -n kubernetes-dashboard patch svc kubernetes-dashboard --type merge \
  -p '{"spec":{"type":"NodePort","ports":[{"port":80,"targetPort":9090,"nodePort":30900}]}}'
```

Parar sin perder datos: `minikube stop -p parking`.
Borrar el cluster entero: `minikube delete -p parking`.

## Comprobaciones

```bash
kubectl -n parking exec deploy/vehicle-service -- wget -qO- http://localhost:8080/actuator/health
kubectl -n parking exec deploy/vehicle-db -- psql -U vehicle -d vehicle_db -c "\dt"
kubectl -n parking exec deploy/stay-service -- wget -qO- http://spot-service:8080/actuator/health
```

## Verificacion

```bash
./k8s/k8s-stack.sh verify              # politica JWT de Kong: 17 assertions
./scripts/checkin-traffic.sh           # flujo funcional: check-ins reales via Kong
```

`verify` ejecuta la coleccion **Parking · Kong JWT (GW-08)**, la misma que el
equipo usa en Postman. Newman no lee el formato de workspace (arboles de
`.request.yaml`), asi que `scripts/postman-export.py` la convierte a JSON v2.1
en un temporal: el YAML sigue siendo la fuente de verdad y no hay dos copias.

Resultado del 2026-08-06 contra el cluster: **16 requests, 17 assertions, 0
fallos**, y 30/30 check-ins en 201. Sin tocar la coleccion ni el environment —
mismos puertos que en Compose, luego el mismo environment vale para los dos.

> [!note] La coleccion `Parking-E2E.postman_collection.json` no sirve para esto
> No lleva `Authorization` en ninguna de sus 19 peticiones: es anterior a
> GW-07/GW-08. Contra Kong da 401 en todas, en Compose igual que en Kubernetes.

## Guion de resiliencia para la demo

Lo que se ensena y en que orden. Requiere el stack levantado y sembrado.

**1. Recuperacion automatica.** Se hace sobre **spot-service**, no sobre
stay-service: el check-in llama a spot de forma sincrona, asi que ejerce la
misma cadena, pero sin tocar el SSE.

> [!warning] Con una sola replica esto NO funciona, y el PDB no salva nada
> Medido el 2026-08-07: matar el pod de stay-service con **1 replica** tira
> **12 de 25** peticiones (10 x 502 y 2 timeouts de 30s). Un PDB no puede
> proteger un deployment de una sola replica, solo impide drenajes voluntarios.
> Hay que escalar **antes**, y escalar tarda ~70s: no se improvisa en directo.

Preparacion (antes de tener publico delante):

```bash
kubectl -n parking scale deployment spot-service --replicas=2
kubectl apply -f k8s/21-resiliencia-demo.yaml       # PDB, minAvailable 1
kubectl -n parking rollout status deploy/spot-service
```

En una terminal, trafico continuo; en otra, matar una replica a mitad:

```bash
./scripts/traffic-gen.py --vehicles 20 --rate 3 --concurrency 3
```

```bash
POD=$(kubectl -n parking get pods -l app.kubernetes.io/name=spot-service -o name | head -1)
kubectl -n parking delete $POD
kubectl -n parking get pods -l app.kubernetes.io/name=spot-service -w
```

`delete pod -l ... | head -1` **no** vale, aunque es lo que ponia aqui antes:
`delete -l` borra todas las replicas que casen con la etiqueta y el `head -1`
solo recorta la salida. Hay que elegir una con `get` y borrar esa.

El trafico sigue en 201 sin un solo fallo y el pod se reemplaza solo. Medido:
**20/20 en 201**, con una peticion que espero 1,8s durante el corte.

Al terminar:

```bash
kubectl delete -f k8s/21-resiliencia-demo.yaml
kubectl -n parking scale deployment spot-service --replicas=1
```

**2. Autoescalado.** El HPA **no esta en el stack por defecto**: hay que
aplicarlo a mano y quitarlo al terminar.

```bash
kubectl apply -f k8s/20-autoscaling.yaml     # 2-5 replicas
# ...demo...
kubectl delete -f k8s/20-autoscaling.yaml
kubectl -n parking scale deployment stay-service --replicas=1
```

> [!warning] No ensenar el SSE con el HPA puesto
> Con mas de una replica, un cliente SSE solo recibe los eventos que procesa
> **su** replica: el emitter vive en memoria y las colas de RabbitMQ son
> competing consumers. Medido con 10 check-ins: con 1 replica llegan 10/10
> `stay_created` y 10/10 `vehicle_updated`; con 2 replicas, **0/10 y 5/10**.

`checkin-traffic.sh` es secuencial y con delay: **no genera CPU suficiente para
disparar el HPA**. Hace falta carga concurrente:

```bash
TOKEN=$(curl -s -X POST http://localhost:8180/realms/parking/protocol/openid-connect/token \
  -d client_id=parking-frontend -d username=admin.test -d 'password=Admin.123!' \
  -d grant_type=password | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')
for i in $(seq 1 6); do
  ( end=$((SECONDS+150)); while [ $SECONDS -lt $end ]; do
      curl -s -o /dev/null -H "Authorization: Bearer $TOKEN" \
        "http://localhost:8000/api/v1/stays?page=0&size=50"; done ) &
done
watch -n5 'kubectl -n parking get hpa stay-service'
```

Tarda ~3 min en escalar: metrics-server publica cada 15s, el HPA decide cada
15s y `scaleUp.stabilizationWindowSeconds` son 30s. Medido: 2 -> 5 replicas con
CPU al 146 %. Baja sola a 2 tras 5 min sin carga (`scaleDown`, deliberadamente
lento para no cortar peticiones en curso).

## Decisiones

- **Los `Service` se llaman igual que los servicios de Compose** (`vehicle-db`,
  `spot-service`, `rabbitmq`, ...). El DNS del cluster resuelve los mismos
  nombres que la red de Docker, asi que `kong.yml`, el `nginx.conf` del frontend
  y los defaults de `application.properties` de stay-service valen sin tocar nada.
- `imagePullPolicy: IfNotPresent` + imagenes cargadas a mano: no hay registry, y
  asi la demo no depende de tener red.

> [!warning] `minikube image load` no sobreescribe un tag que ya existe en el nodo
> Con driver docker y runtime docker, volver a cargar `parking/<svc>:demo` deja
> la imagen anterior en el nodo, y `minikube image rm` antes tampoco basta. No
> falla nada visible: pods `Running`, `rollout status` en verde y Flyway
> diciendo `Schema "public" is up to date`, sirviendo la build del dia anterior.
> Con Compose no se ve porque build y runtime comparten el mismo daemon.
>
> Detectado el 2026-08-07: el JAR dentro del pod de tariff-service tenia 3
> migraciones y la imagen construida tenia 4. Afectaba a las 8 imagenes.
>
> **`load-images.sh` ya lo esquiva** (funcion `load_mutable`): las 8 imagenes de
> aplicacion entran por `docker save`. Las base (`postgres`, `rabbitmq`,
> `keycloak`, `kong`) siguen con `image load` a proposito, porque su tag es
> inmutable y la cache no puede ocultar nada. Si se carga una imagen a mano,
> hacerlo asi:
>
> ```bash
> docker save parking/<svc>:demo | minikube -p parking ssh --native-ssh=false "docker load"
> kubectl -n parking rollout restart deploy/<svc>
> ```
>
> Verificar por **contenido**, no por ID: `save`/`load` cambia el ID aunque el
> contenido sea el mismo.
>
> ```bash
> kubectl -n parking exec deploy/tariff-service -c tariff-service -- sh -c 'unzip -l /app/*.jar | grep "db/migration/V"'
> ```
>
> Desaparece con un registry y tags inmutables por commit: mientras el tag no
> cambie entre builds, cualquier cache puede volver a ocultarlo.
- `startupProbe` en los micros (hasta 3 min) para que el arranque de Spring +
  Flyway no dispare la liveness y deje los pods en bucle de reinicio.
- `JAVA_TOOL_OPTIONS=-XX:MaxRAMPercentage=75` porque la JVM dimensiona el heap
  contra la RAM del nodo, no contra el limit del contenedor.
- Postgres con `PGDATA` en un subdirectorio del volumen: initdb aborta si el
  punto de montaje no esta vacio.
- Probes de RabbitMQ con `timeoutSeconds: 10`: `rabbitmq-diagnostics` levanta una
  VM de Erlang y tarda ~3s, muy por encima del timeout por defecto de 1s.
- `KONG_NGINX_WORKER_PROCESSES=2`: por defecto Kong arranca un worker por core
  (8 en este nodo) y el conjunto no cabe en el limit, los workers mueren con
  signal 9. En Compose no se ve porque el contenedor no tiene limite.
- Probes de Keycloak con `httpGet` contra el puerto de management (9000): la
  imagen es distroless y en Compose hace falta el truco de `/dev/tcp`, pero el
  `httpGet` lo ejecuta el kubelet desde fuera del contenedor.

- `expose.sh` usa `kubectl port-forward`, que es un proceso que puede caerse a
  mitad de demo. Ademas se enlaza a un **pod concreto**: si ese pod se
  reemplaza (rollout, HPA), el proceso sigue vivo pero el puerto deja de
  responder, asi que `k8s-stack.sh` comprueba salud real y no solo el PID.
  Alternativa mas robusta si se recrea el cluster: publicar los puertos en el
  propio nodo con `minikube start --ports=8000:30800,8180:30818` y NodePort,
  que no necesita ningun proceso vivo.
- `initContainer` en los 5 micros (`pg_isready` contra su Postgres) y en el
  shell (`nc -z kong 8000`): sin ellos, tras un `minikube stop`/`start` los
  micros arrancan antes que su BD y se reinician en cascada, y nginx —que
  resuelve el upstream una sola vez al arrancar— muere en `CrashLoopBackOff`.
  En Compose lo evita `depends_on`. Usan la imagen de Postgres, que ya esta en
  el nodo, para no depender de la red.
- HPA con `scaleUp.stabilizationWindowSeconds: 30`: con un arranque de Spring de
  ~40s, el valor por defecto (0s) hace que el HPA no vea todavia el efecto de la
  replica anterior y sobreescale.

## Pendiente

- **`stay-service` no escala horizontalmente sin romper SSE-06/SSE-08.** El
  arreglo esta en `stay-service`, no aqui: cada replica necesita su propia cola
  (fanout) en vez de compartir una con competing consumers. Hasta entonces el
  HPA se queda fuera del stack por defecto.
- `RECON-823`: mover el `data-root` de Docker fuera de la particion raiz.
  **No antes de la demo.**
- La ruta `/api/v1/activeStay` devuelve **500 en vez de 404** (el catch-all
  IN-36 de `stay-service` traga la `NoResourceFoundException`). No es de
  Kubernetes: se reproduce igual contra el micro sin pasar por Kong, y por
  tanto tambien en Compose. Es de `stay-service`, no de esta epica.
