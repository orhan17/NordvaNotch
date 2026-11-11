#!/bin/bash
# Builds build/NordvaNotch.app.
#   --install  also copies it to /Applications and launches it
#   --release  builds a universal app (Apple Silicon + Intel) and packs it into
#              build/NordvaNotch.zip and build/NordvaNotch.dmg
set -euo pipefail
cd "$(dirname "$0")"

mode="${1:-}"
app=build/NordvaNotch.app
products=(NordvaNotch notch-hook)
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

if [[ "$mode" == "--release" ]]; then
    triples=(arm64-apple-macosx13.0 x86_64-apple-macosx13.0)
    # One scratch folder per triple: a shared .build keeps one cached build plan, and switching
    # triples in it fails with "command ... not registered".
    for triple in "${triples[@]}"; do
        swift build -c release --triple "$triple" --scratch-path ".build/universal/$triple"
    done
    for product in "${products[@]}"; do
        slices=()
        for triple in "${triples[@]}"; do
            slices+=("$(swift build -c release --triple "$triple" --scratch-path ".build/universal/$triple" --show-bin-path)/$product")
        done
        lipo -create -output "$app/Contents/MacOS/$product" "${slices[@]}"
    done
else
    swift build -c release
    bin="$(swift build -c release --show-bin-path)"
    for product in "${products[@]}"; do
        cp "$bin/$product" "$app/Contents/MacOS/"
    done
fi
cp Resources/Info.plist "$app/Contents/"
cp Resources/AppIcon.icns "$app/Contents/Resources/"

# An ad-hoc signature's requirement is its cdhash, so every rebuild would look like a new app
# to macOS (login item, notifications). Pinning the requirement to the bundle id keeps them.
codesign --force --sign - -i io.github.orhan17.NordvaNotch.hook -r '=designated => identifier "io.github.orhan17.NordvaNotch.hook"' "$app/Contents/MacOS/notch-hook"
codesign --force --sign - -r '=designated => identifier "io.github.orhan17.NordvaNotch"' "$app"
echo "built: $app"

if [[ "$mode" == "--release" ]]; then
    rm -f build/NordvaNotch.zip build/NordvaNotch.dmg
    ditto -c -k --keepParent "$app" build/NordvaNotch.zip
    echo "packed: build/NordvaNotch.zip"

    stage=build/dmg
    rm -rf "$stage"
    mkdir -p "$stage"
    cp -R "$app" "$stage/"
    ln -s /Applications "$stage/Applications"
    hdiutil create -quiet -volname NordvaNotch -srcfolder "$stage" -fs HFS+ -format UDZO -ov build/NordvaNotch.dmg
    rm -rf "$stage"
    echo "packed: build/NordvaNotch.dmg"
fi

if [[ "$mode" == "--install" ]]; then
    osascript -e 'quit app "NordvaNotch"' 2>/dev/null || true
    # `quit` returns immediately; opening the new copy before the old one exits fails with -600.
    for _ in {1..50}; do
        pgrep -xq NordvaNotch || break
        sleep 0.1
    done
    pkill -x NordvaNotch 2>/dev/null || true
    # Copy first, then swap: Claude Code may run the hook helper at any moment.
    rm -rf /Applications/.NordvaNotch.app.new
    cp -R "$app" /Applications/.NordvaNotch.app.new
    rm -rf /Applications/NordvaNotch.app
    mv /Applications/.NordvaNotch.app.new /Applications/NordvaNotch.app
    open /Applications/NordvaNotch.app
    echo "installed and launched: /Applications/NordvaNotch.app"
fi
