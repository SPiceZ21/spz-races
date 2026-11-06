"""Run tests/run.lua with Lua 5.4 via lupa (pip install lupa) when no lua binary exists.
Usage (from spz-races/):
    python tests/progression/run_lupa.py            # domain tests + golden vectors
    python tests/progression/run_lupa.py pipeline   # real server files against FiveM/DB fakes
"""
import os
import sys
from lupa import lua54

here = os.path.dirname(os.path.abspath(__file__))
root = os.path.dirname(os.path.dirname(here)).replace("\\", "/")
lua = lua54.LuaRuntime()
lua.execute(f'TEST_BASE = "{root}"')
try:
    script = "pipeline_mock.lua" if "pipeline" in sys.argv[1:] else "run.lua"
    lua.execute(f'dofile("{root}/tests/progression/{script}")')
except Exception as exc:  # noqa: BLE001
    print(exc)
    sys.exit(1)
