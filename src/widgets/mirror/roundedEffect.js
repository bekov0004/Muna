import {snippetEffect} from '../../ui/snippetEffect.js';

/**
 * Clips an actor's content to a square with rounded corners (radius 9% of the side), with a
 * soft edge. Used for the enlarged webcam preview (the content must be square).
 */
export const RoundedEffect = snippetEffect('MunaRoundedEffect', '', `
    vec2 muna_p = abs(cogl_tex_coord_in[0].xy - vec2(0.5)) - vec2(0.5 - 0.09);
    float muna_d = length(max(muna_p, vec2(0.0))) + min(max(muna_p.x, muna_p.y), 0.0) - 0.09;
    cogl_color_out *= 1.0 - smoothstep(-0.006, 0.004, muna_d);
`);
