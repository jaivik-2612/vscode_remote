import { DarkTheme, DefaultTheme, NavigationContainer } from '@react-navigation/native';
import { createNativeStackNavigator } from '@react-navigation/native-stack';
import { createBottomTabNavigator } from '@react-navigation/bottom-tabs';
import { StatusBar } from 'expo-status-bar';
import React from 'react';
import { Text } from 'react-native';
import { RootStackParamList, TabParamList } from './src/navigation';
import { AuthProvider, useAuth } from './src/state/auth';
import { StoreProvider } from './src/state/store';
import { ThemeProvider, useTheme } from './src/state/theme';
import AuthScreen from './src/screens/AuthScreen';
import TermsScreen from './src/screens/TermsScreen';
import HomeScreen from './src/screens/HomeScreen';
import IntakeScreen from './src/screens/IntakeScreen';
import PlanScreen from './src/screens/PlanScreen';
import TaskDetailScreen from './src/screens/TaskDetailScreen';
import TimelineScreen from './src/screens/TimelineScreen';
import DashboardScreen from './src/screens/DashboardScreen';
import SettingsScreen from './src/screens/SettingsScreen';

const Stack = createNativeStackNavigator<RootStackParamList>();
const Tab = createBottomTabNavigator<TabParamList>();

function tabIcon(icon: string) {
  return ({ color }: { color: string }) => <Text style={{ color, fontSize: 18 }}>{icon}</Text>;
}

function Tabs() {
  const { colors } = useTheme();
  return (
    <Tab.Navigator
      screenOptions={{
        headerShown: false,
        tabBarActiveTintColor: colors.accent,
        tabBarInactiveTintColor: colors.muted,
        tabBarStyle: { backgroundColor: colors.card, borderTopColor: colors.line },
      }}
    >
      <Tab.Screen name="Home" component={HomeScreen} options={{ tabBarIcon: tabIcon('🏠') }} />
      <Tab.Screen name="Dashboard" component={DashboardScreen} options={{ tabBarIcon: tabIcon('📊') }} />
      <Tab.Screen name="Timeline" component={TimelineScreen} options={{ tabBarIcon: tabIcon('📅') }} />
      <Tab.Screen name="Settings" component={SettingsScreen} options={{ tabBarIcon: tabIcon('⚙️') }} />
    </Tab.Navigator>
  );
}

function AppNavigation() {
  const { colors, mode } = useTheme();
  const navTheme = {
    ...(mode === 'dark' ? DarkTheme : DefaultTheme),
    colors: {
      ...(mode === 'dark' ? DarkTheme : DefaultTheme).colors,
      background: colors.bg,
      card: colors.card,
      text: colors.ink,
      primary: colors.accent,
      border: colors.line,
    },
  };
  return (
    <NavigationContainer theme={navTheme}>
      <StatusBar style={mode === 'dark' ? 'light' : 'dark'} />
      <Stack.Navigator
        screenOptions={{
          headerTintColor: colors.ink,
          headerStyle: { backgroundColor: colors.bg },
          headerShadowVisible: false,
        }}
      >
        <Stack.Screen name="Tabs" component={Tabs} options={{ headerShown: false }} />
        <Stack.Screen name="Intake" component={IntakeScreen} options={{ title: 'New plan' }} />
        <Stack.Screen name="Plan" component={PlanScreen} options={{ title: 'Plan' }} />
        <Stack.Screen name="TaskDetail" component={TaskDetailScreen} options={{ title: 'Task' }} />
      </Stack.Navigator>
    </NavigationContainer>
  );
}

/** Auth gate: sign in → confirm email → accept terms → app. */
function Root() {
  const { status } = useAuth();
  const { colors, mode } = useTheme();
  if (status === 'loading') {
    return (
      <Text
        style={{
          flex: 1,
          textAlign: 'center',
          textAlignVertical: 'center',
          backgroundColor: colors.bg,
          color: colors.muted,
        }}
      >
        LifeOS…
      </Text>
    );
  }
  if (status === 'signed-out') {
    return (
      <>
        <StatusBar style={mode === 'dark' ? 'light' : 'dark'} />
        <AuthScreen />
      </>
    );
  }
  if (status === 'needs-terms') {
    return (
      <>
        <StatusBar style={mode === 'dark' ? 'light' : 'dark'} />
        <TermsScreen />
      </>
    );
  }
  return <AppNavigation />;
}

export default function App() {
  return (
    <ThemeProvider>
      <AuthProvider>
        <StoreProvider>
          <Root />
        </StoreProvider>
      </AuthProvider>
    </ThemeProvider>
  );
}
