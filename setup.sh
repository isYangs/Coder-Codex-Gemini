#!/bin/bash
# CCG One-Click Setup Script for macOS/Linux
set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Helper functions
write_step() {
    echo -e "\n${CYAN}[*] $1${NC}"
}

write_success() {
    echo -e "${GREEN}[OK] $1${NC}"
}

write_error() {
    echo -e "${RED}[ERROR] $1${NC}"
}

write_warning() {
    echo -e "${YELLOW}[WARN] $1${NC}"
}

# ==============================================================================
# Step 1: Check dependencies
# ==============================================================================
write_step "Step 1: Checking dependencies..."

# Check and install uv
if command -v uv &> /dev/null; then
    write_success "uv is installed"
else
    write_warning "uv is not installed, installing automatically..."
    if curl -LsSf https://astral.sh/uv/install.sh | sh; then
        export PATH="$HOME/.local/bin:$PATH"
        write_success "uv installed successfully"
    else
        write_error "Failed to install uv automatically"
        echo "Please install uv manually: https://github.com/astral-sh/uv"
        exit 1
    fi
fi

# Check claude CLI
if command -v claude &> /dev/null; then
    write_success "claude CLI is installed"
else
    write_error "claude CLI is not installed"
    echo "Please install Claude Code CLI first: https://docs.anthropic.com/en/docs/claude-code"
    exit 1
fi

# ==============================================================================
# Step 2: Install project dependencies
# ==============================================================================
write_step "Step 2: Installing project dependencies..."

cd "$SCRIPT_DIR"
if uv sync; then
    write_success "Project dependencies installed"
else
    write_error "Failed to install dependencies"
    exit 1
fi

# ==============================================================================
# Step 3: Register MCP server
# ==============================================================================
write_step "Step 3: Registering MCP server..."

# Check uv version to determine if --refresh is supported
USE_REFRESH=false
UV_VERSION_KNOWN=false

UV_VERSION_OUTPUT=$(uv --version 2>&1) || true
if [[ "$UV_VERSION_OUTPUT" =~ uv\ ([0-9]+)\.([0-9]+)\.([0-9]+) ]]; then
    UV_VERSION_KNOWN=true
    MAJOR="${BASH_REMATCH[1]}"
    MINOR="${BASH_REMATCH[2]}"
    # --refresh requires uv >= 0.4.0
    if [ "$MAJOR" -gt 0 ] || ([ "$MAJOR" -eq 0 ] && [ "$MINOR" -ge 4 ]); then
        USE_REFRESH=true
    fi
fi

# Build the args array based on uv version
if [ "$USE_REFRESH" = true ]; then
    MCP_ARGS='["--refresh", "--from", "git+https://github.com/isYangs/Coder-Codex-Gemini.git", "ccg-mcp"]'
    REFRESH_NOTE="(with --refresh)"
else
    MCP_ARGS='["--from", "git+https://github.com/isYangs/Coder-Codex-Gemini.git", "ccg-mcp"]'
    if [ "$UV_VERSION_KNOWN" = true ]; then
        write_warning "Your uv version does not support --refresh option (requires uv >= 0.4.0)"
    else
        write_warning "Could not determine uv version, skipping --refresh option"
    fi
    write_warning "Consider upgrading uv: curl -LsSf https://astral.sh/uv/install.sh | sh"
    REFRESH_NOTE="(without --refresh)"
fi

# Use Python to directly modify ~/.claude/settings.json
python3 -c "
import json
import os

settings_path = os.path.expanduser('~/.claude/settings.json')
settings_dir = os.path.expanduser('~/.claude')

# Create .claude directory if it doesn't exist
os.makedirs(settings_dir, exist_ok=True)

# Read existing settings or create new structure
if os.path.exists(settings_path):
    try:
        with open(settings_path, 'r') as f:
            content = f.read().strip()
            settings = json.loads(content) if content else {}
    except (json.JSONDecodeError, ValueError):
        print('[WARN] settings.json is corrupt, will recreate')
        settings = {}
else:
    settings = {}

# Ensure mcpServers exists
if 'mcpServers' not in settings:
    settings['mcpServers'] = {}

# Remove existing ccg entry if present
if 'ccg' in settings['mcpServers']:
    print('[WARN] Removed existing ccg MCP server')

# Add the new ccg MCP server entry
settings['mcpServers']['ccg'] = {
    'command': 'uvx',
    'args': $MCP_ARGS
}

# Write back to file with proper formatting
with open(settings_path, 'w') as f:
    json.dump(settings, f, indent=2)
    f.write('\n')
" && write_success "MCP server registered $REFRESH_NOTE" || {
    write_error "Failed to register MCP server"
    exit 1
}

# ==============================================================================
# Step 4: Install Skills
# ==============================================================================
write_step "Step 4: Installing Skills..."

SKILLS_DIR="$HOME/.claude/skills"
CCG_WORKFLOW_SOURCE="$SCRIPT_DIR/skills/ccg-workflow"
GEMINI_COLLAB_SOURCE="$SCRIPT_DIR/skills/gemini-collaboration"

# Create skills directory if it doesn't exist
if [ ! -d "$SKILLS_DIR" ]; then
    mkdir -p "$SKILLS_DIR"
    write_success "Created skills directory: $SKILLS_DIR"
fi

# Copy ccg-workflow skill
if [ -d "$CCG_WORKFLOW_SOURCE" ]; then
    DEST="$SKILLS_DIR/ccg-workflow"
    rm -rf "$DEST"
    cp -r "$CCG_WORKFLOW_SOURCE" "$DEST"
    write_success "Installed ccg-workflow skill"
else
    write_warning "ccg-workflow skill not found, skipping"
fi

# Copy gemini-collaboration skill
if [ -d "$GEMINI_COLLAB_SOURCE" ]; then
    DEST="$SKILLS_DIR/gemini-collaboration"
    rm -rf "$DEST"
    cp -r "$GEMINI_COLLAB_SOURCE" "$DEST"
    write_success "Installed gemini-collaboration skill"
else
    write_warning "gemini-collaboration skill not found, skipping"
fi

# ==============================================================================
# Step 5: Configure global CLAUDE.md
# ==============================================================================
write_step "Step 5: Configuring global CLAUDE.md..."

CLAUDE_MD_PATH="$HOME/.claude/CLAUDE.md"
CCG_MARKER="# CCG Configuration"
CCG_CONFIG_PATH="$SCRIPT_DIR/templates/ccg-global-prompt.md"

# Create .claude directory if it doesn't exist
mkdir -p "$HOME/.claude"

if [ ! -f "$CLAUDE_MD_PATH" ]; then
    # Create new file with CCG config
    if [ -f "$CCG_CONFIG_PATH" ]; then
        cp "$CCG_CONFIG_PATH" "$CLAUDE_MD_PATH"
        write_success "Created global CLAUDE.md"
    else
        write_warning "CCG global prompt template not found at $CCG_CONFIG_PATH"
        write_warning "Please manually copy the CCG configuration to $CLAUDE_MD_PATH"
    fi
else
    # Check if CCG config already exists
    if grep -qF "$CCG_MARKER" "$CLAUDE_MD_PATH"; then
        write_warning "CCG configuration already exists in CLAUDE.md, skipping"
    else
        # Append CCG config
        if [ -f "$CCG_CONFIG_PATH" ]; then
            echo "" >> "$CLAUDE_MD_PATH"
            cat "$CCG_CONFIG_PATH" >> "$CLAUDE_MD_PATH"
            write_success "Appended CCG configuration to CLAUDE.md"
        else
            write_warning "CCG global prompt template not found at $CCG_CONFIG_PATH"
            write_warning "Please manually copy the CCG configuration to $CLAUDE_MD_PATH"
        fi
    fi
fi

# ==============================================================================
# Step 6: Configure Coder
# ==============================================================================
write_step "Step 6: Configuring Coder..."

CONFIG_DIR="$HOME/.ccg-mcp"
CONFIG_PATH="$CONFIG_DIR/config.toml"

# Create config directory if it doesn't exist
mkdir -p "$CONFIG_DIR"

# Check if config already exists
if [ -f "$CONFIG_PATH" ]; then
    write_warning "Config file already exists at $CONFIG_PATH"
    read -p "Overwrite? (y/N): " OVERWRITE
    if [ "$OVERWRITE" != "y" ] && [ "$OVERWRITE" != "Y" ]; then
        write_warning "Skipping Coder configuration"
        # Jump to Done
        echo ""
        echo -e "${GREEN}============================================================${NC}"
        write_success "CCG setup completed successfully!"
        echo -e "${GREEN}============================================================${NC}"
        echo ""
        echo "Next steps:"
        echo "  1. Restart Claude Code CLI"
        echo "  2. Verify MCP server: claude mcp list"
        echo "  3. Check available skills: /ccg-workflow"
        echo ""
        exit 0
    fi
fi

# Prompt for API Token (hidden input)
read -s -p "Enter your API Token: " API_TOKEN
echo
if [ -z "$API_TOKEN" ]; then
    write_error "API Token is required"
    exit 1
fi

# Prompt for Base URL (optional)
read -p "Enter Base URL (default: https://open.bigmodel.cn/api/anthropic): " BASE_URL
if [ -z "$BASE_URL" ]; then
    BASE_URL="https://open.bigmodel.cn/api/anthropic"
fi

# Prompt for Model (required)
read -p "Enter Model (e.g. glm-4.7): " MODEL
MODEL=$(echo "$MODEL" | xargs)
if [ -z "$MODEL" ]; then
    write_error "Model is required"
    exit 1
fi

# Escape special characters for TOML string values (backslash and double quote)
SAFE_API_TOKEN=$(printf '%s' "$API_TOKEN" | sed 's/\\/\\\\/g; s/"/\\"/g')
SAFE_BASE_URL=$(printf '%s' "$BASE_URL" | sed 's/\\/\\\\/g; s/"/\\"/g')
SAFE_MODEL=$(printf '%s' "$MODEL" | sed 's/\\/\\\\/g; s/"/\\"/g')

# Generate config.toml
cat > "$CONFIG_PATH" << EOF
[coder]
api_token = "$SAFE_API_TOKEN"
base_url = "$SAFE_BASE_URL"
model = "$SAFE_MODEL"

[coder.env]
CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = "1"
EOF

# Set file permissions - only current user can read/write
chmod 600 "$CONFIG_PATH"

write_success "Coder configuration saved to $CONFIG_PATH"

# ==============================================================================
# Done!
# ==============================================================================
echo ""
echo -e "${GREEN}============================================================${NC}"
write_success "CCG setup completed successfully!"
echo -e "${GREEN}============================================================${NC}"
echo ""

echo "Next steps:"
echo "  1. Restart Claude Code CLI"
echo "  2. Verify MCP server: claude mcp list"
echo "  3. Check available skills: /ccg-workflow"
echo ""
