#!/usr/bin/env bash
# setup-claude-box.sh — неинтерактивная установка Claude Code в Docker-песочнице.
#
# Запуск от root (создаст пользователя и установит всё ему):
#   CB_USER=dev GIT_NAME="Имя Фамилия" GIT_EMAIL="me@example.com" bash setup-claude-box.sh
# Запуск от обычного пользователя с доступом к Docker (установит ему же, CB_USER не нужен):
#   GIT_NAME="Имя Фамилия" GIT_EMAIL="me@example.com" bash setup-claude-box.sh
#
# Все переменные необязательны. CB_USER по умолчанию dev.
# CB_FIX_VOLUME_OWNER=1 — только после решения человека: передать текущему
# пользователю том настроек Claude, который принадлежит другому UID.
#
# У каждого пользователя свои образ (claude-agent-<имя>) и том настроек
# (claude-box-<имя>_claude_memory). Повторный запуск безопасен. Сгенерированные
# файлы перезаписываются; если файл правили вручную, старая версия сохраняется
# рядом как <файл>.bak-<дата>. Вход по подписке и настройки Claude сохраняются.
#
# Коды выхода: 0 — готово, 1 — ошибка, 2 — нет Docker или docker compose v2.
# Итоговые строки начинаются с "[setup] ИТОГ".

set -Eeuo pipefail

log() { printf '[setup] %s\n' "$*"; }
die() { printf '[setup] ОШИБКА: %s\n' "$1" >&2; exit "${2:-1}"; }
on_err() { die "команда завершилась с кодом $1 (строка $2): $3"; }

# put <файл> <права>: записать содержимое из stdin; ручные правки сохранить в .bak
put() {
  local f=$1 mode=$2 tmp
  tmp=$(mktemp "$f.new.XXXXXX")
  cat > "$tmp"
  chmod "$mode" "$tmp"
  if [ -f "$f" ] && ! cmp -s "$tmp" "$f"; then
    local bak
    bak="$f.bak-$(date +%Y%m%d-%H%M%S)"
    cp -p "$f" "$bak"
    log "$f изменён (ручная правка или прежняя версия установщика), старая копия: $bak"
  fi
  mv -f "$tmp" "$f"
}

user_setup() {
  set -Eeuo pipefail
  trap 'on_err $? $LINENO "$BASH_COMMAND"' ERR
  [ "$(id -u)" != 0 ] || die "установка для root запрещена: контейнер должен работать от обычного пользователя"
  docker info >/dev/null 2>&1 || die "у пользователя $(id -un) нет доступа к Docker (нужна группа docker)"

  local D="$HOME/claude-docker" BIN="$HOME/.local/bin" SLUG PROJ IMG VOL
  mkdir -p "$D" "$BIN"

  # Имена образа и тома — свои для каждого пользователя сервера
  SLUG=$(id -un | tr -cs 'a-z0-9' '-' | sed 's/^-*//; s/-*$//')
  [ -n "$SLUG" ] || SLUG="u$(id -u)"
  PROJ="claude-box-$SLUG" IMG="claude-agent-$SLUG" VOL="claude-box-${SLUG}_claude_memory"

  put "$D/Dockerfile" 644 <<'EOF'
FROM node:22-bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
      git curl python3 ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code

ARG USER_ID=1000
ARG GROUP_ID=1000

# ID 0 (root на хосте) пропускаем; -o допускает ID, уже занятый в образе
RUN if [ "$GROUP_ID" != "0" ]; then groupmod -o -g "$GROUP_ID" node; fi \
 && if [ "$USER_ID" != "0" ]; then usermod -o -u "$USER_ID" node; fi

ENV CLAUDE_CONFIG_DIR=/home/node/.claude \
    DISABLE_AUTOUPDATER=1

RUN mkdir -p /home/node/.claude && chown -R node:node /home/node

USER node
WORKDIR /home/node
CMD ["claude"]
EOF

  put "$D/docker-compose.yml" 644 <<'EOF'
# Сгенерировано setup-claude-box.sh. Свои настройки (например, лимиты)
# пишите в docker-compose.override.yml рядом: установщик его не трогает.
services:
  claude:
    build:
      context: .
      args:
        USER_ID: ${HOST_UID:-1000}
        GROUP_ID: ${HOST_GID:-1000}
    image: ${CB_IMAGE:?run setup-claude-box.sh}
    env_file:
      - claude.env
    working_dir: ${PROJECT_DIR:?run via claude-box}
    volumes:
      - ${PROJECT_DIR:?run via claude-box}:${PROJECT_DIR}
      - claude_memory:/home/node/.claude
    deploy:
      resources:
        limits:
          cpus: "2.0"
          memory: 2G
    stdin_open: true
    tty: true

volumes:
  claude_memory:
EOF

  printf 'COMPOSE_PROJECT_NAME=%s\nCB_IMAGE=%s\nCB_VOLUME=%s\nHOST_UID=%s\nHOST_GID=%s\n' \
    "$PROJ" "$IMG" "$VOL" "$(id -u)" "$(id -g)" > "$D/.env"

  # claude.env: только подпись git. Ключа API здесь быть не должно:
  # ANTHROPIC_API_KEY перекрывает вход по подписке.
  if [ -n "${GIT_NAME:-}" ] || [ -n "${GIT_EMAIL:-}" ]; then
    : > "$D/claude.env"
    if [ -n "${GIT_NAME:-}" ]; then
      printf 'GIT_AUTHOR_NAME=%s\nGIT_COMMITTER_NAME=%s\n' "$GIT_NAME" "$GIT_NAME" >> "$D/claude.env"
    fi
    if [ -n "${GIT_EMAIL:-}" ]; then
      printf 'GIT_AUTHOR_EMAIL=%s\nGIT_COMMITTER_EMAIL=%s\n' "$GIT_EMAIL" "$GIT_EMAIL" >> "$D/claude.env"
    fi
  elif [ -f "$D/claude.env" ]; then
    if grep -q '^ANTHROPIC_' "$D/claude.env"; then
      grep -v '^ANTHROPIC_' "$D/claude.env" > "$D/claude.env.tmp" || true
      mv "$D/claude.env.tmp" "$D/claude.env"
      log "из claude.env удалены переменные ANTHROPIC_* (они перекрывали бы подписку)"
    fi
  else
    : > "$D/claude.env"
  fi

  put "$BIN/claude-box" 755 <<'EOF'
#!/usr/bin/env bash
# Claude Code в контейнере для одного проекта.
#   claude-box <папка> [аргументы claude...]  терминальная сессия; папка обязательна («.» — текущая)
#   claude-box --vscode <папка>               подготовить папку к «Reopen in Container» в VS Code
#   claude-box --update                       пересобрать образ со свежим Claude Code
set -euo pipefail
die() { echo "claude-box: $*" >&2; exit 1; }

[ "$(id -u)" != 0 ] || die "не запускайте под root"

# check_dir <папка>: проверить папку проекта и напечатать её абсолютный путь
check_dir() {
  [ -n "${1:-}" ] || die "укажите папку проекта первым аргументом («.» — текущая)"
  [ -d "$1" ] || die "папка $1 не найдена или к ней нет доступа"
  local d s
  d=$(realpath -e -- "$1")
  case "$HOME/" in "${d%/}/"*) die "$d — домашняя папка или выше, укажите папку проекта";; esac
  [ "$(stat -c %u "$d")" = "$(id -u)" ] || die "$d принадлежит другому пользователю"
  # Папка без своего .git, но с git-репозиториями внутри (до 3 уровней) —
  # скорее всего, папка с несколькими проектами. Проекты без git так не распознать.
  if [ ! -e "$d/.git" ] && [ "${CLAUDE_BOX_ALLOW_PARENT:-}" != 1 ]; then
    s=$(find "$d" -mindepth 1 -maxdepth 4 -name node_modules -prune -o -name .git -print -quit 2>/dev/null || true)
    if [ -n "$s" ]; then
      die "$d похожа на папку с несколькими проектами (внутри есть репозиторий ${s%/.git}). Укажите один проект. Если это действительно один проект: CLAUDE_BOX_ALLOW_PARENT=1 claude-box …"
    fi
  fi
  printf '%s\n' "$d"
}

# envval <имя>: значение из ~/claude-docker/.env (его пишет установщик)
envval() { sed -n "s/^$1=//p" ~/claude-docker/.env 2>/dev/null | head -1; }

case "${1:-}" in
  --update)
    cd ~/claude-docker
    PROJECT_DIR=/nonexistent exec docker compose build --pull --no-cache
    ;;
  --vscode)
    dir=$(check_dir "${2:-}") || exit 1
    img=$(envval CB_IMAGE); vol=$(envval CB_VOLUME)
    [ -n "$img" ] && [ -n "$vol" ] || die "нет ~/claude-docker/.env — сначала запустите setup-claude-box.sh"
    mkdir -p "$dir/.devcontainer/claude-box"
    cat > "$dir/.devcontainer/claude-box/devcontainer.json" <<JSON
{
  "name": "claude-box",
  "image": "$img",
  "remoteUser": "node",
  "updateRemoteUserUID": false,
  "workspaceMount": "source=\${localWorkspaceFolder},target=\${localWorkspaceFolder},type=bind",
  "workspaceFolder": "\${localWorkspaceFolder}",
  "mounts": ["source=$vol,target=/home/node/.claude,type=volume"],
  "runArgs": ["--env-file", "$HOME/claude-docker/claude.env", "--cpus", "2", "--memory", "2g"],
  "customizations": {
    "vscode": {
      "extensions": ["anthropic.claude-code"],
      "settings": { "claudeCode.initialPermissionMode": "default" }
    }
  }
}
JSON
    if [ -d "$dir/.git" ]; then
      mkdir -p "$dir/.git/info"
      grep -qxF '/.devcontainer/claude-box/' "$dir/.git/info/exclude" 2>/dev/null \
        || echo '/.devcontainer/claude-box/' >> "$dir/.git/info/exclude"
    fi
    echo "claude-box: готово: $dir/.devcontainer/claude-box/devcontainer.json"
    echo "claude-box: в VS Code: Remote-SSH → Open Folder $dir → Dev Containers: Reopen in Container"
    exit 0
    ;;
esac

dir=$(check_dir "${1:-}") || exit 1
shift
cd ~/claude-docker
PROJECT_DIR=$dir exec docker compose run --rm claude claude "$@"
EOF

  if ! grep -qs 'claude-box: PATH' "$HOME/.bashrc"; then
    printf '\nexport PATH="$HOME/.local/bin:$PATH"  # claude-box: PATH\n' >> "$HOME/.bashrc"
  fi

  log "сборка образа $IMG (несколько минут)…"
  # PROJECT_DIR при сборке не используется, но compose требует его значение
  (cd "$D" && PROJECT_DIR=/nonexistent docker compose build --quiet) || die "сборка образа не удалась (вывод выше)"

  # Самопроверка во временной папке проекта
  mkdir -p "$HOME/.cache"
  local T out ver st method login mode vowner
  T=$(mktemp -d "$HOME/.cache/claude-box-selftest.XXXXXX")

  # Том настроек с другим владельцем: в нём могут быть чужие данные входа и
  # история сессий. Передаём его только по явному решению человека.
  vowner=$(cd "$D" && PROJECT_DIR="$T" docker compose run --rm -T claude stat -c %u /home/node/.claude 2>/dev/null) \
    || { rm -rf "$T"; die "тестовый контейнер не запустился"; }
  if [ "$vowner" != "$(id -u)" ]; then
    if [ "${CB_FIX_VOLUME_OWNER:-}" != 1 ]; then
      rm -rf "$T"
      die "том $VOL принадлежит uid $vowner, а установка идёт для $(id -un) (uid $(id -u)). В томе могут быть данные входа и история сессий другого человека. Решение за человеком: если это ваш прежний том — повторите установку с CB_FIX_VOLUME_OWNER=1; чтобы начать с чистого тома — выполните docker volume rm $VOL и повторите установку"
    fi
    (cd "$D" && PROJECT_DIR="$T" docker compose run --rm -T --user 0:0 claude \
       chown -R "$(id -u):$(id -g)" /home/node/.claude) >/dev/null 2>&1 \
      || { rm -rf "$T"; die "не удалось сменить владельца тома $VOL"; }
    log "том $VOL: владелец изменён с uid $vowner на $(id -un) (uid $(id -u)) по CB_FIX_VOLUME_OWNER=1"
  fi

  out=$(cd "$D" && PROJECT_DIR="$T" docker compose run --rm -T claude sh -c \
        'pwd; touch selftest; if env | grep -q "^ANTHROPIC_"; then echo HAS_ANTHROPIC_ENV; fi' 2>/dev/null) \
    || { rm -rf "$T"; die "тестовый контейнер не запустился"; }
  [ "$(printf '%s\n' "$out" | head -1)" = "$T" ] || { rm -rf "$T"; die "внутри контейнера неверная рабочая папка: $out"; }
  [ "$(stat -c %u "$T/selftest" 2>/dev/null)" = "$(id -u)" ] || { rm -rf "$T"; die "файлы из контейнера получают чужого владельца"; }
  case "$out" in *HAS_ANTHROPIC_ENV*) rm -rf "$T"; die "в контейнер попадает ANTHROPIC_* — уберите из claude.env и docker-compose.override.yml";; esac

  # Режим по умолчанию Manual: правки файлов показываются диффом и ждут подтверждения.
  # Уже заданный пользователем режим не меняем.
  mode=$(cd "$D" && PROJECT_DIR="$T" docker compose run --rm -T claude node -e '
    const fs = require("fs"), p = process.env.CLAUDE_CONFIG_DIR + "/settings.json";
    let s = {};
    try { s = JSON.parse(fs.readFileSync(p, "utf8")); }
    catch (e) { if (e.code !== "ENOENT") { console.log("BROKEN"); process.exit(0); } }
    s.permissions = s.permissions || {};
    if (!s.permissions.defaultMode) {
      s.permissions.defaultMode = "default";
      fs.writeFileSync(p, JSON.stringify(s, null, 2) + "\n");
    }
    console.log(s.permissions.defaultMode);' 2>/dev/null) \
    || { rm -rf "$T"; die "не удалось записать настройки Claude в том"; }
  [ "$mode" != BROKEN ] || { rm -rf "$T"; die "~/.claude/settings.json в томе повреждён (не JSON)"; }

  ver=$("$BIN/claude-box" "$T" --version </dev/null 2>/dev/null | tail -1) || { rm -rf "$T"; die "claude-box не запускается"; }
  st=$("$BIN/claude-box" "$T" auth status </dev/null 2>/dev/null || true)
  method=$(printf '%s\n' "$st" | sed -n 's/.*"authMethod": *"\([^"]*\)".*/\1/p' | head -1)
  rm -rf "$T"
  case "$method" in
    claude.ai)   login="выполнен (подписка Claude)" ;;
    none|"")     login="НЕ выполнен — нужен человек: claude-box <папка проекта> auth login" ;;
    oauth_token) login="выполнен по токену CLAUDE_CODE_OAUTH_TOKEN (подписка), а не через auth login" ;;
    *)           login="ВНИМАНИЕ: вход не по подписке (authMethod: $method)" ;;
  esac

  log "ИТОГ: готово"
  log "ИТОГ: пользователь: $(id -un) (uid $(id -u)), папка: $D"
  log "ИТОГ: образ: $IMG, том настроек Claude: $VOL"
  log "ИТОГ: команда: $BIN/claude-box"
  log "ИТОГ: Claude Code: $ver"
  log "ИТОГ: вход: $login"
  case "$mode" in
    default|manual) log "ИТОГ: режим по умолчанию: Manual (правки показываются диффом и ждут подтверждения)" ;;
    *)              log "ИТОГ: ВНИМАНИЕ: режим по умолчанию $mode, правки могут записываться без подтверждения" ;;
  esac
  log "ИТОГ: внимание: $(id -un) в группе docker — это права уровня root на этом сервере"
}

command -v docker >/dev/null 2>&1 \
  || die "Docker не установлен: поставьте Docker Engine и docker-compose-plugin по https://docs.docker.com/engine/install/" 2
docker compose version >/dev/null 2>&1 \
  || die "нет docker compose v2: поставьте пакет docker-compose-plugin" 2

if [ "$(id -u)" = 0 ]; then
  trap 'on_err $? $LINENO "$BASH_COMMAND"' ERR
  CB_USER=${CB_USER:-dev}
  [ "$CB_USER" != root ] || die "CB_USER не может быть root"
  [[ "$CB_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "недопустимое имя пользователя: $CB_USER"
  getent group docker >/dev/null || die "в системе нет группы docker (Docker установлен нестандартно, например через snap)"
  if ! id "$CB_USER" >/dev/null 2>&1; then
    if getent group "$CB_USER" >/dev/null; then
      useradd -m -s /bin/bash -g "$CB_USER" "$CB_USER"
    else
      useradd -m -s /bin/bash "$CB_USER"
    fi
    log "создан пользователь $CB_USER без пароля (вход: sudo -iu $CB_USER или по SSH-ключу)"
  fi
  usermod -aG docker "$CB_USER"
  rc=0
  runuser -u "$CB_USER" -- env GIT_NAME="${GIT_NAME:-}" GIT_EMAIL="${GIT_EMAIL:-}" \
    CB_FIX_VOLUME_OWNER="${CB_FIX_VOLUME_OWNER:-}" \
    bash -c "$(declare -f log die on_err put user_setup); user_setup" || rc=$?
  case "$rc" in
    0|1|2) exit "$rc" ;;
    *)     die "не удалось выполнить установку от имени $CB_USER (код $rc)" ;;
  esac
fi

user_setup
