#!/usr/bin/env bash
# Runs automatically every time the codespace starts (see devcontainer.json).
# Builds .env from your Codespaces secrets, wires up the optional yt-dlp
# cookies workaround, and starts SupoClip with Docker Compose.
#
# NOTE: written from the public README without seeing the repo's compose file
# or dev docs. Env var names and service names are best guesses/auto-detected.
# Output is also saved to .devcontainer/setup.log -- paste errors to me.

# ----------------------- TUNABLE CONSTANTS -----------------------
FRONTEND_PORT=3107
BACKEND_PORT=8000
LLM_MODEL="google-gla:gemini-3-flash-preview"
YTDLP_DIR=".ytdlp"                       # cookies + yt-dlp config (git-ignored)
SERVICE_PATTERN="back|api|work"          # compose services that run yt-dlp
UPDATE_YTDLP=true                        # upgrade yt-dlp inside containers on start
MAKE_PORTS_PUBLIC=true                   # needed so the app can call its own API
# ------------------------------------------------------------------

cd "$(dirname "$0")/.." || exit 1
exec > >(tee .devcontainer/setup.log) 2>&1

if [ -z "${ASSEMBLY_AI_API_KEY:-}" ] || [ -z "${GOOGLE_API_KEY:-}" ]; then
  echo "!! Missing secrets. Add ASSEMBLY_AI_API_KEY and GOOGLE_API_KEY in"
  echo "   GitHub Settings > Codespaces > Secrets (grant access to this repo),"
  echo "   then stop and restart the codespace."
  exit 0
fi

BASE="https://${CODESPACE_NAME}-%s.${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN}"
FRONTEND_URL=$(printf "$BASE" "$FRONTEND_PORT")
BACKEND_URL=$(printf "$BASE" "$BACKEND_PORT")

# ---- .env (rewritten on every start) ----
cat > .env <<EOF
ASSEMBLY_AI_API_KEY=${ASSEMBLY_AI_API_KEY}
GOOGLE_API_KEY=${GOOGLE_API_KEY}
LLM=${LLM_MODEL}
FRONTEND_PORT=${FRONTEND_PORT}
SELF_HOST=true
BETTER_AUTH_URL=${FRONTEND_URL}
NEXT_PUBLIC_API_URL=${BACKEND_URL}
NEXT_PUBLIC_APP_URL=${FRONTEND_URL}
FRONTEND_URL=${FRONTEND_URL}
CORS_ORIGINS=${FRONTEND_URL}
EOF
grep -qxF ".env" .git/info/exclude 2>/dev/null || echo ".env" >> .git/info/exclude

# ---- optional yt-dlp cookies workaround ----
rm -f docker-compose.override.yml
if [ -n "${YT_COOKIES:-}" ]; then
  mkdir -p "$YTDLP_DIR"
  printf "%s\n" "$YT_COOKIES" > "$YTDLP_DIR/cookies.txt"
  cat > "$YTDLP_DIR/yt-dlp.conf" <<EOF
--cookies /etc/yt-dlp-cookies.txt
--sleep-requests 1
--retries 5
EOF
  for f in "$YTDLP_DIR" docker-compose.override.yml; do
    grep -qxF "$f" .git/info/exclude 2>/dev/null || echo "$f" >> .git/info/exclude
  done

  SERVICES=$(docker compose config --services 2>/dev/null | grep -E "$SERVICE_PATTERN")
  if [ -n "$SERVICES" ]; then
    echo "services:" > docker-compose.override.yml
    for s in $SERVICES; do
      cat >> docker-compose.override.yml <<EOF
  $s:
    volumes:
      - ./$YTDLP_DIR/yt-dlp.conf:/etc/yt-dlp.conf
      - ./$YTDLP_DIR/cookies.txt:/etc/yt-dlp-cookies.txt
EOF
    done
    echo "yt-dlp cookies mounted into: $SERVICES"
  else
    echo "!! Could not detect backend/worker services for the cookies mount."
  fi
else
  echo "No YT_COOKIES secret set - YouTube links may be blocked; use file upload instead."
fi

# ---- start the stack ----
docker compose up -d --build

# ---- keep yt-dlp fresh (stale versions are the #1 cause of download failures) ----
if [ "$UPDATE_YTDLP" = true ]; then
  for s in $(docker compose config --services 2>/dev/null | grep -E "$SERVICE_PATTERN"); do
    docker compose exec -T "$s" sh -c 'pip install -U yt-dlp >/dev/null 2>&1 || uv pip install -U yt-dlp >/dev/null 2>&1' || true
  done
fi

# ---- make ports reachable from your phone browser ----
if [ "$MAKE_PORTS_PUBLIC" = true ]; then
  gh codespace ports visibility "${FRONTEND_PORT}:public" "${BACKEND_PORT}:public" -c "$CODESPACE_NAME" || true
fi

echo
echo "=============================="
echo "SupoClip: $FRONTEND_URL"
echo "(first start takes a few minutes; check: docker compose logs -f)"
echo "=============================="
