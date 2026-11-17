#!/bin/zsh
# Prints extra `swift build` arguments needed on this machine.
#
# The macOS 27 SDK implements SwiftUI's @State as a macro whose compiler plugin ships only
# with full Xcode. With Command Line Tools alone, build against the newest pre-27 SDK
# instead (the app targets macOS 14, so nothing is lost).
if xcode-select -p 2>/dev/null | grep -q "Xcode"; then
  exit 0
fi
sdk=$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX(1[4-9]|2[0-6]).*.sdk 2>/dev/null | sort -V | tail -1)
[[ -n "$sdk" ]] && echo "--sdk $sdk"
exit 0
