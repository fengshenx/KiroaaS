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

# Commands that must run as the target CPU architecture. Cargo can cross-compile
# macOS targets, but PyInstaller cannot; it must run under the target arch.
ARCH_RUN=()
if [[ "$(uname -m)" == "arm64" && "$ARCH_LABEL" == "x86_64" ]]; then
    if ! arch -x86_64 /usr/bin/true 2>/dev/null; then
        echo "Rosetta 2 is required to build x86_64 Python binaries on Apple Silicon."
        echo "Install it with: softwareupdate --install-rosetta --agree-to-license"
        exit 1
    fi
    ARCH_RUN=(arch -x86_64)
fi

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
# Use a target-architecture Python. PyInstaller cannot cross-compile, so an
# Intel build on Apple Silicon must use an x86_64 Python running via Rosetta.
if [[ "$ARCH_LABEL" == "x86_64" ]]; then
    CONDA_DIR="$HOME/miniconda3-x86_64"
else
    CONDA_DIR="$HOME/miniconda3"
fi
MINICONDA="$CONDA_DIR/bin/python3"
if [[ -x "$MINICONDA" ]]; then
    PYTHON_BIN="$MINICONDA"
elif [[ "$ARCH_LABEL" == "arm64" ]] && command -v python3 &> /dev/null; then
    PYTHON_BIN="python3"
else
    echo "Installing Miniconda3 for $ARCH_LABEL..."
    INSTALLER="Miniconda3-latest-MacOSX-${ARCH_LABEL}.sh"
    curl -sSL "https://repo.anaconda.com/miniconda/$INSTALLER" -o /tmp/miniconda.sh
    "${ARCH_RUN[@]}" /bin/bash /tmp/miniconda.sh -b -p "$CONDA_DIR"
    rm /tmp/miniconda.sh
    PYTHON_BIN="$CONDA_DIR/bin/python3"
    # Force conda to use the target subdir
    "${ARCH_RUN[@]}" "$CONDA_DIR/bin/conda" config --env --set subdir "osx-${ARCH_LABEL}"
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
PYTHON_SCRIPTS_DIR=$("${ARCH_RUN[@]}" "$PYTHON_BIN" -c 'import sysconfig; print(sysconfig.get_path("scripts"))' 2>/dev/null || echo "$CONDA_DIR/bin")
NODE_DIR=$($NODE_BIN --version &>/dev/null && dirname $($NODE_BIN -e "console.log(process.execPath)"))
export PATH="$HOME/.cargo/bin:$PYTHON_SCRIPTS_DIR:$NODE_DIR:$PATH"

echo "Python: $("${ARCH_RUN[@]}" "$PYTHON_BIN" --version) ($("${ARCH_RUN[@]}" "$PYTHON_BIN" -c 'import platform; print(platform.machine())'))"
echo "Node:   $($NODE_BIN --version)"
echo "Rust:   $(rustc --version)"
echo "Prerequisites OK"

# Install Node dependencies
echo "Installing Node dependencies..."
npm install

# Install Python dependencies
echo "Installing Python dependencies..."
cd python-backend
"${ARCH_RUN[@]}" "$PYTHON_BIN" -m pip install --break-system-packages -r requirements.txt
"${ARCH_RUN[@]}" "$PYTHON_BIN" -m pip install --break-system-packages pyinstaller
cd ..

# Build Python backend
echo "Building Python backend..."
cd python-backend/build
rm -rf build dist
"${ARCH_RUN[@]}" "$PYTHON_BIN" build.py
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

rustup target add "$CARGO_TARGET"
npm run tauri:build -- --target "$CARGO_TARGET"

TARGET_RELEASE_DIR="src-tauri/target/$CARGO_TARGET/release"
BUNDLE_DIR="$TARGET_RELEASE_DIR/bundle"

# Rename DMG to include arch label
DMG_PATH=$(ls "$BUNDLE_DIR"/dmg/KiroaaS_*.dmg 2>/dev/null | head -1)
if [[ -n "$DMG_PATH" ]]; then
    mv "$DMG_PATH" "${DMG_PATH%.dmg}_${ARCH_LABEL}.dmg"
fi

# Notarize (requires APPLE_ID, APPLE_PASSWORD, APPLE_TEAM_ID env vars)
if [[ -n "$APPLE_ID" && -n "$APPLE_PASSWORD" && -n "$APPLE_TEAM_ID" ]]; then
    echo "Submitting to Apple for notarization..."
    DMG_PATH=$(ls "$BUNDLE_DIR"/dmg/KiroaaS_*.dmg 2>/dev/null | head -1)
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
echo "DMG: $BUNDLE_DIR/dmg/"
echo "App: $BUNDLE_DIR/macos/KiroaaS.app"
