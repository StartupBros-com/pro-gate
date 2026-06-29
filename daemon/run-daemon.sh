#!/usr/bin/env bash
# systemd wrapper for pro-review-daemon (onwatch pattern: export env, source .env, exec).
export HOME=/home/will
export USER=will
export PATH=/home/will/.local/bin:/home/will/.local/share/mise/shims:/home/will/.local/share/mise/installs/node/24.13.1/bin:/home/will/.local/share/mise/installs/node/24.12.0/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

set -a
[ -f /home/will/.pro-review-daemon/.env ] && source /home/will/.pro-review-daemon/.env
set +a

cd /home/will/.pro-review-daemon
exec /home/will/.pro-review-daemon/daemon.sh
