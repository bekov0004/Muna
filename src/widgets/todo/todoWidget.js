import Clutter from 'gi://Clutter';
import St from 'gi://St';

import {MunaWidget} from '../widget.js';
import {TodoItem} from './todoItem.js';

/** A simple local task list: add, check off, remove, clear the done ones. */
export class TodoWidget extends MunaWidget {
    static id = 'todo';
    static title = 'To-do';
    static iconName = 'checkbox-checked-symbolic';

    constructor(context) {
        super(context);
        this._todo = context.services.todo;
        this._ui = context.ui;
        this._typing = false;
    }

    createView() {
        const root = new St.BoxLayout({
            orientation: Clutter.Orientation.VERTICAL,
            style_class: 'muna-widget muna-todo',
            x_expand: true,
            y_expand: true,
        });

        const header = new St.BoxLayout({style_class: 'muna-todo-header'});
        this._caption = new St.Label({
            style_class: 'muna-todo-caption',
            x_expand: true,
            y_align: Clutter.ActorAlign.CENTER,
        });
        header.add_child(this._caption);
        this._clear = new St.Button({
            label: 'Clear done',
            style_class: 'muna-todo-clear',
            can_focus: true,
        });
        this._clear.connect('clicked', () => this._todo.clearDone());
        header.add_child(this._clear);
        root.add_child(header);

        this._empty = new St.Label({
            text: 'Nothing to do',
            style_class: 'muna-todo-empty',
            x_expand: true,
            y_expand: true,
            x_align: Clutter.ActorAlign.CENTER,
            y_align: Clutter.ActorAlign.CENTER,
        });
        root.add_child(this._empty);

        this._scroll = new St.ScrollView({
            style_class: 'muna-todo-scroll',
            x_expand: true,
            y_expand: true,
            overlay_scrollbars: true,
            hscrollbar_policy: St.PolicyType.NEVER,
            vscrollbar_policy: St.PolicyType.AUTOMATIC,
        });
        this._list = new St.BoxLayout({orientation: Clutter.Orientation.VERTICAL, style_class: 'muna-todo-list', x_expand: true});
        this._scroll.add_child(this._list);
        root.add_child(this._scroll);

        this._entry = new St.Entry({
            hint_text: 'Add a task',
            style_class: 'muna-todo-entry',
            can_focus: true,
            x_expand: true,
        });
        const text = this._entry.clutter_text;
        text.connect('activate', () => {
            if (this._todo.add(this._entry.text))
                this._entry.text = '';
        });
        text.connect('key-press-event', (_actor, event) => {
            if (event.get_key_symbol() === Clutter.KEY_Escape) {
                this._stopTyping();
                return Clutter.EVENT_STOP;
            }
            return Clutter.EVENT_PROPAGATE;
        });
        // Focusing the entry (a click or Tab) starts keyboard input.
        text.connect('key-focus-in', () => this._startTyping());
        root.add_child(this._entry);

        this._todo.connectObject('changed', () => this._rebuild(), this);
        return root;
    }

    onViewCreated() {
        this._rebuild();
    }

    onPageHidden() {
        this._stopTyping();
    }

    destroy() {
        this._todo.disconnectObject(this);
        this._stopTyping();
        super.destroy();
    }

    _startTyping() {
        if (this._typing)
            return;
        this._typing = true;
        // Keyboard input needs a grab; the capsule keeps it until Esc / a click elsewhere.
        this._ui.beginTextInput(() => this._stopTyping(true));
        this._entry.grab_key_focus();
    }

    _stopTyping(fromHost = false) {
        if (!this._typing)
            return;
        this._typing = false;
        if (!fromHost)
            this._ui.endTextInput();
    }

    _rebuild() {
        if (!this._view)
            return;
        const items = this._todo.items;
        const left = this._todo.remaining;
        this._caption.text = items.length === 0 ? 'TO-DO' : `TO-DO · ${left} left`;
        this._clear.visible = this._todo.hasDone;
        this._empty.visible = items.length === 0;
        this._scroll.visible = items.length > 0;

        this._list.destroy_all_children();
        for (const item of items) {
            this._list.add_child(new TodoItem({
                item,
                onToggle: id => this._todo.toggle(id),
                onRemove: id => this._todo.remove(id),
            }));
        }
    }
}
