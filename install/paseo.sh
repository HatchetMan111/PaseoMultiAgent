#!/usr/bin/env bash
#
# Paseo Proxmox LXC Installer – im Stil der Proxmox VE Community Scripts
#
# App:      Paseo – Control Plane for Coding Agents (Claude Code, Codex, OpenCode, Pi …)
# Upstream: https://github.com/getpaseo/paseo
# Stack:    Node.js/TypeScript (offizielles Docker-Image) – Daemon + gebündelte Web UI
# Läuft:    vollständig lokal im LXC, keine Cloud nötig (eigene Provider-CLIs/Keys mitbringen)
# Host:     DAS SKRIPT LÄUFT AUF DEM PROXMOX-HOST (nicht im Container!)
# Usage:
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/PaseoMultiAgent/main/install/paseo.sh)"
#   PASEO_PASSWORD=meinpw CT_ID=150 CORES=2 RAM=2048 DISK=8 bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/PaseoMultiAgent/main/install/paseo.sh)"
#   bash paseo.sh --ctid 150 --cores 2 --memory 2048 --disk 8 --bridge vmbr0 --password meinpw --debug
#
# HINWEIS: Paseo ist leichtgewichtig (kein embedded containerd wie Memoh).
# Darum: UNPRIVILEGIERTER LXC mit nesting=1 reicht, 2 vCPU / 2 GB / 8 GB Standard.
# Wer Agent-Workloads mit viel Build-Last plant: CORES=4 RAM=4096 wählen.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Variablen (oben, Community-Scripts-konform – alles hier anpassbar)
# ---------------------------------------------------------------------------
APP="paseo"                                     # Container-Hostname + Service-Name
WEB_PORT="6767"                                 # Paseo Daemon + Web UI (0.0.0.0:6767 im Container)
PASEO_IMAGE="ghcr.io/getpaseo/paseo:latest"

DEFAULT_CORES="2"                               # vCPU
DEFAULT_RAM="2048"                              # RAM in MB
DEFAULT_SWAP="512"                              # Swap (MB)
DEFAULT_DISK="8"                                # Disk in GB
DEFAULT_BRIDGE="vmbr0"
DEFAULT_TEMPLATE_STORE="local"                  # Storage für CT-Templates
DEFAULT_OS="debian-12-standard"                 # Template-Familie (Docker-getestet)
UNPRIVILEGED="1"                                # 1 = unprivilegiert (reicht für Paseo + nesting)
FEATURES="nesting=1"                            # Docker-im-LXC nötig

# Umgebungs-Overrides: PASEO_PASSWORD=meinpw CT_ID=150 CORES=4 ./paseo.sh
CT_ID_ARG="${CT_ID:-${CTID:-}}"
CORES_ARG="${CORES:-$DEFAULT_CORES}"
RAM_ARG="${RAM:-$DEFAULT_RAM}"
DISK_ARG="${DISK:-$DEFAULT_DISK}"
PASEO_PASSWORD_ARG="${PASEO_PASSWORD:-}"
PASSWORD_ARG=""

DEBUG="${DEBUG:-0}"
LOG_FILE="/tmp/${APP}-install-$(date +%F-%H%M%S).log"
SCRIPT_ARGS="$*"

# ---------------------------------------------------------------------------
# Logging / Farben (Community-Scripts-Stil)
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\e[0m' C_BOLD=$'\e[1m' C_RED=$'\e[31m' C_GREEN=$'\e[32m' \
  C_YELLOW=$'\e[33m' C_BLUE=$'\e[34m' C_CYAN=$'\e[36m'
else
  C_RESET="" C_BOLD="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_CYAN=""
fi

msg_info()  { echo -e "${C_BLUE}[INFO]${C_RESET}  $*"; }
msg_ok()    { echo -e "${C_GREEN}[OK]${C_RESET}    $*"; }
msg_warn()  { echo -e "${C_YELLOW}[WARN]${C_RESET}  $*"; }
msg_error() { echo -e "${C_RED}[ERROR]${C_RESET} $*" >&2; }

# Vollständige Ausgabe ins Log (komplette Kette, nicht nur letzte Zeile)
exec > >(tee -i "$LOG_FILE") 2>&1
msg_info "Logdatei: $LOG_FILE"
[[ "$DEBUG" == "1" ]] && { echo "--- DEBUG: set -x aktiv ---"; set -x; }

# Bei Fehlern: komplette Kette ausgeben (Befehl, Zeile, Exit-Code, Log-Verweis)
trap 'ec=$?; msg_error "FEHLER: Befehl »${BASH_COMMAND}« scheiterte in Zeile ${LINENO} (Exit ${ec})."; msg_error "Vollständiges Log: ${LOG_FILE} – bei Bedarf erneut mit --debug laufen lassen."; exit ${ec}' ERR

usage() {
  cat <<EOF
${APP} Proxmox LXC Installer

Usage:
  bash paseo.sh [OPTIONEN]
  PASEO_PASSWORD=meinpw CT_ID=150 bash paseo.sh
  bash -c "\$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/PaseoMultiAgent/main/install/paseo.sh)"

Optionen:
  --ctid ID            Container-ID (Default: nächste freie ID via 'pvesh get /cluster/nextid')
  --hostname NAME      Hostname (Default: ${APP})
  --cores N            vCPU (Default: ${DEFAULT_CORES})
  --memory MB          RAM in MB (Default: ${DEFAULT_RAM})
  --disk GB            Disk in GB (Default: ${DEFAULT_DISK})
  --storage NAME       RootFS-Storage (Default: auto, bevorzugt local-lvm)
  --template-store N   Template-Storage (Default: ${DEFAULT_TEMPLATE_STORE})
  --bridge NAME        Netzwerk-Bridge (Default: ${DEFAULT_BRIDGE})
  --password PW        Paseo-Passwort (Default: env PASEO_PASSWORD oder 'change-me' – UNBEDINGT ÄNDERN!)
  --ssh-key PATH       SSH Public Key in den Container übernehmen (optional)
  --debug              bash -x + maximale Fehlermeldungskette
  -h, --help           diese Hilfe
EOF
}

# ---------------------------------------------------------------------------
# Argumente
# ---------------------------------------------------------------------------
CT_ID="$CT_ID_ARG" HOSTNAME_ARG="$APP" CORES="$CORES_ARG" RAM="$RAM_ARG" DISK="$DISK_ARG"
STORAGE_ARG="" TEMPLATE_STORE="$DEFAULT_TEMPLATE_STORE" BRIDGE="$DEFAULT_BRIDGE"
SSH_KEY_ARG=""
[[ -n "$PASEO_PASSWORD_ARG" ]] && PASSWORD_ARG="$PASEO_PASSWORD_ARG"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ctid) CT_ID="$2"; shift 2;;
    --hostname) HOSTNAME_ARG="$2"; shift 2;;
    --cores) CORES="$2"; shift 2;;
    --memory|--ram) RAM="$2"; shift 2;;
    --disk) DISK="$2"; shift 2;;
    --storage) STORAGE_ARG="$2"; shift 2;;
    --template-store) TEMPLATE_STORE="$2"; shift 2;;
    --bridge) BRIDGE="$2"; shift 2;;
    --password) PASSWORD_ARG="$2"; shift 2;;
    --ssh-key) SSH_KEY_ARG="$2"; shift 2;;
    --debug) DEBUG="1"; set -x; shift;;
    -h|--help) usage; exit 0;;
    *) msg_error "Unbekannte Option: $1"; usage; exit 1;;
  esac
done

# Einfaches, selbst setzbares Passwort: Flag > Env > Default mit Warnung
if [[ -z "$PASSWORD_ARG" ]]; then
  PASSWORD_ARG="change-me"
  msg_warn "Kein --password / PASEO_PASSWORD gesetzt – nutze Default 'change-me'. UNBEDINGT nach der Installation ändern!"
fi

# ---------------------------------------------------------------------------
# 1. Host-Prüfung
# ---------------------------------------------------------------------------
[[ "$(id -u)" == "0" ]] || { msg_error "Bitte als root auf dem Proxmox-Host ausführen."; exit 1; }
command -v pct >/dev/null || { msg_error "pct nicht gefunden – kein Proxmox-Host?"; exit 1; }
command -v pvesh >/dev/null || { msg_error "pvesh nicht gefunden."; exit 1; }

[[ "$RAM" -ge 1024 ]] || { msg_error "RAM muss >= 1024 sein. Gewählt: $RAM"; exit 1; }
[[ "$CORES" -ge 1 ]] || { msg_error "CORES muss >= 1 sein. Gewählt: $CORES"; exit 1; }
[[ "$DISK" -ge 4 ]] || { msg_error "Disk muss >= 4 GB sein. Gewählt: $DISK"; exit 1; }

# Immer nächste freie ID, außer --ctid gesetzt
if [[ -z "$CT_ID" ]]; then
  CT_ID="$(pvesh get /cluster/nextid)"
  msg_info "Nächste freie CT-ID: $CT_ID"
fi

# RootFS-Storage: Argument > local-lvm (wenn vorhanden) > erstes verfügbares
if [[ -z "$STORAGE_ARG" ]]; then
  if pvesm status --storage local-lvm >/dev/null 2>&1; then STORAGE_ARG="local-lvm";
  else STORAGE_ARG="$(pvesm status -content rootdir | awk 'NR>1 {print $1; exit}')";
  fi
fi
[[ -n "$STORAGE_ARG" ]] || { msg_error "Kein RootFS-Storage gefunden."; exit 1; }
msg_info "Storage: $STORAGE_ARG | Template-Store: $TEMPLATE_STORE | Bridge: $BRIDGE"

# ---------------------------------------------------------------------------
# 2. Template sicherstellen (neuestes debian-12-standard)
# ---------------------------------------------------------------------------
msg_info "Prüfe LXC-Template ..."
pveam update >/dev/null 2>&1 || msg_warn "pveam update scheiterte – nutze vorhandene Templates."
AVAILABLE_TEMPLATES="$(pveam available --section system 2>/dev/null || true)"
# Hinweis: Proxmox liefert Templates heute als .tar.zst (nicht nur .tar.gz/.tar.xz).
TEMPLATE="$(printf '%s' "$AVAILABLE_TEMPLATES" | grep -oP "${DEFAULT_OS}[^ ]*amd64[^ ]*\.tar\.(gz|xz|zst)" | sort -V | tail -n1 || true)"
if [[ -z "${TEMPLATE:-}" ]]; then
  msg_warn "Kein ${DEFAULT_OS}-Template – suche neuestes Debian-Standard-Template als Fallback ..."
  TEMPLATE="$(printf '%s' "$AVAILABLE_TEMPLATES" | grep -oP "debian-[0-9]+-standard[^ ]*amd64[^ ]*\.tar\.(gz|xz|zst)" | sort -V | tail -n1 || true)"
fi
if [[ -z "${TEMPLATE:-}" ]]; then
  msg_error "Kein Debian-Standard-Template gefunden. Verfügbare System-Templates:"
  printf '%s\n' "$AVAILABLE_TEMPLATES" | head -n 20 >&2 || true
  msg_error "Bitte 'pveam update' manuell prüfen (Netz/DNS auf dem Host)."
  exit 1
fi
if ! pveam list "$TEMPLATE_STORE" 2>/dev/null | grep -q "$TEMPLATE"; then
  msg_info "Lade Template $TEMPLATE ..."
  pveam download "$TEMPLATE_STORE" "$TEMPLATE"
fi
msg_ok "Template bereit: $TEMPLATE_STORE:vztmpl/$TEMPLATE"

# ---------------------------------------------------------------------------
# 3. Container erstellen (idempotent: existiert die ID, wird aktualisiert)
# ---------------------------------------------------------------------------
if pct status "$CT_ID" >/dev/null 2>&1; then
  msg_warn "CT $CT_ID existiert – überspringe Erstellung (Update-Modus)."
else
  CT_PASSWORD="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 20)"
  msg_info "Erstelle CT $CT_ID ($HOSTNAME_ARG): $CORES vCPU / $RAM MB / ${DISK}G ..."
  pct create "$CT_ID" "${TEMPLATE_STORE}:vztmpl/${TEMPLATE}" \
    --hostname "$HOSTNAME_ARG" \
    --cores "$CORES" --memory "$RAM" --swap "$DEFAULT_SWAP" \
    --rootfs "${STORAGE_ARG}:${DISK}" \
    --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
    --unprivileged "$UNPRIVILEGED" --features "$FEATURES" \
    --onboot 1 --start 0 \
    --password "$CT_PASSWORD"
  msg_ok "CT $CT_ID erstellt (unprivilegiert, nesting, onboot=1)."
  msg_warn "CT-Root-Passwort (nur jetzt angezeigt): $CT_PASSWORD"
fi

if [[ -n "$SSH_KEY_ARG" ]]; then
  [[ -f "$SSH_KEY_ARG" ]] || { msg_error "SSH-Key nicht gefunden: $SSH_KEY_ARG"; exit 1; }
  pct push "$CT_ID" "$SSH_KEY_ARG" /root/.ssh/authorized_keys 2>/dev/null \
    || { pct exec "$CT_ID" -- mkdir -p /root/.ssh; pct push "$CT_ID" "$SSH_KEY_ARG" /root/.ssh/authorized_keys; }
fi

pct start "$CT_ID" 2>/dev/null || true
msg_info "Warte auf Container-Netz ..."
for i in $(seq 1 24); do
  sleep 5
  CT_IP="$(pct exec "$CT_ID" -- hostname -I 2>/dev/null | awk '{print $1}' || true)"
  [[ -n "${CT_IP:-}" ]] && break
done
[[ -n "${CT_IP:-}" ]] || { msg_error "Keine Container-IP (pct exec hostname -I). Netzwerk/Bridge prüfen."; exit 1; }
msg_ok "Container-IP: $CT_IP"

# ---------------------------------------------------------------------------
# 4. Docker + Paseo im Container (via pct exec, idempotent)
# ---------------------------------------------------------------------------
msg_info "Installiere Docker im Container ..."
# Hinweis: äußere Single-Quotes – der Block läuft dadurch 1:1 im Container,
# ohne dass die Host-Shell $ oder $(...) anfasst (kein Escaping nötig).
pct exec "$CT_ID" -- bash -c '
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  rm -f /etc/apt/sources.list.d/docker.list
  apt-get update
  apt-get install -y git curl openssl ca-certificates sudo gpg
  if ! command -v docker >/dev/null; then
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi
  docker compose version
'
# Hinweis: bewusst kein '| tail' hier – mit pipefail würde der trap sonst
# die Pipe (tail) statt des gescheiterten pct-Befehls melden. Voll-Output steht im Log.

msg_info "Schreibe Paseo-Stack nach /opt/paseo ..."
pct exec "$CT_ID" -- bash -c '
  set -euo pipefail
  mkdir -p /opt/paseo/workspace
'
COMPOSE_URL="${PASEO_COMPOSE_URL:-https://raw.githubusercontent.com/HatchetMan111/PaseoMultiAgent/main/install/docker-compose.yml}"
SERVICE_URL="${PASEO_SERVICE_URL:-https://raw.githubusercontent.com/HatchetMan111/PaseoMultiAgent/main/systemd/paseo.service}"
if pct exec "$CT_ID" -- curl -fsSL -o /opt/paseo/docker-compose.yml "$COMPOSE_URL" 2>/dev/null; then
  msg_ok "docker-compose.yml aus Repo übernommen."
else
  msg_warn "Compose-URL nicht erreichbar – schreibe Inline-Compose."
  pct push "$CT_ID" /dev/stdin /opt/paseo/docker-compose.yml <<'COMPOSE'
services:
  paseo:
    image: ghcr.io/getpaseo/paseo:latest
    container_name: paseo
    restart: unless-stopped
    ports:
      - "6767:6767"
    environment:
      PASEO_PASSWORD: "${PASEO_PASSWORD:-change-me}"
    volumes:
      - paseo-home:/home/paseo
      - ./workspace:/workspace

volumes:
  paseo-home:
COMPOSE
fi
# Passwort idempotent in /opt/paseo/.env ablegen (Compose liest ${PASEO_PASSWORD} daraus)
pct exec "$CT_ID" -- bash -c "set -euo pipefail; printf 'PASEO_PASSWORD=%s\n' '$PASSWORD_ARG' > /opt/paseo/.env; chmod 600 /opt/paseo/.env"

if pct exec "$CT_ID" -- curl -fsSL -o /etc/systemd/system/paseo.service "$SERVICE_URL" 2>/dev/null; then
  msg_ok "paseo.service aus Repo übernommen."
else
  msg_warn "Service-URL nicht erreichbar – schreibe Inline-Unit."
  pct push "$CT_ID" /dev/stdin /etc/systemd/system/paseo.service <<'UNIT'
[Unit]
Description=Paseo Control Plane for Coding Agents (Docker Compose)
Documentation=https://paseo.sh/docs/docker
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/paseo
ExecStart=/usr/bin/docker compose up -d --remove-orphans
ExecStop=/usr/bin/docker compose down
Restart=no

[Install]
WantedBy=multi-user.target
UNIT
fi
pct exec "$CT_ID" -- systemctl daemon-reload
pct exec "$CT_ID" -- systemctl enable --now paseo
# Firewall im LXC für Port 6767 öffnen (falls PVE-Firewall aktiv)
pct exec "$CT_ID" -- bash -c 'command -v ufw >/dev/null && ufw allow 6767/tcp || true'

# ---------------------------------------------------------------------------
# 5. Verifikation: Service + Web UI
# ---------------------------------------------------------------------------
msg_info "Verifiziere Installation ..."
pct exec "$CT_ID" -- systemctl is-active paseo || { msg_error "systemd-Service paseo ist nicht active."; pct exec "$CT_ID" -- systemctl status paseo --no-pager || true; exit 1; }
msg_ok "Service läuft (systemctl is-active paseo = active)."

# /api/health ist ohne Auth erreichbar (Liveness-Probe per Design) – idealer Check.
msg_info "Warte auf Web UI (max. 3 Min, Erststart zieht Image) ..."
WEB_OK=0
for _ in $(seq 1 18); do
  if pct exec "$CT_ID" -- curl -fs -m 10 "http://localhost:${WEB_PORT}/api/health" >/dev/null 2>&1; then WEB_OK=1; break; fi
  sleep 10
done
[[ "$WEB_OK" == "1" ]] \
  || { msg_error "Web UI antwortet nicht auf localhost:${WEB_PORT}/api/health."; pct exec "$CT_ID" -- docker compose -f /opt/paseo/docker-compose.yml logs --tail=50 paseo || true; exit 1; }
msg_ok "Web UI antwortet (HTTP 200 auf localhost:${WEB_PORT}/api/health)."
pct exec "$CT_ID" -- curl -fs -m 10 "http://localhost:${WEB_PORT}/" >/dev/null 2>&1 \
  || { msg_error "Statische Web UI (/) antwortet nicht."; exit 1; }
msg_ok "Statische Web UI (/) erreichbar."

echo ""
echo "════════════════ INSTALLATION ERFOLGREICH ════════════════"
echo "  App          : Paseo – Control Plane for Coding Agents"
echo "  Container    : CT $CT_ID (Hostname: $HOSTNAME_ARG, unprivilegiert, onboot=1)"
echo "  Ressourcen   : $CORES vCPU / $RAM MB RAM / $DISK GB Disk"
echo "  Web UI       : http://${CT_IP}:${WEB_PORT}"
echo "  Health       : http://${CT_IP}:${WEB_PORT}/api/health"
echo "  Passwort     : ${PASSWORD_ARG}  (nur jetzt angezeigt – danach ändern!)"
echo "  Service      : systemctl status paseo  (im Container via: pct enter $CT_ID)"
echo "  Stack        : cd /opt/paseo && docker compose ps / docker compose logs -f (im Container)"
echo "  Agent-CLIs   : Paseo-Image enthält KEINE Agent-CLIs – bei Bedarf Child-Image bauen (siehe README)"
echo "  Update       : Skript erneut laufen lassen (idempotent – docker compose pull + up -d)"
echo "  Deinstall    : pct stop $CT_ID && pct destroy $CT_ID"
echo "  Reboot-Test  : pct reboot $CT_ID && sleep 90 && curl -fs http://${CT_IP}:${WEB_PORT}/api/health"
echo "  Log          : $LOG_FILE"
echo "══════════════════════════════════════════════════════════"
