#!/usr/bin/env python3
"""Convierte una coleccion del formato de workspace de Postman (arboles de
.request.yaml) al JSON v2.1 que ejecuta Newman.

El YAML sigue siendo la fuente de verdad -- es lo que sincroniza el workspace y
lo que se revisa en los PR. El JSON es un artefacto derivado que se regenera,
no se edita a mano, para que RECON-822 pueda correr la misma coleccion que usa
el equipo en Postman sin mantener dos copias divergentes.

Uso:
  scripts/postman-export.py "postman/collections/Parking · Kong JWT (GW-08)" -o out.json
  scripts/postman-export.py --env "postman/environments/Parking - Kong (dev).environment.yaml" -o env.json
"""
import argparse
import json
import pathlib
import sys

import yaml

SCHEMA = "https://schema.getpostman.com/json/collection/v2.1.0/collection.json"
LISTEN = {"afterResponse": "test", "beforeRequest": "prerequest", "preRequest": "prerequest"}


def load(path):
    with open(path, encoding="utf-8") as fh:
        return yaml.safe_load(fh) or {}


def events(node):
    out = []
    for script in node.get("scripts") or []:
        listen = LISTEN.get(script.get("type"), "test")
        out.append({
            "listen": listen,
            "script": {"type": "text/javascript", "exec": script.get("code", "").split("\n")},
        })
    return out


def body(node):
    src = node.get("body")
    if not src:
        return None
    kind = src.get("type")
    content = src.get("content")
    if kind == "urlencoded":
        return {"mode": "urlencoded", "urlencoded": [dict(c) for c in content]}
    if kind in ("formdata", "multipart"):
        return {"mode": "formdata", "formdata": [dict(c) for c in content]}
    if isinstance(content, (dict, list)):
        content = json.dumps(content, indent=2)
    return {
        "mode": "raw",
        "raw": content,
        "options": {"raw": {"language": "json" if kind in ("json", None) else kind}},
    }


def request_item(path):
    node = load(path)
    req = {
        "method": node.get("method", "GET"),
        "header": [{"key": k, "value": v} for k, v in (node.get("headers") or {}).items()],
        "url": node.get("url", ""),
    }
    if node.get("description"):
        req["description"] = node["description"]
    payload = body(node)
    if payload:
        req["body"] = payload
    item = {"name": path.stem.replace(".request", ""), "request": req}
    ev = events(node)
    if ev:
        item["event"] = ev
    return node.get("order", 0), item


def folder_items(directory):
    """Devuelve los hijos de un directorio ordenados por su campo `order`."""
    entries = []
    for child in sorted(directory.iterdir()):
        if child.name == ".resources":
            continue
        if child.is_dir():
            definition = load(child / ".resources" / "definition.yaml") if (child / ".resources" / "definition.yaml").exists() else {}
            node = {"name": child.name, "item": folder_items(child)}
            if definition.get("description"):
                node["description"] = definition["description"]
            entries.append((definition.get("order", 0), node))
        elif child.name.endswith(".request.yaml"):
            entries.append(request_item(child))
    return [item for _, item in sorted(entries, key=lambda e: e[0])]


def build_collection(root):
    definition = load(root / ".resources" / "definition.yaml")
    return {
        "info": {
            "name": root.name,
            "description": definition.get("description", ""),
            "schema": SCHEMA,
        },
        "item": folder_items(root),
    }


def build_environment(path):
    src = load(path)
    return {
        "name": src.get("name", pathlib.Path(path).stem),
        "values": [
            {"key": v["key"], "value": v.get("value", ""), "type": "default", "enabled": True}
            for v in src.get("values", [])
        ],
        "_postman_variable_scope": "environment",
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("source", help="directorio de la coleccion, o fichero .environment.yaml con --env")
    ap.add_argument("-o", "--output", required=True)
    ap.add_argument("--env", action="store_true", help="convertir un environment en vez de una coleccion")
    args = ap.parse_args()

    src = pathlib.Path(args.source)
    if not src.exists():
        sys.exit(f"ERROR: no existe {src}")

    result = build_environment(src) if args.env else build_collection(src)
    with open(args.output, "w", encoding="utf-8") as fh:
        json.dump(result, fh, indent=2, ensure_ascii=False)
        fh.write("\n")
    print(f"escrito {args.output}")


if __name__ == "__main__":
    main()
