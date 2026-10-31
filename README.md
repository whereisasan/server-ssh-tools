# server-ssh-tools

`secure_ssh.sh` — один POSIX-скрипт, который безопасно и повторяемо настраивает OpenSSH-сервер:

- скачивает публичные ключи администратора с GitHub (`https://github.com/<user>.keys`), проверяет каждый
  (`ssh-keygen -lf`) и кладёт их в `authorized_keys` нужных пользователей — туда, куда реально смотрит sshd
  (`AuthorizedKeysFile`), без дублей и с правильными правами;
- отключает вход по паролю и применяет безопасные параметры sshd через drop-in
  `/etc/ssh/sshd_config.d/00-secure-ssh.conf` (OpenSSH ≥ 8.2) или правкой `sshd_config` на старых системах;
- проверяет будущую конфигурацию (`sshd -t`) **до** записи, пишет файлы атомарно с бэкапами, откатывает при
  любой ошибке, перезагружает sshd только при реальных изменениях и убеждается, что он жив и слушает порты;
- показывает эффективные значения (`sshd -T`), в том числе для каждого пользователя с учётом блоков `Match`;
- умеет `--dry-run`, `--check`, `--rollback` и таймер автоотката `--confirm`.

Работает в `bash`, `dash` и `busybox ash`: Debian, Ubuntu (включая 24.04 с `ssh.socket`), Alpine (OpenRC),
CentOS 7 / RHEL-семейство (включая SELinux), а также любой Linux с systemd, OpenRC, SysV `service` или просто
pid-файлом sshd.

> **Важно.** По умолчанию скрипт ставит ключи пользователя GitHub **`whereisasan`**. Если это не вы, всегда
> указывайте своего: `-u <ваш_github>` или `GITHUB_USER=<ваш_github>`. Иначе доступ к серверу получит автор
> скрипта, а пароли будут отключены.

## Требования

- root (запуск через `sudo` или `doas`);
- установленный `openssh-server` (`sshd` ищется в `PATH`, `/usr/sbin`, `/usr/local/sbin`, `/sbin`);
- `curl` или `wget` для загрузки ключей (не нужны с `--keys-file`); `ssh-keygen` желателен для проверки ключей;
- пользователи из `--users` должны существовать и иметь домашний каталог;
- доступ к `github.com` с сервера (нужен и в `--dry-run`). Если ключи получить или проверить не удалось,
  скрипт завершается **без каких-либо изменений**.

## Быстрый старт

```sh
# 1. Посмотреть, что изменится (ничего не записывается, но будущая конфигурация проверяется sshd -t)
curl -fsSL https://raw.githubusercontent.com/whereisasan/server-ssh-tools/main/secure_ssh.sh | sudo sh -s -- -u <github> --dry-run

# 2. Применить с таймером автоотката: если за 120 с вы не подтвердите вход из НОВОГО окна, всё откатится
curl -fsSL https://raw.githubusercontent.com/whereisasan/server-ssh-tools/main/secure_ssh.sh | sudo sh -s -- -u <github> --confirm 120

# 3. В новом окне: ssh <пользователь>@<сервер>, затем  sudo touch /run/secure_ssh.confirmed
```

Параметры можно передавать флагами (`sh -s -- флаги`) или переменными окружения. Переменные при `curl | sudo sh`
передавайте через `sudo env`, иначе `sudo` их отбросит:

```sh
curl -fsSL .../secure_ssh.sh | sudo env GITHUB_USER=<github> TARGET_USERS=root,deploy sh
curl -fsSL .../secure_ssh.sh | sudo sh -s -- --users root,deploy --port 2222 --open-firewall
```

Из клона репозитория:

```sh
git clone https://github.com/whereisasan/server-ssh-tools.git && cd server-ssh-tools
sudo ./secure_ssh.sh -u <github> --dry-run
sudo ./secure_ssh.sh -u <github> --confirm 120
```

Для важных серверов закрепляйте конкретный коммит вместо ветки:
`https://raw.githubusercontent.com/whereisasan/server-ssh-tools/<commit>/secure_ssh.sh`.
Версию можно проверить флагом `--version`.

## Параметры

| Флаг | Переменная | По умолчанию | Назначение |
|---|---|---|---|
| `-u`, `--github-user USER` | `GITHUB_USER` | `whereisasan` | чьи ключи ставить |
| `--keys-url URL` | `KEYS_URL` | `https://github.com/USER.keys` | другой источник ключей |
| `--keys-file ФАЙЛ` | `KEYS_FILE` | | локальный файл с ключами (офлайн) |
| `--users U1,U2` | `TARGET_USERS` | `root` + `SUDO_USER`/`DOAS_USER` | кому класть ключи |
| `--prune` | `PRUNE_KEYS=yes` | нет | удалить ключи с меткой `github:USER`, которых больше нет на GitHub |
| `--unrestrict` | `UNRESTRICT_KEYS=yes` | нет | если ключ уже есть с `from=`/`command=`, добавить строку без ограничений |
| `-p`, `--port N` | `SSH_PORT` | не менять | порт sshd (см. «Смена порта») |
| `--close-old-port` | `KEEP_OLD_PORT=no` | старый порт остаётся | убрать старый порт после проверки входа |
| `--open-firewall` | `OPEN_FIREWALL=yes` | нет | открыть новый порт в `ufw`/`firewalld` |
| `--permit-root-login V` | `PERMIT_ROOT_LOGIN` | `prohibit-password` | `yes` / `no` / `prohibit-password` |
| `--tcp-forwarding V` | `ALLOW_TCP_FORWARDING` | `yes` | туннели, VS Code Remote |
| `--x11 V` | `X11_FORWARDING` | `no` | |
| `--max-auth-tries N` | `MAX_AUTH_TRIES` | `6` | см. FAQ про ssh-agent |
| `--log-level V` | `LOG_LEVEL` | не трогать | `LogLevel` |
| `--keep-accept-env` | `DISABLE_ACCEPT_ENV=no` | комментировать | не трогать `AcceptEnv` |
| `--no-banner` | `BANNER=no` | баннер ставится | |
| `--banner-admin TEXT` | `BANNER_ADMIN` | `@whereisasan` | подпись в баннере |
| `--mode auto\|dropin\|legacy` | `CONFIG_MODE` | `auto` | куда писать настройки |
| `--reset` | `RESET_STATE=yes` | | не брать значения прошлого запуска |
| `--confirm N` | `CONFIRM_TIMEOUT` | `0` | ждать подтверждения N секунд, иначе откат |
| `--no-reload` | `NO_RELOAD=yes` | | не перезагружать sshd |
| `--reload-method M` | `RELOAD_METHOD` | `auto` | `systemd` / `openrc` / `service` / `sighup` |
| `--force` | `FORCE=yes` | | отключить защиту от потери доступа |
| `-y`, `--yes` | `YES=yes` | | не задавать вопросов |
| `-q`, `--quiet` | `QUIET=yes` | | только изменения, предупреждения и итог |
| `-n`, `--dry-run` | `DRY_RUN=yes` | | показать и проверить, ничего не менять |
| `--check` | | | только отчёт о текущем состоянии |
| `--rollback [ФАЙЛ]` | | | откат к `sshd_config.orig` (или ФАЙЛУ) |

Только переменные: `SSHD_CONFIG` (`/etc/ssh/sshd_config`), `DROPIN_NAME` (`00-secure-ssh.conf`), `SSHD_BIN`,
`STATE_FILE` (`/etc/ssh/.secure_ssh.state`), `CONFIRM_FILE` (`/run/secure_ssh.confirmed`), `BANNER_FILE`
(`/etc/issue.net`), `LOGIN_GRACE_TIME` (30), `CLIENT_ALIVE_INTERVAL` (300), `CLIENT_ALIVE_COUNT_MAX` (2), `NO_COLOR`.

Флаги принимают форму `--флаг значение` и `--флаг=значение`; `yes`/`no` можно писать в любом регистре.

**Значения запоминаются.** Параметры sshd, применённые в прошлый раз (порты, `PermitRootLogin`,
`AllowTcpForwarding`, `X11Forwarding`, `MaxAuthTries` и т.д.), сохраняются в `STATE_FILE` и действуют при
следующих запусках без флагов. Повторный запуск «просто доложить ключи» не вернёт порт или туннели к значениям
по умолчанию. Явный флаг переопределяет сохранённое значение, `--reset` сбрасывает всё к значениям по умолчанию.

## Что именно меняется в sshd

Управляемые директивы: `Port` (только если задан), `PermitRootLogin`, `PasswordAuthentication no`,
`PermitEmptyPasswords no`, `PubkeyAuthentication yes`, `KbdInteractiveAuthentication no`
(+ `ChallengeResponseAuthentication no` для OpenSSH < 8.7), `LoginGraceTime`, `MaxAuthTries`,
`ClientAliveInterval`, `ClientAliveCountMax`, `X11Forwarding`, `AllowTcpForwarding`, `LogLevel` (только если
задан), `Banner`. Все глобальные строки `AcceptEnv` комментируются (директива накопительная, иначе её не
отключить), кроме `--keep-accept-env`.

Режимы записи:

- **dropin** (OpenSSH ≥ 8.2, по умолчанию): директивы пишутся в `sshd_config.d/00-secure-ssh.conf`. Файл с
  префиксом `00-` побеждает `50-cloud-init.conf` и `50-redhat.conf`, потому что sshd берёт **первое** значение.
  Если в `sshd_config` нет строки `Include`, она добавляется первой строкой. При смене порта глобальные строки
  `Port` в `sshd_config` комментируются, иначе sshd слушал бы и старый, и новый порт.
- **legacy** (OpenSSH < 8.2 или `--mode legacy`): директивы правятся в самом `sshd_config` в глобальной секции —
  до первого `Match`, а при наличии `Include` ещё и выше него, чтобы иметь приоритет над drop-in'ами. Строки
  внутри блоков `Match` не трогаются.

Если версию sshd определить не удалось, но конфиг уже содержит `Include` и проходит `sshd -t`, выбирается dropin.

Ключи добавляются в первый файл из эффективного `AuthorizedKeysFile` (с подстановкой `%h`, `%u`, `%U`), с
меткой `github:<user>`. Закомментированный ключ не считается установленным — добавляется активная строка. Ключ,
который уже есть **с ограничениями** (`from=`, `command=`, `restrict`, как у cloud-init для root), по умолчанию
не трогается: ограничения снимаются только по `--unrestrict`. Новый файл собирается через `mktemp` в каталоге
назначения и атомарно переименовывается; символические ссылки на месте `~/.ssh` или `authorized_keys` — отказ.
Для каждого пользователя проверяется, что sshd вообще пустит его (`AllowUsers`/`AllowGroups`/`DenyUsers`/
`DenyGroups`) и что тип ключа входит в `PubkeyAcceptedAlgorithms`.

## Смена порта

`--port N` — самый рискованный шаг, поэтому:

- перед записью проверяется, что порт свободен и что в конфигурации нет `ListenAddress` с явным портом
  (на него `Port` не действует);
- на SELinux в режиме Enforcing порт добавляется в `ssh_port_t` через `semanage` (без `semanage` — отказ,
  установите `policycoreutils-python-utils`);
- при активном `ufw`/`firewalld` печатаются готовые команды, с `--open-firewall` они выполняются; про security
  group облака скрипт напоминает всегда — это сделать за вас он не может;
- **старый порт остаётся открытым**, пока вы не проверите вход по новому и не запустите
  `--port N --close-old-port`;
- после перезагрузки проверяется, что sshd действительно слушает нужные порты (включая порты из
  `ListenAddress host:port`); если нет — конфигурация откатывается и sshd перезапускается со старой;
- если менеджер служб отказал (например, OpenRC в контейнере или sshd запущен не через systemd), пробуются
  следующие способы вплоть до SIGHUP по pid-файлу.

На Ubuntu 24.04 порт слушает `ssh.socket`, поэтому при смене порта он перегенерируется и перезапускается.

## Защита от потери доступа

Скрипт отказывается продолжать (без `--force`), если после его работы на сервер нельзя будет войти:

- список `--users` пуст, пользователь не найден или без домашнего каталога;
- `--permit-root-login no`, а ключи ставятся только root (типично при запуске через `su -`, с консоли или из
  cloud-init, где `SUDO_USER` пуст);
- эффективный `AuthorizedKeysFile none`;
- после установки ключей ни один из пользователей не сможет войти: запрещён `AllowUsers`/`AllowGroups`,
  тип ключа не принимается sshd, ключи есть только с ограничениями `from=`/`command=`;
- ключи не скачались или ни один не прошёл проверку;
- исходный `sshd_config` уже не проходит `sshd -t` (кроме чинимых проблем окружения: отсутствующий
  `/run/sshd` создаётся, отсутствующие host-ключи генерируются `ssh-keygen -A`).

Порядок применения: будущая конфигурация собирается во временной копии и проверяется `sshd -t` → только затем
файлы пишутся атомарно (`tmp` + `mv`) с бэкапами → `sshd -t` ещё раз → перезагрузка → проверка портов →
`sshd -T`. Любая ошибка на любом шаге восстанавливает все файлы из бэкапов; если sshd уже был перезагружен,
он перезапускается со старой конфигурацией.

Бэкапы: `sshd_config.orig` (один раз, при первом изменении), `sshd_config.bak.<дата>` (перед каждым
изменением), `issue.net.orig`. Прежний drop-in и `STATE_FILE` восстанавливаются при откате внутри запуска.
Ключи в `authorized_keys` при откате не удаляются.

`--confirm N` — таймер автоотката: после применения скрипт ждёт N секунд, пока вы из **новой** сессии не
выполните `sudo touch /run/secure_ssh.confirmed` (или не нажмёте Enter в текущем окне). Без подтверждения всё
откатывается, sshd перезапускается, код выхода 3. Обрыв текущей сессии (SIGHUP), Ctrl-C или SIGTERM во время
ожидания тоже считаются отсутствием подтверждения и откатывают изменения; на случай гибели основного процесса
запускается независимый сторож, который откатит сам (журнал в `/etc/ssh/.secure_ssh.watchdog.log`). Это
единственная мера, которая спасает при любой ошибке, включая закрытый firewall. Для длинных сессий удобно
запускать в `tmux`/`screen`.

Коды выхода:

| Код | Значение |
|---|---|
| 0 | успех (или `--dry-run`, `--check`) |
| 1 | ошибка; если что-то уже было записано — откачено |
| 2 | настройки записаны, но либо часть значений перекрыта другой директивой (выше `Include`, в другом drop-in, в `Match`; в выводе указано, где именно), либо sshd не удалось перезагрузить — он работает со старой конфигурацией, следующий запуск повторит перезагрузку |
| 3 | изменения откачены по таймеру `--confirm` |

Откат вручную:

```sh
sudo ./secure_ssh.sh --rollback                      # sshd_config <- sshd_config.orig, drop-in убирается, sshd перезагружается
sudo ./secure_ssh.sh --rollback /etc/ssh/sshd_config.bak.20260131-120000
```

### FAQ

**Не могу войти: `Too many authentication failures`.** В ssh-agent загружено больше ключей, чем `MaxAuthTries`
(по умолчанию 6); клиент перебирает их все. Подключайтесь с нужным ключом явно:
`ssh -o IdentitiesOnly=yes -i ~/.ssh/id_ed25519 user@host`, или поднимите `--max-auth-tries`.

**`Permission denied (publickey)` после применения.** Проверьте в консоли провайдера: `sudo ./secure_ssh.sh --check`
покажет, куда sshd смотрит за ключами, какие ключи активны и что эффективно для пользователя с учётом `Match`.
Частые причины: ключ лежит не в том пользователе; домашний каталог доступен на запись группе (`StrictModes`);
на RHEL после ручного копирования ключей нужен `restorecon -R ~/.ssh`.

**Потерял доступ полностью.** Консоль провайдера (VNC/serial) → `sudo ./secure_ssh.sh --rollback` или вручную:
`rm /etc/ssh/sshd_config.d/00-secure-ssh.conf; cp /etc/ssh/sshd_config.orig /etc/ssh/sshd_config; sshd -t && systemctl restart ssh`
(`sshd` на RHEL, `rc-service sshd restart` на Alpine).

**Запуск через `su -` / Ansible / cloud-init.** `SUDO_USER` пуст, по умолчанию ключи получит только root.
Укажите `--users root,<admin>` явно.

## Проверка

```sh
sudo ./secure_ssh.sh --check                                       # полный отчёт без изменений
sudo sshd -T | grep -iE '^(port|passwordauthentication|permitrootlogin|allowtcpforwarding) '
sudo sshd -T -C user=deploy,host=localhost,addr=127.0.0.1 | grep -i passwordauthentication   # с учётом Match
ss -tlnp | grep sshd                                               # какие порты реально слушаются
ssh -p <порт> -o IdentitiesOnly=yes -i ~/.ssh/id_ed25519 <пользователь>@<сервер>
```

## Переход с v1

Первая версия скрипта (bash) дописывала в конец `sshd_config` строки `Port 22`, `Protocol 2`, `UsePAM yes`,
`MaxAuthTries 3`, `AllowTcpForwarding no` и т.п. v2 их не удаляет, но они безвредны: в режиме dropin
значения из `00-secure-ssh.conf` имеют приоритет, а при смене порта глобальные `Port` комментируются.
Изменились значения по умолчанию: `AllowTcpForwarding yes` (нужен VS Code Remote и туннелям), `MaxAuthTries 6`,
`PermitRootLogin prohibit-password`. Если нужен старый режим, передайте `--tcp-forwarding no --max-auth-tries 3`
один раз — значения запомнятся.

## Тесты

```sh
sudo tests/run.sh            # sh; также: tests/run.sh dash, tests/run.sh bash, tests/run.sh "busybox sh"
AWK_IMPL="busybox awk" sudo tests/run.sh
```

Тесты не трогают `/etc/ssh`: конфиги создаются во временном каталоге, sshd запускается на высоких портах с `-f`,
создаётся пользователь `sst_user`. Покрываются оба режима записи, смена и «липкость» порта, защита от lockout,
закомментированные и ограниченные ключи, нестандартный `AuthorizedKeysFile`, симлинки, сбой `sshd -t`,
нехватка места на диске, `--dry-run`/`--check`/`--rollback`/`--confirm` (включая SIGHUP и SIGKILL во время ожидания), `AllowUsers`,
`PubkeyAcceptedAlgorithms`, `%h`/`%U` в `AuthorizedKeysFile`, подложенные временные файлы, CRLF-конфиг и
реальный sshd: SIGHUP, fallback при отказе менеджера служб, вход по ключу, отказ пароля и автоматический откат,
когда порт после перезагрузки не слушается.
CI (`.github/workflows/ci.yml`) гоняет shellcheck и тесты в контейнерах Ubuntu, Debian, Alpine и Rocky Linux.
