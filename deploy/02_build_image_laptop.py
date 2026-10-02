"""
Build and push the EE Ops app image to Snowflake WITHOUT Docker or admin rights.

Same approach as CET_2 / Canopy / CMS: `crane` (single binary, downloaded
automatically) appends one layer -- the app code (api/, eeops/), the prebuilt
React bundle (static/) and Linux x86_64 CPython 3.11 wheels -- onto
python:3.11-slim and pushes it to the Snowflake image repository. FastAPI
serves the SPA and the API on :8080. There is no Dockerfile on purpose.

Runs on your LAPTOP (the CoCo sandbox can't reach GitHub or the registry).

Usage (Windows / macOS / Linux, from the repo root):
    py deploy/02_build_image_laptop.py                  # build and push
    py deploy/02_build_image_laptop.py --reuse-layer    # push without rebuilding
    py deploy/02_build_image_laptop.py --skip-push      # build only (dry run)
    py deploy/02_build_image_laptop.py --clear-pat      # reset saved credentials

Authentication:
    The CPUC registry requires a Programmatic Access Token (PAT); session
    tokens get a silent 401. Credentials are looked up in this order:
      1. SNOWFLAKE_PAT + SNOWFLAKE_REGISTRY_USER environment variables
      2. ~/.snowflake/eeops_pat.json, then the other ED apps' saved PATs
         (canopy_pat.json, cms_pat.json, cet_pat.json)
      3. Interactive prompt (offers to save to ~/.snowflake/eeops_pat.json)
    Generate a PAT: Snowsight -> profile -> Settings -> Authentication
                    -> Programmatic access tokens -> Generate new token
                    (restrict to role CPUC_ED_TITLE20_RL)
"""
from __future__ import annotations

import argparse
import getpass
import hashlib
import io
import json
import os
import platform
import shutil
import subprocess
import sys
import tarfile
import urllib.request
from pathlib import Path

REGISTRY = "californiapublicutilitiescommission-cpuc-aws-us-west-2.registry.snowflakecomputing.com"
IMAGE = f"{REGISTRY}/cpuc_ed_db/energy_efficiency/eeops_images/eeops-app:latest"
BASE_IMAGE = "python:3.11-slim"

ROOT = Path(__file__).resolve().parent.parent  # repo root (one level above deploy/)
BUILD = ROOT / ".build"
PYDEPS = BUILD / "pydeps"
LAYER = BUILD / "layer.tar"
REQS_HASH_FILE = BUILD / "requirements_hash.txt"
APP_DIRS = ("api", "eeops", "static")

CRANE_URL = ("https://github.com/google/go-containerregistry/releases/latest/"
             "download/go-containerregistry_{os}_{arch}.tar.gz")

# Newer and older manylinux tags; python:3.11-slim (Debian bookworm) has glibc 2.36.
WHEEL_PLATFORMS = ["manylinux_2_34_x86_64", "manylinux_2_28_x86_64",
                   "manylinux_2_17_x86_64", "manylinux2014_x86_64"]

PAT_CACHE = Path.home() / ".snowflake" / "eeops_pat.json"
PAT_FALLBACKS = [PAT_CACHE] + [Path.home() / ".snowflake" / f
                               for f in ("canopy_pat.json", "cms_pat.json", "cet_pat.json")]


def step(msg: str) -> None:
    print(f"\n==> {msg}", flush=True)


def get_crane() -> Path:
    exe = BUILD / ("crane.exe" if os.name == "nt" else "crane")
    if exe.exists():
        return exe
    os_name = {"Windows": "Windows", "Darwin": "Darwin"}.get(platform.system(), "Linux")
    arch = "arm64" if platform.machine().lower() in ("arm64", "aarch64") else "x86_64"
    url = CRANE_URL.format(os=os_name, arch=arch)
    step(f"Downloading crane from {url}")
    data = urllib.request.urlopen(url, timeout=120).read()
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as tf:
        with tf.extractfile(tf.getmember(exe.name)) as src, open(exe, "wb") as dst:
            shutil.copyfileobj(src, dst)
    exe.chmod(0o755)
    return exe


def _requirements_hash() -> str:
    return hashlib.sha256((ROOT / "requirements.txt").read_bytes()).hexdigest()[:16]


def install_linux_wheels() -> None:
    current_hash = _requirements_hash()
    if PYDEPS.exists() and REQS_HASH_FILE.exists() and REQS_HASH_FILE.read_text().strip() == current_hash:
        step("Reusing cached wheels (requirements.txt unchanged)")
        print(f"    {PYDEPS}  (delete .build/pydeps/ to force a re-download)")
        return
    step("Downloading Linux x86_64 / CPython 3.11 wheels")
    if PYDEPS.exists():
        shutil.rmtree(PYDEPS)
    cmd = [sys.executable, "-s", "-m", "pip", "install", "--quiet",
           "--ignore-installed", "--no-warn-conflicts",
           "--target", str(PYDEPS),
           "--python-version", "3.11", "--implementation", "cp", "--abi", "cp311",
           "--only-binary=:all:", "-r", str(ROOT / "requirements.txt")]
    for p in WHEEL_PLATFORMS:
        cmd += ["--platform", p]
    subprocess.run(cmd, check=True)
    BUILD.mkdir(exist_ok=True)
    REQS_HASH_FILE.write_text(current_hash + "\n")


def _add_tree(tf: tarfile.TarFile, src: Path, arc_root: str) -> None:
    for path in sorted(src.rglob("*")):
        if "__pycache__" in path.parts or path.suffix in (".pyc", ".pyo") or path.name == ".folder":
            continue
        info = tf.gettarinfo(str(path), arcname=f"{arc_root}/{path.relative_to(src).as_posix()}")
        info.uid = info.gid = 0
        info.uname = info.gname = "root"
        info.mode = 0o755 if path.is_dir() else 0o644
        if path.is_dir():
            tf.addfile(info)
        else:
            with open(path, "rb") as f:
                tf.addfile(info, f)


def check_versions() -> None:
    """Refuse to pack a static/ bundle that doesn't match the source versions.

    frontend/package.json, static/version.json and eeops.__version__ must all
    agree, otherwise an old UI (or old backend) would deploy silently.
    """
    step("Checking versions")
    fe_src = json.loads((ROOT / "frontend" / "package.json").read_text())["version"]
    try:
        fe_built = json.loads((ROOT / "static" / "version.json").read_text())
    except (OSError, ValueError):
        fe_built = {}
    init = (ROOT / "eeops" / "__init__.py").read_text()
    backend = next((line.split("=", 1)[1].strip().strip("\"'")
                    for line in init.splitlines() if line.startswith("__version__")), "?")
    print(f"    frontend/package.json : {fe_src}")
    print(f"    static/version.json   : {fe_built.get('version', 'MISSING')}  (built {fe_built.get('built', '?')})")
    print(f"    eeops/__init__.py     : {backend}")
    if fe_built.get("version") != fe_src:
        sys.exit("\nstatic/ is out of date with frontend/ -- run deploy/01_auto_deploy_sf.sh in CoCo, "
                 "commit ALL changed files (including static/), git pull, and retry.")
    if backend != fe_src:
        sys.exit(f"\nVersion mismatch: frontend {fe_src} vs backend {backend}. "
                 "Re-run deploy/01_auto_deploy_sf.sh (it bumps both).")


def build_layer() -> None:
    step("Packing image layer")
    if not (ROOT / "static" / "index.html").is_file():
        sys.exit("static/index.html missing -- run deploy/01_auto_deploy_sf.sh in CoCo first.")
    check_versions()
    with tarfile.open(LAYER, "w", format=tarfile.PAX_FORMAT) as tf:
        for d in APP_DIRS:
            _add_tree(tf, ROOT / d, f"app/{d}")
        _add_tree(tf, PYDEPS, "opt/pydeps")
    print(f"    {LAYER} ({LAYER.stat().st_size / 1e6:.0f} MB)")


def push(crane: Path, token: str, user: str) -> None:
    def run(*args: str, secret: bool = False) -> None:
        print(f"    $ crane {args[0] + ' ...' if secret else ' '.join(args)}", flush=True)
        subprocess.run([str(crane), *args], check=True)

    step("Logging in to the Snowflake image registry")
    run("auth", "login", REGISTRY, "-u", user, "-p", token, secret=True)
    step(f"Appending layer onto {BASE_IMAGE} (linux/amd64) and pushing")
    run("append", "--platform", "linux/amd64", "-b", BASE_IMAGE, "-f", str(LAYER), "-t", IMAGE)
    step("Setting runtime config (env, cmd)")
    # 2 workers: keep request handlers stateless (no in-process job state that
    # a poll must find -- a second worker won't have it). See AGENTS.md.
    run("mutate", IMAGE,
        "--workdir", "/app",
        "--env", "PYTHONPATH=/app:/opt/pydeps",
        "--env", "PYTHONUNBUFFERED=1",
        "--cmd", "python,-m,uvicorn,api.main:app,--host,0.0.0.0,--port,8080,--workers,2,--proxy-headers")
    step("Verifying pushed image")
    run("config", IMAGE)
    print(f"\nPushed {IMAGE}")


def _load_pat(path: Path) -> tuple[str, str] | None:
    try:
        data = json.loads(path.read_text())
        pat, user = data.get("pat", "").strip(), data.get("user", "").strip()
        return (pat, user) if pat and user else None
    except (OSError, ValueError):
        return None


def get_pat_credentials(*, use_saved: bool = True) -> tuple[str, str]:
    pat = os.environ.get("SNOWFLAKE_PAT", "").strip()
    user = os.environ.get("SNOWFLAKE_REGISTRY_USER", "").strip()
    if pat and user:
        step(f"Using PAT from environment for user {user}")
        return pat, user
    if pat:
        sys.exit("SNOWFLAKE_PAT is set but SNOWFLAKE_REGISTRY_USER is missing "
                 "(use your LOGIN_NAME, e.g. JANE.DOE@CPUC.CA.GOV).")
    for path in PAT_FALLBACKS if use_saved else []:
        saved = _load_pat(path)
        if saved:
            step(f"Using saved PAT for user {saved[1]} (from {path})")
            return saved

    step("No PAT found -- requesting credentials")
    print("\n    The Snowflake image registry requires a Programmatic Access Token (PAT).")
    print("    Session tokens DO NOT work (you'll get a 401).\n")
    print("    Snowsight -> profile icon -> Settings -> Authentication")
    print("    -> Programmatic access tokens -> Generate new token (role CPUC_ED_TITLE20_RL)\n")
    user = input("    Snowflake LOGIN_NAME (your email, e.g. JANE.DOE@CPUC.CA.GOV): ").strip().upper()
    pat = getpass.getpass("    PAT (input hidden): ").strip()
    if not user or not pat:
        sys.exit("Registry user and PAT are required.")
    if input("\n    Save these credentials for next time? [Y/n]: ").strip().lower() in ("", "y", "yes"):
        PAT_CACHE.parent.mkdir(parents=True, exist_ok=True)
        PAT_CACHE.write_text(json.dumps({"pat": pat, "user": user}, indent=2) + "\n")
        try:
            PAT_CACHE.chmod(0o600)
        except OSError:
            pass
        print(f"    Saved credentials to {PAT_CACHE}")
    return pat, user


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--skip-push", action="store_true", help="build the layer only")
    ap.add_argument("--reuse-layer", action="store_true",
                    help="skip wheel download + packing; push the existing .build/layer.tar")
    ap.add_argument("--clear-pat", action="store_true", help="delete saved PAT and prompt for a new one")
    args = ap.parse_args()

    # Only EE Ops' cache is deleted; the other apps' saved PATs are left alone.
    if args.clear_pat and PAT_CACHE.is_file():
        PAT_CACHE.unlink()
        print(f"Deleted {PAT_CACHE}")

    BUILD.mkdir(exist_ok=True)
    if args.reuse_layer and LAYER.exists():
        step(f"Reusing existing layer {LAYER}")
        print("    WARNING: this re-pushes the OLD layer byte-for-byte. Any code pulled since it")
        print("    was packed is NOT included. Only use it to retry a failed push.")
    else:
        install_linux_wheels()
        build_layer()
    if args.skip_push:
        print("\n--skip-push given; not pushing.")
        return
    crane = get_crane()
    pat, user = get_pat_credentials(use_saved=not args.clear_pat)
    push(crane, pat, user)
    print("\nNext: run deploy/03_redeploy_sf.sql in Snowsight, then deploy/04_verify_sf.sql.")


if __name__ == "__main__":
    main()
