/** Terms & disclaimer shown once after sign-up; shared by app and bench. */

export const TERMS_VERSION = '1.0';

export interface TermsSection {
  title: string;
  body: string;
}

export const TERMS_SECTIONS: TermsSection[] = [
  {
    title: 'What LifeOS is',
    body:
      'LifeOS turns life events into organized plans: tasks, steps, deadlines and helpful links. It is an organizational tool — it does not file anything on your behalf.',
  },
  {
    title: 'Not legal, financial or medical advice',
    body:
      'Task lists, deadlines and links are general guidance and can be incomplete, outdated, or wrong for your jurisdiction. Always verify requirements and deadlines with the relevant authority or a qualified professional. You are responsible for your own filings and decisions.',
  },
  {
    title: 'Your data',
    body:
      'Your plans and profile live on your device. When you create an account, an encrypted-in-transit copy is backed up to our database (Supabase) solely so you can restore it — protected so that only your account can access it. We do not sell your data.',
  },
  {
    title: 'Affiliate links',
    body:
      'Product suggestions link to Amazon. As an Amazon Associate, LifeOS may earn from qualifying purchases at no extra cost to you. Suggestions are optional and never required to use the app.',
  },
  {
    title: 'Beta software',
    body:
      'LifeOS is in beta. Features may change, and despite our best efforts data loss or bugs are possible. The app is provided "as is", without warranties of any kind, to the extent permitted by law.',
  },
  {
    title: 'Your account',
    body:
      'You are responsible for keeping your credentials safe. You can delete your plans in Settings at any time; contact us to delete your account and backups entirely.',
  },
];
