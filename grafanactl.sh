#!/usr/bin/env bash

set -e

# === CONFIG LOAD ===
ENV_FILE="./.env"
CONFIG_FILE=""

if [[ -f "$ENV_FILE" ]]; then
  set -o allexport
  source "$ENV_FILE"
  set +o allexport
elif [[ -n "$JS_CONFIG_PATH" && -f "$JS_CONFIG_PATH" ]]; then
  echo "[*] Loading configuration from $JS_CONFIG_PATH"
  GRAFANA_VERSION="10.2.3"
  GRAFANA_PORT=3000
  GRAFANA_CONTAINER_NAME="grafana"
  GRAFANA_ADMIN_USER="admin"
  GRAFANA_ADMIN_PASSWORD="admin"
  DASHBOARD_JSON="jumpserver-audit-dashboard.json"
  NETWORK_NAME=$(grep "^DOCKER_SUBNET=" "$JS_CONFIG_PATH" | awk -F= '{print $2}' | awk -F/ '{print "jms_net"}')
else
  echo "[!] Neither .env nor valid config.txt found."
  read -rp "Enter Grafana container name: " GRAFANA_CONTAINER_NAME
  read -rp "Enter Grafana volume name: " GRAFANA_VOLUME_NAME
  read -rp "Enter Grafana network name: " NETWORK_NAME
  GRAFANA_VERSION="10.2.3"
  GRAFANA_PORT=3000
  GRAFANA_ADMIN_USER="admin"
  GRAFANA_ADMIN_PASSWORD="admin"
  DASHBOARD_JSON="jumpserver-audit-dashboard.json"
fi

GRAFANA_VOLUME_NAME=${GRAFANA_VOLUME_NAME:-grafana_data}

# === FUNCTIONS ===

function usage() {
  echo "Grafana Control Script"
  echo
  echo "Usage:"
  echo "  ./grafanactl.sh start         - Start Grafana"
  echo "  ./grafanactl.sh stop          - Stop Grafana"
  echo "  ./grafanactl.sh restart       - Restart Grafana"
  echo "  ./grafanactl.sh status        - Show container status"
  echo "  ./grafanactl.sh logs          - Tail Grafana logs"
  echo "  ./grafanactl.sh shell         - Open shell in Grafana container"
  echo "  ./grafanactl.sh delete_all    - Full reset (stop, rm, volume)"
  echo
}

function start() {
  if docker ps -a --format '{{.Names}}' | grep -q "^${GRAFANA_CONTAINER_NAME}$"; then
    echo "[!] Container '${GRAFANA_CONTAINER_NAME}' already exists."
    echo "    Starting existing container..."
    docker start "${GRAFANA_CONTAINER_NAME}"
  else
    echo "[*] Creating and starting Grafana container..."
    docker run -d \
      --name "${GRAFANA_CONTAINER_NAME}" \
      --network "${NETWORK_NAME}" \
      -p ${GRAFANA_PORT}:3000 \
      -e GF_SECURITY_ADMIN_USER="${GRAFANA_ADMIN_USER}" \
      -e GF_SECURITY_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD}" \
      -e GF_INSTALL_PLUGINS="grafana-piechart-panel,marcusolsson-gantt-panel" \
      -v ${GRAFANA_VOLUME_NAME}:/var/lib/grafana \
      grafana/grafana:${GRAFANA_VERSION}
  fi
}

function stop() {
  echo "[*] Stopping Grafana..."
  docker stop "${GRAFANA_CONTAINER_NAME}" || true
}

function restart() {
  stop
  start
}

function status() {
  docker ps -a | grep "${GRAFANA_CONTAINER_NAME}" || echo "[!] Container not found."
}

function logs() {
  docker logs -f "${GRAFANA_CONTAINER_NAME}" --tail 100
}

function shell() {
  docker exec -it "${GRAFANA_CONTAINER_NAME}" /bin/bash
}

function down() {
  echo "[*] Removing Grafana container and volume..."
  docker stop "${GRAFANA_CONTAINER_NAME}" 2>/dev/null || true
  docker rm "${GRAFANA_CONTAINER_NAME}" 2>/dev/null || true
  docker volume rm "${GRAFANA_VOLUME_NAME}" 2>/dev/null || true
}

function delete_all() {
  echo "[*] Full Grafana cleanup in progress..."
  down
  echo "[✓] All Grafana data and container removed."
}

# === ENTRYPOINT ===
case "$1" in
  start) start ;;
  stop) stop ;;
  restart) restart ;;
  status) status ;;
  logs) logs ;;
  shell) shell ;;
  delete_all) delete_all ;;
  help | --help | -h) usage ;;
  *) echo "Unknown command: $1" ; usage ;;
esac

