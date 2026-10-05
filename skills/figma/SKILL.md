---
name: figma
description: Доступ к макетам Figma — рендер нода в PNG и выгрузка node JSON (радиусы, паддинги, цвета, шрифты, тени, тексты) через REST API. Используй, когда пользователь даёт ссылку figma.com/design/... (обычно с node-id), просит «свёрстай/сделай как в фигме», «глянь макет», «возьми стили/размеры/цвета из Figma», или нужно свериться с дизайном. WebFetch по figma-ссылке даёт 403 — только этот скилл.
---

# Figma

Доступ к макетам Figma через REST API (`api.figma.com`). WebFetch по обычной
figma-ссылке возвращает **403** (нужна авторизация) — ходи только через этот скилл.

Всё делается скриптом `figma.sh` рядом с этим файлом:

```sh
bash ~/.claude/skills/figma/figma.sh <команда> <аргументы>
```

> ⚠️ Запускай через Bash с **`dangerouslyDisableSandbox: true`** — sandbox режет
> сеть к `api.figma.com` (иначе `curl (7) Failed to connect`).

## Команды

| Команда | Что делает |
|---|---|
| `get <target> [outdir]` | **Основной режим.** Рендерит PNG (scale 2) + сохраняет node JSON + печатает сводку токенов дизайна. `outdir` по умолчанию `./figma-out` |
| `img <target> [outdir] [scale]` | Только PNG |
| `node <target> [outfile]` | Только JSON нода (полный), сводка — в stderr |
| `sum <target>` | Только сводка токенов, без сохранения файлов |
| `me` | Проверить токен (кто я) |

`<target>` — либо **полная ссылка** Figma, либо **два аргумента** `<fileKey> <nodeId>`:

```sh
# по ссылке (кавычки обязательны — в URL есть & и ?):
bash ~/.claude/skills/figma/figma.sh get "https://www.figma.com/design/<FILE_KEY>/<Name>?node-id=18937-24686&m=dev" /tmp/figma

# по ключу+ноду:
bash ~/.claude/skills/figma/figma.sh get <FILE_KEY> 18937:24686 /tmp/figma
```

`node-id` из URL идёт с дефисом (`18937-24686`), в API — с двоеточием (`18937:24686`).
Скрипт конвертирует сам (и `%3A` → `:`).

## Типичный сценарий

**«Свёрстай как здесь <figma-ссылка>»** или **«глянь макет»**:

```sh
bash ~/.claude/skills/figma/figma.sh get "<ссылка>" /tmp/figma
```

Дальше:
- Открой PNG через **Read** — увидишь, как это выглядит.
- Сводка в выводе даёт готовые токены (size, radius, padding, gap, fills, effects, тексты
  с fontSize/weight/lineHeight/цветом).
- Полный `node_*.json` рядом — для точных значений (вложенные слои, все эффекты, переменные).

## Важно

- **JSON — источник правды по значениям**, а не глаз по PNG. Пример: радиус в JSON
  был `4`, хотя на уменьшенном превью казался круглее (замер по пикселям подтвердил 4).
- Цвета Figma в JSON — float 0..1; сводка уже переводит в hex (`#18181b`, `a=10%`).
- Сводка `text:` может показать и скрытые тексты-варианты компонента (например `"Normal"` /
  `"label"` у snackbar) — ориентируйся на видимый первым и сверяйся с PNG.

## Токен

Auth — Figma personal access token со scope **`file_content:read`** (без него `/images`
и `/files/.../nodes` отдают 403 «requires file_content:read scope»).

Токен берётся из env `FIGMA_TOKEN`, иначе из файла `~/.claude/skills/figma/.figma_token`. Заменить — перезаписать этот файл или задать
`FIGMA_TOKEN`.

## Заметки

- Зависимости: `curl`, `jq` (есть в системе).
- Скрипт сам сбрасывает прокси-переменные (sandbox-прокси рвёт TLS к figma).
