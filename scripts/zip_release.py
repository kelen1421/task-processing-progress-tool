"""Create standard UTF-8 ZIPs while preserving executable bits, without host metadata."""
import sys
import zipfile
from pathlib import Path

source, destination = map(Path, sys.argv[1:])
with zipfile.ZipFile(destination, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
    for entry in [source, *sorted(source.rglob('*'))]:
        if entry.is_symlink():
            raise ValueError(f'Release package must not reference outside files: {entry}')
        if entry.name == '.DS_Store':
            continue
        archive.write(entry, entry.relative_to(source.parent).as_posix())
