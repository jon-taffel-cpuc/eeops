// Snowflake identity.
//
// The SPCS ingress authenticates the browser with Snowflake (CPUC SSO) before
// the app loads, so "logging in" already happened. GET /api/v1/me returns the
// Snowflake user name the ingress passed in the Sf-Context-Current-User header.

import { createContext, useContext, useEffect, useState, type ReactNode } from 'react';
import { apiFetch, type Me } from './api';

type AuthState = {
  isLoading: boolean;
  userId: string | null;
  error: string | null;
  logout: () => void;
};

const AuthContext = createContext<AuthState | null>(null);

export function AuthProvider({ children }: { children: ReactNode }) {
  const [me, setMe] = useState<Me | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    apiFetch<Me>('/me')
      .then((res) => setMe(res))
      .catch((e: unknown) => {
        setMe({ authenticated: false, user_id: null });
        setError(e instanceof Error ? e.message : 'Could not load user');
      });
  }, []);

  const value: AuthState = {
    isLoading: me === null,
    userId: me?.user_id ?? null,
    error,
    // The ingress owns the session; this ends it and returns to Snowflake sign-in.
    logout: () => window.location.assign('/sfc-endpoint/logout'),
  };
  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}

export function useAuth(): AuthState {
  const ctx = useContext(AuthContext);
  if (!ctx) throw new Error('useAuth must be used inside <AuthProvider>');
  return ctx;
}
