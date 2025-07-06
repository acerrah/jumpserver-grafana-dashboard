#!/usr/bin/env bash
set -e

# === LOAD ENV ===
ENV_FILE=".env"
if [[ -f "$ENV_FILE" ]]; then
  echo "[*] Loading config from $ENV_FILE"
  set -o allexport
  source "$ENV_FILE"
  set +o allexport
else
  echo "[!] Config file $ENV_FILE not found."
  exit 1
fi

# === PARSE JumpServer CONFIG ===
function detect_db_type() {
  echo "[*] Detecting JumpServer database config..."

  if [[ ! -f "$JS_CONFIG_PATH" ]]; then
    echo "[!] Config file not found at: $JS_CONFIG_PATH"
    read -rp "Enter full path to config.txt: " JS_CONFIG_PATH
    if [[ ! -f "$JS_CONFIG_PATH" ]]; then
      echo "[✗] File not found: $JS_CONFIG_PATH"
      exit 1
    fi
  fi

  echo "[✓] Using config file: $JS_CONFIG_PATH"

  DB_TYPE=$(grep -E "^DB_ENGINE=" "$JS_CONFIG_PATH" | cut -d= -f2)
  DB_HOST=$(grep -E "^DB_HOST=" "$JS_CONFIG_PATH" | cut -d= -f2)
  DB_PORT=$(grep -E "^DB_PORT=" "$JS_CONFIG_PATH" | cut -d= -f2)
  DB_USER=$(grep -E "^DB_USER=" "$JS_CONFIG_PATH" | cut -d= -f2)
  DB_PASSWORD=$(grep -E "^DB_PASSWORD=" "$JS_CONFIG_PATH" | cut -d= -f2)
  DB_NAME=$(grep -E "^DB_NAME=" "$JS_CONFIG_PATH" | cut -d= -f2)

  echo "[✓] DB: $DB_TYPE at $DB_HOST:$DB_PORT (user: $DB_USER)"
}

# === NETWORK CHECK ===
function ensure_network() {
  if ! docker network ls --format '{{.Name}}' | grep -q "^${NETWORK_NAME}$"; then
    echo "[!] Docker network '${NETWORK_NAME}' not found."
    echo "    Please make sure JumpServer is already running."
    exit 1
  fi
  echo "[✓] Docker network '${NETWORK_NAME}' found."
}

# === START GRAFANA ===
function start_grafana() {
  echo "[*] Starting Grafana container..."

  docker run -d \
    --name "${GRAFANA_CONTAINER_NAME}" \
    --network "${NETWORK_NAME}" \
    -p "${GRAFANA_PORT}:3000" \
    -e GF_SECURITY_ADMIN_USER="${GRAFANA_ADMIN_USER}" \
    -e GF_SECURITY_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD}" \
    -e "GF_INSTALL_PLUGINS=grafana-piechart-panel,marcusolsson-gantt-panel" \
    -v grafana_data:/var/lib/grafana \
    grafana/grafana:"${GRAFANA_VERSION}"

  echo "[✓] Grafana started at http://localhost:${GRAFANA_PORT}"
}

# === WAIT FOR GRAFANA ===
function wait_for_grafana() {
  echo -n "[*] Waiting for Grafana to become ready"
  for i in {1..30}; do
    if curl -s http://localhost:${GRAFANA_PORT}/api/health | grep -q '"database": "ok"'; then
      echo -e "\n[✓] Grafana is ready."
      return
    fi
    echo -n "."
    sleep 2
  done
  echo -e "\n[✗] Grafana failed to start within timeout."
  exit 1
}

# === ADD DATASOURCE ===
function add_datasource() {
  echo "[*] Adding data source to Grafana..."

  if [[ "$DB_TYPE" == "postgresql" ]]; then
    DS_TYPE="postgres"
  elif [[ "$DB_TYPE" == "mysql" ]]; then
    DS_TYPE="mysql"
  else
    echo "[x] Unknown DB_TYPE: $DB_TYPE"
    exit 1
  fi

  DS_JSON=$(cat <<EOF
{
  "name": "JumpServer-${DS_TYPE^}",
  "type": "${DS_TYPE}",
  "access": "proxy",
  "url": "${DB_HOST}:${DB_PORT}",
  "database": "${DB_NAME}",
  "user": "${DB_USER}",
  "uid": "JumpserverDatasource",
  "secureJsonData": {
    "password": "${DB_PASSWORD}"
  },
  "jsonData": {
    "sslmode": "disable"
  }
}
EOF
)

  local max_retries=3
  for (( attempt=1; attempt<=max_retries; attempt++ )); do
    echo "[*] Attempt $attempt to add datasource..."

    http_code=$(curl -s -o /tmp/ds_response.json -w "%{http_code}" -X POST \
      -H "Content-Type: application/json" \
      -u "${GRAFANA_ADMIN_USER}:${GRAFANA_ADMIN_PASSWORD}" \
      -d "${DS_JSON}" \
      http://localhost:${GRAFANA_PORT}/api/datasources)

    if [[ "$http_code" == "200" || "$http_code" == "202" ]]; then
      echo "[✓] Data source added successfully."
      return 0
    fi

    echo "[!] Failed (HTTP $http_code):"
    cat /tmp/ds_response.json
    sleep 2
  done

  echo "[✗] Failed to add datasource after $max_retries attempts."
  exit 1
}

# === IMPORT DASHBOARD ===
function import_dashboard() {
  if [[ "$DB_TYPE" == "postgresql" ]]; then
    DASHBOARD_JSON="jumpserver-audit-dashboard-postgresql.json"
  elif [[ "$DB_TYPE" == "mysql" ]]; then
    DASHBOARD_JSON="jumpserver-audit-dashboard-mysql.json"
  else
    echo "[!] Unknown DB_TYPE: $DB_TYPE"
    exit 1
  fi

  echo "[*] Importing dashboard: ${DASHBOARD_JSON}"

  if [[ ! -f "${DASHBOARD_JSON}" ]]; then
    echo "[✗] Dashboard file not found: ${DASHBOARD_JSON}"
    exit 1
  fi

  DASHBOARD_PAYLOAD=$(jq -n \
    --argjson dashboard "$(jq 'del(.id)' "${DASHBOARD_JSON}")" \
    '{dashboard: $dashboard, overwrite: true, folderId: 0, message: "Imported by quick-start"}')

  response=$(curl -s -w "%{http_code}" -o /tmp/dashboard_import_response.json \
    -X POST \
    -H "Content-Type: application/json" \
    -u "${GRAFANA_ADMIN_USER}:${GRAFANA_ADMIN_PASSWORD}" \
    -d "${DASHBOARD_PAYLOAD}" \
    http://localhost:${GRAFANA_PORT}/api/dashboards/db)

  if [[ "$response" == "200" || "$response" == "202" ]]; then
    echo "[✓] Dashboard imported."
  else
    echo "[✗] Failed to import dashboard. HTTP $response"
    cat /tmp/dashboard_import_response.json
    exit 1
  fi
}

# === MAIN ===
function main() {
  ensure_network
  detect_db_type
  start_grafana
  wait_for_grafana
  add_datasource
  import_dashboard
  echo "[✅] Setup complete. Access Grafana at http://localhost:${GRAFANA_PORT}"
}

main

