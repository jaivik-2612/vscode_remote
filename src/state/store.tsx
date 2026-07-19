import AsyncStorage from '@react-native-async-storage/async-storage';
import React, {
  createContext,
  useContext,
  useEffect,
  useMemo,
  useReducer,
  useRef,
} from 'react';
import { reconcileBlocked } from '../core/planner';
import { UserProfile } from '../core/resources';
import { Plan, TaskStatus } from '../core/types';
import { useAuth } from './auth';
import { fetchBackup, queueBackup } from './backup';

/**
 * App state: the user's active plans, persisted to device storage.
 * Kept as a plain reducer so the whole store is unit-testable and the
 * persistence layer is a single effect.
 */

const STORAGE_KEY = 'lifeos.plans.v1';
const PROFILE_KEY = 'lifeos.profile.v1';

interface State {
  plans: Plan[];
  profile: UserProfile | null;
  hydrated: boolean;
}

type Action =
  | { type: 'hydrate'; plans: Plan[]; profile: UserProfile | null }
  | { type: 'setProfile'; profile: UserProfile }
  | { type: 'addPlan'; plan: Plan }
  | { type: 'removePlan'; planId: string }
  | { type: 'setTaskStatus'; planId: string; taskId: string; status: TaskStatus }
  | { type: 'toggleDocument'; planId: string; taskId: string; documentName: string }
  | { type: 'toggleStep'; planId: string; taskId: string; stepName: string };

/** Backfill fields added since a stored plan was created. */
export function migratePlan(plan: Plan): Plan {
  return {
    ...plan,
    milestone: plan.milestone ?? false,
    tasks: plan.tasks.map((t) => ({
      ...t,
      documents: t.documents ?? [],
      steps: t.steps ?? [],
    })),
  };
}

export function reducer(state: State, action: Action): State {
  switch (action.type) {
    case 'hydrate':
      return { plans: action.plans.map(migratePlan), profile: action.profile, hydrated: true };
    case 'setProfile':
      return { ...state, profile: action.profile };
    case 'addPlan':
      return { ...state, plans: [action.plan, ...state.plans] };
    case 'removePlan':
      return { ...state, plans: state.plans.filter((p) => p.id !== action.planId) };
    case 'setTaskStatus':
      return {
        ...state,
        plans: state.plans.map((p) => {
          if (p.id !== action.planId) return p;
          const updated = {
            ...p,
            tasks: p.tasks.map((t) =>
              t.id === action.taskId ? { ...t, status: action.status } : t
            ),
          };
          return reconcileBlocked(updated);
        }),
      };
    case 'toggleDocument':
      return {
        ...state,
        plans: state.plans.map((p) => {
          if (p.id !== action.planId) return p;
          return {
            ...p,
            tasks: p.tasks.map((t) =>
              t.id === action.taskId
                ? {
                    ...t,
                    documents: t.documents.map((d) =>
                      d.name === action.documentName ? { ...d, collected: !d.collected } : d
                    ),
                  }
                : t
            ),
          };
        }),
      };
    case 'toggleStep':
      return {
        ...state,
        plans: state.plans.map((p) => {
          if (p.id !== action.planId) return p;
          return {
            ...p,
            tasks: p.tasks.map((t) =>
              t.id === action.taskId
                ? {
                    ...t,
                    steps: t.steps.map((s) =>
                      s.name === action.stepName ? { ...s, done: !s.done } : s
                    ),
                  }
                : t
            ),
          };
        }),
      };
  }
}

interface StoreValue {
  state: State;
  dispatch: React.Dispatch<Action>;
}

const StoreContext = createContext<StoreValue | undefined>(undefined);

export function StoreProvider({ children }: { children: React.ReactNode }) {
  const [state, dispatch] = useReducer(reducer, { plans: [], profile: null, hydrated: false });
  const hydratedRef = useRef(false);
  const { session } = useAuth();
  const restoredForUser = useRef<string | null>(null);

  useEffect(() => {
    Promise.all([AsyncStorage.getItem(STORAGE_KEY), AsyncStorage.getItem(PROFILE_KEY)])
      .then(([rawPlans, rawProfile]) => {
        dispatch({
          type: 'hydrate',
          plans: rawPlans ? (JSON.parse(rawPlans) as Plan[]) : [],
          profile: rawProfile ? (JSON.parse(rawProfile) as UserProfile) : null,
        });
      })
      .catch(() => dispatch({ type: 'hydrate', plans: [], profile: null }));
  }, []);

  useEffect(() => {
    if (!state.hydrated) return;
    // Skip the write that immediately follows hydration itself.
    if (!hydratedRef.current) {
      hydratedRef.current = true;
      return;
    }
    AsyncStorage.setItem(STORAGE_KEY, JSON.stringify(state.plans)).catch(() => {});
    if (state.profile) {
      AsyncStorage.setItem(PROFILE_KEY, JSON.stringify(state.profile)).catch(() => {});
    }
    if (session?.user) {
      queueBackup(session.user.id, { version: 1, profile: state.profile, plans: state.plans });
    }
  }, [state.plans, state.profile, state.hydrated, session?.user?.id]);

  // On sign-in with an empty device, restore the cloud backup once.
  useEffect(() => {
    const userId = session?.user?.id;
    if (!userId || !state.hydrated || restoredForUser.current === userId) return;
    restoredForUser.current = userId;
    if (state.plans.length > 0) return;
    fetchBackup(userId)
      .then((backup) => {
        if (backup && backup.plans.length > 0) {
          dispatch({ type: 'hydrate', plans: backup.plans, profile: backup.profile ?? state.profile });
        }
      })
      .catch(() => {});
  }, [session?.user?.id, state.hydrated]);

  const value = useMemo(() => ({ state, dispatch }), [state]);
  return <StoreContext.Provider value={value}>{children}</StoreContext.Provider>;
}

export function useStore(): StoreValue {
  const value = useContext(StoreContext);
  if (!value) throw new Error('useStore must be used inside StoreProvider');
  return value;
}

export function todayIso(): string {
  return new Date().toISOString().slice(0, 10);
}
