#!/bin/sh
# Интеграционные тесты secure_ssh.sh. Нужны root, установленный openssh-server и ssh-keygen.
# Ничего не трогают в /etc/ssh: конфиги лежат во временном каталоге, sshd запускается
# на высоких портах с -f. Создаётся тестовый пользователь sst_user.
#
#   sudo tests/run.sh [шелл]      # шелл по умолчанию: sh; например: tests/run.sh dash, tests/run.sh "busybox sh"
#   AWK_IMPL="busybox awk" sudo tests/run.sh   # прогнать с другим awk
# shellcheck disable=SC2012,SC2016
set -u
SHELL_UNDER_TEST="${1:-sh}"
HERE=$(cd "$(dirname "$0")" && pwd); SCRIPT="$HERE/../secure_ssh.sh"
[ "$(id -u)" -eq 0 ] || { echo "нужен root"; exit 1; }
command -v sshd >/dev/null 2>&1 || SSHD=/usr/sbin/sshd; SSHD=${SSHD:-$(command -v sshd)}
T=$(mktemp -d); trap 'cleanup_all' EXIT
PASS=0; FAIL=0; CUR=""
SSHD_PIDS=""
cleanup_all() {
    for p in $SSHD_PIDS; do kill "$p" 2>/dev/null; done
    [ -n "${TMPFS:-}" ] && umount "$TMPFS" 2>/dev/null
    rm -rf "$T"
}
pass() { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL [$CUR] $1"; }
assert()     { if eval "$2" >/dev/null 2>&1; then pass; else fail "$1"; fi; }
assert_out() { if grep -q -- "$2" "$OUT"; then pass; else fail "$1 (ожидалось в выводе: $2)"; fi; }
assert_rc()  { if [ "$RC" = "$1" ]; then pass; else fail "код выхода $RC, ожидался $1"; sed 's/^/      | /' "$OUT"; fi; }
begin() { CUR="$1"; echo "* $1"; }
# Занять порт посторонним процессом (OpenBSD nc, ncat или busybox nc); pid в $T/nc.pid
listen_port() {
    if nc -h 2>&1 | grep -qi busybox; then nc -l -p "$1" -s 127.0.0.1 >/dev/null 2>&1 & else nc -l 127.0.0.1 "$1" >/dev/null 2>&1 & fi
    echo $! > "$T/nc.pid"; sleep 1
}
stop_listener() { kill "$(cat "$T/nc.pid" 2>/dev/null)" 2>/dev/null; rm -f "$T/nc.pid"; }
# Слушается ли TCP-порт (по /proc, без ss/nc)
port_open() {
    h=$(printf '%04X' "$1")
    for f in /proc/net/tcp /proc/net/tcp6; do
        [ -r "$f" ] && awk -v h=":$h" 'NR > 1 && $4 == "0A" { n = split($2, a, ":"); if (":" a[n] == h) ok = 1 } END { exit !ok }' "$f" && return 0
    done
    return 1
}

# --- окружение ---
if ! id sst_user >/dev/null 2>&1; then
    useradd -m -s /bin/sh sst_user 2>/dev/null || adduser -D -s /bin/sh sst_user
fi
H=$(getent passwd sst_user | cut -d: -f6)
ssh-keygen -q -t ed25519 -N '' -f "$T/k1" && ssh-keygen -q -t rsa -b 2048 -N '' -f "$T/k2"
cat "$T/k1.pub" "$T/k2.pub" > "$T/keys"
K1=$(awk '{print $2}' "$T/k1.pub"); K2=$(awk '{print $2}' "$T/k2.pub")
AK="$H/.ssh/authorized_keys"
BIN="$T/bin"; mkdir -p "$BIN"
if [ -n "${AWK_IMPL:-}" ]; then printf '#!/bin/sh\nexec %s "$@"\n' "$AWK_IMPL" > "$BIN/awk"; chmod +x "$BIN/awk"; fi
export PATH="$BIN:$PATH"

# Конфиги
cfg_ubuntu() {  # Include + Port 2222 + cloud-init drop-in с паролями
    mkdir -p "$1/sshd_config.d"
    printf 'Include %s/sshd_config.d/*.conf\nPort 2222\nKbdInteractiveAuthentication no\nUsePAM yes\nX11Forwarding yes\nPrintMotd no\nAcceptEnv LANG LC_*\nSubsystem sftp /usr/lib/openssh/sftp-server\n' "$1" > "$1/sshd_config"
    printf 'PasswordAuthentication yes\n' > "$1/sshd_config.d/50-cloud-init.conf"
}
cfg_legacy() {  # без Include, с Match и несколькими AcceptEnv (как на RHEL)
    mkdir -p "$1/sshd_config.d"
    printf 'Port 2222\nPasswordAuthentication yes\nAcceptEnv LANG LC_CTYPE LC_NUMERIC\nAcceptEnv XMODIFIERS\nSubsystem sftp internal-sftp\nMatch User sftponly\n    ChrootDirectory /srv\n    PasswordAuthentication yes\n' > "$1/sshd_config"
}
reset_user() { rm -rf "$H/.ssh"; }
run() {  # run КАТАЛОГ [аргументы] -> OUT, RC
    d="$1"; shift
    OUT="$d/out.txt"
    SSHD_CONFIG="$d/sshd_config" BANNER_FILE="$d/issue.net" STATE_FILE="$d/state" KEYS_FILE="$T/keys" \
    TARGET_USERS="${USERS_OVERRIDE:-sst_user}" YES=yes $SHELL_UNDER_TEST "$SCRIPT" "$@" > "$OUT" 2>&1
    RC=$?
}
eff() { "$SSHD" -T -f "$1/sshd_config" 2>/dev/null | awk -v k="$2" '$1 == k { $1 = ""; sub(/^ /, ""); print }'; }
new_case() { d="$T/$1"; rm -rf "$d"; mkdir -p "$d"; reset_user; printf '%s' "$d"; }

# --- 1. базовый drop-in ---
begin "drop-in: базовый запуск"
D=$(new_case c1); cfg_ubuntu "$D"; run "$D" --no-reload
assert_rc 0
assert "drop-in создан" "[ -f '$D/sshd_config.d/00-secure-ssh.conf' ]"
assert "PasswordAuthentication no эффективно" "[ \"\$(eff '$D' passwordauthentication)\" = no ]"
assert "порт не тронут" "[ \"\$(eff '$D' port)\" = 2222 ]"
assert "AcceptEnv закомментирован" "[ -z \"\$(eff '$D' acceptenv)\" ]"
assert "ключи установлены" "grep -q \"^ssh-ed25519 $K1 \" '$AK' && grep -q \"^ssh-rsa $K2 \" '$AK'"
assert "права authorized_keys 600" "[ \"\$(stat -c %a '$AK')\" = 600 ] && [ \"\$(stat -c %U '$AK')\" = sst_user ]"
assert "бэкапы main" "[ -f '$D/sshd_config.orig' ] && ls '$D'/sshd_config.bak.* >/dev/null"
assert "state записан" "grep -q '^ALLOW_TCP_FORWARDING=yes' '$D/state'"
assert "баннер записан" "grep -q Administrator '$D/issue.net'"
assert_out "итог: записано без перезагрузки" "Результат:.*не перезагружался"

begin "drop-in: идемпотентность"
n_before=$(ls "$D"/sshd_config.bak.* | wc -l); run "$D" --no-reload
assert_rc 0
assert "новых бэкапов нет" "[ \"\$(ls '$D'/sshd_config.bak.* | wc -l)\" = \"$n_before\" ]"
assert_out "ключи уже есть" "все 2 ключ"
assert_out "drop-in актуален" "уже актуален"

# --- 2. порты ---
begin "drop-in: смена порта с сохранением старого"
run "$D" --no-reload --port 2345
assert_rc 0
assert "оба порта эффективны" "eff '$D' port | sort | tr '\n' ' ' | grep -q '^2222 2345 \$'"
assert "Port в main закомментирован" "! grep -qE '^Port' '$D/sshd_config'"
assert_out "предупреждение про старый порт" "старый порт остаётся"
begin "drop-in: порт сохраняется при повторном запуске без --port"
run "$D" --no-reload
assert_rc 0
assert "порты сохранены" "eff '$D' port | sort | tr '\n' ' ' | grep -q '^2222 2345 \$'"
assert_out "упоминание значений из прошлого" "из прошлого запуска"
begin "drop-in: --close-old-port"
run "$D" --no-reload --port 2345 --close-old-port
assert_rc 0
assert "остался только новый порт" "[ \"\$(eff '$D' port)\" = 2345 ]"
begin "порт занят -> отказ без изменений"
listen_port 24789
n_before=$(ls "$D"/sshd_config.bak.* | wc -l); run "$D" --no-reload --port 24789
assert_rc 1; assert_out "сообщение о занятом порте" "уже занят"
assert "бэкапов не добавилось" "[ \"\$(ls '$D'/sshd_config.bak.* | wc -l)\" = \"$n_before\" ]"
stop_listener

# --- 3. липкие настройки ---
begin "липкие параметры: --tcp-forwarding no сохраняется, --reset сбрасывает"
D=$(new_case c3); cfg_ubuntu "$D"; run "$D" --no-reload --tcp-forwarding No
assert_rc 0; assert "tcp no" "[ \"\$(eff '$D' allowtcpforwarding)\" = no ]"
run "$D" --no-reload; assert_rc 0; assert "tcp всё ещё no" "[ \"\$(eff '$D' allowtcpforwarding)\" = no ]"
run "$D" --no-reload --reset; assert_rc 0; assert "после --reset yes" "[ \"\$(eff '$D' allowtcpforwarding)\" = yes ]"
begin "форма --флаг=значение"
run "$D" --no-reload --x11=yes --max-auth-tries=4; assert_rc 0
assert "x11 yes" "[ \"\$(eff '$D' x11forwarding)\" = yes ]"; assert "maxauthtries 4" "[ \"\$(eff '$D' maxauthtries)\" = 4 ]"

# --- 4. legacy ---
begin "legacy: директивы до Match, AcceptEnv (несколько строк) отключён"
D=$(new_case c4); cfg_legacy "$D"; run "$D" --no-reload --mode legacy --port 2200
assert_rc 0
assert "PasswordAuthentication no" "[ \"\$(eff '$D' passwordauthentication)\" = no ]"
assert "оба порта" "eff '$D' port | sort | tr '\n' ' ' | grep -q '^2200 2222 \$'"
assert "все AcceptEnv выключены" "[ -z \"\$(eff '$D' acceptenv)\" ]"
assert "Match сохранён последним" "awk 'tolower(\$1)==\"match\"{m=NR} tolower(\$1)==\"passwordauthentication\"&&!m{p=NR} END{exit !(p && m && p<m)}' '$D/sshd_config'"
assert "ChrootDirectory внутри Match цел" "grep -q 'ChrootDirectory /srv' '$D/sshd_config'"
run "$D" --no-reload --mode legacy; assert_rc 0; assert_out "legacy идемпотентен" "без изменений"
begin "legacy при наличии Include: директивы выше Include"
D=$(new_case c4b); cfg_ubuntu "$D"; run "$D" --no-reload --mode legacy
assert_rc 0
assert "drop-in cloud-init перекрыт" "[ \"\$(eff '$D' passwordauthentication)\" = no ]"
assert "PasswordAuthentication стоит выше Include" "awk 'tolower(\$1)==\"include\"{i=NR} tolower(\$1)==\"passwordauthentication\"&&!p{p=NR} END{exit !(p && i && p<i)}' '$D/sshd_config'"

# --- 5. защита от lockout ---
begin "lockout: PermitRootLogin no + только root -> отказ"
D=$(new_case c5); cfg_ubuntu "$D"; USERS_OVERRIDE=root run "$D" --no-reload --permit-root-login no
assert_rc 1; assert "ничего не записано" "[ ! -f '$D/sshd_config.d/00-secure-ssh.conf' ] && [ ! -f '$D/sshd_config.orig' ]"
USERS_OVERRIDE=root run "$D" --no-reload --permit-root-login no --force; assert_rc 0
rm -f /root/.ssh/authorized_keys.secure_ssh.tmp
begin "lockout: пустой список пользователей"
D=$(new_case c5b); cfg_ubuntu "$D"; USERS_OVERRIDE=", " run "$D" --no-reload
assert_rc 1; assert_out "сообщение" "список пользователей пуст"

# --- 6. ключи ---
begin "ключ закомментирован / с command= считается отсутствующим"
D=$(new_case c6); cfg_ubuntu "$D"; mkdir -p "$H/.ssh"; chmod 700 "$H/.ssh"
printf '#ssh-ed25519 %s old\ncommand="echo no",no-pty ssh-rsa %s cloud\n' "$K1" "$K2" > "$AK"; chmod 600 "$AK"; chown -R sst_user "$H/.ssh"
run "$D" --no-reload
assert_rc 0; assert_out "предупреждение про ограниченный ключ" "закомментирован или с ограничениями"
assert "активные строки добавлены" "grep -q \"^ssh-ed25519 $K1 \" '$AK' && grep -q \"^ssh-rsa $K2 \" '$AK'"
assert "старые строки не тронуты" "grep -q '^#ssh-ed25519' '$AK' && grep -q '^command=' '$AK'"
begin "--prune удаляет устаревшие ключи с меткой"
printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGQxv4ArgvxvUJ1SxV0bYrW6fYt0d9x4oH3j4fQ8t2Zs github:whereisasan\n' >> "$AK"
run "$D" --no-reload --prune; assert_rc 0
assert "устаревший удалён" "! grep -q AAAAIGQxv4ArgvxvUJ1SxV0bYrW6fYt0d9x4oH3j4fQ8t2Zs '$AK'"
assert "нужные остались" "grep -q \"^ssh-ed25519 $K1 \" '$AK'"
begin "нестандартный AuthorizedKeysFile"
D=$(new_case c6b); cfg_ubuntu "$D"; printf 'AuthorizedKeysFile %s/ak/%%u\n' "$D" >> "$D/sshd_config"
run "$D" --no-reload; assert_rc 0
assert "ключ в $D/ak/sst_user" "grep -q \"$K1\" '$D/ak/sst_user'"
assert "в ~/.ssh ничего не создано" "[ ! -e '$AK' ]"
begin "AuthorizedKeysFile none -> отказ"
D=$(new_case c6c); cfg_ubuntu "$D"; printf 'AuthorizedKeysFile none\n' >> "$D/sshd_config"
run "$D" --no-reload; assert_rc 1; assert_out "сообщение" "AuthorizedKeysFile none"
begin "симлинк в ~/.ssh -> отказ"
D=$(new_case c6d); cfg_ubuntu "$D"; printf 'victim\n' > "$D/victim"; chmod 644 "$D/victim"
mkdir -p "$H/.ssh"; ln -s "$D/victim" "$AK"; chown -h sst_user "$H/.ssh" "$AK"
run "$D" --no-reload; assert_rc 1
assert "жертва не изменена" "[ \"\$(cat '$D/victim')\" = victim ] && [ \"\$(stat -c %U '$D/victim')\" = root ]"
begin "мусор вместо ключей -> отказ без изменений"
D=$(new_case c6e); cfg_ubuntu "$D"; printf 'Not Found\n' > "$T/bad.keys"
SSHD_CONFIG="$D/sshd_config" BANNER_FILE="$D/issue.net" STATE_FILE="$D/state" KEYS_FILE="$T/bad.keys" TARGET_USERS=sst_user $SHELL_UNDER_TEST "$SCRIPT" --no-reload > "$D/out.txt" 2>&1; RC=$?; OUT="$D/out.txt"
assert_rc 1; assert "ничего не записано" "[ ! -f '$D/sshd_config.orig' ]"

# --- 7. сбои записи ---
begin "будущая конфигурация не проходит sshd -t -> ничего не записано"
D=$(new_case c7); cfg_ubuntu "$D"; cp "$D/sshd_config" "$T/pristine"
printf '#!/bin/sh\nif [ "$1" = -t ] && grep -q PermitEmptyPasswords "$3" 2>/dev/null; then echo "fake: bad option" >&2; exit 255; fi\nexec %s "$@"\n' "$SSHD" > "$BIN/sshd-fail"; chmod +x "$BIN/sshd-fail"
SSHD_BIN="$BIN/sshd-fail" run "$D" --no-reload --mode legacy
assert_rc 1; assert_out "ошибка валидации" "не проходит sshd -t"
assert "main не тронут" "[ ! -f '$D/sshd_config.orig' ] && cmp -s '$D/sshd_config' '$T/pristine' && [ ! -f '$D/sshd_config.d/00-secure-ssh.conf' ]"
begin "нет места на диске -> отказ, конфиг цел"
TMPFS="$T/tmpfs"; mkdir -p "$TMPFS"
if mount -t tmpfs -o size=24k tmpfs "$TMPFS" 2>/dev/null; then
    reset_user; cfg_legacy "$TMPFS"; cp "$TMPFS/sshd_config" "$T/pristine"
    dd if=/dev/zero of="$TMPFS/filler" bs=1k count=20 2>/dev/null; dd if=/dev/zero of="$TMPFS/filler2" bs=1 count=4000 2>/dev/null
    run "$TMPFS" --no-reload --mode legacy
    assert_rc 1; assert "конфиг не изменён" "cmp -s '$TMPFS/sshd_config' '$T/pristine'"
    assert "нет пустых бэкапов" "! find '$TMPFS' -name 'sshd_config.*' -size 0 | grep -q ."
    umount "$TMPFS"; TMPFS=""
else
    echo "  (tmpfs недоступен, пропуск)"; TMPFS=""
fi

# --- 8. dry-run, check, rollback, confirm ---
begin "dry-run ничего не пишет"
D=$(new_case c8); cfg_ubuntu "$D"; run "$D" --dry-run --port 2400
assert_rc 0; assert_out "diff показан" "+Port 2400"; assert_out "будущая конфигурация проверена" "будущая конфигурация корректна"
assert "файлы не созданы" "[ ! -f '$D/sshd_config.d/00-secure-ssh.conf' ] && [ ! -f '$D/sshd_config.orig' ] && [ ! -e '$AK' ] && [ ! -f '$D/state' ]"
begin "--check"
run "$D" --check; assert_rc 0; assert_out "эффективные значения" "Эффективные значения"; assert_out "предупреждение о паролях" "PasswordAuthentication yes"
begin "--rollback"
run "$D" --no-reload; assert_rc 0
printf 'PasswordAuthentication yes\n' >> "$D/sshd_config.orig"   # отличие, чтобы увидеть восстановление
run "$D" --rollback --no-reload; assert_rc 0
assert "main восстановлен из .orig" "cmp -s '$D/sshd_config' '$D/sshd_config.orig'"
assert "drop-in удалён" "[ ! -f '$D/sshd_config.d/00-secure-ssh.conf' ]"
assert "state удалён" "[ ! -f '$D/state' ]"
begin "--confirm без подтверждения -> откат, код 3"
D=$(new_case c8b); cfg_ubuntu "$D"; cp "$D/sshd_config" "$T/pristine"
run "$D" --no-reload --confirm 2 < /dev/null
assert_rc 3; assert "main восстановлен" "cmp -s '$D/sshd_config' '$T/pristine'"
assert "drop-in удалён" "[ ! -f '$D/sshd_config.d/00-secure-ssh.conf' ]"
begin "--confirm с подтверждением файлом"
D=$(new_case c8c); cfg_ubuntu "$D"
( sleep 2; touch "$D/confirmed" ) &
CONFIRM_FILE="$D/confirmed" run "$D" --no-reload --confirm 10 < /dev/null
assert_rc 0; assert_out "подтверждено" "подтверждено"
wait

# --- 9. CRLF и privsep ---
begin "CRLF-конфиг распознаётся"
D=$(new_case c9); cfg_ubuntu "$D"; sed -i 's/$/\r/' "$D/sshd_config"; run "$D" --no-reload
assert_rc 0; assert_out "режим dropin" "режим записи настроек: dropin"; assert "пароли выключены" "[ \"\$(eff '$D' passwordauthentication)\" = no ]"

# --- 10. реальный sshd: SIGHUP, проверка живости, откат при мёртвом порте ---
begin "реальный sshd: смена порта через SIGHUP"
D=$(new_case c10); cfg_ubuntu "$D"; P1=24601; P2=24602
sed -i "s/^Port 2222/Port $P1/" "$D/sshd_config"; printf 'PidFile %s/sshd.pid\n' "$D" >> "$D/sshd_config"
mkdir -p /run/sshd; "$SSHD" -f "$D/sshd_config" -E "$D/sshd.log" && sleep 1
SSHD_PIDS="$SSHD_PIDS $(cat "$D/sshd.pid" 2>/dev/null)"
run "$D" --port $P2 --reload-method sighup
assert_rc 0; assert_out "SIGHUP отправлен" "получил SIGHUP"; assert_out "порты слушаются" "sshd слушает порты"
assert "новый порт открыт" "port_open $P2"; assert "старый порт открыт" "port_open $P1"
begin "реальный sshd: вход по ключу работает, по паролю нет"
chmod 600 "$T/k1"
assert "вход по ключу" "ssh -i '$T/k1' -p $P2 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes sst_user@127.0.0.1 true"
assert "пароль отключён" "ssh -p $P2 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o PubkeyAuthentication=no sst_user@127.0.0.1 true 2>&1 | grep -q 'Permission denied (publickey)'"
begin "реальный sshd: порт исчез после reload -> откат и перезапуск"
# Порт P3 держит nc, но подменный ss его скрывает: pre-flight считает порт свободным, sshd после SIGHUP
# не может его занять и умирает, пост-проверка видит, что P3 не слушается, и должна откатить и перезапустить sshd.
P3=24603; listen_port $P3
{
    printf '#!/bin/sh\n# подменный ss: реальные слушатели из /proc, кроме порта %s\n' "$P3"
    cat <<'STUB'
for f in /proc/net/tcp /proc/net/tcp6; do
    [ -r "$f" ] || continue
    tail -n +2 "$f" | while read -r _ local _ st _; do
        [ "$st" = 0A ] || continue
        p=$(printf '%d' "0x${local##*:}")
        [ "$p" = "$HIDE" ] || printf 'LISTEN 0 128 0.0.0.0:%s 0.0.0.0:*\n' "$p"
    done
done
STUB
} > "$BIN/ss"; sed -i "s/\$HIDE/$P3/" "$BIN/ss"
chmod +x "$BIN/ss"
run "$D" --port $P3 --close-old-port --reload-method sighup
rm -f "$BIN/ss"; stop_listener
assert_rc 1; assert_out "откат" "откат выполнен"
sleep 1
assert "sshd снова слушает старые порты" "port_open $P2 && port_open $P1"
assert "конфиг откачен (порт $P3 отсутствует)" "! eff '$D' port | grep -q $P3"
kill "$(cat "$D/sshd.pid" 2>/dev/null)" 2>/dev/null

echo
echo "Итого: пройдено $PASS, провалено $FAIL (шелл: $SHELL_UNDER_TEST, awk: ${AWK_IMPL:-системный})"
[ "$FAIL" -eq 0 ]
