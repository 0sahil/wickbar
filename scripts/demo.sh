#!/usr/bin/env bash
# Launches a second, isolated copy of Wickbar with demo commands (for screenshots / trying it out).
# Your real config in ~/Library/Application Support/Wickbar is not touched.
#   scripts/demo.sh            # uses build/Wickbar.app (run scripts/build-app.sh first)
#   scripts/demo.sh --stop     # quits the demo copy (it stops its commands on the way out)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEMO_DIR="${WICKBAR_DEMO_DIR:-${TMPDIR:-/tmp}/wickbar-demo}"
APP="$ROOT/build/Wickbar.app"

if [[ "${1:-}" == "--stop" ]]; then
  for p in $(ps -Eww -axo pid=,command= | awk '/WICKBAR_CONFIG_DIR=/ && /Wickbar.app\/Contents\/MacOS\/Wickbar/ {print $1}'); do
    kill -TERM "$p"
  done
  echo "Stopped demo copy."; exit 0
fi

[[ -d "$APP" ]] || { echo "Build it first: scripts/build-app.sh"; exit 1; }
mkdir -p "$DEMO_DIR"
cd "$DEMO_DIR"

cat > web.sh <<'EOF'
#!/usr/bin/env bash
printf '\n  \033[1;32mVITE\033[0m v6.2.0  \033[2mready in\033[0m \033[1m412\033[0m \033[2mms\033[0m\n\n'
printf '  \033[32m➜\033[0m  \033[1mLocal\033[0m:   \033[36mhttp://localhost:\033[1m5173\033[0;36m/\033[0m\n'
printf '  \033[2m➜  Network: use --host to expose\033[0m\n\n'
f=(App.tsx Header.tsx api/client.ts styles.css routes/index.tsx); i=0
while true; do
  sleep 2
  printf '\033[2m%s\033[0m \033[1;36m[vite]\033[0m \033[32mhmr update\033[0m \033[2m/src/%s\033[0m\n' "$(date +%T)" "${f[$((i % 5))]}"
  i=$((i + 1))
done
EOF

cat > api.sh <<'EOF'
#!/usr/bin/env bash
printf '\033[1;35m▲ api\033[0m listening on \033[36mhttp://127.0.0.1:8080\033[0m\n'
p=(/health /v1/users /v1/projects /v1/users/42 "/v1/search?q=wick"); m=(GET GET POST GET GET)
s=(200 200 201 200 304); t=(2 14 38 9 5); i=0
while true; do
  sleep 1.3; k=$((i % 5))
  printf '\033[2m%s\033[0m \033[1m%-4s\033[0m %-20s \033[32m%s\033[0m \033[2m%sms\033[0m\n' "$(date +%T)" "${m[$k]}" "${p[$k]}" "${s[$k]}" "${t[$k]}"
  i=$((i + 1))
done
EOF

cat > worker.sh <<'EOF'
#!/usr/bin/env bash
printf '\033[1;33m⚙ worker\033[0m started, concurrency=4\n'; n=1000
while true; do
  sleep 1.7; n=$((n + 1))
  printf '\033[2m%s\033[0m \033[32m✓\033[0m job \033[1m#%s\033[0m send-email \033[2m(%sms)\033[0m\n' "$(date +%T)" "$n" "$((RANDOM % 90 + 10))"
done
EOF

cat > migrate.sh <<'EOF'
#!/usr/bin/env bash
printf 'Running migrations...\n\033[1;31merror\033[0m: connect ECONNREFUSED 127.0.0.1:5432\n'
exit 1
EOF
chmod +x web.sh api.sh worker.sh migrate.sh

python3 - "$DEMO_DIR" <<'PY'
import json, sys, uuid, os
d = sys.argv[1]
def cmd(name, command, auto=True, policy="onFailure"):
    return {"id": str(uuid.uuid4()).upper(), "name": name, "command": command, "workingDirectory": d,
            "environment": {}, "autoStart": auto, "restartPolicy": policy}
cfg = {"settings": {"autoStartOnLaunch": True, "mcpEnabled": False, "mcpPort": 9426, "restoreAfterCrash": "never"},
       "commands": [cmd("web", "./web.sh"), cmd("api", "./api.sh"), cmd("worker", "./worker.sh"),
                    cmd("db-migrate", "./migrate.sh", policy="never"),
                    cmd("docs", "python3 -m http.server 8000", auto=False)]}
json.dump(cfg, open(os.path.join(d, "config.json"), "w"), indent=2, sort_keys=True)
PY

open -n --env WICKBAR_CONFIG_DIR="$DEMO_DIR" "$APP"
echo "Demo copy running with config in $DEMO_DIR (stop with: scripts/demo.sh --stop)"
