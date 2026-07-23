# tartis-recon-ia-parking-infra

Entorno local COMPARTIDO para los microservicios de tartis-recon-ai-parking:
Postgres de dev con un schema por servicio (`vehicle`, `spot`, `tariff`,
`ticket`, `stay`), pgAdmin y SonarQube.

Este repo NO contiene el Postgres dedicado de cada servicio (perfil `prod` /
servicio aislado, database-per-service): ese vive en el `docker-compose.yml`
raíz de cada repo de microservicio, con su propio `./setup.sh`.

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
