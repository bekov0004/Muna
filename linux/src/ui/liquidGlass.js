import Clutter from 'gi://Clutter';
import St from 'gi://St';
import GLib from 'gi://GLib';
import GObject from 'gi://GObject';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

import {snippetEffect} from './snippetEffect.js';

/**
 * "Real glass" behind the capsule (Settings → Appearance → Liquid glass): the desktop behind it is
 * not blurred but bent like through a lens at the rim (refraction), split into colours there
 * (dispersion), with a thin bright rim lit from above. The capsule's own tint lies on top.
 *
 * Copies of what is under the element (the desktop's background and each window there, as the overview's
 * window previews copy them) are lined up with it and drawn through the shader; the shader also cuts it to the
 * element's outline (square top and round bottom corners when it hangs from the screen's edge).
 */
const GlassEffect = snippetEffect('MunaLiquidGlassEffect', `
    uniform float muna_w;
    uniform float muna_h;
    uniform float muna_r;
    uniform float muna_top_r;
    uniform float muna_blur;
    float muna_rbox(vec2 p, float r) {
        // the outline as a signed distance (negative inside), in pixels, with corners of radius r
        vec2 c = vec2(muna_w, muna_h) * 0.5;
        // hanging from the screen's top edge: the upper half only has the sides (no top rim), so the field stays smooth
        if (muna_top_r < 0.5)
            p.y = max(p.y, c.y);
        r = min(r, min(c.x, c.y));
        vec2 q = abs(p - c) - c + vec2(r);
        return length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - r;
    }
    float muna_box(vec2 p) {
        return muna_rbox(p, muna_r);
    }
    // a colour of the spectrum, t from 0 (red) to 1 (violet)
    vec3 muna_spectrum(float t) {
        return clamp(vec3(1.5 - abs(4.0 * t - 1.0), 1.5 - abs(4.0 * t - 2.0), 1.5 - abs(4.0 * t - 3.0)), 0.0, 1.0);
    }
`, `
    vec2 muna_size = vec2(muna_w, muna_h);
    vec2 muna_uv = cogl_tex_coord_in[0].xy;
    vec2 muna_p = muna_uv * muna_size;
    float muna_d = muna_box(muna_p);
    // small panes (buttons, chips) get a thin bevel and a quiet rim; big ones a wide lens
    float muna_small = 1.0 - smoothstep(26.0, 60.0, min(muna_w, muna_h));
    float muna_band = mix(clamp(min(muna_w, muna_h) * 0.34, 14.0, 60.0), min(muna_w, muna_h) * 0.3, muna_small);
    // the lens: a smooth body whose corners are at least as round as its bevel (no crease along a corner's diagonal)
    float muna_lr = max(muna_r, muna_band);
    float muna_ld = muna_rbox(muna_p, muna_lr);
    vec2 muna_n = normalize(vec2(muna_rbox(muna_p + vec2(1.0, 0.0), muna_lr) - muna_rbox(muna_p - vec2(1.0, 0.0), muna_lr),
                                 muna_rbox(muna_p + vec2(0.0, 1.0), muna_lr) - muna_rbox(muna_p - vec2(0.0, 1.0), muna_lr)) + 1e-5);
    float muna_u = clamp(1.0 + muna_ld / muna_band, 0.0, 0.985);
    float muna_z = sqrt(1.0 - muna_u * muna_u);
    vec3 muna_normal = normalize(vec3(muna_n * muna_u, muna_z));
    float muna_thick = muna_band * (0.55 + 0.6 * muna_z) * mix(1.0, 0.35, muna_small);
    // refraction (Snell, index 1.5) for the middle colour, frosted in the middle of the glass
    vec3 muna_ray = refract(vec3(0.0, 0.0, -1.0), muna_normal, 1.0 / 1.5);
    vec2 muna_shift = muna_ray.xy / max(-muna_ray.z, 0.2) * muna_thick / muna_size;
    vec2 muna_at = muna_uv + muna_shift;
    vec2 muna_r = vec2(muna_blur * muna_z) / muna_size;
    vec3 muna_rgb = texture2D(cogl_sampler0, muna_at).rgb * 0.2;
    for (int k = 0; k < 8; k++) {
        float a = float(k) * 0.785398 + 0.39;
        muna_rgb += texture2D(cogl_sampler0, muna_at + vec2(cos(a), sin(a)) * muna_r).rgb * 0.1;
    }
    // dispersion at the steep rim: red bends less, blue more (a rainbow edge)
    float muna_edge = 1.0 - muna_z;
    float muna_spread = smoothstep(0.05, 0.6, muna_edge) * (1.0 - muna_small * 0.7);
    float muna_red = texture2D(cogl_sampler0, muna_uv + muna_shift * 0.72).r;
    float muna_blue = texture2D(cogl_sampler0, muna_uv + muna_shift * 1.35).b;
    muna_rgb.r = mix(muna_rgb.r, muna_red, muna_spread);
    muna_rgb.b = mix(muna_rgb.b, muna_blue, muna_spread);
    // the body of the glass: a light frost and a sheen from above, so it shows on a plain backdrop too
    float muna_y = muna_uv.y;
    muna_rgb = mix(muna_rgb, vec3(1.0), 0.07 + 0.07 * (1.0 - muna_y) * (1.0 - muna_small));
    // light on the rim: reflection where it faces the light (up, left), a lit bottom bevel, Fresnel
    float muna_face = clamp(dot(muna_n, normalize(vec2(-0.6, -1.0))) * 0.5 + 0.5, 0.0, 1.0);
    float muna_quiet = mix(1.0, 0.45, muna_small);
    muna_rgb += vec3(1.0) * pow(muna_edge, 3.0) * (0.12 + 0.28 * muna_face) * muna_quiet;
    muna_rgb += vec3(1.0, 0.97, 0.94) * pow(muna_edge, 6.0) * clamp(muna_n.y, 0.0, 1.0) * 0.22 * muna_quiet;
    float muna_line = smoothstep(-2.0, -0.6, muna_d) * (1.0 - smoothstep(-0.6, 0.5, muna_d));
    muna_rgb = mix(muna_rgb, vec3(1.0), muna_line * (0.18 + 0.5 * muna_face) * muna_quiet);
    float muna_inside = 1.0 - smoothstep(-0.5, 0.5, muna_d);
    cogl_color_out = vec4(muna_rgb * muna_inside, muna_inside);
`);

export const LiquidGlass = GObject.registerClass({GTypeName: 'MunaLiquidGlass'}, class LiquidGlass extends Clutter.Actor {
    _init() {
        super._init({reactive: false, clip_to_allocation: true, visible: false});
        // the scene under the glass: the desktop's background, then copies of the windows under it, bottom to top
        this._background = new Clutter.Clone({source: Main.layoutManager._backgroundGroup});
        this.add_child(this._background);
        this._windows = [];   // [{source, clone}]
        this._effect = new GlassEffect();
        this.add_effect(this._effect);
    }

    /** The windows to see through the glass, bottom to top (their window actors). */
    setWindows(actors) {
        if (actors.length === this._windows.length && actors.every((a, i) => this._windows[i].source === a))
            return;
        this._windows.forEach(w => w.clone.destroy());
        this._windows = actors.map(source => {
            const clone = new Clutter.Clone({source});
            this.add_child(clone);
            return {source, clone};
        });
    }

    /**
     * Puts the glass over a rectangle of the screen with the given outline.
     * @param {{x: number, y: number, width: number, height: number}} rect  in stage pixels
     */
    follow(rect, {radius, hanging = false}) {
        const {x, y, width: w, height: h} = rect;
        if (!(w > 0 && h > 0))
            return;
        const X = Math.round(x), Y = Math.round(y);
        this.set_position(X, Y);
        this.set_size(Math.round(w), Math.round(h));
        this._background.set_position(-X, -Y);
        for (const {source, clone} of this._windows) {
            const [sx, sy] = source.get_transformed_position();
            clone.set_position(Math.round(sx) - X, Math.round(sy) - Y);
            clone.opacity = source.get_paint_opacity();
        }
        const key = `${X},${Y},${Math.round(w)},${Math.round(h)},${radius},${hanging}`;
        if (key === this._key)
            return;
        this._key = key;
        this._effect.setUniform('muna_w', [w]);
        this._effect.setUniform('muna_h', [h]);
        this._effect.setUniform('muna_r', [Math.min(radius, h / 2, w / 2)]);
        this._effect.setUniform('muna_blur', [8.0]);
        this._effect.setUniform('muna_top_r', [hanging ? 0 : Math.min(radius, h / 2, w / 2)]);
        this._effect.queue_repaint();
    }
});

/** The window actors that are seen on the screen, bottom to top, that touch a rectangle. */
function windowsUnder(rect, {below = null} = {}) {
    const list = [];
    for (const actor of global.get_window_actors()) {
        if (actor === below)
            break;
        const window = actor.meta_window;
        if (!actor.visible || !window || window.minimized || !window.showing_on_its_workspace?.())
            continue;
        if (window.get_workspace && !window.is_on_all_workspaces() && window.get_workspace() !== global.workspace_manager.get_active_workspace())
            continue;
        const [ax, ay] = actor.get_transformed_position();
        const [aw, ah] = actor.get_transformed_size();
        if (ax < rect.x + rect.width && ax + aw > rect.x && ay < rect.y + rect.height && ay + ah > rect.y)
            list.push(actor);
    }
    return list;
}

/** Is it one of Muna's own windows (settings, agents, scratchpad, the phone …)? */
function isMunaWindow(window) {
    const id = window.get_gtk_application_id?.() ?? '';
    return id === 'dev.muna.Muna' || (window.get_title?.() ?? '').startsWith('Muna');
}

/**
 * Puts any of Muna's elements on liquid glass while Settings → Appearance → Liquid glass is on: a glass
 * layer under it that sees the windows and the desktop under it and follows it every frame. Muna's own
 * windows get one too (they turn translucent themselves), in the window layer just under them.
 */
/**
 * The blocks inside Muna's surfaces that are panes of glass of their own (as every tile in the video): each
 * gets its own rim, so the blocks stay apart instead of melting into one sheet.
 */
const PANES = ['muna-card', 'muna-subcard', 'muna-menu-tabs', 'muna-menu-action', 'muna-chip', 'muna-lsv-tile',
    'muna-lsv-chip', 'muna-clip-row', 'muna-clip-entry', 'muna-todo-entry', 'muna-entry', 'muna-notif-item',
    'muna-file-main', 'muna-tray-clear', 'muna-timer-chip', 'muna-disk-tile', 'muna-tile', 'quick-toggle',
    'quick-slider', 'icon-button', 'quick-toggle-menu'];

export class GlassManager {
    constructor(settings) {
        this._settings = settings;
        this._entries = new Set();
        this._frame = 0;
        this._windowGlasses = new Map();   // MetaWindow → LiquidGlass
        this._enabled = settings.get('liquid-glass');
        this._settingsId = settings.connect('changed', (_s, key) => {
            if (key === 'liquid-glass')
                this._setEnabled(settings.get('liquid-glass'));
        });
        this._updateId = global.stage.connect('before-update', () => this._update());
    }

    get enabled() {
        return this._enabled;
    }

    /**
     * @param {Clutter.Actor} actor  the element; the glass takes its place and size on the screen
     * @param {() => {radius: number, hanging?: boolean}} shape  its outline now (px)
     * @param {{mark?: St.Widget}} options  mark: gets "muna-liquid" while the glass is on (thin backgrounds)
     * @returns {{remove: Function}}
     */
    attach(actor, shape, {mark = null, panes = false} = {}) {
        if (panes) {
            actor.connectObject('notify::mapped', () => {
                this._scanned = 0;
                GLib.timeout_add(GLib.PRIORITY_DEFAULT, 300, () => {
                    this._scanned = 0;
                    global.stage.queue_redraw();
                    return GLib.SOURCE_REMOVE;
                });
            }, this);
        }
        const entry = {actor, shape, glass: null, mark, panes, children: new Map()};
        this._entries.add(entry);
        this._markOne(entry);
        actor.connectObject('destroy', () => this._remove(entry), this);
        return {remove: () => this._remove(entry)};
    }

    _remove(entry) {
        entry.glass?.destroy();
        entry.glass = null;
        for (const child of entry.children?.values() ?? [])
            this._remove(child);
        entry.children?.clear();
        this._entries.delete(entry);
    }

    /** The panes inside an element (blocks with a pane's style class), outer ones first. */
    _scanPanes(entry) {
        const found = [];
        const walk = (actor, depth) => {
            for (let child = actor.get_first_child(); child; child = child.get_next_sibling()) {
                if (!child.visible)
                    continue;
                if (child.has_style_class_name && PANES.some(name => child.has_style_class_name(name)))
                    found.push(child);
                if (depth < 24)
                    walk(child, depth + 1);
            }
        };
        walk(entry.actor, 0);
        for (const actor of found) {
            if (entry.children.has(actor))
                continue;
            const shape = () => {
                let radius = 12;
                try {
                    radius = actor.get_theme_node().get_border_radius(St.Corner.TOPLEFT);
                } catch {
                    // not styled yet
                }
                return {radius: Math.max(radius, 4)};
            };
            const child = {actor, shape, glass: null, mark: null, panes: false, children: new Map(), pane: true};
            entry.children.set(actor, child);
            this._entries.add(child);
            actor.connectObject('destroy', () => {
                entry.children.delete(actor);
                this._remove(child);
            }, this);
        }
    }

    _setEnabled(on) {
        this._enabled = on;
        for (const entry of this._entries) {
            this._markOne(entry);
            if (!on)
                entry.glass?.hide();
        }
        if (!on)
            this._clearWindows();
        global.stage.queue_redraw();
    }

    _markOne(entry) {
        if (!entry.mark)
            return;
        if (this._enabled)
            entry.mark.add_style_class_name('muna-liquid');
        else
            entry.mark.remove_style_class_name('muna-liquid');
    }

    /** The element's top-level actor in Muna's layer: the glass goes just under it. */
    _topOf(actor) {
        const ui = Main.layoutManager.uiGroup;
        let top = actor;
        while (top && top.get_parent() !== ui)
            top = top.get_parent();
        return top;
    }

    _update() {
        if (!this._enabled)
            return;
        const ui = Main.layoutManager.uiGroup;
        // new blocks inside the surfaces: looked for a few times a second, not every frame
        const now = GLib.get_monotonic_time();
        if (now - (this._scanned ?? 0) > 250000) {
            this._scanned = now;
            for (const entry of [...this._entries]) {
                if (entry.panes && entry.actor.mapped)
                    this._scanPanes(entry);
            }
        }
        for (const entry of this._entries) {
            const {actor} = entry;
            const top = actor.mapped ? this._topOf(actor) : null;
            if (!top || actor.get_paint_opacity() < 8) {
                entry.glass?.hide();
                continue;
            }
            if (!entry.glass) {
                entry.glass = new LiquidGlass();
                ui.add_child(entry.glass);
            }
            // under the element's top actor (inner elements: above the glass of the element they lie on)
            if (entry.glass.get_next_sibling() !== top)
                ui.set_child_below_sibling(entry.glass, top);
            const [x, y] = actor.get_transformed_position();
            const [width, height] = actor.get_transformed_size();
            const rect = {x, y, width, height};
            entry.glass.setWindows(windowsUnder(rect));
            entry.glass.show();
            entry.glass.follow(rect, entry.shape());
        }
        this._updateWindows();
    }

    /** Muna's own windows: a glass in the window layer right under each, seeing the windows under it. */
    _updateWindows() {
        const seen = new Set();
        for (const actor of global.get_window_actors()) {
            const window = actor.meta_window;
            if (!window || !isMunaWindow(window) || window.minimized || !actor.visible)
                continue;
            seen.add(window);
            let glass = this._windowGlasses.get(window);
            if (!glass) {
                glass = new LiquidGlass();
                global.window_group.add_child(glass);
                this._windowGlasses.set(window, glass);
            }
            if (glass.get_next_sibling() !== actor)
                global.window_group.set_child_below_sibling(glass, actor);
            const frame = window.get_frame_rect();
            const rect = {x: frame.x, y: frame.y, width: frame.width, height: frame.height};
            glass.setWindows(windowsUnder(rect, {below: actor}));
            glass.show();
            // a maximized window has square corners
            glass.follow(rect, {radius: window.get_maximized?.() ? 0 : 12});
        }
        for (const [window, glass] of this._windowGlasses) {
            if (!seen.has(window)) {
                glass.destroy();
                this._windowGlasses.delete(window);
            }
        }
    }

    _clearWindows() {
        for (const glass of this._windowGlasses.values())
            glass.destroy();
        this._windowGlasses.clear();
    }

    destroy() {
        this._enabled = false;
        for (const entry of this._entries)
            this._markOne(entry);
        global.stage.disconnect(this._updateId);
        this._settings.disconnect(this._settingsId);
        this._clearWindows();
        for (const entry of [...this._entries])
            this._remove(entry);
    }
}

let shared = null;

/** The one glass manager of the extension (made on first use). */
export function glassManager(settings) {
    shared ??= new GlassManager(settings);
    return shared;
}

/** The extension is switched off: every glass layer goes. */
export function destroyGlassManager() {
    shared?.destroy();
    shared = null;
}

/** The glass manager if the capsule made it already (inner elements attach through it). */
export function currentGlassManager() {
    return shared;
}
