#!/usr/bin/env bash
set -Eeuo pipefail

NVM_VERSION="${NVM_VERSION:-v0.40.3}"
NODE_VERSION="${NODE_VERSION:-16}"
CODEX_PACKAGE="${CODEX_PACKAGE:-@openai/codex}"
CODEX_MODEL="${CODEX_MODEL:-gpt-5.5}"
CODEX_REASONING_EFFORT="${CODEX_REASONING_EFFORT:-high}"
CODEX_BASE_URL="${CODEX_BASE_URL:-https://api.antithor.asia}"
PROVIDER_NAME="${PROVIDER_NAME:-antithor}"
API_KEY_ENV_NAME="${API_KEY_ENV_NAME:-ANTITHOR_API_KEY}"

log() {
  printf '\n[%s] %s\n' "$(date +'%H:%M:%S')" "$*"
}

die() {
  printf '\nERROR: %s\n' "$*" >&2
  exit 1
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

sudo_if_needed() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

ensure_line() {
  local file="$1"
  local line="$2"
  mkdir -p "$(dirname "$file")"
  touch "$file"
  if ! grep -Fqx "$line" "$file"; then
    printf '%s\n' "$line" >> "$file"
  fi
}

shell_quote_export() {
  local name="$1"
  local value="$2"
  printf 'export %s=' "$name"
  printf '%q' "$value"
  printf '\n'
}

if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi

log "Checking system"
uname -a
if [ -f /etc/os-release ]; then
  . /etc/os-release
  printf 'OS: %s\n' "${PRETTY_NAME:-unknown}"
fi

case "$(uname -m)" in
  x86_64|aarch64|arm64) ;;
  *) die "Unsupported architecture: $(uname -m)" ;;
esac

missing=()
for cmd in curl git tar xz; do
  if ! has_cmd "$cmd"; then
    missing+=("$cmd")
  fi
done

if [ "${#missing[@]}" -gt 0 ]; then
  if ! has_cmd apt-get; then
    die "Missing commands: ${missing[*]}; apt-get not found, install them manually first."
  fi
  log "Installing prerequisites: ${missing[*]}"
  sudo_if_needed apt-get update
  sudo_if_needed apt-get install -y curl git ca-certificates tar xz-utils
fi

log "Installing/loading nvm ${NVM_VERSION}"
export NVM_DIR="$HOME/.nvm"
if [ ! -s "$NVM_DIR/nvm.sh" ]; then
  curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh" | bash
fi

# shellcheck source=/dev/null
. "$NVM_DIR/nvm.sh"

log "Installing/using Node.js ${NODE_VERSION}"
nvm install "$NODE_VERSION"
nvm alias default "$NODE_VERSION"
nvm use "$NODE_VERSION"

log "Installing Codex CLI package: ${CODEX_PACKAGE}"
npm install -g "$CODEX_PACKAGE"

mkdir -p "$HOME/.codex"

if [ -z "${!API_KEY_ENV_NAME:-}" ]; then
  printf '\nEnter %s, then press Enter. Input is hidden:\n> ' "$API_KEY_ENV_NAME"
  IFS= read -r -s API_KEY_VALUE
  printf '\n'
else
  API_KEY_VALUE="${!API_KEY_ENV_NAME}"
fi

if [ -z "${API_KEY_VALUE:-}" ]; then
  die "${API_KEY_ENV_NAME} is empty."
fi

log "Writing API key environment file"
umask 077
shell_quote_export "$API_KEY_ENV_NAME" "$API_KEY_VALUE" > "$HOME/.codex/env"
chmod 600 "$HOME/.codex/env"

log "Writing Codex config"
if [ -f "$HOME/.codex/config.toml" ]; then
  cp "$HOME/.codex/config.toml" "$HOME/.codex/config.toml.bak-$(date +'%Y%m%d-%H%M%S')"
fi

cat > "$HOME/.codex/config.toml" <<EOF
model_provider = "${PROVIDER_NAME}"
model = "${CODEX_MODEL}"
model_reasoning_effort = "${CODEX_REASONING_EFFORT}"
disable_response_storage = true

[model_providers.${PROVIDER_NAME}]
name = "${PROVIDER_NAME}"
base_url = "${CODEX_BASE_URL}"
env_key = "${API_KEY_ENV_NAME}"
wire_api = "responses"
EOF

log "Making Codex available to login and non-interactive shells"
ensure_line "$HOME/.profile" 'export NVM_DIR="$HOME/.nvm"'
ensure_line "$HOME/.profile" '[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"'
ensure_line "$HOME/.profile" '[ -f "$HOME/.codex/env" ] && . "$HOME/.codex/env"'
ensure_line "$HOME/.profile" 'export PATH="$HOME/.local/bin:$PATH"'

ensure_line "$HOME/.bashrc" 'export NVM_DIR="$HOME/.nvm"'
ensure_line "$HOME/.bashrc" '[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"'
ensure_line "$HOME/.bashrc" '[ -f "$HOME/.codex/env" ] && . "$HOME/.codex/env"'
ensure_line "$HOME/.bashrc" 'export PATH="$HOME/.local/bin:$PATH"'

mkdir -p "$HOME/.local/bin"
cat > "$HOME/.local/bin/codex" <<'EOF'
#!/usr/bin/env bash
set -e
export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
[ -f "$HOME/.codex/env" ] && . "$HOME/.codex/env"
if [ ! -s "$NVM_DIR/nvm.sh" ]; then
  echo "nvm not found at $NVM_DIR/nvm.sh" >&2
  exit 127
fi
. "$NVM_DIR/nvm.sh"
nvm use --silent default >/dev/null
if [ ! -x "$NVM_BIN/codex" ]; then
  echo "codex not found in $NVM_BIN" >&2
  exit 127
fi
exec "$NVM_BIN/codex" "$@"
EOF
chmod +x "$HOME/.local/bin/codex"

if has_cmd sudo; then
  log "Installing /usr/local/bin/codex wrapper"
  sudo_if_needed install -m 0755 "$HOME/.local/bin/codex" /usr/local/bin/codex
else
  log "sudo not found; installed wrapper at $HOME/.local/bin/codex only"
fi

log "Verification"
printf 'node: '
node -v
printf 'npm: '
npm -v
printf 'codex: '
codex --version
printf 'config: %s\n' "$HOME/.codex/config.toml"
printf 'key env: %s stored in %s\n' "$API_KEY_ENV_NAME" "$HOME/.codex/env"

cat <<'EOF'

Done.

Recommended test:
  codex exec "hello"

For Codex Desktop remote SSH:
  1. Make sure your local machine can SSH into this server.
  2. Reconnect the remote host from Codex Desktop.
  3. If it still says Codex is not installed, log out/in on the server
     or restart Codex Desktop and try again.
EOF
