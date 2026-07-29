# ADR 0001: Reparto de responsabilidades de autorización entre Kong y Spring Security

## Estado

Aceptado — 2026-07-29 (GW-04)

## Contexto

Fase II añade Keycloak (IdP) y Kong (API Gateway, modo DB-less, `kong/kong.yml`)
delante de los 5 microservicios. El documento maestro
(`TARTIS_ReconAI_Contexto_FaseI_FaseII.md`, §9.1) describe el modelo de
seguridad como dos capas — Kong valida el JWT y Spring Security hace "una
segunda verificación más fina" — y pide diferenciar explícitamente:

- 401: token ausente/inválido/caducado.
- 403: token válido, rol insuficiente → **la guía técnica lo describe como
  "problema en configuración de roles en Keycloak/Kong"**, dando a entender
  que Kong participa en la resolución del rol.

Al implementar el plugin `jwt` en las 7 rutas de `kong.yml` se comprobó que
esa lectura no es correcta para el stack elegido (Kong OSS, sin plugin de
pago):

- El plugin `jwt` de Kong OSS sí decodifica el payload — lee el claim `iss`
  (`key_claim_name`, por defecto `iss`) para localizar la credencial del
  consumer — y valida **firma** (RS256 contra la clave pública del realm) y
  **claims registrados** (`claims_to_verify: ["exp"]` explícito, ver
  `kong/kong.yml`). Lo que no hace es **usar** claims custom como
  `realm_access.roles` para autorizar — no tiene noción de "rol" en
  absoluto. Devuelve 401 o deja pasar la petición, nada más.
- El plugin `acl` autoriza por **consumer**, no por rol de usuario. El
  `jwt_secret` está configurado con un único consumer, `keycloak-parking`,
  cuya `key` es el `iss` exacto del token (`http://localhost:8180/realms/parking`).
  Es decir: **todos** los usuarios del realm `parking` — `ADMIN`, `OPERARIO`,
  `USER` — autentican contra el mismo consumer. `acl` no tendría nada que
  discriminar: no hay forma nativa en Kong OSS de derivar un consumer
  distinto por usuario/rol a partir de un claim del JWT en tiempo de
  petición.

En resumen: con el stack actual, Kong puede responder "¿es un JWT válido y
vigente?", pero no "¿tiene este usuario el rol necesario para este
endpoint?". La guía técnica asume una capacidad que el plugin `jwt` de Kong
OSS no tiene.

## Decisión

- **Kong** resuelve únicamente si el JWT es válido (firma RS256 correcta,
  `iss` del realm `parking`) y está vigente (`exp` no caducado). Si falla
  cualquiera de las dos, devuelve **401**. No se añade el plugin `acl` ni
  ningún mecanismo de resolución de rol en Kong.
- **Toda** la autorización por rol — qué rol puede hacer qué en cada
  endpoint — vive en Spring Security, mediante `@PreAuthorize` en cada uno
  de los 5 backends (ticket SEC-10, ya planificado y con tests). Cuando el
  token es válido pero el rol es insuficiente, el backend devuelve **403**.
- Kong está pensado como único punto de entrada externo bajo `/api/v1/`, pero
  es una capa de autenticación, no de autorización fina — eso no cambia
  aunque hoy no sea todavía el único punto de entrada real (ver nota más
  abajo en Consecuencias).

## Alternativas descartadas

### `serverless-functions` (Lua) decodificando el payload en Kong

Una `pre-function` podría decodificar el JWT (base64) y leer
`realm_access.roles` a mano para autorizar o rechazar en el borde.

Descartada porque reimplementa lógica de autorización en Lua, sin
framework de tests en el proyecto para ese código, fuera de la cobertura
≥90% que exige Fase II para el resto del sistema. Duplicaría además la
lógica que SEC-10 ya va a implementar y testear en Spring Security — dos
sitios donde mantener sincronizada la matriz rol×endpoint es peor que uno,
no mejor.

### Kong Enterprise (plugin `openid-connect` con mapeo de roles/claims)

El plugin de pago sí puede mapear claims a autorización de forma nativa.

Descartada por alcance: el stack decidido para el bootcamp es Kong OSS vía
Docker Compose, sin licencia Enterprise.

## Consecuencias

- La autorización por rol queda en un único lugar (Spring Security),
  testeable en Java junto al resto de la lógica de negocio de cada backend,
  en vez de repartida entre Lua sin tests y Java.
- Una petición con rol insuficiente atraviesa la red hasta el backend antes
  de ser rechazada (coste de una llamada de red extra frente a rechazar en
  el borde). Se acepta: el volumen del bootcamp/demo no lo justifica, y la
  alternativa (mantener roles también en Kong) añade una segunda fuente de
  verdad para la matriz rol×endpoint.
- `TARTIS_ReconAI_Contexto_FaseI_FaseII.md` §9.1 sigue describiendo el 403
  como "problema en configuración de roles en Keycloak/Kong"; este ADR
  matiza esa frase — el rol se configura en Keycloak (claims del token) y
  se **verifica** en Spring Security, no en Kong.
- **Kong hoy no es el único punto de entrada externo**, aunque esa sea la
  intención: el frontend llama directo a cada microservicio vía su propio
  `nginx.conf` (rutas `/v1/...`, sin pasar por Kong ni llevar JWT), y
  `docker-compose.demo.yml` publica los puertos 8080-8084 de los 5 backends
  en el host. Este ADR no cambia esa realidad — decide el reparto de
  autorización para el tráfico que sí pasa por Kong, no cierra el bypass.
  Cerrarlo (que el frontend hable con Kong por `/api/v1/...` y que solo
  Kong quede expuesto) queda fuera de alcance de este ADR y sin ticket
  formal todavía; hasta que se resuelva, cualquier petición directa a un
  puerto 8080-8084 se salta tanto la validación de Kong como el 401 —
  Spring Security (SEC-10) sigue siendo la única capa real de defensa en
  ese camino.
- El consumer único (`keycloak-parking`) que impide autorizar por rol en
  Kong (ver Contexto) también impide que Kong **identifique qué usuario**
  hizo la petición: las cabeceras `X-Consumer-*` que añade son idénticas
  para `ADMIN`, `OPERARIO` y `USER`, porque los tres autentican contra el
  mismo consumer. Esto limita GW-06 (correlation-id/logging) — cualquier
  identificación de usuario en logs o trazas tendrá que salir del propio
  JWT dentro de cada backend, no de las cabeceras que añade Kong.
- Pendiente (fuera de este ADR): colección Postman GW-08 con 4 escenarios
  por servicio (sin token / caducado / rol incorrecto / rol correcto) para
  verificar 401 y 403 de extremo a extremo — bloqueada hasta que SEC-10
  exista en los 5 backends.

## Referencias

- `kong/kong.yml` — plugin `jwt` en las 7 rutas, consumer único
  `keycloak-parking`.
- `README.md` (sección Kong) de este repo.
- `TARTIS_ReconAI_Contexto_FaseI_FaseII.md`, §9.1 (Seguridad — Kong +
  Keycloak + Spring Security).
- Tickets relacionados: GW-04 (este ADR), GW-08 (verificación Postman),
  SEC-10 (`@PreAuthorize` en los 5 backends).
