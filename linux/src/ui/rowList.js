import Clutter from 'gi://Clutter';
import St from 'gi://St';

import {iconRow, listRow, menuDivider, menuRow} from './menuKit.js';

/**
 * The rows of a page that the user can rearrange: in customize mode every row gets a handle to
 * drag it up or down and an eye to hide it; hidden rows show again only in customize mode.
 * Order and hidden rows are kept in the settings as "page:row".
 */
export class RowList {
    /**
     * @param {{page: string, settings: SettingsService, card: St.BoxLayout, items: object[]}} options
     *   items: {id, icon, title, subtitle?, desc?, control?, chevron?, onClick?}
     */
    constructor({page, settings, card, items, grid = 0, note = null}) {
        this._grid = grid;          // > 0: tiles in that many columns (the design's quick toggles)
        this._note = note;          // a label under the tiles that says what the one under the pointer does
        this._page = page;
        this._settings = settings;
        this._card = card;
        this._items = items;
        this._customizing = false;
        this._rows = new Map();
        this.render();
    }

    get items() {
        return this._items;
    }

    _key(item) {
        return `${this._page}:${item.id}`;
    }

    get _hidden() {
        return new Set(this._settings?.get('menu-hidden') ?? []);
    }

    _ordered() {
        const order = this._settings?.get('menu-order') ?? [];
        const rank = item => {
            const at = order.indexOf(this._key(item));
            return at < 0 ? 10000 + this._items.indexOf(item) : at;
        };
        return [...this._items].sort((a, b) => rank(a) - rank(b));
    }

    setCustomizing(on) {
        this._customizing = on;
        this.render();
    }

    reset() {
        const prefix = `${this._page}:`;
        const gs = this._settings?.gsettings;
        gs?.set_strv('menu-hidden', (this._settings.get('menu-hidden') ?? []).filter(k => !k.startsWith(prefix)));
        gs?.set_strv('menu-order', (this._settings.get('menu-order') ?? []).filter(k => !k.startsWith(prefix)));
        this.render();
    }

    render() {
        this._card.destroy_all_children();
        this._rows.clear();
        if (this._grid > 0 && !this._customizing) {
            this._renderGrid();
            return;
        }
        const hidden = this._hidden;
        let first = true;
        for (const item of this._ordered()) {
            const isHidden = hidden.has(this._key(item));
            if (isHidden && !this._customizing)
                continue;
            // the design's list rows stand apart on their own; the older rows have lines between them
            if (!first && !item.color && !item.plain)
                this._card.add_child(menuDivider());
            first = false;
            const entry = this._build(item, isHidden);
            this._card.add_child(entry);
            this._rows.set(item.id, entry);
        }
    }

    /** The tiles: an icon in a small square over the name; a switch that is on is violet. */
    _renderGrid() {
        const layout = new Clutter.GridLayout({column_homogeneous: true, column_spacing: 6, row_spacing: 6});
        const grid = new St.Widget({layout_manager: layout, x_expand: true});
        const hidden = this._hidden;
        let index = 0;
        for (const item of this._ordered()) {
            if (hidden.has(this._key(item)))
                continue;
            const tile = new St.Button({style_class: 'muna-qtile', can_focus: true, reactive: true, track_hover: true, x_expand: true});
            const box = new St.BoxLayout({orientation: Clutter.Orientation.VERTICAL, style_class: 'muna-qtile-box', x_expand: true});
            const square = new St.Bin({style_class: 'muna-qtile-square', x_align: Clutter.ActorAlign.CENTER});
            square.set_child(new St.Icon({icon_name: item.icon, style_class: 'muna-qtile-icon'}));
            box.add_child(square);
            const label = new St.Label({text: item.title, style_class: 'muna-qtile-label', x_align: Clutter.ActorAlign.CENTER});
            label.clutter_text.line_wrap = true;
            label.clutter_text.ellipsize = 0;   // Pango.EllipsizeMode.NONE: two lines rather than "…"
            box.add_child(label);
            tile.set_child(box);
            tile.connect('clicked', () => {
                item.onClick?.();
                this.syncTiles();
            });
            tile.connect('notify::hover', () => {
                if (this._note)
                    this._note.text = tile.hover ? item.desc ?? '' : this._noteDefault ?? '';
            });
            tile._munaItem = item;
            layout.attach(tile, index % this._grid, Math.floor(index / this._grid), 1, 1);
            this._rows.set(item.id, tile);
            index++;
        }
        this._card.add_child(grid);
        this.syncTiles();
    }

    /** A tile of a switch that is on shows violet. */
    syncTiles() {
        for (const tile of this._rows.values()) {
            const getter = tile._munaItem?.getter;
            if (!getter)
                continue;
            if (getter())
                tile.add_style_pseudo_class('checked');
            else
                tile.remove_style_pseudo_class('checked');
        }
    }

    _build(item, isHidden) {
        const subtitle = this._customizing ? (item.desc ?? item.subtitle ?? '') : (item.subtitle ?? '');
        // a plain row (the design's switch lines): the name, its pills under it, the switch
        if (!this._customizing && item.plain) {
            const {row} = menuRow({title: item.title, subtitle: item.subtitle ?? '', control: item.control?.() ?? null, onClick: item.onClick});
            const extra = item.extra?.();
            if (!extra)
                return row;
            const box = new St.BoxLayout({orientation: Clutter.Orientation.VERTICAL, style_class: 'muna-qcard-list', x_expand: true});
            box.add_child(row);
            box.add_child(extra);
            return box;
        }
        if (!this._customizing && item.color) {
            const {row} = listRow({icon: item.icon, color: item.color, title: item.title, subtitle: item.subtitle ?? '',
                control: item.control?.() ?? null, value: item.value ?? (item.control ? '' : '›'), onClick: item.onClick});
            return row;
        }
        if (!this._customizing) {
            const {row} = iconRow({icon: item.icon, title: item.title, subtitle, control: item.control?.() ?? null, chevron: item.chevron ?? (!item.control && !!item.onClick), onClick: item.onClick, extra: item.extra?.() ?? null});
            return row;
        }
        const line = new St.BoxLayout({x_expand: true, style_class: 'muna-custom-line'});
        const handle = new St.Button({style_class: 'muna-custom-handle', reactive: true, track_hover: true,
            child: new St.Icon({icon_name: 'open-menu-symbolic', icon_size: 14})});
        line.add_child(handle);
        const {row} = iconRow({icon: item.icon, title: item.title, subtitle});
        row.x_expand = true;
        row.reactive = false;
        line.add_child(row);
        const eye = new St.Button({style_class: 'muna-custom-eye', reactive: true, track_hover: true, y_align: Clutter.ActorAlign.CENTER,
            child: new St.Icon({icon_name: isHidden ? 'view-conceal-symbolic' : 'view-reveal-symbolic', icon_size: 16})});
        eye.connect('clicked', () => this._toggleHidden(item));
        line.add_child(eye);
        if (isHidden)
            line.opacity = 120;
        this._dragHandle(handle, line, item);
        return line;
    }

    _toggleHidden(item) {
        const hidden = this._hidden;
        const key = this._key(item);
        if (hidden.has(key))
            hidden.delete(key);
        else
            hidden.add(key);
        this._settings?.gsettings?.set_strv('menu-hidden', [...hidden]);
        this.render();
    }

    /** Dragging the handle moves the row past the neighbours the pointer reaches. */
    _dragHandle(handle, line, item) {
        handle.connect('button-press-event', (_a, event) => {
            const stage = global.stage;
            line.opacity = 200;
            const id = stage.connect('captured-event', (_s, e) => {
                const type = e.type();
                if (type === Clutter.EventType.MOTION) {
                    const [, y] = e.get_coords();
                    this._moveTo(item, y);
                    return Clutter.EVENT_STOP;
                }
                if (type === Clutter.EventType.BUTTON_RELEASE) {
                    stage.disconnect(id);
                    line.opacity = 255;
                    this._saveOrder();
                    return Clutter.EVENT_STOP;
                }
                return Clutter.EVENT_PROPAGATE;
            });
            void event;
            return Clutter.EVENT_STOP;
        });
    }

    _moveTo(item, pointerY) {
        const children = this._card.get_children().filter(c => !(c instanceof St.Widget && c.has_style_class_name('muna-card-divider')));
        const entry = this._rows.get(item.id);
        let target = children.length - 1;
        for (let i = 0; i < children.length; i++) {
            const [, top] = children[i].get_transformed_position();
            if (pointerY < top + children[i].height / 2) {
                target = i;
                break;
            }
        }
        const from = children.indexOf(entry);
        if (target === from || target < 0)
            return;
        // Rows and dividers alternate: the row at slot n sits at child index 2n.
        this._card.set_child_at_index(entry, target * 2);
        this._rebuildDividers();
    }

    _rebuildDividers() {
        const rows = this._card.get_children().filter(c => !c.has_style_class_name('muna-card-divider'));
        this._card.get_children().filter(c => c.has_style_class_name('muna-card-divider')).forEach(c => c.destroy());
        rows.forEach((row, i) => {
            if (i > 0)
                this._card.insert_child_below(menuDivider(), row);
        });
    }

    _saveOrder() {
        const rows = this._card.get_children().filter(c => !c.has_style_class_name('muna-card-divider'));
        const idsInOrder = rows.map(row => [...this._rows].find(([, r]) => r === row)?.[0]).filter(Boolean);
        const prefix = `${this._page}:`;
        const others = (this._settings.get('menu-order') ?? []).filter(k => !k.startsWith(prefix));
        this._settings?.gsettings?.set_strv('menu-order', [...others, ...idsInOrder.map(id => `${prefix}${id}`)]);
    }
}
