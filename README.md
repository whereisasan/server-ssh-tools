# server-ssh-tools

Этот скрипт автоматически настраивает **SSH-сервер** максимально безопасным образом:  
- применяет рекомендуемые параметры безопасности (включая современную криптографию);  
- добавляет публичные ключи администратора с GitHub;  
- устанавливает кастомный баннер (`/etc/issue.net`);  
- применяет конфигурацию **только при изменениях** (идемпотентность).  

---

## ✨ Возможности

### Корректная работа с современными дистрибутивами
- 📌 Учитывает `Include /etc/ssh/sshd_config.d/*.conf` (Ubuntu 22.04+, Debian 12). Настройки пишутся в drop-in `00-secure-ssh-hardening.conf`, а конфликтующие директивы в остальных файлах (например, `50-cloud-init.conf` с `PasswordAuthentication yes`) отключаются — иначе они молча переопределяли бы хардненинг, так как в `sshd_config` выигрывает **первое** вхождение параметра.  
- 📌 Если `Include` отсутствует, настройки пишутся в основной конфиг **до первого `Match`-блока**, чтобы не попасть внутрь условной секции.  
- 📌 Директивы внутри `Match`-блоков не изменяются — только выводится предупреждение, так как это осознанные исключения администратора.  
- 📌 Автоопределение systemd-юнита (`ssh.service` / `sshd.service`) и поддержка socket-активации (`ssh.socket` в Ubuntu 24.04) с предупреждением о том, что `Port` в этом случае задаётся в сокет-юните.  
- 📌 Применение через `reload` (не рвёт текущие сессии) с откатом к `restart`; ненулевой код возврата при неудаче.  

### Безопасность
- 📌 **Root-вход только по ключам** (без паролей).  
- 📌 Современные `KexAlgorithms`, `Ciphers`, `MACs`, `HostKeyAlgorithms` (для OpenSSH ≥ 7.4). `HostKeyAlgorithms` сужается только при наличии подходящего host key.  
- 📌 Совместимость по версиям: `KbdInteractiveAuthentication` для OpenSSH ≥ 8.7, `ChallengeResponseAuthentication` для более старых; устаревший `Protocol` отключается.  
- 📌 Права `600 root:root` на конфиги, `700` на `~/.ssh`, `600` на `authorized_keys`.  
- 📌 Поддержка SELinux (RHEL/CentOS) — контексты `authorized_keys` восстанавливаются автоматически.  

### Надёжность
- 📌 Проверка `sshd -t` перед применением; при ошибке **вся** конфигурация (основной файл и drop-in'ы) откатывается автоматически.  
- 📌 Резервные копии в `/var/backups/secure_ssh`: разовая `sshd_config.orig` и снимок `pre-run/` перед каждым запуском.  
- 📌 Загруженные с GitHub ключи проверяются на формат; сравнение по телу ключа, а не по подстроке.  
- 📌 Запуск только от root, проверка зависимостей, `flock` от параллельного запуска, таймауты у `curl`.  

---

## ⚙️ Установка и использование

### 0. Быстрый запуск одной командой
```bash
curl -s https://raw.githubusercontent.com/whereisasan/server-ssh-tools/refs/heads/main/secure_ssh.sh | bash
```
### 1. Склонировать репозиторий
```bash
git clone https://github.com/whereisasan/server-ssh-tools.git
cd server-ssh-tools
```
### 2. Сделать скрипт исполняемым
```bash
chmod +x secure_ssh.sh
```
### 3. Запустить
```bash
sudo ./secure_ssh.sh
```

---

## 🔧 Ограничение списка пользователей

`AllowUsers` / `AllowGroups` по умолчанию **выключены**: ошибка в списке приводит к потере доступа к серверу. Включаются явно через окружение:

```bash
sudo SSH_ALLOW_USERS="root deploy" ./secure_ssh.sh
sudo SSH_ALLOW_GROUPS="sshusers" ./secure_ssh.sh
```

---

## ↩️ Откат

```bash
# вернуть конфигурацию, которая была до последнего запуска
sudo cp /var/backups/secure_ssh/pre-run/sshd_config /etc/ssh/sshd_config
sudo cp -a /var/backups/secure_ssh/pre-run/sshd_config.d/. /etc/ssh/sshd_config.d/

# либо вернуться к самому первому состоянию
sudo cp /var/backups/secure_ssh/sshd_config.orig /etc/ssh/sshd_config

sudo sshd -t && sudo systemctl reload ssh
```
