#!/usr/bin/env python3
"""Restore exact captured font files without overwriting different local fonts."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    if (root / '.local/preserve-current-host').exists():
        print('Source Mac: current installed fonts left unchanged.')
        return
    records = json.loads((root / 'metadata/original-configs.json').read_text())
    destination = Path.home() / 'Library/Fonts'
    selected = [r for r in records if r['repository_path'].startswith('fonts/files/')]
    for record in selected:
        source = root / record['repository_path']
        if digest(source) != record['sha256']:
            raise SystemExit('Font snapshot checksum mismatch: ' + source.name)
        target = destination / source.name
        if target.exists() or target.is_symlink():
            if target.is_file() and digest(target) == record['sha256']:
                print('Existing font matches: ' + source.name)
                continue
            raise SystemExit('Different local font preserved; resolve manually: ' + str(target))
        print(('Would restore font: ' if args.dry_run else 'Restoring font: ') + source.name)
        if not args.dry_run:
            destination.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)


if __name__ == '__main__':
    main()

