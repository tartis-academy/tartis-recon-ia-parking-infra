# Colecciones Postman — TARTIS Recon-AI Parking

Colecciones para probar los cinco microservicios del parking en local.

**Verificado contra el código de `origin/release123` de cada repo el 2026-07-23**,
no contra el `openapi.yml`. Donde el contrato y la implementación divergen manda
el código, y la divergencia queda anotada en la descripción de cada request.

---

## Cómo usarlo (de cero a probando)

1. **Levanta la BD compartida**, desde la raíz de este repo:

   ```bash
   ./setup.sh
   ```

2. **Arranca los cinco servicios**, cada uno desde su repo y en su propia
   terminal, con el puerto que espera el environment (detalle y motivo en
   [Levantar los servicios](#levantar-los-servicios)):

   ```bash
   SERVER_PORT=8080 ./mvnw spring-boot:run   # vehicle
   SERVER_PORT=8081 ./mvnw spring-boot:run   # spot
   SERVER_PORT=8082 ./mvnw spring-boot:run   # tariff
   SERVER_PORT=8083 ./mvnw spring-boot:run   # ticket
   ```

   `stay` necesita además las URLs de los demás y la rama
   `feature/checkin-usecase` — ver [Stay necesita saber dónde están los
   demás](#stay-necesita-saber-dónde-están-los-demás).

3. **Importa** en Postman: **Import → Files** → los 7 ficheros de esta carpeta
   de golpe. Arriba a la derecha selecciona el environment
   **Parking - Local (dev)**.

4. **Ejecuta en este orden.** Las colecciones encadenan solas: cada request de
   creación guarda el id (`vehicleId`, `spotId`, `tariffId`, `stayId`) en el
   environment con un test script, así que no hay que copiar nada a mano.

   | Orden | Colección | Qué esperar |
   |---|---|---|
   | 1 | Vehicle | Todo verde |
   | 2 | Spot | Todo verde |
   | 3 | Tariff | Todo verde |
   | 4 | Ticket | 200 con **cuerpo vacío** — es un esqueleto, ver `[STUB]` |
   | 5 | Stay | Solo el check-in, y solo desde `feature/checkin-usecase` |
   | 6 | Parking · E2E | El flujo de entrada completo |

   Dentro de cada colección, ejecuta de arriba abajo (o con el **Collection
   Runner**, botón *Run*). La carpeta *Pendiente de implementar* del final falla
   a propósito: son endpoints que están en el contrato pero no en el código.

5. **Empieza por la E2E si solo quieres ver el flujo de entrada.** Tiene dos
   carpetas: *"1. Simulación manual"* reproduce el check-in llamando a los cinco
   servicios a mano y **funciona hoy**; *"2. Check-in real"* hace la única
   llamada a `/v1/stays/check-in` y **falla** por los bugs 1 y 2 de
   [Bugs conocidos](#bugs-conocidos-que-verás-al-probar). La primera es el
   sustituto temporal de la segunda.

Antes de abrir una incidencia por un fallo, mira
[Bugs conocidos](#bugs-conocidos-que-verás-al-probar) y las etiquetas
`[TODO]` / `[STUB]`: casi todo lo que falla, falla por algo ya documentado aquí.

También se pueden correr desde la terminal con
[newman](https://github.com/postmanlabs/newman), útil para CI:

```bash
newman run Vehicle-Service.postman_collection.json \
  -e Parking-Local.postman_environment.json
```

---

## Qué hay aquí

| Fichero | Contenido |
|---|---|
| `Parking-Local.postman_environment.json` | Environment único: las 5 `baseUrl` + variables de recurso |
| `Vehicle-Service.postman_collection.json` | CRUD de vehículos — **todo implementado** |
| `Spot-Service.postman_collection.json` | Plazas: CRUD + ocupar/liberar — **todo implementado** |
| `Tariff-Service.postman_collection.json` | Tarifas: CRUD + activas + estado — **todo implementado** |
| `Ticket-Service.postman_collection.json` | Tickets y recibos — **esqueleto, ningún método hace nada** |
| `Stay-Service.postman_collection.json` | Check-in (HU-01) — **solo en la rama `feature/checkin-usecase`** |
| `Parking-E2E.postman_collection.json` | El flujo de entrada completo, por los dos caminos |

## Importar

En Postman: **Import → Files** → selecciona los 7 ficheros de golpe.
Luego arriba a la derecha elige el environment **Parking - Local (dev)**.

---

## Levantar los servicios

Los cinco escuchan en `8080` por defecto — es una decisión del proyecto, no un
olvido. Para tenerlos a la vez en el host hay que sobreescribir `SERVER_PORT`,
**sin tocar el default de `application.properties`**:

```bash
# Una terminal por servicio
SERVER_PORT=8080 ./mvnw spring-boot:run   # vehicle
SERVER_PORT=8081 ./mvnw spring-boot:run   # spot
SERVER_PORT=8082 ./mvnw spring-boot:run   # tariff
SERVER_PORT=8083 ./mvnw spring-boot:run   # ticket
SERVER_PORT=8084 ./mvnw spring-boot:run   # stay
```

Esos son los puertos que trae el environment. Si cambias alguno, cámbialo también
en la variable `baseUrl*` correspondiente.

Antes, levanta el Postgres de dev (un contenedor, 5 schemas) desde la raíz de
este repo:

```bash
./setup.sh
```

### Stay necesita saber dónde están los demás

`stay-service` trae por defecto nombres de contenedor Docker, que en local no
resuelven. Si lo corres en el host, sobreescribe las URLs:

```bash
SERVER_PORT=8084 \
SERVICES_VEHICLE_URL=http://localhost:8080 \
SERVICES_SPOT_URL=http://localhost:8081 \
SERVICES_TARIFF_URL=http://localhost:8082 \
SERVICES_TICKET_URL=http://localhost:8083 \
./mvnw spring-boot:run
```

### Rama de stay

En `release123` el `StayRestAdapter` de stay está **vacío**: no existe ningún
endpoint y toda la colección de stay da 404. El `POST /v1/stays/check-in` solo
está en **`feature/checkin-usecase`**. Levanta stay desde esa rama.

---

## Convenciones de la colección

- **`[TODO]`** en el nombre → la ruta está en el `openapi.yml` pero **no hay
  controlador**. Da 404/405. Están agrupadas en la carpeta *Pendiente de
  implementar* de cada colección.
- **`[STUB]`** → el endpoint existe y está mapeado, pero el método hace
  `return null`. Spring lo traduce a **200 OK con cuerpo vacío**, así que *parece*
  que funciona. Todo `ticket-service` está así.
- Las requests sin prefijo funcionan de verdad.

Esto convierte la colección en una checklist contrato-vs-implementación, además
de una suite de pruebas. Cuando alguien implemente un `[STUB]`, el test que
comprueba "el cuerpo sigue vacío" empezará a fallar: esa es la señal de que toca
actualizar la request.

Las variables `vehicleId`, `spotId`, `tariffId`, `stayId` se rellenan solas: cada
request de creación las guarda en el environment con un test script. Ejecuta las
colecciones en orden (o con el Collection Runner) y encadenan.

---

## Valores válidos

| Enum | Valores | Dónde |
|---|---|---|
| `VehicleType` | `CAR`, `CAR_PMR`, `MOTORBIKE` | vehicle, spot, tariff, stay |
| `SpotStatus` | `AVAILABLE`, `OCCUPIED`, `UNAVAILABLE` | spot |
| `StayStatus` | `IN_PROGRESS`, `PAY_PENDING`, `PAID`, `FINISHED`, `CANCELLED` | stay |

Cuerpo de error común a todos los servicios:

```json
{ "timestamp": "...", "status": 409, "error": "CONFLICT", "message": "...", "path": "/v1/stays/check-in" }
```

---

## Bugs conocidos que verás al probar

Ninguno de estos es un fallo de la colección. Están anotados también en la
request correspondiente.

1. **El check-in no ocupa plaza nunca.**
   `StaySpotClientAdapter.occupySpot` llama con `.patch()` a `/v1/spots/occupy`,
   pero spot expone `@PostMapping("/occupy")` → **405**. Un cambio de verbo; la
   ruta ya está bien.

2. **El auto-alta de vehículo devuelve 400.**
   Cuando la matrícula no existe, `StayVehicleClientAdapter` hace
   `POST /v1/vehicles` con `{plate, type}`. Pero `VehicleRequest` exige además
   `active` (`@NotNull`) → 400. El check-in de una matrícula nueva no puede
   funcionar hasta que se mande `active: true` o se relaje la validación.

3. **`PATCH /v1/spots/{id}/status` no cambia el estado.**
   Recibe `SpotRequest` (campo `type`) y delega en `UpdateSpotUseCase`: cambia el
   *tipo* de la plaza. No hay forma por REST de poner una plaza en `UNAVAILABLE`.

4. **`PATCH /v1/vehicles/{id}/status` ignora el body.**
   Siempre desactiva y devuelve 204. No se puede reactivar un vehículo por REST.

5. **RN-01 no se puede mapear a 409 todavía.**
   Cuando spot responde 409 (parking completo), `occupySpot` deja escapar un
   `HttpClientErrorException` / `IllegalStateException` en vez de lanzar
   `NoAvailableSpotException`. Hasta que lo lance, el `CheckInUseCase` no puede
   traducirlo al 409 del contrato.

6. **`POST /v1/tickets/exit` no existe.**
   `StayTicketClientAdapter.issueExitTicket` la llama; ticket-service usa
   `/v1/entry-tickets`. Es del check-out, no bloquea el check-in.

7. **Sin timeouts en las llamadas salientes de stay.**
   El `RestClient.Builder` compartido no fija connect/read timeout. Si spot se
   cuelga, el tótem agota hilos en vez de denegar el acceso.

8. **`SpotOccupyRequest` / `SpotOccupyResponse` son código muerto.**
   Ningún endpoint los usa. El contrato real de `/occupy` es `SpotRequest` in,
   `SpotResponse` out. No te guíes por esas clases.

---

## Lo que todavía no se puede probar

- **Check-out (HU-02)** — bloqueado por `POST /v1/tariffs/calculate`, que no
  existe en tariff-service.
- **Ticket de entrada real** — todo `ticket-service` es esqueleto.
- **Cancelar / consultar / listar estancias** — el dominio de `Stay` ya tiene
  `cancel()`, pero no hay caso de uso ni endpoint.

---

## Mantenimiento

Cuando cambies un endpoint, actualiza la request **y su descripción** en el mismo
PR. Una colección que miente sobre el estado del sistema es peor que no tenerla:
el valor de estos ficheros está en que las etiquetas `[TODO]`/`[STUB]` sean
ciertas.
