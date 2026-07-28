# tartis-recon-ia-parking-infra

Entorno local para tartis-recon-ai-parking: Postgres de dev con un schema por
servicio, pgAdmin, SonarQube, y la infra de Fase II (Keycloak, Kong,
RabbitMQ). Todo en `docker-compose.yml`.

`docker-compose.demo.yml` añade los 5 microservicios (perfil `prod`,
database-per-service real) y el frontend, cada uno con su propia Postgres.
Asume los 6 repos de microservicio/frontend clonados como hermanos de este
repo (convención del proyecto). Depende de `keycloak` y `rabbitmq`
(definidos en `docker-compose.yml`), así que **no se levanta en solitario**:
siempre combinado con el otro fichero.

## Levantar el entorno local

Lo más rápido: un script que hace todos los pasos de abajo (red, `.env`,
contenedores) y espera a que estén listos.

```bash
./setup.sh              # plataforma: Postgres dev, pgAdmin, SonarQube, Keycloak, Kong, RabbitMQ
./setup.sh full         # lo anterior + los 5 microservicios y el frontend
./setup.sh down         # para los contenedores
./setup.sh clean        # para y BORRA los datos
```

Si prefieres ir a mano:

```bash
docker network create parking-shared   # solo la primera vez
cp .env.example .env
docker compose up -d                                              # solo plataforma
docker compose -f docker-compose.yml -f docker-compose.demo.yml up -d --build   # stack completo
docker compose ps                                                 # comprobar healthy
docker compose down                                                # para (-v también borra datos)
```

## Datos de conexión

| Servicio | URL / host:puerto | Credenciales |
|---|---|---|
| pgAdmin | http://localhost:5050 | tu `.env` |
| SonarQube | http://localhost:9000 | `admin`/`admin` |
| Keycloak (admin console) | http://localhost:8180 | tu `.env` |
| RabbitMQ (management UI) | http://localhost:15672 | tu `.env` |
| Kong (proxy) | http://localhost:8000 | — |
| Kong (Admin API) | http://127.0.0.1:8001 | solo local, no publicada en la red |
| Postgres dev, desde tu máquina | `localhost:5432` · `parking_dev` (schemas: vehicle, spot, tariff, ticket, stay) | tu `.env` |
| Postgres dev, desde pgAdmin | `parking-dev-postgres:5432` | tu `.env` |

Cada microservicio, en su perfil de dev, apunta a esta BD usando su propio
schema. Para el perfil `prod` / servicio aislado (stack `full`), cada
servicio usa su propio Postgres dedicado.

## Keycloak

Persistencia en `keycloak-db`, un Postgres dedicado — no se reutiliza el
`postgres-dev` compartido, para no mezclar datos de identidad con datos de
negocio, y para que `./setup.sh clean` (que borra los volúmenes de dev) no
se lleve el realm por delante. La configuración del realm sobrevive a un
`down`/`up` porque vive en `keycloak-db`, no en el contenedor de Keycloak.

Arranca en modo `start-dev`; el `realm-export.json` con roles y usuarios de
prueba es un ticket posterior, todavía no existe.

## Kong

Modo DB-less: la configuración vive en [`kong/kong.yml`](kong/kong.yml),
versionada y revisable en PR. `kong.yml` ya enruta hacia los 5
microservicios; el plugin JWT/OIDC contra Keycloak llega con el ticket de
seguridad.

Verificar rutas (con el stack `full` arriba):

```bash
curl -i http://localhost:8000/v1/vehicles
curl -i http://localhost:8000/v1/spots
curl -i http://localhost:8000/v1/tariffs
curl -i http://localhost:8000/v1/entry-tickets
curl -i http://localhost:8000/v1/stays
```

Cambios en `kong.yml` requieren `docker compose restart kong` (no hay
Admin API de escritura en DB-less).

## RabbitMQ

Imagen `rabbitmq:4-management` en vez del `3-management` de la ficha
original de INF-04: la serie 3.x está fuera de soporte. Misma API AMQP y UI
de management. Las colas persisten en el volumen `parking-rabbitmq-data`.

## Probar los servicios

En `postman/` están las colecciones para probar los cinco microservicios:
una por servicio, una E2E con el flujo de entrada completo y un environment
con las cinco `baseUrl` ya configuradas.

Además de suite de pruebas sirven de checklist contrato-vs-implementación: cada
request lleva en el nombre el estado real del endpoint en el código
(`[TODO]` = no hay controlador, `[STUB]` = mapeado pero devuelve vacío).

Cómo importarlas, en qué orden ejecutarlas y qué fallos son esperados:
[`postman/README.md`](postman/README.md).

## Problemas frecuentes

`network parking-shared ... not found` → te falta el primer comando.

SonarQube arranca y se muere → `sudo sysctl -w vm.max_map_count=262144`.

pgAdmin reinicia en bucle → tu `PGADMIN_EMAIL` no es válido; pgAdmin rechaza
dominios reservados como `.local`.

`docker compose -f docker-compose.demo.yml up` sin el otro `-f` → error
"depends on undefined service keycloak". El stack de demo ya no se levanta
en solitario, usa `./setup.sh full` o combina los dos ficheros a mano.

Cambias el `.env` y no se entera → `docker compose up -d --force-recreate`
(si tocas usuario o contraseña de Postgres, además `docker compose down -v`).
