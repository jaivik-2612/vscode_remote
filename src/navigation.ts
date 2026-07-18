export type RootStackParamList = {
  Tabs: undefined;
  Intake: { eventId: string };
  Plan: { planId: string; celebrate?: boolean };
  TaskDetail: { planId: string; taskId: string };
};

export type TabParamList = {
  Home: undefined;
  Dashboard: undefined;
  Timeline: undefined;
  Settings: undefined;
};
