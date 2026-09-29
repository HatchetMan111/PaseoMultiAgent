# Paseo auf Proxmox – Einzeiler-Installation (Community-Scripts-Stil)

> Upstream-App (kein Teil dieses Repos): `https://github.com/getpaseo/paseo`
> Dieses Repo enthält **nur den Proxmox-Installer**: Install-Script + Compose-Template + systemd-Unit.
> Die App läuft aus dem offiziellen Image (`ghcr.io/getpaseo/paseo:latest`) – vollständig lokal, keine Cloud nötig
> (eigene Agent-CLIs/Keys mitbringen: Claude Code, Codex, OpenCode, Pi …).

## Einzeiler (auf dem Proxmox-Host als root)

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/PaseoMultiAgent/main/install/paseo.sh)"
```

Mit eigenem (einfachem) Passwort und Anpassungen – ID immer **nächste freie**, außer gesetzt:

```bash
PASEO_PASSWORD=meinpw bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/PaseoMultiAgent/main/install/paseo.sh)"
PASEO_PASSWORD=meinpw CT_ID=150 CORES=2 RAM=2048 DISK=8 bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/PaseoMultiAgent/main/install/paseo.sh)"
bash paseo.sh --password meinpw --ctid 150 --cores 2 --memory 2048 --disk 8 --bridge vmbr0 --storage local-lvm
bash paseo.sh --debug   # = bash -x, komplette Fehlermeldungskette + Log unter /tmp/paseo-install-*.log
```

| Eigenschaft | Wert |
|---|---|
| App-Name / Hostname | `paseo` |
| Zweck | Control Plane für Coding Agents – Agenten parallel auf eigenen Maschinen fahren, von Phone/Desktop aus |
| Tech-Stack | Node.js/TypeScript (Docker-Image `ghcr.io/getpaseo/paseo:latest`: Daemon + gebündelte Web UI) |
| Web UI | `http://<LXC-IP>:6767`, Health `http://<LXC-IP>:6767/api/health` (bind `0.0.0.0` via Docker-Port) |
| Standard-Ressourcen | 2 vCPU / 2048 MB RAM / 8 GB Disk (unprivilegiert, `nesting=1`, `onboot: 1`) |
| CT-ID | immer die **nächste freie ID** (`pvesh get /cluster/nextid`), außer `--ctid` gesetzt |
| Template | `debian-12-standard` (neuestes auf Storage `local`) |

Das Skript (`set -euo pipefail`, idempotent, `trap ERR` mit Befehl+Zeile+Exit-Code):
1. prüft Host/Tools, nimmt die nächste freie CT-ID, erkennt RootFS-Storage
   (bevorzugt `local-lvm`), lädt das neueste `debian-12-standard`-Template falls nötig,
2. erstellt den LXC `paseo` (`onboot: 1`, unprivilegiert + `nesting=1`),
3. installiert im Container Docker + Compose-Plugin, schreibt `/opt/paseo/docker-compose.yml`
   + `/opt/paseo/.env` (mit deinem `PASEO_PASSWORD`), `paseo.service`, `systemctl enable --now paseo`,
4. verifiziert `systemctl is-active paseo` + HTTP auf `localhost:6767/api/health` und `/`
   und gibt die finale URL + Container-IP aus.

Erwartete Schlussausgabe (Beispiel):

```text
[OK]    Service läuft (systemctl is-active paseo = active).
[OK]    Web UI antwortet (HTTP 200 auf localhost:6767/api/health).
[OK]    Statische Web UI (/) erreichbar.

════════════════ INSTALLATION ERFOLGREICH ════════════════
  App          : Paseo – Control Plane for Coding Agents
  Container    : CT 100 (Hostname: paseo, unprivilegiert, onboot=1)
  Ressourcen   : 2 vCPU / 2048 MB RAM / 8 GB Disk
  Web UI       : http://192.168.1.100:6767
  Health       : http://192.168.1.100:6767/api/health
  Passwort     : meinpw  (nur jetzt angezeigt – danach ändern!)
  ...
  Log          : /tmp/paseo-install-2026-....log
══════════════════════════════════════════════════════════
```

Danach im Browser `http://<LXC-IP>:6767` öffnen und als Direktverbindung dasselbe Passwort eintragen.

## Agent-CLIs nachinstallieren (wichtig)

Das offizielle Image enthält **keine** Agent-CLIs. Bei Bedarf Child-Image bauen (laut `paseo.sh/docs/docker`):

```dockerfile
FROM ghcr.io/getpaseo/paseo:latest
USER root
RUN npm install -g @openai/codex @anthropic-ai/claude-code opencode-ai
```

```bash
docker build -t paseo-with-agents /opt/paseo
# in /opt/paseo/docker-compose.yml image: paseo-with-agents setzen, dann:
systemctl restart paseo
```

Alternativ im Container: `docker exec -it --user paseo paseo codex` (Login-Flow, Credentials persistieren in `/home/paseo`).

## Reboot-Test (Reboot-sicher belegen)

```bash
CT=100
pct reboot $CT
sleep 90
pct exec $CT -- systemctl is-active paseo
curl -fs http://<LXC-IP>:6767/api/health && echo HEALTH_OK
curl -fs http://<LXC-IP>:6767/ >/dev/null && echo WEB_UI_OK
```

## Update / Deinstall

```bash
bash paseo.sh --ctid 100 --password meinpw   # Update: idempotent (compose pull + up -d)
pct stop 100 && pct destroy 100              # Deinstall
```

## Debugging

- Jeder Fehler gibt Befehl + Zeile + Exit-Code aus, Voll-Log unter `/tmp/paseo-install-*.log`.
- `bash paseo.sh --debug` für `bash -x`-Trace.
- Im Container: `cd /opt/paseo && docker compose ps`, `docker compose logs --tail=100 paseo`.

## Dateien

- `install/paseo.sh` – Proxmox-Einzeiler (Host, root).
- `install/docker-compose.yml` – Compose-Template (wird in den CT nach `/opt/paseo/` übernommen, Fallback inline im Script).
- `systemd/paseo.service` – Compose-Wrapper (`After=network-online.target`, Docker-Abhängigkeit, `enable --now`).
