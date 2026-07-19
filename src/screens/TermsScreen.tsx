import React from 'react';
import { ScrollView, StyleSheet, Text, TouchableOpacity, View } from 'react-native';
import { TERMS_SECTIONS, TERMS_VERSION } from '../core/terms';
import { useAuth } from '../state/auth';
import { useTheme } from '../state/theme';
import { Card } from '../components/ui';
import { spacing } from '../theme';

/** Shown once after sign-up: the user must accept before entering the app. */
export default function TermsScreen() {
  const { acceptTerms, signOut } = useAuth();
  const { colors } = useTheme();

  return (
    <View style={[styles.screen, { backgroundColor: colors.bg }]}>
      <ScrollView style={{ flex: 1 }} contentContainerStyle={{ padding: spacing.md }}>
        <Text style={[styles.title, { color: colors.ink }]}>Terms & Disclaimer</Text>
        <Text style={[styles.version, { color: colors.muted }]}>
          Version {TERMS_VERSION} — please read before using LifeOS.
        </Text>
        {TERMS_SECTIONS.map((section) => (
          <Card key={section.title}>
            <Text style={[styles.sectionTitle, { color: colors.ink }]}>{section.title}</Text>
            <Text style={[styles.body, { color: colors.muted }]}>{section.body}</Text>
          </Card>
        ))}
      </ScrollView>
      <View style={[styles.footer, { backgroundColor: colors.bg, borderTopColor: colors.line }]}>
        <TouchableOpacity
          style={[styles.accept, { backgroundColor: colors.accent }]}
          onPress={acceptTerms}
        >
          <Text style={[styles.acceptText, { color: colors.onAccent }]}>I agree — continue</Text>
        </TouchableOpacity>
        <TouchableOpacity onPress={signOut}>
          <Text style={[styles.decline, { color: colors.muted }]}>Decline and sign out</Text>
        </TouchableOpacity>
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1 },
  title: { fontSize: 26, fontWeight: '800', marginTop: spacing.md },
  version: { fontSize: 12, marginTop: 4, marginBottom: spacing.md },
  sectionTitle: { fontSize: 15, fontWeight: '700', marginBottom: 6 },
  body: { fontSize: 13, lineHeight: 20 },
  footer: { padding: spacing.md, borderTopWidth: StyleSheet.hairlineWidth },
  accept: { borderRadius: 24, padding: spacing.md, alignItems: 'center' },
  acceptText: { fontSize: 16, fontWeight: '700' },
  decline: { fontSize: 13, textAlign: 'center', marginTop: spacing.sm, padding: 4 },
});
