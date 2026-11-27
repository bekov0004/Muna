import Clutter from 'gi://Clutter';
import GObject from 'gi://GObject';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

import {snippetEffect} from './snippetEffect.js';

/**
 * "Real glass" behind the capsule (Settings → Appearance → Liquid glass): the desktop behind it is
 * not blurred but bent like through a lens at the rim (refraction), split into colours there
 * (dispersion), with a thin bright rim lit from above. The capsule's own tint lies on top.
 *
 * A clone of the desktop's background (windows are not taken: GNOME does not paint its window
 * layer into an effect) is lined up with the element and drawn through the shader; the shader also cuts it to the
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
        this._clone = new Clutter.Clone({source: Main.layoutManager._backgroundGroup});
        this.add_child(this._clone);
        this._effect = new GlassEffect();
        this.add_effect(this._effect);
        this._radius = 32;
        this._topRadius = 0;
    }

    /** Lines the glass up with the capsule actor (its place on the screen and its size) and its outline. */
    follow(actor, {radius, hanging}) {
        this._radius = radius;
        this._topRadius = hanging ? 0 : radius;
        const [x, y] = actor.get_transformed_position();
        const [w, h] = actor.get_transformed_size();
        if (!(w > 0 && h > 0))
            return;
        this.set_position(Math.round(x), Math.round(y));
        this.set_size(Math.round(w), Math.round(h));
        this._clone.set_position(-Math.round(x), -Math.round(y));
        this._effect.setUniform('muna_w', [w]);
        this._effect.setUniform('muna_h', [h]);
        this._effect.setUniform('muna_r', [Math.min(radius, h / 2, w / 2)]);
        this._effect.setUniform('muna_top_r', [Math.min(this._topRadius, h / 2, w / 2)]);
        this._effect.queue_repaint();
        this.queue_relayout();
    }
});

/**
 * Puts any of Muna's elements on liquid glass while Settings → Appearance → Liquid glass is on: a glass
 * layer under it (in Muna's layer, below the element's top-level actor) that follows it every frame.
 */
export class GlassManager {
    constructor(settings) {
        this._settings = settings;
        this._entries = new Set();
        this._enabled = settings.get('liquid-glass');
        this._settingsId = settings.connect('changed', (_s, key) => {
            if (key === 'liquid-glass')
                this._setEnabled(settings.get('liquid-glass'));
        });
        this._updateId = global.stage.connect('before-update', () => this._update());
        this._mark();
    }

    /** "muna-liquid" on the marked actors: the stylesheet makes their backgrounds thin tints over the glass. */
    _mark() {
        for (const entry of this._entries ?? [])
            this._markOne(entry);
    }

    _markOne(entry) {
        if (!entry.mark)
            return;
        if (this._enabled)
            entry.mark.add_style_class_name('muna-liquid');
        else
            entry.mark.remove_style_class_name('muna-liquid');
    }

    get enabled() {
        return this._enabled;
    }

    /**
     * @param {Clutter.Actor} actor  the element; the glass takes its place and size on the screen
     * @param {() => {radius: number, hanging?: boolean}} shape  its outline now (px)
     * @returns {{remove: Function}}
     */
    attach(actor, shape, {mark = null} = {}) {
        const entry = {actor, shape, glass: null, mark};
        this._markOne(entry);
        this._entries.add(entry);
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
        this._mark();
        if (!on) {
            for (const entry of this._entries)
                entry.glass?.hide();
        }
        global.stage.queue_redraw();
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
        for (const entry of this._entries) {
            const {actor} = entry;
            const top = actor.mapped ? this._topOf(actor) : null;
            if (!top || actor.get_paint_opacity() < 8) {
                entry.glass?.hide();
                continue;
            }
            if (!entry.glass) {
                entry.glass = new LiquidGlass();
                Main.layoutManager.uiGroup.add_child(entry.glass);
            }
            const ui = Main.layoutManager.uiGroup;
            if (entry.glass.get_parent() !== ui)
                continue;
            // under the element's top actor (inner elements: above the glass of the element they lie on)
            ui.set_child_below_sibling(entry.glass, top);
            entry.glass.show();
            entry.glass.follow(actor, entry.shape());
        }
    }

    destroy() {
        this._enabled = false;
        this._mark();
        global.stage.disconnect(this._updateId);
        this._settings.disconnect(this._settingsId);
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
