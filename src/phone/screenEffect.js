import Cogl from 'gi://Cogl';
import GObject from 'gi://GObject';
import Shell from 'gi://Shell';

/**
 * Clips an actor's picture to a rectangle with round corners (radius in px) and a soft edge, for a
 * picture of a known size. Make a new one when the size changes.
 */
// GLib builds the pipeline while the effect is being constructed, before the constructor can store
// anything on it: the sizes wait here for that moment.
let pending = {w: 1, h: 1, r: 0};

export const ScreenEffect = GObject.registerClass({
    GTypeName: 'MunaPhoneScreenEffect',
}, class ScreenEffect extends Shell.GLSLEffect {
    _init(width, height, radius) {
        pending = {w: Math.max(1, width).toFixed(1), h: Math.max(1, height).toFixed(1), r: Math.max(0, radius).toFixed(1)};
        super._init();
    }

    vfunc_build_pipeline() {
        const {w, h, r} = pending;
        this.add_glsl_snippet(Cogl.SnippetHook.FRAGMENT, '', `
            vec2 muna_size = vec2(${w}, ${h});
            vec2 muna_p = (cogl_tex_coord_in[0].xy - vec2(0.5)) * muna_size;
            vec2 muna_q = abs(muna_p) - (muna_size * 0.5 - vec2(${r}));
            float muna_d = length(max(muna_q, vec2(0.0))) + min(max(muna_q.x, muna_q.y), 0.0) - ${r};
            cogl_color_out *= 1.0 - smoothstep(-0.8, 0.6, muna_d);
        `, false);
    }
});
