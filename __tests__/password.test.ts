import { isValidEmail, validatePassword } from '../src/core/password';

describe('password policy: 8+ chars, letters + numbers + one special', () => {
  test('valid passwords pass', () => {
    expect(validatePassword('Passw0rd!').ok).toBe(true);
    expect(validatePassword('a1!aaaaa').ok).toBe(true);
    expect(validatePassword('LifeOS-2026').ok).toBe(true);
    expect(validatePassword('x9#x9#x9#x9#').ok).toBe(true);
  });

  test('too short fails', () => {
    const check = validatePassword('a1!x');
    expect(check.ok).toBe(false);
    expect(check.problems.join(' ')).toContain('8 characters');
  });

  test('missing number fails', () => {
    const check = validatePassword('Password!');
    expect(check.ok).toBe(false);
    expect(check.problems.join(' ')).toContain('number');
  });

  test('missing letter fails', () => {
    const check = validatePassword('12345678!');
    expect(check.ok).toBe(false);
    expect(check.problems.join(' ')).toContain('letter');
  });

  test('missing special character fails', () => {
    const check = validatePassword('Password1');
    expect(check.ok).toBe(false);
    expect(check.problems.join(' ')).toContain('special');
  });

  test('all problems reported at once', () => {
    expect(validatePassword('').problems).toHaveLength(4);
  });

  test('email sanity check', () => {
    expect(isValidEmail('jaivikpatel6@gmail.com')).toBe(true);
    expect(isValidEmail('not-an-email')).toBe(false);
    expect(isValidEmail('a@b')).toBe(false);
    expect(isValidEmail(' user@site.io ')).toBe(true);
  });
});
