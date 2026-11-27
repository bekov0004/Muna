import Clutter from 'gi://Clutter';
import GLib from 'gi://GLib';
import St from 'gi://St';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';

import {createButton} from './button.js';
import {BUTTERFLY_ICON, iconFor, Logo} from './logo.js';
import {menuCard, menuHeader} from './menuKit.js';

const ROLE = 'muna-tools';
const MENU_WIDTH = 420;

/**
 * The button in the top bar and the window it opens: a row of icon tabs, and under it the page of
 * the chosen tab. The pages are the utility widgets (Windows, Quick Toggles, Focus, System, Sound,
 * Input, Downloads, AI Agents), so every function has room instead of being squeezed into the capsule.
 */
export class ToolsMenu {
    /**
     * @param {MunaWidget[]} widgets the pages, in order (already created with a context)
     * @param {{openSettings: Function}} options
     */
    constructor(widgets, {openSettings, baseIcon = BUTTERFLY_ICON}) {
        this._baseIcon = baseIcon;
        this._lookIcon = null;
        this._widgets = widgets;
        this._openSettings = openSettings;
        this._current = -1;
        this._tabs = [];
        this._pages = [];
        this._button = null;
    }

    get menu() {
        return this._button?.menu ?? null;
    }

    close() {
        this._button?.menu.close();
    }

    /** The icon the button has when nothing special is going on. */
    setBaseIcon(name) {
        this._baseIcon = name;
        this.setLook(this._lookIcon, this._lookColor);
    }

    /** Writes short readings next to the icon ([] removes them): [{label, value}]. */
    /** The top-bar item of the button (the readings are placed after it). */
    get button() {
        return this._button;
    }

    /** Opens the window on the page of the widget with this id. */
    openOn(id) {
        this.openPage(id);
        this._button?.menu.open();
    }

    /** While the computer is kept awake the icon of the button changes (icon null: back to normal). */
    setLook(icon, color) {
        this._lookIcon = icon;
        this._lookColor = color;
        if (!this._icon)
            return;
        this._icon.gicon = iconFor(icon ?? this._baseIcon);
        this._icon.style = icon && color ? `color: ${color};` : '';
    }

    enable() {
        this._button = new PanelMenu.Button(0.5, 'Muna', false);
        this._icon = new St.Icon({gicon: iconFor(this._baseIcon), style_class: 'system-status-icon'});
        this._button.add_child(this._icon);
        this._button.menu.actor.add_style_class_name('muna-menu');

        const item = new PopupMenu.PopupBaseMenuItem({reactive: false, can_focus: false, activate: false});
        item.add_style_class_name('muna-menu-item');
        const root = new St.BoxLayout({orientation: Clutter.Orientation.VERTICAL, style_class: 'muna-menu-root', width: MENU_WIDTH});
        item.add_child(root);
        this._button.menu.addMenuItem(item);

        const logo = new St.BoxLayout({style_class: 'muna-menu-logo', x_expand: true});
        const mark = new Logo();
        mark.x_expand = true;
        logo.add_child(mark);
        root.add_child(logo);

        // The tabs as in the design (7 · Fixed version): a grid of five columns, each an icon over its short
        // name; the chosen one is the violet fill.
        const tabsFrame = new St.Bin({style_class: 'muna-menu-tabs', x_expand: true});
        const grid = new Clutter.GridLayout({column_homogeneous: true, column_spacing: 4, row_spacing: 4});
        const tabs = new St.Widget({layout_manager: grid, x_expand: true});
        const SHORT = {'Keep awake': 'Awake', 'Quick toggles': 'Toggles', 'AI agents': 'Agents', 'Volume mixer': 'Sound'};
        this._widgets.forEach((widget, index) => {
            const title = widget.constructor.title ?? '';
            const tab = new St.Button({style_class: 'muna-button muna-menu-tab', can_focus: true, reactive: true, track_hover: true,
                button_mask: St.ButtonMask.PRIMARY ?? St.ButtonMask.ONE, x_expand: true});
            const box = new St.BoxLayout({orientation: Clutter.Orientation.VERTICAL, style_class: 'muna-menu-tab-box',
                x_align: Clutter.ActorAlign.CENTER, y_align: Clutter.ActorAlign.CENTER});
            box.add_child(new St.Icon({icon_name: widget.constructor.iconName, style_class: 'muna-menu-tab-icon', x_align: Clutter.ActorAlign.CENTER}));
            box.add_child(new St.Label({text: SHORT[title] ?? title, style_class: 'muna-menu-tab-label', x_align: Clutter.ActorAlign.CENTER}));
            tab.set_child(box);
            tab.connect('clicked', () => this._select(index));
            tab.accessible_name = title;
            grid.attach(tab, index % 5, Math.floor(index / 5), 1, 1);
            this._tabs.push(tab);
        });
        tabsFrame.set_child(tabs);
        root.add_child(tabsFrame);

        const titleRow = new St.BoxLayout({x_expand: true, style_class: 'muna-menu-titlerow'});
        this._title = new St.Label({style_class: 'muna-menu-title', x_expand: true, y_align: Clutter.ActorAlign.CENTER});
        titleRow.add_child(this._title);
        this._customize = createButton({iconName: 'emblem-system-symbolic', styleClass: 'muna-menu-customize', onClick: () => this._setCustomizing(true)});
        this._customize.accessible_name = 'Customize';
        this._reset = createButton({iconName: 'edit-undo-symbolic', styleClass: 'muna-menu-reset', onClick: () => this._widgets[this._current]?.resetLayout?.()});
        this._ok = createButton({iconName: 'object-select-symbolic', label: 'OK', styleClass: 'muna-menu-ok', onClick: () => this._setCustomizing(false)});
        [this._customize, this._reset, this._ok].forEach(b => titleRow.add_child(b));
        this._reset.hide();
        this._ok.hide();
        root.add_child(titleRow);

        // The pages: only the chosen one is shown; a tall one scrolls.
        this._scroll = new St.ScrollView({
            style_class: 'muna-menu-scroll',
            hscrollbar_policy: St.PolicyType.NEVER,
            vscrollbar_policy: St.PolicyType.AUTOMATIC,
            overlay_scrollbars: true,
        });
        const pages = new St.BoxLayout({orientation: Clutter.Orientation.VERTICAL, x_expand: true, y_expand: false, y_align: Clutter.ActorAlign.START});
        this._scroll.set_child(pages);
        root.add_child(this._scroll);
        // A widget laid out with the menu kit is a page as it is; any other is put in a card under its title.
        this._pages = this._widgets.map(widget => {
            let page = widget.view;
            if (!widget.constructor.menuNative) {
                page = new St.BoxLayout({orientation: Clutter.Orientation.VERTICAL, style_class: 'muna-menu-page', x_expand: true});
                page.add_child(menuHeader(widget.constructor.title));
                const card = menuCard();
                card.add_style_class_name('muna-card-wrap');
                card.add_child(widget.view);
                page.add_child(card);
            }
            page.y_expand = false;
            page.y_align = Clutter.ActorAlign.START;
            page.hide();
            pages.add_child(page);
            return page;
        });

        if (this._widgets.length === 0) {
            root.add_child(new St.Label({
                text: 'No tools are turned on.\nOpen Settings → Features and switch some on.',
                style_class: 'muna-menu-title',
            }));
        }

        const footer = new St.BoxLayout({style_class: 'muna-menu-footer', x_expand: true});
        footer.add_child(createButton({
            iconName: 'emblem-system-symbolic', label: 'Settings', styleClass: 'muna-menu-action', expand: true,
            onClick: () => {
                this.close();
                this._openSettings();
            },
        }));
        root.add_child(footer);

        this._button.menu.connect('open-state-changed', (_menu, open) => this._onOpenChanged(open));
        if (this._widgets.length > 0)
            this._select(0);
        Main.panel.addToStatusArea(ROLE, this._button, 0, 'right');
    }

    _syncTabArrows() {
        const adjustment = this._tabsScroll?.hadjustment;
        if (!adjustment || !this._tabsLeft)
            return;
        const room = adjustment.upper - adjustment.page_size;
        this._tabsLeft.visible = room > 1 && adjustment.value > 1;
        this._tabsRight.visible = room > 1 && adjustment.value < room - 1;
    }

    /** An arrow pressed: most of a row's width that way. */
    _pageTabs(way) {
        const adjustment = this._tabsScroll.hadjustment;
        const target = adjustment.value + way * adjustment.page_size * 0.7;
        adjustment.ease(Math.max(adjustment.lower, Math.min(target, adjustment.upper - adjustment.page_size)), {duration: 200, mode: Clutter.AnimationMode.EASE_OUT_QUAD});
    }

    /** The wheel (up and down too) and the touchpad move the tab row sideways. */
    _scrollTabs(event) {
        const adjustment = this._tabsScroll.hadjustment;
        if (adjustment.upper - adjustment.page_size <= 0)
            return Clutter.EVENT_PROPAGATE;
        let delta = 0;
        switch (event.get_scroll_direction()) {
        case Clutter.ScrollDirection.UP:
        case Clutter.ScrollDirection.LEFT:
            delta = -60;
            break;
        case Clutter.ScrollDirection.DOWN:
        case Clutter.ScrollDirection.RIGHT:
            delta = 60;
            break;
        case Clutter.ScrollDirection.SMOOTH: {
            const [dx, dy] = event.get_scroll_delta();
            delta = (Math.abs(dx) > Math.abs(dy) ? dx : dy) * 30;
            break;
        }
        default:
            return Clutter.EVENT_PROPAGATE;
        }
        adjustment.value = Math.max(adjustment.lower, Math.min(adjustment.value + delta, adjustment.upper - adjustment.page_size));
        return Clutter.EVENT_STOP;
    }

    /** The chosen tab in view (half a tab of the next one showing, so it is plain there is more). */
    _showTab(index) {
        const tab = this._tabs[index];
        const adjustment = this._tabsScroll?.hadjustment;
        if (!tab || !adjustment || !tab.get_stage())
            return;
        const box = tab.get_allocation_box();
        const margin = tab.width * 0.6;
        if (box.x1 - margin < adjustment.value)
            adjustment.ease(Math.max(adjustment.lower, box.x1 - margin), {duration: 180, mode: Clutter.AnimationMode.EASE_OUT_QUAD});
        else if (box.x2 + margin > adjustment.value + adjustment.page_size)
            adjustment.ease(Math.min(adjustment.upper - adjustment.page_size, box.x2 + margin - adjustment.page_size), {duration: 180, mode: Clutter.AnimationMode.EASE_OUT_QUAD});
    }

    /** The customize mode of a page: its rows get handles and eyes. */
    _setCustomizing(on) {
        const widget = this._widgets[this._current];
        widget?.setCustomizing?.(on);
        this._customizing = on;
        this._customize.visible = !on && !!widget?.customizable;
        this._reset.visible = this._ok.visible = on;
    }

    /** Shows the page of the widget with this id, when it is one of the tabs. @returns {boolean} */
    openPage(id) {
        const index = this._widgets.findIndex(w => w.constructor.id === id);
        if (index < 0)
            return false;
        this._select(index);
        return true;
    }

    _onOpenChanged(open) {
        if (open) {
            GLib.idle_add(GLib.PRIORITY_DEFAULT_IDLE, () => {
                this._showTab(this._current);
                return GLib.SOURCE_REMOVE;
            });
        }
        const widget = this._widgets[this._current];
        if (open)
            widget?.onPageShown();
        else
            widget?.onPageHidden();
    }

    _select(index) {
        if (index === this._current || index < 0 || index >= this._widgets.length)
            return;
        const open = this._button.menu.isOpen;
        if (open)
            this._widgets[this._current]?.onPageHidden();
        if (this._customizing)
            this._setCustomizing(false);
        this._pages[this._current]?.hide();
        this._current = index;
        const widget = this._widgets[index];
        this._pages[index].show();
        this._title.text = widget.constructor.title.toUpperCase();
        this._tabs.forEach((tab, i) => {
            if (i === index)
                tab.add_style_pseudo_class('checked');
            else
                tab.remove_style_pseudo_class('checked');
        });
        this._customize.visible = !!widget.customizable;
        this._scroll.vadjustment.value = 0;
        this._showTab(index);
        if (open)
            widget.onPageShown();
    }

    destroy() {
        if (this._button?.menu.isOpen)
            this._widgets[this._current]?.onPageHidden();
        this._button?.destroy();
        this._button = null;
        this._tabs = [];
        this._pages = [];
        // The pages are destroyed by whoever created them.
    }
}
