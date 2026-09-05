#!/usr/bin/env python
"""Post-extract patches for klipper v0.13.0 on stock K2 firmware.
Idempotent across any previous patch state."""
import re
import sys

srcdir = sys.argv[1]
p = srcdir + "/klippy/extras/lis2dw.py"
s = open(p).read()
changed = False

if "K2PATCH-LIS-DISABLED" not in s:
    # 1) remove config_lis2dw / query_lis2dw add_config_cmd calls from
    #    __init__ (stock fw cannot parse them -> protocol error at connect)
    s2 = re.sub(r"\n\s*mcu\.add_config_cmd\(\"config_lis2dw.*?\)\n",
                "\n", s, flags=re.S)
    s2 = re.sub(r"\n\s*mcu\.add_config_cmd\(\"query_lis2dw.*?\)\n",
                "\n", s2, flags=re.S)
    if s2 != s:
        changed = True
        s = s2

    # 2) remove any previously-generated msgparser probe block
    s2 = re.sub(r"\n\s*msgs = dict\(mcu\.msgparser\.get_messages\(\)\)"
                r".*?on_restart=True\)\n",
                "\n", s, flags=re.S)
    if s2 != s:
        changed = True
        s = s2

    # 3) _build_config: early return (query lookup cannot succeed anyway)
    if "K2PATCH-LIS-DISABLED" not in s:
        s = s.replace(
            "    def _build_config(self):",
            "    def _build_config(self):\n"
            "        return  # K2PATCH-LIS-DISABLED: lis2dw incompatible "
            "with stock K2 fw (accelerometer disabled)", 1)
        changed = True

if changed:
    open(p, "w").write(s)
    print("lis2dw patched: accelerometer disabled (stock fw incompatible)")
else:
    print("lis2dw already patched")
