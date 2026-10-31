#!/bin/sh
# secure_ssh.sh — идемпотентная настройка OpenSSH-сервера.
#
#   * загружает публичные ключи администратора с GitHub и кладёт их в
#     authorized_keys нужных пользователей (по умолчанию root + SUDO_USER);
#   * применяет безопасные параметры sshd: через drop-in в sshd_config.d
#     (OpenSSH >= 8.2) или правкой sshd_config перед первым блоком Match;
#   * ставит баннер, проверяет конфиг (sshd -t), откатывает при ошибке,
#     перезагружает sshd только при реальных изменениях и показывает
#     эффективные значения (sshd -T).
#
# POSIX sh: работает в bash, dash и busybox ash (Debian, Ubuntu, Alpine,
# CentOS 7, RHEL-семейство). Параметры задаются переменными окружения
# или флагами, см. --help.
set -eu

VERSION="2.0.0"

# ---------- Параметры (переменные окружения или флаги) ----------
GITHUB_USER="${GITHUB_USER:-whereisasan}"
TARGET_USERS="${TARGET_USERS:-}"                 # пусто = root + SUDO_USER
SSH_PORT="${SSH_PORT:-}"                         # пусто = порт не трогаем
PERMIT_ROOT_LOGIN="${PERMIT_ROOT_LOGIN:-prohibit-password}"
ALLOW_TCP_FORWARDING="${ALLOW_TCP_FORWARDING:-yes}"
X11_FORWARDING="${X11_FORWARDING:-no}"
MAX_AUTH_TRIES="${MAX_AUTH_TRIES:-6}"
LOGIN_GRACE_TIME="${LOGIN_GRACE_TIME:-30}"
CLIENT_ALIVE_INTERVAL="${CLIENT_ALIVE_INTERVAL:-300}"
CLIENT_ALIVE_COUNT_MAX="${CLIENT_ALIVE_COUNT_MAX:-2}"
LOG_LEVEL="${LOG_LEVEL:-INFO}"
DISABLE_ACCEPT_ENV="${DISABLE_ACCEPT_ENV:-yes}"  # комментировать "AcceptEnv LANG LC_*"
BANNER="${BANNER:-yes}"
BANNER_FILE="${BANNER_FILE:-/etc/issue.net}"
BANNER_ADMIN="${BANNER_ADMIN:-@whereisasan}"
SSHD_CONFIG="${SSHD_CONFIG:-/etc/ssh/sshd_config}"
DROPIN_NAME="${DROPIN_NAME:-00-secure-ssh.conf}"
CONFIG_MODE="${CONFIG_MODE:-auto}"               # auto | dropin | legacy
SSHD_BIN="${SSHD_BIN:-}"
DRY_RUN="${DRY_RUN:-no}"
NO_RELOAD="${NO_RELOAD:-no}"

usage() {
    cat <<USAGE
secure_ssh.sh v$VERSION — безопасная настройка sshd + ключи с GitHub.

Запуск:  sudo ./secure_ssh.sh [флаги]
         curl -fsSL <url>/secure_ssh.sh | sudo sh -s -- [флаги]
         curl -fsSL <url>/secure_ssh.sh | sudo TARGET_USERS=root,deploy sh

Флаги (в скобках переменная окружения и значение по умолчанию):
  -u, --github-user USER    пользователь GitHub, чьи ключи ставим (GITHUB_USER=$GITHUB_USER)
      --users U1,U2         кому класть ключи (TARGET_USERS; по умолчанию root + SUDO_USER)
  -p, --port N              порт sshd (SSH_PORT; по умолчанию порт НЕ меняется)
      --permit-root-login V yes|no|prohibit-password (PERMIT_ROOT_LOGIN=$PERMIT_ROOT_LOGIN)
      --tcp-forwarding V    yes|no, туннели и VS Code Remote (ALLOW_TCP_FORWARDING=$ALLOW_TCP_FORWARDING)
      --x11 V               yes|no (X11_FORWARDING=$X11_FORWARDING)
      --max-auth-tries N    (MAX_AUTH_TRIES=$MAX_AUTH_TRIES)
      --keep-accept-env     не комментировать "AcceptEnv LANG LC_*" (DISABLE_ACCEPT_ENV=no)
      --no-banner           не ставить баннер (BANNER=no)
      --banner-admin TEXT   подпись в баннере (BANNER_ADMIN=$BANNER_ADMIN)
      --mode auto|dropin|legacy  куда писать настройки (CONFIG_MODE=$CONFIG_MODE)
  -n, --dry-run             показать изменения, ничего не записывать
      --no-reload           не перезагружать sshd после изменений
  -h, --help                эта справка
  -V, --version             версия

Коды выхода: 0 — успех; 1 — ошибка (изменения откачены); 2 — настройки записаны,
но часть значений перекрыта другим файлом конфигурации (см. предупреждения).
USAGE
}

# ---------- Вывод ----------
say()    { printf '%s\n' "$*"; }
info()   { say "[INFO] $*"; }
ok()     { say "[OK] $*"; }
warn()   { say "[WARN] $*" >&2; }
die()    { say "[ERROR] $*" >&2; exit 1; }
change() {
    if [ "$DRY_RUN" = yes ]; then say "[DRY-RUN][$1] $2"; else say "[$1] $2"; fi
}
lower()  { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# ---------- Разбор аргументов ----------
need_arg() { [ "$#" -ge 2 ] || die "флаг $1 требует значение"; }
while [ "$#" -gt 0 ]; do
    case "$1" in
        -u|--github-user)    need_arg "$@"; GITHUB_USER="$2"; shift 2 ;;
        --users)             need_arg "$@"; TARGET_USERS="$2"; shift 2 ;;
        -p|--port)           need_arg "$@"; SSH_PORT="$2"; shift 2 ;;
        --permit-root-login) need_arg "$@"; PERMIT_ROOT_LOGIN="$2"; shift 2 ;;
        --tcp-forwarding)    need_arg "$@"; ALLOW_TCP_FORWARDING="$2"; shift 2 ;;
        --x11)               need_arg "$@"; X11_FORWARDING="$2"; shift 2 ;;
        --max-auth-tries)    need_arg "$@"; MAX_AUTH_TRIES="$2"; shift 2 ;;
        --keep-accept-env)   DISABLE_ACCEPT_ENV=no; shift ;;
        --no-banner)         BANNER=no; shift ;;
        --banner-admin)      need_arg "$@"; BANNER_ADMIN="$2"; shift 2 ;;
        --mode)              need_arg "$@"; CONFIG_MODE="$2"; shift 2 ;;
        -n|--dry-run)        DRY_RUN=yes; shift ;;
        --no-reload)         NO_RELOAD=yes; shift ;;
        -h|--help)           usage; exit 0 ;;
        -V|--version)        say "$VERSION"; exit 0 ;;
        *)                   die "неизвестный аргумент: $1 (см. --help)" ;;
    esac
done

is_yes_no() { case "$1" in yes|no) return 0 ;; *) return 1 ;; esac; }
is_uint()   { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

is_yes_no "$ALLOW_TCP_FORWARDING" || die "--tcp-forwarding: ожидается yes|no"
is_yes_no "$X11_FORWARDING"       || die "--x11: ожидается yes|no"
is_yes_no "$DISABLE_ACCEPT_ENV"   || die "DISABLE_ACCEPT_ENV: ожидается yes|no"
is_yes_no "$BANNER"               || die "BANNER: ожидается yes|no"
is_uint "$MAX_AUTH_TRIES"         || die "--max-auth-tries: ожидается число"
is_uint "$LOGIN_GRACE_TIME"       || die "LOGIN_GRACE_TIME: ожидается число"
is_uint "$CLIENT_ALIVE_INTERVAL"  || die "CLIENT_ALIVE_INTERVAL: ожидается число"
is_uint "$CLIENT_ALIVE_COUNT_MAX" || die "CLIENT_ALIVE_COUNT_MAX: ожидается число"
case "$PERMIT_ROOT_LOGIN" in
    yes|no|prohibit-password|without-password|forced-commands-only) ;;
    *) die "--permit-root-login: ожидается yes|no|prohibit-password" ;;
esac
case "$CONFIG_MODE" in auto|dropin|legacy) ;; *) die "--mode: ожидается auto|dropin|legacy" ;; esac
if [ -n "$SSH_PORT" ]; then
    if ! is_uint "$SSH_PORT" || [ "$SSH_PORT" -lt 1 ] || [ "$SSH_PORT" -gt 65535 ]; then
        die "--port: ожидается число 1..65535"
    fi
fi
case "$GITHUB_USER" in
    ''|*[!A-Za-z0-9-]*) die "GITHUB_USER содержит недопустимые символы: '$GITHUB_USER'" ;;
esac

# ---------- Предварительные проверки ----------
[ "$(id -u)" -eq 0 ] || die "скрипт нужно запускать от root (sudo)"

if [ -z "$SSHD_BIN" ]; then
    SSHD_BIN=$(command -v sshd 2>/dev/null || true)
fi
if [ -z "$SSHD_BIN" ]; then
    for p in /usr/sbin/sshd /usr/local/sbin/sshd /sbin/sshd; do
        if [ -x "$p" ]; then SSHD_BIN="$p"; break; fi
    done
fi
if [ -z "$SSHD_BIN" ] || [ ! -x "$SSHD_BIN" ]; then die "sshd не найден: установите openssh-server"; fi
[ -f "$SSHD_CONFIG" ] || die "файл $SSHD_CONFIG не найден"

TMPDIR_=$(mktemp -d 2>/dev/null || mktemp -d -t secure_ssh.XXXXXX)
APPLY_STARTED=0; APPLY_OK=0; ROLLED_BACK=0
RUN_BACKUP=""; DROPIN_SAVED=""; DROPIN_PATH=""; NEED_RELOAD=0

rollback() {
    [ "$ROLLED_BACK" = 1 ] && return 0
    ROLLED_BACK=1
    warn "Откатываю изменения конфигурации sshd..."
    if [ -n "$RUN_BACKUP" ] && [ -f "$RUN_BACKUP" ]; then
        cat "$RUN_BACKUP" > "$SSHD_CONFIG" && warn "$SSHD_CONFIG восстановлен из $RUN_BACKUP"
    fi
    case "$DROPIN_SAVED" in
        existing) cat "$TMPDIR_/dropin.prev" > "$DROPIN_PATH" && warn "$DROPIN_PATH восстановлен" ;;
        absent)   rm -f "$DROPIN_PATH" && warn "$DROPIN_PATH удалён" ;;
    esac
}
# shellcheck disable=SC2317  # вызывается из trap
cleanup() {
    rc=$?
    if [ "$rc" -ne 0 ] && [ "$APPLY_STARTED" = 1 ] && [ "$APPLY_OK" = 0 ]; then
        rollback
    fi
    rm -rf "$TMPDIR_"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ---------- Версия OpenSSH и режим записи настроек ----------
# Любая версия sshd печатает "OpenSSH_X.Y..." в ответ на -V (или в usage).
SSHD_VER=$("$SSHD_BIN" -V 2>&1 | grep -oE 'OpenSSH_[0-9]+\.[0-9]+' | head -n 1 | sed 's/OpenSSH_//' || true)
SSHD_MAJOR=${SSHD_VER%%.*}; SSHD_MINOR=${SSHD_VER#*.}
if ! is_uint "$SSHD_MAJOR" || ! is_uint "$SSHD_MINOR"; then
    warn "не удалось определить версию OpenSSH, считаю её старой (без Include)"
    SSHD_MAJOR=0; SSHD_MINOR=0
fi
ver_ge() { [ "$SSHD_MAJOR" -gt "$1" ] || { [ "$SSHD_MAJOR" -eq "$1" ] && [ "$SSHD_MINOR" -ge "$2" ]; }; }
info "sshd: $SSHD_BIN (OpenSSH $SSHD_MAJOR.$SSHD_MINOR), конфиг: $SSHD_CONFIG"

if [ "$PERMIT_ROOT_LOGIN" = prohibit-password ] && ! ver_ge 7 0; then
    PERMIT_ROOT_LOGIN=without-password   # до OpenSSH 7.0 значение называлось иначе
fi

# Первая активная строка Include и её шаблон
INCLUDE_LINENO=$(grep -niE '^[[:space:]]*Include[[:space:]]+' "$SSHD_CONFIG" | head -n 1 | cut -d: -f1 || true)
INCLUDE_PATTERN=""
if [ -n "$INCLUDE_LINENO" ]; then
    INCLUDE_PATTERN=$(sed -n "${INCLUDE_LINENO}p" "$SSHD_CONFIG" | awk '{print $2}' | tr -d '"')
    case "$INCLUDE_PATTERN" in /*) ;; *) INCLUDE_PATTERN="/etc/ssh/$INCLUDE_PATTERN" ;; esac
fi
FIRST_ACTIVE_LINENO=$(grep -nvE '^[[:space:]]*(#|$)' "$SSHD_CONFIG" | head -n 1 | cut -d: -f1 || true)

if [ "$CONFIG_MODE" = auto ]; then
    if ver_ge 8 2; then CONFIG_MODE=dropin; else CONFIG_MODE=legacy; fi
fi
if [ "$CONFIG_MODE" = dropin ] && ! ver_ge 8 2; then
    warn "OpenSSH $SSHD_MAJOR.$SSHD_MINOR не поддерживает Include, переключаюсь на режим legacy"
    CONFIG_MODE=legacy
fi
DROPIN_DIR="$(dirname "$SSHD_CONFIG")/sshd_config.d"
if [ "$CONFIG_MODE" = dropin ] && [ -n "$INCLUDE_PATTERN" ]; then
    case "$INCLUDE_PATTERN" in
        */\*.conf) DROPIN_DIR=$(dirname "$INCLUDE_PATTERN") ;;
        *) warn "необычный Include '$INCLUDE_PATTERN', переключаюсь на режим legacy"; CONFIG_MODE=legacy ;;
    esac
    if [ "$CONFIG_MODE" = dropin ] && [ "$INCLUDE_LINENO" != "$FIRST_ACTIVE_LINENO" ]; then
        warn "Include стоит не первой директивой в $SSHD_CONFIG: значения выше него перекроют drop-in (см. итоговую проверку)"
    fi
fi
info "режим записи настроек: $CONFIG_MODE"

# ---------- Ключи с GitHub: скачать и проверить ДО любых изменений ----------
fetch_url() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 10 --max-time 30 "$1"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -T 30 -O - "$1"
    else
        die "нужен curl или wget для загрузки ключей"
    fi
}
is_valid_key() {
    printf '%s\n' "$1" | grep -qE '^(ssh-(ed25519|rsa|dss)|ecdsa-sha2-nistp(256|384|521)|sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh\.com)[[:space:]]+[A-Za-z0-9+/]+={0,3}([[:space:]].*)?$' || return 1
    if command -v ssh-keygen >/dev/null 2>&1; then
        printf '%s\n' "$1" > "$TMPDIR_/one.pub"
        ssh-keygen -lf "$TMPDIR_/one.pub" >/dev/null 2>&1 || return 1
    fi
    return 0
}

KEYS_URL="https://github.com/${GITHUB_USER}.keys"
RAW_KEYS="$TMPDIR_/raw.keys"; VALID_KEYS="$TMPDIR_/valid.keys"
info "Загружаю ключи: $KEYS_URL"
if ! fetch_url "$KEYS_URL" > "$RAW_KEYS"; then
    die "не удалось скачать $KEYS_URL (нет сети, нет такого пользователя или GitHub недоступен). Ничего не меняю."
fi
: > "$VALID_KEYS"
while IFS= read -r line || [ -n "$line" ]; do
    line=$(printf '%s' "$line" | tr -d '\r')
    [ -n "$line" ] || continue
    if is_valid_key "$line"; then
        printf '%s\n' "$line" >> "$VALID_KEYS"
    else
        warn "строка из ответа GitHub не похожа на ключ и отброшена: $(printf '%.60s' "$line")"
    fi
done < "$RAW_KEYS"
N_KEYS=$(wc -l < "$VALID_KEYS" | tr -d ' ')
[ "$N_KEYS" -gt 0 ] || die "с GitHub не получено ни одного валидного ключа. Ничего не меняю."
ok "получено валидных ключей: $N_KEYS"

# ---------- Ключи: установить нужным пользователям ----------
if [ -z "$TARGET_USERS" ]; then
    TARGET_USERS="root"
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then TARGET_USERS="root,$SUDO_USER"; fi
fi
TARGET_USERS=$(printf '%s' "$TARGET_USERS" | tr ',;' '  ')

user_home() {
    if command -v getent >/dev/null 2>&1; then
        getent passwd "$1" | cut -d: -f6
    else
        awk -F: -v u="$1" '$1 == u { print $6 }' /etc/passwd
    fi
}
# Проверяем всех пользователей заранее, чтобы не остановиться на полпути
for u in $TARGET_USERS; do
    h=$(user_home "$u")
    [ -n "$h" ] || die "пользователь '$u' не найден"
    [ -d "$h" ] || die "домашний каталог $h пользователя '$u' не существует"
done

install_keys_for_user() {
    u="$1"; h=$(user_home "$u"); grp=$(id -gn "$u")
    sshdir="$h/.ssh"; ak="$sshdir/authorized_keys"
    added=0; present=0
    while read -r ktype kblob _rest; do
        if [ -f "$ak" ] && grep -qF -- "$kblob" "$ak"; then
            present=$((present + 1))
            continue
        fi
        added=$((added + 1))
        [ "$DRY_RUN" = yes ] && continue
        if [ ! -d "$sshdir" ]; then mkdir -p "$sshdir"; chmod 700 "$sshdir"; chown "$u:$grp" "$sshdir"; fi
        if [ ! -f "$ak" ]; then : > "$ak"; chmod 600 "$ak"; chown "$u:$grp" "$ak"; fi
        # защита от файла без завершающего перевода строки
        if [ -s "$ak" ] && [ -n "$(tail -c 1 "$ak")" ]; then printf '\n' >> "$ak"; fi
        printf '%s %s github:%s\n' "$ktype" "$kblob" "$GITHUB_USER" >> "$ak"
    done < "$VALID_KEYS"
    if [ "$added" -gt 0 ]; then
        change ADD "$u: добавлено ключей в $ak: $added (уже было: $present)"
    else
        ok "$u: все $present ключ(ей) уже в $ak"
    fi
    if [ "$DRY_RUN" != yes ] && [ -d "$sshdir" ]; then
        chmod 700 "$sshdir"; chmod 600 "$ak"; chown "$u:$grp" "$sshdir" "$ak"
        if command -v restorecon >/dev/null 2>&1; then restorecon -R "$sshdir" 2>/dev/null || true; fi
    fi
}
for u in $TARGET_USERS; do install_keys_for_user "$u"; done

# ---------- Настройки sshd ----------
managed_directives() {
    if [ -n "$SSH_PORT" ]; then printf 'Port %s\n' "$SSH_PORT"; fi
    printf 'PermitRootLogin %s\n' "$PERMIT_ROOT_LOGIN"
    printf 'PasswordAuthentication no\n'
    printf 'PermitEmptyPasswords no\n'
    printf 'PubkeyAuthentication yes\n'
    if ver_ge 8 7; then
        printf 'KbdInteractiveAuthentication no\n'
    else
        printf 'ChallengeResponseAuthentication no\n'
        printf 'KbdInteractiveAuthentication no\n'
    fi
    printf 'LoginGraceTime %s\n' "$LOGIN_GRACE_TIME"
    printf 'MaxAuthTries %s\n' "$MAX_AUTH_TRIES"
    printf 'ClientAliveInterval %s\n' "$CLIENT_ALIVE_INTERVAL"
    printf 'ClientAliveCountMax %s\n' "$CLIENT_ALIVE_COUNT_MAX"
    printf 'X11Forwarding %s\n' "$X11_FORWARDING"
    printf 'AllowTcpForwarding %s\n' "$ALLOW_TCP_FORWARDING"
    printf 'LogLevel %s\n' "$LOG_LEVEL"
    if [ "$BANNER" = yes ]; then printf 'Banner %s\n' "$BANNER_FILE"; fi
}

show_diff() {  # $1 = текущий файл (может отсутствовать), $2 = новый
    if command -v diff >/dev/null 2>&1; then
        diff -u "$1" "$2" 2>/dev/null | sed -e '1,2d' -e 's/^/    /' || true
    fi
}

backup_main() {
    [ -n "$RUN_BACKUP" ] && return 0
    if [ ! -f "$SSHD_CONFIG.orig" ]; then
        cp -p "$SSHD_CONFIG" "$SSHD_CONFIG.orig"
        info "первоначальная копия сохранена: $SSHD_CONFIG.orig"
    fi
    RUN_BACKUP="$SSHD_CONFIG.bak.$(date +%Y%m%d-%H%M%S)"
    cp -p "$SSHD_CONFIG" "$RUN_BACKUP"
    info "бэкап перед изменением: $RUN_BACKUP"
}

# apply_file НОВЫЙ ЦЕЛЕВОЙ main|dropin  -> 0 если файл изменён (или изменился бы), 1 если без изменений
apply_file() {
    src="$1"; dst="$2"; kind="$3"
    if [ -f "$dst" ] && cmp -s "$src" "$dst"; then return 1; fi
    if [ "$DRY_RUN" = yes ]; then
        if [ -f "$dst" ]; then show_diff "$dst" "$src"; else show_diff /dev/null "$src"; fi
        return 0
    fi
    if [ "$kind" = main ]; then
        backup_main
    elif [ -z "$DROPIN_SAVED" ]; then
        if [ -f "$dst" ]; then cp -p "$dst" "$TMPDIR_/dropin.prev"; DROPIN_SAVED=existing; else DROPIN_SAVED=absent; fi
    fi
    APPLY_STARTED=1
    if [ -f "$dst" ]; then
        cat "$src" > "$dst"
    else
        mkdir -p "$(dirname "$dst")"
        cat "$src" > "$dst"
        chmod 644 "$dst"
    fi
    NEED_RELOAD=1
    return 0
}

# Значение директивы в глобальной секции (до первого Match), первое вхождение
get_global() {
    awk -v lk="$(lower "$1")" '
        { f = $1; sub(/=.*/, "", f); lf = tolower(f) }
        lf == "match" { exit }
        lf == lk {
            v = $0
            sub(/^[[:space:]]*[^[:space:]=]+[[:space:]=]+/, "", v)
            sub(/[[:space:]]+$/, "", v)
            print v; exit
        }' "$2"
}
# Установить директиву в глобальной секции: заменить первое вхождение, убрать дубли,
# иначе вставить перед первым Match (или в конец). Строки внутри Match не трогаем.
set_global() {
    awk -v key="$1" -v val="$2" '
        BEGIN { lk = tolower(key); done = 0; inmatch = 0 }
        {
            f = $1; sub(/=.*/, "", f); lf = tolower(f)
            if (lf == "match") {
                if (!done) { print key " " val; done = 1 }
                inmatch = 1
            }
            if (!inmatch && lf == lk) {
                if (!done) { print key " " val; done = 1 }
                next
            }
            print
        }
        END { if (!done) print key " " val }' "$3"
}

apply_dropin() {
    DROPIN_PATH="$DROPIN_DIR/$DROPIN_NAME"
    if [ -z "$INCLUDE_PATTERN" ]; then
        {
            printf '# Добавлено secure_ssh.sh: файлы из sshd_config.d имеют приоритет (sshd берёт первое значение)\n'
            printf 'Include %s/*.conf\n\n' "$DROPIN_DIR"
            cat "$SSHD_CONFIG"
        } > "$TMPDIR_/main.new"
        if apply_file "$TMPDIR_/main.new" "$SSHD_CONFIG" main; then
            change UPDATE "в начало $SSHD_CONFIG добавлен Include $DROPIN_DIR/*.conf"
        fi
    fi
    {
        printf '# Управляется secure_ssh.sh v%s. Файл перезаписывается при каждом запуске, не редактируйте вручную.\n' "$VERSION"
        printf '# Имя с префиксом 00- даёт приоритет над 50-cloud-init.conf, 50-redhat.conf и т.п.\n'
        managed_directives
    } > "$TMPDIR_/dropin.new"
    if apply_file "$TMPDIR_/dropin.new" "$DROPIN_PATH" dropin; then
        change UPDATE "записан $DROPIN_PATH"
    else
        ok "$DROPIN_PATH уже актуален"
    fi
}

apply_legacy() {
    cp "$SSHD_CONFIG" "$TMPDIR_/main.new"
    managed_directives > "$TMPDIR_/directives"
    while read -r key val; do
        cur=$(get_global "$key" "$TMPDIR_/main.new")
        if [ "$(lower "$cur")" = "$(lower "$val")" ]; then
            ok "$key уже = $val"
            continue
        fi
        set_global "$key" "$val" "$TMPDIR_/main.new" > "$TMPDIR_/main.tmp"
        mv "$TMPDIR_/main.tmp" "$TMPDIR_/main.new"
        if [ -n "$cur" ]; then change UPDATE "$key: $cur -> $val"; else change ADD "$key -> $val"; fi
    done < "$TMPDIR_/directives"
    if apply_file "$TMPDIR_/main.new" "$SSHD_CONFIG" main; then
        info "$SSHD_CONFIG обновлён (директивы в глобальной секции, до первого Match)"
    fi
}

case "$CONFIG_MODE" in
    dropin) apply_dropin ;;
    legacy) apply_legacy ;;
esac

# AcceptEnv — накопительная директива, из drop-in её не отключить, поэтому комментируем в основном файле
if [ "$DISABLE_ACCEPT_ENV" = yes ]; then
    if grep -qE '^[[:space:]]*AcceptEnv[[:space:]]+LANG[[:space:]]+LC_\*' "$SSHD_CONFIG"; then
        sed -E 's/^([[:space:]]*)(AcceptEnv[[:space:]]+LANG[[:space:]]+LC_\*)/\1#\2/' "$SSHD_CONFIG" > "$TMPDIR_/main.ae"
        if apply_file "$TMPDIR_/main.ae" "$SSHD_CONFIG" main; then
            change UPDATE "AcceptEnv LANG LC_* закомментирован в $SSHD_CONFIG"
        fi
    else
        ok "AcceptEnv LANG LC_* отсутствует или уже закомментирован"
    fi
fi

# ---------- Баннер ----------
banner_text() {
    cat <<'ART'
__        ___   _ _____ ____  _____ ___ ____    _    ____    _    _   _
\ \      / / | | | ____|  _ \| ____|_ _/ ___|  / \  / ___|  / \  | \ | |
 \ \ /\ / /| |_| |  _| | |_) |  _|  | |\___ \ / _ \ \___ \ / _ \ |  \| |
  \ V  V / |  _  | |___|  _ <| |___ | | ___) / ___ \ ___) / ___ \| |\  |
   \_/\_/  |_| |_|_____|_| \_\_____|___|____/_/   \_\____/_/   \_\_| \_|

ART
    printf 'Administrator: %s\nUnauthorized access is prohibited!\n' "$BANNER_ADMIN"
}
if [ "$BANNER" = yes ]; then
    banner_text > "$TMPDIR_/banner"
    if [ -f "$BANNER_FILE" ] && cmp -s "$TMPDIR_/banner" "$BANNER_FILE"; then
        ok "баннер $BANNER_FILE уже актуален"
    else
        if [ "$DRY_RUN" != yes ]; then cat "$TMPDIR_/banner" > "$BANNER_FILE"; chmod 644 "$BANNER_FILE"; fi
        change UPDATE "баннер записан в $BANNER_FILE"
    fi
fi

# ---------- Проверка конфига и откат ----------
if [ "$DRY_RUN" = yes ]; then
    info "DRY-RUN: ничего не записано. Запустите без --dry-run для применения."
    exit 0
fi
if [ "$APPLY_STARTED" = 1 ]; then
    if out=$("$SSHD_BIN" -t -f "$SSHD_CONFIG" 2>&1); then
        ok "sshd -t: конфигурация корректна"
        APPLY_OK=1
    else
        say "$out" >&2
        rollback
        die "sshd -t нашёл ошибку в конфигурации, изменения откачены. sshd не перезапускался."
    fi
else
    APPLY_OK=1
    ok "конфигурация sshd не менялась"
fi

# ---------- Перезагрузка sshd ----------
reload_sshd() {
    if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
        unit=""
        for u in ssh sshd; do
            if systemctl cat "$u.service" >/dev/null 2>&1; then unit="$u.service"; break; fi
        done
        if [ -z "$unit" ]; then warn "systemd: юнит ssh.service/sshd.service не найден"; return 1; fi
        if [ -n "$SSH_PORT" ] && systemctl is-active --quiet ssh.socket 2>/dev/null; then
            systemctl daemon-reload && systemctl restart ssh.socket && info "ssh.socket перезапущен (новый порт $SSH_PORT)"
        fi
        if systemctl is-active --quiet "$unit"; then
            if systemctl reload "$unit" 2>/dev/null || systemctl restart "$unit"; then
                ok "$unit перезагружен"; return 0
            fi
            warn "не удалось перезагрузить $unit"; return 1
        fi
        info "$unit не активен (socket-активация): новые подключения получат новую конфигурацию"
        return 0
    fi
    if command -v rc-service >/dev/null 2>&1; then
        svc=sshd; if [ ! -e /etc/init.d/sshd ] && [ -e /etc/init.d/ssh ]; then svc=ssh; fi
        if rc-service "$svc" reload 2>/dev/null || rc-service "$svc" restart; then ok "OpenRC: $svc перезагружен"; return 0; fi
        warn "OpenRC: не удалось перезагрузить $svc"; return 1
    fi
    if command -v service >/dev/null 2>&1; then
        for s in ssh sshd; do
            if [ -e "/etc/init.d/$s" ]; then
                if service "$s" reload 2>/dev/null || service "$s" restart; then ok "service $s перезагружен"; return 0; fi
                warn "не удалось перезагрузить service $s"; return 1
            fi
        done
    fi
    for pf in /run/sshd.pid /var/run/sshd.pid; do
        if [ -f "$pf" ] && kill -HUP "$(cat "$pf")" 2>/dev/null; then ok "sshd получил SIGHUP (pid $(cat "$pf"))"; return 0; fi
    done
    warn "не удалось определить способ перезапуска sshd"
    return 1
}
if [ "$NEED_RELOAD" = 1 ]; then
    if [ "$NO_RELOAD" = yes ]; then
        warn "--no-reload: sshd не перезагружен, изменения вступят в силу после перезагрузки службы"
    elif ! reload_sshd; then
        warn "перезагрузите sshd вручную, иначе изменения не вступят в силу"
    fi
else
    info "изменений в конфигурации sshd нет, перезагрузка не требуется"
fi

# ---------- Эффективные значения (sshd -T) ----------
MISMATCH=0
if eff=$("$SSHD_BIN" -T -f "$SSHD_CONFIG" 2>/dev/null); then
    managed_directives > "$TMPDIR_/directives"
    while read -r key val; do
        k=$(lower "$key"); v=$(lower "$val")
        got=$(printf '%s\n' "$eff" | awk -v k="$k" '$1 == k { sub(/^[^ ]+ /, ""); print; exit }')
        [ "$k" = permitrootlogin ] && [ "$v" = prohibit-password ] && v=without-password
        if [ -z "$got" ] && [ "$k" = challengeresponseauthentication ]; then continue; fi
        if [ "$(lower "$got")" = "$v" ]; then
            ok "эффективно: $key $got"
        else
            MISMATCH=1
            warn "эффективно: $key = '${got:-?}', ожидалось '$val'. Значение перекрыто другим файлом или директивой выше по порядку (sshd берёт первое значение). Проверьте: $SSHD_BIN -T | grep -i $k"
        fi
    done < "$TMPDIR_/directives"
else
    warn "sshd -T недоступен, пропускаю проверку эффективных значений"
fi

say ""
info "Готово. Ключи ($N_KEYS) у пользователей: $TARGET_USERS. Режим: $CONFIG_MODE."
info "Не закрывая эту сессию, проверьте вход по ключу в НОВОМ окне терминала."
if [ "$MISMATCH" = 1 ]; then exit 2; fi
exit 0
