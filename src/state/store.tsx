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
import { Plan, TaskStatus } from '../core/types';

/**
 * App state: the user's active plans, persisted to device storage.
 * Kept as a plain reducer so the whole store is unit-testable and the
 * persistence layer is a single effect.
 */

const STORAGE_KEY = 'lifeos.plans.v1';

interface State {
  plans: Plan[];
  hydrated: boolean;
}

type Action =
  | { type: 'hydrate'; plans: Plan[] }
  | { type: 'addPlan'; plan: Plan }
  | { type: 'removePlan'; planId: string }
  | { type: 'setTaskStatus'; planId: string; taskId: string; status: TaskStatus }
  | { type: 'toggleDocument'; planId: string; taskId: string; documentName: string };

export function reducer(state: State, action: Action): State {
  switch (action.type) {
    case 'hydrate':
      return { plans: action.plans, hydrated: true };
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
  }
}

interface StoreValue {
  state: State;
  dispatch: React.Dispatch<Action>;
}

const StoreContext = createContext<StoreValue | undefined>(undefined);

export function StoreProvider({ children }: { children: React.ReactNode }) {
  const [state, dispatch] = useReducer(reducer, { plans: [], hydrated: false });
  const hydratedRef = useRef(false);

  useEffect(() => {
    AsyncStorage.getItem(STORAGE_KEY)
      .then((raw) => {
        dispatch({ type: 'hydrate', plans: raw ? (JSON.parse(raw) as Plan[]) : [] });
      })
      .catch(() => dispatch({ type: 'hydrate', plans: [] }));
  }, []);

  useEffect(() => {
    if (!state.hydrated) return;
    // Skip the write that immediately follows hydration itself.
    if (!hydratedRef.current) {
      hydratedRef.current = true;
      return;
    }
    AsyncStorage.setItem(STORAGE_KEY, JSON.stringify(state.plans)).catch(() => {});
  }, [state.plans, state.hydrated]);

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
