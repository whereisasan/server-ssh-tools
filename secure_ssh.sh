#!/bin/bash

CONFIG="/etc/ssh/sshd_config"
BACKUP="/etc/ssh/sshd_config.bak.$(date +%F_%T)"
SSH_DIR="/root/.ssh"
AUTH_KEYS="$SSH_DIR/authorized_keys"
BANNER_FILE="/etc/issue.net"

# === GitHub username ===
GITHUB_USER="whereisasan"

# === Текст баннера (можно кастомизировать) ===
BANNER_TEXT=$(cat <<EOF
###########################################
#   🚀 Добро пожаловать на сервер!       #
#   👨‍💻 Администратор: @whereisasan       #
#   ⚡ Несанкционированный доступ ⚡     #
###########################################
EOF
)

# Загружаем публичные ключи с GitHub
echo "[INFO] Загружаю публичные ключи с GitHub пользователя $GITHUB_USER..."
MY_PUB_KEYS=$(curl -s https://github.com/${GITHUB_USER}.keys)

if [ -z "$MY_PUB_KEYS" ]; then
    echo "[ERROR] Не удалось загрузить ключи с GitHub!"
    exit 1
fi

# Бэкап sshd_config (только один раз)
if [ ! -f "$BACKUP" ]; then
    cp $CONFIG $BACKUP
    echo "[INFO] Backup создан: $BACKUP"
fi

# Функция для установки параметра (идемпотентно)
set_param() {
    local key="$1"
    local value="$2"
    if grep -qE "^\s*${key}\s+${value}$" $CONFIG; then
        echo "[OK] ${key} уже = ${value}"
    elif grep -qE "^\s*${key}" $CONFIG; then
        sed -i "s|^\s*${key}.*|${key} ${value}|" $CONFIG
        echo "[UPDATE] ${key} -> ${value}"
        RESTART=1
    else
        echo "${key} ${value}" >> $CONFIG
        echo "[ADD] ${key} -> ${value}"
        RESTART=1
    fi
}

# Основные параметры безопасности
set_param "Port" "22"
set_param "Protocol" "2"
set_param "PermitRootLogin" "prohibit-password"
set_param "PasswordAuthentication" "no"
set_param "PermitEmptyPasswords" "no"
set_param "PubkeyAuthentication" "yes"
set_param "ChallengeResponseAuthentication" "no"
set_param "UsePAM" "yes"
set_param "LoginGraceTime" "30"
set_param "MaxAuthTries" "3"
set_param "ClientAliveInterval" "300"
set_param "ClientAliveCountMax" "2"
set_param "X11Forwarding" "no"
set_param "AllowTcpForwarding" "no"
set_param "LogLevel" "INFO"
set_param "Banner" "$BANNER_FILE"

# Устанавливаем баннер (идемпотентно)
if [ -f "$BANNER_FILE" ] && cmp -s <(echo "$BANNER_TEXT") "$BANNER_FILE"; then
    echo "[OK] Баннер уже установлен и совпадает"
else
    echo "$BANNER_TEXT" > "$BANNER_FILE"
    echo "[UPDATE] Баннер записан в $BANNER_FILE"
    RESTART=1
fi

# Добавляем публичные ключи (идемпотентно)
mkdir -p $SSH_DIR
chmod 700 $SSH_DIR
touch "$AUTH_KEYS"
chmod 600 "$AUTH_KEYS"

while IFS= read -r key; do
    if grep -qF "$key" "$AUTH_KEYS"; then
        echo "[OK] Ключ уже есть в $AUTH_KEYS"
    else
        echo "$key" >> "$AUTH_KEYS"
        echo "[ADD] Новый ключ добавлен в $AUTH_KEYS"
    fi
done <<< "$MY_PUB_KEYS"

# Перезапуск SSH только если были изменения
if [ "$RESTART" == "1" ]; then
    echo "[INFO] Были изменения. Перезапускаю SSH..."
    systemctl restart sshd && echo "[OK] SSH перезапущен" || echo "[ERROR] Не удалось перезапустить SSH"
else
    echo "[INFO] Изменений нет, перезапуск не требуется"
fi