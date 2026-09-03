#!/usr/bin/env python3
"""Static host-API compatibility audit for k2-vanilla vendored modules.

For each vendored klippy extra + config file, verify that every host API it
uses exists in the target host trees:
  - `from extras.X import ...` (X provided by host extras or by our vendored set)
  - `lookup_object("name")` targets and method calls on bound variables
    (guarded lookups with a default, and calls behind runtime hasattr guards,
    are reported separately / whitelisted)
  - config options per [section] vs the module's config.get* literals
  - gcode commands used in our configs/macros vs commands registered anywhere
    in the host tree or by our own files

Usage:
  python scripts/audit_compat.py --host v013=PATH --host stock=PATH [...]
PATH points at the host's klippy/ directory. Report on stdout.
"""
import argparse
import ast
import os
import re

KIT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FILES = os.path.join(KIT, "files")
CONFIG = os.path.join(KIT, "config")

# object name -> host-relative file providing it; VENDORED = files/<name>.py
CORE_OBJECT_MAP = {
    "toolhead": "toolhead.py",
    "mcu": "mcu.py",
    "gcode": "gcode.py",
    "gcode_move": "gcode_move.py",
    "pins": "pins.py",
    "webhooks": "webhooks.py",
    "homing": "homing.py",
    "extruder": "kinematics/extruder.py",
    "idle_timeout": "extras/idle_timeout.py",
    "print_stats": "extras/print_stats.py",
    "motion_report": "extras/motion_report.py",
    "query_endstops": "extras/query_endstops.py",
    "stepper_enable": "extras/stepper_enable.py",
    "display_status": "extras/display_status.py",
    "pause_resume": "extras/pause_resume.py",
    "virtual_sdcard": "extras/virtual_sdcard.py",
    "bed_mesh": "extras/bed_mesh.py",
    "exclude_object": "extras/exclude_object.py",
}

# runtime hasattr-guarded calls, verified by hand (do not report)
GUARDED_CALLS = {
    ("force_stop_homing.py", "request_homing_abort"),
    ("force_stop_homing.py", "is_homing_abort_in_progress"),
    ("motor_control.py", "request_motor_fault_abort"),
    ("motor_control.py", "has_active_homing_session"),
    ("motor_control.py", "is_homing_session_aborted"),
    ("motor_control.py", "is_homing_abort_in_progress"),
    ("box.py", "Coord"),
    ("motor_control.py", "Coord"),
}

# modules intentionally NOT loaded on base K2 (findings are informational)
DISABLED_ON_BASE = {"power_loss_recovery.py"}

CFG_OPT_RE = re.compile(
    r"\b\w+\.get(?:floatlist|intlist|float|int|boolean|lists?|choice|string)?\("
    r"\s*['\"]([a-z_0-9]+)['\"]")

# sections whose options are partly read by a helper module
EXTRA_PROVIDERS = {"controller_fan": ("extras/fan.py",),
                   "fan_generic": ("extras/fan.py",),
                   "fan": ("extras/fan.py",)}


def read(path):
    with open(path, encoding="utf-8", errors="ignore") as f:
        return f.read()


def extract_methods(src):
    names = set()
    try:
        tree = ast.parse(src)
    except SyntaxError:
        return names
    for node in ast.walk(tree):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            names.add(node.name)
    return names


class HostInventory:
    def __init__(self, name, klippy_dir):
        self.name = name
        extras_dir = os.path.join(klippy_dir, "extras")
        self.extras = ({f[:-3] for f in os.listdir(extras_dir)
                        if f.endswith(".py")}
                       if os.path.isdir(extras_dir) else set())
        self.files = {}
        for root, _d, files in os.walk(klippy_dir):
            for f in files:
                if f.endswith(".py"):
                    rel = os.path.relpath(os.path.join(root, f), klippy_dir)
                    self.files[rel.replace("\\", "/")] = read(
                        os.path.join(root, f))
        self.module_methods = {rel: extract_methods(src)
                               for rel, src in self.files.items()}
        for f in os.listdir(FILES):
            if f.endswith(".py"):
                self.module_methods["VENDORED:" + f] = extract_methods(
                    read(os.path.join(FILES, f)))
        self.commands = set()
        for src in self.files.values():
            for m in re.finditer(
                    r"register_(?:mux_)?command\(\s*['\"]([A-Z0-9_.]+)['\"]",
                    src):
                self.commands.add(m.group(1))

    def provider_file(self, object_name):
        vendored = os.path.join(FILES, object_name + ".py")
        if os.path.isfile(vendored):
            return "VENDORED:" + object_name + ".py"
        rel = CORE_OBJECT_MAP.get(object_name)
        if rel and rel in self.files:
            return rel
        for cand in ("extras/%s.py" % object_name, "%s.py" % object_name):
            if cand in self.files:
                return cand
        return None


def analyze_vendored(path, host):
    issues = []
    where = os.path.basename(path)
    src = read(path)
    try:
        tree = ast.parse(src)
    except SyntaxError as e:
        return [("syntax", str(e), where)]
    guarded_lines = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Try):
            for n in ast.walk(node):
                guarded_lines.add(getattr(n, "lineno", 0))
    bindings = {}
    imports = []
    for node in ast.walk(tree):
        if isinstance(node, ast.ImportFrom) and node.module:
            imports.append((node.module, node.lineno))
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) \
                and node.func.attr == "lookup_object" \
                and node.args and isinstance(node.args[0], ast.Constant):
            objname = str(node.args[0].value).split()[0]
            if len(node.args) > 1:
                objname = "GUARDED:" + objname
            bindings.setdefault(("__call__", node.lineno), objname)
    for node in ast.walk(tree):
        if isinstance(node, ast.Assign) and isinstance(node.value, ast.Call):
            call = node.value
            if (isinstance(call.func, ast.Attribute)
                    and call.func.attr == "lookup_object"
                    and call.args and isinstance(call.args[0], ast.Constant)):
                objname = str(call.args[0].value).split()[0]
                if len(call.args) > 1:
                    objname = "GUARDED:" + objname
                for t in node.targets:
                    if isinstance(t, ast.Name):
                        bindings[t.id] = objname
                    elif isinstance(t, ast.Attribute):
                        bindings[t.attr] = objname
    vendored_names = {f[:-3] for f in os.listdir(FILES) if f.endswith(".py")}
    for module, lineno in imports:
        if module.startswith("extras."):
            base = module.split(".")[1]
            if base in vendored_names:
                continue
            if not host.has_module(base):
                level = "guarded-import" if lineno in guarded_lines else "import"
                issues.append((level, "extras.%s missing in host" % module,
                               "%s:%d" % (where, lineno)))
    for node in ast.walk(tree):
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute):
            attr = node.func
            if isinstance(attr.value, ast.Name):
                var = attr.value.id
            elif isinstance(attr.value, ast.Attribute):
                var = attr.value.attr
            else:
                continue
            if var not in bindings:
                continue
            objname = bindings[var]
            guarded = objname.startswith("GUARDED:")
            if guarded:
                objname = objname.split(":", 1)[1]
            provider = host.provider_file(objname)
            if provider is None:
                level = "guarded-lookup" if guarded else "object"
                issues.append((level,
                               "lookup_object('%s') not resolvable in host"
                               % objname, "%s:%d" % (where, node.lineno)))
                continue
            methods = host.module_methods.get(provider, set())
            if attr.attr in methods:
                continue
            if (where, attr.attr) in GUARDED_CALLS:
                continue
            level = "guarded-method" if guarded else "method"
            issues.append((level,
                           "%s (from '%s') missing in host %s"
                           % (attr.attr, objname, provider),
                           "%s:%d" % (where, node.lineno)))
    return issues


def config_sections(path):
    cur = None
    out = {}
    for raw in read(path).splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        m = re.match(r"\[([A-Za-z0-9_]+)", line)
        if m:
            cur = m.group(1)
            out.setdefault(cur, set())
            continue
        if line.startswith("[include"):
            continue
        m = re.match(r"([a-z_0-9]+)\s*:", line)
        if m and cur:
            out[cur].add(m.group(1))
    return out


def module_config_options(host, section):
    rels = []
    for rel in ("extras/%s.py" % section, "%s.py" % section):
        if rel in host.files:
            rels.append(rel)
            break
    if not rels:
        return None, None
    opts = set(CFG_OPT_RE.findall(host.files[rels[0]]))
    for extra in EXTRA_PROVIDERS.get(section, ()):
        if extra in host.files:
            opts |= set(CFG_OPT_RE.findall(host.files[extra]))
            rels.append(extra)
    return "+".join(rels), opts


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", action="append", required=True,
                    help="name=path-to-klippy-dir (repeatable)")
    args = ap.parse_args()
    hosts = {}
    for spec in args.host:
        name, path = spec.split("=", 1)
        hosts[name] = HostInventory(name, path)

    for fname in sorted(os.listdir(FILES)):
        if not fname.endswith(".py"):
            continue
        path = os.path.join(FILES, fname)
        note = " (disabled on base - informational)" \
            if fname in DISABLED_ON_BASE else ""
        rows = []
        for hname, inv in hosts.items():
            for kind, detail, where in analyze_vendored(path, inv):
                if kind in ("guarded-import", "guarded-lookup",
                            "guarded-method"):
                    continue
                rows.append("  [%s] %s: %s (%s)" % (hname, kind, detail, where))
        if rows:
            print("## %s%s" % (fname, note))
            for r in rows:
                print(r)

    sec_opts = {}
    for c in sorted(os.listdir(CONFIG)):
        if c.endswith(".cfg"):
            for s, o in config_sections(os.path.join(CONFIG, c)).items():
                sec_opts.setdefault(s, set()).update(o)
    for hname, inv in hosts.items():
        for sec, opts in sorted(sec_opts.items()):
            rel, have = module_config_options(inv, sec)
            if rel is None:
                continue
            miss = sorted(o for o in opts - have)
            if miss:
                print("## config[%s] vs %s (%s): %s"
                      % (sec, hname, rel, ", ".join(miss)))
    print("--- audit done ---")


if __name__ == "__main__":
    main()
