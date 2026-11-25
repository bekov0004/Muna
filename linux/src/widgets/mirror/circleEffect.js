import {snippetEffect} from '../../ui/snippetEffect.js';

/**
 * Clips an actor's content to the circle inscribed in its box, with a soft
 * edge. Used for the round webcam preview (the content must be square).
 */
export const CircleEffect = snippetEffect('MunaCircleEffect', '', `
    vec2 muna_p = cogl_tex_coord_in[0].xy - vec2(0.5);
    float muna_edge = 1.0 - smoothstep(0.485, 0.5, length(muna_p));
    cogl_color_out *= muna_edge;
`);
