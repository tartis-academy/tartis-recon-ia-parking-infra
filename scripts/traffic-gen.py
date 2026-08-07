#!/usr/bin/env python3
"""Generador de trafico y de datos congruentes contra el parking, via Kong.

Genera vehiculos que el dominio acepta -- matricula NNNNLLL con el juego de
letras real, modelo que existe para esa marca, y puertas/sidecar coherentes con
el tipo -- y los mete por `POST /api/v1/stays/check-in` con concurrencia
configurable. Sirve como datos de entrada de las pruebas de ITEST y como motor
de la demo.

No usa dependencias externas: solo stdlib, para que corra en cualquier maquina
del equipo sin preparar un virtualenv.

Uso:
  scripts/traffic-gen.py --vehicles 30 --concurrency 6
  scripts/traffic-gen.py --vehicles 50 --rate 5 --duration 60 --checkout 50
  scripts/traffic-gen.py --dry-run --vehicles 5 --print-payloads
  scripts/traffic-gen.py --scenario cb05 --scenario rn11
  scripts/traffic-gen.py --scenario parking-lleno        # ojo: llena el parking

Devuelve 0 solo si todo salio como se esperaba; distinto de 0 si hubo fallos.
"""
import argparse
import collections
import json
import random
import statistics
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor

# El juego real de la matricula espanola: 20 consonantes. Sin vocales (para no
# formar palabras), sin N con virgulilla y sin Q (se confunde con la O).
LETRAS = "BCDFGHJKLMNPRSTVWXYZ"

COLORES = ["Blanco", "Negro", "Gris", "Azul", "Rojo", "Verde", "Plata", "Marron", "Beige", "Amarillo"]

# (modelo, puertas). El dominio solo admite 2, 4 o 5 puertas en coche y 0 en
# moto, asi que aqui no hay ningun 3 puertas aunque exista en la calle.
CATALOGO = {
    "CAR": {
        "Seat": [("Ibiza", 5), ("Leon", 5), ("Arona", 5), ("Ateca", 5), ("Toledo", 4)],
        "Renault": [("Clio", 5), ("Megane", 5), ("Captur", 5), ("Kadjar", 5)],
        "Volkswagen": [("Golf", 5), ("Polo", 5), ("Tiguan", 5), ("Passat", 4)],
        "Peugeot": [("208", 5), ("308", 5), ("3008", 5), ("508", 4)],
        "Citroen": [("C3", 5), ("C4", 5), ("C5 Aircross", 5)],
        "Ford": [("Fiesta", 5), ("Focus", 5), ("Kuga", 5)],
        "Toyota": [("Yaris", 5), ("Corolla", 5), ("RAV4", 5)],
        "BMW": [("Serie 1", 5), ("Serie 3", 4), ("X1", 5), ("Z4", 2)],
        "Mercedes": [("Clase A", 5), ("Clase C", 4), ("CLA", 4), ("SLC", 2)],
        "Mazda": [("2", 5), ("3", 5), ("CX-5", 5), ("MX-5", 2)],
        "Audi": [("A1", 5), ("A3", 5), ("Q3", 5), ("TT", 2)],
    },
    # Vehiculos adaptados: en la practica son monovolumenes y furgonetas de
    # techo alto, siempre de 5 puertas.
    "CAR_PMR": {
        "Volkswagen": [("Caddy", 5)],
        "Citroen": [("Berlingo", 5)],
        "Peugeot": [("Rifter", 5)],
        "Renault": [("Kangoo", 5)],
        "Fiat": [("Doblo", 5)],
        "Ford": [("Tourneo Connect", 5)],
        "Mercedes": [("Citan", 5)],
    },
    "MOTORBIKE": {
        "Honda": [("CB500F", 0), ("CBR650R", 0), ("Africa Twin", 0), ("PCX125", 0)],
        "Yamaha": [("MT-07", 0), ("MT-09", 0), ("Tracer 900", 0), ("XMAX 300", 0)],
        "Kawasaki": [("Z650", 0), ("Ninja 400", 0), ("Versys 650", 0)],
        "BMW": [("R 1250 GS", 0), ("F 850 GS", 0), ("R nineT", 0)],
        "Ducati": [("Monster", 0), ("Multistrada V4", 0), ("Scrambler", 0)],
        "Suzuki": [("V-Strom 650", 0), ("GSX-R750", 0), ("Burgman 400", 0)],
        "Vespa": [("Primavera 125", 0), ("GTS 300", 0)],
        # Unica marca del catalogo que monta sidecar de fabrica.
        "Ural": [("Gear Up", 0), ("cT", 0)],
    },
}

# CAR pesa mas porque es lo que mas se siembra en el parking.
PESOS_TIPO = ["CAR"] * 6 + ["MOTORBIKE"] * 3 + ["CAR_PMR"] * 1

# Codigos que el dominio devuelve a proposito. Un check-in que los recibe no es
# un fallo del script: es una regla de negocio aplicandose.
NEGOCIO = {
    409: "parking lleno (RN-01) o matricula ya dentro (CB-05)",
    422: "vehiculo dado de baja (RN-11)",
}


class Generador:
    """Datos congruentes y matriculas unicas dentro de una ejecucion."""

    def __init__(self, semilla=None):
        self.rnd = random.Random(semilla)
        self.usadas = set()
        self._lock = threading.Lock()

    def matricula(self):
        with self._lock:
            for _ in range(10000):
                p = f"{self.rnd.randrange(10000):04d}" + "".join(self.rnd.choices(LETRAS, k=3))
                if p not in self.usadas:
                    self.usadas.add(p)
                    return p
        raise RuntimeError("no quedan matriculas libres, baja --vehicles")

    def vehiculo(self, tipo=None):
        tipo = tipo or self.rnd.choice(PESOS_TIPO)
        marca = self.rnd.choice(list(CATALOGO[tipo]))
        modelo, puertas = self.rnd.choice(CATALOGO[tipo][marca])
        return {
            "plate": self.matricula(),
            "type": tipo,
            "brand": marca,
            "model": modelo,
            "color": self.rnd.choice(COLORES),
            "numDoors": puertas,
            # Solo Ural, y no en todas: el dominio rechaza sidecar en coche.
            "hasSidecar": tipo == "MOTORBIKE" and marca == "Ural" and self.rnd.random() < 0.5,
        }


class Cliente:
    """HTTP contra Kong con token de Keycloak renovado solo."""

    def __init__(self, base_url, keycloak_url, realm, client_id, usuario, password, dry_run=False):
        self.base_url = base_url.rstrip("/")
        self.token_url = f"{keycloak_url.rstrip('/')}/realms/{realm}/protocol/openid-connect/token"
        self.client_id, self.usuario, self.password = client_id, usuario, password
        self.dry_run = dry_run
        self._token = None
        self._expira_en = 0
        self._lock = threading.Lock()

    def _token_valido(self):
        with self._lock:
            if self._token and time.time() < self._expira_en:
                return self._token
            datos = urllib.parse.urlencode({
                "client_id": self.client_id, "username": self.usuario,
                "password": self.password, "grant_type": "password",
            }).encode()
            with urllib.request.urlopen(self.token_url, datos, timeout=15) as r:
                cuerpo = json.load(r)
            self._token = cuerpo["access_token"]
            # Margen de 60s: una tanda larga pasa de los 300s del realm y sin
            # esto la segunda mitad fallaria con 401 pareciendo un bug de la API.
            vida = cuerpo.get("expires_in", 300)
            self._expira_en = time.time() + (vida - 60 if vida > 120 else vida / 2)
            return self._token

    def peticion(self, metodo, ruta, cuerpo=None):
        """Devuelve (codigo, cuerpo, milisegundos). No lanza en errores HTTP."""
        if self.dry_run:
            return 201 if metodo == "POST" else 200, {}, 0.0
        datos = json.dumps(cuerpo).encode() if cuerpo is not None else None
        req = urllib.request.Request(
            self.base_url + ruta, data=datos, method=metodo,
            headers={"Authorization": "Bearer " + self._token_valido(),
                     "Content-Type": "application/json"})
        t0 = time.perf_counter()
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                bruto = r.read()
                return r.status, (json.loads(bruto) if bruto else {}), (time.perf_counter() - t0) * 1000
        except urllib.error.HTTPError as e:
            bruto = e.read()
            try:
                cuerpo_err = json.loads(bruto) if bruto else {}
            except json.JSONDecodeError:
                cuerpo_err = {"raw": bruto.decode(errors="replace")[:200]}
            return e.code, cuerpo_err, (time.perf_counter() - t0) * 1000
        except (urllib.error.URLError, TimeoutError, OSError) as e:
            return 0, {"error": str(e)}, (time.perf_counter() - t0) * 1000


class Resumen:
    def __init__(self):
        self.lock = threading.Lock()
        self.altas = collections.Counter()
        self.entradas = collections.Counter()
        self.salidas = collections.Counter()
        self.tiempos = collections.defaultdict(list)
        self.errores = []
        self.escenarios = []

    def registra(self, fase, codigo, ms, detalle=None):
        with self.lock:
            getattr(self, fase)[codigo] += 1
            self.tiempos[fase].append(ms)
            # 0 es error de red; >=500 y 4xx inesperados tambien cuentan.
            if codigo == 0 or codigo >= 500 or (codigo >= 400 and codigo not in NEGOCIO):
                self.errores.append((fase, codigo, detalle))

    @property
    def hay_fallos(self):
        return bool(self.errores) or any(not ok for _, ok, _ in self.escenarios)


def percentiles(valores):
    if not valores:
        return "-"
    v = sorted(valores)
    p50 = statistics.median(v)
    p95 = v[min(len(v) - 1, int(len(v) * 0.95))]
    return f"p50 {p50:.0f} ms · p95 {p95:.0f} ms · max {v[-1]:.0f} ms"


def alta_y_entrada(cli, res, vehiculo, hacer_checkout):
    """Alta explicita con todos los atributos + check-in.

    El check-in tambien crea el vehiculo si no existe, pero lo rellena con
    "Desconocido" y 4 puertas fijas: no vale como dato congruente.
    """
    cod, cuerpo, ms = cli.peticion("POST", "/api/v1/vehicles", vehiculo)
    res.registra("altas", cod, ms, f"{vehiculo['plate']} {cuerpo.get('message') or cuerpo.get('error', '')}")
    if cod not in (200, 201):
        return

    entrada = {"plate": vehiculo["plate"], "vehicleType": vehiculo["type"],
               "brand": vehiculo["brand"], "model": vehiculo["model"], "color": vehiculo["color"]}
    cod, cuerpo, ms = cli.peticion("POST", "/api/v1/stays/check-in", entrada)
    res.registra("entradas", cod, ms, f"{vehiculo['plate']} {cuerpo.get('message') or cuerpo.get('error', '')}")
    if cod != 201 or not hacer_checkout:
        return

    cod, cuerpo, ms = cli.peticion("POST", "/api/v1/stays/check-out", {"plate": vehiculo["plate"]})
    res.registra("salidas", cod, ms, f"{vehiculo['plate']} {cuerpo.get('message') or cuerpo.get('error', '')}")


def escenario_cb05(cli, gen):
    """Misma matricula dos veces con estancia activa -> 409."""
    v = gen.vehiculo("CAR")
    cli.peticion("POST", "/api/v1/vehicles", v)
    entrada = {"plate": v["plate"], "vehicleType": v["type"]}
    cod1, _, _ = cli.peticion("POST", "/api/v1/stays/check-in", entrada)
    cod2, _, _ = cli.peticion("POST", "/api/v1/stays/check-in", entrada)
    cli.peticion("POST", "/api/v1/stays/check-out", {"plate": v["plate"]})
    ok = cod1 == 201 and cod2 == 409
    return ok, f"primera {cod1} (esperado 201), segunda {cod2} (esperado 409)"


def escenario_rn11(cli, gen):
    """Vehiculo dado de baja -> 422, no entra."""
    v = gen.vehiculo("CAR")
    cod, cuerpo, _ = cli.peticion("POST", "/api/v1/vehicles", v)
    if cod not in (200, 201):
        return False, f"no se pudo dar de alta el vehiculo ({cod})"
    vid = cuerpo.get("uniqueId")
    cli.peticion("PATCH", f"/api/v1/vehicles/{vid}/status", {"active": False})
    cod, _, _ = cli.peticion("POST", "/api/v1/stays/check-in",
                             {"plate": v["plate"], "vehicleType": v["type"]})
    return cod == 422, f"check-in devolvio {cod} (esperado 422)"


def escenario_parking_lleno(cli, gen, tipo="MOTORBIKE"):
    """Llena el parking hasta el 409 de RN-01 y lo vacia al terminar."""
    dentro = []
    cod = 201
    for _ in range(200):
        v = gen.vehiculo(tipo)
        if cli.peticion("POST", "/api/v1/vehicles", v)[0] not in (200, 201):
            break
        cod, _, _ = cli.peticion("POST", "/api/v1/stays/check-in",
                                 {"plate": v["plate"], "vehicleType": tipo})
        if cod != 201:
            break
        dentro.append(v["plate"])
    for p in dentro:
        cli.peticion("POST", "/api/v1/stays/check-out", {"plate": p})
    return cod == 409, f"lleno tras {len(dentro)} entradas de {tipo}, siguiente dio {cod} (esperado 409)"


ESCENARIOS = {
    "cb05": ("matricula duplicada con estancia activa (CB-05)", escenario_cb05),
    "rn11": ("vehiculo dado de baja (RN-11)", escenario_rn11),
    "parking-lleno": ("parking lleno (RN-01)", escenario_parking_lleno),
}


def estado(cli):
    cod, plazas, _ = cli.peticion("GET", "/api/v1/spots")
    if cod != 200:
        print(f"ERROR: /api/v1/spots devolvio {cod}")
        return 1
    lista = plazas["content"] if isinstance(plazas, dict) else plazas
    n = collections.Counter((p["type"], p["status"]) for p in lista)
    print("==> Plazas")
    for k in sorted(n):
        print(f"  {k[0]:<10} {k[1]:<10} {n[k]:>3}")
    _, pagina, _ = cli.peticion("GET", "/api/v1/stays?status=IN_PROGRESS&page=0&size=1")
    print(f"\n==> Estancias en curso: {pagina.get('totalElements', '?')}")
    return 0


def vaciar(cli):
    """Check-out de todo lo que este dentro. Deja el parking a cero."""
    _, pagina, _ = cli.peticion("GET", "/api/v1/stays?status=IN_PROGRESS&page=0&size=200")
    matriculas = [s["plate"] for s in pagina.get("content", [])]
    print(f"==> {len(matriculas)} estancias abiertas")
    fallos = 0
    for p in matriculas:
        cod, cuerpo, _ = cli.peticion("POST", "/api/v1/stays/check-out", {"plate": p})
        if cod != 200:
            fallos += 1
            print(f"  FALLO {p}: {cod} {cuerpo.get('message', '')}")
    print(f"==> {len(matriculas) - fallos} cerradas, {fallos} fallos")
    # Las plazas las libera spot-service al consumir el evento, no el check-out.
    if matriculas:
        print("    (las plazas tardan un instante en volver a AVAILABLE: es asincrono)")
    return 1 if fallos else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--base-url", default="http://localhost:8000", help="Kong (por defecto %(default)s)")
    ap.add_argument("--keycloak-url", default="http://localhost:8180")
    ap.add_argument("--realm", default="parking")
    ap.add_argument("--client-id", default="parking-frontend")
    ap.add_argument("--user", default="admin.test")
    ap.add_argument("--password", default="Admin.123!")
    ap.add_argument("--vehicles", type=int, default=20, help="cuantos vehiculos generar")
    ap.add_argument("--concurrency", type=int, default=4, help="peticiones en paralelo")
    ap.add_argument("--rate", type=float, default=0, help="entradas por segundo (0 = sin limite)")
    ap.add_argument("--duration", type=float, default=0, help="corta a los N segundos (0 = sin limite)")
    ap.add_argument("--checkout", type=float, default=0, help="%% de vehiculos que ademas salen")
    ap.add_argument("--dry-run", action="store_true", help="simulacion: genera datos y no llama a nadie")
    ap.add_argument("--print-payloads", action="store_true", help="imprime los vehiculos generados")
    ap.add_argument("--scenario", action="append", default=[], choices=list(ESCENARIOS),
                    help="escenario de borde (repetible)")
    ap.add_argument("--seed", type=int, default=None, help="semilla, para tandas reproducibles")
    ap.add_argument("--checkout-all", action="store_true",
                    help="cierra todas las estancias abiertas y sale (deja el parking vacio)")
    ap.add_argument("--status", action="store_true", help="imprime plazas y estancias abiertas, y sale")
    args = ap.parse_args()

    gen = Generador(args.seed)
    cli = Cliente(args.base_url, args.keycloak_url, args.realm, args.client_id,
                  args.user, args.password, args.dry_run)
    res = Resumen()

    if args.status:
        return estado(cli)
    if args.checkout_all:
        return vaciar(cli)

    modo = "SIMULACION (sin llamadas reales)" if args.dry_run else args.base_url
    print(f"==> {args.vehicles} vehiculos · concurrencia {args.concurrency} · destino {modo}")
    if args.rate:
        print(f"    ritmo objetivo {args.rate}/s", end="")
        print(f" · corte a los {args.duration:.0f}s" if args.duration else "")

    vehiculos = [gen.vehiculo() for _ in range(args.vehicles)]
    if args.print_payloads:
        for v in vehiculos:
            print("   ", json.dumps(v, ensure_ascii=False))

    corte = time.time() + args.duration if args.duration else None
    intervalo = 1.0 / args.rate if args.rate else 0
    t0 = time.time()
    lanzados = 0

    with ThreadPoolExecutor(max_workers=args.concurrency) as pool:
        futuros = []
        for i, v in enumerate(vehiculos):
            if corte and time.time() >= corte:
                print(f"    corte por --duration tras {lanzados} de {len(vehiculos)}")
                break
            futuros.append(pool.submit(alta_y_entrada, cli, res, v, i * 100 < args.checkout * len(vehiculos)))
            lanzados += 1
            if intervalo:
                time.sleep(max(0, (t0 + lanzados * intervalo) - time.time()))
        for f in futuros:
            f.result()

    duracion = time.time() - t0

    for nombre in args.scenario:
        etiqueta, fn = ESCENARIOS[nombre]
        if args.dry_run:
            res.escenarios.append((etiqueta, True, "no ejecutado (--dry-run)"))
            continue
        try:
            ok, detalle = fn(cli, gen)
        except Exception as e:
            ok, detalle = False, f"excepcion: {e}"
        res.escenarios.append((etiqueta, ok, detalle))

    print(f"\n==> Resumen ({duracion:.1f}s)")
    for fase, etiqueta in (("altas", "Altas de vehiculo"), ("entradas", "Entradas"), ("salidas", "Salidas")):
        contador = getattr(res, fase)
        if not contador:
            continue
        total = sum(contador.values())
        desglose = " ".join(f"{c}:{n}" for c, n in sorted(contador.items()))
        print(f"  {etiqueta:<18} {total:>4}   [{desglose}]   {percentiles(res.tiempos[fase])}")

    if res.escenarios:
        print("\n==> Escenarios de borde")
        for etiqueta, ok, detalle in res.escenarios:
            print(f"  [{'OK ' if ok else 'FALLO'}] {etiqueta}: {detalle}")

    negocio = {c: n for fase in ("entradas",) for c, n in getattr(res, fase).items() if c in NEGOCIO}
    if negocio:
        print("\n==> Rechazos de negocio (esperados, no son errores)")
        for c, n in sorted(negocio.items()):
            print(f"  {c} x{n}: {NEGOCIO[c]}")

    if res.errores:
        print(f"\n==> {len(res.errores)} errores")
        for fase, codigo, detalle in res.errores[:10]:
            print(f"  {fase} HTTP {codigo}: {detalle}")
        if len(res.errores) > 10:
            print(f"  ... y {len(res.errores) - 10} mas")

    if res.hay_fallos:
        print("\nRESULTADO: con fallos")
        return 1
    print("\nRESULTADO: todo correcto")
    return 0


if __name__ == "__main__":
    sys.exit(main())
