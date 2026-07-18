import { Domain, Priority } from './core/types';

/**
 * The finalized "Sky" design system: cool ground, floating borderless cards,
 * vivid blue accent, full-round inputs. Light and dark palettes; the active
 * one is provided app-wide by ThemeProvider (src/state/theme.tsx).
 */

export interface Palette {
  bg: string;
  card: string;
  ink: string;
  muted: string;
  line: string;
  accent: string;
  soft: string;
  onAccent: string;
  danger: string;
  dangerSoft: string;
  success: string;
  warning: string;
  gold: string;
}

export const palettes: Record<'light' | 'dark', Palette> = {
  light: {
    bg: '#F3F6FB',
    card: '#FFFFFF',
    ink: '#16233B',
    muted: '#6B7A94',
    line: '#E3E9F2',
    accent: '#3564E2',
    soft: '#E7EEFD',
    onAccent: '#FFFFFF',
    danger: '#C62828',
    dangerSoft: '#FDECEA',
    success: '#2E7D32',
    warning: '#B26A00',
    gold: '#B8860B',
  },
  dark: {
    bg: '#0F1420',
    card: '#1A2130',
    ink: '#E8EDF7',
    muted: '#8B97AC',
    line: '#262F42',
    accent: '#7C9BFF',
    soft: '#24304D',
    onAccent: '#0F1420',
    danger: '#E57373',
    dangerSoft: '#3A2020',
    success: '#6BBF6E',
    warning: '#E0A23F',
    gold: '#E8B84B',
  },
};

/** Sky card treatment: borderless, floating on a soft shadow. */
export const cardShadow = {
  shadowColor: '#16233B',
  shadowOpacity: 0.08,
  shadowRadius: 14,
  shadowOffset: { width: 0, height: 6 },
  elevation: 3,
} as const;

export const domainColors: Record<Domain, string> = {
  government: '#5C6BC0',
  finance: '#00897B',
  insurance: '#8E24AA',
  tax: '#6D4C41',
  employment: '#039BE5',
  utilities: '#F4511E',
  housing: '#7CB342',
  health: '#E53935',
  legal: '#546E7A',
  immigration: '#D81B60',
  business: '#FB8C00',
  education: '#3949AB',
  travel: '#00ACC1',
  social: '#EC407A',
};

export const priorityLabels: Record<Priority, string> = {
  critical: 'Critical',
  high: 'High',
  medium: 'Medium',
  low: 'Low',
};

export function priorityColor(priority: Priority, c: Palette): string {
  switch (priority) {
    case 'critical':
      return c.danger;
    case 'high':
      return c.warning;
    case 'medium':
      return c.accent;
    default:
      return c.muted;
  }
}

export const spacing = { xs: 4, sm: 8, md: 16, lg: 24, xl: 32 };
export const radius = { card: 20, input: 999, chip: 999, small: 12 };
