#!/bin/bash
# Build et empaquetage locaux sans Xcode (CommandLineTools Swift 6.4+ + MacOSX26.5.sdk).
# Produit dist/Escale.app (signe ad hoc) et dist/Escale-<version>.dmg sans modifier les fichiers suivis.
# Usage : scripts/package-local.sh [--version X.Y.Z] [--skip-dmg]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="1.2.0-ai"
SKIP_DMG=0
while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION="$2"; shift 2 ;;
    --skip-dmg) SKIP_DMG=1; shift ;;
    -h|--help) sed -n '2,4p' "$0"; exit 0 ;;
    *) echo "Option inconnue : $1" >&2; exit 64 ;;
  esac
done

BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
SDK_26="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
if [ ! -d "$SDK_26" ]; then
  SDK_26="$(find /Library/Developer/CommandLineTools/SDKs -maxdepth 1 -name 'MacOSX26*.sdk' | head -n 1 || true)"
fi
[ -d "$SDK_26" ] || { echo "SDK MacOSX26.x introuvable dans /Library/Developer/CommandLineTools/SDKs" >&2; exit 2; }

WORK="$ROOT/build/local-pkg"
DEPS="$WORK/Deps"
SRC="$WORK/Sources/Escale"
DIST="$ROOT/dist"
APP="$DIST/Escale.app"
DMG="$DIST/Escale-$VERSION.dmg"

step() { echo; echo "==> $*"; }

step "Preparation du workspace SwiftPM local ($WORK)"
mkdir -p "$WORK/Sources" "$DEPS" "$DIST"

# Bootstrap SwiftTerm 1.99.3 avec repli MacOSX26.5 (ByteRunScanner #if compiler(>=6.4) -> #if false).
if [ ! -f "$DEPS/SwiftTerm/Package.swift" ]; then
  TMP_RESOLVE="$WORK/resolve-tmp"
  rm -rf "$TMP_RESOLVE"
  mkdir -p "$TMP_RESOLVE/Sources/Stub"
  echo 'print("stub")' > "$TMP_RESOLVE/Sources/Stub/main.swift"
  cat > "$TMP_RESOLVE/Package.swift" <<'SWIFT'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "Stub",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.99.3"),
    ],
    targets: [
        .executableTarget(name: "Stub", dependencies: ["SwiftTerm"])
    ]
)
SWIFT
  (cd "$TMP_RESOLVE" && swift package resolve)
  cp -R "$TMP_RESOLVE/.build/checkouts/SwiftTerm" "$DEPS/SwiftTerm"
  chmod -R u+w "$DEPS/SwiftTerm"
  rm -rf "$TMP_RESOLVE"
fi

python3 - "$DEPS/SwiftTerm/Sources/SwiftTerm/ByteRunScanner.swift" <<'PY'
import sys
p = sys.argv[1]
lines = open(p, encoding="utf-8").read().splitlines(True)
out = [
    ("#if false // RawSpan.load requires MacOSX27.2.sdk\n" if l.strip() == "#if compiler(>=6.4)" and i > 100 else l)
    for i, l in enumerate(lines, 1)
]
open(p, "w", encoding="utf-8").write("".join(out))
PY

rm -rf "$SRC"
mkdir -p "$SRC"
for item in "$ROOT/Escale/"*; do
  ln -s "$item" "$SRC/$(basename "$item")"
done

# Compatibilite ToolbarContentBuilder (>=11 elements) pour MacOSX26.5.sdk.
cat > "$SRC/ToolbarBuilderCompat.swift" <<'SWIFT'
import SwiftUI

extension ToolbarContentBuilder {
    static func buildBlock<
        C0: CustomizableToolbarContent, C1: CustomizableToolbarContent,
        C2: CustomizableToolbarContent, C3: CustomizableToolbarContent,
        C4: CustomizableToolbarContent, C5: CustomizableToolbarContent,
        C6: CustomizableToolbarContent, C7: CustomizableToolbarContent,
        C8: CustomizableToolbarContent, C9: CustomizableToolbarContent,
        C10: CustomizableToolbarContent
    >(
        _ c0: C0, _ c1: C1, _ c2: C2, _ c3: C3, _ c4: C4,
        _ c5: C5, _ c6: C6, _ c7: C7, _ c8: C8, _ c9: C9,
        _ c10: C10
    ) -> some CustomizableToolbarContent {
        buildBlock(buildBlock(c0, c1, c2, c3, c4, c5, c6, c7, c8, c9), c10)
    }

    static func buildBlock<
        C0: CustomizableToolbarContent, C1: CustomizableToolbarContent,
        C2: CustomizableToolbarContent, C3: CustomizableToolbarContent,
        C4: CustomizableToolbarContent, C5: CustomizableToolbarContent,
        C6: CustomizableToolbarContent, C7: CustomizableToolbarContent,
        C8: CustomizableToolbarContent, C9: CustomizableToolbarContent,
        C10: CustomizableToolbarContent, C11: CustomizableToolbarContent
    >(
        _ c0: C0, _ c1: C1, _ c2: C2, _ c3: C3, _ c4: C4,
        _ c5: C5, _ c6: C6, _ c7: C7, _ c8: C8, _ c9: C9,
        _ c10: C10, _ c11: C11
    ) -> some CustomizableToolbarContent {
        buildBlock(buildBlock(c0, c1, c2, c3, c4, c5, c6, c7, c8, c9), buildBlock(c10, c11))
    }
}
SWIFT

cat > "$WORK/Package.swift" <<SWIFT
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Escale",
    defaultLocalization: "fr",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "$ROOT/Packages/EscaleCore"),
        .package(path: "Deps/SwiftTerm"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        .executableTarget(
            name: "Escale",
            dependencies: [
                .product(name: "EscaleCore", package: "EscaleCore"),
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            exclude: [
                "Info.plist",
                "Escale.entitlements",
                "Resources",
                "AppIcon.icon",
            ],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        )
    ]
)
SWIFT

step "Compilation Release (SDK: $(basename "$SDK_26"))"
(cd "$WORK" && SDKROOT="$SDK_26" swift build -c release)

BIN="$WORK/.build/release/Escale"
SPK_SRC="$(find "$WORK/.build/artifacts" -name "Sparkle.framework" -path "*macos-*" | head -n 1)"
[ -x "$BIN" ] || { echo "Binaire introuvable : $BIN" >&2; exit 3; }
[ -d "$SPK_SRC" ] || { echo "Sparkle.framework introuvable" >&2; exit 3; }

step "Assemblage de $APP (version $VERSION, build $BUILD)"
rm -rf "$APP"
C="$APP/Contents"
mkdir -p "$C/MacOS" "$C/Frameworks" "$C/Helpers" "$C/Resources/en.lproj" "$C/Resources/fr.lproj"

cp "$BIN" "$C/MacOS/Escale"
chmod 755 "$C/MacOS/Escale"
install_name_tool -delete_rpath /Library/Developer/CommandLineTools/usr/lib/swift-6.2/macosx "$C/MacOS/Escale" 2>/dev/null || true

ditto "$SPK_SRC" "$C/Frameworks/Sparkle.framework"

if [ -f "/Applications/Escale.app/Contents/Resources/AppIcon.icns" ]; then
  cp "/Applications/Escale.app/Contents/Resources/AppIcon.icns" "$C/Resources/AppIcon.icns"
fi
if [ -f "/Applications/Escale.app/Contents/Resources/Assets.car" ]; then
  cp "/Applications/Escale.app/Contents/Resources/Assets.car" "$C/Resources/Assets.car"
fi

python3 - "$ROOT/Escale/Resources/Localizable.xcstrings" "$C/Resources" <<'PY'
import json, os, plistlib, sys
src, res_dir = sys.argv[1], sys.argv[2]
data = json.load(open(src, encoding="utf-8"))
fr_map, en_map = {}, {}
for k, v in data.get("strings", {}).items():
    locs = v.get("localizations", {})
    fr_map[k] = locs.get("fr", {}).get("stringUnit", {}).get("value", k)
    en_map[k] = locs.get("en", {}).get("stringUnit", {}).get("value", k)
for lang, mapping in [("fr", fr_map), ("en", en_map)]:
    p = os.path.join(res_dir, f"{lang}.lproj", "Localizable.strings")
    with open(p, "wb") as f:
        plistlib.dump(mapping, f, fmt=plistlib.FMT_BINARY)
print(f"Localizable.strings: {len(fr_map)} fr + {len(en_map)} en")
PY

python3 - "$ROOT/Escale/Info.plist" "$C/Info.plist" "$VERSION" "$BUILD" <<'PY'
import plistlib, sys
src, dst, version, build = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
with open(src, "rb") as f:
    pl = plistlib.load(f)
subs = {
    "$(DEVELOPMENT_LANGUAGE)": "fr",
    "$(EXECUTABLE_NAME)": "Escale",
    "$(PRODUCT_BUNDLE_IDENTIFIER)": "com.attila-krb.Escale",
    "$(PRODUCT_NAME)": "Escale",
    "$(MARKETING_VERSION)": version,
    "$(CURRENT_PROJECT_VERSION)": build,
    "$(ESCALE_FEED_URL)": "",
}
for k, v in list(pl.items()):
    if isinstance(v, str) and v in subs:
        pl[k] = subs[v]
pl["CFBundleIconFile"] = "AppIcon"
pl["CFBundleIconName"] = "AppIcon"
pl["CFBundleSupportedPlatforms"] = ["MacOSX"]
pl["LSMinimumSystemVersion"] = "15.0"
with open(dst, "wb") as f:
    plistlib.dump(pl, f, fmt=plistlib.FMT_XML)
PY
printf "APPL????" > "$C/PkgInfo"

step "Serveur X11 integre"
"$ROOT/scripts/x11-bundle.sh" --install "$C/Helpers" --sign -

step "Signature ad hoc et verification"
SPK="$C/Frameworks/Sparkle.framework/Versions/B"
for x in "$SPK/XPCServices/Installer.xpc" "$SPK/XPCServices/Downloader.xpc" "$SPK/Autoupdate" "$SPK/Updater.app"; do
  [ -e "$x" ] && codesign --force --sign - --preserve-metadata=entitlements "$x"
done
codesign --force --sign - "$C/Frameworks/Sparkle.framework"
codesign --force --sign - --entitlements "$ROOT/Escale/Escale.entitlements" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

if [ "$SKIP_DMG" = 0 ]; then
  step "Creation du DMG : $DMG"
  STAGE="$WORK/dmg-stage"
  rm -rf "$STAGE" "$DMG"
  mkdir -p "$STAGE"
  ditto "$APP" "$STAGE/Escale.app"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "Escale" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
  ls -lh "$DMG"
fi

step "Termine : $APP"
