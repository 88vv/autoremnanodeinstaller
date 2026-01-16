#!/usr/bin/env bash
set -euo pipefail

USE_COLOR=0
if [[ -t 1 ]]; then
  USE_COLOR=1
fi

c_reset=$'\033[0m'
c_red=$'\033[31m'
c_green=$'\033[32m'
c_yellow=$'\033[33m'
c_cyan=$'\033[36m'
c_bold=$'\033[1m'

print_line() { printf '%s\n' "$*"; }

info() {
  if [[ $USE_COLOR -eq 1 ]]; then
    print_line "${c_cyan}${c_bold}[*]${c_reset} $*"
  else
    print_line "[*] $*"
  fi
}

ok() {
  if [[ $USE_COLOR -eq 1 ]]; then
    print_line "${c_green}${c_bold}[+]${c_reset} $*"
  else
    print_line "[+] $*"
  fi
}

warn() {
  if [[ $USE_COLOR -eq 1 ]]; then
    print_line "${c_yellow}${c_bold}[!]${c_reset} $*"
  else
    print_line "[!] $*"
  fi
}

err() {
  if [[ $USE_COLOR -eq 1 ]]; then
    print_line "${c_red}${c_bold}[x]${c_reset} $*"
  else
    print_line "[x] $*"
  fi
}

need_cmd() { command -v "$1" >/dev/null 2>&1; }

if ! need_cmd sudo; then
  err "sudo не найден. Установи sudo или запускай от root."
  exit 1
fi

if [[ "$(id -u)" -ne 0 ]]; then
  SUDO="sudo"
else
  SUDO=""
fi

export DEBIAN_FRONTEND=noninteractive

info "Remnawave node installer"
info "Сейчас вставь свой docker-compose.yml прямо сюда."
warn "Правило: после окончания вставки нажми Enter и ничего не трогай 2 секунды - скрипт сам продолжит."
print_line ""

compose_tmp="$(mktemp)"
: > "$compose_tmp"

got_any=0
idle_hits=0
idle_needed=2
idle_timeout=1

while true; do
  if IFS= read -r -t "$idle_timeout" line; then
    got_any=1
    idle_hits=0
    printf '%s\n' "$line" >> "$compose_tmp"
  else
    if [[ $got_any -eq 1 ]]; then
      idle_hits=$((idle_hits + 1))
      if [[ $idle_hits -ge $idle_needed ]]; then
        break
      fi
    fi
  fi
done

if [[ ! -s "$compose_tmp" ]]; then
  err "docker-compose ввод пустой."
  exit 1
fi

default_service_name="$(
  awk '
    $0 ~ /^services:[[:space:]]*$/ {in_services=1; next}
    in_services && $0 ~ /^[[:space:]]{2}[A-Za-z0-9_.-]+:[[:space:]]*$/ {
      gsub(/^[[:space:]]{2}/,"",$0); gsub(/:[[:space:]]*$/,"",$0); print; exit
    }
  ' "$compose_tmp" || true
)"

print_line ""
info "Какой сервис в compose нужно пропатчить (добавить volumes с логами)?"
info "Enter = взять первый сервис из compose."
read -r -p "Имя сервиса [${default_service_name:-не найдено}]: " service_name

if [[ -z "${service_name}" ]]; then
  service_name="${default_service_name}"
fi

if [[ -z "${service_name}" ]]; then
  err "Не смог определить сервис в compose. Укажи имя сервиса и запусти заново."
  exit 1
fi

ok "Выбран сервис: ${service_name}"

info "Ставлю Docker..."
$SUDO curl -fsSL https://get.docker.com | sh

info "Готовлю каталоги..."
$SUDO mkdir -p /opt/remnanode
$SUDO mkdir -p /var/log/remnanode

info "Создаю файлы логов (чтобы сторонние скрипты не спрашивали про создание)..."
$SUDO touch /var/log/remnanode/access.log
$SUDO touch /var/log/remnanode/error.log
$SUDO chmod 0644 /var/log/remnanode/access.log /var/log/remnanode/error.log || true

info "Пишу /opt/remnanode/docker-compose.yml"
$SUDO cp "$compose_tmp" /opt/remnanode/docker-compose.yml

info "Добавляю volume /var/log/remnanode:/var/log/remnanode (если его нет)"
patched_tmp="$(mktemp)"

awk -v target="$service_name" -v mount='- "/var/log/remnanode:/var/log/remnanode"' '
BEGIN {
  in_services=0
  in_target=0
  seen_mount=0
  has_vol_header=0
  inserted=0
}
function maybe_insert_before_leaving_service() {
  if (in_target && !inserted && !seen_mount) {
    if (!has_vol_header) {
      print "    volumes:"
    }
    print "      " mount
    inserted=1
  }
}
{
  line=$0

  if (line ~ /^services:[[:space:]]*$/) {
    in_services=1
    print line
    next
  }

  if (in_services && line ~ /^[[:space:]]{2}[A-Za-z0-9_.-]+:[[:space:]]*$/) {
    svc=line
    sub(/^[[:space:]]{2}/,"",svc)
    sub(/:[[:space:]]*$/,"",svc)

    if (in_target && svc != target) {
      maybe_insert_before_leaving_service()
      in_target=0
      seen_mount=0
      has_vol_header=0
      inserted=0
    }

    if (svc == target) {
      in_target=1
      seen_mount=0
      has_vol_header=0
      inserted=0
    }

    print line
    next
  }

  if (in_target) {
    if (index(line, "/var/log/remnanode:/var/log/remnanode") > 0) {
      seen_mount=1
    }

    if (line ~ /^[[:space:]]{4}volumes:[[:space:]]*$/) {
      has_vol_header=1
      print line
      if (!seen_mount && !inserted) {
        print "      " mount
        inserted=1
      }
      next
    }

    print line
    next
  }

  print line
}
END {
  maybe_insert_before_leaving_service()
}
' /opt/remnanode/docker-compose.yml > "$patched_tmp"

$SUDO mv "$patched_tmp" /opt/remnanode/docker-compose.yml
$SUDO chown root:root /opt/remnanode/docker-compose.yml
$SUDO chmod 0644 /opt/remnanode/docker-compose.yml

info "Ставлю logrotate..."
$SUDO apt update -y
$SUDO apt install -y logrotate

info "Пишу /etc/logrotate.d/remnanode"
$SUDO tee /etc/logrotate.d/remnanode >/dev/null <<'EOF'
/var/log/remnanode/*.log {
  size 50M
  rotate 5
  compress
  missingok
  notifempty
  copytruncate
}
EOF

info "Прогоняю logrotate (force, verbose)"
$SUDO logrotate -vf /etc/logrotate.d/remnanode || true

info "Запускаю remnawave docker compose..."
cd /opt/remnanode
$SUDO docker compose up -d

print_line ""
warn "Покажу логи docker compose 15 секунд (дальше продолжу установку)..."
if need_cmd timeout; then
  $SUDO timeout 15s docker compose logs -f -t || true
else
  $SUDO docker compose logs -t --tail 120 || true
fi

info "Ставлю xray-torrent-blocker..."
cd /opt
if [[ -d /opt/xray-torrent-blocker ]]; then
  warn "/opt/xray-torrent-blocker уже существует - пропускаю clone."
else
  $SUDO git clone https://github.com/kutovoys/xray-torrent-blocker.git
fi

cd /opt/xray-torrent-blocker

info "Ставлю зависимости (без вопросов apt)..."
$SUDO apt update -y
$SUDO apt install -y curl iptables jq git expect conntrack

info "Запускаю install.sh и автоматически отвечаю на вопросы..."
$SUDO expect <<'EXPECT'
set timeout -1
log_user 1

proc answer {pattern value} {
  expect {
    -re $pattern { send -- "$value\r" }
    timeout { return }
  }
}

spawn env DEBIAN_FRONTEND=noninteractive bash install.sh

# Путь к логу
answer {(?i)enter.*path.*log|log.*file.*monitor|укаж.*путь.*лог|путь.*лог} "/var/log/remnanode/access.log"

# Если вдруг спросит про создание файла
answer {(?i)does not exist.*create.*\?\s*\(y\/n\)|do you want to create it.*\?\s*\(y\/n\)|создат.*\?\s*\(y\/n\)} "y"

# Выбор firewall: "Select firewall (1-2):"
answer {(?i)select.*firewall.*\(1-2\)|select.*firewall|firewalls:.*1\).*iptables.*2\).*nft} "1"

# Если apt вдруг спросит подтверждение (Y/n)
while {1} {
  expect {
    -re {(?i)do you want to continue\?\s*\[y\/n\]} { send -- "Y\r"; exp_continue }
    -re {(?i)\(y\/n\)|\[y\/n\]} { send -- "Y\r"; exp_continue }
    eof { break }
    timeout { exp_continue }
  }
}

EXPECT

info "Включаю и запускаю tblocker..."
$SUDO systemctl daemon-reload
$SUDO systemctl enable tblocker
$SUDO systemctl start tblocker

ok "Все успешно."
warn "Логи tblocker (Ctrl+C чтобы выйти):"
$SUDO journalctl -u tblocker -f
