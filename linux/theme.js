/**
 * The colours of Muna's windows (the settings, the agents window ...): black with dark grey blocks and a quiet blue
 * accent in the dark scheme, the capsule's own colours; a light one too. Both follow Settings → General → Appearance.
 */
export const SETTINGS_THEME = {
    light: {
        BACKGROUND: '#f2f2f4',
        TOOLBAR: '#e4e4e9',
        SURFACE: '#ffffff',
        CARD: '#f7f7f9',
        CONTROL: 'rgba(0, 0, 0, 0.07)',
        BORDER: 'rgba(0, 0, 0, 0.09)',
        HOVER: 'rgba(0, 0, 0, 0.05)',
        SELECTED: 'rgba(0, 0, 0, 0.09)',
        TEXT: 'rgba(0, 0, 0, 0.86)',
        TEXT_SECONDARY: 'rgba(0, 0, 0, 0.5)',
        TEXT_DISABLED: 'rgba(0, 0, 0, 0.26)',
        ACCENT: '#007aff',
        ACCENT_SOFT: 'rgba(0, 122, 255, 0.14)',
        CAPSULE: '#0c0c10',
        CAPSULE_BLOCK: '#232327',
        TRACK: 'rgba(0, 0, 0, 0.16)',
    },
    // the colours of the capsule itself: black, with dark grey blocks on it
    dark: {
        BACKGROUND: '#000000',
        TOOLBAR: '#0f0f11',
        SURFACE: '#151517',
        CARD: '#1d1d20',
        CONTROL: '#29292c',
        BORDER: 'rgba(255, 255, 255, 0.09)',
        HOVER: 'rgba(255, 255, 255, 0.07)',
        SELECTED: 'rgba(255, 255, 255, 0.12)',
        TEXT: '#f5f5f7',
        TEXT_SECONDARY: '#98989d',
        TEXT_DISABLED: 'rgba(255, 255, 255, 0.28)',
        ACCENT: '#1283ff',
        ACCENT_SOFT: 'rgba(18, 131, 255, 0.2)',
        CAPSULE: '#050507',
        CAPSULE_BLOCK: '#1d1d21',
        TRACK: '#3a3a3d',
    },
};

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
