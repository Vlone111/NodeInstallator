# NodeInstallator

Один линейный установщик edge для Remnawave Panel `2.8.1`, Node `2.8.0` и
встроенного Xray `26.6.27`. Скрипт рассчитан на чистый Ubuntu/Debian-сервер:
меню и выбор транспортов отсутствуют.

## Что устанавливается

Всегда создаются четыре серверных inbound и инструкция ровно для пяти
физических Host:

1. VLESS RAW/TCP + REALITY self-SNI;
2. VLESS RAW/TCP + REALITY на измеренном внешнем target;
3. отдельный Host второго inbound с клиентским FinalMask/fragment;
4. VLESS XHTTP auto за обычным TLS/HTTP2;
5. Hysteria2 на UDP/443.

TCP/443 принимает HAProxy, а UDP/443 — Hysteria2. Xray и Caddy backend-порты
доступны только на loopback. Node API разрешается в UFW только с указанного
исходящего IPv4 панели. Caddy автоматически получает публичные сертификаты
Let's Encrypt и обслуживает локальный адаптивный cover-site без сторонних CDN.

Клиентский Xray JSON template предназначен для Happ/INCY в TUN-режиме. Он
перехватывает DNS, использует DoH/FakeDNS, проверяет пять путей через
`leastPing`, блокирует внутренний QUIC и отправляет российские сервисы,
`geoip:ru`, выбранные игровые порты и распознанный BitTorrent напрямую с
устройства.

AUTO выбирает физические Host только по пяти точным UUID:

```json
"selector": {
  "type": "uuids",
  "values": ["uuid-1", "uuid-2", "uuid-3", "uuid-4", "uuid-5"]
}
```

Поиск по Remark/regex не используется.

## Требования

- чистый Ubuntu или Debian, root и доступ к консоли хостера;
- публичный IPv4;
- два собственных домена с A-записями на этот IPv4;
- стабильный исходящий IPv4 Remnawave Panel;
- у хостера разрешены TCP/443, UDP/443 и TCP-порт Node API только от IP Panel;
- AAAA отсутствует, если на сервере нет рабочего глобального IPv6.

## Запуск

На чистом сервере достаточно одной команды:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Vlone111/NodeInstallator/main/remnawave-edge-oneclick.sh)
```

Установщик спросит два домена, IPv4 Node, IPv4 Panel, email ACME, порт API и
короткое имя Node. Затем он один раз покажет пять Host для создания в Panel,
скрыто примет `SECRET_KEY` и запросит UUID этих пяти Host. После этого останется
вставить готовый AUTO template и создать один видимый виртуальный AUTO Host.

Готовые файлы находятся в закрытом каталоге:

```text
/opt/remnawave-edge/private/config-profile.ready.json
/opt/remnawave-edge/private/xray-json-auto.ready.json
/opt/remnawave-edge/private/PANEL-HOSTS.txt
/opt/remnawave-edge/private/PANEL-AUTO.txt
```

В Panel необходимо включить `Serve JSON at base subscription`. Существующие
Response Rules и `happRouting` менять не нужно. Пользователь Happ/INCY только
обновляет обычную ссылку подписки.

## Автоматические действия

Установщик сам:

- устанавливает Docker и необходимые пакеты;
- закрепляет версии образов Node, HAProxy и Caddy;
- выбирает валидный региональный REALITY target из Google/AMD/Tesla;
- создаёт ключи, shortId и закрытый XHTTP path;
- включает и проверяет UFW, сохраняя SSH;
- получает и проверяет публичные сертификаты Caddy;
- применяет BBR, live `fq`, MTU probing и сетевые буферы;
- проверяет строгий JSON, Xray, Compose, HAProxy и Caddy;
- выполняет аутентифицированный тест всех пяти клиентских путей, включая
  отдельный FinalMask Host.

Сервисные команды сохранённой копии:

```bash
/opt/remnawave-edge/remnawave-edge-oneclick.sh verify
/opt/remnawave-edge/remnawave-edge-oneclick.sh verify-auth
/opt/remnawave-edge/remnawave-edge-oneclick.sh status
/opt/remnawave-edge/remnawave-edge-oneclick.sh selftest
```

## Важные свойства

- FinalMask находится только в отдельном пятом клиентском Host и никогда не
  вставляется в серверный inbound.
- У всех пяти физических Host: Visibility ON, Hide Host ON и исключён
  `XRAY_JSON`; injector всё равно добавляет их по UUID в AUTO.
- Виртуальный AUTO Host видим и остаётся только в `XRAY_JSON`.
- Fingerprint всех подходящих клиентов — `firefox`.
- Теги Host административные и на UUID-селектор не влияют.
- Скрипт не обещает абсолютную неуязвимость к блокировкам: canary-тест из
  нужных российских сетей всё равно обязателен.
- `SECRET_KEY`, REALITY private keys, shortId, UUID пользователей и содержимое
  `/opt/remnawave-edge/private` нельзя публиковать или коммитить.
