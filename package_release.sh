#!/bin/bash
# Package PocketQuake release into a zip file.
# Usage: ./package_release.sh [VERSION]
# If VERSION is provided, updates core.json before packaging.
# If omitted, uses the version already in core.json.

set -e

if [ -n "$1" ]; then
    VERSION="$1"
    # Update version and date in core.json
    python3 -c "
import json, datetime
with open('core.json', 'r') as f:
    data = json.load(f)
data['core']['metadata']['version'] = '$VERSION'
data['core']['metadata']['date_release'] = datetime.date.today().isoformat()
with open('core.json', 'w') as f:
    json.dump(data, f, indent=4)
    f.write('\n')
"
    echo "Updated core.json: version=${VERSION}, date=$(date +%Y-%m-%d)"
else
    VERSION=$(python3 -c "import json; print(json.load(open('core.json'))['core']['metadata']['version'])")
fi

ZIP_NAME="PocketQuake-v${VERSION}.zip"

echo "Packaging PocketQuake v${VERSION}..."

# Build the release directory
make package

# Create zip from release directory contents (no release/ prefix)
cd release
zip -r "../${ZIP_NAME}" .
cd ..

echo ""
echo "Release packaged: ${ZIP_NAME}"
ls -lh "${ZIP_NAME}"
