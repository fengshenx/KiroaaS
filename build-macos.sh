#!/bin/bash
set -e

echo "=== KiroaaS macOS Build Script ==="

# Check prerequisites
echo "Checking prerequisites..."

if ! command -v rustc &> /dev/null; then
    echo "Error: Rust not installed. Run:"
    echo "  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
    exit 1
fi

if ! command -v node &> /dev/null; then
    echo "Error: Node.js not installed"
    exit 1
fi

if ! command -v python3 &> /dev/null; then
    echo "Error: Python3 not installed"
    exit 1
fi

echo "Prerequisites OK"

# Set up PATH: miniconda3 (Python), cargo, nvm node
export PATH="/Users/mxwu/miniconda3/bin:$HOME/.cargo/bin:$HOME/.nvm/versions/node/v22.22.0/bin:$PATH"

# Install Node dependencies
echo "Installing Node dependencies..."
npm install

# Install Python dependencies
echo "Installing Python dependencies..."
cd python-backend
pip3 install -r requirements.txt
pip3 install pyinstaller
cd ..

# Build Python backend
echo "Building Python backend..."
cd python-backend/build
python3 build.py
cd ../..

# Copy to Tauri resources (compressed to avoid Tauri bundling issues with .so files)
echo "Packaging Python backend..."
rm -rf src-tauri/resources/kiro-gateway
mkdir -p src-tauri/resources

# Sign all native binaries in the Python backend before tarring
echo "Signing Python backend binaries..."
SIGN_IDENTITY="Developer ID Application: Mingxi Wu (65B2283FZJ)"
find python-backend/build/dist/kiro-gateway -type f \( -name "*.so" -o -name "*.dylib" -o -type f -perm +111 \) | while read bin; do
    codesign --force --sign "$SIGN_IDENTITY" --timestamp --options runtime "$bin" 2>/dev/null || true
done

cd python-backend/build/dist
tar czf ../../../src-tauri/resources/kiro-gateway.tar.gz kiro-gateway
cd ../../..

# Workaround: macOS 15+ removed xattr -r flag, but Tauri 1.x uses `xattr -cr` internally
XATTR_SHIM_DIR=$(mktemp -d)
cat > "$XATTR_SHIM_DIR/xattr" << 'SHIM'
#!/bin/bash
if [[ "$*" == *-*r* ]]; then
  find "${@: -1}" -exec /usr/bin/xattr -c {} \; 2>/dev/null
  exit 0
fi
/usr/bin/xattr "$@"
SHIM
chmod +x "$XATTR_SHIM_DIR/xattr"
export PATH="$XATTR_SHIM_DIR:$PATH"

# Build Tauri app
echo "Building macOS app..."
# export TAURI_PRIVATE_KEY=$(cat ~/.tauri/kiroaas.key)
# export TAURI_KEY_PASSWORD=""
export TAURI_SIGNING_IDENTITY="Developer ID Application: Mingxi Wu (65B2283FZJ)"
npm run tauri:build

# Notarize (requires APPLE_ID, APPLE_PASSWORD, APPLE_TEAM_ID env vars)
if [[ -n "$APPLE_ID" && -n "$APPLE_PASSWORD" && -n "$APPLE_TEAM_ID" ]]; then
    echo "Submitting to Apple for notarization..."
    DMG_PATH=$(ls src-tauri/target/release/bundle/dmg/KiroaaS_*.dmg 2>/dev/null | head -1)
    if [[ -n "$DMG_PATH" ]]; then
        xcrun notarytool submit "$DMG_PATH" \
            --apple-id "$APPLE_ID" \
            --password "$APPLE_PASSWORD" \
            --team-id "$APPLE_TEAM_ID" \
            --wait
        xcrun stapler staple "$DMG_PATH"
        echo "Notarization complete."
    else
        echo "DMG not found, skipping notarization."
    fi
else
    echo "Skipping notarization (APPLE_ID, APPLE_PASSWORD, or APPLE_TEAM_ID not set)."
fi

rm -rf "$XATTR_SHIM_DIR"

echo ""
echo "=== Build Complete ==="
echo "DMG: src-tauri/target/release/bundle/dmg/"
echo "App: src-tauri/target/release/bundle/macos/KiroaaS.app"
