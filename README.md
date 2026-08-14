# NodeInstallator

Интерактивный мастер для развёртывания Remnawave edge на чистом сервере.
Скрипт собирает staged-конфигурацию, выдаёт точные поля для Remnawave Panel,
запускает Node и поднимает несколько клиентских транспортов на одном edge.

Зафиксированная совместимая база:

- NodeInstallator `2026-08-14.1`;
- Remnawave Panel/Backend `2.8.1`;
- Remnawave Node `2.8.0`;
- встроенный Xray `26.6.27`;
- pinned Docker-образы Node, HAProxy и Caddy;
- клиентский fingerprint по умолчанию — `firefox`.

Скрипт не обещает универсальную «неблокируемость»: доступность зависит от
оператора, региона, маршрута и текущего поведения DPI. Развёртывание нужно
начинать с canary-пользователя и проверять из тех сетей, где будут клиенты.

## Что разворачивается

```text
TCP/443 -> HAProxy SNI routing
             |-- VLESS RAW + REALITY self-SNI + Vision
             |-- VLESS RAW + REALITY external target + Vision
             `-- Caddy TLS/HTTP2 -> VLESS XHTTP auto

UDP/443 -> optional Hysteria2

Panel -> allowlisted Node API port -> Remnawave Node -> managed Xray
```

- self-SNI RAW/REALITY использует локальный HTTPS cover-site и не создаёт петлю
  через публичный `443`;
- внешний RAW/REALITY может автоматически выбрать самый быстрый валидный на
  этой ноде target из `dl.google.com`, `www.amd.com` и `www.tesla.com`; мастер
  проверяет DNS, сертификат, TLS 1.3, Xray handshake и делает три замера TLS;
- для внешнего target включён лимит только неавторизованного fallback-трафика,
  чтобы сканер не превратил ноду в неограниченный CDN-forwarder;
- XHTTP работает за обычным TLS/HTTP/2, случайным закрытым path и режимом
  `auto`; на HTTP/2 это обычно выбирает быстрый `stream-up`, не фиксируя
  `packet-up` для всех клиентов;
- Hysteria2 включается отдельно и использует `UDP/443`;
- Hysteria2 certificate/key хранятся отдельными файлами `0600` на Node и
  передаются в Node-контейнер read-only volume; PEM и private key не
  встраиваются в Config Profile;
- Xray/Caddy/HAProxy backend-порты остаются на loopback;
- Node API разрешается только реально наблюдаемому egress IP панели;
- мастер генерирует XRAY_JSON AUTO template для Happ/INCY;
- клиентский AUTO template перехватывает DNS в TUN, отправляет российские
  сервисы, игровые порты и распознанный BitTorrent напрямую с устройства, а
  остальной трафик — через health-aware `RU_AUTO`;
- локальный cover-site — полноценный адаптивный endpoint dashboard без
  сторонних CDN, analytics и cookies; его статический payload жёстко ограничен
  40 MiB (фактический размер значительно меньше);
- host tuning включает live `fq`, BBR, MTU probing и 32 MiB TCP autotuning;
  контейнеры используют относительные CPU weights без жёсткого CFS-потолка,
  поэтому свободные vCPU доступны для кратковременного throughput burst;
- изменения UFW и server tuning имеют отдельный явный rollback.

## Требования

- чистый Ubuntu или Debian с `apt` и systemd;
- root/sudo и доступ к provider console/OOB;
- публичный IPv4 сервера;
- один собственный cover/self-SNI домен с A-записью на этот IPv4;
- второй собственный домен нужен только при выборе XHTTP;
- стабильный исходящий/NAT IPv4 Remnawave Panel для allowlist Node API;
- открытый `TCP/443`, а для Hysteria2 также `UDP/443`, в firewall провайдера.

Не публикуйте AAAA, пока на сервере нет реально работающего глобального IPv6.

## Быстрый запуск

```bash
git clone https://github.com/Vlone111/NodeInstallator.git
cd NodeInstallator
chmod 700 remnawave-edge-oneclick.sh

sudo ./remnawave-edge-oneclick.sh bootstrap
sudo ./remnawave-edge-oneclick.sh selftest
sudo ./remnawave-edge-oneclick.sh all
```

При запуске через `bash <(curl ...)` мастер сохраняет собственную исполняемую
копию в `/opt/remnawave-edge/remnawave-edge-oneclick.sh`. Повторный запуск после
обрыва использует уже сохранённые защищённые значения и не просит Node
`SECRET_KEY` второй раз.

Запуск без аргументов открывает интерактивное меню:

```bash
sudo ./remnawave-edge-oneclick.sh
```

Монохромный и автоматизированный вывод:

```bash
sudo RW_NO_COLOR=1 ./remnawave-edge-oneclick.sh status
sudo RW_ASCII=1 ./remnawave-edge-oneclick.sh
sudo RW_QUIET=1 ./remnawave-edge-oneclick.sh verify
```

Скрипт также поддерживает стандартную переменную `NO_COLOR`.

## Этапы

| Команда | Назначение |
|---|---|
| `bootstrap` | Установить базовые пакеты и Docker Compose |
| `selftest` | Изолированно сгенерировать и проверить конфигурацию |
| `init` | Собрать параметры и подготовить защищённые файлы |
| `panel` | Показать точные поля первого этапа Panel 2.8.1 |
| `node` | Принять скрытый `SECRET_KEY`, применить allowlist и запустить Node |
| `template` | Принять UUID физических Hosts и создать AUTO template |
| `edge` | Запустить HAProxy/Caddy и проверить публичный `443` |
| `verify` | Проверить DNS, mTLS, TLS, listener ownership и маршрутизацию |
| `verify-auth` | Проверить все выбранные транспорты с canary-пользователем |
| `status` | Показать read-only состояние контейнеров и сокетов |
| `tune` / `untune` | Применить или восстановить сетевые sysctl |
| `rollback` | Остановить только созданные мастером контейнеры |
| `rollback-host` | Дополнительно восстановить UFW и tuning |

Полная справка:

```bash
./remnawave-edge-oneclick.sh --help
```

## Последовательность в Panel

Мастер сам останавливается в нужных точках. Общая последовательность:

1. Создать новый Config Profile из защищённого
   `/opt/remnawave-edge/private/config-profile.ready.json`.
2. Создать Node на предложенном control-plane порту и получить `SECRET_KEY`.
3. Запустить стадию `node` и дождаться настоящей Panel mTLS-сессии.
4. Создать canary Internal Squad, пользователя и физические Hosts.
   У каждого физического Host включить `Hide Host` и добавить
   `XRAY_JSON` в `Exclude formats`: UUID-injector Backend 2.8.1 всё равно
   использует эти Host, но отдельные JSON-конфиги из них не генерируются.
5. Передать UUID Hosts стадии `template`.
6. Добавить готовый XRAY_JSON template и AUTO Host по сгенерированной памятке.
7. Выполнить `edge`, затем `verify-auth`.
8. Проверить Happ/INCY в TUN-режиме и только потом расширять аудиторию.

Точные имена inbound, Host visibility, SNI, port, fingerprint, path и template
показываются в файлах `PANEL-STAGE-1.txt` и `PANEL-STAGE-2.txt` внутри
защищённого каталога установки.

## Выбор транспортов и SNI

Во время `init` мастер отдельно спрашивает про self-SNI REALITY, внешний
REALITY, XHTTP и Hysteria2. Можно включить любой один транспорт или сочетание;
для каждого выбранного пути генерируется отдельный inbound и физический Host.
Рекомендуемый canary-набор — все четыре, после измерений можно убрать лишнее.

Отдельный Fragment/FinalMask Host по умолчанию выключен и предназначен только
для изолированного A/B-теста. Его fragment использует singular-поля
`length`/`delay`, совместимые с Xray 26.5.9 в Happ и с Node Xray 26.6.27.
Plural-поля `lengths`/`delays` на старом ядре приводят к ошибке запуска
`LengthMin can't be 0`.

Для внешнего REALITY пункт `Auto benchmark` выбирает не «вечный лучший SNI», а
лучший из доступных кандидатов именно с текущей ноды в момент установки. CDN
ответы региональны и могут меняться. Поэтому `verify` повторно проверяет target,
а пользовательские тесты из нужных российских сетей всё равно обязательны.
Обычный TLS/XHTTP на чужом имени мастер не предлагает: для него нужен
сертификат, соответствующий домену; чужое имя здесь применимо именно как
REALITY target/SNI.

## Клиентский RU-direct routing

Готовый XRAY_JSON template сохраняет DNS-перехват первым, после чего отправляет
напрямую с клиентского устройства:

- базово распознанный BitTorrent;
- Steam/STUN-порты `27015-27059,3478,4379-4380`;
- `geosite:category-ru`, Steam, Twitch, Apple, Xiaomi, Huawei и Android
  downloads;
- основные российские банки, государственные сервисы, маркетплейсы, доставку,
  VK/Mail.ru, Yandex, 2GIS, Wildberries, Ozon, Avito, Самокат, Купер,
  Мегамаркет, X5 и Золотое Яблоко;
- `geoip:ru` и локальные `geoip:private` адреса.

`geosite:category-ru` уже включает весь `.ru` и профильные категории банков,
государственных, retail- и e-commerce-сервисов; явные домены в шаблоне нужны
для важных `.com`, `.net`, `.tech` и региональных endpoints. Остальной трафик
остаётся за `RU_AUTO`. DIRECT означает, что соответствующий сервис видит
реальный IP пользователя. Распознавание зашифрованного или обфусцированного
BitTorrent не гарантируется самим Xray.

Короткие значения для автоматизации тоже поддерживаются:

```bash
RW_EXTERNAL_REALITY_TARGET=amd       # -> www.amd.com:443
RW_EXTERNAL_REALITY_TARGET=tesla     # -> www.tesla.com:443
RW_EXTERNAL_REALITY_TARGET=dl.google # -> dl.google.com:443
```

## Безопасность

- `SECRET_KEY`, REALITY private key, short ID, TLS private keys, UUID
  пользователей, готовые подписки и raw runtime config нельзя коммитить;
- закрытые файлы находятся в `/opt/remnawave-edge/private` с режимами
  `0700/0600`;
- мастер не печатает секреты или сгенерированный XHTTP path;
- Node API не является user-plane портом и не должен быть открыт всему миру;
- `rollback` не удаляет recovery data, сертификаты или DNS;
- перед `rollback-host` требуется отдельное подтверждение `RESTORE`.

Если secret когда-либо попал в Git history, недостаточно удалить файл —
перевыпустите Node secret в Panel до дальнейшего использования.
