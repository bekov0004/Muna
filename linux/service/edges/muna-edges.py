#!/usr/bin/env python3
"""muna-edges: one-finger swipes along the edges of the touchpad.

GNOME tells nobody where a single finger is on the touchpad (one finger only moves the pointer), so this reads the
touchpad itself (/dev/input/eventN; the user needs read access to it: scripts/touchpad-access.sh gives the user of the
seat access to touchpads only). A swipe that starts at an edge and goes along it gives steps:

    {"type": "ready", "device": "ELAN076C:00 04F3:3245 Touchpad"}
    {"type": "begin", "edge": "left"}          left / right: along the edge up or down; top / bottom: left or right
    {"type": "step", "edge": "left", "dir": 1}  1: up (left, right) or to the right (top, bottom); -1: the other way
    {"type": "end", "edge": "left"}
    {"type": "doubletap", "zone": "top"}      a double tap in a zone: left, right (edges), top, bottom (middle third)
    {"type": "hold", "zone": "top"}           a finger resting still in a zone for half a second
    {"type": "error", "code": "access" | "none" | "read", "message": "..."}

Usage: muna-edges.py [--device /dev/input/eventN] [--test FILE --range W H]   (--test replays raw events, for tests)
"""
import fcntl
import glob
import json
import os
import select
import struct
import sys
import time

EV_SYN, EV_KEY, EV_ABS = 0, 1, 3
SYN_REPORT = 0
ABS_X, ABS_Y = 0x00, 0x01
ABS_MT_SLOT, ABS_MT_POSITION_X, ABS_MT_POSITION_Y, ABS_MT_TRACKING_ID = 0x2f, 0x35, 0x36, 0x39
EVENT = struct.Struct('llHHi')          # struct input_event on 64-bit: timeval, type, code, value

EDGE_X = 0.06       # a touch starting this close (of the width) to the left or right side is on that edge
EDGE_Y = 0.08       # of the height, for the top and bottom
START = 0.035       # travel along the edge before it counts as a swipe
STEP = 0.07         # travel for each step after that
TAP_S = 0.22        # a tap: down and up within this
DOUBLE_S = 0.40     # two taps in the same zone within this: a double tap
HOLD_S = 0.55       # resting still this long: a hold
STILL = 0.02        # a tap or a hold moves less than this


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
        self.single = None      # the one touch: {'x0', 'y0', 'edge', 'zone', 'active', 't0', 'moved', 'held'}
        self.last_tap = None    # (zone, time)
        self.now = 0.0

    def norm(self, x, y):
        return ((x - self.xmin) / max(1, self.xmax - self.xmin), (y - self.ymin) / max(1, self.ymax - self.ymin))

    def event(self, etype, code, value, now):
        self.now = now
        self._event(etype, code, value)

    def _event(self, etype, code, value):
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
            self.single = {'id': touches[0]['id'], 'x0': x, 'y0': y, 'edge': self.edge_at(x, y), 'zone': self.zone_at(x, y),
                           'active': False, 't0': self.now, 'moved': False, 'held': False}
            return
        if max(abs(x - s['x0']), abs(y - s['y0'])) > STILL:
            s['moved'] = True
        self.tick(self.now)
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

    def zone_at(self, x, y):
        """Where a tap or a hold counts: the left and right edges, the middle third of the top and bottom edges."""
        if x <= EDGE_X:
            return 'left'
        if x >= 1 - EDGE_X:
            return 'right'
        if 1 / 3 <= x <= 2 / 3:
            if y <= EDGE_Y:
                return 'top'
            if y >= 1 - EDGE_Y:
                return 'bottom'
        return None

    def tick(self, now):
        """A finger resting still in a zone long enough is a hold (also when the touchpad sends nothing meanwhile)."""
        s = self.single
        if s and s['zone'] and not s['moved'] and not s['held'] and not s['active'] and now - s['t0'] >= HOLD_S:
            s['held'] = True
            say(type='hold', zone=s['zone'])

    def finish(self):
        s = self.single
        if s and s.get('active'):
            say(type='end', edge=s['edge'])
        elif s and s['zone'] and not s['moved'] and not s['held'] and self.now - s['t0'] <= TAP_S:
            # a tap: the second one in the same zone soon after the first is a double tap
            last = self.last_tap
            if last and last[0] == s['zone'] and s['t0'] - last[1] <= DOUBLE_S:
                say(type='doubletap', zone=s['zone'])
                self.last_tap = None
            else:
                self.last_tap = (s['zone'], self.now)
        self.single = None


def replay(stream, edges):
    """Events from a file (tests): the time is the events' own."""
    while True:
        data = stream.read(EVENT.size)
        if not data or len(data) < EVENT.size:
            break
        sec, usec, etype, code, value = EVENT.unpack(data)
        edges.event(etype, code, value, sec + usec / 1e6)
    edges.finish()


def listen(fd, edges):
    """The touchpad itself; a hold is noticed also when it sends nothing."""
    buffer = b''
    while True:
        ready, _, _ = select.select([fd], [], [], 0.05)
        now = time.monotonic()
        if not ready:
            edges.tick(now)
            continue
        data = os.read(fd, EVENT.size * 64)
        if not data:
            break
        buffer += data
        while len(buffer) >= EVENT.size:
            _sec, _usec, etype, code, value = EVENT.unpack(buffer[:EVENT.size])
            buffer = buffer[EVENT.size:]
            edges.event(etype, code, value, now)
    edges.finish()


def main(argv):
    if '--test' in argv:
        path = argv[argv.index('--test') + 1]
        w, h = (int(v) for v in argv[argv.index('--range') + 1:argv.index('--range') + 3])
        with open(path, 'rb') as stream:
            replay(stream, Edges((0, w), (0, h)))
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
    try:
        listen(fd, Edges((x[1], x[2]), (y[1], y[2])))
    except OSError as e:
        say(type='error', code='read', message=str(e))
        return 1
    finally:
        os.close(fd)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
