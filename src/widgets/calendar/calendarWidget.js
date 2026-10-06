import Clutter from 'gi://Clutter';
import St from 'gi://St';

import {MunaWidget} from '../widget.js';
import {CalendarClock} from './clock.js';
import {WeekStrip} from './weekStrip.js';

export class CalendarWidget extends MunaWidget {
    static id = 'calendar';
    static title = 'Calendar';
    static iconName = 'x-office-calendar-symbolic';

    createView() {
        const box = new St.BoxLayout({
            vertical: true,
            style_class: 'muna-widget muna-calendar-widget',
            x_expand: true,
            y_align: Clutter.ActorAlign.START,
        });
        this._clock = new CalendarClock();
        this._week = new WeekStrip();
        box.add_child(this._clock);
        box.add_child(this._week);
        return box;
    }

    onTick(now) {
        this.view; // make sure the view exists
        this._clock.update(now);
        this._week.update(now);
    }
}
