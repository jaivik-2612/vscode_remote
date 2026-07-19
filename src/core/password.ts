/**
 * Password policy: at least 8 characters, must contain letters and numbers,
 * and at least one special (non-alphanumeric) character.
 */

export interface PasswordCheck {
  ok: boolean;
  /** Human-readable requirements not yet met, in display order. */
  problems: string[];
}

export const PASSWORD_RULES = [
  'At least 8 characters',
  'At least one letter',
  'At least one number',
  'At least one special character (!@#$…)',
];

export function validatePassword(password: string): PasswordCheck {
  const problems: string[] = [];
  if (password.length < 8) problems.push(PASSWORD_RULES[0]);
  if (!/[a-zA-Z]/.test(password)) problems.push(PASSWORD_RULES[1]);
  if (!/[0-9]/.test(password)) problems.push(PASSWORD_RULES[2]);
  if (!/[^a-zA-Z0-9]/.test(password)) problems.push(PASSWORD_RULES[3]);
  return { ok: problems.length === 0, problems };
}

export function isValidEmail(email: string): boolean {
  return /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(email.trim());
}
