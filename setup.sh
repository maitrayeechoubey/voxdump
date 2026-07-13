#!/usr/bin/env bash
# FocusFlow – one-shot project setup
# Run: bash setup.sh
set -e

echo "→ Generating Xcode project..."
xcodegen generate

echo "→ Opening in Xcode..."
open Voxdump.xcodeproj

echo ""
echo "✓ Done. Two things to do in Xcode before building:"
echo "  1. Signing: FocusFlow target → Signing & Capabilities → Team (choose your Apple ID)"
echo "  2. App icon: Assets.xcassets → AppIcon (drag a 1024×1024 PNG)"
echo ""
echo "Simulator: Cmd+R (text input mode auto-enabled)"
echo "iPhone:    plug in → trust → Cmd+R (voice + Apple Intelligence)"
