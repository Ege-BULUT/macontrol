"""Probe: does Kudu@0ef4292 rules/schema/rules.schema.json (draft-07) accept rule paths that
resolve to whole user folders or climb out with '..'? Also re-checks the shipped darwin rules.
Mirrors the schema half of src/main/rules/validate.ts (Ajv) with python-jsonschema; the
validator's only other path check is the ${VAR} allowlist (validate.ts:81-88), which all of
these pass. Run: python3 rule_schema_probe.py"""
import json, pathlib, jsonschema
S = pathlib.Path.home() / "projects/macontrol/research/sources/adventdevinc-kudu/rules"
schema = json.loads((S / "schema/rules.schema.json").read_text())
v = jsonschema.Draft7Validator(schema)
for f in sorted((S / "darwin").glob("*.json")):
    errs = list(v.iter_errors(json.loads(f.read_text())))
    print(f"shipped darwin/{f.name}: {'valid' if not errs else f'{len(errs)} errors'}")
probes = ["${HOME}", "${HOME}/Documents", "${LIBRARY}", "${CACHES}/../..", "/", "${APP_SUPPORT}/../Keychains"]
for p in probes:
    apps = {"$schema": "../schema/rules.schema.json", "type": "apps",
            "apps": [{"id": "probe", "name": "Probe", "paths": [p]}]}
    sysr = {"$schema": "../schema/rules.schema.json", "type": "system",
            "cleanTargets": [{"path": p, "subcategory": "Probe"}]}
    print(f"{p!r:32} apps.json: {'ACCEPTED' if v.is_valid(apps) else 'rejected'}"
          f"   system.json: {'ACCEPTED' if v.is_valid(sysr) else 'rejected'}")
