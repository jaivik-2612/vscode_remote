import { NavigationContainer } from '@react-navigation/native';
import { createNativeStackNavigator } from '@react-navigation/native-stack';
import { createBottomTabNavigator } from '@react-navigation/bottom-tabs';
import { StatusBar } from 'expo-status-bar';
import React from 'react';
import { Text } from 'react-native';
import { RootStackParamList, TabParamList } from './src/navigation';
import { StoreProvider } from './src/state/store';
import HomeScreen from './src/screens/HomeScreen';
import IntakeScreen from './src/screens/IntakeScreen';
import PlanScreen from './src/screens/PlanScreen';
import TaskDetailScreen from './src/screens/TaskDetailScreen';
import TimelineScreen from './src/screens/TimelineScreen';
import { colors } from './src/theme';

const Stack = createNativeStackNavigator<RootStackParamList>();
const Tab = createBottomTabNavigator<TabParamList>();

function Tabs() {
  return (
    <Tab.Navigator
      screenOptions={{
        headerShown: false,
        tabBarActiveTintColor: colors.accent,
        tabBarInactiveTintColor: colors.textSecondary,
      }}
    >
      <Tab.Screen
        name="Home"
        component={HomeScreen}
        options={{ tabBarIcon: ({ color }) => <Text style={{ color, fontSize: 18 }}>🏠</Text> }}
      />
      <Tab.Screen
        name="Timeline"
        component={TimelineScreen}
        options={{ tabBarIcon: ({ color }) => <Text style={{ color, fontSize: 18 }}>📅</Text> }}
      />
    </Tab.Navigator>
  );
}

export default function App() {
  return (
    <StoreProvider>
      <NavigationContainer>
        <StatusBar style="dark" />
        <Stack.Navigator
          screenOptions={{
            headerTintColor: colors.text,
            headerStyle: { backgroundColor: colors.background },
            headerShadowVisible: false,
          }}
        >
          <Stack.Screen name="Tabs" component={Tabs} options={{ headerShown: false }} />
          <Stack.Screen name="Intake" component={IntakeScreen} options={{ title: 'New plan' }} />
          <Stack.Screen name="Plan" component={PlanScreen} options={{ title: 'Plan' }} />
          <Stack.Screen name="TaskDetail" component={TaskDetailScreen} options={{ title: 'Task' }} />
        </Stack.Navigator>
      </NavigationContainer>
    </StoreProvider>
  );
}
