# Подготовка планшета: iOS 9 в 2026 году

Заметки по тому, как довести iPad mini 1 (iOS 9.3.5) до состояния «есть терминал, SSH и можно ставить
свои приложения». Всё ниже проверено 28–29 сентября 2026.

## Сайдлоад с Apple ID больше не работает

Sideloadly, Impactor и подобные подписывают IPA бесплатным Apple ID. Приложение при этом ставится, но
на iOS 9 не проходит «Verify App»: в syslog планшета
`online-auth-agent: SecTrustEvaluate [leaf AnchorTrusted] … Could not verify the CMS blob, error -25293`.
Ответ сервера проверки Apple (ppq.apple.com) подписан цепочкой, которой iOS 9 не доверяет. Это не сеть,
не часы и не инструмент. Sideloadly 0.60 вдобавок падает с «Guru Meditation … Invalid file».

## Что работает: Carbon

- Открыть в Safari **на самом планшете** `http://carbon.sep.lol`, нажать Run. Это WebKit‑эксплойт для
  всех 32‑битных устройств на iOS 8.0–9.3.6, компьютер и Apple ID не нужны. На A5 может потребоваться
  2–3 попытки.
- На той же странице есть «Install certs» — обновлённые корневые сертификаты, без них половина сайтов
  и часть Cydia не открываются.
- Для 9.3.5/9.3.6 джейлбрейк полупривязанный, untether ставится отдельно: пакет
  `com.staturnz.iocaste` из репозитория `https://lukezgd.github.io/repo` (в Cydia: «iocaste untether»).
  Ставится 1–5 минут, во время установки Cydia не закрывать. После перезагрузки джейлбрейк остаётся.
- Никогда не делать «Erase All Content and Settings» на джейлбрейкнутом устройстве.

## Cydia из России

`apt.saurik.com` (основной репозиторий) живёт на CloudFront и из сетей РФ не отвечает — Cydia виснет
на «The request timed out». Нужен прокси: на планшете в настройках Wi‑Fi → HTTP Proxy → Manual (или PAC).
Проще всего дать планшету SSH‑туннель до своего сервера с локальным tinyproxy:
`autossh -N -L 127.0.0.1:8118:127.0.0.1:8118 root@server` в LaunchDaemon от пользователя mobile,
а в Wi‑Fi прокси `127.0.0.1:8118`. Для apt: `/etc/apt/apt.conf.d/99proxy`.

## Пакеты, которые стоит поставить

Через Cydia или `dpkg -i` по SSH (в Cydia нет `apt-get`, пока не поставлен `apt7`):

`openssh`, `apt7` (+ `berkeleydb`), `coreutils`, `curl`, `wget`, `nano`,
`com.officialscheduler.mterminal` (MTerminal, терминал для iOS 7–9), `com.linusyang.mosh`, `autossh`, `rsync`.

Индексы репозиториев можно скачать на Mac и разрешить зависимости самому
(`http://apt.saurik.com/dists/ios/1290.11/main/binary-iphoneos-arm/Packages.bz2`,
`http://apt.thebigboss.org/repofiles/cydia/dists/stable/main/binary-iphoneos-arm/Packages.bz2`).

OpenSSH на планшете — версии 6.7: с современным sshd совместим, но не знает
`StrictHostKeyChecking=accept-new`. Для входа с Mac нужен `-o HostKeyAlgorithms=+ssh-rsa`.

## Системный раздел

Корневой раздел 2 ГБ, после джейлбрейка свободно ~90 МБ, и iOS показывает «Storage Almost Full», хотя раздел
данных пустой. Carbon ставит `/.cydia_no_stash`, Cydia сама ничего не переносит. Помогает ручной перенос
на раздел данных с симлинками: `/usr/share` (75 МБ), `/Library/Wallpaper` (37), `/Library/Ringtones` (18),
`/usr/include` (3) → `/var/db/stash/…`. Пакет vim (6 МБ) и подобное ставить не стоит.

## Доступ с Mac по USB

```bash
brew install libimobiledevice
iproxy 2222 22 &
ssh -o HostKeyAlgorithms=+ssh-rsa -p 2222 root@localhost     # пароль по умолчанию alpine, сразу сменить
```

`ideviceinstaller list` показывает установленные приложения, `idevicesyslog --syslog-relay`
(именно с этим ключом на iOS 9) — системный лог, в котором видно, почему не проходит «Verify App»
или падает приложение.

## Установка своих приложений

Собранный бинарник подписывается `ldid -S`, кладётся в `/Applications/Name.app` вместе с `Info.plist`,
права `root:wheel 755`, затем `uicache`. Никакие сертификаты и профили не нужны. Тулчейн — в README.
