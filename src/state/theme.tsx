import AsyncStorage from '@react-native-async-storage/async-storage';
import React, { createContext, useContext, useEffect, useMemo, useState } from 'react';
import { useColorScheme } from 'react-native';
import { Palette, palettes } from '../theme';

/** App-wide theme: light / dark / system, persisted on-device. */

export type ThemeSetting = 'light' | 'dark' | 'system';

const THEME_KEY = 'lifeos.theme.v1';

interface ThemeValue {
  colors: Palette;
  mode: 'light' | 'dark';
  setting: ThemeSetting;
  setSetting: (s: ThemeSetting) => void;
}

const ThemeContext = createContext<ThemeValue | undefined>(undefined);

export function ThemeProvider({ children }: { children: React.ReactNode }) {
  const system = useColorScheme();
  const [setting, setSettingState] = useState<ThemeSetting>('system');

  useEffect(() => {
    AsyncStorage.getItem(THEME_KEY)
      .then((raw) => {
        if (raw === 'light' || raw === 'dark' || raw === 'system') setSettingState(raw);
      })
      .catch(() => {});
  }, []);

  const setSetting = (s: ThemeSetting) => {
    setSettingState(s);
    AsyncStorage.setItem(THEME_KEY, s).catch(() => {});
  };

  const mode: 'light' | 'dark' =
    setting === 'system' ? (system === 'dark' ? 'dark' : 'light') : setting;

  const value = useMemo(
    () => ({ colors: palettes[mode], mode, setting, setSetting }),
    [mode, setting]
  );
  return <ThemeContext.Provider value={value}>{children}</ThemeContext.Provider>;
}

export function useTheme(): ThemeValue {
  const value = useContext(ThemeContext);
  if (!value) throw new Error('useTheme must be used inside ThemeProvider');
  return value;
}
