#!/usr/bin/env python3
"""Static (no-runtime, no-MLX) checks on the engine sidecar.

Runs anywhere python3 runs — CI included — while the full E2E suite
(Tests/test_engine_e2e.py) needs the local voxmlx venv and is the
developer-machine path.

Checks:
  1. The engine parses (syntax gate for the one file CI cannot build
     against Xcode).
  2. Source tripwire: every literal emit(...) dict whose "type" is
     "final" or "cancelled" carries a "token" key, so a stale result can
     never be mistaken for the current session's (mirrors case 3a of the
     E2E suite).
"""
import ast
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ENGINE = os.path.join(ROOT, "Whistral",
                      "Resources", "Engine", "whistral_engine.py")

with open(ENGINE, "r", encoding="utf-8") as f:
    src = f.read()

failures = []

# 1. Syntax gate.
try:
    tree = ast.parse(src)
    print("PASS  engine sidecar parses")
except SyntaxError as e:
    failures.append("engine does not parse: %s (line %d)" % (e.msg, e.lineno))
    tree = None

# 2. Token tripwire on literal final/cancelled emits.
if tree is not None:
    bad = []
    total = 0
    for node in ast.walk(tree):
        if not (isinstance(node, ast.Call)
                and isinstance(node.func, ast.Name)
                and node.func.id == "emit"):
            continue
        for arg in node.args:
            if not isinstance(arg, ast.Dict):
                continue
            str_keys = [k.value for k in arg.keys
                        if isinstance(k, ast.Constant) and isinstance(k.value, str)]
            consts = {k.value: v.value for k, v in zip(arg.keys, arg.values)
                      if isinstance(k, ast.Constant) and isinstance(k.value, str)
                      and isinstance(v, ast.Constant)}
            if consts.get("type") in ("final", "cancelled"):
                total += 1
                if "token" not in str_keys:
                    bad.append("line %d" % node.lineno)
    if total == 0:
        failures.append("no literal final/cancelled emits found — did the "
                        "engine's event vocabulary change?")
    elif bad:
        failures.append("final/cancelled emits without 'token': %s" % ", ".join(bad))
    else:
        print("PASS  all %d literal final/cancelled emits carry 'token'" % total)

if failures:
    for f in failures:
        print("FAIL  %s" % f)
    sys.exit(1)
print("ALL STATIC CHECKS PASSED")
