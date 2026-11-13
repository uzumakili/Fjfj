#!/usr/bin/env python3
"""Plays Neon Canvas outside Roblox to catch mistakes before anyone opens Studio.

The two game scripts run inside a small imitation of the Roblox engine (engine.lua). It checks
every class, property, method, event and enum against Roblox's published API dump and simulates
players, characters, the network and time, so scripted testers can play whole matches.

    pip install lupa
    python run_tests.py                 run every scenario
    python run_tests.py solo_pc         run the scenarios whose name contains "solo_pc"
    python run_tests.py -v ...          also print notes and statistics for passing scenarios

The API dump (8 MB) is downloaded next to this file the first time.
"""
import json
import os
import sys
import time
import urllib.request

try:
    import lupa.luajit21 as lua_mod
except ImportError:  # pragma: no cover
    import lupa as lua_mod

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "..", "src")
DUMP = os.path.join(HERE, "Full-API-Dump.json")
DUMP_URL = "https://raw.githubusercontent.com/MaximumADHD/Roblox-Client-Tracker/roblox/Full-API-Dump.json"


# Methods whose optional arguments the API dump does not mark as optional.
OPTIONAL_OVERRIDES = {("Instance", "WaitForChild"): 1}


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def load_schema():
    if not os.path.exists(DUMP):
        print("downloading the Roblox API dump ...")
        urllib.request.urlretrieve(DUMP_URL, DUMP)
    with open(DUMP, encoding="utf-8") as f:
        dump = json.load(f)
    classes = {}
    for c in dump["Classes"]:
        props, funcs, events, callbacks = {}, {}, {}, {}
        for m in c["Members"]:
            tags = [t for t in m.get("Tags", []) if isinstance(t, str)]
            sec = m.get("Security")
            kind = m["MemberType"]
            if kind == "Property":
                entry = {
                    "cat": m["ValueType"]["Category"],
                    "type": m["ValueType"]["Name"],
                    "ro": "ReadOnly" in tags,
                    "ns": "NotScriptable" in tags,
                    "dep": "Deprecated" in tags,
                    "rsec": sec["Read"],
                    "wsec": sec["Write"],
                }
                if isinstance(m.get("Default"), str):
                    entry["default"] = m["Default"]
                props[m["Name"]] = entry
            elif kind == "Function":
                params = m["Parameters"]
                required, most = 0, len(params)
                for p in params:
                    kind_name = p["Type"]["Name"]
                    if kind_name == "Tuple":      # "..." in Lua: any number of extra arguments
                        most = 999
                    elif "Default" not in p and not kind_name.endswith("?"):
                        required += 1
                required = OPTIONAL_OVERRIDES.get((c["Name"], m["Name"]), required)
                funcs[m["Name"]] = {
                    "n": most,
                    "req": required,
                    "sec": sec if isinstance(sec, str) else "None",
                    "dep": "Deprecated" in tags,
                }
            elif kind == "Event":
                events[m["Name"]] = {"dep": "Deprecated" in tags}
            elif kind == "Callback":
                callbacks[m["Name"]] = True
        classes[c["Name"]] = {
            "super": c["Superclass"],
            "tags": [t for t in c.get("Tags", []) if isinstance(t, str)],
            "props": props,
            "funcs": funcs,
            "events": events,
            "callbacks": callbacks,
        }
    # each item: [name, value, old names that still work...]
    enums = {e["Name"]: [[i["Name"], i["Value"]] + list(i.get("LegacyNames", [])) for i in e["Items"]]
             for e in dump["Enums"]}
    return classes, enums


class World:
    """One fresh Lua state with the mock engine booted."""

    def __init__(self, schema, seed=1):
        self.lua = lua_mod.LuaRuntime(unpack_returned_tuples=True)
        load = self.lua.eval(
            "function(src, name) local f, e = loadstring(src, name) if not f then error(e) end return f end")
        self.load = load
        types = load(read(os.path.join(HERE, "types.lua")), "=types.lua")()
        factory = load(read(os.path.join(HERE, "engine.lua")), "=engine.lua")()
        classes, enums = schema
        self.M = factory(types, self.lua.table_from(classes, recursive=True),
                         self.lua.table_from(enums, recursive=True))
        self.M.boot(seed)
        self.scenarios = load(read(os.path.join(HERE, "scenarios.lua")), "=scenarios.lua")()


def lua_list(tbl):
    return [tbl[i] for i in range(1, len(tbl) + 1)] if tbl is not None else []


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("-")]
    verbose = "-v" in sys.argv
    schema = load_schema()
    server_src = read(os.path.join(SRC, "NeonCanvas.server.lua"))
    client_src = read(os.path.join(SRC, "NeonCanvas.client.lua"))

    probe = World(schema)
    names = lua_list(probe.scenarios.names)
    if args:
        names = [n for n in names if any(a in n for a in args)]
    failed = 0
    for name in names:
        world = World(schema, seed=int(os.environ.get("SEED", "7")))
        started = time.time()
        try:
            result = world.scenarios.run(world.M, name, server_src, client_src)
            failures = lua_list(result.failures)
            notes = lua_list(result.notes)
        except Exception as exc:  # the scenario itself crashed
            failures, notes = ["scenario crashed: %s" % exc], []
        errors = lua_list(world.M.errors)
        warnings = lua_list(world.M.warnings)
        took = time.time() - started
        bad = bool(failures or errors)
        failed += bad
        print("%s  %-28s %5.1fs  %d errors, %d warnings" % ("FAIL" if bad else "ok  ", name, took, len(errors), len(warnings)))
        for f in failures[:12]:
            print("      failed: " + str(f))
        seen = set()
        shown = 0
        for e in errors:
            key = str(e)[:240]
            if key not in seen and shown < 6:
                seen.add(key)
                shown += 1
                print("      error: " + "\n             ".join(str(e).split("\n")[:9]))
        if len(errors) > shown:
            print("      ... %d errors in total (%d different)" % (len(errors), len(seen)))
        seen = set()
        for w in warnings:
            key = str(w)[:200]
            if key not in seen and len(seen) < 6:
                seen.add(key)
                print("      warning: " + key)
        if verbose or bad:
            for n in notes:
                print("      " + str(n))
    print("\n%d of %d scenarios failed" % (failed, len(names)) if failed else "\nall %d scenarios passed" % len(names))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
