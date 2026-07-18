export type RootStackParamList = {
  Tabs: undefined;
  Intake: { eventId: string };
  Plan: { planId: string };
  TaskDetail: { planId: string; taskId: string };
};

export type TabParamList = {
  Home: undefined;
  Timeline: undefined;
};
