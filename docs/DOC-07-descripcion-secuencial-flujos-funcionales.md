# DOC-07 - Descripción Secuencial de los Tres Flujos Funcionales

Este documento constituye la especificación secuencial detallada texto paso a paso de los tres flujos funcionales del sistema de gestión de aparcamiento (`tartis-recon-ai-parking`). 

Esta especificación es independiente de los diagramas visuales y detalla cada etapa del procesamiento desde la recepción del mensaje HTTP con token de autenticación en el API Gateway hasta las respuestas de backend, DTOs, persistencia y emisión de eventos.

---

## 1. Contexto Arquitectónico General

La plataforma está construida sobre una arquitectura de microservicios descompuestos por dominio de negocio:

- **Kong API Gateway**: Punto de entrada unificado (`http://localhost:8000/api/v1/...`). Realiza la validación JWT RS256 en el borde (`claims_to_verify: ["exp"]`) e inyecta la cabecera de trazabilidad `X-Correlation-ID`.
- **Keycloak (Identity Provider)**: Emisor de tokens JWT (Realm `parking`) con asignación de roles (`ADMIN`, `OPERARIO`, `USER`).
- **Vehicle Service (`vehicleService`)**: Gestión del catálogo de vehículos y sus clasificaciones exactas del dominio (`CAR`, `CAR_PMR`, `MOTORBIKE`).
- **Spot Service (`spotService`)**: Gestión del inventario de plazas de aparcamiento y su estado operacional (`DISPONIBLE`, `OCUPADA`, `MANTENIMIENTO`).
- **Tariff Service (`tariffService`)**: Definición de esquemas tarifarios y motor de cálculo de importes (`POST /v1/tariffs/calculate`).
- **Ticket Service (`ticketService`)**: Generación y control de tickets de entrada (`/v1/entry-tickets`) y tickets de cobro/salida (`/v1/tickets`).
- **Stay Service (`stayService`)**: Orquestación del ciclo de vida de la estancia (check-in/check-out) y emisor de eventos SSE (`event:stay_updated`).
- **RabbitMQ**: Bus de eventos asíncronos entre servicios.

---

## 2. Flujo Funcional 1: Entrada de Vehículo (Check-in)

### Objetivo
Registrar el acceso de un vehículo al aparcamiento, verificar disponibilidad, reservar plaza, generar ticket de entrada y estancia, retornando la confirmación con estado **HTTP 201 Created**.

### Descripción Secuencial Paso a Paso

1. **Petición del Cliente (Inicio del Flujo)**:
   - El cliente (terminal de entrada o aplicación web de operario) envía una petición HTTP `POST` a la ruta unificada `/api/v1/stays/check-in` (que Kong reenvía internamente a `/v1/stays/check-in` en `stay-service`).
   - La petición incluye en la cabecera HTTP: `Authorization: Bearer <JWT_ACCESS_TOKEN>`.
   - El cuerpo de la petición (JSON `StayRequest`) contiene los campos obligatorios del vehículo:
     - `plate` (String, matrícula del vehículo).
     - `vehicleType` (Enum: `CAR`, `CAR_PMR` o `MOTORBIKE`).

2. **Recepción y Validación en Kong API Gateway**:
   - Kong intercepta la petición entrante en `/api/v1/stays/check-in`.
   - El plugin `jwt` verifica la firma RS256 del token contra la clave pública del Realm `parking` de Keycloak.
   - Kong valida la vigencia del token comprobando el claim `exp`. Si el token ha expirado o la firma es inválida, Kong detiene el flujo y responde inmediatamente con `HTTP 401 Unauthorized`.
   - El plugin `correlation-id` inyecta o genera la cabecera `X-Correlation-ID` en la petición entrante para asegurar la trazabilidad entre microservicios.

3. **Enrutamiento e Inserción de Trazabilidad en Backend**:
   - Kong reenvía la petición al backend `stay-service`.
   - El filtro `CorrelationIdFilter` del microservicio `stay-service` extrae la cabecera `X-Correlation-ID` y la registra en el contexto de diagnóstico de logs (`MDC`).
   - La identidad del usuario que realiza la acción se extrae del claim `sub` del JWT y se añade al contexto de log.

4. **Autorización a Nivel de Aplicación (Spring Security)**:
   - Spring Security en `StayRestAdapter` inspecciona los roles del JWT.
   - Se evalúa la anotación `@PreAuthorize("hasAnyRole('ADMIN', 'OPERARIO')")`. Si el usuario posee el rol `ADMIN` u `OPERARIO`, se permite continuar la ejecución; de lo contrario, responde con `HTTP 403 Forbidden`.

5. **Verificación y Registro del Vehículo (`vehicleService`)**:
   - `stay-service` realiza una llamada interna hacia `vehicle-service` enviando la matrícula (`plate`).
   - `vehicle-service` verifica si el vehículo existe en la base de datos (schema `vehicle`).
   - Si no existe, lo registra de forma automática asociando su tipo exacto (`CAR`, `CAR_PMR` o `MOTORBIKE`). Retorna los datos validados del vehículo.

6. **Comprobación de Disponibilidad y Reserva de Plaza (`spotService`)**:
   - `stay-service` solicita a `spot-service` una plaza libre adecuada para el tipo de vehículo (`CAR`, `CAR_PMR` o `MOTORBIKE`).
   - `spot-service` consulta el inventario en el schema `spot` filtrando por estado `DISPONIBLE` y tipo de vehículo compatible.
   - De haber disponibilidad, `spot-service` ejecuta la ocupación: actualiza el estado de la plaza elegida a `OCUPADA` y retorna la plaza reservada (`spotId`, número de plaza).
   - *Caso de excepción*: Si no hay plazas libres, se interrumpe la transacción y se devuelve `HTTP 409 Conflict` (Parking completo, regla RN-01) o `HTTP 422 Unprocessable Entity` si el vehículo está dado de baja (RN-11) o ya está dentro (CB-05).

7. **Generación de Ticket de Entrada y Creación de Estancia (`ticketService` / `stayService`)**:
   - `stay-service` invoca a `ticket-service` (`POST /v1/entry-tickets`) para generar un ticket de entrada con su identificador único (`entryTicketId`).
   - `stay-service` crea y persiste la nueva entidad de Estancia (`Stay`) en el schema `stay` registrando:
     - `stayId` (UUID).
     - `plate` (matrícula).
     - `spotId` (plaza asignada).
     - `entryTicketId` (ticket asignado).
     - `entryDate` (timestamp actual de entrada).
     - `status` (`ACTIVE`).

8. **Respuesta HTTP 201 Created**:
   - `stay-service` retorna el objeto `CheckInResponse` en el cuerpo de la respuesta con el código **HTTP 201 Created**.
   - Incluye la cabecera `X-Correlation-ID` devuelta al cliente.

---

## 3. Flujo Funcional 2: Salida de Vehículo (Check-out)

### Objetivo
Registrar la salida de un vehículo, calcular la duración e importe mediante `tariffService`, liberar la plaza en `spotService`, cerrar la estancia y emitir eventos SSE y RabbitMQ, finalizando con **HTTP 200 OK**.

### Descripción Secuencial Paso a Paso

1. **Petición del Cliente (Inicio de Check-out)**:
   - El cliente realiza una petición HTTP `POST` a la ruta `/api/v1/stays/check-out` (reenviada internamente a `/v1/stays/check-out` en `stay-service`).
   - Incluye en la cabecera: `Authorization: Bearer <JWT_ACCESS_TOKEN>`.
   - El cuerpo de la petición (JSON `StayCheckOutRequest`) contiene:
     - `plate` (String, matrícula del vehículo) y/o `entryTicketId` (UUID del ticket de entrada).

2. **Validación Gateway y Trazabilidad**:
   - Kong API Gateway valida la firma RS256 y vigencia del JWT (`HTTP 401` si falla).
   - Kong inyecta/propaga el `X-Correlation-ID`.
   - Reenvía la petición a `stay-service`.

3. **Autorización en Spring Security**:
   - `stay-service` evalúa `@PreAuthorize("hasAnyRole('ADMIN', 'OPERARIO')")`. Si falta el rol, responde con `HTTP 403 Forbidden`.

4. **Búsqueda y Verificación de Estancia Activa**:
   - `stay-service` consulta en el schema `stay` la estancia activa (`status = ACTIVE`) mediante la matrícula o `entryTicketId`.
   - Si no existe estancia activa, el sistema retorna `HTTP 404 Not Found`.
   - Se captura la fecha/hora exacta de salida (`exitDate`).

5. **Cálculo de Importe (`tariffService`)**:
   - `stay-service` invoca a `tariff-service` (`POST /v1/tariffs/calculate`) enviando el `vehicleType` (`CAR`, `CAR_PMR` o `MOTORBIKE`) y la duración en minutos entre `entryDate` y `exitDate`.
   - `tariff-service` aplica las reglas tarifarias activas del schema `tariff` y calcula el importe total (`totalAmount`).
   - Retorna el DTO de cálculo de precio.

6. **Liberación de Plaza (`spotService`)**:
   - `stay-service` invoca a `spot-service` (`POST /v1/spots/{spotId}/release` o `PATCH /v1/spots/{spotId}/status`) enviando el `spotId`.
   - `spot-service` cambia el estado de la plaza en el schema `spot` de `OCUPADA` a `DISPONIBLE`.

7. **Generación de Ticket de Salida y Cierre de Estancia**:
   - `stay-service` invoca a `ticket-service` (`POST /v1/tickets`) para generar el ticket de cobro/salida.
   - `stay-service` actualiza la entidad `Stay` en el schema `stay`:
     - Asigna `exitDate`.
     - Asigna `totalAmount`.
     - Cambia `status` de `ACTIVE` a `CLOSED`.

8. **Emisión de Eventos de Dominio (SSE y RabbitMQ)**:
   - `stay-service` emite el evento `event:stay_updated` a través del canal Server-Sent Events (`GET /v1/events`, expuesto con token en query string `?access_token=`).
   - El payload del evento incluye `StayClosedEvent` con `stayId`, `spotId`, `plate`, `entryDate`, `exitDate` y `totalAmount`.
   - Paralelamente, se emite el evento al bus RabbitMQ.

9. **Respuesta HTTP 200 OK**:
   - `stay-service` responde con el objeto `CheckOutResponse` y código **HTTP 200 OK**, incluyendo el importe total calculado y los tiempos de la estancia.

---

## 4. Flujo Funcional 3: Gestión de Tarifas, Plazas, Vehículos y Administradores

### Objetivo
Permitir el mantenimiento CRUD de las entidades maestras del sistema con control de acceso por rol en Spring Security y seguimiento por audit logs.

---

### 4.1 Subflujo: Gestión de Tarifas (`tariffService`)

1. **Rutas REST en `TariffRestAdapter` (`/api/v1/tariffs`)**:
   - `GET /api/v1/tariffs/active?type={type}`: Consulta tarifas activas por tipo de vehículo (`CAR`, `CAR_PMR`, `MOTORBIKE`).
   - `GET /api/v1/tariffs`: Listado completo de tarifas.
   - `GET /api/v1/tariffs/{id}`: Detalle de una tarifa.
   - `POST /api/v1/tariffs`: Creación de nueva tarifa (`HTTP 201 Created`).
   - `PUT /api/v1/tariffs/{id}`: Modificación completa de tarifa (`HTTP 200 OK`).
   - `PATCH /api/v1/tariffs/{id}/status`: Activación/Desactivación de tarifa (`HTTP 200 OK`).
   - `POST /api/v1/tariffs/calculate`: Motor de cálculo de precios.
2. **Autorización**:
   - Creación y modificación restringidas al rol `ADMIN` en Spring Security.

---

### 4.2 Subflujo: Gestión de Plazas (`spotService`)

1. **Rutas REST en `SpotRestAdapter` (`/api/v1/spots`)**:
   - `GET /api/v1/spots`: Consulta de todas las plazas (`ADMIN`, `OPERARIO`).
   - `GET /api/v1/spots/availability?type={type}`: Consulta disponibilidad por tipo de vehículo.
   - `POST /api/v1/spots`: Alta de plaza para un tipo de vehículo (`CAR`, `CAR_PMR`, `MOTORBIKE`), rol `ADMIN` (`HTTP 201 Created`).
   - `PUT /api/v1/spots/{id}`: Actualización de plaza, rol `ADMIN` (`HTTP 200 OK`).
   - `PATCH /api/v1/spots/{id}/status`: Cambio de estado (`DISPONIBLE`, `OCUPADA`, `MANTENIMIENTO`), roles `ADMIN`, `OPERARIO` (`HTTP 200 OK`).
   - `POST /api/v1/spots/occupy`: Ocupación directa de plaza, rol `ADMIN` (`HTTP 200 OK`).
   - `POST /api/v1/spots/{id}/release`: Liberación directa de plaza, rol `ADMIN` (`HTTP 200 OK`).

---

### 4.3 Subflujo: Gestión de Vehículos (`vehicleService`)

1. **Rutas REST en `VehicleRestAdapter` (`/api/v1/vehicles`)**:
   - `GET /api/v1/vehicles/{plate}`: Consulta de un vehículo por matrícula.
   - `POST /api/v1/vehicles`: Alta de un vehículo asociando su matrícula y `vehicleType` (`CAR`, `CAR_PMR`, `MOTORBIKE`).
2. **Procesamiento**:
   - Validación y actualización directa en el schema `vehicle`.

---

### 4.4 Subflujo: Gestión de Administradores y Seguridad (Keycloak & Spring Security)

1. **Autenticación (Obtención de JWT)**:
   - `POST http://localhost:8180/realms/parking/protocol/openid-connect/token`
   - `client_id=parking-frontend`, `grant_type=password`, `username`, `password`.
   - Retorna JWT firmado RS256 con claims `realm_access.roles` (`ADMIN`, `OPERARIO`, `USER`) y `sub` (UUID del usuario).
2. **Autorización Distribuida**:
   - Kong verifica firma RS256 y expiración en la frontera.
   - Cada microservicio evalúa anotaciones `@PreAuthorize` o `@PostAuthorize` (ej. en `getStay` para evitar vulnerabilidades IDOR comprobando la coincidencia de matrícula o rol elevado).
3. **Auditoría**:
   - Traza correlacionada en logs de los 5 microservicios cruzando `X-Correlation-ID` con el claim `sub`.

---

## 5. Matriz Resumen de Respuestas y Trazabilidad

| Flujo | Método HTTP & Ruta | Body / Params | Rol Requerido | Código HTTP | Componentes Clave |
|---|---|---|---|---|---|
| **Check-in** | `POST /api/v1/stays/check-in` | `StayRequest` (`plate`, `vehicleType`) | `ADMIN`, `OPERARIO` | **201 Created** | Kong, Keycloak, `vehicleService`, `spotService`, `ticketService`, `stayService` |
| **Check-out** | `POST /api/v1/stays/check-out` | `StayCheckOutRequest` (`plate`, `entryTicketId`) | `ADMIN`, `OPERARIO` | **200 OK** | Kong, `stayService`, `tariffService`, `spotService`, SSE (`stay_updated`), RabbitMQ |
| **Consultar Estancia** | `GET /api/v1/stays/{stayId}` | `{stayId}` en path | `ADMIN`, `OPERARIO`, `USER` (suya) | **200 OK** | Kong, `stayService` (con `@PostAuthorize`) |
| **SSE Eventos** | `GET /api/v1/events` | `?access_token=<JWT>` | `ADMIN`, `OPERARIO` | **200 OK** (Stream) | Kong, `stayService` (`EventStreamRestAdapter`) |
| **Crear Plaza** | `POST /api/v1/spots` | `SpotRequest` (`type`) | `ADMIN` | **201 Created** | Kong, `spotService` |
| **Liberar Plaza** | `POST /api/v1/spots/{id}/release` | `{id}` en path | `ADMIN` | **200 OK** | Kong, `spotService` |
| **Crear Tarifa** | `POST /api/v1/tariffs` | `TariffCreateRequest` | `ADMIN` | **201 Created** | Kong, `tariffService` |
| **Calcular Tarifa** | `POST /api/v1/tariffs/calculate` | `TariffPriceRequest` (`vehicleType`, `minutes`) | Interno / Gateway | **200 OK** | `tariffService` |
| **Login Keycloak** | `POST /realms/parking/.../token` | `grant_type=password`, etc. | Público (credenciales) | **200 OK** | Keycloak |
