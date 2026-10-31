# server-ssh-tools

`secure_ssh.sh` — идемпотентный скрипт настройки **OpenSSH-сервера**:

- загружает публичные ключи администратора с GitHub (`https://github.com/<user>.keys`), проверяет их и кладёт в `authorized_keys` нужных пользователей;
- применяет безопасные параметры sshd: вход только по ключам, root только по ключу, лимиты на попытки входа, keepalive, баннер;
- пишет настройки туда, где они **реально действуют**: в `/etc/ssh/sshd_config.d/00-secure-ssh.conf` (OpenSSH 8.2+, приоритет над `50-cloud-init.conf` и `50-redhat.conf`) или, на старых системах, в `sshd_config` **перед первым блоком `Match`**;
- проверяет конфиг (`sshd -t`) и **откатывает изменения при ошибке**, перезагружает sshd только при реальных изменениях;
- в конце показывает **эффективные значения** (`sshd -T`) и предупреждает, если что-то перекрыто другим файлом.

Скрипт написан на POSIX `sh` и работает в `bash`, `dash` и `busybox ash`:
Debian, Ubuntu (включая 24.04 с socket-активацией), Alpine (OpenRC), CentOS 7 / RHEL-семейство, Ubuntu 18.04/20.04.

---

## ⚠️ Перед запуском

1. Скрипт **отключает вход по паролю**. Убедитесь, что в вашем GitHub-аккаунте лежит актуальный публичный ключ, а приватный есть у вас под рукой.
2. Если ключи с GitHub не скачались или ни один не прошёл проверку, скрипт **ничего не меняет** и завершается с ошибкой.
3. Порт SSH **не меняется**, пока вы не укажете его явно (`--port`).
4. После запуска **не закрывайте текущую сессию**: откройте новое окно и проверьте вход по ключу.

---

## ⚙️ Запуск

### Одной командой
```bash
curl -fsSL https://raw.githubusercontent.com/whereisasan/server-ssh-tools/main/secure_ssh.sh | sudo sh
```
Параметры через переменные окружения или флаги:
```bash
curl -fsSL https://raw.githubusercontent.com/whereisasan/server-ssh-tools/main/secure_ssh.sh | sudo TARGET_USERS=root,deploy sh
curl -fsSL https://raw.githubusercontent.com/whereisasan/server-ssh-tools/main/secure_ssh.sh | sudo sh -s -- --users root,deploy --port 2222
```

### Из клона репозитория
```bash
git clone https://github.com/whereisasan/server-ssh-tools.git
cd server-ssh-tools
sudo ./secure_ssh.sh --dry-run      # сначала посмотреть, что изменится
sudo ./secure_ssh.sh
```

---

## 🔧 Параметры

| Флаг | Переменная | По умолчанию | Описание |
|---|---|---|---|
| `-u, --github-user` | `GITHUB_USER` | `whereisasan` | Пользователь GitHub, чьи ключи ставим |
| `--users` | `TARGET_USERS` | `root` + `SUDO_USER` | Кому класть ключи, через запятую |
| `-p, --port` | `SSH_PORT` | не менять | Порт sshd |
| `--permit-root-login` | `PERMIT_ROOT_LOGIN` | `prohibit-password` | `yes` / `no` / `prohibit-password` |
| `--tcp-forwarding` | `ALLOW_TCP_FORWARDING` | `yes` | Туннели `ssh -L/-R`, VS Code Remote SSH |
| `--x11` | `X11_FORWARDING` | `no` | X11 forwarding |
| `--max-auth-tries` | `MAX_AUTH_TRIES` | `6` | Попыток аутентификации (каждый ключ в ssh-agent = попытка) |
| | `LOGIN_GRACE_TIME` | `30` | Секунд на вход |
| | `CLIENT_ALIVE_INTERVAL` / `CLIENT_ALIVE_COUNT_MAX` | `300` / `2` | Keepalive |
| | `LOG_LEVEL` | `INFO` | LogLevel sshd |
| `--keep-accept-env` | `DISABLE_ACCEPT_ENV=no` | комментировать | Не трогать `AcceptEnv LANG LC_*` |
| `--no-banner` | `BANNER=no` | ставить | Не писать баннер |
| `--banner-admin` | `BANNER_ADMIN` | `@whereisasan` | Подпись в баннере |
| | `BANNER_FILE` | `/etc/issue.net` | Файл баннера |
| `--mode` | `CONFIG_MODE` | `auto` | `dropin` / `legacy` / `auto` (по версии OpenSSH) |
| `-n, --dry-run` | `DRY_RUN=yes` | | Показать изменения, ничего не писать |
| `--no-reload` | `NO_RELOAD=yes` | | Не перезагружать sshd |
| `-h, --help` | | | Справка |

Когда скрипт запущен через `sudo`, ключи по умолчанию получают и `root`, и пользователь, из-под которого вызван `sudo`.

---

## 🛡️ Что именно настраивается

```
PermitRootLogin prohibit-password
PasswordAuthentication no
PermitEmptyPasswords no
PubkeyAuthentication yes
KbdInteractiveAuthentication no      # + ChallengeResponseAuthentication no на OpenSSH < 8.7
LoginGraceTime 30
MaxAuthTries 6
ClientAliveInterval 300
ClientAliveCountMax 2
X11Forwarding no
AllowTcpForwarding yes
LogLevel INFO
Banner /etc/issue.net
```
Дополнительно в `sshd_config` комментируется `AcceptEnv LANG LC_*` (чтобы локаль клиента не ломала сессию на сервере без нужных локалей). Отключается флагом `--keep-accept-env`.

---

## 🔁 Безопасность и откат

- Перед первым изменением сохраняется `sshd_config.orig`, перед каждым изменением — `sshd_config.bak.<дата-время>`.
- После записи выполняется `sshd -t`. Если конфиг невалиден, файлы восстанавливаются из бэкапа, sshd не перезапускается, код выхода `1`.
- Перезагрузка выполняется через `systemctl reload` (`ssh.service` или `sshd.service`), OpenRC (`rc-service sshd reload`), `service` или `SIGHUP` по pid-файлу. На Ubuntu 24.04 при смене порта дополнительно перезапускается `ssh.socket`.
- Код выхода `2`: настройки записаны, но `sshd -T` показывает, что часть значений перекрыта другим файлом (например, `Include` стоит не первой строкой). В выводе будет указано, какая директива и где её искать.

Ручной откат:
```bash
sudo rm /etc/ssh/sshd_config.d/00-secure-ssh.conf          # режим dropin
sudo cp /etc/ssh/sshd_config.orig /etc/ssh/sshd_config      # или любой .bak.*
sudo sshd -t && sudo systemctl reload ssh || sudo systemctl reload sshd
```

---

## 🧪 Проверка

```bash
sudo ./secure_ssh.sh --dry-run            # что изменится
sudo sshd -T | grep -iE 'passwordauthentication|permitrootlogin|port'
```
