#!/usr/bin/env python3
"""muna-edges: one-finger swipes along the edges of the touchpad.

GNOME tells nobody where a single finger is on the touchpad (one finger only moves the pointer), so this reads the
touchpad itself (/dev/input/eventN; the user needs read access to it: scripts/touchpad-access.sh gives the user of the
seat access to touchpads only). A swipe that starts at an edge and goes along it gives steps:

    {"type": "ready", "device": "ELAN076C:00 04F3:3245 Touchpad"}
    {"type": "begin", "edge": "left"}          left / right: along the edge up or down; top / bottom: left or right
    {"type": "step", "edge": "left", "dir": 1}  1: up (left, right) or to the right (top, bottom); -1: the other way
    {"type": "end", "edge": "left"}
    {"type": "error", "code": "access" | "none" | "read", "message": "..."}

Usage: muna-edges.py [--device /dev/input/eventN] [--test FILE --range W H]   (--test replays raw events, for tests)
"""
import fcntl
import glob
import json
import os
import struct
import sys

EV_SYN, EV_KEY, EV_ABS = 0, 1, 3
SYN_REPORT = 0
ABS_X, ABS_Y = 0x00, 0x01
ABS_MT_SLOT, ABS_MT_POSITION_X, ABS_MT_POSITION_Y, ABS_MT_TRACKING_ID = 0x2f, 0x35, 0x36, 0x39
EVENT = struct.Struct('llHHi')          # struct input_event on 64-bit: timeval, type, code, value

EDGE_X = 0.06       # a touch starting this close (of the width) to the left or right side is on that edge
EDGE_Y = 0.08       # of the height, for the top and bottom
START = 0.035       # travel along the edge before it counts as a swipe
STEP = 0.07         # travel for each step after that


def say(**message):
    sys.stdout.write(json.dumps(message) + '\n')
    sys.stdout.flush()


def find_touchpad():
    """The first input device udev marks as a touchpad."""
    for data in sorted(glob.glob('/run/udev/data/c13:*')):
        try:
            with open(data) as f:
                if 'E:ID_INPUT_TOUCHPAD=1' not in f.read():
                    continue
        except OSError:
            continue
        minor = int(data.rsplit(':', 1)[1])
        for node in glob.glob('/sys/class/input/event*/dev'):
            try:
                with open(node) as f:
                    if f.read().strip() == f'13:{minor}':
                        return '/dev/input/' + node.split('/')[-2]
            except OSError:
                continue
    return None


def device_name(path):
    try:
        with open(f'/sys/class/input/{os.path.basename(path)}/device/name') as f:
            return f.read().strip()
    except OSError:
        return path


def absinfo(fd, code):
    """EVIOCGABS(code): value, minimum, maximum, fuzz, flat, resolution."""
    request = (2 << 30) | (24 << 16) | (ord('E') << 8) | (0x40 + code)
    data = fcntl.ioctl(fd, request, bytes(24))
    return struct.unpack('6i', data)


class Edges:
    def __init__(self, xrange, yrange):
        self.xmin, self.xmax = xrange
        self.ymin, self.ymax = yrange
        self.slots = {}         # slot -> {'id', 'x', 'y'}
        self.slot = 0
        self.single = None      # the one touch: {'x0', 'y0', 'edge', 'active', 'steps'}

    def norm(self, x, y):
        return ((x - self.xmin) / max(1, self.xmax - self.xmin), (y - self.ymin) / max(1, self.ymax - self.ymin))

    def event(self, etype, code, value):
        if etype == EV_ABS:
            if code == ABS_MT_SLOT:
                self.slot = value
            elif code == ABS_MT_TRACKING_ID:
                if value < 0:
                    self.slots.pop(self.slot, None)
                else:
                    self.slots[self.slot] = {'id': value, 'x': None, 'y': None}
            elif code == ABS_MT_POSITION_X:
                self.slots.setdefault(self.slot, {'id': 0, 'x': None, 'y': None})['x'] = value
            elif code == ABS_MT_POSITION_Y:
                self.slots.setdefault(self.slot, {'id': 0, 'x': None, 'y': None})['y'] = value
        elif etype == EV_SYN and code == SYN_REPORT:
            self.frame()

    def frame(self):
        touches = [t for t in self.slots.values() if t['x'] is not None and t['y'] is not None]
        if len(touches) != 1:
            # lifted, or more fingers (those are GNOME's gestures and scrolling)
            self.finish()
            return
        x, y = self.norm(touches[0]['x'], touches[0]['y'])
        s = self.single
        if s is None or s['id'] != touches[0]['id']:
            self.finish()
            self.single = {'id': touches[0]['id'], 'x0': x, 'y0': y, 'edge': self.edge_at(x, y), 'active': False, 'travel': 0.0}
            return
        if not s['edge']:
            return
        vertical = s['edge'] in ('left', 'right')
        along = (s['y0'] - y) if vertical else (x - s['x0'])     # up / to the right is positive
        across = abs(x - s['x0']) if vertical else abs(y - s['y0'])
        if not s['active']:
            if across > START * 1.5 and across > abs(along):
                s['edge'] = None        # it moves away from the edge: an ordinary pointer move
                return
            if abs(along) >= START and abs(along) > 2 * across:
                s['active'] = True
                s['base'] = along
                say(type='begin', edge=s['edge'])
            return
        while along - s['base'] >= STEP:
            s['base'] += STEP
            say(type='step', edge=s['edge'], dir=1)
        while s['base'] - along >= STEP:
            s['base'] -= STEP
            say(type='step', edge=s['edge'], dir=-1)

    def edge_at(self, x, y):
        near = []
        if x <= EDGE_X:
            near.append((x / EDGE_X, 'left'))
        if x >= 1 - EDGE_X:
            near.append(((1 - x) / EDGE_X, 'right'))
        if y <= EDGE_Y:
            near.append((y / EDGE_Y, 'top'))
        if y >= 1 - EDGE_Y:
            near.append(((1 - y) / EDGE_Y, 'bottom'))
        return min(near)[1] if near else None

    def finish(self):
        if self.single and self.single.get('active'):
            say(type='end', edge=self.single['edge'])
        self.single = None


def run(stream, edges):
    while True:
        data = stream.read(EVENT.size)
        if not data or len(data) < EVENT.size:
            break
        _sec, _usec, etype, code, value = EVENT.unpack(data)
        edges.event(etype, code, value)
    edges.finish()


def main(argv):
    if '--test' in argv:
        path = argv[argv.index('--test') + 1]
        w, h = (int(v) for v in argv[argv.index('--range') + 1:argv.index('--range') + 3])
        with open(path, 'rb') as stream:
            run(stream, Edges((0, w), (0, h)))
        return 0
    path = argv[argv.index('--device') + 1] if '--device' in argv else find_touchpad()
    if not path:
        say(type='error', code='none', message='No touchpad was found')
        return 1
    try:
        fd = os.open(path, os.O_RDONLY)
    except PermissionError:
        say(type='error', code='access', message=f'No access to {path}: run touchpad-access.sh once (see Settings → Touchpad gestures)')
        return 2
    except OSError as e:
        say(type='error', code='read', message=str(e))
        return 1
    try:
        x = absinfo(fd, ABS_MT_POSITION_X)
        y = absinfo(fd, ABS_MT_POSITION_Y)
    except OSError:
        x, y = absinfo(fd, ABS_X), absinfo(fd, ABS_Y)
    say(type='ready', device=device_name(path), width=x[2] - x[1], height=y[2] - y[1])
    with os.fdopen(fd, 'rb', buffering=0) as stream:
        try:
            run(stream, Edges((x[1], x[2]), (y[1], y[2])))
        except OSError as e:
            say(type='error', code='read', message=str(e))
            return 1
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
