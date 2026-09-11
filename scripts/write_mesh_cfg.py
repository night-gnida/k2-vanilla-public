import json

# Append the probed mesh as a [bed_mesh default] config section — the same
# way stock ships its mesh. Reads /tmp/mesh.json (bed_mesh status dump).

mesh = json.load(open("/tmp/mesh.json"))
matrix = mesh["probed_matrix"]
cfg = "/mnt/UDISK/printer_data/config-vanilla/printer.cfg"

section = "\n[bed_mesh default]\nversion: 1\npoints:\n"
for row in matrix:
    section += "  " + ", ".join("%.6f" % v for v in row) + ",\n"
section += (
    "mesh_min: 5.0, 5.0\n"
    "mesh_max: 255.0, 255.0\n"
    "algo: bicubic\n"
    "tension: 0.2\n"
)

data = open(cfg).read()
if "[bed_mesh default]" in data:
    print("section already present, nothing to do")
    raise SystemExit(0)
open(cfg + ".bak", "w").write(data)
open(cfg, "a").write(section)
print("appended [bed_mesh default] (%d rows), backup at printer.cfg.bak"
      % len(matrix))
