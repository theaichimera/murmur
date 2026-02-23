#!/bin/bash
# Build, sign, and deploy Murmur to /Applications
set -e

cd "$(dirname "$0")/Murmur"

echo "Building Murmur (release)..."
swift build -c release 2>&1 | tail -3

echo "Stopping Murmur..."
killall Murmur 2>/dev/null || true
sleep 1

echo "Deploying to /Applications..."
cp .build/release/Murmur /Applications/Murmur.app/Contents/MacOS/Murmur

echo "Code-signing..."
codesign --force --sign "Apple Development: David Schwartz (59WWP328GZ)" --deep /Applications/Murmur.app

echo "Launching Murmur..."
open /Applications/Murmur.app

echo "Done ✓"
