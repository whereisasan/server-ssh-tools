#!/bin/bash
set -euo pipefail

CONFIG="/etc/ssh/sshd_config"
ORIG_BACKUP="/etc/ssh/sshd_config.orig.bak"
RUN_BACKUP="/etc/ssh/sshd_config.pre-run.bak"
SSH_DIR="/root/.ssh"
AUTH_KEYS="$SSH_DIR/authorized_keys"
BANNER_FILE="/etc/issue.net"
RESTART=0

# === GitHub username ===
GITHUB_USER="whereisasan"

# === Текст баннера (можно кастомизировать) ===
BANNER_TEXT=$(cat <<EOF
__        ___   _ _____ ____  _____ ___ ____    _    ____    _    _   _
\ \      / / | | | ____|  _ \| ____|_ _/ ___|  / \  / ___|  / \  | \ | |
 \ \ /\ / /| |_| |  _| | |_) |  _|  | |\___ \ / _ \ \___ \ / _ \ |  \| |
  \ V  V / |  _  | |___|  _ <| |___ | | ___) / ___ \ ___) / ___ \| |\  |
   \_/\_/  |_| |_|_____|_| \_\_____|___|____/_/   \_\____/_/   \_\_| \_|


Administrator: @whereisasan
Unauthorized access is prohibited!
EOF
)

# Проверка, что скрипт запущен от root
if [ "$EUID" -ne 0 ]; then
    echo "[ERROR] Скрипт должен запускаться от root"
    exit 1
fi

# Проверка, что похоже на валидный SSH-публичный ключ
is_valid_pubkey() {
    local line="$1"
    [[ "$line" =~ ^(ssh-rsa|ssh-ed25519|ssh-dss|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)\ [A-Za-z0-9+/]+=*([[:space:]].*)?$ ]]
}

# Загружаем публичные ключи с GitHub
echo "[INFO] Загружаю публичные ключи с GitHub пользователя $GITHUB_USER..."
if ! RAW_KEYS=$(curl -fsSL "https://github.com/${GITHUB_USER}.keys"); then
    echo "[ERROR] Не удалось загрузить ключи с GitHub (сетевая ошибка или пользователь/ключи не найдены)"
    exit 1
fi

if [ -z "$RAW_KEYS" ]; then
    echo "[ERROR] GitHub вернул пустой список ключей для $GITHUB_USER"
    exit 1
fi

VALID_KEYS=()
while IFS= read -r line; do
    [ -z "$line" ] && continue
    if is_valid_pubkey "$line"; then
        VALID_KEYS+=("$line")
    else
        echo "[WARN] Пропускаю строку, не похожую на SSH-ключ: ${line:0:40}..."
    fi
done <<< "$RAW_KEYS"

if [ "${#VALID_KEYS[@]}" -eq 0 ]; then
    echo "[ERROR] Ни одного валидного SSH-ключа не найдено, прерываю"
    exit 1
fi

# Бэкап оригинального sshd_config (создаётся один раз за всё время)
if [ ! -f "$ORIG_BACKUP" ]; then
    cp "$CONFIG" "$ORIG_BACKUP"
    echo "[INFO] Исходный конфиг сохранён: $ORIG_BACKUP"
fi

# Бэкап перед текущим запуском (для автоматического отката при ошибке)
cp "$CONFIG" "$RUN_BACKUP"

# Функция для установки параметра (идемпотентно)
set_param() {
    local key="$1"
    local value="$2"
    if grep -qE "^\s*${key}\s+${value}$" "$CONFIG"; then
        echo "[OK] ${key} уже = ${value}"
    elif grep -qE "^\s*${key}" "$CONFIG"; then
        sed -i "s|^\s*${key}.*|${key} ${value}|" "$CONFIG"
        echo "[UPDATE] ${key} -> ${value}"
        RESTART=1
    else
        echo "${key} ${value}" >> "$CONFIG"
        echo "[ADD] ${key} -> ${value}"
        RESTART=1
    fi
}

# Функция для комментирования параметра, если он присутствует (идемпотентно)
comment_param() {
    local pattern="$1"
    local desc="$2"
    if grep -qE "^\s*${pattern}$" "$CONFIG"; then
        sed -i -E "s|^\s*(${pattern})$|#\1|" "$CONFIG"
        echo "[UPDATE] ${desc} закомментирован"
        RESTART=1
    else
        echo "[OK] ${desc} уже закомментирован или отсутствует"
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

comment_param "AcceptEnv LANG LC_\*" "AcceptEnv LANG LC_*"

# Устанавливаем баннер (идемпотентно)
if [ -f "$BANNER_FILE" ] && cmp -s <(echo "$BANNER_TEXT") "$BANNER_FILE"; then
    echo "[OK] Баннер уже установлен и совпадает"
else
    echo "$BANNER_TEXT" > "$BANNER_FILE"
    echo "[UPDATE] Баннер записан в $BANNER_FILE"
    RESTART=1
fi

# Проверяем синтаксис конфига перед перезапуском; при ошибке — откат
if ! sshd -t -f "$CONFIG"; then
    echo "[ERROR] Проверка sshd -t не пройдена, откатываю конфиг из $RUN_BACKUP"
    cp "$RUN_BACKUP" "$CONFIG"
    exit 1
fi

# Добавляем публичные ключи (идемпотентно)
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
touch "$AUTH_KEYS"
chmod 600 "$AUTH_KEYS"

for key in "${VALID_KEYS[@]}"; do
    if grep -qF "$key" "$AUTH_KEYS"; then
        echo "[OK] Ключ уже есть в $AUTH_KEYS"
    else
        echo "$key" >> "$AUTH_KEYS"
        echo "[ADD] Новый ключ добавлен в $AUTH_KEYS"
    fi
done

# Перезапуск SSH только если были изменения
if [ "$RESTART" == "1" ]; then
    echo "[INFO] Были изменения. Перезапускаю SSH..."
    systemctl restart sshd && echo "[OK] SSH перезапущен" || echo "[ERROR] Не удалось перезапустить SSH"
else
    echo "[INFO] Изменений нет, перезапуск не требуется"
fi
