"""Load signed exit listings; drop bad signatures."""
from __future__ import annotations

import json
import sys
from pathlib import Path

# Listing verifier from vendor/ (copied from session-router-exits-HOST)
_PACK = Path(__file__).resolve().parents[1] / "vendor"
if str(_PACK) not in sys.path:
    sys.path.insert(0, str(_PACK))
import listing as L  # noqa: E402


def load_board(path: Path) -> list[dict]:
    """path is a JSON file: either one listing doc, or {"listings":[...]} / a JSONL file."""
    text = path.read_text()
    out: list[dict] = []
    if path.suffix == ".jsonl":
        for line in text.splitlines():
            line = line.strip()
            if line:
                out.append(json.loads(line))
    else:
        data = json.loads(text)
        if isinstance(data, list):
            out = data
        elif isinstance(data, dict) and "listings" in data:
            out = data["listings"]
        elif isinstance(data, dict) and "listing" in data:
            out = [data]
        else:
            raise ValueError("unrecognized listings file shape")
    good = []
    for doc in out:
        if L.verify(doc):
            good.append(doc)
        # silently drop bad signatures
    return good


def find_seller(board: list[dict], seller: str) -> dict | None:
    for doc in board:
        if doc.get("listing", {}).get("seller") == seller:
            return doc
    return None
