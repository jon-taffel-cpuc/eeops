#!/usr/bin/env bash
# ==========================================================================
# 01_auto_deploy_sf.sh -- Version bump, CHANGELOG, frontend build -> static/
# ==========================================================================
# Run from Cortex Code (CoCo) in Snowsight. /workspace is a Snowflake stage
# mount (no git CLI, npm hangs there), so:
#   * change detection uses a file manifest saved by the previous deploy,
#   * the frontend is built in $HOME/fe and dist/ is copied back to static/.
# Commit + push happen afterwards in the Snowsight Git panel.
#
# Usage:
#   bash /workspace/deploy/01_auto_deploy_sf.sh              # interactive
#   bash /workspace/deploy/01_auto_deploy_sf.sh --patch      # force patch
#   bash /workspace/deploy/01_auto_deploy_sf.sh --minor      # force minor
#   bash /workspace/deploy/01_auto_deploy_sf.sh --major      # force major
# CoCo should always pass a flag (the prompt can't be answered from chat).
# --------------------------------------------------------------------------

set -euo pipefail

WORKSPACE="${EEOPS_WORKSPACE:-/workspace}"   # override only for dry runs on a copy
FE_DIR="$HOME/fe"
MANIFEST="$WORKSPACE/.deploy_manifest.json"

BOLD='\033[1m'; CYAN='\033[36m'; YELLOW='\033[33m'; GREEN='\033[32m'; RED='\033[31m'; RESET='\033[0m'
step()  { echo -e "\n${CYAN}${BOLD}==> $1${RESET}"; }
info()  { echo -e "    $1"; }
warn()  { echo -e "    ${YELLOW}$1${RESET}"; }
err()   { echo -e "    ${RED}$1${RESET}"; }
ok()    { echo -e "    ${GREEN}$1${RESET}"; }

FORCE_BUMP=""
for arg in "$@"; do
  case "$arg" in
    --patch) FORCE_BUMP="patch" ;;
    --minor) FORCE_BUMP="minor" ;;
    --major) FORCE_BUMP="major" ;;
    --help|-h)
      echo "Usage: bash 01_auto_deploy_sf.sh [--patch|--minor|--major]"
      echo "  No flag = analyze changes and recommend a bump level."
      exit 0 ;;
    *) err "Unknown arg: $arg"; exit 1 ;;
  esac
done

# --------------------------------------------------------------------------
# 1. Current version
# --------------------------------------------------------------------------
step "Reading current version"
CURRENT_VERSION=$(python3 -c "
import json, pathlib
print(json.loads(pathlib.Path('$WORKSPACE/frontend/package.json').read_text())['version'])
")
info "Current version: ${BOLD}$CURRENT_VERSION${RESET}"
if [ -f "$WORKSPACE/static/version.json" ]; then
  info "Last built: $(python3 -c "import json; d=json.load(open('$WORKSPACE/static/version.json')); print(d.get('version','?'), '(built', d.get('built','?') + ')')")"
fi
IFS='.' read -r V_MAJOR V_MINOR V_PATCH <<< "$CURRENT_VERSION"

# Minor and patch count like decimal digits, so they never roll over into the
# next level: 8 -> 9 -> 91 -> 92 ... 99 -> 991 -> 992 ... (same scheme as
# CET_2). Each step is still a larger integer, so versions stay valid,
# increasing semver (0.9.0 < 0.91.0 < 0.991.0). Major is a plain integer.
next_decimal() {
  local n="$1" last="${1: -1}"
  if [ "$last" = "9" ]; then
    echo "${n}1"
  else
    echo "${n%?}$((last + 1))"
  fi
}
NEXT_PATCH="$V_MAJOR.$V_MINOR.$(next_decimal "$V_PATCH")"
NEXT_MINOR="$V_MAJOR.$(next_decimal "$V_MINOR").0"
NEXT_MAJOR="$((V_MAJOR + 1)).0.0"

# --------------------------------------------------------------------------
# 2. Changed files vs. the last deploy manifest
# --------------------------------------------------------------------------
# Tracked sources. Keep in sync with the manifest save in step 6.
SOURCE_DIRS="api eeops deploy/sql frontend/src frontend/public"
SOURCE_FILES="frontend/package.json frontend/package-lock.json frontend/vite.config.ts frontend/tsconfig.json frontend/tsconfig.app.json frontend/tsconfig.node.json frontend/index.html requirements.txt"

snapshot() {
  WORKSPACE="$WORKSPACE" SOURCE_DIRS="$SOURCE_DIRS" SOURCE_FILES="$SOURCE_FILES" python3 << 'PYEOF'
import hashlib, json, os
ws = os.environ["WORKSPACE"]
m = {}
for d in os.environ["SOURCE_DIRS"].split():
    for root, dirs, files in os.walk(os.path.join(ws, d)):
        dirs[:] = [x for x in dirs if x not in ("__pycache__", "node_modules", ".build")]
        for f in files:
            if f.endswith((".pyc", ".pyo")) or f == ".folder":
                continue
            full = os.path.join(root, f)
            m[os.path.relpath(full, ws)] = hashlib.sha256(open(full, "rb").read()).hexdigest()[:16]
for f in os.environ["SOURCE_FILES"].split():
    full = os.path.join(ws, f)
    if os.path.isfile(full):
        m[f] = hashlib.sha256(open(full, "rb").read()).hexdigest()[:16]
print(json.dumps(m, sort_keys=True))
PYEOF
}

step "Detecting changed files"
CURRENT_MANIFEST=$(snapshot)
CHANGED_FILES=$(CURRENT_MANIFEST="$CURRENT_MANIFEST" MANIFEST="$MANIFEST" python3 << 'PYEOF'
import json, os
current = json.loads(os.environ["CURRENT_MANIFEST"])
try:
    previous = json.loads(open(os.environ["MANIFEST"]).read())
except (FileNotFoundError, json.JSONDecodeError):
    previous = {}
changed = [f for f, h in sorted(current.items()) if previous.get(f) != h]
changed += [f + " (deleted)" for f in sorted(previous) if f not in current]
print("\n".join(changed))
PYEOF
)

if [ -z "$CHANGED_FILES" ]; then
  warn "No changes detected since the last deploy manifest."
  info "To force a full rebuild, delete .deploy_manifest.json and re-run."
  exit 0
fi
echo "$CHANGED_FILES" | head -30 | while read -r f; do info "  $f"; done
TOTAL=$(echo "$CHANGED_FILES" | wc -l | tr -d ' ')
if [ "$TOTAL" -gt 30 ]; then info "  ... and $((TOTAL - 30)) more"; fi
info ""
info "${BOLD}$TOTAL files changed${RESET} since last deploy"

# --------------------------------------------------------------------------
# 3. Categorize -> recommended bump
# --------------------------------------------------------------------------
HAS_API_CHANGES=false; HAS_CORE_CHANGES=false; HAS_SCHEMA_CHANGES=false; HAS_SQL_CHANGES=false
HAS_FRONTEND_CHANGES=false; HAS_CONFIG_CHANGES=false; HAS_DOCS_ONLY=true
while IFS= read -r file; do
  case "$file" in
    api/*)                                        HAS_API_CHANGES=true; HAS_DOCS_ONLY=false ;;
    deploy/sql/*.sql*)                            HAS_SCHEMA_CHANGES=true; HAS_SQL_CHANGES=true; HAS_DOCS_ONLY=false ;;
    eeops/config.py)                              HAS_SCHEMA_CHANGES=true; HAS_DOCS_ONLY=false ;;
    eeops/*)                                      HAS_CORE_CHANGES=true; HAS_DOCS_ONLY=false ;;
    frontend/src/*|frontend/public/*|frontend/*.ts|frontend/*.html)
                                                  HAS_FRONTEND_CHANGES=true; HAS_DOCS_ONLY=false ;;
    requirements.txt|frontend/package*.json|frontend/tsconfig*)
                                                  HAS_CONFIG_CHANGES=true; HAS_DOCS_ONLY=false ;;
    *.md|*.txt|.gitignore)                        ;;
    *)                                            HAS_DOCS_ONLY=false ;;
  esac
done <<< "$CHANGED_FILES"

RECOMMENDED="patch"; REASON="frontend-only changes"
if   $HAS_DOCS_ONLY;                          then RECOMMENDED="patch"; REASON="docs only"
elif $HAS_SCHEMA_CHANGES;                     then RECOMMENDED="minor"; REASON="schema or config changes detected"
elif $HAS_CORE_CHANGES || $HAS_API_CHANGES;   then RECOMMENDED="minor"; REASON="backend logic or API changes"
elif $HAS_CONFIG_CHANGES;                     then RECOMMENDED="minor"; REASON="dependency/config changes"
fi

echo ""
info "Analysis:"
info "  API routes changed:     $HAS_API_CHANGES"
info "  Backend changed:        $HAS_CORE_CHANGES"
info "  Schema/config changed:  $HAS_SCHEMA_CHANGES"
info "  Frontend changed:       $HAS_FRONTEND_CHANGES"
info "  Dependencies changed:   $HAS_CONFIG_CHANGES"
if $HAS_SQL_CHANGES; then
  warn "  deploy/sql changed -> re-run the changed deploy/sql/*.sql file(s) in Snowsight before 03."
fi

if [ -n "$FORCE_BUMP" ]; then
  BUMP="$FORCE_BUMP"; info "Forced bump: ${BOLD}$BUMP${RESET}"
else
  info "Recommended bump: ${BOLD}$RECOMMENDED${RESET} ($REASON)"
  echo ""
  echo -e "    ${YELLOW}Choose bump level:${RESET}"
  echo "      1) patch  ($NEXT_PATCH)"
  echo "      2) minor  ($NEXT_MINOR)"
  echo "      3) major  ($NEXT_MAJOR)"
  echo "      *) accept recommendation ($RECOMMENDED)"
  echo ""
  read -r -p "    Choice [Enter = $RECOMMENDED]: " CHOICE || CHOICE=""
  case "$CHOICE" in 1) BUMP="patch" ;; 2) BUMP="minor" ;; 3) BUMP="major" ;; *) BUMP="$RECOMMENDED" ;; esac
fi
case "$BUMP" in
  patch) NEW_VERSION="$NEXT_PATCH" ;;
  minor) NEW_VERSION="$NEXT_MINOR" ;;
  major) NEW_VERSION="$NEXT_MAJOR" ;;
esac
step "Bumping version: $CURRENT_VERSION -> $NEW_VERSION ($BUMP)"

# --------------------------------------------------------------------------
# 4. Version files + CHANGELOG
# --------------------------------------------------------------------------
python3 - "$WORKSPACE" "$NEW_VERSION" << 'PYEOF'
import json, pathlib, re, sys
ws, v = pathlib.Path(sys.argv[1]), sys.argv[2]
p = ws / "frontend/package.json"; d = json.loads(p.read_text()); d["version"] = v
p.write_text(json.dumps(d, indent=2) + "\n")
p = ws / "eeops/__init__.py"
p.write_text(re.sub(r'__version__\s*=\s*["\'].*?["\']', f'__version__ = "{v}"', p.read_text()))
print(f"    frontend/package.json -> {v}\n    eeops/__init__.py     -> {v}")
PYEOF

step "Updating CHANGELOG.md"
CHANGED_FILES="$CHANGED_FILES" python3 - "$WORKSPACE" "$NEW_VERSION" "$BUMP" "$REASON" "$TOTAL" << 'PYEOF'
import datetime, os, pathlib, sys
ws, version, bump, reason, total = pathlib.Path(sys.argv[1]), *sys.argv[2:6]
files = [f for f in os.environ["CHANGED_FILES"].splitlines() if f.strip()]
groups = [("Backend", ("eeops/",)), ("API", ("api/",)), ("Schema (deploy/sql)", ("deploy/sql/",)),
          ("Frontend", ("frontend/src/", "frontend/public/")), ("Config / dependencies", ("requirements.txt", "frontend/"))]
used, body = set(), []
for title, prefixes in groups:
    hits = [f for f in files if f not in used and f.startswith(prefixes)]
    if hits:
        used.update(hits)
        body.append(f"### {title}\n" + "\n".join(f"- Updated `{f}`" for f in hits))
entry = (f"## [{version}] — {datetime.date.today():%Y-%m-%d}\n\n"
         f"**Bump type:** {bump} ({reason}) — {total} files changed\n\n" + "\n\n".join(body) + "\n")
p = ws / "CHANGELOG.md"
if p.is_file():
    head, _, rest = p.read_text().partition("\n")
    p.write_text(f"{head}\n\n{entry}\n{rest.lstrip()}")
else:
    p.write_text(f"# EE Ops Changelog\n\n{entry}")
print(f"    Wrote {p}")
PYEOF

# --------------------------------------------------------------------------
# 5. Build the frontend off the stage mount, copy dist/ -> static/
# --------------------------------------------------------------------------
step "Building frontend in $FE_DIR"
rm -rf "$FE_DIR"
python3 -c "
import shutil
shutil.copytree('$WORKSPACE/frontend', '$FE_DIR', copy_function=shutil.copyfile,
                ignore=shutil.ignore_patterns('node_modules', 'dist', '.folder'))
"
cd "$FE_DIR"
info "npm ci ..."
# NODE_ENV=development: the sandbox defaults to production, which silently
# skips devDependencies (vite, typescript) and the build fails.
NODE_ENV=development npm ci --include=dev --no-audit --no-fund --loglevel=error 2>&1 | tail -3
info "npm run build ..."
if ! npm run build 2>&1 | tail -8; then err "Frontend build failed"; exit 1; fi
[ -f "$FE_DIR/dist/index.html" ] || { err "dist/index.html missing -- build failed (see output above)"; exit 1; }

# CSP guard: the SPCS ingress sends default-src 'self'. Anything loaded from
# another origin (Google Fonts, CDNs) or as a data: URI gets blocked.
CSP_HITS=$(grep -n -o -E "(https?:)?//[a-zA-Z0-9.-]+\.[a-z]{2,}[^\"' )]*|url\(\s*['\"]?data:" \
  "$FE_DIR/dist/index.html" "$FE_DIR"/dist/assets/*.css 2>/dev/null | grep -v -E "w3\.org" || true)
if [ -n "$CSP_HITS" ]; then
  err "Built HTML/CSS references external origins or data: URIs (blocked by the ingress CSP):"
  echo "$CSP_HITS" | head -10 | while read -r l; do err "  $l"; done
  err "Self-host the asset (npm package or frontend/public/) and rebuild."
  exit 1
fi
ok "CSP check: no external origins or data: URIs in index.html / CSS"

step "Copying dist/ to static/"
python3 - "$FE_DIR/dist" "$WORKSPACE/static" << 'PYEOF'
import pathlib, shutil, sys
src, dst = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
dst.mkdir(exist_ok=True)
# /workspace is a stage mount: rm -rf on dirs is unreliable, remove files individually.
for p in list(dst.rglob("*")):
    if p.is_file() and p.name != ".gitkeep":
        p.unlink()
for p in sorted(dst.rglob("*"), reverse=True):
    if p.is_dir():
        try: p.rmdir()
        except OSError: pass
for p in src.rglob("*"):
    if p.is_file():
        t = dst / p.relative_to(src)
        t.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(p, t)
PYEOF
BUILT_VERSION=$(python3 -c "import json; print(json.load(open('$WORKSPACE/static/version.json'))['version'])")
if [ "$BUILT_VERSION" != "$NEW_VERSION" ]; then
  err "static/version.json says $BUILT_VERSION but expected $NEW_VERSION!"; exit 1
fi
ok "static/version.json: $BUILT_VERSION"
cd "$WORKSPACE"

# --------------------------------------------------------------------------
# 6. Save manifest (post-bump state) for the next run
# --------------------------------------------------------------------------
# Recomputed after the bump so the version edits don't show up as "changed" next run.
step "Saving deploy manifest"
snapshot > "$MANIFEST"
ok "Wrote $MANIFEST"

echo ""
echo -e "${GREEN}${BOLD}=== Step 1 complete: $CURRENT_VERSION -> $NEW_VERSION ===${RESET}"
echo ""
echo -e "${YELLOW}${BOLD}NEXT: commit + push in the Snowsight Git panel${RESET} (git CLI doesn't work on /workspace)."
echo -e "      Include ${BOLD}static/${RESET} (new hashed filenames + deleted old ones), CHANGELOG.md,"
echo -e "      frontend/package.json, eeops/__init__.py and .deploy_manifest.json."
echo ""
echo -e "${CYAN}${BOLD}Then:${RESET}"
echo "  2. Laptop:    git pull ; py deploy\\02_build_image_laptop.py"
echo "  3. Snowsight: run deploy/03_redeploy_sf.sql"
echo "  4. Snowsight: run deploy/04_verify_sf.sql"
if $HAS_SQL_CHANGES; then
  echo -e "  ${YELLOW}Schema changed: run the changed deploy/sql/*.sql file(s) before step 3.${RESET}"
fi
echo ""
