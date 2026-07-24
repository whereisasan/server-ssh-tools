#!/bin/bash
set -euo pipefail

CONFIG="/etc/ssh/sshd_config"
SSH_DIR="/root/.ssh"
AUTH_KEYS="$SSH_DIR/authorized_keys"
BANNER_FILE="/etc/issue.net"
LOCK_FILE="/var/lock/secure_ssh.sh.lock"
BACKUP_DIR="/var/backups/secure_ssh"
ORIG_BACKUP="$BACKUP_DIR/sshd_config.orig"
PRERUN_DIR="$BACKUP_DIR/pre-run"

MARK_BEGIN="# >>> secure_ssh.sh managed block >>>"
MARK_END="# <<< secure_ssh.sh managed block <<<"

RESTART=0
SNAPSHOT=""
DROPIN_DIR=""
DROPIN_FILE=""

# === GitHub username ===
GITHUB_USER="whereisasan"

# === Ограничение списка пользователей (по умолчанию выключено) ===
# Задаётся через окружение, т.к. неверное значение приводит к потере доступа:
#   SSH_ALLOW_USERS="root deploy" ./secure_ssh.sh
#   SSH_ALLOW_GROUPS="sshusers" ./secure_ssh.sh
SSH_ALLOW_USERS="${SSH_ALLOW_USERS:-}"
SSH_ALLOW_GROUPS="${SSH_ALLOW_GROUPS:-}"

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

# ---------------------------------------------------------------------------
# Предварительные проверки
# ---------------------------------------------------------------------------

if [ "$EUID" -ne 0 ]; then
    echo "[ERROR] Скрипт должен запускаться от root"
    exit 1
fi

REQUIRED_CMDS=(curl sshd systemctl flock awk cmp mktemp)
MISSING_CMDS=()
for cmd in "${REQUIRED_CMDS[@]}"; do
    command -v "$cmd" >/dev/null 2>&1 || MISSING_CMDS+=("$cmd")
done
if [ "${#MISSING_CMDS[@]}" -gt 0 ]; then
    echo "[ERROR] Не найдены необходимые команды: ${MISSING_CMDS[*]}"
    exit 1
fi

if [ ! -f "$CONFIG" ]; then
    echo "[ERROR] Не найден $CONFIG"
    exit 1
fi

# Не даём запустить два экземпляра скрипта одновременно
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    echo "[ERROR] Другой экземпляр скрипта уже выполняется"
    exit 1
fi

cleanup() {
    [ -n "$SNAPSHOT" ] && [ -d "$SNAPSHOT" ] && rm -rf "$SNAPSHOT"
    return 0
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Вспомогательные функции
# ---------------------------------------------------------------------------

version_ge() {
    [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" = "$1" ]
}

is_valid_pubkey() {
    local line="$1"
    [[ "$line" =~ ^(ssh-rsa|ssh-ed25519|ssh-dss|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)\ [A-Za-z0-9+/]+=*([[:space:]].*)?$ ]]
}

# Комментирует активные вхождения ключевого слова в глобальной секции файла.
# Строки внутри Match-блоков и внутри управляемого блока не трогаются.
comment_key() {
    local file="$1" key="$2"
    [ -f "$file" ] || return 0

    local tmp
    tmp=$(mktemp)
    awk -v key="$key" -v mb="$MARK_BEGIN" -v me="$MARK_END" '
        BEGIN { inmatch = 0; inblock = 0 }
        $0 == mb { inblock = 1; print; next }
        $0 == me { inblock = 0; print; next }
        inblock  { print; next }
        {
            if (tolower($1) == "match") inmatch = 1
            if (!inmatch && tolower($1) == tolower(key)) {
                print "#" $0
                next
            }
            print
        }
    ' "$file" > "$tmp"

    if cmp -s "$tmp" "$file"; then
        rm -f "$tmp"
    else
        cat "$tmp" > "$file"   # cat, а не mv — сохраняем владельца и права
        rm -f "$tmp"
        echo "[UPDATE] $key отключён в $file"
        RESTART=1
    fi

    # Про Match-блоки только предупреждаем: это осознанные исключения админа
    awk -v key="$key" -v f="$file" '
        { if (tolower($1) == "match") inmatch = 1
          else if (inmatch && tolower($1) == tolower(key))
              print "[WARN] " key " задан внутри Match-блока в " f ":" NR " — оставлен без изменений" }
    ' "$file"
}

render_conf() {
    printf '%s\n' "$MARK_BEGIN"
    printf '# Управляется secure_ssh.sh — ручные правки будут перезаписаны.\n'
    local line
    for line in "${CONF_LINES[@]}"; do
        printf '%s\n' "$line"
    done
    printf '%s\n' "$MARK_END"
}

ensure_trailing_newline() {
    local file="$1"
    [ -s "$file" ] || return 0
    if [ "$(tail -c1 "$file" | wc -l)" -eq 0 ]; then
        printf '\n' >> "$file"
        echo "[FIX] Добавлен отсутствовавший перенос строки в конец $file"
    fi
}

snapshot_create() {
    SNAPSHOT=$(mktemp -d)
    cp -a "$CONFIG" "$SNAPSHOT/sshd_config"
    if [ -n "$DROPIN_DIR" ] && [ -d "$DROPIN_DIR" ]; then
        mkdir -p "$SNAPSHOT/dropin"
        cp -a "$DROPIN_DIR/." "$SNAPSHOT/dropin/"
    fi
}

snapshot_restore() {
    cp -a "$SNAPSHOT/sshd_config" "$CONFIG"
    # Проверка $DROPIN_DIR обязательна: при пустом значении rm ушёл бы в корень
    if [ -n "$DROPIN_DIR" ] && [ -d "$DROPIN_DIR" ] && [ -d "$SNAPSHOT/dropin" ]; then
        rm -f "$DROPIN_DIR"/*.conf
        cp -a "$SNAPSHOT/dropin/." "$DROPIN_DIR/"
    fi
}

# ---------------------------------------------------------------------------
# Загружаем и проверяем публичные ключи (до любых изменений в системе)
# ---------------------------------------------------------------------------

echo "[INFO] Загружаю публичные ключи с GitHub пользователя $GITHUB_USER..."
if ! RAW_KEYS=$(curl -fsSL --connect-timeout 10 --max-time 20 "https://github.com/${GITHUB_USER}.keys"); then
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

# ---------------------------------------------------------------------------
# Определяем окружение: версия OpenSSH, drop-in каталог, юнит systemd
# ---------------------------------------------------------------------------

OPENSSH_VERSION="$(sshd -V 2>&1 | grep -oE 'OpenSSH_[0-9]+\.[0-9]+' | grep -oE '[0-9]+\.[0-9]+' | head -n1 || true)"
if [ -z "$OPENSSH_VERSION" ]; then
    OPENSSH_VERSION="$(ssh -V 2>&1 | grep -oE 'OpenSSH_[0-9]+\.[0-9]+' | grep -oE '[0-9]+\.[0-9]+' | head -n1 || true)"
fi
if [ -n "$OPENSSH_VERSION" ]; then
    echo "[INFO] Обнаружен OpenSSH $OPENSSH_VERSION"
else
    echo "[WARN] Не удалось определить версию OpenSSH — применяю консервативные настройки"
fi

# В sshd_config выигрывает ПЕРВОЕ вхождение параметра, а Include на Debian 12 /
# Ubuntu 22.04+ стоит в начале файла. Поэтому свои настройки кладём в drop-in,
# который сортируется раньше остальных (00-*), а конфликты гасим отдельно.
INCLUDE_PATH="$(awk 'tolower($1) == "include" { print $2; exit }' "$CONFIG" || true)"
if [ -n "$INCLUDE_PATH" ]; then
    case "$INCLUDE_PATH" in
        /*) ;;
        *) INCLUDE_PATH="/etc/ssh/$INCLUDE_PATH" ;;
    esac
    if [ "$(basename "$INCLUDE_PATH")" = "*.conf" ]; then
        DROPIN_DIR="$(dirname "$INCLUDE_PATH")"
        DROPIN_FILE="$DROPIN_DIR/00-secure-ssh-hardening.conf"
        echo "[INFO] Найден Include $INCLUDE_PATH — настройки пойдут в $DROPIN_FILE"
    else
        echo "[WARN] Include с нестандартным шаблоном ($INCLUDE_PATH) — пишу напрямую в $CONFIG"
    fi
else
    echo "[INFO] Include не найден — настройки пойдут прямо в $CONFIG"
fi

SSH_UNIT=""
for unit in ssh.service sshd.service; do
    if systemctl cat "$unit" >/dev/null 2>&1; then
        if [ -z "$SSH_UNIT" ] || systemctl is-active --quiet "$unit"; then
            SSH_UNIT="$unit"
        fi
    fi
done
if [ -z "$SSH_UNIT" ]; then
    echo "[ERROR] Не найден systemd-юнит SSH (ни ssh.service, ни sshd.service)"
    exit 1
fi
echo "[INFO] SSH-юнит: $SSH_UNIT"

SOCKET_ACTIVE=0
if systemctl is-active --quiet ssh.socket 2>/dev/null; then
    SOCKET_ACTIVE=1
fi

# ---------------------------------------------------------------------------
# Резервные копии
# ---------------------------------------------------------------------------

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

if [ ! -f "$ORIG_BACKUP" ]; then
    cp -a "$CONFIG" "$ORIG_BACKUP"
    echo "[INFO] Исходный конфиг сохранён: $ORIG_BACKUP"
fi

rm -rf "$PRERUN_DIR"
mkdir -p "$PRERUN_DIR"
cp -a "$CONFIG" "$PRERUN_DIR/sshd_config"
if [ -n "$DROPIN_DIR" ] && [ -d "$DROPIN_DIR" ]; then
    mkdir -p "$PRERUN_DIR/sshd_config.d"
    cp -a "$DROPIN_DIR/." "$PRERUN_DIR/sshd_config.d/"
fi
echo "[INFO] Копия конфигурации до запуска: $PRERUN_DIR"

snapshot_create

# ---------------------------------------------------------------------------
# Формируем набор параметров
# ---------------------------------------------------------------------------

CONF_LINES=()
add_param() { CONF_LINES+=("$1 $2"); }

add_param "Port" "22"
add_param "PermitRootLogin" "prohibit-password"
add_param "PasswordAuthentication" "no"
add_param "PermitEmptyPasswords" "no"
add_param "PubkeyAuthentication" "yes"
add_param "UsePAM" "yes"
add_param "LoginGraceTime" "30"
add_param "MaxAuthTries" "3"
add_param "ClientAliveInterval" "300"
add_param "ClientAliveCountMax" "2"
add_param "X11Forwarding" "no"
add_param "AllowTcpForwarding" "no"
add_param "LogLevel" "INFO"
add_param "Banner" "$BANNER_FILE"

# KbdInteractiveAuthentication появился в OpenSSH 8.7 взамен
# устаревшего ChallengeResponseAuthentication
if [ -n "$OPENSSH_VERSION" ] && version_ge "$OPENSSH_VERSION" "8.7"; then
    add_param "KbdInteractiveAuthentication" "no"
else
    add_param "ChallengeResponseAuthentication" "no"
fi

# Современная криптография (имена алгоритмов доступны начиная с OpenSSH 7.4)
if [ -n "$OPENSSH_VERSION" ] && version_ge "$OPENSSH_VERSION" "7.4"; then
    add_param "KexAlgorithms" "curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512,diffie-hellman-group-exchange-sha256"
    add_param "Ciphers" "chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr"
    add_param "MACs" "hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,umac-128-etm@openssh.com"
    # HostKeyAlgorithms сужаем только если у сервера есть подходящий ключ,
    # иначе sshd останется вообще без host key
    if [ -f /etc/ssh/ssh_host_ed25519_key ] || [ -f /etc/ssh/ssh_host_rsa_key ]; then
        add_param "HostKeyAlgorithms" "ssh-ed25519,ssh-ed25519-cert-v01@openssh.com,rsa-sha2-512,rsa-sha2-512-cert-v01@openssh.com,rsa-sha2-256,rsa-sha2-256-cert-v01@openssh.com"
    else
        echo "[WARN] Не найдены ed25519/RSA host key — HostKeyAlgorithms не сужается"
    fi
else
    echo "[INFO] OpenSSH < 7.4 или версия не определена — криптонастройки пропущены"
fi

if [ -n "$SSH_ALLOW_USERS" ]; then
    add_param "AllowUsers" "$SSH_ALLOW_USERS"
    echo "[INFO] Доступ ограничен пользователями: $SSH_ALLOW_USERS"
fi
if [ -n "$SSH_ALLOW_GROUPS" ]; then
    add_param "AllowGroups" "$SSH_ALLOW_GROUPS"
    echo "[INFO] Доступ ограничен группами: $SSH_ALLOW_GROUPS"
fi

MANAGED_KEYS=()
for line in "${CONF_LINES[@]}"; do
    MANAGED_KEYS+=("${line%% *}")
done

# ---------------------------------------------------------------------------
# Гасим конфликтующие директивы везде, кроме нашего блока
# ---------------------------------------------------------------------------

CONFLICT_FILES=("$CONFIG")
if [ -n "$DROPIN_DIR" ] && [ -d "$DROPIN_DIR" ]; then
    for f in "$DROPIN_DIR"/*.conf; do
        [ -f "$f" ] || continue
        [ "$f" = "$DROPIN_FILE" ] && continue
        CONFLICT_FILES+=("$f")
    done
fi

for f in "${CONFLICT_FILES[@]}"; do
    for key in "${MANAGED_KEYS[@]}"; do
        comment_key "$f" "$key"
    done
    comment_key "$f" "AcceptEnv"
    # Protocol удалён из OpenSSH 7.4 — просто мусор в конфиге
    if [ -n "$OPENSSH_VERSION" ] && version_ge "$OPENSSH_VERSION" "7.4"; then
        comment_key "$f" "Protocol"
    fi
    # На новых версиях ChallengeResponseAuthentication заменён на KbdInteractive
    if [ -n "$OPENSSH_VERSION" ] && version_ge "$OPENSSH_VERSION" "8.7"; then
        comment_key "$f" "ChallengeResponseAuthentication"
    fi
done

# ---------------------------------------------------------------------------
# Записываем управляемый блок
# ---------------------------------------------------------------------------

if [ -n "$DROPIN_FILE" ]; then
    mkdir -p "$DROPIN_DIR"
    chmod 755 "$DROPIN_DIR"
    NEW_CONF=$(mktemp)
    render_conf > "$NEW_CONF"
    if [ -f "$DROPIN_FILE" ] && cmp -s "$NEW_CONF" "$DROPIN_FILE"; then
        echo "[OK] $DROPIN_FILE уже актуален"
    else
        cat "$NEW_CONF" > "$DROPIN_FILE"
        echo "[UPDATE] Настройки записаны в $DROPIN_FILE"
        RESTART=1
    fi
    rm -f "$NEW_CONF"
    chown root:root "$DROPIN_FILE"
    chmod 600 "$DROPIN_FILE"
else
    # Без Include пишем блок в основной конфиг — обязательно ДО первого Match,
    # иначе параметры попадут внутрь условного блока
    BLOCK=$(render_conf)
    TMP_A=$(mktemp)
    TMP_B=$(mktemp)
    awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
        $0 == b { skip = 1; next }
        $0 == e { skip = 0; next }
        !skip   { print }
    ' "$CONFIG" > "$TMP_A"
    awk -v block="$BLOCK" '
        BEGIN { inserted = 0 }
        tolower($1) == "match" && !inserted { print block; inserted = 1 }
        { print }
        END { if (!inserted) print block }
    ' "$TMP_A" > "$TMP_B"
    if cmp -s "$TMP_B" "$CONFIG"; then
        echo "[OK] $CONFIG уже актуален"
    else
        cat "$TMP_B" > "$CONFIG"
        echo "[UPDATE] Настройки записаны в $CONFIG"
        RESTART=1
    fi
    rm -f "$TMP_A" "$TMP_B"
fi

# ---------------------------------------------------------------------------
# Баннер
# ---------------------------------------------------------------------------

if [ -f "$BANNER_FILE" ] && cmp -s <(echo "$BANNER_TEXT") "$BANNER_FILE"; then
    echo "[OK] Баннер уже установлен и совпадает"
else
    echo "$BANNER_TEXT" > "$BANNER_FILE"
    echo "[UPDATE] Баннер записан в $BANNER_FILE"
    RESTART=1
fi

# ---------------------------------------------------------------------------
# Права и проверка синтаксиса
# ---------------------------------------------------------------------------

chown root:root "$CONFIG"
chmod 600 "$CONFIG"

if ! sshd -t -f "$CONFIG"; then
    echo "[ERROR] Проверка sshd -t не пройдена, откатываю конфигурацию"
    snapshot_restore
    exit 1
fi

# ---------------------------------------------------------------------------
# Публичные ключи
# ---------------------------------------------------------------------------

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
touch "$AUTH_KEYS"
chmod 600 "$AUTH_KEYS"
ensure_trailing_newline "$AUTH_KEYS"

for key in "${VALID_KEYS[@]}"; do
    blob=$(awk '{print $2}' <<< "$key")
    if awk -v blob="$blob" '$2 == blob { found = 1 } END { exit !found }' "$AUTH_KEYS"; then
        echo "[OK] Ключ уже есть в $AUTH_KEYS"
    else
        printf '%s\n' "$key" >> "$AUTH_KEYS"
        echo "[ADD] Новый ключ добавлен в $AUTH_KEYS"
    fi
done

# На системах с SELinux (RHEL/CentOS) нужно восстановить контексты,
# иначе sshd может отказаться использовать authorized_keys
if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce)" != "Disabled" ]; then
    if command -v restorecon >/dev/null 2>&1; then
        restorecon -R "$SSH_DIR"
        echo "[INFO] SELinux-контексты для $SSH_DIR восстановлены"
    else
        echo "[WARN] SELinux активен, но restorecon не найден — контексты для $SSH_DIR не обновлены"
    fi
fi

# ---------------------------------------------------------------------------
# Применяем конфигурацию
# ---------------------------------------------------------------------------

if [ "$RESTART" -ne 1 ]; then
    echo "[INFO] Изменений нет, перезагрузка не требуется"
    exit 0
fi

echo "[INFO] Были изменения, применяю конфигурацию..."

if [ "$SOCKET_ACTIVE" -eq 1 ]; then
    echo "[WARN] SSH работает через ssh.socket — порт задаётся в сокет-юните,"
    echo "[WARN] параметр Port из sshd_config игнорируется"
    if ! systemctl restart ssh.socket; then
        echo "[ERROR] Не удалось перезапустить ssh.socket"
        exit 1
    fi
    echo "[OK] ssh.socket перезапущен"
fi

if systemctl is-active --quiet "$SSH_UNIT"; then
    # reload (SIGHUP) не рвёт существующие сессии, в отличие от restart
    if systemctl reload "$SSH_UNIT" 2>/dev/null; then
        echo "[OK] $SSH_UNIT перечитал конфигурацию"
    elif systemctl restart "$SSH_UNIT"; then
        echo "[OK] $SSH_UNIT перезапущен"
    else
        echo "[ERROR] Не удалось применить конфигурацию в $SSH_UNIT"
        exit 1
    fi
else
    echo "[INFO] $SSH_UNIT не запущен — применять нечего"
fi
