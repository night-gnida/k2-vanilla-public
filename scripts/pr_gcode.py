import socket, json, sys, time, urllib.request

# helpers on-printer:
#   python3 g.py gcode "G28" [timeout_s]   -> UDS gcode script, streams responses
#   python3 g.py get "toolhead,gcode_move" -> moonraker objects query

if len(sys.argv) < 3:
    print("usage: g.py gcode SCRIPT [timeout] | g.py get OBJECTS")
    sys.exit(2)

if sys.argv[1] == "get":
    q = json.load(urllib.request.urlopen(
        "http://127.0.0.1:7125/printer/objects/query?" + sys.argv[2], timeout=10))
    print(json.dumps(q.get("result", {}).get("status", q), indent=1))
    sys.exit(0)

script = sys.argv[2]
timeout = float(sys.argv[3]) if len(sys.argv) > 3 else 120.0
s = socket.socket(socket.AF_UNIX)
s.connect("/tmp/klippy_uds")


def send(o):
    s.sendall((json.dumps(o) + "\x03").encode())


buf = b""


def recv_all(t):
    global buf
    s.settimeout(max(0.5, t))
    while b"\x03" not in buf:
        try:
            d = s.recv(4096)
        except socket.timeout:
            return []
        if not d:
            return []
        buf += d
    msgs = []
    parts = buf.split(b"\x03")
    buf = parts.pop()
    for p in parts:
        p = p.decode(errors="replace").strip()
        if p:
            try:
                msgs.append(json.loads(p))
            except Exception:
                pass
    return msgs


send({"id": 1, "method": "gcode/script", "params": {"script": script}})
ok = False
deadline = time.time() + timeout
while time.time() < deadline and not ok:
    for m in (recv_all(min(5, deadline - time.time())) or []):
        if m.get("id") == 1:
            if "error" in m:
                print("KLIPPY-ERROR:", json.dumps(m["error"])[:500])
                sys.exit(1)
            ok = True
        elif m.get("method") == "gcode_response":
            print(m["params"]["response"])
print("DONE" if ok else "TIMEOUT")
