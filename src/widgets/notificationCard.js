import GObject from 'gi://GObject';

import {MunaCard} from './munaCard.js';

/** Card for `notification` events (and the fallback for types without a card of their own). */
export class NotificationCard extends MunaCard {
    static {
        GObject.registerClass({GTypeName: 'MunaNotificationCard'}, this);
    }

    constructor(card) {
        super(card);
        this.add_style_class_name('muna-notification-card');
    }
}
