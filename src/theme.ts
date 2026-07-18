import { Domain, Priority } from './core/types';

export const colors = {
  background: '#F7F7F5',
  card: '#FFFFFF',
  text: '#1A1A1A',
  textSecondary: '#6B6B6B',
  border: '#E6E4E0',
  accent: '#2F6FED',
  accentSoft: '#E8F0FE',
  danger: '#C62828',
  dangerSoft: '#FDECEA',
  success: '#2E7D32',
  successSoft: '#E8F5E9',
  warning: '#B26A00',
  warningSoft: '#FFF3E0',
};

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
};

export const priorityLabels: Record<Priority, string> = {
  critical: 'Critical',
  high: 'High',
  medium: 'Medium',
  low: 'Low',
};

export const priorityColors: Record<Priority, string> = {
  critical: colors.danger,
  high: colors.warning,
  medium: colors.accent,
  low: colors.textSecondary,
};

export const spacing = { xs: 4, sm: 8, md: 16, lg: 24, xl: 32 };
