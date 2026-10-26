#!/usr/bin/env python3
"""Create ignored, portable copies for a new Mac without editing originals."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess


def parse_jsonc(text):
    out = []
    quoted = escaped = False
    i = 0
    while i < len(text):
        c = text[i]
        if quoted:
            out.append(c)
            if escaped:
                escaped = False
            elif c == '\\':
                escaped = True
            elif c == '"':
                quoted = False
            i += 1
        elif c == '"':
            quoted = True
            out.append(c)
            i += 1
        elif text.startswith('//', i):
            end = text.find('\n', i)
            i = len(text) if end < 0 else end
        elif text.startswith('/*', i):
            end = text.find('*/', i + 2)
            if end < 0:
                raise ValueError('Unterminated JSONC comment')
            out.append(' ')
            i = end + 2
        else:
            out.append(c)
            i += 1
    text = ''.join(out)
    out = []
    quoted = escaped = False
    for i, c in enumerate(text):
        if quoted:
            out.append(c)
            if escaped:
                escaped = False
            elif c == '\\':
                escaped = True
            elif c == '"':
                quoted = False
        elif c == '"':
            quoted = True
            out.append(c)
        elif c == ',':
            j = i + 1
            while j < len(text) and text[j].isspace():
                j += 1
            if j >= len(text) or text[j] not in '}]':
                out.append(c)
        else:
            out.append(c)
    return json.loads(''.join(out))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    if (root / '.local/preserve-current-host').exists():
        print('Source Mac: original settings remain byte-for-byte unchanged.')
        return
    origin = json.loads((root / 'metadata/source-host.json').read_text())
    home = str(Path.home())
    brew = shutil.which('brew')
    if not brew:
        raise SystemExit('Homebrew is required before preparing another Mac.')
    prefix = subprocess.check_output([brew, '--prefix'], text=True).strip()
    files = {}
    for name in ['.zshrc', '.zprofile']:
        text = (root / 'zsh' / name).read_text()
        text = text.replace(origin['source_home'], home)
        text = text.replace(origin['brew_prefix'], prefix)
        text = text.replace('/usr/local/mysql-9.6.0-macos15-arm64/bin', prefix + '/opt/mysql-client/bin')
        text = text.replace('eval "$(but completions zsh)"',
                            'if command -v but >/dev/null 2>&1; then\n  eval "$(but completions zsh)"\nfi')
        files['.local/zsh/' + name] = text
    settings = parse_jsonc((root / 'zed/settings.json').read_text())
    extensions = json.loads((root / 'zed/extensions.json').read_text())
    automatic = settings.setdefault('auto_install_extensions', {})
    for extension in extensions:
        automatic.setdefault(extension, True)
    files['.local/zed/settings.json'] = json.dumps(settings, indent=2, ensure_ascii=False) + '\n'
    aliases = {'zsh/.zshrc': '.local/zsh/.zshrc', 'zsh/.zprofile': '.local/zsh/.zprofile',
               'zed/settings.json': '.local/zed/settings.json'}
    manifest = []
    for line in (root / 'links.tsv').read_text().splitlines():
        if not line or line.startswith('#'):
            manifest.append(line)
            continue
        source, destination = line.split('\t')
        manifest.append(aliases.get(source, source) + '\t' + destination)
    files['.local/links.tsv'] = '\n'.join(manifest) + '\n'
    for relative, text in files.items():
        print(('Would prepare ' if args.dry_run else 'Prepared ') + relative)
        if not args.dry_run:
            target = root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(text)
    print('Original configurations retained; new-Mac overlays use its home directory and Homebrew prefix.')
    print('Zed will restore the captured extension IDs when launched; versions may be newer.')


if __name__ == '__main__':
    main()

