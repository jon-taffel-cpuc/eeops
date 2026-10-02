import { useEffect, useState } from 'react';
import PageScaffold, { ScopePlaceholder } from '../components/PageScaffold';
import { Icon } from '../components/Icon';
import { apiFetch, type Health, type SnowflakeCheck } from '../lib/api';
import { useAuth } from '../lib/auth';

// Deployment status is here so a deploy can be verified from the browser
// (step 4 of the Quick Deploy Guide): the three versions must match.
function SystemStatus() {
  const { userId } = useAuth();
  const [health, setHealth] = useState<Health | null>(null);
  const [healthError, setHealthError] = useState<string | null>(null);
  const [sf, setSf] = useState<SnowflakeCheck | null>(null);
  const [sfError, setSfError] = useState<string | null>(null);
  const [sfLoading, setSfLoading] = useState(false);

  useEffect(() => {
    apiFetch<Health>('/health')
      .then(setHealth)
      .catch((e: unknown) => setHealthError(e instanceof Error ? e.message : String(e)));
  }, []);

  async function checkSnowflake() {
    setSfLoading(true);
    setSfError(null);
    try {
      setSf(await apiFetch<SnowflakeCheck>('/system/snowflake'));
    } catch (e) {
      setSf(null);
      setSfError(e instanceof Error ? e.message : String(e));
    } finally {
      setSfLoading(false);
    }
  }

  const stale = health !== null && (health.version !== __APP_VERSION__ || health.frontend_version !== __APP_VERSION__);

  return (
    <section className="panel panel-padless">
      <div className="panel-header">
        <div>
          <h2 className="panel-title">System status</h2>
          <p className="section-copy tiny-copy">Service EEOPS_APP · CPUC_ED_DB.ENERGY_EFFICIENCY</p>
        </div>
        <button type="button" className="button button-secondary button-small" onClick={() => void checkSnowflake()} disabled={sfLoading}>
          <Icon name="refresh" />
          {sfLoading ? 'Checking…' : 'Check Snowflake connection'}
        </button>
      </div>
      <div className="panel-body">
        <div className="page-stack">
          {stale ? (
            <div className="notice">
              Version mismatch: this browser is running v{__APP_VERSION__} but the server reports
              backend v{health?.version} / bundle v{health?.frontend_version}. Hard-refresh (Ctrl+Shift+R);
              if it persists, the deploy did not land (see Quick Deploy Guide, step 4).
            </div>
          ) : null}
          {healthError ? <pre className="error-block">Health check failed: {healthError}</pre> : null}
          <div className="detail-grid">
            <Detail label="Signed-in user" value={userId ?? '—'} />
            <Detail label="Browser bundle" value={`v${__APP_VERSION__}`} />
            <Detail label="Backend" value={health ? `v${health.version}` : '…'} />
            <Detail label="Bundle on server" value={health ? `v${health.frontend_version}` : '…'} />
            {sf ? (
              <>
                <Detail label="Service role" value={sf.session.role ?? '—'} />
                <Detail label="Warehouse" value={sf.session.warehouse ?? '—'} />
                <Detail label="Database.Schema" value={`${sf.session.database ?? '—'}.${sf.session.schema ?? '—'}`} />
                <Detail label="Snowflake version" value={sf.session.version ?? '—'} />
              </>
            ) : null}
          </div>
          {sfError ? <pre className="error-block">Snowflake check failed: {sfError}</pre> : null}
        </div>
      </div>
    </section>
  );
}

function Detail({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <div className="detail-label">{label}</div>
      <div className="detail-value">{value}</div>
    </div>
  );
}

export default function CpucAdmin() {
  return (
    <PageScaffold page="cpuc-admin">
      <SystemStatus />
      <ScopePlaceholder />
    </PageScaffold>
  );
}
