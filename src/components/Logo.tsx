import React from 'react';
import { StyleSheet, Text, View } from 'react-native';
import Svg, { Circle, Path } from 'react-native-svg';
import { useTheme } from '../state/theme';

/**
 * The LifeOS mark: a nearly-complete progress ring with a dot at the gap
 * (life in progress) around a checkmark (handled). One color, scales from
 * tab-bar size to app icon.
 */
export function LogoMark({ size = 64, color }: { size?: number; color?: string }) {
  const { colors } = useTheme();
  const c = color ?? colors.accent;
  return (
    <Svg width={size} height={size} viewBox="0 0 64 64" fill="none">
      <Path
        d="M48.97 15.03 A24 24 0 1 1 15.03 15.03"
        stroke={c}
        strokeWidth={6}
        strokeLinecap="round"
        fill="none"
      />
      <Circle cx={32} cy={8} r={3.5} fill={c} />
      <Path
        d="M22 33 L29.5 40.5 L43 25"
        stroke={c}
        strokeWidth={5.5}
        strokeLinecap="round"
        strokeLinejoin="round"
        fill="none"
      />
    </Svg>
  );
}

/** Mark + wordmark, for headers. */
export function LogoLockup({ markSize = 26, fontSize = 20 }: { markSize?: number; fontSize?: number }) {
  const { colors } = useTheme();
  return (
    <View style={styles.row}>
      <LogoMark size={markSize} />
      <Text style={[styles.word, { color: colors.ink, fontSize }]}>LifeOS</Text>
    </View>
  );
}

const styles = StyleSheet.create({
  row: { flexDirection: 'row', alignItems: 'center', gap: 8 },
  word: { fontWeight: '800', letterSpacing: -0.3 },
});
