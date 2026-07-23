#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="${CAIRN_OUTPUT_DIR:-$REPO_ROOT/.build/distribution}"

# Release bundles default to the vendored static, network-off libgit2 so the
# shipped app carries no SSH/TLS stack (the audit-tool security story). Requires
# scripts/vendor-libgit2.sh to have staged Vendor/libgit2 first; override with
# CAIRN_LIBGIT2=brew only for local dev bundles.
if [[ -z "${CAIRN_LIBGIT2:-}" ]]; then
    if [[ -f "$REPO_ROOT/Vendor/libgit2/lib/libgit2.a" ]]; then
        export CAIRN_LIBGIT2=vendored
    else
        echo "make-app: Vendor/libgit2 missing; run scripts/vendor-libgit2.sh for a" >&2
        echo "          static network-off release bundle, or set CAIRN_LIBGIT2=brew." >&2
        exit 1
    fi
fi
SIGNING_IDENTITY="${CAIRN_CODESIGN_IDENTITY:--}"
BUNDLE_IDENTIFIER="${CAIRN_BUNDLE_IDENTIFIER:-dev.cairn.Cairn}"
NOTARY_PROFILE="${CAIRN_NOTARY_PROFILE:-}"
APPLE_ID="${CAIRN_NOTARY_APPLE_ID:-}"
TEAM_ID="${CAIRN_NOTARY_TEAM_ID:-}"
PASSWORD="${CAIRN_NOTARY_PASSWORD:-}"

usage() {
    echo "usage: $0 [--output DIR] [--signing-identity IDENTITY] [--bundle-id ID]"
    echo "          [--notary-profile PROFILE | --apple-id ID --team-id ID --password VALUE]"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output) OUTPUT_DIR="$2"; shift 2 ;;
        --signing-identity) SIGNING_IDENTITY="$2"; shift 2 ;;
        --bundle-id) BUNDLE_IDENTIFIER="$2"; shift 2 ;;
        --notary-profile) NOTARY_PROFILE="$2"; shift 2 ;;
        --apple-id) APPLE_ID="$2"; shift 2 ;;
        --team-id) TEAM_ID="$2"; shift 2 ;;
        --password) PASSWORD="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

if [[ -n "$NOTARY_PROFILE" && ( -n "$APPLE_ID" || -n "$TEAM_ID" || -n "$PASSWORD" ) ]]; then
    echo "choose a notary profile or Apple ID credentials, not both" >&2
    exit 2
fi
if [[ -z "$NOTARY_PROFILE" && ( -n "$APPLE_ID" || -n "$TEAM_ID" || -n "$PASSWORD" ) ]] \
   && [[ -z "$APPLE_ID" || -z "$TEAM_ID" || -z "$PASSWORD" ]]; then
    echo "Apple ID notarization requires --apple-id, --team-id, and --password" >&2
    exit 2
fi

cd "$REPO_ROOT"
mkdir -p "$OUTPUT_DIR"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$REPO_ROOT/.build/clang-module-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$REPO_ROOT/.build/swift-module-cache}"

swift_options=()
if [[ -n "${CODEX_SANDBOX:-}" ]]; then
    swift_options=(
        --disable-sandbox
        --cache-path .build/cache
        --config-path .build/config
        --security-path .build/security
        --manifest-cache local
    )
fi

swift build -c release --product codeinsight-app \
    ${swift_options[@]+"${swift_options[@]}"}
BIN_DIR="$(swift build -c release --show-bin-path \
    ${swift_options[@]+"${swift_options[@]}"})"
SOURCE_BINARY="$BIN_DIR/codeinsight-app"
test -x "$SOURCE_BINARY"

APP="$OUTPUT_DIR/Cairn.app"
ZIP="$OUTPUT_DIR/Cairn.zip"
rm -rf "$APP"
rm -f "$ZIP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$SOURCE_BINARY" "$APP/Contents/MacOS/codeinsight-app"
chmod 755 "$APP/Contents/MacOS/codeinsight-app"

bundle_homebrew_dylibs() {
    local main_binary="$1"
    local frameworks="$APP/Contents/Frameworks"
    local -a queue=("$main_binary")
    local index=0
    mkdir -p "$frameworks"
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$main_binary"

    while (( index < ${#queue[@]} )); do
        local binary="${queue[$index]}"
        index=$((index + 1))
        while IFS= read -r dependency; do
            local name destination
            name="$(basename "$dependency")"
            destination="$frameworks/$name"
            if [[ ! -e "$destination" ]]; then
                cp "$dependency" "$destination"
                chmod u+w "$destination"
                install_name_tool -id "@rpath/$name" "$destination"
                queue+=("$destination")
            fi
            install_name_tool -change "$dependency" "@rpath/$name" "$binary"
        done < <(otool -L "$binary" | awk 'NR > 1 { print $1 }' \
            | grep '^/opt/homebrew/' || true)
    done
}

if otool -L "$APP/Contents/MacOS/codeinsight-app" \
    | grep -q '^[[:space:]]*/opt/homebrew/'; then
    echo "Bundling Homebrew libgit2 dylibs (vendored static fallback)."
    bundle_homebrew_dylibs "$APP/Contents/MacOS/codeinsight-app"
fi

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Cairn</string>
    <key>CFBundleDisplayName</key>
    <string>Cairn</string>
    <key>CFBundleExecutable</key>
    <string>codeinsight-app</string>
    <!-- Placeholder: replace with the final reverse-DNS identifier before release. -->
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_IDENTIFIER</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleShortVersionString</key>
    <string>${CAIRN_VERSION:-0.1.0}</string>
    <key>CFBundleVersion</key>
    <string>${CAIRN_BUILD_VERSION:-1}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

plutil -lint "$APP/Contents/Info.plist"

sign_args=(--force --sign "$SIGNING_IDENTITY" --options runtime)
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    sign_args+=(--timestamp=none)
else
    sign_args+=(--timestamp)
fi
if [[ -d "$APP/Contents/Frameworks" ]]; then
    while IFS= read -r -d '' library; do
        codesign "${sign_args[@]}" "$library"
    done < <(find "$APP/Contents/Frameworks" -type f -name '*.dylib' -print0)
fi
app_sign_args=("${sign_args[@]}")
ADHOC_ENTITLEMENTS="$OUTPUT_DIR/.Cairn-ad-hoc.entitlements"
if [[ "$SIGNING_IDENTITY" == "-" && -d "$APP/Contents/Frameworks" ]]; then
    cat > "$ADHOC_ENTITLEMENTS" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.cs.disable-library-validation</key>
    <true/>
</dict>
</plist>
EOF
    app_sign_args+=(--entitlements "$ADHOC_ENTITLEMENTS")
fi
codesign "${app_sign_args[@]}" "$APP"
rm -f "$ADHOC_ENTITLEMENTS"
codesign --verify --strict --verbose=2 "$APP"

ditto -c -k --keepParent "$APP" "$ZIP"

notary_args=()
if [[ -n "$NOTARY_PROFILE" ]]; then
    notary_args=(--keychain-profile "$NOTARY_PROFILE")
elif [[ -n "$APPLE_ID" ]]; then
    notary_args=(--apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$PASSWORD")
fi

if [[ ${#notary_args[@]} -gt 0 ]]; then
    if [[ "$SIGNING_IDENTITY" == "-" ]]; then
        echo "notarization requires a Developer ID signing identity" >&2
        exit 2
    fi
    xcrun notarytool submit "$ZIP" --wait "${notary_args[@]}"
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
else
    echo "No notarization credentials; completed ad-hoc signed bundle flow."
fi

echo "app: $APP"
echo "zip: $ZIP"
