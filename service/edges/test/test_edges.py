#!/usr/bin/env python3
"""Replays made-up touchpad events through muna-edges.py --test and checks what it says."""
import json, os, struct, subprocess, sys, tempfile
HERE = os.path.dirname(os.path.abspath(__file__))
HELPER = os.path.join(HERE, '..', 'muna-edges.py')
EV = struct.Struct('llHHi')
W, H = 3000, 2000

def ev(t, c, v): return EV.pack(0, 0, t, c, v)
def syn(): return ev(0, 0, 0)

def touch_path(points, slot=0, tid=1, extra=None):
    out = ev(3, 0x2f, slot) + ev(3, 0x39, tid)
    for i, (x, y) in enumerate(points):
        out += ev(3, 0x2f, slot) + ev(3, 0x35, int(x * W)) + ev(3, 0x36, int(y * H))
        if extra and i == 0:
            out += extra
        out += syn()
    out += ev(3, 0x2f, slot) + ev(3, 0x39, -1) + syn()
    return out

def line(x0, y0, x1, y1, n=40): return [(x0 + (x1 - x0) * i / n, y0 + (y1 - y0) * i / n) for i in range(n + 1)]

def run(data):
    with tempfile.NamedTemporaryFile(delete=False) as f:
        f.write(data)
    out = subprocess.run([sys.executable, HELPER, '--test', f.name, '--range', str(W), str(H)], capture_output=True, text=True).stdout
    os.unlink(f.name)
    return [json.loads(l) for l in out.splitlines()]

def ok(c, what):
    if not c:
        print('FAIL', what); sys.exit(1)

m = run(touch_path(line(0.03, 0.2, 0.03, 0.8)))
steps = [x['dir'] for x in m if x['type'] == 'step']
ok(m[0] == {'type': 'begin', 'edge': 'left'} and m[-1]['type'] == 'end' and steps and all(d == -1 for d in steps) and 7 <= len(steps) <= 9, f'left down: {m}')
m = run(touch_path(line(0.97, 0.9, 0.97, 0.3)))
ok(m[0]['edge'] == 'right' and all(x['dir'] == 1 for x in m if x['type'] == 'step'), f'right up: {m}')
m = run(touch_path(line(0.2, 0.04, 0.8, 0.04)))
ok(m[0]['edge'] == 'top' and all(x['dir'] == 1 for x in m if x['type'] == 'step'), f'top right: {m}')
m = run(touch_path(line(0.8, 0.96, 0.3, 0.96)))
ok(m[0]['edge'] == 'bottom' and all(x['dir'] == -1 for x in m if x['type'] == 'step'), f'bottom left: {m}')
ok(run(touch_path(line(0.5, 0.2, 0.5, 0.9))) == [], 'a move in the middle is the pointer')
ok(run(touch_path(line(0.03, 0.5, 0.6, 0.55))) == [], 'leaving the edge is the pointer')
two = ev(3, 0x2f, 1) + ev(3, 0x39, 7) + ev(3, 0x35, 1500) + ev(3, 0x36, 1000)
ok(run(touch_path(line(0.03, 0.2, 0.03, 0.8), extra=two)) == [], 'two fingers are not ours')
ok(run(touch_path(line(0.03, 0.5, 0.031, 0.51))) == [], 'a tap at the edge does nothing')
print('edges ok')
