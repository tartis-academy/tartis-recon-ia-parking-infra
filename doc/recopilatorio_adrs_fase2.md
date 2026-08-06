# DOC-09 — Compendio Maestro de Architectural Decision Records (ADR) — Fase II

Este documento recopila de forma unificada las **Decisiones Arquitectónicas Clave (ADRs)** tomadas durante la **Fase II** del proyecto **TARTIS Recon-AI Parking**. Diseñado específicamente como guía de preparación para la **Demo Final (DEMO-04)**.

---

## Índice de Decisiones Arquitectónicas

1. [ADR-01: Patrón de Resiliencia por Llamada en Clientes HTTP (RES-01)](#adr-01-patrón-de-resiliencia-por-llamada-en-clientes-http-res-01)
2. [ADR-02: Kong API Gateway en Modo DB-less y Validación de `access_token` frente a OIDC (GW-02, INF-05)](#adr-02-kong-api-gateway-en-modo-db-less-y-validación-de-access_token-frente-a-oidc-gw-02-inf-05)
3. [ADR-03: Reparto de Responsabilidades de Autorización entre Kong y Spring Security (GW-04)](#adr-03-reparto-de-responsabilidades-de-autorización-entre-kong-y-spring-security-gw-04)
4. [ADR-04: Asincronía en el Sistema: Contrato de Eventos, Idempotencia y Mensajes Muertos (ASY-01)](#adr-04-asincronía-en-el-sistema-contrato-de-eventos-idempotencia-y-mensajes-muertos-asy-01)
5. [ADR-05: Ubicación del Emisor de Notificaciones en Tiempo Real SSE (SSE-01)](#adr-05-ubicación-del-emisor-de-notificaciones-en-tiempo-real-sse-sse-01)
6. [ADR-06: Autenticación de Server-Sent Events por Query Parameter `access_token` (SSE-08 / RFC 6750)](#adr-06-autenticación-de-server-sent-events-por-query-parameter-access_token-sse-08--rfc-6750)
7. [ADR-07: Modelo de Gestión de Usuarios y Roles en Keycloak IdP](#adr-07-modelo-de-gestión-de-usuarios-y-roles-en-keycloak-idp)

---

## ADR-01: Patrón de Resiliencia por Llamada en Clientes HTTP (RES-01)

### Estado
**Aceptada**

### Contexto
El microservicio orquestador `stay-service` realiza llamadas síncronas REST hacia `vehicle-service`, `spot-service` y `tariff-service` durante los flujos de check-in y check-out. Caídas parciales, retardos de red o fallos en microservicios secundarios no deben colapsar los hilos del servidor Tomcat ni inhabilitar la barrera de entrada.

### Decisión
Se implementa el patrón de **Resiliencia por Llamada Específica (Circuit Breaker / Timeouts / Fallbacks)** con la librería **Resilience4j** en cada adaptador HTTP cliente de `stay-service`:
- `StayVehicleClientAdapter`: Timeout de 2 segundos. Fallback que consulta la existencia del vehículo si el servicio no responde.
- `StaySpotClientAdapter`: Timeout estricto de 1.5 segundos en la ocupación de plaza.
- `StayTariffClientAdapter`: Fallback con tarifa ordinaria por defecto si `tariff-service` está inalcanzable.

### Consecuencias & Argumentario para la Demo
- **Ventaja:** Previene caídas en cascada (*cascading failures*). Si `vehicle-service` o `tariff-service` caen, el parking no se detiene por completo (degradación elegante).
- **Compromiso:** Requiere mantener métodos de *fallback* coherentes que no violen los invariantes de negocio.

---

## ADR-02: Kong API Gateway en Modo DB-less y Validación de `access_token` frente a OIDC (GW-02, INF-05)

### Estado
**Aceptada**

### Contexto
Se requería un API Gateway en el perímetro para unificar las peticiones del Frontend y aplicar seguridad centralizada. Se evaluó desplegar Kong con PostgreSQL (modo stateful) frente a Kong **DB-less** (modo declarativo en YAML `kong.yml`), y la validación directa del **`access_token`** en el perímetro frente a OIDC.

### Decisión
1. **Modo DB-less (`INF-05`):** Kong se despliega sin base de datos propia, cargando la configuración de rutas y servicios desde el archivo declarativo `kong.yml`.
2. **Validación de `access_token` (`GW-02`):** Se utiliza el plugin de autenticación validando la firma del **`access_token`** (Bearer token emitido por Keycloak) mediante la clave pública RSA en lugar del plugin `oidc`.

### Consecuencias & Argumentario para la Demo
- **¿Por qué DB-less?** Elimina la dependencia de una base de datos exclusiva para el Gateway, reduce el consumo de RAM/CPU a menos de 100MB y permite despliegues inmutables (*Infrastructure as Code*).
- **¿Por qué validación de `access_token` sobre `oidc`?** El plugin `oidc` requiere mantener sesiones HTTP en servidor o realizar llamadas síncronas de introspección hacia Keycloak por cada petición. Validar el **`access_token`** directamente comprueba la firma criptográfica RSA en memoria en < 1 milisegundo (stateless puro).

---

## ADR-03: Reparto de Responsabilidades de Autorización entre Kong y Spring Security (GW-04)

### Estado
**Aceptada**

### Contexto
Existía la duda sobre si Kong debía encargarse de todo el control de acceso (validación de token y restricción de roles por ruta) o si cada microservicio debía mantener su propia seguridad.

### Decisión
Se aplica el principio de **Defensa en Profundidad (*Defense in Depth*)** repartiendo las responsabilidades:
- **Kong (Perímetro / Autenticación):** Intercepta la petición externa en los puertos `8000`/`8443`. Comprueba la validez, expiración (`exp`) y firma del **`access_token`**. Si no hay token o es inválido, rechaza con `401 Unauthorized`.
- **Spring Security (Backend / Autorización Fina RBAC `SEC-03`):** Cada microservicio actúa como un OAuth2 Resource Server. Descodifica los *claims* del **`access_token`** y mediante la clase `KeycloakRoleConverter` extrae los roles (`ADMIN`, `OPERARIO`, `USER`), aplicando reglas `@PreAuthorize` a nivel de controlador y método.

### Consecuencias & Argumentario para la Demo
- Evita acoplar reglas complejas de negocio en la configuración del API Gateway.
- Si un atacante lograse saltarse Kong o acceder a la red interna Docker, los microservicios siguen protegidos exigiendo un **`access_token`** válido firmado con las autoridades correspondientes.

---

## ADR-04: Asincronía en el Sistema: Contrato de Eventos, Idempotencia y Mensajes Muertos (ASY-01)

### Estado
**Aceptada**

### Contexto
Tras un check-out en `stay-service`, la emisión del ticket y la liberación de la plaza deben ocurrir de forma **asíncrona y desacoplada** sin bloquear la respuesta HTTP de la barrera de salida. RabbitMQ entrega mensajes con garantía *at-least-once* (al menos una vez), por lo que un evento duplicado o desfasado podría intentar liberar una plaza ya libre o duplicar tickets.

### Decisión
1. **Publicación Asíncrona (ASY-01):** `stay-service` emite `StayClosedEvent` (`stayId`, `vehicleId`, `spotId`, `totalAmount`, `closedAt`) al Exchange Topic `stay.events` sin esperar la finalización del procesamiento en los servicios consumidores.
2. **Consumo Asíncrono e Idempotencia:**
   - `ticket-service` (`ticket-service-stay-closed-queue`): Restricción de unicidad en base de datos `uk_stay_id`. Si recibe un evento duplicado, la excepción `TicketAlreadyExistsException` es capturada confirmando el mensaje (`ACK`) sin fallar la cola.
   - `spot-service` (`spot-service-stay-closed-queue`): Captura `SpotNotOccupiedException` y confirma el mensaje si la plaza ya estaba liberada.
3. **Dead Letter Queues (DLQ):** Tras 6 reintentos exponenciales fallidos, los mensajes se desvían a `ticket-service-stay-closed-dlq` y `spot-service-stay-closed-dlq`.

### Consecuencias & Argumentario para la Demo
- **Desacoplamiento Temporal:** La respuesta de salida del vehículo es instantánea.
- Demuestra arquitectura reactiva e impulsada por eventos (*Event-Driven Architecture*).
- Garantiza **consistencia eventual** e **idempotencia total** sin envenenamiento de colas (*poison pill messages*).

---

## ADR-05: Ubicación del Emisor de Notificaciones en Tiempo Real SSE (SSE-01)

### Estado
**Aceptada**

### Contexto
El Frontend requiere actualizar de forma reactiva en pantalla la ocupación de plazas y el estado de las estancias. Se evaluó crear un microservicio de notificaciones o emitir el stream SSE desde `stay-service`.

### Decisión
`stay-service` expone el endpoint `GET /v1/events` (`EventStreamRestAdapter` + `SseEmitterRegistry`) emitiendo el canal `text/event-stream` con eventos `event:stay_updated`.

### Consecuencias & Argumentario para la Demo
- **Simplicidad Arquitectónica:** `stay-service` es el orquestador natural del dominio de estancias. Crear un sexto microservicio exclusivo para notificaciones habría añadido complejidad innecesaria.
- **Limitación Conocida:** El registro `SseEmitterRegistry` almacena las conexiones en la memoria (heap) de la JVM. Para escalar `stay-service` horizontalmente a múltiples réplicas se requeriría un bus de pub/sub como Redis para *broadcast* entre instancias.

---

## ADR-06: Autenticación de Server-Sent Events por Query Parameter `access_token` (SSE-08 / RFC 6750)

### Estado
**Aceptada**

### Contexto
La especificación nativa del navegador HTML5 `EventSource` (`new EventSource('/v1/events')`) **no permite enviar cabeceras HTTP personalizadas** (como `Authorization: Bearer <access_token>`).

### Decisión
Se habilita la autenticación del token de acceso mediante el parámetro de consulta en la URL:  
`GET /v1/events?access_token=<ACCESS_TOKEN>`  
Soportado oficialmente por el estándar **RFC 6750 (Sección 2.3 - URI Query Parameter)** y configurado en la clase `SecurityConfig.SSE_PATH` de `stay-service`.

### Consecuencias & Argumentario para la Demo
- Permite usar la API nativa de JavaScript del navegador sin necesidad de envoltorios o librerías externas complejas.
- **Mitigación de Seguridad:** La extracción del token por el parámetro `access_token` está restringida **únicamente** a la ruta `/v1/events`. En el resto de endpoints REST del sistema se exige strictly la cabecera `Authorization: Bearer <access_token>`.

---

## ADR-07: Modelo de Gestión de Usuarios y Roles en Keycloak IdP

### Estado
**Aceptada**

### Contexto
Es necesario definir la estructura de la base de identidades para el gobierno del acceso RBAC mediante la emisión del `access_token`.

### Decisión
- **Realm:** `parking`.
- **Roles de Realm:** `ADMIN`, `OPERARIO`, `USER`.
- **Usuarios de Prueba Preconfigurados:**
  - `admin@parking.com` / `admin123` $\rightarrow$ Rol `ADMIN` (acceso a configuración de tarifas, bajas lógicas y cancelación de estancias).
  - `operario@parking.com` / `operario123` $\rightarrow$ Rol `OPERARIO` (operaciones habituales de check-in, check-out y consulta de plazas).
  - `user@parking.com` / `user123` $\rightarrow$ Rol `USER` (consulta pública por código de ticket).

### Consecuencias & Argumentario para la Demo
- Garantiza la demostración en vivo del cumplimiento de la matriz de autorización **SEC-03**, probando que peticiones sin el `access_token` adecuado devuelven `403 Forbidden`.
