#!/usr/bin/env python3
"""Muuntaa purun raakatekstuurit PNG:ksi Blenderia varten.

Blenderissa ei ole PILia, joten muunnos on tehtava ennen kirjaston rakentamista.
Alfa sailyy, koska ilman sita alfamaskatut lehtikortit ovat umpinaisia.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from common import raw_dir_to_png  # noqa: E402


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("directory")
    ap.add_argument("--no-alpha", action="store_true")
    args = ap.parse_args()

    d = Path(args.directory)
    if not d.exists():
        print(f"{d} puuttuu - ei muunnettavaa")
        return 0
    made = raw_dir_to_png(d, keep_alpha=not args.no_alpha)
    print(f"{made} tekstuuria muunnettu PNG:ksi ({d})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
