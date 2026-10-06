import Clutter from 'gi://Clutter';
import GObject from 'gi://GObject';
import St from 'gi://St';

/** LEFT section. Placeholder for the future media card (MPRIS). */
export class MediaSection extends St.BoxLayout {
    static {
        GObject.registerClass({GTypeName: 'MunaMediaSection'}, this);
    }

    constructor() {
        super({vertical: true, style_class: 'muna-section muna-media-section'});

        const top = new St.BoxLayout({style_class: 'muna-media-top'});
        top.add_child(new St.Bin({
            style_class: 'muna-media-art',
            y_align: Clutter.ActorAlign.START,
            child: new St.Icon({
                icon_name: 'audio-x-generic-symbolic',
                style_class: 'muna-media-art-icon',
            }),
        }));
        const texts = new St.BoxLayout({
            vertical: true,
            x_expand: true,
            y_align: Clutter.ActorAlign.CENTER,
            style_class: 'muna-media-texts',
        });
        texts.add_child(new St.Label({text: 'Not playing', style_class: 'muna-media-title'}));
        texts.add_child(new St.Label({text: 'Media', style_class: 'muna-media-subtitle'}));
        top.add_child(texts);
        this.add_child(top);

        const controls = new St.BoxLayout({
            style_class: 'muna-media-controls',
            x_align: Clutter.ActorAlign.CENTER,
            y_expand: true,
            y_align: Clutter.ActorAlign.END,
        });
        for (const name of ['media-skip-backward', 'media-playback-start', 'media-skip-forward']) {
            controls.add_child(new St.Icon({
                icon_name: `${name}-symbolic`,
                style_class: 'muna-media-control',
            }));
        }
        this.add_child(controls);
    }
}
