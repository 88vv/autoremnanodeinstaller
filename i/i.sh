#!/usr/bin/env bash
set -euo pipefail

if ! command -v sudo >/dev/null 2>&1; then
  echo "Ошибка: sudo не найден. Установите sudo или запускайте скрипт от root."
  exit 1
fi

echo "Remnawave node installer"
echo "------------------------"
echo "Сейчас вы вставите содержимое docker-compose.yml."
echo "Завершите ввод одной строкой: __EOF__"
echo

compose_tmp="$(mktemp)"
: > "$compose_tmp"

while IFS= read -r line; do
  if [[ "$line" == "__EOF__" ]]; then
    break
  fi
  printf '%s\n' "$line" >> "$compose_tmp"
done

if [[ ! -s "$compose_tmp" ]]; then
  echo "Ошибка: docker-compose.yml пустой."
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

echo
echo "Какой сервис в docker-compose.yml нужно пропатчить (добавить volumes с логами)?"
echo "Если оставить пустым - будет выбран первый сервис из compose."
read -r -p "Имя сервиса [${default_service_name:-не найдено}]: " service_name

if [[ -z "${service_name}" ]]; then
  service_name="${default_service_name}"
fi

if [[ -z "${service_name}" ]]; then
  echo "Ошибка: не удалось определить сервис в compose. Укажите имя сервиса и запустите скрипт заново."
  exit 1
fi

echo
echo "Выбран сервис: ${service_name}"
echo "Будет добавлен volume: /var/log/remnanode:/var/log/remnanode (если его нет)."
echo

sudo curl -fsSL https://get.docker.com | sh

sudo mkdir -p /opt/remnanode
sudo mkdir -p /var/log/remnanode

sudo cp "$compose_tmp" /opt/remnanode/docker-compose.yml

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

  # Detect start of a service at indent=2
  if (in_services && line ~ /^[[:space:]]{2}[A-Za-z0-9_.-]+:[[:space:]]*$/) {
    svc=line
    sub(/^[[:space:]]{2}/,"",svc)
    sub(/:[[:space:]]*$/,"",svc)

    # If we are leaving the target service, insert missing block before new service
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
      # Вставляем сразу после volumes:, если монтирования еще не было в сервисе
      if (!seen_mount && !inserted) {
        print "      " mount
        inserted=1
      }
      next
    }

    # Если встретили другой верхнеуровневый ключ того же уровня, продолжаем без вставки (вставка будет при выходе)
    print line
    next
  }

  print line
}
END {
  # EOF: если target сервис был последним - вставляем в конец
  maybe_insert_before_leaving_service()
}
' /opt/remnanode/docker-compose.yml > "$patched_tmp"

sudo mv "$patched_tmp" /opt/remnanode/docker-compose.yml
sudo chown root:root /opt/remnanode/docker-compose.yml
sudo chmod 0644 /opt/remnanode/docker-compose.yml

sudo apt update -y
sudo apt install -y logrotate

sudo tee /etc/logrotate.d/remnanode >/dev/null <<'EOF'
/var/log/remnanode/*.log {
  size 50M
  rotate 5
  compress
  missingok
  notifempty
  copytruncate
}
EOF

sudo logrotate -vf /etc/logrotate.d/remnanode || true

cd /opt/remnanode
sudo docker compose up -d

echo
echo "Показываю логи docker compose (15 секунд), дальше установка продолжится..."
echo
if command -v timeout >/dev/null 2>&1; then
  sudo timeout 15s docker compose logs -f -t || true
else
  sudo docker compose logs -t --tail 80 || true
fi

cd /opt
if [[ -d /opt/xray-torrent-blocker ]]; then
  echo
  echo "Каталог /opt/xray-torrent-blocker уже существует, пропускаю git clone."
else
  sudo git clone https://github.com/kutovoys/xray-torrent-blocker.git
fi

cd /opt/xray-torrent-blocker
sudo apt install -y curl iptables jq git expect

echo
echo "Запускаю установку xray-torrent-blocker и отвечаю на вопросы установщика..."
echo

sudo expect <<'EXPECT'
set timeout -1
spawn bash install.sh
expect {
  -re "(?i)log.*file|path.*log|access\\.log|укаж.*лог|путь.*лог" {
    send "/var/log/remnanode/access.log\r"
  }
  timeout {
    # если промпт не распознан, пробуем просто отправить путь
    send "/var/log/remnanode/access.log\r"
  }
}
expect {
  -re "(?i)select|choose|вариант|номер|option|menu" {
    send "1\r"
  }
  timeout {
    send "1\r"
  }
}
expect eof
EXPECT

sudo systemctl daemon-reload
sudo systemctl enable tblocker
sudo systemctl start tblocker

echo
echo "Все успешно установлено."
echo "Логи сервиса tblocker (Ctrl+C для выхода):"
echo

sudo journalctl -u tblocker -f
