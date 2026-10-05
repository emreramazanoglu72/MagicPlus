#!/bin/bash
#
# Reports every string the app shows that has no Turkish translation.
#
# Uses Xcode's own export rather than a grep over the source: SwiftUI's string literals never
# appear as a call to anything, so nothing short of the compiler can find them all. An earlier
# hand-rolled check counted keys present in the catalog and reported zero problems while 46
# strings were still shipping in English.
#
# Usage: Scripts/check-localization.sh [language]   (default: tr)

set -euo pipefail
cd "$(dirname "$0")/.."

LANGUAGE="${1:-tr}"
EXPORT_DIR=$(mktemp -d)
trap 'rm -rf "$EXPORT_DIR"' EXIT

# Built for both architectures first, and it has to be.
#
# The export links every target in the scheme, including the helper — a command-line tool that
# embeds its Info.plist into the binary with `-sectcreate`, which needs a processed plist per
# architecture. The export does not produce those itself and ignores `ONLY_ACTIVE_ARCH`, so it
# fails on whichever architecture nothing has built yet.
#
# This used to pass `ONLY_ACTIVE_ARCH=YES` and appear to work. It was working on the artefacts a
# previous universal build had left in `DerivedData`: deleting that folder broke it, which is the
# definition of a hidden dependency rather than a build step. One explicit build, and the check is
# self-sufficient.
xcodebuild build \
  -project tabmenu.xcodeproj \
  -scheme tabmenu \
  -destination 'platform=macOS' \
  ONLY_ACTIVE_ARCH=NO >/dev/null 2>&1 \
  || { echo "!! Build failed before the strings could be extracted."; exit 1; }

xcodebuild -exportLocalizations \
  -project tabmenu.xcodeproj \
  -scheme tabmenu \
  -localizationPath "$EXPORT_DIR" \
  -exportLanguage "$LANGUAGE" >/dev/null 2>&1 \
  || { echo "!! Export failed. Run the xcodebuild line by hand to see why."; exit 1; }

python3 - "$EXPORT_DIR/$LANGUAGE.xcloc/Localized Contents/$LANGUAGE.xliff" "$LANGUAGE" <<'PY'
import json, pathlib, sys, xml.etree.ElementTree as ET

ns = {"x": "urn:oasis:names:tc:xliff:document:1.2"}
path, language = sys.argv[1], sys.argv[2]

# Keys the catalogs mark as "do not translate" — names, numbers, separators, placeholders. Xcode
# exports them anyway, with no target, so the flag has to be read from the source of truth or the
# check reports twenty untranslatable strings for ever and stops being read.
untranslatable = set()
for catalog in pathlib.Path(".").glob("**/*.xcstrings"):
    if "Tools/" in str(catalog):
        continue
    for key, entry in json.loads(catalog.read_text()).get("strings", {}).items():
        if entry.get("shouldTranslate") is False:
            untranslatable.add(key)

missing = []
total = 0
for file in ET.parse(path).getroot().findall(".//x:file", ns):
    where = (file.get("original") or "").split("/")[-1]
    for unit in file.findall(".//x:trans-unit", ns):
        key = unit.get("id") or ""
        # Turkish uses only CLDR's "other" plural category, so a missing "one" variant is correct
        # rather than untranslated. Reporting it would train the reader to ignore this check.
        if language == "tr" and key.endswith("|==|plural.one"):
            continue
        if key in untranslatable:
            continue
        total += 1
        target = unit.find("x:target", ns)
        if target is None or not (target.text or "").strip():
            missing.append((where, key))

print(f"{total} strings, {len(missing)} untranslated ({language})")
for where, key in missing:
    print(f"  [{where}] {key[:110]}")
sys.exit(1 if missing else 0)
PY
