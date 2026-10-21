import json
import glob
import os
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
INFO_DIR = os.path.join(REPO, 'remote', 'remote-info')
OUT = os.path.join(REPO, 'remote', 'mapping', 'remote-info-index.json')


def parse(path):
    """Parse one remote-info txt.

    Format:
        Scope
        Manufacturer<TAB>Model
        <manufacturer><TAB><model>

        Remotable<TAB>Min<TAB>Max<TAB>Input type<TAB>Output type
        <name><TAB><min><TAB><max><TAB><input><TAB><output>
        ...
    """
    with open(path, 'r', encoding='utf-8', errors='replace') as f:
        lines = f.read().split('\n')

    man = model = None
    remotes = []

    i = 0
    n = len(lines)

    # --- Scope block -------------------------------------------------------
    while i < n and lines[i].strip() != 'Scope':
        i += 1
    i += 1
    if i < n and lines[i].strip() == 'Manufacturer\tModel':
        i += 1
    if i < n:
        parts = lines[i].split('\t')
        if len(parts) >= 2:
            man, model = parts[0].strip(), parts[1].strip()
        i += 1

    # --- Remotable block --------------------------------------------------
    while i < n:
        line = lines[i]
        if line.startswith('Remotable\t'):
            i += 1
            break
        i += 1
    else:
        return man, model, remotes

    while i < n:
        line = lines[i].rstrip('\r')
        if not line.strip():
            i += 1
            continue
        if '\t' not in line:
            # A new section header - the Remotable list ends here.
            break
        parts = line.split('\t')
        remotes.append({
            'name': parts[0].strip(),
            'min': parts[1].strip() if len(parts) > 1 else '',
            'max': parts[2].strip() if len(parts) > 2 else '',
            'input': parts[3].strip() if len(parts) > 3 else '',
            'output': parts[4].strip() if len(parts) > 4 else '',
        })
        i += 1

    return man, model, remotes


def main():
    files = sorted(glob.glob(os.path.join(INFO_DIR, '**', '*.txt'), recursive=True))
    index = {}
    for path in files:
        man, model, remotes = parse(path)
        if not man or not model:
            print('SKIP (no scope): %s' % os.path.relpath(path, REPO))
            continue
        key = '%s\t%s' % (man, model)
        entry = index.setdefault(key, {
            'manufacturer': man,
            'model': model,
            'remotables': [],
            'sources': [],
        })
        seen = {r['name'] for r in entry['remotables']}
        for r in remotes:
            if r['name'] not in seen:
                seen.add(r['name'])
                entry['remotables'].append(r)
        entry['sources'].append(os.path.relpath(path, REPO))

    for key in index:
        index[key]['remotables'].sort(key=lambda r: r['name'].lower())

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, 'w', encoding='utf-8') as f:
        json.dump(index, f, indent=1, ensure_ascii=False)

    total = sum(len(v['remotables']) for v in index.values())
    print('Wrote %s' % os.path.relpath(OUT, REPO))
    print('  %d scopes, %d distinct remotables' % (len(index), total))
    for key in sorted(index):
        print('  %-58s %4d' % (key.replace('\t', ' | '), len(index[key]['remotables'])))


if __name__ == '__main__':
    main()
