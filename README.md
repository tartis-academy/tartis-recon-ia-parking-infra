# tartis-recon-ai-parking — Infraestructura y Descripción General del Sistema

Sistema integral de gestión de parking inteligente (**TARTIS Recon-AI**). Orquesta el ciclo de vida completo de las estancias de vehículos en estacionamiento mediante una arquitectura de microservicios hexagonales, seguridad perimetral OAuth2/OIDC, mensajería asíncrona por eventos y notificaciones en tiempo real.

Entorno local COMPARTIDO para los microservicios de tartis-recon-ai-parking:
Postgres de dev con un schema por servicio (`vehicle`, `spot`, `tariff`,
`ticket`, `stay`), pgAdmin y SonarQube.

Este repo NO contiene el Postgres dedicado de cada servicio (perfil `prod` /
servicio aislado, database-per-service): ese vive en el `docker-compose.yml`
raíz de cada repo de microservicio, con su propio `./setup.sh`.

## Descripción del Sistema y Arquitectura

El sistema automatiza el control de acceso, la asignación atómica de plazas, el cálculo tarifario por tramos y la emisión/gestión de tickets de entrada y cobro:

- **Check-in de Vehículo:** Registro de entrada en terminal/barrera con comprobación de disponibilidad por categoría (**RN-01**), verificación síncrona de existencia y estado activo del vehículo (**RN-11**), asignación atómica de plaza (**RN-05**) y emisión de ticket de entrada (`EntryTicket`) con código de barras.
- **Check-out y Salida de Vehículo:** Lectura de matrícula o ticket de salida, cálculo síncrono del importe exacto mediante `tariff-service` (**RN-06** a **RN-09**), cierre de estancia a estado terminal `FINISHED` (**IN-19**), publicación asíncrona del evento de dominio `StayClosedEvent` hacia RabbitMQ para la emisión del ticket de cobro (**IN-20**) y la liberación de la plaza ocupada a `AVAILABLE`, y emisión instantánea del evento mediante Server-Sent Events (SSE).
- **Cancelación Manual de Estancia (CB06 / RN-02):** Permite a administradores cancelar estancias de vehículos que dan marcha atrás antes de cruzar la barrera, pasando la estancia a estado terminal `CANCELLED` (**IN-19**) y liberando la plaza reservada.
- **Gestión de Excepciones e Incidencias:** Marcado de tickets perdidos (**IN-22**), bloqueo de plazas por mantenimiento (**RN-10**), gestión de bajas/altas lógicas de vehículos (**RN-11**) y resiliencia con colas de mensajes muertos (DLQ) y cortocircuitos Resilience4j.

---

## Componentes del Ecosistema

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
contenedores) y espera a que estén listos.

```bash
./setup.sh              # levanta todo
./setup.sh down         # para los contenedores
./setup.sh clean        # para y BORRA los datos de la BD
```

Si prefieres ir a mano, los pasos son estos.

Crea la red compartida que conecta pgAdmin con los Postgres de cada servicio
(solo la primera vez).

```bash
docker network create parking-shared
```

Levanta el Postgres de dev, pgAdmin (5050) y SonarQube (9000).

```bash
cp .env.example .env
docker compose up -d
```

Comprueba que los contenedores estén `healthy`.

```bash
docker compose ps
```

Para los contenedores (con `-v` además borra los datos de la BD).

```bash
docker compose down
```

## Datos de conexión

| Dato | Valor |
|---|---|
| pgAdmin | http://localhost:5050 (usuario y contraseña de tu `.env`) |
| SonarQube | http://localhost:9000 (`admin`/`admin`) |
| BD desde tu máquina | `localhost:5432` · `parking_dev` (schemas: vehicle, spot, tariff, ticket, stay) |
| BD desde pgAdmin | `parking-dev-postgres:5432` (nombre del contenedor, puerto interno) |

Cada microservicio, en su perfil de dev, apunta a esta BD usando su propio
schema (`search_path` o equivalente). Para el perfil `prod` / servicio
aislado, cada servicio usa su propio Postgres dedicado (ver el repo de ese
servicio).

## Probar los servicios

En `postman/` están las colecciones para probar los cinco microservicios contra
este entorno: una por servicio, una E2E con el flujo de entrada completo y un
environment con las cinco `baseUrl` ya configuradas.

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

Cambias el `.env` y no se entera → `docker compose up -d --force-recreate`
(si tocas usuario o contraseña de Postgres, además `docker compose down -v`).
