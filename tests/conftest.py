"""Make the repo root importable (api/, eeops/) when pytest runs from anywhere."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
