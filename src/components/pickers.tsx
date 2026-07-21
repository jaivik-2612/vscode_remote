import React, { useMemo, useState } from 'react';
import {
  FlatList,
  Modal,
  StyleSheet,
  Text,
  TextInput,
  TouchableOpacity,
  View,
} from 'react-native';
import { useTheme } from '../state/theme';
import { radius, spacing } from '../theme';

export interface SelectOption {
  value: string;
  label: string;
}

/**
 * A dropdown that opens a full-screen sheet with a filter box — usable for
 * long lists (all countries) and short ones (US states) alike. The trigger
 * takes `style` so it can visually match sibling TextInputs on any screen.
 */
export function SelectField({
  placeholder,
  title,
  value,
  options,
  onSelect,
  style,
}: {
  placeholder: string;
  title?: string;
  value: string;
  options: SelectOption[];
  onSelect: (value: string) => void;
  style?: object | object[];
}) {
  const { colors } = useTheme();
  const [open, setOpen] = useState(false);
  const [filter, setFilter] = useState('');

  const shown = useMemo(() => {
    const q = filter.trim().toLowerCase();
    return q ? options.filter((o) => o.label.toLowerCase().includes(q)) : options;
  }, [filter, options]);

  const selected = options.find((o) => o.value === value);

  return (
    <>
      <TouchableOpacity
        style={[styles.trigger, style]}
        onPress={() => {
          setFilter('');
          setOpen(true);
        }}
      >
        <Text
          style={[styles.triggerText, { color: selected ? colors.ink : colors.muted }]}
          numberOfLines={1}
        >
          {selected?.label ?? placeholder}
        </Text>
        <Text style={{ color: colors.muted, fontSize: 12 }}>▾</Text>
      </TouchableOpacity>

      <Modal visible={open} animationType="slide" onRequestClose={() => setOpen(false)}>
        <View style={[styles.sheet, { backgroundColor: colors.bg }]}>
          <View style={styles.sheetHeader}>
            <Text style={[styles.sheetTitle, { color: colors.ink }]}>
              {title ?? placeholder}
            </Text>
            <TouchableOpacity onPress={() => setOpen(false)} hitSlop={12}>
              <Text style={{ color: colors.accent, fontSize: 15, fontWeight: '700' }}>Close</Text>
            </TouchableOpacity>
          </View>
          {options.length > 12 && (
            <TextInput
              style={[
                styles.search,
                { backgroundColor: colors.card, color: colors.ink, borderColor: colors.line },
              ]}
              placeholder="Type to filter…"
              placeholderTextColor={colors.muted}
              value={filter}
              onChangeText={setFilter}
              autoFocus
            />
          )}
          <FlatList
            data={shown}
            keyExtractor={(o) => o.value}
            keyboardShouldPersistTaps="handled"
            renderItem={({ item }) => (
              <TouchableOpacity
                style={[styles.row, { borderBottomColor: colors.line }]}
                onPress={() => {
                  onSelect(item.value);
                  setOpen(false);
                }}
              >
                <Text
                  style={{
                    fontSize: 15,
                    color: item.value === value ? colors.accent : colors.ink,
                    fontWeight: item.value === value ? '700' : '400',
                  }}
                >
                  {item.label}
                  {item.value === value ? '  ✓' : ''}
                </Text>
              </TouchableOpacity>
            )}
            ListEmptyComponent={
              <Text style={{ color: colors.muted, padding: spacing.md, textAlign: 'center' }}>
                No matches.
              </Text>
            }
          />
        </View>
      </Modal>
    </>
  );
}

const styles = StyleSheet.create({
  trigger: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
  },
  triggerText: { fontSize: 15, flex: 1, marginRight: spacing.sm },
  sheet: { flex: 1, padding: spacing.md },
  sheetHeader: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    marginTop: spacing.lg,
    marginBottom: spacing.sm,
  },
  sheetTitle: { fontSize: 20, fontWeight: '800' },
  search: {
    borderWidth: 1,
    borderRadius: radius.small,
    paddingHorizontal: spacing.sm,
    paddingVertical: 10,
    fontSize: 15,
    marginBottom: spacing.sm,
  },
  row: {
    paddingVertical: 13,
    borderBottomWidth: StyleSheet.hairlineWidth,
  },
});
