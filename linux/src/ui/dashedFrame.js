import Cairo from 'cairo';
import GObject from 'gi://GObject';
import St from 'gi://St';

/**
 * A dashed rounded outline (St draws borders solid only): put it in a BinLayout under the content.
 * The design's dashed places: the shortcuts' "Add" tile, the tray's "Drop files on the capsule" tile.
 */
export const DashedFrame = GObject.registerClass({GTypeName: 'MunaDashedFrame'}, class DashedFrame extends St.DrawingArea {
    /** @param {{radius?: number, width?: number, rgba?: number[], dash?: number, gap?: number}} params */
    _init({radius = 13, width = 1.5, rgba = [1, 1, 1, 0.3], dash = 4, gap = 3} = {}) {
        super._init({x_expand: true, y_expand: true, reactive: false});
        this._look = {radius, width, rgba, dash, gap};
    }

    vfunc_repaint() {
        const cr = this.get_context();
        const [w, h] = this.get_surface_size();
        const scale = St.ThemeContext.get_for_stage(global.stage).scale_factor;
        const {radius, width, rgba, dash, gap} = this._look;
        const lw = width * scale;
        const inset = lw / 2;
        const ww = w - 2 * inset, hh = h - 2 * inset;
        const r = Math.min(radius * scale, ww / 2, hh / 2);
        cr.newSubPath();
        cr.arc(inset + ww - r, inset + r, r, -Math.PI / 2, 0);
        cr.arc(inset + ww - r, inset + hh - r, r, 0, Math.PI / 2);
        cr.arc(inset + r, inset + hh - r, r, Math.PI / 2, Math.PI);
        cr.arc(inset + r, inset + r, r, Math.PI, 1.5 * Math.PI);
        cr.closePath();
        cr.setSourceRGBA(...rgba);
        cr.setLineWidth(lw);
        cr.setLineCap(Cairo.LineCap.BUTT);
        cr.setDash([dash * scale, gap * scale], 0);
        cr.stroke();
        cr.$dispose();
    }
});
