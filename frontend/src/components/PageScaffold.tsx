import type { ReactNode } from 'react';
import { navItem, type PageKey } from '../nav';

// Standard page frame: title + subtitle (from nav.ts), optional header
// actions, then the page body. With no children it shows an empty scoping
// placeholder, which is where each page starts until features are built.
export default function PageScaffold({
  page,
  actions,
  children,
}: {
  page: PageKey;
  actions?: ReactNode;
  children?: ReactNode;
}) {
  const { label, subtitle } = navItem(page);
  return (
    <div className="page-stack">
      <div className="page-header-row">
        <div>
          <h1 className="page-title">{label}</h1>
          <p className="page-subtitle narrow-copy">{subtitle}</p>
        </div>
        {actions ? <div className="toolbar-row">{actions}</div> : null}
      </div>
      {children ?? <ScopePlaceholder />}
    </div>
  );
}

export function ScopePlaceholder() {
  return (
    <section className="panel">
      <div className="empty-state">
        <div className="section-heading">No features scoped yet</div>
        <p className="section-copy">This page is reserved. Features will be added here as they are scoped.</p>
      </div>
    </section>
  );
}
