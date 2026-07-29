# tartis-recon-ia-parking-infra

Entorno local para tartis-recon-ai-parking. `docker-compose.yml` trae la
plataforma núcleo de Fase II (Keycloak, Kong, RabbitMQ). `docker-compose.dev.yml`
añade la Postgres de dev con un schema por servicio y pgAdmin.

`docker-compose.demo.yml` añade los 5 microservicios (perfil `prod`,
database-per-service real) y el frontend, cada uno con su propia Postgres.
Asume los 6 repos de microservicio/frontend clonados como hermanos de este
repo (convención del proyecto). Depende de `keycloak` y `rabbitmq`
(definidos en `docker-compose.yml`), así que **no se levanta en solitario**:
siempre combinado con el otro fichero.

## Solo la BD, sin configurar nada a mano

Si lo único que quieres es programar contra la BD compartida, `./dev-db.sh`
levanta el Postgres (sin pgAdmin), asegura los cinco schemas y
**escribe las credenciales en el `.env` de cada microservicio**, que es lo que
leen sus `application-dev.properties`. Después de esto los servicios arrancan
sin tocar ningún fichero de configuración.

```bash
./dev-db.sh             # levanta el Postgres y sincroniza los .env
./dev-db.sh sync        # solo reescribe los .env (tras cambiar el .env de infra)
./dev-db.sh down        # para el Postgres
./dev-db.sh clean       # para el Postgres y BORRA sus datos
```

Busca los repos de los cinco servicios como hermanos de este. Si los tienes en
otro sitio: `PARKING_ROOT=/ruta/a/los/repos ./dev-db.sh`.

En el `.env` de cada servicio solo toca su propio bloque (entre los marcadores
`tartis dev-db`); lo demás, como las `VEHICLE_DB_*` del Postgres dedicado, se
queda como esté. Es idempotente: relanzarlo no rompe nada.

También avisa si el Postgres ya existente no acepta el usuario o la contraseña
del `.env`: eso pasa cuando se cambian con el volumen de datos ya creado, y la
única forma de aplicarlas es recrearlo (`./dev-db.sh clean && ./dev-db.sh`).

## Levantar el entorno local completo

Lo más rápido: un script que hace todos los pasos de abajo (red, `.env`,
contenedores) y espera a que estén listos. A diferencia de `./dev-db.sh`,
levanta además pgAdmin, y no toca los `.env` de los servicios.

```bash
./setup.sh              # plataforma + Postgres dev + pgAdmin
./setup.sh full         # plataforma + los 5 microservicios y el frontend
./setup.sh down         # para los contenedores
./setup.sh clean        # para y BORRA los datos
```

Si prefieres ir a mano:

```bash
docker network create parking-shared   # solo la primera vez
cp .env.example .env
docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d           # plataforma + Postgres dev + pgAdmin
docker compose -f docker-compose.yml -f docker-compose.demo.yml up -d --build  # stack completo
docker compose ps                                                              # comprobar healthy
docker compose down                                                            # para (-v también borra datos)
```

## Datos de conexión

| Servicio | URL / host:puerto | Credenciales |
|---|---|---|
| pgAdmin | http://localhost:5050 | tu `.env` |
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
se lleve el realm por delante.

El realm `parking` vive como código en [`keycloak/realm-export.json`](keycloak/realm-export.json)
y se importa solo al arrancar (`start-dev --import-realm`): un entorno recién
levantado ya tiene los roles `ADMIN`/`OPERARIO`/`USER`, el cliente público
`parking-frontend` y tres usuarios de prueba (`admin.test`, `operario.test`,
`user.test`, contraseñas `<Rol>.123!`). El realm incluye además un par de
claves RS256 **fijas** (`components.org.keycloak.keys.KeyProvider`) en vez de
dejar que Keycloak genere unas nuevas en cada `./setup.sh clean` — si no,
la clave pública que Kong tiene hardcodeada dejaría de coincidir cada vez que
alguien recrea el volumen.

Sacar un token de prueba:

```bash
curl -s -X POST http://localhost:8180/realms/parking/protocol/openid-connect/token \
  -d client_id=parking-frontend -d grant_type=password \
  -d username=admin.test -d password=Admin.123!
```

## Kong

Modo DB-less: la configuración vive en [`kong/kong.yml`](kong/kong.yml),
versionada y revisable en PR. Rutas públicas bajo `/api/v1/` (fachada del
gateway); internamente reenvía al path real de cada backend (`/v1/...`) vía
`strip_path: true` + el path ya incluido en la `url` del service.

El plugin `jwt` (Kong OSS, no `openid-connect` — es de pago) está en **las 7
rutas** (5 servicios, 3 de ellas de `ticket-service`), contra un consumer con
la clave pública RS256 del realm `parking`. `claims_to_verify: ["exp"]`
explícito porque por defecto viene vacío y Kong aceptaría tokens caducados
sin avisar. El `key` del `jwt_secret` es el `iss` exacto del token
(`http://localhost:8180/realms/parking`), no el nombre del realm.

Kong solo resuelve si el token es válido y está vigente (401 si no). El
plugin `jwt` no lee `realm_access.roles` — la autorización por rol vive en
Spring Security (`@PreAuthorize`, ticket SEC-10, pendiente en cada backend),
que devuelve 403. Decisión documentada, pendiente el ADR formal.

Pendiente (fuera de este repo o de esta sesión): CORS ya configurado en Kong
para `:8090`/`:5173`, pero el frontend sigue llamando directo a cada
microservicio (su `nginx.conf`, en el repo del frontend) en vez de a Kong —
y con la ruta `/v1/...` vieja, no `/api/v1/...`. La ruta SSE de `stay-service`
(SSE-08) todavía no existe; cuando se añada necesita su propia ruta sin este
plugin (valida por query param, no por cabecera).

Verificar (con el stack `full` arriba, token de arriba en `$TOKEN`):

```bash
curl -i http://localhost:8000/api/v1/vehicles                              # sin token -> 401
curl -i http://localhost:8000/api/v1/vehicles -H "Authorization: Bearer $TOKEN"  # token valido
```

Cambios en `kong.yml` requieren `docker compose restart kong` (no hay
Admin API de escritura en DB-less).

## RabbitMQ

Imagen `rabbitmq:4-management` en vez del `3-management` de la ficha
original de INF-04: la serie 3.x está fuera de soporte. Misma API AMQP y UI
de management. Las colas persisten en el volumen `parking-rabbitmq-data`.

## Dev vs producción

Este repo es un entorno **local**, no una plantilla de despliegue. Atajos que
solo valen aquí, con la condición que dispararía arreglarlos:

| Atajo de local | Por qué aquí es correcto | Cuándo dejaría de serlo |
|---|---|---|
| Keycloak en modo `start-dev` | Sin TLS, admin bootstrap por env vars: rápido para levantar y tirar | En cuanto haya un entorno real, pasar a `start` + TLS + secretos gestionados |
| Contraseñas `change.me` en `.env.example` | Nadie las usa fuera de un portátil | Nunca deben salir de local; un entorno real necesita un gestor de secretos, no un `.env` |
| Un único Postgres compartido con 5 schemas (`docker-compose.dev.yml`) | Más barato que 5 contenedores para programar contra la BD | El stack `full`/demo ya usa una BD dedicada por servicio; cualquier entorno real también debería |
| Kong DB-less con `kong.yml` versionado | Reproducible entre las 15 máquinas del equipo, config revisable en PR | Sigue siendo válido en producción — es la misma filosofía de config as code |

`SPRING_PROFILES_ACTIVE` (`dev`/`prod`) en cada microservicio es el eje real
de esta separación, no algo de este repo — aquí solo se refleja en qué
Postgres apunta cada perfil.

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

pgAdmin reinicia en bucle → tu `PGADMIN_EMAIL` no es válido; pgAdmin rechaza
dominios reservados como `.local`.

`docker compose -f docker-compose.demo.yml up` sin el otro `-f` → error
"depends on undefined service keycloak". El stack de demo ya no se levanta
en solitario, usa `./setup.sh full` o combina los dos ficheros a mano.

Cambias el `.env` y no se entera → `docker compose up -d --force-recreate`
(si tocas usuario o contraseña de Postgres, además `docker compose down -v`).
