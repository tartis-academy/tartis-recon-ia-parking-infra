# tartis-recon-ai-parking — Infraestructura y Descripción General del Sistema

Sistema integral de gestión de parking inteligente (**TARTIS Recon-AI**). Orquesta el ciclo de vida completo de las estancias de vehículos en estacionamiento mediante una arquitectura de microservicios hexagonales, seguridad perimetral OAuth2/OIDC, mensajería asíncrona por eventos y notificaciones en tiempo real.

Entorno local para tartis-recon-ai-parking. `docker-compose.yml` trae la
plataforma núcleo de Fase II (Keycloak, Kong, RabbitMQ). `docker-compose.dev.yml`
añade la Postgres de dev con un schema por servicio y pgAdmin.

`docker-compose.demo.yml` añade los 5 microservicios (perfil `prod`,
database-per-service real) y el frontend, cada uno con su propia Postgres.
Asume los 6 repos de microservicio/frontend clonados como hermanos de este
repo (convención del proyecto). Depende de `keycloak` y `rabbitmq`
(definidos en `docker-compose.yml`), así que **no se levanta en solitario**:
siempre combinado con el otro fichero.

## Descripción del Sistema y Arquitectura

El sistema automatiza el control de acceso, la asignación atómica de plazas, el cálculo tarifario por tramos y la emisión/gestión de tickets de entrada y cobro:

- **Check-in de Vehículo:** Registro de entrada en terminal/barrera con comprobación de disponibilidad por categoría (**RN-01**), verificación síncrona de existencia y estado activo del vehículo (**RN-11**), asignación atómica de plaza (**RN-05**) y emisión de ticket de entrada (`EntryTicket`) con código de barras.
- **Check-out y Salida de Vehículo:** Lectura de matrícula o ticket de salida, cálculo síncrono del importe exacto mediante `tariff-service` (**RN-06** a **RN-09**), cierre de estancia a estado terminal `FINISHED` (**IN-19**), publicación asíncrona del evento de dominio `StayClosedEvent` hacia RabbitMQ para la emisión del ticket de cobro (**IN-20**) y la liberación de la plaza ocupada a `AVAILABLE`, y emisión instantánea del evento mediante Server-Sent Events (SSE).
- **Cancelación Manual de Estancia (CB06 / RN-02):** Permite a administradores cancelar estancias de vehículos que dan marcha atrás antes de cruzar la barrera, pasando la estancia a estado terminal `CANCELLED` (**IN-19**) y liberando la plaza reservada.
- **Gestión de Excepciones e Incidencias:** Marcado de tickets perdidos (**IN-22**), bloqueo de plazas por mantenimiento (**RN-10**), gestión de bajas/altas lógicas de vehículos (**RN-11**) y resiliencia con colas de mensajes muertos (DLQ) y cortocircuitos Resilience4j.


### 1. Frontend (Aplicación Web & Kiosk)
Aplicación SPA desarrollada en **React 18**, **TypeScript**, **Vite** y **Tailwind CSS**.
- **Terminal Entrada/Salida (Kiosk):** Interfaz para terminales en barrera (check-in, escaneo de códigos de barras, inicio de check-out e impresión de tickets).
- **Panel de Administración:** Gestión de catálogo de vehículos, mapa interactivo de plazas, configuración de tarifas, lista de estancias, cancelación manual (CB06) y monitorización en tiempo real vía Server-Sent Events (SSE).

### 2. API Gateway (Kong DB-less)
Puerta de entrada perimetral de la API REST. Actúa como Proxy Inverso interceptando el tráfico externo en los puertos `8000` (HTTP) / `8443` (HTTPS):
- **Autenticación en Perímetro:** Valida los tokens Bearer JWT emitidos por Keycloak mediante el plugin de seguridad.
- **Enrutamiento:** Dirige las peticiones autorizadas hacia el microservicio correspondiente (`/v1/vehicles`, `/v1/spots`, `/v1/tariffs`, `/v1/tickets`, `/v1/stays`, `/v1/events`).

### 3. Identity Provider (Keycloak IdP)
Servidor de autenticación centralizado basado en **OAuth2** y **OpenID Connect (OIDC)** (Realm `parking` en puerto `8180`):
- Almacena y gestiona las cuentas de usuarios y credenciales.
- Emite y firma los *Access Tokens* JWT con los roles RBAC (`ADMIN`, `OPERARIO`, `USER`).

### 4. Bus de Mensajería Asíncrona (RabbitMQ Broker)
Message Broker gestionando la comunicación basada en eventos (puerto `5672` AMQP, `15672` Management UI):
- **Exchange `stay.events` (Topic):** Recibe el evento `StayClosedEvent` publicado por `stay-service` al completar un check-out.
- **Cola `ticket-service-stay-closed-queue`:** Consumida asíncronamente por `ticket-service` para la emisión automática del ticket de salida.
- **Cola `spot-service-stay-closed-queue`:** Consumida asíncronamente por `spot-service` para liberar la plaza ocupada (`OCCUPIED` $\rightarrow$ `AVAILABLE`).
- **Dead Letter Queues (DLQ):** Colas `ticket-service-stay-closed-dlq` y `spot-service-stay-closed-dlq` para aislar mensajes fallidos tras 6 reintentos exponenciales.

### 5. Microservicios Backend (Spring Boot 3.x - Arquitectura Hexagonal)
- **`stay-service` (Puerto 8085 / Orquestador Central):** Orquesta el ciclo de vida de estancias (`CheckInUseCase`, `CheckOutUseCase`, `CancelStayUseCase`). Consulta síncronamente a `vehicle-service`, `spot-service` y `tariff-service`. Publica `StayClosedEvent` hacia RabbitMQ y transmite Server-Sent Events (`GET /v1/events` con evento `event:stay_updated`).
- **`vehicle-service` (Puerto 8081):** Gestión del catálogo de vehículos, validación de expresiones regulares de matrícula española (`Vehicle.validPlate`), bajas/altas lógicas (**RN-11**), categoría `CAR_PMR` y control de concurrencia optimista (`version` en Flyway `V2`).
- **`spot-service` (Puerto 8082):** Gestión de disponibilidad y estado de plazas (`AVAILABLE`, `OCCUPIED`, `UNAVAILABLE`), ocupación atómica (**RN-05**), bloqueo por mantenimiento (**RN-10**) y consumidor RabbitMQ para liberación de plazas.
- **`tariff-service` (Puerto 8083):** Gestión del catálogo de tarifas, garantía de tarifa única activa por categoría (**IN-08**), endpoint `/tariffs/calculate` (**RN-06** a **RN-09** cuota fija 0,10 €, cortesía 10 min y tramos escalonados).
- **`ticket-service` (Puerto 8084):** Gestión de tickets de entrada (`EntryTicket`) y salida (`Ticket` **IN-20**), consumidor RabbitMQ para generación de ticket de cobro, gestión de tickets perdidos (**IN-22**) y timeout pesimista Hikari.

### 6. Bases de Datos (PostgreSQL)
- **Entorno Dev (Compartido):** Host `localhost:5432` / BD `parking_dev` con schemas dedicados por servicio (`vehicle`, `spot`, `tariff`, `ticket`, `stay`).
- **Entorno Prod (Database per Service):** 5 instancias independientes de PostgreSQL (`vehicle_db:5433`, `spot_db:5434`, `tariff_db:5435`, `ticket_db:5436`, `stay_db:5437`).

---

## Tabla de Puertos del Sistema

| Servicio / Componente | Tecnología | Puerto Host (Externo) | Puerto Docker (Interno) | Descripción / Perfil |
|---|---|---|---|---|
| **Frontend Web App** | React 18 + Vite | `3000` / `5173` | `80` / `5173` | Kiosk y Panel de Administración |
| **Kong API Gateway** | Kong Gateway DB-less | `8000` (HTTP) / `8443` (HTTPS) | `8000` / `8443` | API Gateway perimetral y validación JWT |
| **Keycloak IdP** | Keycloak OAuth2 / OIDC | `8180` | `8080` | Servidor de identidades (Realm `parking`) |
| **RabbitMQ Broker** | RabbitMQ | `5672` (AMQP) / `15672` (UI) | `5672` / `15672` | Bus de mensajería asíncrona y colas DLQ |
| **`vehicle-service`** | Spring Boot 3.x | `8081` | `8081` | Catálogo y validación de vehículos |
| **`spot-service`** | Spring Boot 3.x | `8082` | `8082` | Plazas, disponibilidad y consumidor RabbitMQ |
| **`tariff-service`** | Spring Boot 3.x | `8083` | `8083` | Cálculo de tarifas e invariante IN-08 |
| **`ticket-service`** | Spring Boot 3.x | `8084` | `8084` | Tickets de entrada/salida y consumidor RabbitMQ |
| **`stay-service`** | Spring Boot 3.x | `8085` | `8085` | Orquestador de estancias y Server-Sent Events |
| **PostgreSQL Dev (Compartido)** | PostgreSQL 16 | `5432` | `5432` | BD `parking_dev` (schemas: vehicle, spot, tariff, ticket, stay) |
| **pgAdmin 4** | Web UI | `5050` | `80` | Administración visual de BD Dev |
| **SonarQube** | SonarQube Community | `9000` | `9000` | Análisis estático de calidad de código |
| **`vehicle_db` (Prod)** | PostgreSQL 16 | `5433` | `5432` | BD dedicada de vehículos |
| **`spot_db` (Prod)** | PostgreSQL 16 | `5434` | `5432` | BD dedicada de plazas |
| **`tariff_db` (Prod)** | PostgreSQL 16 | `5435` | `5432` | BD dedicada de tarifas |
| **`ticket_db` (Prod)** | PostgreSQL 16 | `5436` | `5432` | BD dedicada de tickets |
| **`stay_db` (Prod)** | PostgreSQL 16 | `5437` | `5432` | BD dedicada de estancias |

---

## Tabla de Credenciales de Prueba

| Sistema / Componente | URL de Acceso | Usuario / Email | Contraseña / Token | Rol / Ámbito |
|---|---|---|---|---|
| **Keycloak Admin Console** | `http://localhost:8180` | `admin` | `admin` | Administrador de Keycloak |
| **Usuario Pruebas (Admin)** | `http://localhost:8180/realms/parking` | `admin@parking.com` | `admin123` | Rol `ADMIN` (Acceso total a la API) |
| **Usuario Pruebas (Operario)** | `http://localhost:8180/realms/parking` | `operario@parking.com` | `operario123` | Rol `OPERARIO` (Check-in, check-out, plazas) |
| **Usuario Pruebas (Conductor)** | `http://localhost:8180/realms/parking` | `user@parking.com` | `user123` | Rol `USER` (Consulta por código de ticket) |
| **RabbitMQ Management UI** | `http://localhost:15672` | `guest` | `guest` | Monitor de colas, exchanges y mensajes |
| **pgAdmin 4** | `http://localhost:5050` | `admin@parking.com` *(o `.env`)* | `admin` | Gestión visual de PostgreSQL |
| **PostgreSQL Dev** | `localhost:5432` (`parking_dev`) | `parking_dev` | `change.me` | Schemas de desarrollo compartidos |
| **SonarQube Dashboard** | `http://localhost:9000` | `admin` | `admin` | Análisis de calidad de código |

---

## Levantar el entorno local

Lo más rápido: un script que hace todos los pasos de abajo (red, `.env`,
contenedores) y espera a que estén listos. A diferencia de `./dev-db.sh`,
levanta además pgAdmin, y no toca los `.env` de los servicios.

```bash
./setup.sh              # plataforma + Postgres dev + pgAdmin
./setup.sh -f           # plataforma + los 5 microservicios y el frontend
./setup.sh -f -s vehicle,spot   # -f pero solo estos microservicios (+ sus dependencias)
./setup.sh -d           # para los contenedores
./setup.sh -c           # para y BORRA los datos
./setup.sh -h           # ayuda completa
```

(`full`/`down`/`clean` sin guion también funcionan, por compatibilidad con la sintaxis anterior.)

Para una demo (levantar y comprobar que todo llega a `healthy`, con estado y
reinicio de un servicio suelto), `./demo-stack.sh` envuelve el mismo stack
`full` con más feedback:

```bash
./demo-stack.sh up              # build + up + espera healthchecks + siembra datos
./demo-stack.sh up --no-seed    # igual, pero sin sembrar
./demo-stack.sh up --no-frontend
./demo-stack.sh status          # solo el estado actual, sin levantar nada
./demo-stack.sh restart ticket-service   # rebuild + recreate de uno solo
./demo-stack.sh info            # puertos/URLs + estado
./demo-stack.sh down [--clean]
```

`./setup.sh -f` sigue siendo la opción para levantar rápido o para un
subconjunto (`-s`); `./demo-stack.sh` es para cuando necesitas saber con
certeza que todo terminó healthy antes de seguir (p. ej. antes de una demo o
en un script que encadena pasos).

### Datos de demo

`demo-stack.sh up` termina llamando a `scripts/seed-demo-data.sh`, que deja el
sistema listo para hacer check-in: **50 plazas** (20 `CAR`, 20 `MOTORBIKE`, 10
`CAR_PMR`) y **una tarifa activa por tipo**. Sin tarifa activa el check-in
responde `409`, y sin plazas libres no hay nada que ocupar: son precondiciones
de negocio, no un fallo del stack.

El script es **idempotente**: cuenta lo que ya existe y crea solo lo que falta
hasta el cupo. Importa porque las BD son volúmenes persistentes — si no lo
fuera, cada `up` añadiría otras 50 plazas.

```bash
./scripts/seed-demo-data.sh                      # a mano, mismos cupos
SPOTS_CAR=40 ./scripts/seed-demo-data.sh         # cupo distinto
./demo-stack.sh down --clean                     # BD desde cero; el siguiente up siembra las 50
```

Si levantas con `setup.sh` o con `docker compose` directamente, el seed **no**
se ejecuta: lánzalo a mano.

Si prefieres ir a mano:

```bash
docker network create parking-shared   # solo la primera vez
cp .env.example .env
docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d           # plataforma + Postgres dev + pgAdmin
docker compose -f docker-compose.yml -f docker-compose.demo.yml up -d --build  # stack completo
docker compose ps                                                              # comprobar healthy
docker compose down                                                            # para (-v también borra datos)
```

## Qué script uso

Tres scripts, cada uno pensado para un caso distinto — la confusión más
habitual es pensar que "dev" en `docker-compose.dev.yml` tiene algo que ver
con qué tan completo es el stack. No es así: es solo qué Postgres usan los
microservicios (compartido vs. dedicado), no si se levanta la plataforma
entera ni si hay 1 contenedor o 16.

| Script | Ficheros compose | Qué levanta | Selección de servicios | Cuándo usarlo |
|---|---|---|---|---|
| `./dev-db.sh` | `docker-compose.dev.yml` | Solo el Postgres compartido de dev (schema por servicio), sin pgAdmin | Todo o nada | Programar contra la BD sin tocar Docker a mano; además sincroniza el `.env` de cada microservicio |
| `./setup.sh` (sin flags) | `docker-compose.yml` + `docker-compose.dev.yml` | Plataforma (Keycloak/Kong/RabbitMQ) + Postgres dev + pgAdmin | Todo o nada | Día a día: cada micro corriendo en tu IDE con perfil `dev`, contra el Postgres compartido |
| `./setup.sh -f` | `docker-compose.yml` + `docker-compose.demo.yml` | Plataforma + los 5 microservicios + frontend, perfil `prod`, Postgres dedicado por servicio | `-s vehicle,spot` levanta solo ese subconjunto (+ sus dependencias) | Levantar rápido el stack completo, o solo una parte, sin esperar healthchecks |
| `./demo-stack.sh` | `docker-compose.yml` + `docker-compose.demo.yml` (**mismo stack que `setup.sh -f`, nunca toca `docker-compose.dev.yml`**) | Lo mismo que `setup.sh -f`: plataforma + 5 micros + mfe-entryexit + frontend | Sin `-s`. Solo `up --no-frontend`, o `restart <servicio>` para rehacer uno ya levantado | Cuando necesitas confirmar que TODO llegó a `healthy` antes de seguir (demos, scripts encadenados); `status`/`info` para ver puertos y estado sin levantar nada |

En corto: si quieres elegir qué microservicios arrancan, es `setup.sh -f -s
...`, `demo-stack.sh` no tiene esa opción. Si quieres la garantía de que todo
terminó `healthy` (o saber puertos/estado de un vistazo), es `demo-stack.sh`.
`dev-db.sh` y `setup.sh` (sin `-f`) son el único par que toca
`docker-compose.dev.yml`; todo lo demás usa `docker-compose.demo.yml`.

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
negocio, y para que `./setup.sh -c` (que borra los volúmenes de dev) no
se lleve el realm por delante.

El realm `parking` vive como código en [`keycloak/realm-export.dev-only.json`](keycloak/realm-export.dev-only.json)
y se importa solo al arrancar (`start-dev --import-realm`): un entorno recién
levantado ya tiene los roles `ADMIN`/`OPERARIO`/`USER`, el cliente público
`parking-frontend`, el cliente de servicio `parking-stay-service` (con el que
`stay-service` llama a los demás microservicios) y tres usuarios de prueba
(`admin.test`, `operario.test`, `user.test`, contraseñas `<Rol>.123!`).

> [!WARNING]
> **`--import-realm` solo importa si el realm NO existe.** Si ya tenías el
> stack levantado antes de un cambio en `realm-export.dev-only.json`, tu
> Keycloak **no** recibirá lo nuevo: seguirá con el realm viejo, sin avisar.
> El síntoma típico es un servicio que arranca bien y falla en su primera
> llamada saliente, lo que parece un bug de ese servicio y no lo es.
>
> Para aplicar un cambio del realm hay que recrear su volumen:
>
> ```bash
> docker compose -f docker-compose.yml -f docker-compose.demo.yml down
> docker volume rm tartis-recon-ia-parking-infra_parking-keycloak-db-data
> ./setup.sh -f
> ```
>
> Y acuérdate de rehacer el `.env` desde `.env.example` cuando aparezcan
> variables nuevas: `STAY_CLIENT_SECRET` no tiene valor por defecto y el
> compose falla a propósito si falta.

El realm incluye además un par de
claves RS256 **fijas** (`components.org.keycloak.keys.KeyProvider`) en vez de
dejar que Keycloak genere unas nuevas en cada `./setup.sh -c` — si no,
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
que devuelve 403. Ver [ADR-0001](docs/adr/0001-reparto-autorizacion-kong-spring-security.md).

`uri_param_names: []` en todas las rutas de API menos una: por defecto ese
campo vale `["jwt"]`, así que sin fijarlo Kong aceptaría el token por query
string y acabaría en el access log, en el historial del navegador y en la
cabecera `Referer`.

La excepción es `stay-service-events-route` (`/api/v1/events`, SSE-08), donde
`EventSource` no admite cabeceras y el token tiene que ir en la URL sí o sí.
Por eso es la única ruta con `uri_param_names: ["access_token"]` +
`header_names: []`, y la única con `file-log` propio: el serializer de Kong
redacta la cabecera `Authorization` de oficio, pero **no** la query string.
`scripts/ci/validate_kong.py` exige las dos cosas para ese nombre de ruta.

Verificar (con el stack `full` arriba, token de arriba en `$TOKEN`):

```bash
curl -i http://localhost:8000/api/v1/vehicles                              # sin token -> 401
curl -i http://localhost:8000/api/v1/vehicles -H "Authorization: Bearer $TOKEN"  # token valido
curl -i "http://localhost:8000/api/v1/vehicles?jwt=$TOKEN"                 # token en la URL -> 401

# SSE: al reves que el resto, solo por query string y solo con access_token
curl -N "http://localhost:8000/api/v1/events?access_token=$TOKEN"          # stream abierto
curl -i "http://localhost:8000/api/v1/events" -H "Authorization: Bearer $TOKEN"  # cabecera -> 401
docker logs parking-kong --tail 1 | grep -o '"querystring":[^,]*'          # -> "REDACTED"
```

Cambios en `kong.yml` requieren `docker compose restart kong` (no hay
Admin API de escritura en DB-less).

### Trazabilidad (GW-06)

Kong y Spring se reparten la traza, porque Kong solo puede dar la mitad:

| Quién | Qué aporta |
|---|---|
| Kong (`correlation-id`) | identidad de **petición** — `X-Correlation-ID`, propagada upstream |
| Cada micro (`CorrelationIdFilter`) | mete ese id en el MDC de sus logs |
| Cada micro (pendiente, tras SEC-07) | identidad de **usuario** — `sub` del JWT en el MDC |

Kong no puede identificar al usuario: el plugin `jwt` casa el token contra el
consumer cuyo `key` es el claim `iss`, y `admin.test`, `operario.test` y
`user.test` salen todos del mismo issuer, así que mapean al mismo consumer
`keycloak-parking`. Las cabeceras `X-Consumer-*` que Kong inyecta valen igual
para los tres y no sirven para auditar. Por eso la identidad sale del JWT dentro
de cada backend, y los logs de los seis contenedores se cruzan por el
correlation-id.

`echo_downstream: true` devuelve la cabecera al cliente, y `cors` la lista en
`exposed_headers` — sin eso el navegador la recibe pero el JavaScript del front
no puede leerla, así que el usuario no podría aportarla al reportar un fallo.

El plugin `file-log` escribe un registro JSON por petición a `/dev/stdout`, que
es donde Kong ya escribe, así que lo recoge `docker logs parking-kong`. **No
filtra el token**: el serializer de Kong redacta de oficio `Authorization` y
`Proxy-Authorization`. Lo que **no** redacta es la query string, y la duplica en
`request.uri`, `request.url` y `request.querystring` — irrelevante en estas 7
rutas, crítico en la ruta SSE cuando llegue (ver el comentario en `kong.yml`).

Verificar:

```bash
# la cabecera llega al cliente, incluso en un 401
curl -si http://localhost:8000/api/v1/tariffs | grep -i x-correlation-id

# el registro JSON sale y el token NO: debe imprimir "authorization":"REDACTED"
docker logs parking-kong --tail 1 | grep -o '"authorization":"[^"]*"'
```

### Validación automática

[`scripts/ci/validate_kong.py`](scripts/ci/validate_kong.py) comprueba los
invariantes de GW-03 y GW-06 sobre `kong.yml`: que ninguna ruta se quede sin
`jwt`, que todas verifiquen `exp`, que no acepten el token por query string ni
por cookie, y que la trazabilidad esté completa. Corre en cada PR desde
`.github/workflows/validate-infra.yml`, y en local sin necesidad de levantar
nada:

```bash
python3 scripts/ci/validate_kong.py kong/kong.yml
```

Las excepciones (hoy solo la futura ruta SSE) están declaradas como constantes
al principio del script, con su justificación. Ampliar ese set requiere tocar el
fichero y que se vea en la review.

### Autenticación Keycloak y Generación de Tráfico en Python (SIM-04)

Para scripts de automatización y pruebas de larga duración, se incluye un módulo Python nativo que gestiona la obtención y **renovación automática del token JWT** de Keycloak antes de que expire:

- **[`scripts/lib/keycloak_auth.py`](scripts/lib/keycloak_auth.py)**: Módulo reutilizable (`KeycloakAuthenticator`) que soporta **Password Grant** (`grant_type=password`) y **Client Credentials Grant** (`grant_type=client_credentials`), calculando dinámicamente el tiempo de refresco (`expires_in` menos margen de seguridad).
- **[`scripts/sim04_keycloak_token.py`](scripts/sim04_keycloak_token.py)**: Script ejecutable que permite obtener directamente el token JWT (`--token-only`) o simular tráfico continuo comprobando la auto-renovación sin producir errores `401 Unauthorized`.
- **[`scripts/tests/test_keycloak_auth.py`](scripts/tests/test_keycloak_auth.py)**: Suite de pruebas de integración REALES contra la instancia de Keycloak activa (`http://localhost:8180`) sin mocks.

```bash
# Ejecutar suite de pruebas reales contra Keycloak activo (sin mocks)
python3 scripts/tests/test_keycloak_auth.py

# Obtener únicamente el token y cabecera Bearer por consola
python3 scripts/sim04_keycloak_token.py --token-only

# Simulación de tráfico con Password Grant (default)
python3 scripts/sim04_keycloak_token.py --count 10 --min-delay 1 --max-delay 2

# Simulación con Client Credentials Grant
python3 scripts/sim04_keycloak_token.py --grant-type client_credentials \
  --client-id parking-stay-service \
  --client-secret stay-service-dev-secret-no-usar-fuera-de-local \
  --count 5
```





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
| **Clave privada RSA del realm en `keycloak/realm-export.dev-only.json`, en texto plano en un repo público** | Sin ella, la clave pública que Kong tiene hardcodeada dejaría de coincidir en cada `./setup.sh -c` (Keycloak generaría una nueva) | **Nunca** reusar este fichero fuera de local — quien lo tenga puede firmarse un JWT válido con rol `ADMIN`. El nombre del fichero y el `displayName` del realm avisan a propósito; si algún día hay un entorno real, claves nuevas generadas ahí, nunca las de aquí |

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
en solitario, usa `./setup.sh -f` o combina los dos ficheros a mano.

Cambias el `.env` y no se entera → `docker compose up -d --force-recreate`
(si tocas usuario o contraseña de Postgres, además `docker compose down -v`).

## Script SIM-06: Simulación de Check-Out y Tramos de Tarifa (RN-08)

El script `scripts/sim06_checkout_simulation.py` actúa como **punto de entrada principal MAIN** para la simulación de salidas de vehículos (`POST /api/v1/stays/check-out`), ejercitando la regla de negocio **RN-08** y activando los tres tramos tarifarios (**Minuto**, **Hora** y **Día**).

### Comandos de uso:

```bash
# 1. Obtener directamente el token JWT y la cabecera Authorization
python3 scripts/sim06_checkout_simulation.py --token-only

# 2. Lanzar la suite completa de pruebas de integración reales de Check-Out (9/9 tests)
python3 scripts/sim06_checkout_simulation.py --test

# 3. Simular tráfico completo (Check-In -> Check-Out) ejercitando los tramos de tarifa
python3 scripts/sim06_checkout_simulation.py --count 10 --distribution mixed

# 4. Simulación con Client Credentials Grant (Service Account)
python3 scripts/sim06_checkout_simulation.py --count 5 \
  --grant-type client_credentials \
  --client-id parking-stay-service \
  --client-secret stay-service-dev-secret-no-usar-fuera-de-local
```

