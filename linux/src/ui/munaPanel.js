import Clutter from 'gi://Clutter';
import GLib from 'gi://GLib';
import GObject from 'gi://GObject';
import St from 'gi://St';

import {animDuration} from '../utils/animation.js';
import {BUTTERFLY_ICON, iconFor} from './logo.js';
import {createButton} from './button.js';

/** How much taller (CSS px) a list tab (Clipboard, Alerts) opens than the widgets' row: about four rows. */
const LIST_EXTRA = 96;

export const PanelMode = Object.freeze({MUNA: 'muna', TRAY: 'tray', LOCALSEND: 'localsend', CLIPBOARD: 'clipboard', NOTIFICATIONS: 'notifications', COMMAND: 'command'});
const MODE_ORDER = [PanelMode.MUNA, PanelMode.TRAY, PanelMode.LOCALSEND, PanelMode.CLIPBOARD, PanelMode.NOTIFICATIONS, PanelMode.COMMAND];

const px = (css, scale) => Math.round(css * scale);

/**
 * The expanded capsule's content, in the same container as the collapsed one:
 *
 *   header   [Muna] [Tray]            (page dots / camera dot)              [⚙]
 *   body     the widgets side by side (Muna mode)  |  the file tray (Tray mode)
 *
 * The header sits in the band of the top bar; the body hangs below it. The
 * capsule's width and the widgets' widths come from the layout engine
 * (applyLayout); widgets that do not fit on the screen go on extra pages.
 */
export class MunaPanel extends St.BoxLayout {
    static {
        GObject.registerClass({GTypeName: 'MunaPanel'}, this);
    }

    /** @param {{widgets: MunaWidget[], tray: TrayView, clipboard: ClipboardView, notifications: NotificationsView, onOpenSettings: Function}} params */
    constructor({widgets, tray, localsend, clipboard, notifications, command, onOpenSettings, onModeChanged = () => {}}) {
        super({
            orientation: Clutter.Orientation.VERTICAL,
            style_class: 'muna-panel',
            x_align: Clutter.ActorAlign.CENTER,
            y_align: Clutter.ActorAlign.START,
        });
        this._widgets = widgets;
        this._tray = tray;
        this._localsend = localsend;
        this._clipboard = clipboard;
        this._notifications = notifications;
        this._command = command;
        this._onModeChanged = onModeChanged;
        this._pages = [];
        this._signature = '';
        this._pageIndex = 0;
        this._mode = PanelMode.MUNA;
        this._headerHidden = false;
        this._modeBeforeDrop = null;
        this._opened = false;
        this._shown = new Set();
        this._scale = 1;

        this._buildHeader(onOpenSettings);

        this._body = new St.Widget({
            style_class: 'muna-body',
            layout_manager: new Clutter.BinLayout(),
            clip_to_allocation: true,
            x_expand: true,
        });
        this._munaView = new St.Widget({
            layout_manager: new Clutter.BinLayout(),
            x_expand: true,
            y_expand: true,
        });
        this._tray.opacity = 0;
        this._tray.hide();
        this._clipboard.opacity = 0;
        this._clipboard.hide();
        this._localsend.opacity = 0;
        this._localsend.hide();
        this._body.add_child(this._munaView);
        this._body.add_child(this._tray);
        this._notifications.opacity = 0;
        this._notifications.hide();
        this._command.opacity = 0;
        this._command.hide();
        this._body.add_child(this._localsend);
        this._body.add_child(this._clipboard);
        this._body.add_child(this._notifications);
        this._body.add_child(this._command);
        this.add_child(this._body);
    }

    get mode() {
        return this._mode;
    }

    get pageCount() {
        return this._pages.length;
    }

    get pageIndex() {
        return this._pageIndex;
    }

    get tray() {
        return this._tray;
    }

    get clipboard() {
        return this._clipboard;
    }

    /** Lets go of the tray view (owned by the tray controller) before this panel is destroyed. */
    remove_tray() {
        this._body.remove_child(this._tray);
        this._body.remove_child(this._localsend);
        this._body.remove_child(this._clipboard);
        this._body.remove_child(this._notifications);
        this._body.remove_child(this._command);
    }

    _viewFor(mode) {
        switch (mode) {
        case PanelMode.TRAY:
            return this._tray;
        case PanelMode.LOCALSEND:
            return this._localsend;
        case PanelMode.CLIPBOARD:
            return this._clipboard;
        case PanelMode.NOTIFICATIONS:
            return this._notifications;
        case PanelMode.COMMAND:
            return this._command;
        default:
            return this._munaView;
        }
    }

    // --- layout ---------------------------------------------------------

    /**
     * @param {object} layout     from computeLayout()
     * @param {{scale: number, headerHeight: number}} metrics  UI scale and the
     *   height (real px) of the header band, i.e. of the top bar
     */
    applyLayout(layout, {scale, headerHeight}) {
        this._scale = scale;
        this.set_width(px(layout.widthCss, scale));
        this._header.set_height(headerHeight);
        this._header.style = `padding: 0 ${layout.padding}px;`;
        // the row of cards is `rowHeight` high (the design: 112); the panel's bottom padding comes on top of it
        this._baseBodyHeight = px(layout.rowHeight + Math.round(layout.padding * 0.75), scale);
        this._body.set_height(this._baseBodyHeight);

        const signature = layout.pages.map(page => page.map(w => w.id).join('+')).join('|');
        if (signature !== this._signature) {
            this._signature = signature;
            this._buildPages(layout);
        }

        // The design (7 · Fixed version): every widget in its own card, 8 apart; "Dividers" off: no cards.
        const cards = layout.dividers;
        const half = cards ? 4 : layout.gap / 2;
        this._body.style = this._mode === PanelMode.COMMAND
            ? 'padding: 0;'
            : `padding: 0 ${Math.max(layout.padding - half, 0)}px ${Math.round(layout.padding * 0.75)}px;`;
        this._pages.forEach((page, pageIndex) => {
            layout.pages[pageIndex].forEach((entry, i) => {
                const holder = page.holders[i];
                holder.set_width(px(entry.widthCss + layout.gap, scale));
                holder.style = `padding: 0 ${half}px;`;
                holder.remove_style_class_name('muna-column-separated');
                if (cards)
                    holder.add_style_class_name('muna-widget-holder-card');
                else
                    holder.remove_style_class_name('muna-widget-holder-card');
            });
        });
        this._updateDots();
        this._syncShown();
    }

    /** Modes whose list can be pulled taller (a two-finger swipe down). */
    get growable() {
        return this._mode === PanelMode.CLIPBOARD || this._mode === PanelMode.NOTIFICATIONS || this._mode === PanelMode.COMMAND;
    }

    /** The scrolling lists of the section on screen: [{scroll, list}] (none for the widgets' pages). */
    get scrollTargets() {
        return this._mode === PanelMode.MUNA ? [] : (this._viewFor(this._mode).scrollTargets ?? []);
    }

    /**
     * px the section on screen needs beyond the normal body height (the design: every tab takes the height
     * it needs): LocalSend and the Tray all of it, the lists (Clipboard, Alerts) room for a few more rows.
     */
    contentExtra(width) {
        if (this._mode === PanelMode.MUNA || this._mode === PanelMode.COMMAND || !this._baseBodyHeight)
            return 0;
        const view = this._viewFor(this._mode);
        // the body's own padding (the panel's bottom edge) comes on top of what the view needs
        const node = this._body.get_theme_node();
        const padding = node.get_padding(St.Side.TOP) + node.get_padding(St.Side.BOTTOM);
        const extra = Math.max(0, view.get_preferred_height(width)[1] + padding - this._baseBodyHeight);
        if (this._mode === PanelMode.LOCALSEND || this._mode === PanelMode.TRAY)
            return extra;
        return Math.min(extra, px(LIST_EXTRA, this._scale ?? 1));
    }

    /**
     * The command bar: the panel becomes `width` wide and exactly as tall as the field and its results.
     * @returns {number} the panel's height
     */
    fitCommand(width) {
        this.set_width(width);
        this._body.set_height(Math.ceil(this._command.neededHeight(width)));
        this.queue_relayout();
        return this.getHeightForWidth(width);
    }

    /** Makes the body (and the list in it) `extra` px taller than the widgets' row (0 = back to normal). */
    setExtraHeight(extra) {
        if (this._baseBodyHeight)
            this._body.set_height(this._baseBodyHeight + (this.growable || this._mode === PanelMode.LOCALSEND || this._mode === PanelMode.TRAY ? Math.max(0, extra) : 0));
        // The new height must reach the cached size request of the panel before it is asked for it.
        this.queue_relayout();
    }

    /** Height in px the panel needs at its current width. */
    getHeightForWidth(width) {
        return this.get_preferred_height(width)[1];
    }

    // --- state ----------------------------------------------------------

    /** @param {GLib.DateTime} now */
    tick(now) {
        for (const widget of this._widgets)
            widget.onTick(now);
    }

    /** The capsule finished opening or closing; tells the visible widgets. */
    setOpen(open) {
        this._opened = open;
        this._syncShown();
    }

    /**
     * Tells the widgets of the page on screen that they are shown, and the others that they are not.
     * The panel may be told it is open before its pages exist (the first opening), so this runs
     * again once the layout has built them.
     */
    _syncShown() {
        const want = new Set(this._opened && this._mode === PanelMode.MUNA ? this._pages[this._pageIndex]?.widgets ?? [] : []);
        for (const widget of [...this._shown]) {
            if (!want.has(widget)) {
                this._shown.delete(widget);
                widget.onPageHidden();
            }
        }
        for (const widget of want) {
            if (!this._shown.has(widget)) {
                this._shown.add(widget);
                widget.onPageShown();
            }
        }
    }

    setCameraActive(active) {
        this._cameraDot.visible = active;
    }

    /** Switches between the widgets and the tray. */
    setMode(mode, {animate = true} = {}) {
        if (mode === this._mode)
            return;
        const from = this._viewFor(this._mode);
        const to = this._viewFor(mode);
        const forward = MODE_ORDER.indexOf(mode) > MODE_ORDER.indexOf(this._mode);

        if (this._mode === PanelMode.MUNA)
            this.setOpen(false);
        if (this._mode === PanelMode.CLIPBOARD)
            this._clipboard.stopTyping();
        if (this._mode === PanelMode.COMMAND)
            this._command.stopTyping();
        this._mode = mode;
        // The command bar is the capsule itself turned into a search field: no tabs above it.
        this._header.visible = mode !== PanelMode.COMMAND;
        if (mode === PanelMode.COMMAND) {
            // The field takes the keyboard once the tab is on screen.
            GLib.timeout_add(GLib.PRIORITY_DEFAULT, 220, () => {
                if (this._mode === PanelMode.COMMAND)
                    this._command.focusEntry();
                return GLib.SOURCE_REMOVE;
            });
        }
        if (mode === PanelMode.NOTIFICATIONS)
            this._notifications.refresh();
        if (mode === PanelMode.MUNA)
            this.setOpen(true);
        this._updateTabs();
        this._updateDots();
        this._onModeChanged();

        from.remove_all_transitions();
        to.remove_all_transitions();
        const shift = animate ? px(18, this._scale) * (forward ? 1 : -1) : 0;
        from.ease({
            opacity: 0,
            translation_x: -shift,
            duration: animDuration(animate ? 130 : 0),
            mode: Clutter.AnimationMode.EASE_OUT_QUAD,
            onComplete: () => from.hide(),
        });
        to.set({opacity: 0, translation_x: shift});
        to.show();
        to.ease({
            opacity: 255,
            translation_x: 0,
            duration: animDuration(animate ? 230 : 0),
            delay: animDuration(animate ? 50 : 0),
            mode: Clutter.AnimationMode.EASE_OUT_CUBIC,
        });
    }

    /**
     * Files are being dragged over the capsule: show the tray as the drop
     * target (and go back to what was shown when the drag ends).
     */
    setDrop({active, zone = null, count = 0}) {
        // While dragging only the drop targets are shown: the tabs and settings step aside.
        this._setHeaderHidden(active);
        if (active) {
            if (this._modeBeforeDrop === null)
                this._modeBeforeDrop = this._mode;
            this.setMode(PanelMode.TRAY);
        } else if (this._modeBeforeDrop !== null) {
            const before = this._modeBeforeDrop;
            this._modeBeforeDrop = null;
            // After a drag the capsule shows the tray (or closes); never the widgets by surprise.
            this.setMode(before, {animate: false});
        }
        this._tray.setDrop({active, zone, count});
    }

    _setHeaderHidden(hidden) {
        if (this._headerHidden === hidden)
            return;
        this._headerHidden = hidden;
        this._header.remove_all_transitions();
        this._header.ease({
            opacity: hidden ? 0 : 255,
            duration: animDuration(hidden ? 120 : 180),
            mode: Clutter.AnimationMode.EASE_OUT_QUAD,
        });
    }

    /** Shows what the widget with this id has to offer (a page or the tray). */
    showWidget(id) {
        const section = {tray: PanelMode.TRAY, localsend: PanelMode.LOCALSEND, clipboard: PanelMode.CLIPBOARD, notifications: PanelMode.NOTIFICATIONS, command: PanelMode.COMMAND}[id];
        if (section) {
            this.setMode(section, {animate: false});
            return;
        }
        const index = this._pages.findIndex(page => page.widgets.some(w => w.constructor.id === id));
        if (index < 0)
            return;
        this.setMode(PanelMode.MUNA, {animate: false});
        this.showPage(index, {animate: false});
    }

    nextPage() {
        return this.showPage(this._pageIndex + 1);
    }

    previousPage() {
        return this.showPage(this._pageIndex - 1);
    }

    /** @returns {boolean} whether the page changed */
    showPage(index, {animate = true} = {}) {
        if (index < 0 || index >= this._pages.length || index === this._pageIndex)
            return false;

        const from = this._pages[this._pageIndex];
        const to = this._pages[index];
        const direction = index > this._pageIndex ? 1 : -1;
        this._pageIndex = index;

        this._syncShown();
        this._updateDots();

        const shift = px(26, this._scale) * direction * (animate ? 1 : 0);
        from.actor.remove_all_transitions();
        to.actor.remove_all_transitions();
        from.actor.ease({
            opacity: 0,
            translation_x: -shift,
            duration: animDuration(140),
            mode: Clutter.AnimationMode.EASE_OUT_QUAD,
            onComplete: () => from.actor.hide(),
        });
        to.actor.set({opacity: 0, translation_x: shift});
        to.actor.show();
        to.actor.ease({
            opacity: 255,
            translation_x: 0,
            duration: animDuration(220),
            delay: animDuration(60),
            mode: Clutter.AnimationMode.EASE_OUT_CUBIC,
        });
        return true;
    }

    // --- opening / closing animation --------------------------------------

    /** The capsule is growing: the header and then the widgets appear, one after the other. */
    reveal() {
        const targets = this._contentTargets();
        this._header.remove_all_transitions();
        this._header.set({opacity: 0});
        if (!this._headerHidden) {
            this._header.ease({
                opacity: 255,
                duration: animDuration(200),
                delay: animDuration(60),
                mode: Clutter.AnimationMode.EASE_OUT_QUAD,
            });
        }
        targets.forEach((actor, i) => {
            actor.remove_all_transitions();
            actor.set({opacity: 0, translation_y: px(10, this._scale)});
            actor.ease({
                opacity: 255,
                translation_y: 0,
                duration: animDuration(260),
                delay: animDuration(110 + i * 55),
                mode: Clutter.AnimationMode.EASE_OUT_CUBIC,
            });
        });
    }

    /** The capsule is about to shrink: the content fades first. */
    conceal() {
        for (const actor of [this._header, ...this._contentTargets()]) {
            actor.remove_all_transitions();
            actor.ease({
                opacity: 0,
                duration: animDuration(90),
                mode: Clutter.AnimationMode.EASE_OUT_QUAD,
            });
        }
    }

    _contentTargets() {
        if (this._mode !== PanelMode.MUNA)
            return [this._viewFor(this._mode)];
        return this._pages[this._pageIndex]?.holders ?? [];
    }

    // --- building ---------------------------------------------------------

    _buildHeader(onOpenSettings) {
        this._header = new St.Widget({
            style_class: 'muna-header',
            layout_manager: new Clutter.BinLayout(),
            x_expand: true,
        });

        this._tabs = new St.BoxLayout({
            style_class: 'muna-tabs',
            x_expand: true,
            y_expand: true,
            x_align: Clutter.ActorAlign.START,
            y_align: Clutter.ActorAlign.CENTER,
        });
        this._tabButtons = new Map();
        for (const [mode, label, icon] of [
            [PanelMode.MUNA, 'Muna', BUTTERFLY_ICON],
            [PanelMode.TRAY, 'Tray', 'muna-tray-symbolic'],
            [PanelMode.LOCALSEND, 'LocalSend', 'network-wireless-symbolic'],
            [PanelMode.CLIPBOARD, 'Clipboard', 'edit-paste-symbolic'],
            [PanelMode.NOTIFICATIONS, 'Alerts', 'preferences-system-notifications-symbolic'],
        ]) {
            const tab = createButton({
                label,
                ...(icon.startsWith('muna-') ? {gicon: iconFor(icon)} : {iconName: icon}),
                styleClass: mode === PanelMode.MUNA ? 'muna-tab muna-tab-muna' : 'muna-tab',
                onClick: () => this.setMode(mode),
            });
            this._tabButtons.set(mode, tab);
            this._tabs.add_child(tab);
        }
        this._header.add_child(this._tabs);

        this._status = new St.BoxLayout({
            style_class: 'muna-header-status',
            x_expand: true,
            y_expand: true,
            x_align: Clutter.ActorAlign.CENTER,
            y_align: Clutter.ActorAlign.CENTER,
        });
        this._dots = new St.BoxLayout({style_class: 'muna-dots', y_align: Clutter.ActorAlign.CENTER});
        this._cameraDot = new St.Widget({
            style_class: 'muna-camera-dot',
            y_align: Clutter.ActorAlign.CENTER,
            visible: false,
        });
        this._status.add_child(this._dots);
        this._status.add_child(this._cameraDot);
        this._header.add_child(this._status);

        const settings = createButton({
            iconName: 'emblem-system-symbolic',
            styleClass: 'muna-gear',
            onClick: () => onOpenSettings(),
        });
        settings.set({
            x_expand: true,
            y_expand: true,
            x_align: Clutter.ActorAlign.END,
            y_align: Clutter.ActorAlign.CENTER,
        });
        this._header.add_child(settings);
        this.add_child(this._header);
        this._updateTabs();
    }

    _buildPages(layout) {
        // Keep the widgets' views alive while the pages are rebuilt.
        for (const page of this._pages) {
            page.holders.forEach(holder => holder.set_child(null));
            page.actor.destroy();
        }
        this._pages = [];
        this._munaView.destroy_all_children();

        const byId = new Map(this._widgets.map(widget => [widget.constructor.id, widget]));
        layout.pages.forEach(entries => {
            const actor = new St.BoxLayout({
                style_class: 'muna-page',
                x_expand: true,
                y_expand: true,
                x_align: Clutter.ActorAlign.CENTER,
                opacity: 0,
                visible: false,
            });
            const widgets = [];
            const holders = [];
            for (const entry of entries) {
                const widget = byId.get(entry.id);
                if (!widget)
                    continue;
                const holder = new St.Bin({
                    style_class: 'muna-column',
                    y_expand: true,
                    x_align: Clutter.ActorAlign.FILL,
                    y_align: Clutter.ActorAlign.FILL,
                    child: widget.view,
                });
                actor.add_child(holder);
                widgets.push(widget);
                holders.push(holder);
            }
            this._munaView.add_child(actor);
            this._pages.push({actor, widgets, holders});
        });

        this._pageIndex = Math.min(this._pageIndex, this._pages.length - 1);
        const current = this._pages[this._pageIndex];
        if (current) {
            current.actor.opacity = 255;
            current.actor.show();
        }
    }

    _updateTabs() {
        for (const [mode, tab] of this._tabButtons) {
            if (mode === this._mode)
                tab.add_style_pseudo_class('active');
            else
                tab.remove_style_pseudo_class('active');
        }
    }

    _updateDots() {
        this._dots.destroy_all_children();
        this._dots.visible = this._pages.length > 1 && this._mode === PanelMode.MUNA;
        this._pages.forEach((_page, index) => {
            this._dots.add_child(new St.Widget({
                style_class: `muna-dot${index === this._pageIndex ? ' muna-dot-active' : ''}`,
            }));
        });
    }
}
