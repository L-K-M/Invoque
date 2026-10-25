#!/usr/bin/env python3
"""Collect the pinned calculator dependencies' license texts from Cargo metadata."""

import json
from pathlib import Path
import sys


def notices(documents):
    sections = ["Invoque's calculator uses Numbat (https://github.com/sharkdp/numbat).\n"
                "Rust standard library notices are in Rust-Licenses.html.\n"]
    packages = {}
    for metadata in documents:
        nodes = {node["id"]: node for node in metadata["resolve"]["nodes"]}
        reachable = set()
        pending = list(metadata["workspace_members"])
        while pending:
            identifier = pending.pop()
            if identifier in reachable:
                continue
            reachable.add(identifier)
            pending.extend(dependency["pkg"] for dependency in nodes[identifier]["deps"])
        packages.update((package["id"], package) for package in metadata["packages"]
                        if package["id"] in reachable)
    for package in sorted(packages.values(), key=lambda p: (p["name"], p["version"])):
        if package["source"] is None:
            continue
        root = Path(package["manifest_path"]).parent
        paths = set()
        if package["license_file"]:
            paths.add(root / package["license_file"])
        for pattern in ("LICENSE*", "LICENCE*", "COPYING*", "UNLICENSE*", "NOTICE*", "license*", "licenses/*"):
            paths.update(path for path in root.glob(pattern) if path.is_file())
        # Numbat's published crates omit the repository's shared license file.
        if package["name"] in ("numbat", "numbat-exchange-rates"):
            paths.add(Path(__file__).resolve().parents[1] / "Numbat/LICENSE-MIT")
        # This dual-licensed crate publishes neither license text; choose Apache-2.0.
        if package["name"] == "pretty_dtoa" and package["license"] == "MIT OR Apache-2.0":
            paths.add(Path(__file__).resolve().parents[1] / "Numbat/LICENSE-APACHE")
        if not paths:
            raise ValueError(f"No license text for {package['name']} {package['version']}")
        sections.append(f"\n{'=' * 72}\n{package['name']} {package['version']}\n"
                        f"{package['license']}\n{' · '.join(package['authors'])}\n")
        for path in sorted(paths):
            sections.append(f"\n{path.name}\n\n{path.read_text(encoding='utf-8')}\n")
    return "".join(sections)


if __name__ == "__main__":
    documents = [json.loads(Path(path).read_text(encoding="utf-8")) for path in sys.argv[2:]]
    Path(sys.argv[1]).write_text(notices(documents), encoding="utf-8")
