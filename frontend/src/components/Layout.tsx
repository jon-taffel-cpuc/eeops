import { useEffect, useState, type ReactNode } from 'react';
import { NavLink, useLocation } from 'react-router';
import { NAV } from '../nav';
import { useAuth } from '../lib/auth';
import { Icon } from './Icon';

function initials(userId: string | null): string {
  if (!userId) return '?';
  const parts = userId.split(/[._\s-]+/).filter(Boolean);
  const letters = parts.length > 1 ? parts[0][0] + parts[1][0] : userId.slice(0, 2);
  return letters.toUpperCase();
}

// Canopy app shell: gold banner, navy sidebar, white topbar with gold rule.
export default function Layout({ children }: { children: ReactNode }) {
  const { userId, logout } = useAuth();
  const { pathname } = useLocation();
  const [isNavOpen, setIsNavOpen] = useState(false);

  // Close the mobile drawer whenever the route changes.
  useEffect(() => setIsNavOpen(false), [pathname]);

  const current = NAV.find((n) => pathname === n.path || pathname.startsWith(`${n.path}/`));

  return (
    <>
      <div className="prototype-banner">
        Internal · EE Ops v{__APP_VERSION__} · CPUC Energy Division · Not for distribution
      </div>
      <div className="eeops-app">
        <aside className={`sidebar${isNavOpen ? ' is-open' : ''}`}>
          <div className="sidebar-brand">
            <div className="brand-mark">EE OPS</div>
            <div className="brand-copy">CPUC Energy Division · Energy Efficiency Operations</div>
          </div>

          <nav className="nav-list" aria-label="Main">
            {NAV.map((item) => (
              <NavLink key={item.key} to={item.path} className={({ isActive }) => `nav-link${isActive ? ' is-active' : ''}`}>
                <span className="nav-icon"><Icon name={item.icon} /></span>
                <span>{item.label}</span>
                {item.badge ? <span className="nav-badge">{item.badge}</span> : null}
              </NavLink>
            ))}
          </nav>

          <div className="sidebar-footer">
            <div className="user-avatar">{initials(userId)}</div>
            <div>
              <div className="user-name">{userId ?? 'Not signed in'}</div>
              <div className="user-role">Snowflake SSO</div>
            </div>
          </div>
          <div className="sidebar-version">EE Ops v{__APP_VERSION__}</div>
        </aside>
        <div className={`nav-scrim${isNavOpen ? ' is-open' : ''}`} onClick={() => setIsNavOpen(false)} />

        <main className="main-shell">
          <header className="topbar">
            <div className="topbar-left">
              <button
                type="button"
                className="button button-icon mobile-only"
                aria-label="Toggle navigation"
                onClick={() => setIsNavOpen((open) => !open)}
              >
                <Icon name="menu" />
              </button>
              <div className="breadcrumb">
                <span className="breadcrumb-link">EE Ops</span>
                <Icon name="chevron-right" />
                <span className="breadcrumb-current">{current?.label ?? 'Not found'}</span>
              </div>
            </div>
            <div className="toolbar-row topbar-actions">
              <button type="button" className="button button-secondary button-small" onClick={logout}>
                <Icon name="logout" />
                Sign out
              </button>
            </div>
          </header>

          <section className="view-shell">{children}</section>
        </main>
      </div>
    </>
  );
}
