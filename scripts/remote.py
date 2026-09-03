#!/usr/bin/env python3
"""PC-side remote runner for k2-vanilla testing.

Usage:
  python scripts/remote.py exec  "command"            # run on printer, print output
  python scripts/remote.py push   LOCAL REMOTE        # recursive upload
  python scripts/remote.py gcode  "G28 X"             # send gcode via /tmp/klippy_uds

Env: K2_HOST (default 192.168.1.10), K2_USER (root), K2_PASS (creality_2024)
"""
import os
import socket
import sys
import time

import paramiko

HOST = os.environ.get("K2_HOST", "192.168.1.10")
USER = os.environ.get("K2_USER", "root")
PASS = os.environ.get("K2_PASS", "creality_2024")


def connect():
    cli = paramiko.SSHClient()
    cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    cli.connect(HOST, username=USER, password=PASS, timeout=10,
                look_for_keys=False, allow_agent=False)
    return cli


def run(cli, cmd, timeout=590):
    stdin, stdout, stderr = cli.exec_command(cmd, timeout=timeout)
    out = stdout.read().decode("utf-8", "replace")
    err = stderr.read().decode("utf-8", "replace")
    code = stdout.channel.recv_exit_status()
    return code, out, err


def push(cli, local, remote):
    """Upload via tar streamed over exec (stock firmware has no SFTP)."""
    import io
    import tarfile
    remote_dir = os.path.dirname(remote)
    base = os.path.basename(os.path.abspath(local))
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tf:
        tf.add(local, arcname=base)
    data = buf.getvalue()
    stdin, stdout, stderr = cli.exec_command(
        "mkdir -p '%s' && tar xzf - -C '%s' && echo TARBALL-OK" % (remote_dir, remote_dir),
        timeout=300)
    stdin.write(data)
    stdin.channel.shutdown_write()
    out = stdout.read().decode()
    code = stdout.channel.recv_exit_status()
    print("uploaded %d bytes -> %s: %s" % (len(data), remote, out.strip()))
    if code != 0:
        raise RuntimeError(stderr.read().decode())


def gcode(cli, script):
    py = (
        "import socket,json,sys,time\n"
        "s=socket.socket(socket.AF_UNIX); s.connect('/tmp/klippy_uds'); s.settimeout(60)\n"
        "def send(o):\n"
        "    s.sendall((json.dumps(o)+'\\x03').encode())\n"
        "def recv():\n"
        "    buf=b''\n"
        "    while not buf.endswith(b'\\x03'):\n"
        "        d=s.recv(4096)\n"
        "        if not d: break\n"
        "        buf+=d\n"
        "    return [json.loads(x) for x in buf.decode(errors='replace').split('\\x03') if x.strip()]\n"
        "send({'id':1,'method':'info'})\n"
        "print([m for m in recv() if m.get('id')==1])\n"
        "send({'id':2,'method':'gcode/script','params':{'script':%s}})\n"
        "done=False\n"
        "while not done:\n"
        "    for m in recv():\n"
        "        if m.get('id')==2: done=True\n"
        "        elif m.get('method')=='gcode_response': print(m['params']['response'])\n"
        "    if not done: send({'id':9,'method':'info'})\n"
        ") " % json.dumps(script)
    )
    # simpler inline: write python to temp then run
    code, out, err = run(cli, "cat > /tmp/gc.py <<'PYEOF'\n" + PY_BODY % json.dumps(script) + "\nPYEOF\npython3 /tmp/gc.py", timeout=120)
    print(out)
    if code != 0:
        print("ERR:", err)


PY_BODY = '''import socket,json,sys,time
s=socket.socket(socket.AF_UNIX); s.connect('/tmp/klippy_uds'); s.settimeout(30)
def send(o): s.sendall((json.dumps(o)+'\\x03').encode())
buf=b''
def recv_all(t=30):
    global buf
    s.settimeout(t)
    while b'\\x03' not in buf:
        d=s.recv(4096)
        if not d: break
        buf+=d
    msgs=[]
    parts=buf.split(b'\\x03')
    buf=parts.pop()
    for p in parts:
        p=p.decode(errors='replace').strip()
        if p:
            try: msgs.append(json.loads(p))
            except Exception: pass
    return msgs
script=json.loads(sys.argv[1]) if len(sys.argv)>1 else 'M114'
send({'id':1,'method':'gcode/script','params':{'script':script}})
ok=False
deadline=time.time()+float(sys.argv[2] if len(sys.argv)>2 else 60)
while time.time()<deadline and not ok:
    for m in recv_all():
        if m.get('id')==1: ok=True
        elif m.get('method')=='gcode_response': print(m['params']['response'])
print('DONE' if ok else 'TIMEOUT')
'''


def main():
    if len(sys.argv) < 2:
        print(__doc__); sys.exit(2)
    cli = connect()
    try:
        mode = sys.argv[1]
        if mode == "exec":
            code, out, err = run(cli, sys.argv[2])
            if out: print(out, end="")
            if err: print("STDERR:", err, end="")
            sys.exit(code)
        elif mode == "push":
            push(cli, sys.argv[2], sys.argv[3])
        elif mode == "gcode":
            code, out, err = run(cli, "cat > /tmp/gc.py <<'PYEOF'\n" + PY_BODY + "\nPYEOF\npython3 /tmp/gc.py %s %s"
                                 % (json.dumps(sys.argv[2]), json.dumps(sys.argv[3] if len(sys.argv) > 3 else "60")),
                                 timeout=200)
            print(out, end="")
            if code: print("ERR:", err, end="")
    finally:
        cli.close()


if __name__ == "__main__":
    main()
