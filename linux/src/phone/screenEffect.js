import {snippetEffect} from '../ui/snippetEffect.js';

const ScreenEffectBase = snippetEffect('MunaPhoneScreenEffect',
    'uniform vec2 muna_size;\nuniform float muna_radius;\n', `
    vec2 muna_p = (cogl_tex_coord_in[0].xy - vec2(0.5)) * muna_size;
    vec2 muna_q = abs(muna_p) - (muna_size * 0.5 - vec2(muna_radius));
    float muna_d = length(max(muna_q, vec2(0.0))) + min(max(muna_q.x, muna_q.y), 0.0) - muna_radius;
    cogl_color_out *= 1.0 - smoothstep(-0.8, 0.6, muna_d);
`);

/**
 * An effect that clips an actor's picture to a rectangle with round corners (radius in px) and a
 * soft edge, for a picture of a known size. Make a new one when the size changes.
 */
export function screenEffect(width, height, radius) {
    const effect = new ScreenEffectBase();
    effect.setUniform('muna_size', [Math.max(1, width), Math.max(1, height)]);
    effect.setUniform('muna_radius', [Math.max(0, radius)]);
    return effect;
}
