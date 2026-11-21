#!/usr/bin/env bash
# K10: the whole branch policy of the default branch, not only the parts T1's ext: list names.
#   canon <effective rules.json> <rulesets.json>   print the canonical snapshot (what ruleset-snapshot.json holds)
#   check <snapshot> <effective rules.json> <rulesets.json>   RULESET MATCH, or RULESET drift: <field> ... and exit 1
# effective rules = GET repos/{o}/{r}/rules/branches/{default}; rulesets = the GET repos/{o}/{r}/rulesets/{id} answers
# of the branch rulesets, as a JSON array. Every field is compared except metadata that changes without any change of
# policy or depends on who asks: node_id, created_at, updated_at, _links (bookkeeping) and current_user_can_bypass
# (the asking token's own bypass, not the policy). A field GitHub adds later is compared too: unknown means drift.
# Bypass actors are visible to admins only: without them the verdict says UNCHECKED; RULESET_REQUIRE_BYPASS=1 refuses.
set -uo pipefail
PY="${PY:-python3}"
case "${1:-}" in
  canon) [ $# -eq 3 ] || { echo "usage: canon <rules.json> <rulesets.json>"; exit 2; } ;;
  check) [ $# -eq 4 ] || { echo "usage: check <snapshot> <rules.json> <rulesets.json>"; exit 2; } ;;
  *) echo "usage: $0 canon|check ..."; exit 2 ;;
esac
"$PY" - "$@" <<'PY'
import json, os, sys
UNCHECKED = []
VOLATILE = {"node_id", "created_at", "updated_at", "_links", "current_user_can_bypass"}
def load(p, what):
    try: return json.load(open(p))
    except Exception as e: print(f"RULESET {what} unreadable: {p}: {e}"); sys.exit(1)
def canon(rules, rulesets):
    if not isinstance(rules, list) or not isinstance(rulesets, list):
        print("RULESET input is not a JSON array"); sys.exit(1)
    eff = sorted(rules, key=lambda r: (r.get("type", ""), json.dumps(r, sort_keys=True)))
    rs = []
    for r in rulesets:
        if "bypass_actors" not in r:
            # GitHub shows bypass actors only to admins; the Actions token is not one. Never compared as if empty:
            # either refused (RULESET_REQUIRE_BYPASS=1, the owner's admin run) or named as unchecked in the verdict.
            if os.environ.get("RULESET_REQUIRE_BYPASS") == "1":
                print(f"RULESET bypass_actors not visible for ruleset {r.get('name', '?')} (token lacks admin read)"); sys.exit(1)
            UNCHECKED.append(r.get("name", "?"))
        r = {k: v for k, v in r.items() if k not in VOLATILE}
        r["rules"] = sorted(r.get("rules", []), key=lambda x: (x.get("type", ""), json.dumps(x, sort_keys=True)))
        if "bypass_actors" in r: r["bypass_actors"] = sorted(r["bypass_actors"], key=lambda x: json.dumps(x, sort_keys=True))
        rs.append(r)
    rs.sort(key=lambda r: (r.get("name", ""), r.get("id", 0)))
    return {"effective_rules": eff, "rulesets": rs}
def walk(a, b, path, out):
    if isinstance(a, dict) and isinstance(b, dict):
        for k in sorted(set(a) | set(b)):
            p = f"{path}.{k}" if path else k
            if k not in a: out.append(f"+ {p} = {json.dumps(b[k], sort_keys=True)}")
            elif k not in b: out.append(f"- {p}")
            else: walk(a[k], b[k], p, out)
    elif isinstance(a, list) and isinstance(b, list):
        key = lambda x: x.get("type") or x.get("name") or x.get("context") if isinstance(x, dict) else None
        ka, kb = [key(x) for x in a], [key(x) for x in b]
        if None not in ka and None not in kb and len(set(ka)) == len(ka) and len(set(kb)) == len(kb):
            da, db = dict(zip(ka, a)), dict(zip(kb, b))
            for k in sorted(set(da) | set(db)):
                p = f"{path}[{k}]"
                if k not in da: out.append(f"+ {p}")
                elif k not in db: out.append(f"- {p}")
                else: walk(da[k], db[k], p, out)
        elif json.dumps(a, sort_keys=True) != json.dumps(b, sort_keys=True):
            out.append(f"~ {path}: {json.dumps(a, sort_keys=True)} -> {json.dumps(b, sort_keys=True)}")
    elif a != b:
        out.append(f"~ {path}: {json.dumps(a)} -> {json.dumps(b)}")
cmd = sys.argv[1]
if cmd == "canon":
    print(json.dumps(canon(load(sys.argv[2], "rules"), load(sys.argv[3], "rulesets")), indent=2, sort_keys=True))
    sys.exit(0)
snap = load(sys.argv[2], "snapshot")
live = canon(load(sys.argv[3], "rules"), load(sys.argv[4], "rulesets"))
if not snap.get("effective_rules") or not snap.get("rulesets"):
    print("RULESET snapshot has no rules: an empty policy is not a match"); sys.exit(1)
if UNCHECKED:   # compare what is visible; the snapshot's bypass actors stay unverified, and say so
    for r in snap.get("rulesets", []):
        if r.get("name") in UNCHECKED: r.pop("bypass_actors", None)
d = []; walk(snap, live, "", d)
if d:
    for x in d: print(f"RULESET drift: {x}  (snapshot -> live)")
    sys.exit(1)
u = f"; bypass actors UNCHECKED (not visible to this token) for: {', '.join(UNCHECKED)}" if UNCHECKED else "; bypass actors compared"
print(f"RULESET MATCH: {len(live['effective_rules'])} effective rules, {len(live['rulesets'])} rulesets{u}")
PY
