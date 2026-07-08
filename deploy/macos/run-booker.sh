#!/bin/bash
# Booker launcher for self-hosting on macOS (late-2015 MacBook Pro, Monterey).
# launchd runs this script; it sets config + secrets and starts the app under
# `caffeinate` so the Mac stays awake while Booker is running.
set -euo pipefail

APP_DIR="$HOME/booker-app"     # where you published the app (dotnet publish -o)
DATA_DIR="$HOME/booker-data"   # persistent SQLite location (survives re-publishes)
DOTNET="$(command -v dotnet || echo /usr/local/share/dotnet/dotnet)"

mkdir -p "$DATA_DIR"

# Bind to localhost only — Cloudflare Tunnel connects here; the app is never
# directly exposed on your LAN or the internet.
export ASPNETCORE_URLS="http://127.0.0.1:5000"
export ConnectionStrings__Default="Data Source=$DATA_DIR/booker.db"

# ---------------------------------------------------------------------------
# SECRETS — edit these. Do NOT commit this file with real values filled in.
# These names map to appsettings.json sections automatically (no code changes).
# ---------------------------------------------------------------------------
export Admin__Username="admin"
export Admin__Password="CHANGE_ME_to_a_strong_password"

# Optional: enable real email sending (Gmail needs an App Password, not your login):
# export Email__Host="smtp.gmail.com"
# export Email__Username="rootedreaders123@gmail.com"
# export Email__Password="your-16-char-app-password"

exec caffeinate -is "$DOTNET" "$APP_DIR/Booker.dll"
