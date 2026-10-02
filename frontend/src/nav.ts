// The one place that defines EE Ops' top-level pages. The sidebar, the router
// (App.tsx) and each page's header all read from here, so adding or renaming a
// page is: add/edit an entry below + add the page component in App.tsx.

import type { IconName } from './components/Icon';

export type PageKey =
  | 'customers-markets'
  | 'potentials-goals'
  | 'ex-ante-custom'
  | 'tools-calculators'
  | 'programs-performance'
  | 'evaluations'
  | 'grid-details'
  | 'policies-proceedings'
  | 'cpuc-admin';

export type NavItem = {
  key: PageKey;
  path: `/${string}`;
  label: string;
  icon: IconName;
  /** One-line page description shown under the title. Edit freely as scope firms up. */
  subtitle: string;
  badge?: string;
};

export const NAV: NavItem[] = [
  {
    key: 'customers-markets',
    path: '/customers-markets',
    label: 'Customers and Markets',
    icon: 'customers',
    subtitle: 'Page scope in development.',
  },
  {
    key: 'potentials-goals',
    path: '/potentials-goals',
    label: 'Potentials and Goals',
    icon: 'potentials',
    subtitle: 'Page scope in development.',
  },
  {
    key: 'ex-ante-custom',
    path: '/ex-ante-custom',
    label: 'Ex Ante/Custom',
    icon: 'exante',
    subtitle: 'Page scope in development.',
  },
  {
    key: 'tools-calculators',
    path: '/tools-calculators',
    label: 'Tools and Calculators',
    icon: 'tools',
    subtitle: 'Page scope in development.',
  },
  {
    key: 'programs-performance',
    path: '/programs-performance',
    label: 'Programs and Performance',
    icon: 'programs',
    subtitle: 'Page scope in development.',
  },
  {
    key: 'evaluations',
    path: '/evaluations',
    label: 'Evaluations',
    icon: 'evaluations',
    subtitle: 'Page scope in development.',
  },
  {
    key: 'grid-details',
    path: '/grid-details',
    label: 'Grid Details',
    icon: 'grid',
    subtitle: 'Page scope in development.',
  },
  {
    key: 'policies-proceedings',
    path: '/policies-proceedings',
    label: 'Policies and Proceedings',
    icon: 'policies',
    subtitle: 'Page scope in development.',
  },
  {
    key: 'cpuc-admin',
    path: '/cpuc-admin',
    label: 'CPUC Admin',
    icon: 'admin',
    subtitle: 'App administration and deployment status.',
    badge: 'Admin',
  },
];

export const DEFAULT_PATH = NAV[0].path;

export function navItem(key: PageKey): NavItem {
  const item = NAV.find((n) => n.key === key);
  if (!item) throw new Error(`Unknown page key: ${key}`);
  return item;
}
