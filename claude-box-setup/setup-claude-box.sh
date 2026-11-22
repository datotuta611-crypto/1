#!/usr/bin/env bash
# setup-claude-box.sh — неинтерактивная установка Claude Code в Docker-песочнице.
#
# Запуск от root (создаст пользователя и установит всё ему):
#   CB_USER=dev GIT_NAME="Имя Фамилия" GIT_EMAIL="me@example.com" bash setup-claude-box.sh
# Запуск от обычного пользователя с доступом к Docker (установит ему же, CB_USER не нужен):
#   GIT_NAME="Имя Фамилия" GIT_EMAIL="me@example.com" bash setup-claude-box.sh
#
# Все переменные необязательны. CB_USER по умолчанию dev.
# Повторный запуск безопасен: файлы перезаписываются, образ пересобирается,
# вход по подписке (том claude-docker_claude_memory) сохраняется.
#
# Коды выхода: 0 — готово, 1 — ошибка, 2 — нет Docker или docker compose v2.
# Итоговые строки начинаются с "[setup] ИТОГ".

set -euo pipefail

log() { printf '[setup] %s\n' "$*"; }
die() { printf '[setup] ОШИБКА: %s\n' "$1" >&2; exit "${2:-1}"; }

user_setup() {
  set -euo pipefail
  [ "$(id -u)" != 0 ] || die "установка для root запрещена: контейнер должен работать от обычного пользователя"
  docker info >/dev/null 2>&1 || die "у пользователя $(id -un) нет доступа к Docker (нужна группа docker)"

  local D="$HOME/claude-docker" BIN="$HOME/.local/bin"
  mkdir -p "$D" "$BIN"

  cat > "$D/Dockerfile" <<'EOF'
FROM node:22-bookworm-slim

ARG USER_ID=1000
ARG GROUP_ID=1000

RUN apt-get update && apt-get install -y --no-install-recommends \
      git curl python3 ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code

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

  cat > "$D/docker-compose.yml" <<'EOF'
services:
  claude:
    build:
      context: .
      args:
        USER_ID: ${HOST_UID:-1000}
        GROUP_ID: ${HOST_GID:-1000}
    image: claude-agent
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

  printf 'HOST_UID=%s\nHOST_GID=%s\n' "$(id -u)" "$(id -g)" > "$D/.env"

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

  cat > "$BIN/claude-box" <<'EOF'
#!/usr/bin/env bash
# Claude Code в контейнере для одного проекта.
# claude-box [папка] [аргументы claude...]   (без папки — текущая)
# claude-box --update                        (пересобрать образ со свежим Claude Code)
set -euo pipefail
die() { echo "claude-box: $*" >&2; exit 1; }

[ "$(id -u)" != 0 ] || die "не запускайте под root"

if [ "${1:-}" = "--update" ]; then
  cd ~/claude-docker
  PROJECT_DIR=/nonexistent exec docker compose build --pull --no-cache
fi

dir=.
if [ $# -gt 0 ]; then
  case "$1" in
    /*|./*|../*|.|..|\~*)
      [ -d "$1" ] || die "папка $1 не найдена или к ней нет доступа"
      dir=$1; shift ;;
    *)
      if [ -d "$1" ]; then dir=$1; shift; fi ;;
  esac
fi
dir=$(realpath -e -- "$dir")

case "$HOME/" in "${dir%/}/"*) die "$dir — домашняя папка или выше, укажите папку проекта";; esac
[ "$(stat -c %u "$dir")" = "$(id -u)" ] || die "$dir принадлежит другому пользователю"

cd ~/claude-docker
PROJECT_DIR=$dir exec docker compose run --rm claude claude "$@"
EOF
  chmod +x "$BIN/claude-box"

  if ! grep -qs 'claude-box: PATH' "$HOME/.bashrc"; then
    printf '\nexport PATH="$HOME/.local/bin:$PATH"  # claude-box: PATH\n' >> "$HOME/.bashrc"
  fi

  log "сборка образа claude-agent (несколько минут)…"
  # PROJECT_DIR при сборке не используется, но compose требует его значение
  (cd "$D" && PROJECT_DIR=/nonexistent docker compose build --quiet) || die "сборка образа не удалась (вывод выше)"

  # Самопроверка во временной папке проекта
  mkdir -p "$HOME/.cache"
  local T out ver login
  T=$(mktemp -d "$HOME/.cache/claude-box-selftest.XXXXXX")
  out=$(cd "$D" && PROJECT_DIR="$T" docker compose run --rm -T claude sh -c \
        'pwd; touch selftest; if env | grep -q "^ANTHROPIC_"; then echo HAS_ANTHROPIC_ENV; fi' 2>/dev/null) \
    || { rm -rf "$T"; die "тестовый контейнер не запустился"; }
  [ "$(printf '%s\n' "$out" | head -1)" = "$T" ] || { rm -rf "$T"; die "внутри контейнера неверная рабочая папка: $out"; }
  [ "$(stat -c %u "$T/selftest" 2>/dev/null)" = "$(id -u)" ] || { rm -rf "$T"; die "файлы из контейнера получают чужого владельца"; }
  case "$out" in *HAS_ANTHROPIC_ENV*) rm -rf "$T"; die "в контейнер попадает ANTHROPIC_* — уберите из claude.env";; esac

  ver=$("$BIN/claude-box" "$T" --version </dev/null 2>/dev/null | tail -1) || { rm -rf "$T"; die "claude-box не запускается"; }
  if "$BIN/claude-box" "$T" auth status </dev/null 2>/dev/null | grep -q '"loggedIn": *true'; then
    login="выполнен"
  else
    login="НЕ выполнен — нужен человек: claude-box <папка проекта> auth login"
  fi
  rm -rf "$T"

  log "ИТОГ: готово"
  log "ИТОГ: пользователь: $(id -un) (uid $(id -u)), папка: $D"
  log "ИТОГ: команда: $BIN/claude-box"
  log "ИТОГ: Claude Code: $ver"
  log "ИТОГ: вход по подписке: $login"
}

command -v docker >/dev/null 2>&1 \
  || die "Docker не установлен: поставьте Docker Engine и docker-compose-plugin по https://docs.docker.com/engine/install/" 2
docker compose version >/dev/null 2>&1 \
  || die "нет docker compose v2: поставьте пакет docker-compose-plugin" 2

if [ "$(id -u)" = 0 ]; then
  CB_USER=${CB_USER:-dev}
  [ "$CB_USER" != root ] || die "CB_USER не может быть root"
  getent group docker >/dev/null || die "в системе нет группы docker (Docker установлен нестандартно, например через snap)"
  if ! id "$CB_USER" >/dev/null 2>&1; then
    useradd -m -s /bin/bash "$CB_USER"
    log "создан пользователь $CB_USER без пароля (вход: sudo -iu $CB_USER или по SSH-ключу)"
  fi
  usermod -aG docker "$CB_USER"
  exec runuser -u "$CB_USER" -- env GIT_NAME="${GIT_NAME:-}" GIT_EMAIL="${GIT_EMAIL:-}" \
    bash -c "$(declare -f log die user_setup); user_setup"
fi

user_setup
