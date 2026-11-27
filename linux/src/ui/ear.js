import Cairo from 'gi://cairo';
import GObject from 'gi://GObject';
import St from 'gi://St';

/**
 * A small concave fillet where the expanded capsule meets the bottom edge of
 * the top bar, so the capsule looks like it hangs from the bar (as a notch does) instead of overlapping it. One on each side.
 */
export class Ear extends St.DrawingArea {
    static {
        GObject.registerClass({GTypeName: 'MunaEar'}, this);
    }

    /** @param {'left'|'right'} side which side of the capsule it is on */
    constructor(side) {
        super({reactive: false, visible: false, opacity: 0});
        this._side = side;
        this._color = [0, 0, 0, 0.96];
        this._bottom = null;
        this._share = 0;
    }

    setColor(r, g, b, a) {
        this._color = [r, g, b, a];
        this._bottom = null;
        this.queue_repaint();
    }

    /**
     * The capsule's background is a vertical gradient: the ear paints the same one, so ear and capsule are one piece.
     * @param {number[]} top     [r, g, b, a] at the capsule's top (0–255, alpha 0–1)
     * @param {number[]} bottom  the same at the capsule's bottom
     */
    setGradient(top, bottom) {
        this._color = top;
        this._bottom = bottom;
        this.queue_repaint();
    }

    /** How much of the capsule's height the ear covers (0–1): where its own gradient must end. */
    setShare(share) {
        const value = Math.max(0, Math.min(1, share));
        if (Math.abs(value - this._share) < 0.001)
            return;
        this._share = value;
        this.queue_repaint();
    }

    /** On liquid glass the capsule is the glass's own shape: the ears draw nothing. */
    setHidden(hidden) {
        this._hidden = hidden;
        this.queue_repaint();
    }

    vfunc_repaint() {
        const cr = this.get_context();
        if (this._hidden) {
            cr.$dispose();
            return;
        }
        const [width, height] = this.get_surface_size();
        const [r, g, b, a] = this._color;
        // The box minus a circle centred on its far bottom corner: what
        // remains hugs the bar above and the capsule beside it.
        if (this._bottom) {
            const [r2, g2, b2, a2] = this._bottom;
            const t = this._share;
            const mix = (x, y) => x + (y - x) * t;
            const gradient = new Cairo.LinearGradient(0, 0, 0, height);
            gradient.addColorStopRGBA(0, r / 255, g / 255, b / 255, a);
            gradient.addColorStopRGBA(1, mix(r, r2) / 255, mix(g, g2) / 255, mix(b, b2) / 255, mix(a, a2));
            cr.setSource(gradient);
        } else {
            cr.setSourceRGBA(r / 255, g / 255, b / 255, a);
        }
        cr.setFillRule(Cairo.FillRule.EVEN_ODD);
        cr.rectangle(0, 0, width, height);
        const left = this._side === 'left';
        // The ear is `height` tall and as wide, plus a strip that lies over the capsule's side border.
        const radius = height;
        cr.arc(left ? 0 : width, height, radius, 0, 2 * Math.PI);
        cr.fill();

        // The capsule's thin side border carries on along the curve, up to the screen edge.
        cr.rectangle(0, 0, width, height);
        cr.clip();
        cr.newPath();
        if (left)
            cr.arc(0, height, radius + 0.5, -Math.PI / 2, 0);
        else
            cr.arc(width, height, radius + 0.5, Math.PI, 1.5 * Math.PI);
        cr.setSourceRGBA(176 / 255, 184 / 255, 1, 0.19);
        cr.setLineWidth(1);
        cr.stroke();
        cr.$dispose();
    }
}
