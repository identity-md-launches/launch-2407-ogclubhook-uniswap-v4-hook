#!/usr/bin/env python3
"""Export the two deployment ABIs from a successful root forge build. No network required."""
import json
from pathlib import Path

root = Path(__file__).resolve().parent.parent
for name in ("OGClubHook", "OGClubHookDeployer"):
    artifact = json.loads((root / "out" / f"{name}.sol" / f"{name}.json").read_text())
    target = root / "abi" / f"{name}.json"
    target.parent.mkdir(exist_ok=True)
    target.write_text(json.dumps(artifact["abi"], indent=2) + "\n")
    print(target.relative_to(root))
