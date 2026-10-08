import { useEffect, useId, useRef, useState, type KeyboardEvent } from 'react';
import { Icon } from './Icon';
import { apiFetch, type PremiseHit, type PremiseSearch } from '../lib/api';
import { formatDate } from '../lib/time';

// Address bar for the Consumption page: type-ahead over EEOPS_PGE_PREMISE.
// Debounced, and every keystroke aborts the previous request, so a fast
// typist sends one query per pause rather than one per letter.

const MIN_CHARS = 3; // eeops/interval_data.py MIN_SEARCH_CHARS
const RESULT_LIMIT = 12;
const DEBOUNCE_MS = 250;

export function premiseLabel(p: PremiseHit): string {
  return [p.address, p.city, p.zip].filter(Boolean).join(', ') || 'Address not on file';
}

function message(e: unknown): string {
  return e instanceof Error ? e.message : String(e);
}

export default function AddressSearch({
  source,
  disabled,
  onSelect,
}: {
  source: string;
  disabled?: boolean;
  onSelect: (hit: PremiseHit) => void;
}) {
  const listId = useId();
  const [q, setQ] = useState('');
  const [results, setResults] = useState<PremiseHit[]>([]);
  const [open, setOpen] = useState(false);
  const [active, setActive] = useState(-1);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // Set when we fill the box with the chosen address, so it isn't re-searched.
  const skipSearch = useRef(false);

  const enough = q.replace(/[^A-Za-z0-9]/g, '').length >= MIN_CHARS;

  useEffect(() => {
    if (skipSearch.current) {
      skipSearch.current = false;
      return;
    }
    if (!enough) {
      setResults([]);
      setLoading(false);
      setError(null);
      return;
    }
    const ctrl = new AbortController();
    const timer = window.setTimeout(() => {
      setLoading(true);
      const qs = new URLSearchParams({ q: q.trim(), source, limit: String(RESULT_LIMIT) });
      apiFetch<PremiseSearch>(`/interval/search?${qs}`, { signal: ctrl.signal })
        .then((res) => {
          setResults(res.results);
          setActive(res.results.length ? 0 : -1);
          setError(null);
          setOpen(true);
        })
        .catch((e: unknown) => {
          if (ctrl.signal.aborted) return;
          setResults([]);
          setError(message(e));
        })
        .finally(() => {
          if (!ctrl.signal.aborted) setLoading(false);
        });
    }, DEBOUNCE_MS);
    return () => {
      window.clearTimeout(timer);
      ctrl.abort();
    };
  }, [q, source, enough]);

  function choose(hit: PremiseHit) {
    skipSearch.current = true;
    setQ(premiseLabel(hit));
    setOpen(false);
    setResults([]);
    onSelect(hit);
  }

  function onKeyDown(e: KeyboardEvent<HTMLInputElement>) {
    if (e.key === 'ArrowDown' && results.length) {
      e.preventDefault();
      setOpen(true);
      setActive((i) => (i + 1) % results.length);
    } else if (e.key === 'ArrowUp' && results.length) {
      e.preventDefault();
      setOpen(true);
      setActive((i) => (i <= 0 ? results.length - 1 : i - 1));
    } else if (e.key === 'Enter' && open && active >= 0 && results[active]) {
      e.preventDefault();
      choose(results[active]);
    } else if (e.key === 'Escape') {
      setOpen(false);
    }
  }

  const showList = open && results.length > 0;
  const showEmpty = open && enough && !loading && !error && results.length === 0;

  return (
    <div className="address-search">
      <label className="detail-label" htmlFor={`${listId}-input`}>Service address</label>
      <div className="search-anchor">
        <div className="search-field">
          <Icon name="search" />
          <input
            id={`${listId}-input`}
            type="search"
            role="combobox"
            aria-expanded={showList}
            aria-controls={listId}
            aria-autocomplete="list"
            aria-activedescendant={showList && active >= 0 ? `${listId}-${active}` : undefined}
            autoComplete="off"
            spellCheck={false}
            placeholder="Start typing a street address, city or ZIP…"
            value={q}
            disabled={disabled}
            onChange={(e) => { setQ(e.target.value); setOpen(true); }}
            onKeyDown={onKeyDown}
            onFocus={() => { if (results.length) setOpen(true); }}
            onBlur={() => setOpen(false)}
          />
          {loading ? <span className="search-spinner" aria-label="Searching" /> : null}
          {q && !loading ? (
            <button type="button" className="search-clear" aria-label="Clear address" onClick={() => { setQ(''); setResults([]); }}>
              <Icon name="close" />
            </button>
          ) : null}
        </div>

        {showList ? (
          <ul id={listId} role="listbox" className="search-results">
            {results.map((r, i) => (
              <li
                key={r.premise_id}
                id={`${listId}-${i}`}
                role="option"
                aria-selected={i === active}
                className={`search-option${i === active ? ' is-active' : ''}`}
                // mousedown, not click: fires before the input's blur closes the list
                onMouseDown={(e) => { e.preventDefault(); choose(r); }}
                onMouseEnter={() => setActive(i)}
              >
                <span className="search-option-main">{r.address ?? 'Address not on file'}</span>
                <span className="search-option-meta">
                  {[r.city, r.zip].filter(Boolean).join(' ')}
                  {' · '}
                  {r.meter_count} meter{r.meter_count === 1 ? '' : 's'}
                  {r.last_interval ? ` · data to ${formatDate(r.last_interval)}` : ''}
                </span>
              </li>
            ))}
          </ul>
        ) : null}
        {showEmpty ? <div className="search-results search-empty">No premises with interval data match “{q.trim()}”.</div> : null}
      </div>

      {error ? <pre className="error-block">{error}</pre> : (
        <div className="search-hint">
          {showList && results.length >= RESULT_LIMIT
            ? `Showing the first ${RESULT_LIMIT} matches. Add a unit or space number, city or ZIP to narrow it down (one street address can cover many units).`
            : enough
              ? 'Every word must match the start of a word in the address, in any order (e.g. “1450 market sf”).'
              : `Type at least ${MIN_CHARS} letters or digits.`}
        </div>
      )}
    </div>
  );
}
