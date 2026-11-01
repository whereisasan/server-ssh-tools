# server-ssh-tools

[![CI](https://github.com/whereisasan/server-ssh-tools/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/whereisasan/server-ssh-tools/actions/workflows/ci.yml)
![POSIX sh](https://img.shields.io/badge/shell-POSIX%20sh%20%7C%20dash%20%7C%20bash%20%7C%20busybox-blue)
![OpenSSH](https://img.shields.io/badge/OpenSSH-7.4%20%E2%80%93%2010.0-informational)
![ShellCheck](https://img.shields.io/badge/shellcheck-clean-brightgreen)
![Proxmox VE](https://img.shields.io/badge/Proxmox%20VE-supported-E57000)

**`secure_ssh.sh`** — один скрипт, который безопасно и повторяемо закрывает SSH-сервер: ставит ваши ключи с
GitHub, отключает пароли, применяет проверенные настройки sshd и **не даёт потерять доступ**. Один файл,
POSIX sh, без зависимостей, работает от Ubuntu 18.04 и CentOS 7 до Ubuntu 24.04, Alpine и нод Proxmox.

```sh
curl -fsSL https://raw.githubusercontent.com/whereisasan/server-ssh-tools/main/secure_ssh.sh | sudo sh -s -- -u <github> --dry-run
```

> **Важно.** По умолчанию ставятся ключи пользователя GitHub **`whereisasan`**. Если это не вы, всегда указывайте
> своего: `-u <ваш_github>`. Иначе доступ к серверу получит автор скрипта, а пароли будут отключены.

---

## Содержание

- [Что делает](#что-делает)
- [Поддерживаемые системы](#поддерживаемые-системы)
- [Быстрый старт](#быстрый-старт)
- [Как это работает](#как-это-работает)
- [Что меняется в sshd](#что-меняется-в-sshd)
- [Параметры](#параметры)
- [Proxmox VE](#proxmox-ve)
- [Смена порта](#смена-порта)
- [Защита от потери доступа](#защита-от-потери-доступа)
- [Дополнительное усиление](#дополнительное-усиление)
- [FAQ](#faq)
- [Тесты и CI](#тесты-и-ci)
- [Переход с v1](#переход-с-v1)

---

## Что делает

| | |
|---|---|
| **Ключи** | скачивает публичные ключи с GitHub (`github.com/<user>.keys`), проверяет каждый через `ssh-keygen`, кладёт в `authorized_keys` нужных пользователей туда, куда реально смотрит sshd (`AuthorizedKeysFile`), без дублей и с правильными правами |
| **Настройки** | отключает пароли и применяет безопасные параметры через drop-in `sshd_config.d/00-secure-ssh.conf` (OpenSSH ≥ 8.2) или правкой `sshd_config` на старых системах |
| **Безопасность применения** | проверяет будущую конфигурацию `sshd -t` **до** записи, пишет атомарно с бэкапами, откатывает при любой ошибке, перезагружает sshd только при изменениях и убеждается, что он жив и слушает порты |
| **Проверка** | показывает эффективные значения `sshd -T`, в том числе для каждого пользователя с учётом `Match`, и говорит, кто именно сможет войти |
| **Режимы** | `--dry-run`, `--check`, `--rollback`, таймер автоотката `--confirm` |

## Поддерживаемые системы

Каждый коммит прогоняется в CI на реальных контейнерах с настоящим sshd: поднимается демон на высоком порту,
выполняется вход по ключу, проверяется отказ по паролю и автоматический откат.

| Система | OpenSSH | Шелл | awk | Режим | CI |
|---|---|---|---|---|:-:|
| Ubuntu 24.04 (`ssh.socket`) | 9.6 | dash, bash | mawk 1.3.4 | drop-in | ✅ |
| Ubuntu 22.04 | 8.9 | dash, bash | mawk 1.3.4 | drop-in | ✅ |
| Debian 12 | 9.2 | dash, bash | mawk 1.3.4 | drop-in | ✅ |
| Debian 11 | 8.4 | dash | mawk 1.3.4 | drop-in | ✅ |
| Alpine 3.20 (OpenRC) | 9.7 | busybox ash | busybox awk | drop-in | ✅ |
| Rocky Linux 9 (RHEL, SELinux, без `diffutils`) | 8.7 | bash | gawk | drop-in | ✅ |
| Ubuntu 18.04 | 7.6 | dash 0.5.8 | mawk 1.3.3 | legacy | ✅ |
| Proxmox VE 7 / 8 / 9 | 8.4 – 10.0 | dash | mawk | drop-in | ручная проверка |
| CentOS 7 / RHEL 7 | 7.4 | bash | gawk | legacy | имитация 7.x в тестах |

Перезагрузка sshd: systemd (с учётом `ssh.socket`), OpenRC, SysV `service`, SIGHUP по pid-файлу. Если один
способ отказал, пробуется следующий.

## Быстрый старт

```sh
# 1. Посмотреть, что изменится: ничего не записывается, но будущая конфигурация проверяется sshd -t
curl -fsSL https://raw.githubusercontent.com/whereisasan/server-ssh-tools/main/secure_ssh.sh | sudo sh -s -- -u <github> --dry-run

# 2. Применить с таймером автоотката: без подтверждения из НОВОГО окна за 120 с всё откатится
curl -fsSL https://raw.githubusercontent.com/whereisasan/server-ssh-tools/main/secure_ssh.sh | sudo sh -s -- -u <github> --confirm 120

# 3. В новом окне: ssh <пользователь>@<сервер>, затем  sudo touch /run/secure_ssh.confirmed
```

Если вы уже root (Proxmox, контейнеры), `sudo` не нужен: `... | sh -s -- -u <github> --dry-run`.

Переменные окружения при `curl | sudo sh` передавайте через `sudo env`, иначе `sudo` их отбросит:

```sh
curl -fsSL .../secure_ssh.sh | sudo env GITHUB_USER=<github> TARGET_USERS=root,deploy sh
curl -fsSL .../secure_ssh.sh | sudo sh -s -- --users root,deploy --port 2222 --open-firewall
```

Из клона:

```sh
git clone https://github.com/whereisasan/server-ssh-tools.git && cd server-ssh-tools
sudo ./secure_ssh.sh -u <github> --dry-run
sudo ./secure_ssh.sh -u <github> --confirm 120
```

Для важных серверов закрепляйте коммит вместо ветки:
`https://raw.githubusercontent.com/whereisasan/server-ssh-tools/<commit>/secure_ssh.sh`. Версия: `--version`.

<details>
<summary><b>Пример вывода</b></summary>

```
[INFO] secure_ssh.sh v2.1.0; sshd: /usr/sbin/sshd (OpenSSH 9.6), конфиг: /etc/ssh/sshd_config
[INFO] режим записи настроек: dropin
[INFO] Загружаю ключи: https://github.com/whereisasan.keys
[OK] получено валидных ключей: 2
[INFO]   ключ: SHA256:l/nGj1ExAdLZvzeoCVQyRRtfGcyckrlQUVTEYgSKoFU (ED25519) AAAAC3NzaC1l...
[INFO]   ключ: SHA256:xnF9miDyuCDuLMw8ShLKLIjKxhJo7yonHg0K97WHkSY (RSA) AAAAB3NzaC1y...
[ADD] deploy: добавить ключей в /home/deploy/.ssh/authorized_keys: 2 (уже есть: 0)
[OK] root: все 2 ключ(ей) уже в /root/.ssh/authorized_keys
[OK] sshd -t: будущая конфигурация корректна
[UPDATE] /etc/ssh/sshd_config:
  закомментированы глобальные AcceptEnv (клиент не сможет навязать переменные окружения)
[UPDATE] /etc/ssh/sshd_config.d/00-secure-ssh.conf
[INFO] первоначальная копия сохранена: /etc/ssh/sshd_config.orig
[INFO] бэкап перед изменением: /etc/ssh/sshd_config.bak.20261101-120000
[OK] sshd -t: записанная конфигурация корректна
[OK] ssh.service перезагружен
[OK] sshd слушает порты: 22
[OK] эффективно: Port 22
[OK] эффективно: PasswordAuthentication no
[OK] эффективно: PermitRootLogin prohibit-password
...
──────── Итог ────────
Режим:           dropin (/etc/ssh/sshd_config.d/00-secure-ssh.conf)
Порты sshd:      22
Вход по ключу:   root (2 ключ.), deploy (2 ключ.) — ключи https://github.com/whereisasan.keys
Результат:       OK
Проверьте вход, НЕ закрывая эту сессию, в новом окне:  ssh -p 22 <пользователь>@<сервер>
```

</details>

## Как это работает

```
 скачать и проверить ключи ──► проверить пользователей и доступ ──► собрать будущий конфиг во временной копии
          │ ошибка: выход без изменений                                     │ sshd -t
          ▼                                                                 ▼
 установить ключи (mktemp + rename) ──► записать файлы атомарно с бэкапами ──► sshd -t ещё раз
                                                                                   │
 sshd -T: эффективные значения ◄── проверить, что sshd слушает порты ◄── перезагрузить sshd
          │                                        │ не слушает: откат + перезапуск со старой конфигурацией
          ▼
 --confirm N: ждать подтверждения из новой сессии, иначе откат (переживает обрыв сессии)
```

Любая ошибка на любом шаге восстанавливает все файлы из бэкапов. Если sshd уже был перезагружен, он
перезапускается со старой конфигурацией. Параметры прошлого запуска запоминаются в
`/etc/ssh/.secure_ssh.state`: повторный запуск «просто доложить ключи» не вернёт порт и настройки к значениям
по умолчанию. Явный флаг переопределяет сохранённое значение, `--reset` сбрасывает всё.

## Что меняется в sshd

| Директива | Значение | Зачем |
|---|---|---|
| `PasswordAuthentication` | `no` | только ключи; главная защита от перебора |
| `KbdInteractiveAuthentication` | `no` | закрывает второй путь ввода пароля через PAM (+ `ChallengeResponseAuthentication no` на OpenSSH < 8.7) |
| `PermitRootLogin` | `prohibit-password` | root только по ключу |
| `PermitEmptyPasswords` | `no` | страховка от аккаунтов без пароля |
| `PubkeyAuthentication` | `yes` | явно, чтобы случайный `no` в другом файле не отключил ключи |
| `LoginGraceTime` | `30` | меньше висящих соединений от сканеров |
| `MaxAuthTries` | `6` | не 3: клиент с несколькими ключами в агенте перебирает их все |
| `ClientAliveInterval` / `CountMax` | `300` / `2` | обнаружение оборванных соединений (это не таймаут простоя) |
| `X11Forwarding` | `no` | на сервере не нужен |
| `AllowTcpForwarding` | `yes` | туннели, VS Code Remote, миграция Proxmox |
| `LogLevel` | `VERBOSE` | в журнале отпечаток ключа при входе; нужно fail2ban (`--log-level keep`, чтобы не трогать) |
| `Banner` | `/etc/issue.net` | текст до входа |
| `AcceptEnv` | закомментирован | клиент не может навязать переменные окружения; исключения через `--accept-env` |
| `Port` | не трогается | только по `--port`, см. [Смена порта](#смена-порта) |

По флагам добавляются `AuthenticationMethods publickey`, `AllowGroups`, `AllowAgentForwarding`,
`UnusedConnectionTimeout` + `ChannelTimeout session=N`. Алгоритмы шифрования не трогаются: дефолты современных
версий без SHA-1 и CBC, а жёсткие списки ломают старых клиентов.

**Режимы записи.** *dropin* (OpenSSH ≥ 8.2): директивы в `sshd_config.d/00-secure-ssh.conf`; префикс `00-`
побеждает `50-cloud-init.conf` и `50-redhat.conf`, потому что sshd берёт **первое** значение; если `Include`
нет, он добавляется первой строкой. *legacy* (OpenSSH < 8.2 или `--mode legacy`): директивы правятся в
`sshd_config` в глобальной секции, до первого `Match` и выше `Include`. Строки внутри `Match` не трогаются.

**Ключи.** Пишутся в первый файл из эффективного `AuthorizedKeysFile` (`%h`, `%u`, `%U`) с меткой
`github:<user>`. Закомментированный ключ не считается установленным. Ключ, который уже стоит **с ограничениями**
(`from=`, `command=`, как у cloud-init для root), не трогается: ограничения снимаются только по `--unrestrict`.
Новый файл собирается через `mktemp` в каталоге назначения и атомарно переименовывается; символические ссылки на
месте `~/.ssh` или `authorized_keys` отвергаются (кроме ссылки root на Proxmox, см. ниже). Для каждого
пользователя проверяется, что sshd вообще его пустит (`AllowUsers`/`AllowGroups`/`Deny*`) и что тип ключа входит
в `PubkeyAcceptedAlgorithms`.

## Параметры

Флаги принимают форму `--флаг значение` и `--флаг=значение`; `yes`/`no` в любом регистре. Каждому флагу
соответствует переменная окружения.

**Ключи и пользователи**

| Флаг | Переменная | По умолчанию | Назначение |
|---|---|---|---|
| `-u`, `--github-user USER` | `GITHUB_USER` | `whereisasan` | чьи ключи ставить |
| `--keys-url URL` | `KEYS_URL` | `https://github.com/USER.keys` | другой источник ключей |
| `--keys-file ФАЙЛ` | `KEYS_FILE` | | локальный файл с ключами (офлайн) |
| `--users U1,U2` | `TARGET_USERS` | `root` + `SUDO_USER`/`DOAS_USER` | кому класть ключи |
| `--prune` | `PRUNE_KEYS=yes` | нет | удалить ключи с меткой `github:USER`, которых больше нет на GitHub |
| `--unrestrict` | `UNRESTRICT_KEYS=yes` | нет | если ключ уже есть с `from=`/`command=`, добавить строку без ограничений |

**Настройки sshd** (запоминаются между запусками)

| Флаг | Переменная | По умолчанию | Назначение |
|---|---|---|---|
| `-p`, `--port N` | `SSH_PORT` | не менять | порт sshd |
| `--close-old-port` | `KEEP_OLD_PORT=no` | старый порт остаётся | убрать старый порт после проверки входа |
| `--open-firewall` | `OPEN_FIREWALL=yes` | нет | открыть новый порт в `ufw`/`firewalld` |
| `--permit-root-login V` | `PERMIT_ROOT_LOGIN` | `prohibit-password` | `yes` / `no` / `prohibit-password` |
| `--tcp-forwarding V` | `ALLOW_TCP_FORWARDING` | `yes` | туннели, VS Code Remote |
| `--x11 V` | `X11_FORWARDING` | `no` | |
| `--max-auth-tries N` | `MAX_AUTH_TRIES` | `6` | см. FAQ про ssh-agent |
| `--log-level V` | `LOG_LEVEL` | `VERBOSE` | `keep` = не трогать |
| `--strict-auth` | `STRICT_AUTH=yes` | нет | `AuthenticationMethods publickey` |
| `--allow-group G1,G2` | `ALLOW_GROUPS` | | `AllowGroups`; целевые пользователи должны состоять в группах |
| `--idle-timeout N` | `IDLE_TIMEOUT` | | закрывать сессии без активности через N секунд (OpenSSH ≥ 9.2) |
| `--agent-forwarding V` | `ALLOW_AGENT_FORWARDING` | не трогать | `AllowAgentForwarding` |
| `--accept-env "V1 V2"` | `ACCEPT_ENV` | | переменные, которые sshd должен принимать; на Proxmox `LC_PVE_TICKET` добавляется всегда |
| `--no-pve-ticket` | `NO_PVE_TICKET=yes` | | на Proxmox не добавлять `LC_PVE_TICKET` |
| `--keep-accept-env` | `DISABLE_ACCEPT_ENV=no` | комментировать | не трогать чужие `AcceptEnv` |
| `--no-banner` | `BANNER=no` | баннер ставится | |
| `--banner-admin TEXT` | `BANNER_ADMIN` | `@whereisasan` | подпись в баннере |
| `--mode auto\|dropin\|legacy` | `CONFIG_MODE` | `auto` | куда писать настройки |
| `--reset` | `RESET_STATE=yes` | | не брать значения прошлого запуска |

**Режим работы и безопасность применения**

| Флаг | Переменная | По умолчанию | Назначение |
|---|---|---|---|
| `-n`, `--dry-run` | `DRY_RUN=yes` | | показать и проверить, ничего не менять |
| `--check` | | | только отчёт о текущем состоянии |
| `--rollback [ФАЙЛ]` | | | откат к `sshd_config.orig` (или ФАЙЛУ) |
| `--confirm N` | `CONFIRM_TIMEOUT` | `0` | ждать подтверждения N секунд, иначе откат |
| `--no-reload` | `NO_RELOAD=yes` | | не перезагружать sshd |
| `--reload-method M` | `RELOAD_METHOD` | `auto` | `systemd` / `openrc` / `service` / `sighup` |
| `--force` | `FORCE=yes` | | отключить защиту от потери доступа |
| `-y`, `--yes` | `YES=yes` | | не задавать вопросов |
| `-q`, `--quiet` | `QUIET=yes` | | только изменения, предупреждения и итог |

Только переменные: `SSHD_CONFIG` (`/etc/ssh/sshd_config`), `DROPIN_NAME` (`00-secure-ssh.conf`), `SSHD_BIN`,
`STATE_FILE` (`/etc/ssh/.secure_ssh.state`), `CONFIRM_FILE` (`/run/secure_ssh.confirmed`), `BANNER_FILE`
(`/etc/issue.net`), `LOGIN_GRACE_TIME` (30), `CLIENT_ALIVE_INTERVAL` (300), `CLIENT_ALIVE_COUNT_MAX` (2), `NO_COLOR`.

## Proxmox VE

Нода Proxmox определяется по каталогу `/etc/pve` или команде `pveversion`. Учитываются три особенности:

- **Консоль VM с другой ноды.** Нода подключается к ноде с VM по ssh и передаёт билет переменной
  `LC_PVE_TICKET`. Если sshd её не принимает, консоль падает с ошибкой
  `LC_PVE_TICKET not set, VNC proxy without password is forbidden`. Скрипт всегда добавляет `LC_PVE_TICKET` к
  `AcceptEnv`, в том числе к списку из `--accept-env`; отключить можно только флагом `--no-pve-ticket`.
  Выполнить нужно на каждой ноде.
- **Ключи root.** `/root/.ssh/authorized_keys` на ноде является ссылкой на `/etc/pve/priv/authorized_keys`,
  который кластер синхронизирует между нодами. Для root скрипт следует такой ссылке (ссылка и целевой каталог
  должны принадлежать root) и пишет ключи по целевому пути, не ломая её.
- **Миграция VM** идёт через ssh-туннель с пробросом портов: `AllowTcpForwarding` должен оставаться `yes`.

Ручной вариант без скрипта, если консоль уже не открывается:

```sh
echo 'AcceptEnv LC_PVE_TICKET' > /etc/ssh/sshd_config.d/10-proxmox.conf && sshd -t && systemctl reload ssh
```

## Смена порта

`--port N` — самый рискованный шаг, поэтому:

- перед записью проверяется, что порт свободен и что нет `ListenAddress` с явным портом (на него `Port` не действует);
- на SELinux в режиме Enforcing порт добавляется в `ssh_port_t` через `semanage` (без `semanage` — отказ,
  установите `policycoreutils-python-utils`);
- при активном `ufw`/`firewalld` печатаются готовые команды, с `--open-firewall` они выполняются; про security
  group облака скрипт напоминает всегда;
- **старый порт остаётся открытым**, пока вы не проверите вход по новому и не запустите `--port N --close-old-port`;
- после перезагрузки проверяется, что sshd слушает нужные порты (включая `ListenAddress host:port`); если нет,
  конфигурация откатывается и sshd перезапускается со старой;
- на Ubuntu 24.04 порт слушает `ssh.socket`, он перегенерируется и перезапускается.

## Защита от потери доступа

Скрипт отказывается продолжать (без `--force`), если после его работы на сервер нельзя будет войти:

- список `--users` пуст, пользователь не найден или без домашнего каталога;
- `--permit-root-login no`, а ключи ставятся только root (типично при запуске через `su -`, с консоли или из
  cloud-init, где `SUDO_USER` пуст);
- эффективный `AuthorizedKeysFile none`;
- ни один пользователь не сможет войти: запрещён `AllowUsers`/`AllowGroups`, тип ключа не принимается sshd,
  ключи есть только с ограничениями `from=`/`command=`;
- ключи не скачались или ни один не прошёл проверку;
- исходный `sshd_config` уже не проходит `sshd -t` (чинимые проблемы окружения исправляются: создаётся
  `/run/sshd`, генерируются host-ключи).

**Бэкапы:** `sshd_config.orig` (один раз, при первом изменении), `sshd_config.bak.<дата>` (перед каждым
изменением), `issue.net.orig`. Прежний drop-in и файл состояния восстанавливаются при откате внутри запуска.
Ключи в `authorized_keys` при откате не удаляются.

**`--confirm N`** — таймер автоотката: после применения скрипт ждёт N секунд, пока вы из **новой** сессии не
выполните `sudo touch /run/secure_ssh.confirmed` (или не нажмёте Enter в текущем окне). Без подтверждения всё
откатывается, sshd перезапускается, код выхода 3. Обрыв текущей сессии, Ctrl-C или SIGTERM во время ожидания
тоже считаются отсутствием подтверждения; на случай гибели процесса работает независимый сторож
(журнал `/etc/ssh/.secure_ssh.watchdog.log`). Это единственная мера, которая спасает при любой ошибке, включая
закрытый firewall.

| Код выхода | Значение |
|:-:|---|
| 0 | успех (или `--dry-run`, `--check`) |
| 1 | ошибка; если что-то уже было записано, откачено |
| 2 | настройки записаны, но часть значений перекрыта другой директивой (в выводе указано, где) или sshd не удалось перезагрузить; следующий запуск повторит перезагрузку |
| 3 | изменения откачены по таймеру `--confirm` |

Откат вручную:

```sh
sudo ./secure_ssh.sh --rollback                                   # sshd_config <- .orig, drop-in убирается, sshd перезагружается
sudo ./secure_ssh.sh --rollback /etc/ssh/sshd_config.bak.20260131-120000
```

## Дополнительное усиление

По умолчанию скрипт не делает ничего, что могло бы закрыть вход администратору. Дальше по желанию:

| Флаг | Что даёт | На что обратить внимание |
|---|---|---|
| `--strict-auth` | только ключ, на уровне `AuthenticationMethods`, не переопределяется другими файлами | ломает схемы «ключ + пароль» и форсированные команды с паролем |
| `--allow-group ssh-users` | входят только участники группы, сервисные аккаунты не войдут даже с ключом | скрипт проверяет членство целевых пользователей; не забудьте добавить root, если он нужен |
| `--idle-timeout 1800` | закрывает забытые сессии (OpenSSH ≥ 9.2) | `ClientAliveInterval` этого не делает: живой клиент отвечает на проверки сам |
| `--agent-forwarding no` | скомпрометированный сервер не воспользуется вашим агентом | VS Code Remote без проброса агента работает |
| `--accept-env LANG` | язык вашего терминала в сессии | без такой локали на сервере будут предупреждения `setlocale` |

Разумный набор для обычного сервера:

```sh
... | sudo sh -s -- -u <github> --strict-auth --idle-timeout 1800 --agent-forwarding no --confirm 120
```

## FAQ

**`Too many authentication failures`.** В ssh-agent больше ключей, чем `MaxAuthTries`; клиент перебирает их все.
Подключайтесь с нужным ключом явно: `ssh -o IdentitiesOnly=yes -i ~/.ssh/id_ed25519 user@host`.

**`Permission denied (publickey)` после применения.** Из консоли провайдера: `sudo ./secure_ssh.sh --check`
покажет, куда sshd смотрит за ключами, какие ключи активны и что эффективно для пользователя с учётом `Match`.
Частые причины: ключ не у того пользователя; домашний каталог доступен на запись группе (`StrictModes`);
на RHEL после ручного копирования ключей нужен `restorecon -R ~/.ssh`.

**Потерял доступ полностью.** Консоль провайдера → `sudo ./secure_ssh.sh --rollback`, или вручную:
`rm /etc/ssh/sshd_config.d/00-secure-ssh.conf; cp /etc/ssh/sshd_config.orig /etc/ssh/sshd_config; sshd -t && systemctl restart ssh`
(`sshd` на RHEL, `rc-service sshd restart` на Alpine).

**Запуск через `su -` / Ansible / cloud-init.** `SUDO_USER` пуст, по умолчанию ключи получит только root.
Укажите `--users root,<admin>` явно.

**«Не получено ни одного валидного ключа».** У аккаунта GitHub нет публичных ключей (Settings → SSH and GPG
keys) или сервер не достучался до `github.com`. Проверьте `curl -fsSL https://github.com/<user>.keys`.
Пока ключей нет, скрипт по замыслу ничего не меняет.

Проверка состояния в любой момент:

```sh
sudo ./secure_ssh.sh --check
sudo sshd -T | grep -iE '^(port|passwordauthentication|permitrootlogin|allowtcpforwarding) '
sudo sshd -T -C user=deploy,host=localhost,addr=127.0.0.1 | grep -i passwordauthentication   # с учётом Match
ss -tlnp | grep sshd
```

## Тесты и CI

[![CI](https://github.com/whereisasan/server-ssh-tools/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/whereisasan/server-ssh-tools/actions/workflows/ci.yml)

`tests/run.sh` — около 180 интеграционных проверок с **настоящим sshd**: он поднимается на высоких портах с
`-f`, выполняется вход по ключу, проверяется отказ по паролю, SIGHUP, fallback при отказе менеджера служб и
автоматический откат, когда порт после перезагрузки не слушается. `/etc/ssh` не затрагивается.

Что покрыто: оба режима записи, смена и «липкость» порта, все сценарии защиты от lockout, закомментированные и
ограниченные ключи, нестандартный `AuthorizedKeysFile` (`%h`, `%U`, `none`), симлинки и подложенные временные
файлы, `AllowUsers`/`AllowGroups`, `PubkeyAcceptedAlgorithms`, сбой `sshd -t`, нехватка места на диске,
`--dry-run`/`--check`/`--rollback`, `--confirm` с SIGHUP и SIGKILL во время ожидания, CRLF-конфиг, Proxmox
(автоопределение, `--accept-env`, ссылка root), `--strict-auth`, `--idle-timeout`, `--agent-forwarding`.

```sh
sudo tests/run.sh                         # sh; также: tests/run.sh dash | bash | "busybox sh"
AWK_IMPL="busybox awk" sudo tests/run.sh  # с другим awk
SSHD_FAKE_OLD=1 sudo tests/run.sh         # имитация OpenSSH 7.x (режим legacy)
```

CI (`.github/workflows/ci.yml`) на каждый push и PR: `shellcheck` + `dash -n` + `bash -n`, затем тесты в
контейнерах Ubuntu 18.04 / 22.04 / 24.04, Debian 11 / 12, Alpine 3.20 и Rocky Linux 9 — см. таблицу
[поддерживаемых систем](#поддерживаемые-системы).

## Переход с v1

Первая версия (bash) дописывала в конец `sshd_config` строки `Port 22`, `Protocol 2`, `UsePAM yes`,
`MaxAuthTries 3`, `AllowTcpForwarding no`. v2 их не удаляет, но они безвредны: в режиме dropin значения из
`00-secure-ssh.conf` имеют приоритет, а при смене порта глобальные `Port` комментируются. Изменились значения
по умолчанию: `AllowTcpForwarding yes`, `MaxAuthTries 6`, `PermitRootLogin prohibit-password`, `LogLevel VERBOSE`.
На нодах Proxmox v1 ломала консоль VM между нодами; достаточно запустить v2 ещё раз на каждой ноде.
