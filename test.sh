#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

# Command Line Tools without Xcode keep the Testing module outside the default search path.
flags=()
if [[ "$(xcode-select -p)" == /Library/Developer/CommandLineTools ]]; then
    frameworks=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
    flags=(
        -Xswiftc -F -Xswiftc "$frameworks"
        -Xlinker -F -Xlinker "$frameworks"
        -Xlinker -rpath -Xlinker "$frameworks"
    )
fi
swift test ${flags[@]+"${flags[@]}"}
