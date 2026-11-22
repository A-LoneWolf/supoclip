#!/usr/bin/env bash
# Runs automatically every time the codespace starts (see devcontainer.json).
# Builds .env from the repo's .env.example + your Codespaces secrets, wires up
# the optional yt-dlp cookies workaround, and starts SupoClip with Docker Compose.
# Output is also saved to .devcontainer/setup.log.

# ----------------------- TUNABLE CONSTANTS -----------------------
FRONTEND_PORT=3107
BACKEND_PORT=8000
LLM_MODEL="google-gla:gemini-3-flash-preview"
YTDLP_DIR=".ytdlp"                                # cookies live here (git-ignored)
PATCH_DIR=".devcontainer/ytdlp_patch"             # sitecustomize.py that injects cookies
SECRETS_FILE=".devcontainer/.generated-secrets"   # random secrets, created once (git-ignored)
SERVICE_PATTERN="back|api|work"                   # compose services that run yt-dlp
UPDATE_YTDLP=true                                 # upgrade yt-dlp inside containers on start
MAKE_PORTS_PUBLIC=true                            # needed so the app can call its own API
# ------------------------------------------------------------------

cd "$(dirname "$0")/.." || exit 1
exec > >(tee .devcontainer/setup.log) 2>&1

quiet() { grep -v "variable is not set"; }
exclude() { grep -qxF "$1" .git/info/exclude 2>/dev/null || echo "$1" >> .git/info/exclude; }

if [ -z "${ASSEMBLY_AI_API_KEY:-}" ] || [ -z "${GOOGLE_API_KEY:-}" ]; then
  echo "!! Missing secrets. Add ASSEMBLY_AI_API_KEY and GOOGLE_API_KEY in"
  echo "   GitHub Settings > Codespaces > Secrets (grant access to this repo),"
  echo "   then stop and restart the codespace."
  exit 0
fi

BASE="https://${CODESPACE_NAME}-%s.${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN}"
FRONTEND_URL=$(printf "$BASE" "$FRONTEND_PORT")
BACKEND_URL=$(printf "$BASE" "$BACKEND_PORT")

# ---- random secrets, generated once and reused so stored data stays valid ----
if [ ! -f "$SECRETS_FILE" ]; then
  {
    echo "BACKEND_AUTH_SECRET=$(openssl rand -hex 32)"
    echo "APP_SETTINGS_ENCRYPTION_KEY=$(openssl rand -hex 32)"
    echo "BETTER_AUTH_SECRET=$(openssl rand -hex 32)"
  } > "$SECRETS_FILE"
fi
exclude "$SECRETS_FILE"

# ---- .env = repo defaults (.env.example) + our overrides ----
if [ -f .env.example ]; then cp .env.example .env; else : > .env; fi
set_env() { grep -v "^$1=" .env > .env.tmp; mv .env.tmp .env; printf "%s=%s\n" "$1" "$2" >> .env; }

set_env ASSEMBLY_AI_API_KEY "$ASSEMBLY_AI_API_KEY"
set_env GOOGLE_API_KEY "$GOOGLE_API_KEY"
set_env LLM "$LLM_MODEL"
set_env FRONTEND_PORT "$FRONTEND_PORT"
set_env SELF_HOST true
set_env BETTER_AUTH_URL "$FRONTEND_URL"
set_env NEXT_PUBLIC_API_URL "$BACKEND_URL"
set_env NEXT_PUBLIC_APP_URL "$FRONTEND_URL"
set_env FRONTEND_URL "$FRONTEND_URL"
set_env CORS_ORIGINS "$FRONTEND_URL"
[ -n "${YOUTUBE_DATA_API_KEY:-}" ] && set_env YOUTUBE_DATA_API_KEY "$YOUTUBE_DATA_API_KEY"
while IFS='=' read -r k v; do [ -n "$k" ] && set_env "$k" "$v"; done < "$SECRETS_FILE"
exclude ".env"

# ---- optional YouTube cookies (YT_COOKIES_B64 preferred, YT_COOKIES as fallback) ----
rm -f docker-compose.override.yml
mkdir -p "$YTDLP_DIR"
rm -f "$YTDLP_DIR/cookies.txt"
if [ -n "${YT_COOKIES_B64:-}" ]; then
  printf "%s" "$YT_COOKIES_B64" | base64 -d > "$YTDLP_DIR/cookies.txt" 2>/dev/null
elif [ -n "${YT_COOKIES:-}" ]; then
  printf "%s\n" "$YT_COOKIES" > "$YTDLP_DIR/cookies.txt"
fi
exclude "$YTDLP_DIR"
exclude "docker-compose.override.yml"

if [ -s "$YTDLP_DIR/cookies.txt" ]; then
  LINES=$(wc -l < "$YTDLP_DIR/cookies.txt")
  if [ "$LINES" -lt 3 ]; then
    echo "!! cookies.txt has only $LINES line(s) - pasting into the secret box flattened it."
    echo "   Use the YT_COOKIES_B64 secret (base64 of the file) instead."
  fi
  SERVICES=$(docker compose config --services 2>/dev/null | grep -E "$SERVICE_PATTERN")
  if [ -n "$SERVICES" ]; then
    echo "services:" > docker-compose.override.yml
    for s in $SERVICES; do
      cat >> docker-compose.override.yml <<EOF
  $s:
    environment:
      PYTHONPATH: /opt/ytdlp_patch
      YTDLP_COOKIEFILE: /opt/ytdlp_cookies/cookies.txt
    volumes:
      - ./$PATCH_DIR:/opt/ytdlp_patch:ro
      - ./$YTDLP_DIR:/opt/ytdlp_cookies
EOF
    done
    echo "YouTube cookies + patch mounted into: $(echo $SERVICES)"
  else
    echo "!! Could not detect backend/worker services for the cookies mount."
  fi
else
  echo "No YouTube cookies secret set - YouTube links may be blocked; use file upload instead."
fi

# ---- start the stack (errors are shown, only the noisy warnings are hidden) ----
docker compose up -d --build 2>&1 | quiet
if [ "${PIPESTATUS[0]}" -ne 0 ]; then
  echo
  echo "!! docker compose up FAILED - the error is above. Paste it to Claude."
  exit 1
fi

echo "--- containers ---"
docker compose ps 2>&1 | quiet

# ---- keep yt-dlp fresh (stale versions are the #1 cause of download failures) ----
if [ "$UPDATE_YTDLP" = true ]; then
  sleep 10
  for s in $(docker compose ps --status running --services 2>/dev/null | grep -E "$SERVICE_PATTERN"); do
    docker compose exec -T "$s" sh -c 'pip install -U yt-dlp >/dev/null 2>&1 || uv pip install -U yt-dlp >/dev/null 2>&1' || true
  done
fi

# ---- confirm the cookie patch is active inside the backend ----
if [ -s "$YTDLP_DIR/cookies.txt" ]; then
  for s in $(docker compose ps --status running --services 2>/dev/null | grep -E "back|api" | head -1); do
    docker compose exec -T "$s" python -c "import sitecustomize; print('cookie patch loaded from', sitecustomize.__file__)" 2>&1 | tail -1 || true
  done
fi

# ---- make ports reachable from your browser ----
if [ "$MAKE_PORTS_PUBLIC" = true ]; then
  gh codespace ports visibility "${FRONTEND_PORT}:public" "${BACKEND_PORT}:public" -c "$CODESPACE_NAME" || true
fi

echo
echo "=============================="
echo "SupoClip: $FRONTEND_URL"
echo "(give it a minute after the build; check: docker compose logs -f backend worker)"
echo "=============================="
