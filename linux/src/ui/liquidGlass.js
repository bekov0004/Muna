import Clutter from 'gi://Clutter';
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
    float muna_box(vec2 p) {
        // the capsule's outline as a signed distance (negative inside), in pixels
        vec2 c = vec2(muna_w, muna_h) * 0.5;
        // hanging from the screen's top edge: the upper half only has the sides (no top rim), so the field stays smooth
        if (muna_top_r < 0.5)
            p.y = max(p.y, c.y);
        vec2 q = abs(p - c) - c + vec2(muna_r);
        return length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - muna_r;
    }
`, `
    vec2 muna_size = vec2(muna_w, muna_h);
    vec2 muna_uv = cogl_tex_coord_in[0].xy;
    vec2 muna_p = muna_uv * muna_size;
    float muna_d = muna_box(muna_p);
    // the outline's normal, from the distance field
    vec2 muna_n = normalize(vec2(muna_box(muna_p + vec2(1.0, 0.0)) - muna_box(muna_p - vec2(1.0, 0.0)),
                                 muna_box(muna_p + vec2(0.0, 1.0)) - muna_box(muna_p - vec2(0.0, 1.0))) + 1e-5);
    // how close to the rim (0 in the middle, 1 at the edge), a lens profile
    float muna_band = clamp(min(muna_w, muna_h) * 0.42, 14.0, 46.0);
    float muna_e = clamp(1.0 + muna_d / muna_band, 0.0, 1.0);
    float muna_lens = muna_e * muna_e;
    // refraction: near the rim the picture is taken from further in (it bends and magnifies);
    // dispersion: red, green and blue bend by different amounts
    // at most a third of the band: the picture magnifies at the rim but never folds over (red bends most)
    vec2 muna_bend = muna_n * muna_lens * muna_band * 0.26 / muna_size;
    float muna_red = texture2D(cogl_sampler0, muna_uv - muna_bend * 1.9).r;
    float muna_green = texture2D(cogl_sampler0, muna_uv - muna_bend).g;
    float muna_blue = texture2D(cogl_sampler0, muna_uv - muna_bend * 0.15).b;
    vec3 muna_rgb = vec3(muna_red, muna_green, muna_blue);
    // rim light: a thin bright line, strongest where it faces the light (up and to the left)
    float muna_line = smoothstep(-3.0, -0.8, muna_d) * (1.0 - smoothstep(-0.8, 0.5, muna_d));
    float muna_face = clamp(dot(muna_n, normalize(vec2(-0.6, -1.0))) * 0.5 + 0.5, 0.0, 1.0);
    muna_rgb = mix(muna_rgb, vec3(1.0), muna_line * (0.35 + 0.6 * muna_face));
    // a soft lit band inside the rim, as thick glass catches light
    muna_rgb += vec3(0.6, 0.65, 1.0) * muna_lens * muna_lens * 0.16;
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
        this._effect.setUniform('muna_w', [w]);
        this._effect.setUniform('muna_h', [h]);
        this._effect.setUniform('muna_r', [Math.min(radius, h / 2, w / 2)]);
        this._effect.setUniform('muna_top_r', [hanging ? 0 : Math.min(radius, h / 2, w / 2)]);
        this._effect.queue_repaint();
        this.queue_relayout();
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
export class GlassManager {
    constructor(settings) {
        this._settings = settings;
        this._entries = new Set();
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
    attach(actor, shape, {mark = null} = {}) {
        const entry = {actor, shape, glass: null, mark};
        this._entries.add(entry);
        this._markOne(entry);
        actor.connectObject('destroy', () => this._remove(entry), this);
        return {remove: () => this._remove(entry)};
    }

    _remove(entry) {
        entry.glass?.destroy();
        entry.glass = null;
        this._entries.delete(entry);
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
            global.window_group.set_child_below_sibling(glass, actor);
            const frame = window.get_frame_rect();
            const rect = {x: frame.x, y: frame.y, width: frame.width, height: frame.height};
            glass.setWindows(windowsUnder(rect, {below: actor}));
            glass.show();
            // a maximized window has square corners
            glass.follow(rect, {radius: window.get_maximized?.() ? 0 : 15});
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
