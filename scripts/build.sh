#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
APP_NAME="Murmur"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
DEVELOPER_ID="${DEVELOPER_ID:?Set DEVELOPER_ID env var (e.g. 'Developer ID Application: Your Name (TEAMID)')}"

echo "🔨 Building Murmur..."

# Clean build directory
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Build using Swift Package Manager (Universal binary)
cd "$PROJECT_DIR/Murmur"
swift build -c release --arch arm64 --arch x86_64

# Create app bundle structure
echo "📦 Creating app bundle..."
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy executable (universal binary is in apple/Products/Release)
if [ -f ".build/apple/Products/Release/Murmur" ]; then
    cp ".build/apple/Products/Release/Murmur" "$APP_BUNDLE/Contents/MacOS/"
else
    cp ".build/release/Murmur" "$APP_BUNDLE/Contents/MacOS/"
fi

# Copy Info.plist
cp "Sources/Info.plist" "$APP_BUNDLE/Contents/"

# Copy icon if it exists
if [ -f "Sources/Resources/AppIcon.icns" ]; then
    cp "Sources/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/"
fi

# Bundle whisper-cli with all dependencies
WHISPER_DIR="$APP_BUNDLE/Contents/Frameworks/whisper"
WHISPER_SRC="/opt/homebrew/Cellar/whisper-cpp/1.8.2"

if [ -f "$WHISPER_SRC/bin/whisper-cli" ]; then
    echo "📦 Bundling whisper-cli and dependencies..."
    mkdir -p "$WHISPER_DIR"
    
    # Copy whisper-cli
    cp "$WHISPER_SRC/bin/whisper-cli" "$WHISPER_DIR/"
    
    # Copy all required dylibs
    cp "$WHISPER_SRC/libexec/lib/libwhisper.1.8.2.dylib" "$WHISPER_DIR/libwhisper.1.dylib"
    cp "$WHISPER_SRC/libexec/lib/libggml.dylib" "$WHISPER_DIR/"
    cp "$WHISPER_SRC/libexec/lib/libggml-base.dylib" "$WHISPER_DIR/"
    cp "$WHISPER_SRC/libexec/lib/libggml-cpu.dylib" "$WHISPER_DIR/"
    cp "$WHISPER_SRC/libexec/lib/libggml-blas.dylib" "$WHISPER_DIR/"
    cp "$WHISPER_SRC/libexec/lib/libggml-metal.dylib" "$WHISPER_DIR/"
    
    # Copy Metal shader
    if [ -f "$WHISPER_SRC/libexec/lib/ggml-metal.metal" ]; then
        cp "$WHISPER_SRC/libexec/lib/ggml-metal.metal" "$WHISPER_DIR/"
    fi
    if [ -f "$WHISPER_SRC/libexec/lib/default.metallib" ]; then
        cp "$WHISPER_SRC/libexec/lib/default.metallib" "$WHISPER_DIR/"
    fi
    
    # Fix rpaths in whisper-cli to use @executable_path
    echo "🔧 Fixing library paths..."
    install_name_tool -add_rpath @executable_path "$WHISPER_DIR/whisper-cli" 2>/dev/null || true
    install_name_tool -change @rpath/libwhisper.1.dylib @executable_path/libwhisper.1.dylib "$WHISPER_DIR/whisper-cli"
    install_name_tool -change @rpath/libggml.dylib @executable_path/libggml.dylib "$WHISPER_DIR/whisper-cli"
    install_name_tool -change @rpath/libggml-base.dylib @executable_path/libggml-base.dylib "$WHISPER_DIR/whisper-cli"
    install_name_tool -change @rpath/libggml-cpu.dylib @executable_path/libggml-cpu.dylib "$WHISPER_DIR/whisper-cli"
    install_name_tool -change @rpath/libggml-blas.dylib @executable_path/libggml-blas.dylib "$WHISPER_DIR/whisper-cli"
    install_name_tool -change @rpath/libggml-metal.dylib @executable_path/libggml-metal.dylib "$WHISPER_DIR/whisper-cli"
    
    # Fix inter-library dependencies
    for lib in libwhisper.1.dylib libggml.dylib libggml-base.dylib libggml-cpu.dylib libggml-blas.dylib libggml-metal.dylib; do
        if [ -f "$WHISPER_DIR/$lib" ]; then
            # Set the install name to @rpath
            install_name_tool -id "@rpath/$lib" "$WHISPER_DIR/$lib" 2>/dev/null || true
            # Fix references to other libs
            install_name_tool -change @rpath/libggml.dylib @executable_path/libggml.dylib "$WHISPER_DIR/$lib" 2>/dev/null || true
            install_name_tool -change @rpath/libggml-base.dylib @executable_path/libggml-base.dylib "$WHISPER_DIR/$lib" 2>/dev/null || true
            install_name_tool -change @rpath/libggml-cpu.dylib @executable_path/libggml-cpu.dylib "$WHISPER_DIR/$lib" 2>/dev/null || true
            install_name_tool -change @rpath/libggml-blas.dylib @executable_path/libggml-blas.dylib "$WHISPER_DIR/$lib" 2>/dev/null || true
            install_name_tool -change @rpath/libggml-metal.dylib @executable_path/libggml-metal.dylib "$WHISPER_DIR/$lib" 2>/dev/null || true
        fi
    done
    
    chmod +x "$WHISPER_DIR/whisper-cli"
else
    echo "⚠️  whisper-cpp not found at $WHISPER_SRC - will use system whisper"
fi

# Copy whisper model
if [ -f "Sources/Resources/whisper/ggml-base.en.bin" ]; then
    echo "📦 Bundling whisper model..."
    mkdir -p "$APP_BUNDLE/Contents/Resources/whisper"
    cp "Sources/Resources/whisper/ggml-base.en.bin" "$APP_BUNDLE/Contents/Resources/whisper/"
fi

# Create PkgInfo
echo "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

# Sign everything in correct order (inside-out)
# 1. Sign all dylibs first
if [ -d "$WHISPER_DIR" ]; then
    echo "🔏 Signing whisper libraries..."
    for dylib in "$WHISPER_DIR"/*.dylib; do
        if [ -f "$dylib" ]; then
            codesign --force --sign "$DEVELOPER_ID" \
                --options runtime \
                --timestamp \
                "$dylib"
        fi
    done
    
    # 2. Sign whisper-cli
    echo "🔏 Signing whisper-cli..."
    codesign --force --sign "$DEVELOPER_ID" \
        --options runtime \
        --timestamp \
        "$WHISPER_DIR/whisper-cli"
fi

# 3. Sign main executable
echo "🔏 Signing main executable..."
codesign --force --sign "$DEVELOPER_ID" \
    --entitlements "Sources/Murmur.entitlements" \
    --options runtime \
    --timestamp \
    "$APP_BUNDLE/Contents/MacOS/Murmur"

# 4. Sign app bundle
echo "🔏 Signing app bundle..."
codesign --force --sign "$DEVELOPER_ID" \
    --entitlements "Sources/Murmur.entitlements" \
    --options runtime \
    --timestamp \
    "$APP_BUNDLE"

# Verify signature
echo "🔍 Verifying signature..."
codesign --verify --verbose "$APP_BUNDLE"

# Remove quarantine attribute (helps with Gatekeeper on shared copies)
xattr -cr "$APP_BUNDLE" 2>/dev/null || true

echo "✅ Build complete: $APP_BUNDLE"
echo ""
echo "To install, run: cp -r '$APP_BUNDLE' /Applications/"
echo "Or run: open '$APP_BUNDLE'"
echo ""
echo "To create DMG: ./scripts/create-dmg.sh"
