#!/bin/sh
# secure_ssh.sh — идемпотентная и безопасная настройка OpenSSH-сервера.
#
#   * загружает публичные ключи администратора с GitHub (или из файла/URL),
#     проверяет их и кладёт в authorized_keys нужных пользователей
#     (по умолчанию root + пользователь, вызвавший sudo/doas);
#   * применяет безопасные параметры sshd: через drop-in в sshd_config.d
#     (OpenSSH >= 8.2) или правкой sshd_config до первого Include/Match;
#   * проверяет будущую конфигурацию (sshd -t), пишет файлы атомарно,
#     откатывает при любой ошибке, перезагружает sshd только при изменениях,
#     проверяет, что sshd жив и слушает нужные порты, и показывает
#     эффективные значения (sshd -T), в том числе для каждого пользователя;
#   * умеет --dry-run, --check, --rollback и таймер автоотката --confirm.
#
# POSIX sh: bash, dash, busybox ash (Debian, Ubuntu, Alpine, CentOS 7,
# RHEL-семейство). Параметры задаются переменными окружения или флагами,
# см. --help. Весь код обёрнут в main(), поэтому оборванная загрузка
# через curl | sh ничего не выполнит.
# shellcheck disable=SC2015,SC2012,SC2317  # "A && B || C" здесь намеренно; стратегии reload вызываются по имени
set -eu

VERSION="2.1.0"

# ---------- Параметры (переменные окружения или флаги) ----------
# Пустое значение = «не задано»: берётся из состояния прошлого запуска
# (см. STATE_FILE), а если его нет — встроенное значение по умолчанию.
GITHUB_USER="${GITHUB_USER:-whereisasan}"
KEYS_URL="${KEYS_URL:-}"                         # альтернативный URL со списком ключей
KEYS_FILE="${KEYS_FILE:-}"                       # локальный файл с ключами (офлайн)
TARGET_USERS="${TARGET_USERS:-}"                 # пусто = root + SUDO_USER/DOAS_USER
SSH_PORT="${SSH_PORT:-}"                         # пусто = порт не трогаем
KEEP_OLD_PORT="${KEEP_OLD_PORT:-yes}"            # при смене порта старый остаётся открыт
PERMIT_ROOT_LOGIN="${PERMIT_ROOT_LOGIN:-}"       # по умолчанию prohibit-password
ALLOW_TCP_FORWARDING="${ALLOW_TCP_FORWARDING:-}" # по умолчанию yes
X11_FORWARDING="${X11_FORWARDING:-}"             # по умолчанию no
MAX_AUTH_TRIES="${MAX_AUTH_TRIES:-}"             # по умолчанию 6
LOGIN_GRACE_TIME="${LOGIN_GRACE_TIME:-}"         # по умолчанию 30
CLIENT_ALIVE_INTERVAL="${CLIENT_ALIVE_INTERVAL:-}"   # по умолчанию 300
CLIENT_ALIVE_COUNT_MAX="${CLIENT_ALIVE_COUNT_MAX:-}" # по умолчанию 2
LOG_LEVEL="${LOG_LEVEL:-}"                       # по умолчанию VERBOSE (в журнале отпечаток ключа); keep = не трогать
STRICT_AUTH="${STRICT_AUTH:-no}"                 # AuthenticationMethods publickey
ALLOW_GROUPS="${ALLOW_GROUPS:-}"                 # AllowGroups: только эти группы могут входить
IDLE_TIMEOUT="${IDLE_TIMEOUT:-}"                 # секунд простоя до закрытия сессии (OpenSSH >= 9.2)
ALLOW_AGENT_FORWARDING="${ALLOW_AGENT_FORWARDING:-}"  # пусто = не трогать
NO_PVE_TICKET="${NO_PVE_TICKET:-no}"             # на Proxmox не добавлять LC_PVE_TICKET в AcceptEnv
DISABLE_ACCEPT_ENV="${DISABLE_ACCEPT_ENV:-yes}"  # комментировать все глобальные AcceptEnv
ACCEPT_ENV="${ACCEPT_ENV:-}"                     # переменные, которые sshd всё же должен принимать (Proxmox: LC_PVE_TICKET)
BANNER="${BANNER:-yes}"
BANNER_FILE="${BANNER_FILE:-/etc/issue.net}"
BANNER_ADMIN="${BANNER_ADMIN:-@whereisasan}"
SSHD_CONFIG="${SSHD_CONFIG:-/etc/ssh/sshd_config}"
DROPIN_NAME="${DROPIN_NAME:-00-secure-ssh.conf}"
CONFIG_MODE="${CONFIG_MODE:-auto}"               # auto | dropin | legacy
SSHD_BIN="${SSHD_BIN:-}"
STATE_FILE="${STATE_FILE:-}"                     # по умолчанию <каталог конфига>/.secure_ssh.state
CONFIRM_TIMEOUT="${CONFIRM_TIMEOUT:-0}"          # >0 = ждать подтверждения N секунд, иначе откат
CONFIRM_FILE="${CONFIRM_FILE:-/run/secure_ssh.confirmed}"
DRY_RUN="${DRY_RUN:-no}"
NO_RELOAD="${NO_RELOAD:-no}"
RELOAD_METHOD="${RELOAD_METHOD:-auto}"           # auto | systemd | openrc | service | sighup
OPEN_FIREWALL="${OPEN_FIREWALL:-no}"
PRUNE_KEYS="${PRUNE_KEYS:-no}"
UNRESTRICT_KEYS="${UNRESTRICT_KEYS:-no}"         # добавлять обычную строку, если ключ есть только с from=/command=
FORCE="${FORCE:-no}"
YES="${YES:-no}"
QUIET="${QUIET:-no}"
RESET_STATE="${RESET_STATE:-no}"
ACTION=apply                                     # apply | check | rollback
ROLLBACK_FROM=""

D_PERMIT_ROOT_LOGIN=prohibit-password; D_ALLOW_TCP_FORWARDING=yes; D_X11_FORWARDING=no; D_LOG_LEVEL=VERBOSE
D_MAX_AUTH_TRIES=6; D_LOGIN_GRACE_TIME=30; D_CLIENT_ALIVE_INTERVAL=300; D_CLIENT_ALIVE_COUNT_MAX=2

usage() {
    cat <<USAGE
secure_ssh.sh v$VERSION — безопасная настройка sshd + ключи с GitHub.

Запуск:  sudo ./secure_ssh.sh [флаги]
         curl -fsSL <url>/secure_ssh.sh | sudo sh -s -- [флаги]
         curl -fsSL <url>/secure_ssh.sh | sudo env TARGET_USERS=root,deploy sh

Режимы:
      (по умолчанию)        установить ключи и применить настройки
  -n, --dry-run             показать и проверить (sshd -t) будущую конфигурацию, ничего не менять
      --check               только отчёт: эффективные настройки, порты, ключи пользователей
      --rollback [ФАЙЛ]     вернуть sshd_config из .orig (или ФАЙЛА), убрать drop-in, перезагрузить

Ключи:
  -u, --github-user USER    пользователь GitHub, чьи ключи ставим (GITHUB_USER=$GITHUB_USER)
      --keys-url URL        брать ключи с другого URL (KEYS_URL)
      --keys-file ФАЙЛ      брать ключи из локального файла (KEYS_FILE)
      --users U1,U2         кому класть ключи (TARGET_USERS; по умолчанию root + SUDO_USER/DOAS_USER)
      --prune               удалить ключи с меткой github:USER, которых больше нет в списке (PRUNE_KEYS)
      --unrestrict          если ключ уже есть с ограничениями (from=/command=), добавить строку без них (UNRESTRICT_KEYS)

Настройки sshd (значения запоминаются в STATE_FILE и действуют при следующих запусках):
  -p, --port N              порт sshd (SSH_PORT; по умолчанию порт НЕ меняется)
      --close-old-port      при смене порта НЕ оставлять старый порт открытым (KEEP_OLD_PORT=no)
      --open-firewall       открыть новый порт в ufw/firewalld автоматически (OPEN_FIREWALL)
      --permit-root-login V yes|no|prohibit-password (по умолчанию $D_PERMIT_ROOT_LOGIN)
      --tcp-forwarding V    yes|no, туннели и VS Code Remote (по умолчанию $D_ALLOW_TCP_FORWARDING)
      --x11 V               yes|no (по умолчанию $D_X11_FORWARDING)
      --max-auth-tries N    (по умолчанию $D_MAX_AUTH_TRIES)
      --log-level V         LogLevel (по умолчанию $D_LOG_LEVEL: в журнале виден отпечаток ключа; keep = не трогать)
      --strict-auth         AuthenticationMethods publickey: только ключ, другие методы невозможны (STRICT_AUTH)
      --allow-group G1,G2   AllowGroups: входить могут только участники этих групп (ALLOW_GROUPS);
                            целевые пользователи должны состоять в одной из них, иначе отказ
      --idle-timeout N      закрывать сессии без активности через N секунд (OpenSSH >= 9.2) (IDLE_TIMEOUT)
      --agent-forwarding V  yes|no, проброс ssh-agent (ALLOW_AGENT_FORWARDING; по умолчанию не трогается)
      --keep-accept-env     не комментировать AcceptEnv (DISABLE_ACCEPT_ENV=no)
      --accept-env "V1 V2"  принимать перечисленные переменные окружения (ACCEPT_ENV);
                            на Proxmox VE LC_PVE_TICKET добавляется к списку всегда (иначе не работает консоль VM
                            с другой ноды); отключить это можно только флагом --no-pve-ticket
      --no-banner           не ставить баннер (BANNER=no)
      --banner-admin TEXT   подпись в баннере (BANNER_ADMIN=$BANNER_ADMIN)
      --mode auto|dropin|legacy  куда писать настройки (CONFIG_MODE=$CONFIG_MODE)
      --reset               не брать значения прошлого запуска, только флаги и значения по умолчанию

Безопасность применения:
      --confirm N           после применения ждать N секунд подтверждения из НОВОЙ сессии
                            (touch $CONFIRM_FILE или Enter в этом окне), иначе откатить всё
      --no-reload           не перезагружать sshd после изменений
      --reload-method M     auto|systemd|openrc|service|sighup — как перезагружать sshd (RELOAD_METHOD)
      --force               отключить защиту от потери доступа (см. README)
  -y, --yes                 не задавать вопросов (смена порта)
  -q, --quiet               печатать только изменения, предупреждения и итог
  -h, --help                эта справка
  -V, --version             версия

Переменные окружения без флагов: SSHD_CONFIG, DROPIN_NAME, SSHD_BIN, STATE_FILE, CONFIRM_FILE,
LOGIN_GRACE_TIME, CLIENT_ALIVE_INTERVAL, CLIENT_ALIVE_COUNT_MAX, BANNER_FILE, NO_COLOR.

Коды выхода: 0 — успех; 1 — ошибка, изменения откачены; 2 — настройки записаны, но часть
значений перекрыта другой директивой (см. предупреждения); 3 — откат по таймеру --confirm.
USAGE
}

# ---------- Вывод ----------
C_INFO=""; C_OK=""; C_WARN=""; C_ERR=""; C_CHG=""; C_OFF=""
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != dumb ]; then
    C_INFO="$(printf '\033[36m')"; C_OK="$(printf '\033[32m')"; C_WARN="$(printf '\033[33m')"
    C_ERR="$(printf '\033[31m')"; C_CHG="$(printf '\033[35m')"; C_OFF="$(printf '\033[0m')"
fi
say()    { printf '%s\n' "$*" 2>/dev/null || :; }   # терминал может быть уже мёртв (EIO/EPIPE)
info()   { [ "$QUIET" = yes ] || say "${C_INFO}[INFO]${C_OFF} $*"; }
ok()     { [ "$QUIET" = yes ] || say "${C_OK}[OK]${C_OFF} $*"; }
note()   { say "${C_INFO}[INFO]${C_OFF} $*"; }           # печатается и в --quiet
warn()   { say "${C_WARN}[WARN]${C_OFF} $*" >&2; }
die()    { say "${C_ERR}[ERROR]${C_OFF} $*" >&2; exit 1; }
change() {
    if [ "$DRY_RUN" = yes ]; then say "${C_CHG}[DRY-RUN][$1]${C_OFF} $2"; else say "${C_CHG}[$1]${C_OFF} $2"; fi
}
lower()  { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# ---------- Разбор аргументов ----------
need_arg() { [ "$#" -ge 2 ] || die "флаг $1 требует значение"; }
parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --*=*) opt=${1%%=*}; val=${1#*=}; shift; set -- "$opt" "$val" "$@" ;;
        esac
        case "$1" in
            -u|--github-user)    need_arg "$@"; GITHUB_USER="$2"; shift 2 ;;
            --keys-url)          need_arg "$@"; KEYS_URL="$2"; shift 2 ;;
            --keys-file)         need_arg "$@"; KEYS_FILE="$2"; shift 2 ;;
            --users)             need_arg "$@"; TARGET_USERS="$2"; shift 2 ;;
            --prune)             PRUNE_KEYS=yes; shift ;;
            --unrestrict)        UNRESTRICT_KEYS=yes; shift ;;
            -p|--port)           need_arg "$@"; SSH_PORT="$2"; shift 2 ;;
            --close-old-port)    KEEP_OLD_PORT=no; shift ;;
            --open-firewall)     OPEN_FIREWALL=yes; shift ;;
            --permit-root-login) need_arg "$@"; PERMIT_ROOT_LOGIN="$2"; shift 2 ;;
            --tcp-forwarding)    need_arg "$@"; ALLOW_TCP_FORWARDING="$2"; shift 2 ;;
            --x11)               need_arg "$@"; X11_FORWARDING="$2"; shift 2 ;;
            --max-auth-tries)    need_arg "$@"; MAX_AUTH_TRIES="$2"; shift 2 ;;
            --log-level)         need_arg "$@"; LOG_LEVEL="$2"; shift 2 ;;
            --strict-auth)       STRICT_AUTH=yes; shift ;;
            --allow-group|--allow-groups) need_arg "$@"; ALLOW_GROUPS="$2"; shift 2 ;;
            --idle-timeout)      need_arg "$@"; IDLE_TIMEOUT="$2"; shift 2 ;;
            --agent-forwarding)  need_arg "$@"; ALLOW_AGENT_FORWARDING="$2"; shift 2 ;;
            --no-pve-ticket)     NO_PVE_TICKET=yes; shift ;;
            --keep-accept-env)   DISABLE_ACCEPT_ENV=no; shift ;;
            --accept-env)        need_arg "$@"; ACCEPT_ENV="$2"; shift 2 ;;
            --no-banner)         BANNER=no; shift ;;
            --banner-admin)      need_arg "$@"; BANNER_ADMIN="$2"; shift 2 ;;
            --mode)              need_arg "$@"; CONFIG_MODE="$2"; shift 2 ;;
            --reset)             RESET_STATE=yes; shift ;;
            --confirm)           need_arg "$@"; CONFIRM_TIMEOUT="$2"; shift 2 ;;
            -n|--dry-run)        DRY_RUN=yes; shift ;;
            --check)             ACTION=check; shift ;;
            --rollback)          ACTION=rollback; shift
                                 if [ "$#" -gt 0 ]; then case "$1" in -*) ;; *) ROLLBACK_FROM="$1"; shift ;; esac; fi ;;
            --no-reload)         NO_RELOAD=yes; shift ;;
            --reload-method)     need_arg "$@"; RELOAD_METHOD="$2"; shift 2 ;;
            --force)             FORCE=yes; shift ;;
            -y|--yes)            YES=yes; shift ;;
            -q|--quiet)          QUIET=yes; shift ;;
            -h|--help)           usage; exit 0 ;;
            -V|--version)        say "$VERSION"; exit 0 ;;
            *)                   die "неизвестный аргумент: $1 (см. --help)" ;;
        esac
    done
}

# yes/no в любом регистре, а также on/off, true/false, 1/0
norm_yn() {
    case "$(lower "$1")" in
        yes|y|on|true|1) printf 'yes' ;;
        no|n|off|false|0) printf 'no' ;;
        *) printf '%s' "$1" ;;
    esac
}
is_yes_no() { case "$1" in yes|no) return 0 ;; *) return 1 ;; esac; }
is_uint()   { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
is_port()   { is_uint "$1" && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }

# ---------- Состояние прошлого запуска ----------
# Файл KEY=VALUE с параметрами, которые скрипт применил в прошлый раз. Параметры, не заданные
# явно в этом запуске, берутся оттуда: повторный запуск «просто доложить ключи» не возвращает
# порт и прочие настройки к значениям по умолчанию.
ST_PORTS=""; ST_PERMIT_ROOT_LOGIN=""; ST_ALLOW_TCP_FORWARDING=""; ST_X11_FORWARDING=""
ST_MAX_AUTH_TRIES=""; ST_LOGIN_GRACE_TIME=""; ST_CLIENT_ALIVE_INTERVAL=""; ST_CLIENT_ALIVE_COUNT_MAX=""
ST_LOG_LEVEL=""; ST_MODE=""; ST_RELOAD_PENDING=""; ST_ACCEPT_ENV=""
ST_STRICT_AUTH=""; ST_ALLOW_GROUPS=""; ST_IDLE_TIMEOUT=""; ST_ALLOW_AGENT_FORWARDING=""
load_state() {
    [ -f "$STATE_FILE" ] || return 0
    while IFS='=' read -r k v || [ -n "$k" ]; do
        v=$(printf '%s' "$v" | tr -d '\r')
        case "$k" in
            PORTS)                  for p in $v; do is_port "$p" || { warn "в $STATE_FILE некорректный PORTS='$v', игнорирую"; v=""; break; }; done
                                    ST_PORTS="$v" ;;
            PERMIT_ROOT_LOGIN)      ST_PERMIT_ROOT_LOGIN="$v" ;;
            ALLOW_TCP_FORWARDING)   ST_ALLOW_TCP_FORWARDING="$v" ;;
            X11_FORWARDING)         ST_X11_FORWARDING="$v" ;;
            MAX_AUTH_TRIES)         ST_MAX_AUTH_TRIES="$v" ;;
            LOGIN_GRACE_TIME)       ST_LOGIN_GRACE_TIME="$v" ;;
            CLIENT_ALIVE_INTERVAL)  ST_CLIENT_ALIVE_INTERVAL="$v" ;;
            CLIENT_ALIVE_COUNT_MAX) ST_CLIENT_ALIVE_COUNT_MAX="$v" ;;
            LOG_LEVEL)              ST_LOG_LEVEL="$v" ;;
            ACCEPT_ENV)             ST_ACCEPT_ENV="$v" ;;
            STRICT_AUTH)            ST_STRICT_AUTH="$v" ;;
            ALLOW_GROUPS)           ST_ALLOW_GROUPS="$v" ;;
            IDLE_TIMEOUT)           ST_IDLE_TIMEOUT="$v" ;;
            ALLOW_AGENT_FORWARDING) ST_ALLOW_AGENT_FORWARDING="$v" ;;
            MODE)                   ST_MODE="$v" ;;
            RELOAD_PENDING)         ST_RELOAD_PENDING="$v" ;;
        esac
    done < "$STATE_FILE"
}
# Применить значение из состояния / по умолчанию к незаданному параметру и сообщить об этом
STICKY_NOTE=""
pick() {  # pick ИМЯ_ПЕРЕМЕННОЙ ЗНАЧЕНИЕ_ИЗ_СОСТОЯНИЯ ЗНАЧЕНИЕ_ПО_УМОЛЧАНИЮ
    eval "cur=\${$1}"
    if [ -n "$cur" ]; then return 0; fi
    if [ -n "$2" ]; then eval "$1=\"\$2\""; STICKY_NOTE="$STICKY_NOTE $1=$2"; else eval "$1=\"\$3\""; fi
}

validate_params() {
    ALLOW_TCP_FORWARDING=$(norm_yn "$ALLOW_TCP_FORWARDING"); X11_FORWARDING=$(norm_yn "$X11_FORWARDING")
    DISABLE_ACCEPT_ENV=$(norm_yn "$DISABLE_ACCEPT_ENV"); BANNER=$(norm_yn "$BANNER")
    KEEP_OLD_PORT=$(norm_yn "$KEEP_OLD_PORT"); OPEN_FIREWALL=$(norm_yn "$OPEN_FIREWALL")
    PRUNE_KEYS=$(norm_yn "$PRUNE_KEYS"); FORCE=$(norm_yn "$FORCE"); YES=$(norm_yn "$YES")
    QUIET=$(norm_yn "$QUIET"); DRY_RUN=$(norm_yn "$DRY_RUN"); NO_RELOAD=$(norm_yn "$NO_RELOAD")
    RESET_STATE=$(norm_yn "$RESET_STATE")
    PERMIT_ROOT_LOGIN=$(lower "$PERMIT_ROOT_LOGIN"); CONFIG_MODE=$(lower "$CONFIG_MODE")
    is_yes_no "$ALLOW_TCP_FORWARDING" || die "--tcp-forwarding: ожидается yes|no"
    is_yes_no "$X11_FORWARDING"       || die "--x11: ожидается yes|no"
    is_yes_no "$DISABLE_ACCEPT_ENV"   || die "DISABLE_ACCEPT_ENV: ожидается yes|no"
    is_yes_no "$BANNER"               || die "BANNER: ожидается yes|no"
    is_yes_no "$KEEP_OLD_PORT"        || die "KEEP_OLD_PORT: ожидается yes|no"
    UNRESTRICT_KEYS=$(norm_yn "$UNRESTRICT_KEYS")
    for v in OPEN_FIREWALL PRUNE_KEYS UNRESTRICT_KEYS FORCE YES QUIET DRY_RUN NO_RELOAD RESET_STATE; do
        eval "x=\${$v}"; is_yes_no "$x" || die "$v: ожидается yes|no"
    done
    is_uint "$MAX_AUTH_TRIES"         || die "--max-auth-tries: ожидается число"
    is_uint "$LOGIN_GRACE_TIME"       || die "LOGIN_GRACE_TIME: ожидается число"
    is_uint "$CLIENT_ALIVE_INTERVAL"  || die "CLIENT_ALIVE_INTERVAL: ожидается число"
    is_uint "$CLIENT_ALIVE_COUNT_MAX" || die "CLIENT_ALIVE_COUNT_MAX: ожидается число"
    is_uint "$CONFIRM_TIMEOUT"        || die "--confirm: ожидается число секунд"
    case "$PERMIT_ROOT_LOGIN" in
        yes|no|prohibit-password|without-password|forced-commands-only) ;;
        *) die "--permit-root-login: ожидается yes|no|prohibit-password" ;;
    esac
    case "$CONFIG_MODE" in auto|dropin|legacy) ;; *) die "--mode: ожидается auto|dropin|legacy" ;; esac
    RELOAD_METHOD=$(lower "$RELOAD_METHOD")
    case "$RELOAD_METHOD" in auto|systemd|openrc|service|sighup) ;; *) die "--reload-method: ожидается auto|systemd|openrc|service|sighup" ;; esac
    if [ -n "$SSH_PORT" ]; then is_port "$SSH_PORT" || die "--port: ожидается число 1..65535"; fi
    if [ "$KEEP_OLD_PORT" = no ] && [ -z "$SSH_PORT" ]; then die "--close-old-port имеет смысл только вместе с --port"; fi
    LOG_LEVEL=$(printf '%s' "$LOG_LEVEL" | tr '[:lower:]' '[:upper:]')
    case "$LOG_LEVEL" in
        KEEP|NONE) LOG_LEVEL="" ;;
        ''|QUIET|FATAL|ERROR|INFO|VERBOSE|DEBUG|DEBUG1|DEBUG2|DEBUG3) ;;
        *) die "--log-level: ожидается QUIET|FATAL|ERROR|INFO|VERBOSE|DEBUG|keep" ;;
    esac
    STRICT_AUTH=$(norm_yn "$STRICT_AUTH"); is_yes_no "$STRICT_AUTH" || die "STRICT_AUTH: ожидается yes|no"
    NO_PVE_TICKET=$(norm_yn "$NO_PVE_TICKET"); is_yes_no "$NO_PVE_TICKET" || die "NO_PVE_TICKET: ожидается yes|no"
    if [ -n "$ALLOW_AGENT_FORWARDING" ]; then
        ALLOW_AGENT_FORWARDING=$(norm_yn "$ALLOW_AGENT_FORWARDING"); is_yes_no "$ALLOW_AGENT_FORWARDING" || die "--agent-forwarding: ожидается yes|no"
    fi
    if [ -n "$IDLE_TIMEOUT" ]; then is_uint "$IDLE_TIMEOUT" || die "--idle-timeout: ожидается число секунд (0 = выключить)"; fi
    ALLOW_GROUPS=$(printf '%s' "$ALLOW_GROUPS" | tr ',' ' ')
    for g in $ALLOW_GROUPS; do
        case "$g" in *[!A-Za-z0-9_.@*?-]*) die "--allow-group: недопустимое имя группы '$g'" ;; esac
    done
    case "$GITHUB_USER" in
        ''|*[!A-Za-z0-9-]*) die "GITHUB_USER содержит недопустимые символы: '$GITHUB_USER'" ;;
    esac
    ACCEPT_ENV=$(printf '%s' "$ACCEPT_ENV" | tr ',' ' ')
    for v in $ACCEPT_ENV; do
        case "$v" in *[!A-Za-z0-9_*?]*|[0-9]*) die "--accept-env: недопустимое имя переменной '$v'" ;; esac
    done
    case "$DROPIN_NAME" in
        */*|'') die "DROPIN_NAME должен быть именем файла" ;;
        *.conf) ;;
        *) warn "DROPIN_NAME '$DROPIN_NAME' не оканчивается на .conf: Include */*.conf его не подхватит" ;;
    esac
    if [ -n "$KEYS_FILE" ] && [ ! -r "$KEYS_FILE" ]; then die "файл ключей $KEYS_FILE не читается"; fi
}

# ---------- Общие помощники ----------
have() { command -v "$1" >/dev/null 2>&1; }
file_uid()  { stat -c %u "$1" 2>/dev/null || ls -ldn "$1" | awk '{print $3}'; }
file_mode() { stat -c %a "$1" 2>/dev/null || true; }
user_uid()  { id -u "$1" 2>/dev/null; }
user_home() {
    if have getent; then getent passwd "$1" | cut -d: -f6
    else U="$1" awk -F: '$1 == ENVIRON["U"] { print $6 }' /etc/passwd; fi
}
# Одинаково ли содержимое двух файлов (cmp есть не везде: минимальные образы RHEL без diffutils)
same_file() {
    [ -f "$1" ] && [ -f "$2" ] || return 1
    if have cmp; then cmp -s "$1" "$2"; return $?; fi
    [ "$(cksum < "$1")" = "$(cksum < "$2")" ]
}
# Строки файла без \r (sshd_config, отредактированный в Windows)
cfg_lines() { tr -d '\r' < "$1"; }

# Проверка: слушает ли кто-нибудь TCP-порт $1 (ss, иначе /proc/net/tcp*)
port_listening() {
    if have ss && out=$(ss -Hltn 2>/dev/null) && [ -n "$out" ]; then
        printf '%s\n' "$out" | awk -v p=":$1" '{ n = split($4, a, ":"); if (":" a[n] == p) found = 1 } END { exit !found }'
        return $?
    fi
    hex=$(printf '%04X' "$1")
    for f in /proc/net/tcp /proc/net/tcp6; do
        [ -r "$f" ] || continue
        if awk -v h=":$hex" 'NR > 1 && $4 == "0A" { n = split($2, a, ":"); if (":" a[n] == h) found = 1 } END { exit !found }' "$f"; then
            return 0
        fi
    done
    return 1
}
# Ждать до $2 секунд, пока все порты из $1 не начнут слушаться
wait_listening() {
    i=0
    while [ "$i" -lt "$2" ]; do
        all=1
        for p in $1; do port_listening "$p" || all=0; done
        [ "$all" = 1 ] && return 0
        sleep 1; i=$((i + 1))
    done
    for p in $1; do port_listening "$p" || return 1; done
    return 0
}

# Эффективные значения sshd для файла конфигурации $1 (и, опционально, пользователя $2)
sshd_T() {
    if [ -n "${2:-}" ]; then
        "$SSHD_BIN" -T -f "$1" -C "user=$2,host=localhost,addr=127.0.0.1" 2>/dev/null
    else
        "$SSHD_BIN" -T -f "$1" 2>/dev/null
    fi
}
# Все значения ключа $2 (в нижнем регистре) из вывода sshd -T, сохранённого в файле $1
eff_values() { K="$2" awk '$1 == ENVIRON["K"] { sub(/^[^ ]+ /, ""); print }' "$1"; }
eff_value()  { eff_values "$1" "$2" | head -n 1; }

# ---------- Предварительные проверки и окружение ----------
TMPDIR_=""; LOCK_DIR=""
APPLY_STARTED=0; APPLY_OK=0; ROLLED_BACK=0; CONFIRM_PENDING=0; RPID=""; WD_PID=""; NO_ORIG=0
RUN_BACKUP=""; DROPIN_SAVED=""; DROPIN_PATH=""; BANNER_SAVED=""; STATE_SAVED=""; NEED_RELOAD=0
SERVICE_WAS_UP=0; RELOAD_DONE=""; RELOAD_UNIT=""; RELOAD_FAILED=0

restore_file() {  # restore_file БЭКАП ЦЕЛЬ -> восстановить атомарно; пустой бэкап не используем
    if [ ! -s "$1" ]; then warn "бэкап $1 пуст или отсутствует, $2 не восстанавливаю"; return 1; fi
    cp -p "$1" "$2.secure_ssh.tmp" 2>/dev/null && mv -f "$2.secure_ssh.tmp" "$2"
}
rollback() {
    [ "$ROLLED_BACK" = 1 ] && return 0
    ROLLED_BACK=1
    warn "Откатываю изменения..."
    if [ -n "$RUN_BACKUP" ]; then
        restore_file "$RUN_BACKUP" "$SSHD_CONFIG" && warn "$SSHD_CONFIG восстановлен из $RUN_BACKUP"
    fi
    case "$DROPIN_SAVED" in
        existing) restore_file "$TMPDIR_/dropin.prev" "$DROPIN_PATH" && warn "$DROPIN_PATH восстановлен" ;;
        absent)   rm -f "$DROPIN_PATH" && warn "$DROPIN_PATH удалён" ;;
    esac
    case "$BANNER_SAVED" in
        existing) restore_file "$TMPDIR_/banner.prev" "$BANNER_FILE" && warn "$BANNER_FILE восстановлен" ;;
        absent)   rm -f "$BANNER_FILE" ;;
    esac
    case "$STATE_SAVED" in
        existing) restore_file "$TMPDIR_/state.prev" "$STATE_FILE" || true ;;
        absent)   rm -f "$STATE_FILE" ;;
    esac
    if [ "$ROLLED_BACK" = 1 ] && [ "$RELOAD_DONE" = 1 ]; then
        warn "sshd уже был перезагружен с новой конфигурацией, перезапускаю со старой..."
        reload_sshd restart || warn "не удалось перезапустить sshd после отката, проверьте вручную: $SSHD_BIN -t && <перезапуск службы>"
    fi
}
# shellcheck disable=SC2317  # вызывается из trap
cleanup() {
    rc=$?
    set +e
    if [ -n "$RPID" ]; then kill "$RPID" 2>/dev/null; fi
    if [ "$CONFIRM_PENDING" = 1 ]; then
        # Сигнал (обрыв сессии, Ctrl-C) во время ожидания подтверждения: считаем, что подтверждения нет
        warn "ожидание подтверждения прервано (сигнал), откатываю"
        APPLY_OK=1; rollback
        : > "$CONFIRM_FILE.done" 2>/dev/null
        rc=3
    elif [ "$rc" -ne 0 ] && [ "$APPLY_STARTED" = 1 ] && [ "$APPLY_OK" = 0 ]; then
        rollback
    fi
    if [ -n "$WD_PID" ]; then kill "$WD_PID" 2>/dev/null; fi
    [ -n "$LOCK_DIR" ] && rm -rf "$LOCK_DIR"
    [ -n "$TMPDIR_" ] && rm -rf "$TMPDIR_"
    [ "$rc" = 3 ] && exit 3
    return 0
}

preflight() {
    [ "$(id -u)" -eq 0 ] || die "скрипт нужно запускать от root (sudo)"
    [ -f "$SSHD_CONFIG" ] || die "файл $SSHD_CONFIG не найден"
    CFG_DIR=$(dirname "$SSHD_CONFIG")
    [ -n "$STATE_FILE" ] || STATE_FILE="$CFG_DIR/.secure_ssh.state"

    TMPDIR_=$(mktemp -d 2>/dev/null || mktemp -d -t secure_ssh.XXXXXX) || die "не удалось создать временный каталог"
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    trap 'exit 141' PIPE

    # Защита от параллельного запуска
    LOCK_DIR="$CFG_DIR/.secure_ssh.lock"
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        oldpid=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
        if [ -n "$oldpid" ] && kill -0 "$oldpid" 2>/dev/null; then
            LOCK_DIR=""; die "уже выполняется другой экземпляр (pid $oldpid)"
        fi
        rm -rf "$LOCK_DIR"; mkdir "$LOCK_DIR" || { LOCK_DIR=""; die "не удалось создать блокировку $LOCK_DIR"; }
    fi
    printf '%s\n' "$$" > "$LOCK_DIR/pid"

    # Бинарник sshd: предпочитаем тот, что реально запущен
    if [ -z "$SSHD_BIN" ]; then
        for pf in /run/sshd.pid /var/run/sshd.pid; do
            [ -f "$pf" ] || continue
            pid=$(tr -d ' \n' < "$pf" 2>/dev/null || true)
            if is_uint "$pid" && [ -r "/proc/$pid/exe" ]; then
                exe=$(readlink "/proc/$pid/exe" 2>/dev/null || true)
                case "$exe" in */sshd|*/sshd\ \(deleted\)) SSHD_BIN="${exe% (deleted)}"; break ;; esac
            fi
        done
    fi
    [ -n "$SSHD_BIN" ] && [ -x "$SSHD_BIN" ] || SSHD_BIN=$(command -v sshd 2>/dev/null || true)
    if [ -z "$SSHD_BIN" ]; then
        for p in /usr/sbin/sshd /usr/local/sbin/sshd /sbin/sshd; do
            if [ -x "$p" ]; then SSHD_BIN="$p"; break; fi
        done
    fi
    if [ -z "$SSHD_BIN" ] || [ ! -x "$SSHD_BIN" ]; then die "sshd не найден: установите openssh-server"; fi

    # Версия OpenSSH: любая версия печатает "OpenSSH_X.Y" в ответ на -V
    SSHD_VER=$("$SSHD_BIN" -V 2>&1 | grep -oE 'OpenSSH_[0-9]+\.[0-9]+' | head -n 1 | sed 's/OpenSSH_//' || true)
    SSHD_MAJOR=${SSHD_VER%%.*}; SSHD_MINOR=${SSHD_VER#*.}
    if ! is_uint "$SSHD_MAJOR" || ! is_uint "$SSHD_MINOR"; then
        warn "не удалось определить версию OpenSSH по '$SSHD_BIN -V'"
        SSHD_MAJOR=0; SSHD_MINOR=0
    fi
    info "secure_ssh.sh v$VERSION; sshd: $SSHD_BIN (OpenSSH $SSHD_MAJOR.$SSHD_MINOR), конфиг: $SSHD_CONFIG"
}
ver_ge() { [ "$SSHD_MAJOR" -gt "$1" ] || { [ "$SSHD_MAJOR" -eq "$1" ] && [ "$SSHD_MINOR" -ge "$2" ]; }; }

# Исходная конфигурация должна проходить sshd -t ДО любых изменений; типичные проблемы окружения чиним
precheck_config() {
    attempt=0
    while :; do
        if out=$("$SSHD_BIN" -t -f "$SSHD_CONFIG" 2>&1); then
            [ "$attempt" -gt 0 ] && ok "sshd -t: исходная конфигурация корректна (после починки окружения)"
            return 0
        fi
        attempt=$((attempt + 1))
        [ "$attempt" -le 3 ] || break
        case "$out" in
            *"Missing privilege separation directory"*)
                d=$(printf '%s\n' "$out" | sed -n 's/.*Missing privilege separation directory: *//p' | head -n 1)
                if [ -n "$d" ] && [ "$ACTION" != check ]; then
                    mkdir -p "$d" && chmod 755 "$d" && info "создан каталог $d (нужен sshd для privilege separation)"; continue
                fi ;;
            *"no hostkeys available"*|*"Could not load host key"*)
                if have ssh-keygen && [ "$ACTION" != check ] && [ "$DRY_RUN" != yes ]; then
                    info "host-ключи отсутствуют, генерирую: ssh-keygen -A"
                    ssh-keygen -A >/dev/null 2>&1 && continue
                fi ;;
        esac
        break
    done
    say "$out" >&2
    die "исходная конфигурация $SSHD_CONFIG уже не проходит sshd -t. Исправьте её вручную, я ничего не менял."
}

# ---------- Режим записи настроек и Include ----------
detect_mode() {
    if [ "$PERMIT_ROOT_LOGIN" = prohibit-password ] && ! ver_ge 7 0; then
        PERMIT_ROOT_LOGIN=without-password   # до OpenSSH 7.0 значение называлось иначе
    fi
    INCLUDE_LINENO=$(cfg_lines "$SSHD_CONFIG" | grep -niE '^[[:space:]]*Include[[:space:]=]+' | head -n 1 | cut -d: -f1 || true)
    INCLUDE_PATTERN=""
    if [ -n "$INCLUDE_LINENO" ]; then
        INCLUDE_PATTERN=$(cfg_lines "$SSHD_CONFIG" | sed -n "${INCLUDE_LINENO}p" | sed 's/^[[:space:]]*[Ii][Nn][Cc][Ll][Uu][Dd][Ee][[:space:]=]*//' | awk '{print $1}' | tr -d '"')
        case "$INCLUDE_PATTERN" in /*) ;; *) INCLUDE_PATTERN="/etc/ssh/$INCLUDE_PATTERN" ;; esac
    fi
    FIRST_ACTIVE_LINENO=$(cfg_lines "$SSHD_CONFIG" | grep -nvE '^[[:space:]]*(#|$)' | head -n 1 | cut -d: -f1 || true)
    # Include внутри Match-блока не глобальный
    if [ -n "$INCLUDE_LINENO" ]; then
        first_match=$(cfg_lines "$SSHD_CONFIG" | grep -niE '^[[:space:]]*Match[[:space:]]' | head -n 1 | cut -d: -f1 || true)
        if [ -n "$first_match" ] && [ "$first_match" -lt "$INCLUDE_LINENO" ]; then
            warn "Include в $SSHD_CONFIG стоит внутри блока Match (строка $INCLUDE_LINENO) и не является глобальным"
            INCLUDE_LINENO=""; INCLUDE_PATTERN=""
        fi
    fi

    SUPPORTS_INCLUDE=0
    if ver_ge 8 2; then SUPPORTS_INCLUDE=1
    elif [ "$SSHD_MAJOR" = 0 ] && [ -n "$INCLUDE_PATTERN" ]; then
        SUPPORTS_INCLUDE=1   # версия не определилась, но конфиг уже использует Include и прошёл sshd -t
    fi
    if [ "$CONFIG_MODE" = auto ]; then
        if [ "$SUPPORTS_INCLUDE" = 1 ]; then CONFIG_MODE=dropin; else CONFIG_MODE=legacy; fi
    fi
    if [ "$CONFIG_MODE" = dropin ] && [ "$SUPPORTS_INCLUDE" = 0 ]; then
        warn "OpenSSH $SSHD_MAJOR.$SSHD_MINOR не поддерживает Include, переключаюсь на режим legacy"
        CONFIG_MODE=legacy
    fi
    DROPIN_DIR="$CFG_DIR/sshd_config.d"
    if [ "$CONFIG_MODE" = dropin ] && [ -n "$INCLUDE_PATTERN" ]; then
        case "$INCLUDE_PATTERN" in
            */\*.conf) DROPIN_DIR=$(dirname "$INCLUDE_PATTERN") ;;
            *) warn "необычный Include '$INCLUDE_PATTERN', переключаюсь на режим legacy"; CONFIG_MODE=legacy ;;
        esac
        if [ "$CONFIG_MODE" = dropin ] && [ "$INCLUDE_LINENO" != "$FIRST_ACTIVE_LINENO" ]; then
            warn "Include стоит не первой директивой в $SSHD_CONFIG: значения выше него перекроют drop-in (см. итоговую проверку)"
        fi
    fi
    if [ "$CONFIG_MODE" = legacy ] && [ -n "$INCLUDE_PATTERN" ]; then
        info "режим legacy при наличии Include: директивы будут вставлены ВЫШЕ строки Include, чтобы иметь приоритет"
    fi
    DROPIN_PATH="$DROPIN_DIR/$DROPIN_NAME"
    if [ -n "$ST_MODE" ] && [ "$ST_MODE" != "$CONFIG_MODE" ]; then
        warn "в прошлый раз использовался режим $ST_MODE, сейчас $CONFIG_MODE"
    fi
    info "режим записи настроек: $CONFIG_MODE"
    if [ -n "$IDLE_TIMEOUT" ] && [ "$IDLE_TIMEOUT" -gt 0 ] && ! ver_ge 9 2; then
        warn "--idle-timeout не поддерживается OpenSSH $SSHD_MAJOR.$SSHD_MINOR (нужен 9.2+: UnusedConnectionTimeout/ChannelTimeout), пропускаю"
    fi
    detect_pve
}
# Proxmox VE: консоль VM с другой ноды передаёт билет через переменную LC_PVE_TICKET по ssh,
# миграция VM идёт через ssh-туннель с пробросом портов, ключи root кластер хранит в /etc/pve/priv.
IS_PVE=0
detect_pve() {
    if [ -d /etc/pve ] || have pveversion; then IS_PVE=1; fi
    [ "$IS_PVE" = 1 ] || return 0
    if [ "$NO_PVE_TICKET" = yes ]; then
        warn "Proxmox VE: --no-pve-ticket — LC_PVE_TICKET не принимается, консоль VM с другой ноды работать не будет"
    else
        case " $ACCEPT_ENV " in
            *" LC_PVE_TICKET "*|*" LC_* "*) ;;
            *) ACCEPT_ENV="${ACCEPT_ENV:+$ACCEPT_ENV }LC_PVE_TICKET" ;;
        esac
        info "обнаружен Proxmox VE: sshd будет принимать LC_PVE_TICKET (консоль VM между нодами); AcceptEnv: $ACCEPT_ENV"
    fi
    [ "$ALLOW_TCP_FORWARDING" = yes ] || warn "Proxmox VE: AllowTcpForwarding no сломает миграцию VM по ssh-туннелю"
}

# ---------- Перезагрузка sshd ----------
# Каждая стратегия: 0 = успех, 1 = попытка не удалась, 2 = стратегия неприменима
systemd_usable() {
    [ -d /run/systemd/system ] && have systemctl || return 1
    st=$(systemctl is-system-running 2>/dev/null || true)
    case "$st" in running|degraded|starting|maintenance|stopping) return 0 ;; *) return 1 ;; esac
}
reload_systemd() {  # $1 = reload|restart
    systemd_usable || return 2
    unit=""
    for u in ssh sshd; do
        if systemctl cat "$u.service" >/dev/null 2>&1; then unit="$u.service"; break; fi
    done
    [ -n "$unit" ] || return 2
    RELOAD_UNIT="$unit"
    socket_active=0
    systemctl is-active --quiet ssh.socket 2>/dev/null && socket_active=1
    if [ "$socket_active" = 1 ] && [ "$PORTS_CHANGED" = 1 ]; then
        # Ubuntu 24.04: порт слушает systemd, а не sshd; сокет надо перегенерировать и перезапустить
        if systemctl daemon-reload && systemctl restart ssh.socket; then
            info "ssh.socket перезапущен (новые порты: $WANT_PORTS)"
        else
            warn "не удалось перезапустить ssh.socket"; return 1
        fi
    fi
    if systemctl is-active --quiet "$unit"; then
        if [ "$1" = restart ]; then
            systemctl restart "$unit" && { ok "$unit перезапущен"; return 0; }
        else
            { systemctl reload "$unit" 2>/dev/null || systemctl restart "$unit"; } && { ok "$unit перезагружен"; return 0; }
        fi
        warn "не удалось перезагрузить $unit"; return 1
    fi
    if [ "$socket_active" = 1 ]; then
        info "$unit не активен, активация через ssh.socket: новые подключения получат новую конфигурацию"
        return 0
    fi
    return 2   # sshd запущен не через systemd (или не запущен) — пробуем другие способы
}
reload_openrc() {
    have rc-service || return 2
    svc=sshd; if [ ! -e /etc/init.d/sshd ] && [ -e /etc/init.d/ssh ]; then svc=ssh; fi
    [ -e "/etc/init.d/$svc" ] || return 2
    if [ "$1" = restart ]; then
        rc-service "$svc" restart && { ok "OpenRC: $svc перезапущен"; return 0; }
    else
        { rc-service "$svc" reload 2>/dev/null || rc-service "$svc" restart; } && { ok "OpenRC: $svc перезагружен"; return 0; }
    fi
    warn "OpenRC: не удалось перезагрузить $svc"; return 1
}
reload_service() {
    have service || return 2
    for s in ssh sshd; do
        [ -e "/etc/init.d/$s" ] || continue
        if [ "$1" = restart ]; then
            service "$s" restart && { ok "service $s перезапущен"; return 0; }
        else
            { service "$s" reload 2>/dev/null || service "$s" restart; } && { ok "service $s перезагружен"; return 0; }
        fi
        warn "не удалось перезагрузить service $s"; return 1
    done
    return 2
}
sshd_pid() {  # pid работающего sshd по PidFile из конфигурации (или стандартным путям)
    pf=$(eff_value "$TMPDIR_/eff.orig" pidfile 2>/dev/null || true)
    for f in $pf /run/sshd.pid /var/run/sshd.pid; do
        [ -f "$f" ] || continue
        p=$(tr -d ' \n' < "$f" 2>/dev/null || true)
        is_uint "$p" || continue
        if [ -r "/proc/$p/comm" ]; then
            [ "$(cat "/proc/$p/comm" 2>/dev/null)" = sshd ] || continue
        fi
        kill -0 "$p" 2>/dev/null && { printf '%s' "$p"; return 0; }
    done
    return 1
}
reload_sighup() {
    p=$(sshd_pid) || p=""
    if [ "$1" = restart ]; then
        if [ -n "$p" ]; then kill -TERM "$p" 2>/dev/null || true; sleep 1; fi
        "$SSHD_BIN" -f "$SSHD_CONFIG" && { ok "sshd запущен напрямую: $SSHD_BIN -f $SSHD_CONFIG"; return 0; }
        warn "не удалось запустить $SSHD_BIN"; return 1
    fi
    [ -n "$p" ] || return 2
    kill -HUP "$p" 2>/dev/null && { ok "sshd (pid $p) получил SIGHUP"; return 0; }
    return 1
}
reload_sshd() {  # $1 = reload|restart
    mode="${1:-reload}"
    strats="reload_systemd reload_openrc reload_service reload_sighup"
    [ "$RELOAD_METHOD" = auto ] || strats="reload_$RELOAD_METHOD"
    tried=0
    for strat in $strats; do
        "$strat" "$mode"; rc=$?
        case "$rc" in
            0) RELOAD_DONE=1; return 0 ;;
            1) tried=1; RELOAD_DONE=1 ;;   # служба уже тронута (reload/restart пытались) — пробуем следующий способ
        esac
    done
    [ "$tried" = 1 ] || warn "не удалось определить способ перезапуска sshd (systemd/OpenRC/service/pid-файл)"
    return 1
}

# ---------- Ключи: получить и проверить ДО любых изменений ----------
fetch_url() {
    if have curl; then
        curl -fsSL --connect-timeout 10 --max-time 30 "$1"
    elif have wget; then
        wget -q -T 30 -O - "$1"
    else
        die "нужен curl или wget для загрузки ключей (или укажите --keys-file)"
    fi
}
is_valid_key() {
    printf '%s\n' "$1" | grep -qE '^(ssh-(ed25519|rsa|dss)|ecdsa-sha2-nistp(256|384|521)|sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh\.com)[[:space:]]+[A-Za-z0-9+/]+={0,3}([[:space:]].*)?$' || return 1
    if have ssh-keygen; then
        printf '%s\n' "$1" > "$TMPDIR_/one.pub"
        ssh-keygen -lf "$TMPDIR_/one.pub" >/dev/null 2>&1 || return 1
    fi
    return 0
}
key_fingerprint() {  # "SHA256:... (ED25519)" или пусто
    have ssh-keygen || return 0
    printf '%s\n' "$1" > "$TMPDIR_/one.pub"
    ssh-keygen -lf "$TMPDIR_/one.pub" 2>/dev/null | awk '{ printf "%s %s", $2, $NF }'
}

RAW_KEYS=""; VALID_KEYS=""; N_KEYS=0; KEYS_SOURCE=""
fetch_keys() {
    RAW_KEYS="$TMPDIR_/raw.keys"; VALID_KEYS="$TMPDIR_/valid.keys"
    if [ -n "$KEYS_FILE" ]; then
        KEYS_SOURCE="$KEYS_FILE"
        info "Читаю ключи из файла: $KEYS_FILE"
        cat "$KEYS_FILE" > "$RAW_KEYS"
    else
        [ -n "$KEYS_URL" ] || KEYS_URL="https://github.com/${GITHUB_USER}.keys"
        KEYS_SOURCE="$KEYS_URL"
        info "Загружаю ключи: $KEYS_URL"
        if ! fetch_url "$KEYS_URL" > "$RAW_KEYS"; then
            die "не удалось скачать $KEYS_URL (нет сети, нет такого пользователя или сервер недоступен). Ничего не меняю."
        fi
    fi
    : > "$VALID_KEYS"
    while IFS= read -r line || [ -n "$line" ]; do
        line=$(printf '%s' "$line" | tr -d '\r')
        case "$line" in ''|'#'*) continue ;; esac
        if is_valid_key "$line"; then
            printf '%s\n' "$line" >> "$VALID_KEYS"
        else
            warn "строка не похожа на ключ и отброшена: $(printf '%.60s' "$line")"
        fi
    done < "$RAW_KEYS"
    N_KEYS=$(wc -l < "$VALID_KEYS" | tr -d ' ')
    [ "$N_KEYS" -gt 0 ] || die "не получено ни одного валидного ключа из $KEYS_SOURCE. Ничего не меняю."
    ok "получено валидных ключей: $N_KEYS"
    while read -r ktype kblob _rest; do
        fp=$(key_fingerprint "$ktype $kblob")
        info "  ключ: ${fp:-$ktype} $(printf '%.12s' "$kblob")..."
    done < "$VALID_KEYS"
}

# ---------- Пользователи и защита от потери доступа ----------
resolve_users() {
    if [ -z "$TARGET_USERS" ]; then
        TARGET_USERS="root"
        caller="${SUDO_USER:-${DOAS_USER:-}}"
        if [ -n "$caller" ] && [ "$caller" != root ]; then TARGET_USERS="root,$caller"; fi
    fi
    TARGET_USERS=$(printf '%s' "$TARGET_USERS" | tr ',;' '  ')
    # shellcheck disable=SC2086
    set -- $TARGET_USERS
    [ "$#" -gt 0 ] || die "список пользователей пуст (--users). Не отключаю пароли, никому не поставив ключ."
    TARGET_USERS="$*"
    non_root=0
    for u in $TARGET_USERS; do
        h=$(user_home "$u")
        [ -n "$h" ] || die "пользователь '$u' не найден"
        [ -d "$h" ] || die "домашний каталог $h пользователя '$u' не существует"
        [ "$u" = root ] || non_root=1
    done
    case "$PERMIT_ROOT_LOGIN" in
        no|forced-commands-only)
            if [ "$non_root" = 0 ]; then
                msg="PermitRootLogin $PERMIT_ROOT_LOGIN, а ключи ставятся только root ($TARGET_USERS): после отключения паролей войти не сможет никто. Укажите --users <admin> или --permit-root-login prohibit-password"
                if [ "$FORCE" = yes ]; then warn "$msg (продолжаю из-за --force)"; else die "$msg (или --force, если понимаете последствия)"; fi
            fi
            case " $TARGET_USERS " in *" root "*) warn "ключ для root бесполезен при PermitRootLogin $PERMIT_ROOT_LOGIN" ;; esac ;;
    esac
}

# ---------- authorized_keys: путь, безопасная запись, дедупликация ----------
# Раскрыть токены sshd (%h, %u, %U, %%) в строке $1 для дома $2, пользователя $3, uid $4
expand_tokens() {
    str="$1"; out=""
    while :; do
        case "$str" in
            *%*)
                out="$out${str%%\%*}"; rest=${str#*%}
                case "$rest" in
                    h*) out="$out$2"; str=${rest#h} ;;
                    u*) out="$out$3"; str=${rest#u} ;;
                    U*) out="$out$4"; str=${rest#U} ;;
                    %*) out="$out%";  str=${rest#%} ;;
                    *)  return 1 ;;
                esac ;;
            *) out="$out$str"; break ;;
        esac
    done
    printf '%s' "$out"
}
# Первый файл из эффективного AuthorizedKeysFile для пользователя $1 с домом $2 и uid $3.
# Побочный эффект: $TMPDIR_/eff.user — вывод sshd -T -C для этого пользователя
akf_for_user() {
    f=""
    if sshd_T "$SSHD_CONFIG" "$1" > "$TMPDIR_/eff.user" 2>/dev/null || sshd_T "$SSHD_CONFIG" > "$TMPDIR_/eff.user" 2>/dev/null; then
        f=$(eff_value "$TMPDIR_/eff.user" authorizedkeysfile | awk '{print $1}')
    fi
    [ -n "$f" ] || f=".ssh/authorized_keys"
    [ "$f" = none ] && { printf 'none'; return 0; }
    f=$(expand_tokens "$f" "$2" "$1" "$3") || die "$1: AuthorizedKeysFile '$f' содержит неподдерживаемый токен"
    case "$f" in /*) ;; *) f="$2/$f" ;; esac
    printf '%s' "$f"
}
# Состояние ключа (тип $1, blob $2) в файле $3: active | restricted (с опциями from=/command=) | commented | absent
key_state() {
    [ -f "$3" ] || { printf 'absent'; return 0; }
    grep -qF -- "$2" "$3" || { printf 'absent'; return 0; }
    T="$1" B="$2" awk '
        /^[ \t]*(#|$)/ { if (index($0, ENVIRON["B"])) c = 1; next }
        { for (i = 1; i < NF; i++) if ($i == ENVIRON["T"] && $(i+1) == ENVIRON["B"]) { if (i == 1) a = 1; else r = 1 } }
        END { if (a) print "active"; else if (r) print "restricted"; else if (c) print "commented"; else print "absent" }' "$3"
}
# Принимает ли sshd ключ типа $1 (по pubkeyacceptedalgorithms / pubkeyacceptedkeytypes из $2)
key_type_accepted() {
    algs=$(eff_value "$2" pubkeyacceptedalgorithms); [ -n "$algs" ] || algs=$(eff_value "$2" pubkeyacceptedkeytypes)
    [ -n "$algs" ] || return 0   # старый sshd без такой директивы в -T: принимает всё, что знает
    case ",$algs," in
        *",$1,"*) return 0 ;;
    esac
    case "$1" in ssh-rsa) case ",$algs," in *",rsa-sha2-256,"*|*",rsa-sha2-512,"*) return 0 ;; esac ;; esac
    return 1
}
# Разрешён ли вход пользователю $1 по AllowUsers/AllowGroups/DenyUsers/DenyGroups из $2 (sshd -T -C user=...)
# shellcheck disable=SC2254  # шаблон намеренно раскрывается как glob (AllowUsers user*, *@host)
glob_match() { case "$1" in $2) return 0 ;; *) return 1 ;; esac; }
user_allowed() {
    u="$1"; e="$2"; groups_=$(id -Gn "$u" 2>/dev/null || true)
    for pat in $(eff_values "$e" denyusers); do glob_match "$u" "${pat%%@*}" && [ "${pat#*@}" = "$pat" ] && { ALLOW_REASON="DenyUsers $pat"; return 1; }; done
    for pat in $(eff_values "$e" denygroups); do for g in $groups_; do glob_match "$g" "$pat" && { ALLOW_REASON="DenyGroups $pat"; return 1; }; done; done
    allow=$(eff_values "$e" allowusers | tr '\n' ' ')
    if [ -n "$allow" ]; then
        okk=0; for pat in $allow; do glob_match "$u" "${pat%%@*}" && okk=1; done
        [ "$okk" = 1 ] || { ALLOW_REASON="нет в AllowUsers ($allow)"; return 1; }
    fi
    allow=$(eff_values "$e" allowgroups | tr '\n' ' ')
    if [ -n "$allow" ]; then
        okk=0; for pat in $allow; do for g in $groups_; do glob_match "$g" "$pat" && okk=1; done; done
        [ "$okk" = 1 ] || { ALLOW_REASON="группы ($groups_) нет в AllowGroups ($allow)"; return 1; }
    fi
    return 0
}
# Проверка, что путь $1 не симлинк и принадлежит uid $2 или root
assert_safe_path() {
    [ -L "$1" ] && die "$1 — символическая ссылка, отказываюсь писать через неё"
    [ -e "$1" ] || return 0
    own=$(file_uid "$1")
    if [ "$own" != "$2" ] && [ "$own" != 0 ]; then die "$1 принадлежит uid $own, а не пользователю (uid $2) и не root"; fi
}
LOGIN_MATRIX=""; LOGIN_OK_USERS=0; ALLOW_REASON=""
install_keys_for_user() {
    u="$1"; h=$(user_home "$u"); uid=$(user_uid "$u"); grp=$(id -gn "$u")
    ak=$(akf_for_user "$u" "$h" "$uid")
    if [ "$ak" = none ]; then
        msg="$u: AuthorizedKeysFile none — sshd не читает файлы ключей (только AuthorizedKeysCommand)"
        if [ "$FORCE" = yes ]; then warn "$msg"; return 0; else die "$msg. Отключать пароли опасно (--force, чтобы продолжить)"; fi
    fi
    can_login=1
    if ! user_allowed "$u" "$TMPDIR_/eff.user"; then
        warn "$u: sshd не пустит этого пользователя: $ALLOW_REASON. Ключ поставлю, но входа не будет"
        can_login=0
    fi
    if [ -n "$ALLOW_GROUPS" ] && [ "$can_login" = 1 ]; then
        okk=0; for g in $(id -Gn "$u" 2>/dev/null); do for pat in $ALLOW_GROUPS; do glob_match "$g" "$pat" && okk=1; done; done
        if [ "$okk" = 0 ]; then
            ALLOW_REASON="не состоит в группах из --allow-group ($ALLOW_GROUPS); добавить: usermod -aG ${ALLOW_GROUPS%% *} $u"
            warn "$u: после применения AllowGroups $ALLOW_GROUPS этот пользователь войти не сможет: $ALLOW_REASON"
            can_login=0
        fi
    fi
    if [ -L "$ak" ] && [ "$uid" = 0 ] && [ "$(file_uid "$ak")" = 0 ]; then
        target=$(readlink -f "$ak" 2>/dev/null || true)
        if [ -n "$target" ] && [ -d "$(dirname "$target")" ] && [ "$(file_uid "$(dirname "$target")")" = 0 ]; then
            pve_note=""; [ "$IS_PVE" = 1 ] && pve_note=" (Proxmox: ключи root синхронизирует кластер)"
            info "$u: $ak — ссылка root на $target$pve_note; пишу по целевому пути"
            ak="$target"
        fi
    fi
    akdir=$(dirname "$ak")
    case "$ak" in
        "$h"/*) in_home=1 ;;
        *) in_home=0; info "$u: AuthorizedKeysFile = $ak (вне домашнего каталога)" ;;
    esac
    # StrictModes: домашний каталог и каталог ключей не должны быть доступны на запись группе/остальным
    for d in "$h" "$akdir"; do
        [ -d "$d" ] || continue
        m=$(file_mode "$d")
        case "$m" in ?[2367]?|??[2367]) warn "$u: $d имеет права $m (запись для группы/остальных) — при StrictModes yes sshd не примет ключ. Исправьте: chmod go-w $d" ;; esac
    done
    added=0; present=0; restricted=0; unusable=0; add_list=""
    while read -r ktype kblob _rest; do
        if ! key_type_accepted "$ktype" "$TMPDIR_/eff.user"; then
            unusable=$((unusable + 1))
            warn "$u: ключ типа $ktype не входит в PubkeyAcceptedAlgorithms этого sshd — вход с ним невозможен"
        fi
        case "$(key_state "$ktype" "$kblob" "$ak")" in
            active) present=$((present + 1)); continue ;;
            restricted)
                if [ "$UNRESTRICT_KEYS" = yes ]; then
                    warn "$u: ключ $(printf '%.12s' "$kblob")... есть в $ak с ограничениями (from=/command=); по --unrestrict добавляю строку без ограничений"
                else
                    restricted=$((restricted + 1))
                    warn "$u: ключ $(printf '%.12s' "$kblob")... есть в $ak только с ограничениями (from=/command=/restrict) — оставляю как есть; снять: --unrestrict"
                    continue
                fi ;;
            commented) warn "$u: ключ $(printf '%.12s' "$kblob")... закомментирован в $ak — добавлю активную строку" ;;
        esac
        added=$((added + 1)); add_list="$add_list$ktype $kblob github:$GITHUB_USER
"
    done < "$VALID_KEYS"
    pruned=0
    if [ "$PRUNE_KEYS" = yes ] && [ -f "$ak" ]; then
        pruned=$(L="github:$GITHUB_USER" awk 'FNR == NR { b[$2] = 1; next } $NF == ENVIRON["L"] && !($2 in b) { n++ } END { print n + 0 }' "$VALID_KEYS" "$ak")
    fi
    if [ "$added" -gt 0 ] || [ "$pruned" -gt 0 ]; then
        change ADD "$u: добавить ключей в $ak: $added (уже есть: $present${pruned:+, удалить устаревших github:$GITHUB_USER: $pruned})"
    else
        ok "$u: все $((present + restricted)) ключ(ей) уже в $ak"
    fi
    if [ "$DRY_RUN" != yes ] && [ "$ACTION" = apply ] && { [ "$added" -gt 0 ] || [ "$pruned" -gt 0 ] || [ ! -f "$ak" ]; }; then
        assert_safe_path "$akdir" "$uid"; assert_safe_path "$ak" "$uid"
        if [ ! -d "$akdir" ]; then
            parent=$(dirname "$akdir")
            [ -d "$parent" ] || mkdir -p "$parent" || die "не удалось создать $parent"
            mkdir "$akdir" || die "не удалось создать $akdir"   # без -p: по симлинку mkdir не пройдёт
            if [ "$in_home" = 1 ]; then chmod 700 "$akdir" && chown -h "$uid:$grp" "$akdir"; else chmod 755 "$akdir"; fi
        fi
        [ -e "$ak" ] && [ ! -f "$ak" ] && die "$ak не обычный файл"
        # Новый файл собирается в каталоге назначения через mktemp (O_EXCL, случайное имя, 600 root),
        # затем атомарно переименовывается поверх $ak: симлинки на месте $ak при rename не разыменовываются.
        newak=$(mktemp "$akdir/.authorized_keys.XXXXXX") || die "не удалось создать временный файл в $akdir"
        if [ -f "$ak" ]; then
            [ -L "$ak" ] && die "$ak стал символической ссылкой"
            if [ "$pruned" -gt 0 ]; then
                L="github:$GITHUB_USER" awk 'FNR == NR { b[$2] = 1; next } $NF == ENVIRON["L"] && !($2 in b) { next } { print }' "$VALID_KEYS" "$ak" > "$newak" || { rm -f "$newak"; die "ошибка при очистке $ak"; }
            else
                cat "$ak" > "$newak" || { rm -f "$newak"; die "не удалось прочитать $ak"; }
            fi
        fi
        if [ -s "$newak" ] && [ -n "$(tail -c 1 "$newak")" ]; then printf '\n' >> "$newak"; fi
        printf '%s' "$add_list" >> "$newak" || { rm -f "$newak"; die "не удалось записать $newak"; }
        if [ "$in_home" = 1 ]; then chmod 600 "$newak" && chown -h "$uid:$grp" "$newak"
        elif [ "$uid" = 0 ]; then chmod 600 "$newak" 2>/dev/null || true     # /etc/pve (pmxcfs) может не поддерживать chmod
        else chmod 644 "$newak"; fi
        mv -f "$newak" "$ak" || { rm -f "$newak"; die "не удалось заменить $ak"; }
        # права каталога: только для созданного нами ~/.ssh; домашний каталог (AuthorizedKeysFile %h/...) не трогаем
        if [ "$in_home" = 1 ] && [ "$akdir" != "$h" ] && [ "$(file_mode "$akdir")" != 700 ]; then
            chmod 700 "$akdir" 2>/dev/null || true
        fi
        if have restorecon; then restorecon -R "$akdir" 2>/dev/null || true; fi
    fi
    total=$((present + added))
    usable=$((N_KEYS - unusable))
    case "$u:$PERMIT_ROOT_LOGIN" in
        root:no|root:forced-commands-only) LOGIN_MATRIX="$LOGIN_MATRIX, root (нет: PermitRootLogin $PERMIT_ROOT_LOGIN)" ;;
        *)
            if [ "$can_login" = 0 ]; then LOGIN_MATRIX="$LOGIN_MATRIX, $u (нет: $ALLOW_REASON)"
            elif [ "$total" -eq 0 ] && [ "$restricted" -gt 0 ]; then LOGIN_MATRIX="$LOGIN_MATRIX, $u (только ключи с ограничениями)"
            elif [ "$usable" -le 0 ]; then LOGIN_MATRIX="$LOGIN_MATRIX, $u (нет: тип ключей не принимается sshd)"
            else LOGIN_MATRIX="$LOGIN_MATRIX, $u ($total ключ.)"; LOGIN_OK_USERS=$((LOGIN_OK_USERS + 1)); fi ;;
    esac
}
# После установки ключей: должен остаться хотя бы один пользователь, который реально сможет войти
assert_login_possible() {
    [ "$LOGIN_OK_USERS" -gt 0 ] && return 0
    msg="после отключения паролей войти по ключу не сможет никто (${LOGIN_MATRIX#, }). Проверьте AllowUsers/AllowGroups, PubkeyAcceptedAlgorithms, ограничения from=/command= (--unrestrict)"
    if [ "$FORCE" = yes ]; then warn "$msg (продолжаю из-за --force)"; else die "$msg (или --force)"; fi
}

# ---------- Порты: план и предварительные проверки ----------
CUR_PORTS=""; WANT_PORTS=""; NEW_PORTS=""; MANAGE_PORTS=0; PORTS_CHANGED=0
in_list() { case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
same_set() {  # одинаковые ли множества слов
    for x in $1; do in_list "$x" "$2" || return 1; done
    for x in $2; do in_list "$x" "$1" || return 1; done
    return 0
}
# Активные глобальные ListenAddress с явным портом (host:port, [v6]:port) в main и drop-in'ах
explicit_listen_ports() {
    { cfg_lines "$SSHD_CONFIG" | awk 'tolower($1) == "match" { exit } { print }'
      if [ "$CONFIG_MODE" = dropin ] && [ -d "$DROPIN_DIR" ]; then
          for f in "$DROPIN_DIR"/*.conf; do [ -f "$f" ] && cfg_lines "$f" | awk 'tolower($1) == "match" { exit } { print }'; done
      fi
    } | awk 'tolower($1) == "listenaddress" {
          v = $2; gsub(/"/, "", v)
          if (v ~ /^\[.*\]:[0-9]+$/) { sub(/.*\]:/, "", v); print v; next }
          if (v !~ /\[/ && gsub(/:/, ":", v) == 1) { sub(/.*:/, "", v); print v }
      }' 2>/dev/null | sort -u | tr '\n' ' '
}
# Порты из вывода sshd -T ($1): строки port и явные порты в listenaddress (host:port, [v6]:port)
eff_ports() {
    { eff_values "$1" port
      eff_values "$1" listenaddress | awk '{ v = $1; if (v ~ /\]:[0-9]+$/ || (v !~ /\[/ && gsub(/:/, ":", v) == 1)) { sub(/.*:/, "", v); print v } }'
    } | awk '!seen[$0]++' | tr '\n' ' '
}
# Только вычисления: какие порты сейчас, какие нужны, слушает ли их кто-то. Ничего не меняет и не спрашивает.
compute_ports() {
    sshd_T "$SSHD_CONFIG" > "$TMPDIR_/eff.orig" || die "sshd -T не отработал на исходной конфигурации"
    CUR_PORTS=$(eff_ports "$TMPDIR_/eff.orig"); CUR_PORTS=${CUR_PORTS% }
    SERVICE_WAS_UP=0
    for p in $CUR_PORTS; do port_listening "$p" && SERVICE_WAS_UP=1; done
    [ "$SERVICE_WAS_UP" = 1 ] || warn "сейчас никто не слушает порты sshd ($CUR_PORTS): sshd не запущен? Проверить живость после перезагрузки не смогу"
    MANAGE_PORTS=0; WANT_PORTS=""; PORTS_CHANGED=0
    if [ -n "$SSH_PORT" ]; then
        MANAGE_PORTS=1; WANT_PORTS="$SSH_PORT"
        if [ "$KEEP_OLD_PORT" = yes ]; then
            for p in $CUR_PORTS; do [ "$p" = "$SSH_PORT" ] || WANT_PORTS="$WANT_PORTS $p"; done
        fi
    elif [ -n "$ST_PORTS" ]; then
        MANAGE_PORTS=1; WANT_PORTS="$ST_PORTS"
    elif [ "$CONFIG_MODE" = dropin ] && [ -f "$DROPIN_PATH" ]; then
        prev=$(cfg_lines "$DROPIN_PATH" | awk 'tolower($1) == "port" { print $2 }' | tr '\n' ' ')
        if [ -n "$prev" ]; then MANAGE_PORTS=1; WANT_PORTS=${prev% }; info "порты из прежнего $DROPIN_PATH сохраняются: $WANT_PORTS"; fi
    fi
    if [ "$MANAGE_PORTS" = 1 ]; then
        same_set "$WANT_PORTS" "$CUR_PORTS" || PORTS_CHANGED=1
    else
        WANT_PORTS="$CUR_PORTS"
    fi
    NEW_PORTS=""
    for p in $WANT_PORTS; do in_list "$p" "$CUR_PORTS" || NEW_PORTS="$NEW_PORTS $p"; done
    NEW_PORTS=${NEW_PORTS# }
}
# Предварительные проверки смены порта: занятость, ListenAddress, SELinux, firewall, подтверждение
preflight_ports() {
    [ "$PORTS_CHANGED" = 1 ] || { [ "$MANAGE_PORTS" = 1 ] && ok "порты sshd: $WANT_PORTS (без изменений)"; return 0; }
    note "порты sshd: $CUR_PORTS -> $WANT_PORTS"
    lp=$(explicit_listen_ports)
    if [ -n "$lp" ]; then
        msg="в конфигурации есть ListenAddress с явным портом ($lp): директива Port на него не действует, смена порта не сработает. Исправьте ListenAddress вручную"
        if [ "$FORCE" = yes ]; then warn "$msg"; else die "$msg (или --force)"; fi
    fi
    for p in $NEW_PORTS; do
        if port_listening "$p"; then die "порт $p уже занят другим процессом (ss -ltnp | grep :$p)"; fi
        selinux_allow_port "$p"
        firewall_allow_port "$p"
    done
    if [ "$KEEP_OLD_PORT" = yes ] && [ -n "$SSH_PORT" ] && [ "$WANT_PORTS" != "$SSH_PORT" ]; then
        note "старый порт остаётся открытым, пока вы не проверите вход по новому. Закрыть: --port $SSH_PORT --close-old-port"
    fi
    confirm_prompt "Сменить порты sshd на '$WANT_PORTS'? Убедитесь, что порт открыт в firewall и security group облака."
}
plan_ports() { compute_ports; preflight_ports; }
confirm_prompt() {
    [ "$YES" = yes ] && return 0
    [ "$DRY_RUN" = yes ] && return 0
    if [ -r /dev/tty ] && [ -w /dev/tty ]; then
        printf '%s [y/N] ' "$1" > /dev/tty
        read -r ans < /dev/tty || ans=""
        case "$(lower "$ans")" in y|yes|д|да) return 0 ;; *) die "отменено пользователем" ;; esac
    fi
    info "терминала нет, продолжаю без подтверждения (--yes убирает это сообщение)"
}
selinux_allow_port() {
    have getenforce || return 0
    [ "$(getenforce 2>/dev/null)" = Enforcing ] || return 0
    if ! have semanage; then
        msg="SELinux в режиме Enforcing, а semanage не найден: sshd не сможет слушать порт $1. Установите policycoreutils-python-utils (или python-policycoreutils) и повторите"
        if [ "$FORCE" = yes ]; then warn "$msg"; return 0; else die "$msg"; fi
    fi
    if semanage port -l 2>/dev/null | awk '$1 == "ssh_port_t"' | tr ',' ' ' | grep -qw "$1"; then
        ok "SELinux: порт $1 уже разрешён для ssh_port_t"; return 0
    fi
    if [ "$DRY_RUN" = yes ]; then change SELINUX "semanage port -a -t ssh_port_t -p tcp $1"; return 0; fi
    if semanage port -a -t ssh_port_t -p tcp "$1" 2>/dev/null || semanage port -m -t ssh_port_t -p tcp "$1"; then
        change SELINUX "порт $1 добавлен в ssh_port_t"
    else
        die "semanage не смог разрешить порт $1 для sshd"
    fi
}
firewall_allow_port() {
    fw_seen=0
    if have ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then
        fw_seen=1
        if [ "$OPEN_FIREWALL" = yes ]; then
            if [ "$DRY_RUN" = yes ]; then change FIREWALL "ufw allow $1/tcp"; else ufw allow "$1/tcp" >/dev/null && change FIREWALL "ufw: открыт $1/tcp"; fi
        else
            warn "ufw активен: откройте порт сами (ufw allow $1/tcp) или запустите с --open-firewall"
        fi
    fi
    if have firewall-cmd && firewall-cmd --state 2>/dev/null | grep -q running; then
        fw_seen=1
        if [ "$OPEN_FIREWALL" = yes ]; then
            if [ "$DRY_RUN" = yes ]; then change FIREWALL "firewall-cmd --permanent --add-port=$1/tcp && firewall-cmd --reload"
            else firewall-cmd --permanent --add-port="$1/tcp" >/dev/null && firewall-cmd --reload >/dev/null && change FIREWALL "firewalld: открыт $1/tcp"; fi
        else
            warn "firewalld активен: откройте порт сами (firewall-cmd --permanent --add-port=$1/tcp && firewall-cmd --reload) или --open-firewall"
        fi
    fi
    if [ "$fw_seen" = 0 ]; then
        if { have nft && nft list ruleset 2>/dev/null | grep -q 'hook input'; } || { have iptables && iptables -S INPUT 2>/dev/null | grep -qE -- '-P INPUT (DROP|REJECT)|-j (DROP|REJECT)'; }; then
            warn "обнаружены правила nftables/iptables: убедитесь, что порт $1/tcp разрешён"
        fi
    fi
    warn "если сервер в облаке, откройте порт $1/tcp в security group / сетевом фильтре провайдера"
}

# ---------- Редактирование sshd_config ----------
# Директивы, которыми управляет скрипт (Port — несколько строк, если портов несколько)
managed_directives() {
    if [ "$MANAGE_PORTS" = 1 ]; then for p in $WANT_PORTS; do printf 'Port %s\n' "$p"; done; fi
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
    if [ -n "$LOG_LEVEL" ]; then printf 'LogLevel %s\n' "$LOG_LEVEL"; fi
    if [ "$BANNER" = yes ]; then printf 'Banner %s\n' "$BANNER_FILE"; fi
    if [ -n "$ACCEPT_ENV" ]; then printf 'AcceptEnv %s\n' "$ACCEPT_ENV"; fi
    if [ "$STRICT_AUTH" = yes ]; then printf 'AuthenticationMethods publickey\n'; fi
    if [ -n "$ALLOW_GROUPS" ]; then printf 'AllowGroups %s\n' "$ALLOW_GROUPS"; fi
    if [ -n "$ALLOW_AGENT_FORWARDING" ]; then printf 'AllowAgentForwarding %s\n' "$ALLOW_AGENT_FORWARDING"; fi
    if [ -n "$IDLE_TIMEOUT" ] && [ "$IDLE_TIMEOUT" -gt 0 ] && ver_ge 9 2; then
        printf 'UnusedConnectionTimeout %s\n' "$IDLE_TIMEOUT"
        printf 'ChannelTimeout session=%s\n' "$IDLE_TIMEOUT"
    fi
}
# Все значения директивы $1 в глобальной секции файла $2 (до первого Match), по одному в строке
get_global_all() {
    K="$(lower "$1")" awk '
        { f = $1; sub(/=.*/, "", f); lf = tolower(f) }
        lf == "match" { exit }
        lf == ENVIRON["K"] {
            v = $0
            sub(/^[ \t]*[^ \t=]+[ \t=]+/, "", v); sub(/[ \t]+$/, "", v)
            print v
        }' "$2"
}
get_global() { get_global_all "$1" "$2" | head -n 1; }
# Записать блок строк $2 (первая строка — "$1 значение", далее полные директивы) в глобальную секцию:
# заменить первое вхождение $1, убрать его дубли, иначе вставить перед первым Include/Match или в конец.
set_global() {
    K="$1" BLOCK="$2" KEEP="${4:-0}" awk '
        BEGIN { lk = tolower(ENVIRON["K"]); done = 0; inmatch = 0; keep = ENVIRON["KEEP"] }
        {
            f = $1; sub(/=.*/, "", f); lf = tolower(f)
            if (lf == "match" || lf == "include") {
                if (!done) { print ENVIRON["BLOCK"]; done = 1 }
                if (lf == "match") inmatch = 1
            }
            if (!inmatch && lf == lk && !keep) {
                if (!done) { print ENVIRON["BLOCK"]; done = 1 }
                next
            }
            print
        }
        END { if (!done) print ENVIRON["BLOCK"] }' "$3"
}
# insert_global KEY LINE FILE — вставить строку в глобальную секцию, не трогая существующие (накопительные директивы)
insert_global() { set_global "$1" "$2" "$3" 1; }
# Закомментировать все активные строки директивы $1 в глобальной секции файла $2,
# кроме строки со значением $3 (если задано) — свою строку оставляем
comment_global() {
    K="$(lower "$1")" KEEPVAL="${3:-}" awk '
        BEGIN { inmatch = 0 }
        { f = $1; sub(/=.*/, "", f); lf = tolower(f) }
        lf == "match" { inmatch = 1 }
        !inmatch && lf == ENVIRON["K"] {
            v = $0; sub(/^[ \t]*[^ \t=]+[ \t=]+/, "", v); sub(/[ \t]+$/, "", v)
            if (ENVIRON["KEEPVAL"] != "" && v == ENVIRON["KEEPVAL"]) { print; next }
            print "#" $0 " # отключено secure_ssh.sh"; next
        }
        { print }' "$2"
}
show_diff() {  # $1 = текущий файл (может отсутствовать), $2 = новый
    if have diff; then
        diff -u "$1" "$2" 2>/dev/null | sed -e '1,2d' -e 's/^/    /' || true
    fi
}

MAIN_CHANGES=""; DROPIN_CHANGED=0; MAIN_CHANGED=0
# Собрать будущий $SSHD_CONFIG в $TMPDIR_/main.new и описать изменения (ничего не пишет)
build_main() {
    cfg_lines "$SSHD_CONFIG" > "$TMPDIR_/main.new"
    if [ "$DISABLE_ACCEPT_ENV" = yes ] && get_global_all AcceptEnv "$TMPDIR_/main.new" | grep -qvxF -- "${ACCEPT_ENV:-__none__}"; then
        comment_global AcceptEnv "$TMPDIR_/main.new" "$ACCEPT_ENV" > "$TMPDIR_/main.tmp" && mv "$TMPDIR_/main.tmp" "$TMPDIR_/main.new"
        MAIN_CHANGES="$MAIN_CHANGES
  закомментированы глобальные AcceptEnv${ACCEPT_ENV:+ (кроме $ACCEPT_ENV)} (клиент не сможет навязать переменные окружения)"
    fi
    if [ "$CONFIG_MODE" = dropin ]; then
        if [ -z "$INCLUDE_PATTERN" ]; then
            {
                printf '# Добавлено secure_ssh.sh: файлы из sshd_config.d имеют приоритет (sshd берёт первое значение)\n'
                printf 'Include %s/*.conf\n\n' "$DROPIN_DIR"
                cat "$TMPDIR_/main.new"
            } > "$TMPDIR_/main.tmp" && mv "$TMPDIR_/main.tmp" "$TMPDIR_/main.new"
            MAIN_CHANGES="$MAIN_CHANGES
  в начало добавлен Include $DROPIN_DIR/*.conf"
        fi
        if [ "$MANAGE_PORTS" = 1 ] && [ -n "$(get_global Port "$TMPDIR_/main.new")" ]; then
            comment_global Port "$TMPDIR_/main.new" > "$TMPDIR_/main.tmp" && mv "$TMPDIR_/main.tmp" "$TMPDIR_/main.new"
            MAIN_CHANGES="$MAIN_CHANGES
  закомментированы строки Port (Port накопительный, порты теперь задаёт drop-in)"
        fi
    else
        managed_directives > "$TMPDIR_/directives"
        prev_key=""
        while read -r key val; do
            [ "$key" = "$prev_key" ] && continue   # Port с несколькими значениями обрабатывается один раз
            prev_key="$key"
            if [ "$key" = Port ]; then
                cur=$(get_global_all Port "$TMPDIR_/main.new" | tr '\n' ' '); cur=${cur% }
                if same_set "${cur:-22}" "$WANT_PORTS"; then ok "Port уже = $WANT_PORTS"; continue; fi
                block=""; for p in $WANT_PORTS; do block="${block:+$block
}Port $p"; done
                set_global Port "$block" "$TMPDIR_/main.new" > "$TMPDIR_/main.tmp" && mv "$TMPDIR_/main.tmp" "$TMPDIR_/main.new"
                MAIN_CHANGES="$MAIN_CHANGES
  Port: ${cur:-<по умолчанию 22>} -> $WANT_PORTS"
                continue
            fi
            case "$key" in AcceptEnv|AllowGroups)   # накопительные: добавляем свою строку, чужие активные не трогаем
                if get_global_all "$key" "$TMPDIR_/main.new" | grep -qxF -- "$val"; then ok "$key $val уже есть"; continue; fi
                insert_global "$key" "$key $val" "$TMPDIR_/main.new" > "$TMPDIR_/main.tmp" && mv "$TMPDIR_/main.tmp" "$TMPDIR_/main.new"
                MAIN_CHANGES="$MAIN_CHANGES
  $key $val (добавлено)"
                continue ;;
            esac
            cur=$(get_global "$key" "$TMPDIR_/main.new")
            if [ "$(lower "$cur")" = "$(lower "$val")" ]; then ok "$key уже = $val"; continue; fi
            set_global "$key" "$key $val" "$TMPDIR_/main.new" > "$TMPDIR_/main.tmp" && mv "$TMPDIR_/main.tmp" "$TMPDIR_/main.new"
            if [ -n "$cur" ]; then MAIN_CHANGES="$MAIN_CHANGES
  $key: $cur -> $val"; else MAIN_CHANGES="$MAIN_CHANGES
  $key -> $val (добавлено)"; fi
        done < "$TMPDIR_/directives"
    fi
    if ! same_file "$TMPDIR_/main.new" "$SSHD_CONFIG"; then MAIN_CHANGED=1; fi
}
build_dropin() {
    [ "$CONFIG_MODE" = dropin ] || return 0
    {
        printf '# Управляется secure_ssh.sh v%s. Файл перезаписывается при каждом запуске, не редактируйте вручную.\n' "$VERSION"
        printf '# Имя с префиксом 00- даёт приоритет над 50-cloud-init.conf, 50-redhat.conf и т.п.\n'
        managed_directives
    } > "$TMPDIR_/dropin.new"
    if [ ! -f "$DROPIN_PATH" ] || ! same_file "$TMPDIR_/dropin.new" "$DROPIN_PATH"; then DROPIN_CHANGED=1; fi
}
# Проверить будущую конфигурацию sshd -t во временной копии, ещё ничего не записав
validate_candidate() {
    cand="$TMPDIR_/cand"; mkdir -p "$cand/d"
    cp "$TMPDIR_/main.new" "$cand/sshd_config"
    if [ "$CONFIG_MODE" = dropin ]; then
        if [ -d "$DROPIN_DIR" ]; then for f in "$DROPIN_DIR"/*.conf; do [ -f "$f" ] && cp "$f" "$cand/d/"; done; fi
        cp "$TMPDIR_/dropin.new" "$cand/d/$DROPIN_NAME"
        P="${INCLUDE_PATTERN:-$DROPIN_DIR/*.conf}" C="$cand/d/*.conf" awk '
            !done && tolower($1) == "include" && index($0, ENVIRON["P"]) { sub(/[Ii][Nn][Cc][Ll][Uu][Dd][Ee].*/, "Include " ENVIRON["C"]); done = 1 }
            { print }' "$cand/sshd_config" > "$cand/sshd_config.tmp" && mv "$cand/sshd_config.tmp" "$cand/sshd_config"
    fi
    if out=$("$SSHD_BIN" -t -f "$cand/sshd_config" 2>&1); then
        ok "sshd -t: будущая конфигурация корректна"
    else
        say "$out" >&2
        die "будущая конфигурация не проходит sshd -t, ничего не записано"
    fi
    sshd_T "$cand/sshd_config" > "$TMPDIR_/eff.cand" || true
}

# ---------- Запись файлов: бэкапы, атомарность ----------
backup_main() {
    [ -n "$RUN_BACKUP" ] && return 0
    if [ ! -f "$SSHD_CONFIG.orig" ] && [ "$NO_ORIG" = 0 ]; then
        cp -p "$SSHD_CONFIG" "$SSHD_CONFIG.orig" && same_file "$SSHD_CONFIG" "$SSHD_CONFIG.orig" \
            || { rm -f "$SSHD_CONFIG.orig"; die "не удалось сохранить первоначальную копию $SSHD_CONFIG.orig (нет места?)"; }
        info "первоначальная копия сохранена: $SSHD_CONFIG.orig"
    fi
    b="$SSHD_CONFIG.bak.$(date +%Y%m%d-%H%M%S)"
    cp -p "$SSHD_CONFIG" "$b" && same_file "$SSHD_CONFIG" "$b" || { rm -f "$b"; die "не удалось создать бэкап $b (нет места?)"; }
    RUN_BACKUP="$b"
    info "бэкап перед изменением: $RUN_BACKUP"
}
# apply_file ИСТОЧНИК ЦЕЛЬ main|dropin|banner|state — атомарная запись с бэкапом; сбой = откат и выход
apply_file() {
    src="$1"; dst="$2"; kind="$3"
    if [ -f "$dst" ] && same_file "$src" "$dst"; then return 0; fi
    case "$kind" in
        main)   backup_main ;;
        dropin) if [ -z "$DROPIN_SAVED" ]; then
                    if [ -f "$dst" ]; then cp -p "$dst" "$TMPDIR_/dropin.prev" || die "не удалось прочитать $dst"; DROPIN_SAVED=existing; else DROPIN_SAVED=absent; fi
                fi ;;
        banner) if [ -z "$BANNER_SAVED" ]; then
                    if [ -f "$dst" ]; then
                        cp -p "$dst" "$TMPDIR_/banner.prev" || die "не удалось прочитать $dst"; BANNER_SAVED=existing
                        [ -f "$dst.orig" ] || cp -p "$dst" "$dst.orig" 2>/dev/null || true
                    else BANNER_SAVED=absent; fi
                fi ;;
        state)  if [ -z "$STATE_SAVED" ]; then
                    if [ -f "$dst" ]; then cp -p "$dst" "$TMPDIR_/state.prev" 2>/dev/null && STATE_SAVED=existing || STATE_SAVED=absent; else STATE_SAVED=absent; fi
                fi ;;
    esac
    APPLY_STARTED=1
    tmp="$dst.secure_ssh.tmp"
    if [ -f "$dst" ]; then
        cp -p "$dst" "$tmp" 2>/dev/null || { rm -f "$tmp"; die "не удалось записать $tmp"; }   # сохраняем владельца/права
    else
        mkdir -p "$(dirname "$dst")" || die "не удалось создать каталог для $dst"
        : > "$tmp" && chmod 644 "$tmp" || { rm -f "$tmp"; die "не удалось создать $tmp"; }
    fi
    if ! cat "$src" > "$tmp" || ! same_file "$src" "$tmp"; then rm -f "$tmp"; die "не удалось записать $dst (нет места на диске?)"; fi
    mv -f "$tmp" "$dst" || { rm -f "$tmp"; die "не удалось заменить $dst"; }
    if have restorecon; then restorecon "$dst" 2>/dev/null || true; fi
    case "$kind" in main|dropin) NEED_RELOAD=1 ;; esac
    return 0
}

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
BANNER_CHANGED=0
plan_banner() {
    [ "$BANNER" = yes ] || return 0
    banner_text > "$TMPDIR_/banner"
    if [ -L "$BANNER_FILE" ]; then
        warn "$BANNER_FILE — символическая ссылка, баннер не трогаю"; BANNER=no; return 0
    fi
    if [ -f "$BANNER_FILE" ] && same_file "$TMPDIR_/banner" "$BANNER_FILE"; then
        ok "баннер $BANNER_FILE уже актуален"
    else
        BANNER_CHANGED=1
        change UPDATE "баннер будет записан в $BANNER_FILE${BANNER_FILE:+ (прежний сохраняется как $BANNER_FILE.orig)}"
    fi
}

# ---------- Применение ----------
apply_config() {
    if [ "$MAIN_CHANGED" = 1 ]; then
        change UPDATE "$SSHD_CONFIG:$MAIN_CHANGES"
        if [ "$DRY_RUN" = yes ]; then show_diff "$SSHD_CONFIG" "$TMPDIR_/main.new"; fi
    else
        ok "$SSHD_CONFIG без изменений"
    fi
    if [ "$CONFIG_MODE" = dropin ]; then
        if [ "$DROPIN_CHANGED" = 1 ]; then
            change UPDATE "$DROPIN_PATH"
            if [ "$DRY_RUN" = yes ]; then if [ -f "$DROPIN_PATH" ]; then show_diff "$DROPIN_PATH" "$TMPDIR_/dropin.new"; else show_diff /dev/null "$TMPDIR_/dropin.new"; fi; fi
        else
            ok "$DROPIN_PATH уже актуален"
        fi
    fi
    [ "$DRY_RUN" = yes ] && return 0
    [ "$MAIN_CHANGED" = 1 ] && apply_file "$TMPDIR_/main.new" "$SSHD_CONFIG" main
    [ "$DROPIN_CHANGED" = 1 ] && apply_file "$TMPDIR_/dropin.new" "$DROPIN_PATH" dropin
    if [ "$APPLY_STARTED" = 1 ] && [ "$NEED_RELOAD" = 1 ]; then
        if out=$("$SSHD_BIN" -t -f "$SSHD_CONFIG" 2>&1); then
            ok "sshd -t: записанная конфигурация корректна"
        else
            say "$out" >&2
            rollback
            die "sshd -t нашёл ошибку в записанной конфигурации, изменения откачены. sshd не перезапускался."
        fi
    fi
    [ "$BANNER_CHANGED" = 1 ] && apply_file "$TMPDIR_/banner" "$BANNER_FILE" banner
    APPLY_OK=1
    return 0
}
do_reload() {
    [ "$DRY_RUN" = yes ] && return 0
    if [ "$NEED_RELOAD" != 1 ] && [ "$ST_RELOAD_PENDING" = 1 ]; then
        note "в прошлый раз перезагрузка sshd не удалась — повторяю"
        NEED_RELOAD=1
    fi
    if [ "$NEED_RELOAD" != 1 ]; then info "изменений в конфигурации sshd нет, перезагрузка не требуется"; return 0; fi
    if [ "$NO_RELOAD" = yes ]; then warn "--no-reload: sshd не перезагружен, изменения вступят в силу после перезагрузки службы"; return 0; fi
    if ! reload_sshd reload; then
        RELOAD_FAILED=1
        if [ "$SERVICE_WAS_UP" = 1 ] && ! wait_listening "$CUR_PORTS" 3; then
            APPLY_OK=0
            warn "после неудачной перезагрузки sshd не слушает ни старые, ни новые порты!"
            rollback
            die "откат выполнен, sshd перезапущен со старой конфигурацией"
        fi
        warn "sshd НЕ перезагружен и работает со старой конфигурацией. Перезагрузите его вручную; при следующем запуске скрипт повторит перезагрузку"
        return 0
    fi
    if [ "$SERVICE_WAS_UP" = 1 ]; then
        if wait_listening "$WANT_PORTS" 5; then
            ok "sshd слушает порты: $WANT_PORTS"
        else
            APPLY_OK=0
            warn "после перезагрузки sshd не слушает порты '$WANT_PORTS'! Проверьте журнал: journalctl -u ${RELOAD_UNIT:-ssh} -n 20"
            rollback
            die "откат выполнен, sshd перезапущен со старой конфигурацией"
        fi
    fi
}

# ---------- Проверка эффективных значений ----------
MISMATCH=0
locate_directive() {  # где в конфигурации встречается директива $1 (файл:строка активных вхождений)
    { grep -niE "^[[:space:]]*$1([[:space:]]|=)" "$SSHD_CONFIG" | sed "s|^|$SSHD_CONFIG:|"
      if [ -d "$DROPIN_DIR" ]; then for f in "$DROPIN_DIR"/*.conf; do [ -f "$f" ] && grep -niE "^[[:space:]]*$1([[:space:]]|=)" "$f" | sed "s|^|$f:|"; done; fi
    } 2>/dev/null | head -n 5 | tr '\n' ';'
}
verify_effective() {
    efff="$1"
    managed_directives > "$TMPDIR_/directives"
    if [ "$MANAGE_PORTS" = 1 ] || [ -n "$CUR_PORTS" ]; then
        got=$(eff_values "$efff" port | awk '!seen[$0]++' | tr '\n' ' '); got=${got% }
        if same_set "$got" "$WANT_PORTS"; then ok "эффективно: Port $got"
        else MISMATCH=1; warn "эффективно: Port = '$got', ожидалось '$WANT_PORTS'. Строки Port: $(locate_directive Port)"; fi
    fi
    got=$(eff_values "$efff" acceptenv | tr '\n' ' '); got=${got% }
    if [ "$DISABLE_ACCEPT_ENV" = yes ]; then
        if same_set "$got" "$ACCEPT_ENV"; then ok "эффективно: AcceptEnv ${got:-<нет>}"
        else MISMATCH=1; warn "эффективно: AcceptEnv = '${got:-<нет>}', ожидалось '${ACCEPT_ENV:-<нет>}'. Вхождения: $(locate_directive AcceptEnv)"; fi
    elif [ -n "$ACCEPT_ENV" ]; then
        miss=""; for v in $ACCEPT_ENV; do in_list "$v" "$got" || miss="$miss $v"; done
        if [ -z "$miss" ]; then ok "эффективно: AcceptEnv $got"; else MISMATCH=1; warn "эффективно: AcceptEnv = '$got', не хватает:$miss"; fi
    fi
    if [ -n "$ALLOW_GROUPS" ]; then
        got=$(eff_values "$efff" allowgroups | tr '\n' ' '); miss=""
        for g in $ALLOW_GROUPS; do in_list "$g" "$got" || miss="$miss $g"; done
        if [ -z "$miss" ]; then ok "эффективно: AllowGroups ${got% }"; else MISMATCH=1; warn "эффективно: AllowGroups = '${got% }', не хватает:$miss"; fi
    fi
    while read -r key val; do
        [ "$key" = Port ] && continue
        [ "$key" = AcceptEnv ] && continue
        [ "$key" = AllowGroups ] && continue
        k=$(lower "$key"); v=$(lower "$val")
        got=$(eff_value "$efff" "$k")
        [ "$k" = permitrootlogin ] && [ "$v" = prohibit-password ] && v=without-password
        if [ -z "$got" ] && [ "$k" = challengeresponseauthentication ]; then continue; fi
        if [ "$(lower "$got")" = "$v" ]; then
            ok "эффективно: $key $val"
        else
            MISMATCH=1
            warn "эффективно: $key = '${got:-?}', ожидалось '$val'. sshd берёт первое значение; вхождения: $(locate_directive "$key")"
        fi
    done < "$TMPDIR_/directives"
    # Match-блоки видны только с -C: проверяем для каждого целевого пользователя
    for u in $TARGET_USERS; do
        sshd_T "$2" "$u" > "$TMPDIR_/eff.u" 2>/dev/null || continue
        pa=$(eff_value "$TMPDIR_/eff.u" passwordauthentication); pk=$(eff_value "$TMPDIR_/eff.u" pubkeyauthentication)
        if [ "$pa" != no ] || [ "$pk" != yes ]; then
            MISMATCH=1
            warn "для пользователя $u (с учётом Match): PasswordAuthentication=$pa PubkeyAuthentication=$pk — проверьте блоки Match в $SSHD_CONFIG"
        fi
        if ! user_allowed "$u" "$TMPDIR_/eff.u"; then
            case "$u:$PERMIT_ROOT_LOGIN" in root:no|root:forced-commands-only) ;; *) MISMATCH=1; warn "для пользователя $u вход запрещён: $ALLOW_REASON" ;; esac
        fi
    done
}

# ---------- Подтверждение из новой сессии (таймер автоотката) ----------
confirm_or_rollback() {
    [ "$CONFIRM_TIMEOUT" -gt 0 ] || return 0
    [ "$DRY_RUN" = yes ] && return 0
    rm -f "$CONFIRM_FILE" "$CONFIRM_FILE.done"
    say ""
    note "ЖДУ ПОДТВЕРЖДЕНИЯ $CONFIRM_TIMEOUT с: откройте НОВОЕ окно, войдите по ключу и выполните:  sudo touch $CONFIRM_FILE"
    note "(или нажмите Enter здесь). Без подтверждения, а также при обрыве этой сессии, все изменения будут откачены, sshd перезапущен."
    # Сторож, независимый от терминала: переживает SIGHUP и откатывает сам, если основной процесс исчез,
    # не откатив (например, убит SIGKILL). Журнал сторожа — рядом с бэкапами.
    wdlog="$CFG_DIR/.secure_ssh.watchdog.log"
    (
        trap '' HUP INT TERM PIPE; set +e
        exec >"$wdlog" 2>&1
        i=0
        while [ "$i" -lt "$((CONFIRM_TIMEOUT + 5))" ]; do
            [ -f "$CONFIRM_FILE" ] && exit 0
            [ -f "$CONFIRM_FILE.done" ] && exit 0
            sleep 1; i=$((i + 1))
        done
        [ -f "$CONFIRM_FILE" ] || [ -f "$CONFIRM_FILE.done" ] && exit 0
        warn "сторож: основной процесс не завершил ожидание, откатываю сам ($(date))"
        rollback; : > "$CONFIRM_FILE.done"
    ) &
    WD_PID=$!
    CONFIRM_PENDING=1
    if [ -r /dev/tty ]; then ( read -r _ < /dev/tty && : > "$CONFIRM_FILE" ) 2>/dev/null & RPID=$!; fi
    i=0; confirmed=0
    while [ "$i" -lt "$CONFIRM_TIMEOUT" ]; do
        if [ -f "$CONFIRM_FILE" ]; then confirmed=1; break; fi
        sleep 1; i=$((i + 1))
    done
    CONFIRM_PENDING=0
    if [ -n "$RPID" ]; then kill "$RPID" 2>/dev/null || true; RPID=""; fi
    if [ "$confirmed" = 1 ]; then
        : > "$CONFIRM_FILE.done"; kill "$WD_PID" 2>/dev/null || true; WD_PID=""
        rm -f "$CONFIRM_FILE" "$CONFIRM_FILE.done"
        ok "подтверждено, изменения сохранены"; return 0
    fi
    warn "подтверждение не получено за $CONFIRM_TIMEOUT с"
    APPLY_OK=1; rollback; : > "$CONFIRM_FILE.done"
    kill "$WD_PID" 2>/dev/null || true; WD_PID=""
    rm -f "$CONFIRM_FILE" "$CONFIRM_FILE.done"
    say ""; note "Итог: изменения ОТКАЧЕНЫ по таймеру --confirm, sshd перезапущен со старой конфигурацией (ключи в authorized_keys остались)."
    exit 3
}

write_state() {
    [ "$DRY_RUN" = yes ] && return 0
    {
        printf '# secure_ssh.sh v%s: параметры последнего запуска, используются как значения по умолчанию\n' "$VERSION"
        printf 'MODE=%s\n' "$CONFIG_MODE"
        [ "$MANAGE_PORTS" = 1 ] && printf 'PORTS=%s\n' "$WANT_PORTS"
        printf 'PERMIT_ROOT_LOGIN=%s\nALLOW_TCP_FORWARDING=%s\nX11_FORWARDING=%s\nMAX_AUTH_TRIES=%s\n' \
            "$PERMIT_ROOT_LOGIN" "$ALLOW_TCP_FORWARDING" "$X11_FORWARDING" "$MAX_AUTH_TRIES"
        printf 'LOGIN_GRACE_TIME=%s\nCLIENT_ALIVE_INTERVAL=%s\nCLIENT_ALIVE_COUNT_MAX=%s\n' \
            "$LOGIN_GRACE_TIME" "$CLIENT_ALIVE_INTERVAL" "$CLIENT_ALIVE_COUNT_MAX"
        [ -n "$LOG_LEVEL" ] && printf 'LOG_LEVEL=%s\n' "$LOG_LEVEL"
        [ -n "$ACCEPT_ENV" ] && printf 'ACCEPT_ENV=%s\n' "$ACCEPT_ENV"
        printf 'STRICT_AUTH=%s\n' "$STRICT_AUTH"
        [ -n "$ALLOW_GROUPS" ] && printf 'ALLOW_GROUPS=%s\n' "$ALLOW_GROUPS"
        [ -n "$IDLE_TIMEOUT" ] && printf 'IDLE_TIMEOUT=%s\n' "$IDLE_TIMEOUT"
        [ -n "$ALLOW_AGENT_FORWARDING" ] && printf 'ALLOW_AGENT_FORWARDING=%s\n' "$ALLOW_AGENT_FORWARDING"
        [ "$RELOAD_FAILED" = 1 ] && printf 'RELOAD_PENDING=1\n'
    } > "$TMPDIR_/state.new"
    apply_file "$TMPDIR_/state.new" "$STATE_FILE" state
}

summary() {
    say ""
    say "──────── Итог ────────"
    if [ "$CONFIG_MODE" = dropin ]; then say "Режим:           dropin ($DROPIN_PATH)"; else say "Режим:           legacy ($SSHD_CONFIG)"; fi
    say "Порты sshd:      $WANT_PORTS$( [ "$PORTS_CHANGED" = 1 ] && printf ' (было: %s)' "$CUR_PORTS")"
    say "Вход по ключу:   ${LOGIN_MATRIX#, } — ключи $KEYS_SOURCE"
    [ -n "$STICKY_NOTE" ] && say "Из прошлого:    $STICKY_NOTE (сбросить: --reset)"
    if [ "$DRY_RUN" = yes ]; then
        say "Результат:       DRY-RUN, ничего не записано. Запустите без --dry-run для применения."
    elif [ "$RELOAD_FAILED" = 1 ]; then
        say "Результат:       ${C_WARN}настройки записаны, но sshd НЕ перезагружен${C_OFF} — перезагрузите вручную"
    elif [ "$MISMATCH" = 1 ]; then
        say "Результат:       ${C_WARN}ВНИМАНИЕ: часть значений перекрыта другой директивой (код выхода 2)${C_OFF}, см. предупреждения выше"
    elif [ "$NEED_RELOAD" = 1 ] && [ "$NO_RELOAD" = yes ]; then
        say "Результат:       настройки записаны, sshd не перезагружался (--no-reload)"
    else
        say "Результат:       ${C_OK}OK${C_OFF}"
    fi
    first_port=${WANT_PORTS%% *}
    say "Проверьте вход, НЕ закрывая эту сессию, в новом окне:  ssh -p ${first_port:-22} <пользователь>@<сервер>"
}

# ---------- --check ----------
do_check() {
    compute_ports
    say ""
    say "──────── Проверка (ничего не меняется) ────────"
    say "Конфиг: $SSHD_CONFIG; режим: $CONFIG_MODE; Include: ${INCLUDE_PATTERN:-нет}"
    if [ "$CONFIG_MODE" = dropin ]; then
        if [ -f "$DROPIN_PATH" ]; then say "Drop-in: $DROPIN_PATH ($(grep -cvE '^[[:space:]]*(#|$)' "$DROPIN_PATH") директив)"; else say "Drop-in: $DROPIN_PATH отсутствует"; fi
        if [ -d "$DROPIN_DIR" ]; then
            others=""
            for f in "$DROPIN_DIR"/*; do [ -e "$f" ] || continue; [ "$(basename "$f")" = "$DROPIN_NAME" ] || others="$others $(basename "$f")"; done
            [ -n "$others" ] && say "Другие drop-in:$others"
        fi
    fi
    [ -f "$STATE_FILE" ] && say "Состояние прошлого запуска: $STATE_FILE"
    say ""
    say "Порты: $CUR_PORTS"
    for p in $CUR_PORTS; do if port_listening "$p"; then say "  $p: слушается"; else say "  $p: НЕ слушается"; fi; done
    say ""
    say "Эффективные значения:"
    for k in permitrootlogin passwordauthentication permitemptypasswords pubkeyauthentication kbdinteractiveauthentication \
             challengeresponseauthentication authenticationmethods maxauthtries logingracetime clientaliveinterval clientalivecountmax \
             x11forwarding allowtcpforwarding loglevel banner authorizedkeysfile strictmodes usepam acceptenv; do
        v=$(eff_values "$TMPDIR_/eff.orig" "$k" | tr '\n' ' '); [ -n "$v" ] || continue
        say "  $k $v"
    done
    [ "$(eff_value "$TMPDIR_/eff.orig" passwordauthentication)" = yes ] && warn "PasswordAuthentication yes — вход по паролю разрешён"
    say ""
    say "Пользователи:"
    for u in $TARGET_USERS; do
        h=$(user_home "$u"); ak=$(akf_for_user "$u" "$h" "$(user_uid "$u")")
        pa=$(eff_value "$TMPDIR_/eff.user" passwordauthentication); pk=$(eff_value "$TMPDIR_/eff.user" pubkeyauthentication)
        say "  $u: AuthorizedKeysFile=$ak; с учётом Match: PasswordAuthentication=${pa:-?} PubkeyAuthentication=${pk:-?}"
        user_allowed "$u" "$TMPDIR_/eff.user" || warn "  $u: вход запрещён: $ALLOW_REASON"
        algs=$(eff_value "$TMPDIR_/eff.user" pubkeyacceptedalgorithms); [ -n "$algs" ] && say "    PubkeyAcceptedAlgorithms: $algs"
        if [ -f "$ak" ]; then
            n=$(grep -cvE '^[[:space:]]*(#|$)' "$ak" || true); g=$(grep -c "github:$GITHUB_USER\$" "$ak" || true)
            say "    активных ключей: $n (с меткой github:$GITHUB_USER: $g); права: $(file_mode "$ak"), владелец uid $(file_uid "$ak")"
            if have ssh-keygen; then ssh-keygen -lf "$ak" 2>/dev/null | awk '{ print "    " $2 " " $NF " " $3 }'; fi
        else
            say "    файл ключей отсутствует"
        fi
    done
    say ""
    if systemd_usable; then
        for u in ssh sshd; do systemctl cat "$u.service" >/dev/null 2>&1 && say "Служба: $u.service $(systemctl is-active "$u.service" 2>/dev/null || true); ssh.socket: $(systemctl is-active ssh.socket 2>/dev/null || true)" && break; done
    fi
    return 0
}

# ---------- --rollback ----------
do_rollback() {
    src="${ROLLBACK_FROM:-$SSHD_CONFIG.orig}"
    [ -s "$src" ] || die "файл для отката $src не найден или пуст. Доступные бэкапы: $(ls "$SSHD_CONFIG".orig "$SSHD_CONFIG".bak.* 2>/dev/null | tr '\n' ' ')"
    if [ -n "$ROLLBACK_FROM" ] && [ ! -f "$SSHD_CONFIG.orig" ] && ! grep -q 'secure_ssh.sh' "$src"; then
        info "$SSHD_CONFIG.orig отсутствует; $src не содержит следов скрипта, сохраняю его как $SSHD_CONFIG.orig"
        cp -p "$src" "$SSHD_CONFIG.orig" 2>/dev/null || true
    fi
    compute_ports
    note "откат: $SSHD_CONFIG <- $src"
    if same_file "$src" "$SSHD_CONFIG"; then ok "$SSHD_CONFIG уже совпадает с $src"; else show_diff "$SSHD_CONFIG" "$src"; fi
    if [ "$DRY_RUN" = yes ]; then
        [ -f "$DROPIN_PATH" ] && change REMOVE "$DROPIN_PATH"
        [ -f "$BANNER_FILE.orig" ] && change RESTORE "$BANNER_FILE <- $BANNER_FILE.orig"
        info "DRY-RUN: ничего не изменено"; return 0
    fi
    NO_ORIG=1   # при откате явным файлом «первоначальной копией» не должен стать уже изменённый конфиг
    apply_file "$src" "$SSHD_CONFIG" main
    if [ -f "$DROPIN_PATH" ]; then
        cp -p "$DROPIN_PATH" "$TMPDIR_/dropin.prev" && DROPIN_SAVED=existing
        rm -f "$DROPIN_PATH" && change REMOVE "$DROPIN_PATH"; NEED_RELOAD=1
    fi
    if [ -f "$BANNER_FILE.orig" ]; then apply_file "$BANNER_FILE.orig" "$BANNER_FILE" banner && change RESTORE "$BANNER_FILE <- $BANNER_FILE.orig"; fi
    if [ -f "$STATE_FILE" ]; then cp -p "$STATE_FILE" "$TMPDIR_/state.prev" 2>/dev/null && STATE_SAVED=existing; rm -f "$STATE_FILE"; fi
    if out=$("$SSHD_BIN" -t -f "$SSHD_CONFIG" 2>&1); then
        ok "sshd -t: конфигурация после отката корректна"
    else
        say "$out" >&2; rollback; die "конфигурация из $src не проходит sshd -t, возвращено как было"
    fi
    APPLY_OK=1
    sshd_T "$SSHD_CONFIG" > "$TMPDIR_/eff.rb" || true
    WANT_PORTS=$(eff_ports "$TMPDIR_/eff.rb"); WANT_PORTS=${WANT_PORTS% }
    PORTS_CHANGED=0; same_set "$WANT_PORTS" "$CUR_PORTS" || { PORTS_CHANGED=1; warn "после отката порты sshd: $WANT_PORTS (были: $CUR_PORTS) — проверьте firewall"; }
    do_reload
    note "ключи в authorized_keys не удалялись. Порты sshd теперь: $WANT_PORTS"
    return 0
}

# ---------- main ----------
main() {
    parse_args "$@"
    preflight
    [ "$RESET_STATE" = yes ] || load_state
    pick PERMIT_ROOT_LOGIN "$ST_PERMIT_ROOT_LOGIN" "$D_PERMIT_ROOT_LOGIN"
    pick ALLOW_TCP_FORWARDING "$ST_ALLOW_TCP_FORWARDING" "$D_ALLOW_TCP_FORWARDING"
    pick X11_FORWARDING "$ST_X11_FORWARDING" "$D_X11_FORWARDING"
    pick MAX_AUTH_TRIES "$ST_MAX_AUTH_TRIES" "$D_MAX_AUTH_TRIES"
    pick LOGIN_GRACE_TIME "$ST_LOGIN_GRACE_TIME" "$D_LOGIN_GRACE_TIME"
    pick CLIENT_ALIVE_INTERVAL "$ST_CLIENT_ALIVE_INTERVAL" "$D_CLIENT_ALIVE_INTERVAL"
    pick CLIENT_ALIVE_COUNT_MAX "$ST_CLIENT_ALIVE_COUNT_MAX" "$D_CLIENT_ALIVE_COUNT_MAX"
    pick LOG_LEVEL "$ST_LOG_LEVEL" "$D_LOG_LEVEL"
    pick ACCEPT_ENV "$ST_ACCEPT_ENV" ""
    [ "$STRICT_AUTH" = no ] && [ "$ST_STRICT_AUTH" = yes ] && { STRICT_AUTH=yes; STICKY_NOTE="$STICKY_NOTE STRICT_AUTH=yes"; }
    pick ALLOW_GROUPS "$ST_ALLOW_GROUPS" ""
    pick IDLE_TIMEOUT "$ST_IDLE_TIMEOUT" ""
    pick ALLOW_AGENT_FORWARDING "$ST_ALLOW_AGENT_FORWARDING" ""
    validate_params
    [ -n "$STICKY_NOTE" ] && info "значения из прошлого запуска:$STICKY_NOTE (явный флаг их переопределяет, --reset сбрасывает)"
    precheck_config
    detect_mode
    case "$ACTION" in
        check)    resolve_users; do_check; exit 0 ;;
        rollback) do_rollback; exit 0 ;;
    esac

    fetch_keys
    resolve_users
    plan_ports
    for u in $TARGET_USERS; do install_keys_for_user "$u"; done
    assert_login_possible

    build_main
    build_dropin
    plan_banner
    validate_candidate
    apply_config
    do_reload

    if [ "$DRY_RUN" = yes ]; then
        [ -f "$TMPDIR_/eff.cand" ] && verify_effective "$TMPDIR_/eff.cand" "$TMPDIR_/cand/sshd_config"
    else
        sshd_T "$SSHD_CONFIG" > "$TMPDIR_/eff.new" || true
        verify_effective "$TMPDIR_/eff.new" "$SSHD_CONFIG"
        write_state
    fi
    confirm_or_rollback
    summary
    [ "$MISMATCH" = 1 ] && exit 2
    [ "$RELOAD_FAILED" = 1 ] && exit 2
    exit 0
}
main "$@"
