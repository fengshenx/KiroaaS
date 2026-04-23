#!/bin/bash
set -e

echo "=== KiroaaS macOS Build Script ==="

# Parse arguments
ARCH="${1:-x86_64}"
if [[ "$ARCH" == "arm" || "$ARCH" == "arm64" || "$ARCH" == "aarch64" ]]; then
    CARGO_TARGET="aarch64-apple-darwin"
    ARCH_LABEL="arm64"
elif [[ "$ARCH" == "x86" || "$ARCH" == "x86_64" ]]; then
    CARGO_TARGET="x86_64-apple-darwin"
    ARCH_LABEL="x86_64"
else
    echo "Usage: $0 [arm|x86]"
    echo "  arm  - build for aarch64-apple-darwin (Apple Silicon)"
    echo "  x86  - build for x86_64-apple-darwin (Intel)"
    exit 1
fi

echo "Building for: $CARGO_TARGET"

# Detect CI environment
IS_CI="${GITHUB_ACTIONS:-false}"

# =============================================================================
# Auto-install prerequisites if missing
# =============================================================================

# --- Rust ---
if ! command -v rustc &> /dev/null; then
    echo "Installing Rust..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    source "$HOME/.cargo/env"
fi

# --- Python (miniconda3) ---
# Prefer local miniconda3, fall back to installing it
MINICONDA="$HOME/miniconda3/bin/python3"
if [[ -x "$MINICONDA" ]]; then
    PYTHON_BIN="$MINICONDA"
elif command -v python3 &> /dev/null; then
    PYTHON_BIN="python3"
else
    echo "Installing Miniconda3..."
    INSTALLER="Miniconda3-latest-MacOSX-${ARCH_LABEL}.sh"
    curl -sSL "https://repo.anaconda.com/miniconda/$INSTALLER" -o /tmp/miniconda.sh
    bash /tmp/miniconda.sh -b -p "$HOME/miniconda3"
    rm /tmp/miniconda.sh
    PYTHON_BIN="$HOME/miniconda3/bin/python3"
    # Force conda to use the target subdir
    "$HOME/miniconda3/bin/conda" config --env --set subdir osx-${ARCH_LABEL}
fi

# --- Node.js (nvm) ---
NODE_VERSION="22.22.0"
NVM_NODE="$HOME/.nvm/versions/node/v${NODE_VERSION}/bin/node"
if [[ -x "$NVM_NODE" ]]; then
    NODE_BIN="$NVM_NODE"
elif command -v node &> /dev/null; then
    NODE_BIN="node"
elif [[ -d "$HOME/.nvm" ]]; then
    echo "Installing Node.js $NODE_VERSION via nvm..."
    source "$HOME/.nvm/nvm.sh" 2>/dev/null || true
    nvm install "$NODE_VERSION"
    nvm use "$NODE_VERSION"
    NODE_BIN="$NVM_NODE"
else
    echo "Installing Node.js $NODE_VERSION..."
    curl -sSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-darwin-${ARCH_LABEL}.tar.gz" -o /tmp/node.tar.gz
    tar -xzf /tmp/node.tar.gz -C /tmp
    mkdir -p "$HOME/.local/bin"
    mv "/tmp/node-v${NODE_VERSION}-darwin-${ARCH_LABEL}/bin/"* "$HOME/.local/bin/"
    rm -rf /tmp/node.tar.gz /tmp/node-v${NODE_VERSION}-darwin-${ARCH_LABEL}
    NODE_BIN="$HOME/.local/bin/node"
fi

# Set up PATH with explicit tool paths first
export PATH="$HOME/.cargo/bin:$($PYTHON_BIN -c 'import sysconfig; print(sysconfig.get_path("scripts"))' 2>/dev/null || echo "$HOME/miniconda3/bin"):$($NODE_BIN --version &>/dev/null && dirname $($NODE_BIN -e "console.log(process.execPath)")):$PATH"

echo "Python: $($PYTHON_BIN --version)"
echo "Node:   $($NODE_BIN --version)"
echo "Rust:   $(rustc --version)"
echo "Prerequisites OK"

# Install Node dependencies
echo "Installing Node dependencies..."
npm install

# Install Python dependencies
echo "Installing Python dependencies..."
cd python-backend
pip3 install --break-system-packages -r requirements.txt
pip3 install --break-system-packages pyinstaller
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
find python-backend/build/dist/kiro-gateway -type f \( -name "*.so" -o -name "*.dylib" -o -type f -perm +111 \) -print0 | xargs -0 codesign --force --sign "$SIGN_IDENTITY" --timestamp --options runtime 2>&1 || true

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

# Build Tauri app with specified target
echo "Building macOS app for $ARCH_LABEL..."
export TAURI_SIGNING_IDENTITY="Developer ID Application: Mingxi Wu (65B2283FZJ)"

# Build Rust binary first with correct target
echo "Building Rust binary for $CARGO_TARGET..."
cd src-tauri
cargo build --release --target "$CARGO_TARGET"
# Copy to where Tauri expects it (tauri build looks in target/release/)
cp "target/$CARGO_TARGET/release/kiroaas" "target/release/kiroaas"
cd ..

# Now run tauri build (it will skip cargo build since binary exists)
npm run tauri:build

# Rename DMG to include arch label
DMG_PATH=$(ls src-tauri/target/release/bundle/dmg/KiroaaS_*.dmg 2>/dev/null | head -1)
if [[ -n "$DMG_PATH" ]]; then
    mv "$DMG_PATH" "${DMG_PATH%.dmg}_${ARCH_LABEL}.dmg"
fi

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
