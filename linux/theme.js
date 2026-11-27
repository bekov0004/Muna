/**
 * The colours of Muna's windows (the settings, the agents window ...): indigo glass in the dark scheme, cool
 * lilac whites in the light one, a violet accent. Both follow Settings → General → Appearance.
 */
export const SETTINGS_THEME = {
    // the design's "7 · Fixed version": cool lilac whites and a violet accent
    light: {
        BACKGROUND: '#f3f4fd',
        TOOLBAR: '#e9ebfb',
        SURFACE: '#ffffff',
        CARD: '#ffffff',
        CONTROL: '#e2e4f8',
        BORDER: 'rgba(48, 50, 120, 0.12)',
        HOVER: 'rgba(90, 75, 220, 0.07)',
        SELECTED: 'rgba(90, 75, 220, 0.13)',
        TEXT: '#191a36',
        TEXT_SECONDARY: '#51537a',
        TEXT_DISABLED: 'rgba(25, 26, 54, 0.3)',
        ACCENT: '#5a4bdc',
        ACCENT_SOFT: 'rgba(90, 75, 220, 0.13)',
        ACCENT_LINE: 'rgba(90, 75, 220, 0.35)',
        CAPSULE: '#1e2042',
        CAPSULE_BLOCK: '#2b2f62',
        TRACK: '#c5c8e8',
    },
    // indigo glass, like the capsule
    dark: {
        BACKGROUND: '#15173a',
        TOOLBAR: '#191c40',
        SURFACE: '#1f2250',
        CARD: '#1f2250',
        CONTROL: '#2b2f62',
        BORDER: 'rgba(176, 184, 255, 0.16)',
        HOVER: 'rgba(124, 112, 255, 0.12)',
        SELECTED: 'rgba(124, 112, 255, 0.24)',
        TEXT: '#f3f4ff',
        TEXT_SECONDARY: '#aaadd6',
        TEXT_DISABLED: 'rgba(243, 244, 255, 0.3)',
        ACCENT: '#5a4bdc',
        ACCENT_SOFT: 'rgba(124, 112, 255, 0.24)',
        ACCENT_LINE: 'rgba(160, 150, 255, 0.45)',
        CAPSULE: '#1e2042',
        CAPSULE_BLOCK: '#2b2f62',
        TRACK: '#3d4178',
    },
};

/** The coloured tiles behind the icons of the settings' left list (the design), in the list's order. */
export const PAGE_TILES = {
    'General': ['#7c6cff', '#5140c8'], 'Menu bar': ['#2f9bf0', '#1a63c4'], 'Touchpad gestures': ['#12a594', '#0b6f6b'],
    'Fingerprint': ['#e5588f', '#b02b68'], 'Monitor': ['#f08a24', '#c25708'], 'Overview': ['#6b7cff', '#4150c9'],
    'Music and media': ['#e64980', '#a61e6a'], 'System': ['#1c9ed6', '#126aa3'], 'Windows and desktops': ['#8b5cf6', '#5b32c0'],
    'Work': ['#d9820f', '#a85a06'], 'Files and sharing': ['#22a45d', '#14733f'], 'Capsule': ['#a855f7', '#6d28d9'],
    'Command Bar': ['#4c6ef5', '#2f49b8'], 'Quick panel': ['#e8590c', '#b03c02'],
};
/** For the pages the table does not name: the same colours in turn. */
export const TILE_CYCLE = Object.values(PAGE_TILES);

/** The accent of GTK and libadwaita (buttons, switches, selection) in Muna's blue instead of the system's. */
export const accentCss = p => `
:root { --accent-bg-color: ${p.ACCENT}; --accent-color: ${p.ACCENT}; --accent-fg-color: white; }
@define-color accent_bg_color ${p.ACCENT};
@define-color accent_color ${p.ACCENT};
@define-color accent_fg_color white;
`;

/** Light, dark or the system's, as chosen in the settings ('color-scheme'). */
export function schemeOf(settings, Adw) {
    const choice = settings?.get_string('color-scheme') ?? 'system';
    return choice === 'light' ? Adw.ColorScheme.FORCE_LIGHT : choice === 'dark' ? Adw.ColorScheme.FORCE_DARK : Adw.ColorScheme.DEFAULT;
}

/**
 * The palette for Liquid glass: the window's own surfaces become thin tints (the shell draws real glass
 * under Muna's windows), the rest stays.
 */
export function glassPalette(p, dark) {
    // the glass alone: no colour of the window's own; the blocks are only a faint sheen of light
    const sheen = dark ? 'rgba(255, 255, 255, 0.06)' : 'rgba(255, 255, 255, 0.22)';
    return {
        ...p,
        BACKGROUND: 'rgba(0, 0, 0, 0)',
        TOOLBAR: 'rgba(0, 0, 0, 0)',
        SURFACE: sheen,
        CARD: sheen,
        CONTROL: dark ? 'rgba(255, 255, 255, 0.10)' : 'rgba(255, 255, 255, 0.3)',
    };
}

/**
 * Liquid glass inside Muna's windows: every block (the left list, cards, buttons, fields, drop-downs) is a pane
 * of its own (a thin bright rim, a highlight along its top, the slight darkening of glass), so the blocks stay
 * apart on the clear window; the texts get a soft shadow.
 */
export function glassPanesCss(dark) {
    const fill = dark ? 'rgba(0, 0, 0, 0.34)' : 'rgba(255, 255, 255, 0.46)';
    const rim = dark ? 'rgba(255, 255, 255, 0.22)' : 'rgba(255, 255, 255, 0.7)';
    const top = dark ? 'rgba(255, 255, 255, 0.28)' : 'rgba(255, 255, 255, 0.9)';
    const shadow = dark ? 'rgba(0, 0, 0, 0.65)' : 'rgba(255, 255, 255, 0.8)';
    const panes = ['.muna-sidebar', '.s-card', '.s-preset', '.muna-nav', '.muna-pill', '.muna-caps', '.muna-tag',
        '.muna-sidebar searchentry', '.muna-prefs entry', '.muna-prefs spinbutton', '.muna-prefs dropdown > button',
        '.muna-prefs button:not(.flat):not(.muna-try)', '.muna-prefs .s-tile'];
    return `
${panes.join(', ')} {
    background-color: ${fill};
    border: 1px solid ${rim};
    box-shadow: inset 0 1px 0 ${top}, inset 0 -1px 0 rgba(255, 255, 255, 0.06);
}
.muna-sidebar row:selected { background-color: rgba(90, 75, 220, 0.55); box-shadow: inset 0 0 0 1px ${rim}, inset 0 1px 0 ${top}; }
.muna-prefs label, .muna-sidebar label, headerbar label { text-shadow: 0 1px 3px ${shadow}; }
.muna-prefs .dim, .muna-prefs label.dim, .muna-sidebar .caption-heading { color: ${dark ? 'rgba(255, 255, 255, 0.85)' : 'rgba(0, 0, 0, 0.75)'}; }
`;
}
