import { Link } from 'react-router';
import { DEFAULT_PATH } from '../nav';

export default function NotFound() {
  return (
    <div className="page-stack">
      <section className="panel">
        <div className="empty-state">
          <div className="section-heading">Page not found</div>
          <p className="section-copy">
            <Link className="breadcrumb-link" to={DEFAULT_PATH}>Back to EE Ops</Link>
          </p>
        </div>
      </section>
    </div>
  );
}
