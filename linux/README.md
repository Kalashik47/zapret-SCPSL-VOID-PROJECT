# Zapret SCP:SL — VOID PROJECT для Linux

Linux-пакет предназначен для игроков и выделенных серверов SCP: Secret
Laboratory. Он устанавливает официальный
[bol-van/zapret2](https://github.com/bol-van/zapret2), затем добавляет профиль
для центральных сервисов SCP:SL и игрового трафика.

> [!IMPORTANT]
> Обязательный профиль: **Game Filter — enabled (TCP and UDP)** и
> **IPSet Filter — any**. В Linux это реализовано через TCP+UDP в
> `NFQWS2_PORTS_*` и `MODE_FILTER=none`.

> [!WARNING]
> `MODE_FILTER=none` и широкие диапазоны портов перехватывают не только SCP:SL.
> На сервере с другими сервисами профиль может повлиять на их соединения.
> Сначала проверьте его в контролируемое время.

## Поддерживаемая среда

- обычный Linux с root-доступом;
- systemd, OpenRC/SysV-совместимый init;
- nftables или iptables;
- поддержка NFQUEUE в ядре;
- `bash`, `curl`, `tar`, `sha256sum`, `awk`, `sed`.

WSL и macOS не поддерживаются. Для роутеров/OpenWrt используйте официальный
инсталлятор `zapret2` и переносите параметры из `scpsl.conf` вручную.

## Установка

```bash
tar -xzf zapret-SCPSL-VOID-PROJECT-Linux-1.10.1.tar.gz
cd zapret-SCPSL-VOID-PROJECT-Linux-1.10.1
chmod +x SCP-SL-Linux.sh
sudo ./SCP-SL-Linux.sh install
```

Если `zapret2` ещё нет, скрипт скачает официальный релиз v1.0.4 и официальный
`sha256sum.txt`, проверит архив и запустит `install_easy.sh`. В появившемся
официальном установщике согласитесь установить **NFQWS2**. После его завершения
профиль SCP:SL применится автоматически.

Установщик:

1. не подменяет и не включает сторонние бинарники в этот пакет;
2. перед изменением сохраняет `/opt/zapret2/config.before-scpsl.*`;
3. автоматически выбирает `nftables`, а при его отсутствии — `iptables`;
4. включает IPv4 и IPv6;
5. перезапускает службу `zapret2`.

После установки полностью закройте и заново откройте Steam и SCP:SL.

## Проверка центральных серверов

Запускается без `sudo`:

```bash
./SCP-SL-Linux.sh test
```

Проверяются `scpslgame.com`, `api.scpslgame.com`, `servers.php`,
`sbg1.scpslgame.com` и `slac.scpslgame.com` с User-Agent, похожим на Unity.
Результат сохраняется рядом со скриптом в `test_results_linux_*.txt`.

Успешный HTTP/TLS-тест подтверждает доступность сети, но не доказывает, что
игровая авторизация завершится успешно. Если игра продолжает писать
«Подключение к центральным серверам», приложите отчёт и файл
`~/.config/unity3d/Northwood/SCPSL/Player.log` (если он есть).

## Управление

```bash
sudo ./SCP-SL-Linux.sh start
sudo ./SCP-SL-Linux.sh stop
sudo ./SCP-SL-Linux.sh restart
./SCP-SL-Linux.sh status
sudo ./SCP-SL-Linux.sh apply
```

`apply` повторно добавляет профиль, предварительно удаляя старый блок VOID
PROJECT, поэтому одинаковые настройки не накапливаются.

## Безопасное отключение профиля

```bash
sudo ./SCP-SL-Linux.sh remove-profile
```

Команда удаляет только блок VOID PROJECT из `/opt/zapret2/config`, сохраняет
резервную копию и перезапускает службу. Сама `zapret2` и файлы пользователя не
удаляются.

## Настройки профиля

| Параметр | Значение |
|---|---|
| Game Filter | enabled, TCP and UDP |
| IPSet Filter | any (`MODE_FILTER=none`) |
| TCP | `80,443,1024-65535` |
| UDP | `443,1024-65535` |
| IPv4 / IPv6 | включены |
| Firewall | nftables, иначе iptables |

Проект неофициальный и не связан с Northwood Studios, Cloudflare или авторами
`zapret2`. Сервер VOID PROJECT: `193.164.16.165:7777`.
