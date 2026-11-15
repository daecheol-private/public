#!/usr/bin/env bash
# Friday 한 번에 설치·업그레이드 (2026-11-15). GitHub Release에서 설치 묶음을 받아 검사하고, 처음이면 설정(.env)을
# 묻고 만든 뒤, 묶음 안의 install.sh로 설치한다. 이미 설치된 곳에서는 업그레이드한다(.env·데이터는 그대로).
#
#   curl -fsSLO https://raw.githubusercontent.com/daecheol-private/public/main/frdy/frdy-setup.sh
#   sudo bash frdy-setup.sh [--version TAG] [--dir DIR] [--yes]
#
#   --version  설치할 Release 태그(예: v1.0.0.dev2). 없으면 가장 새 Release(미리 보기 포함)
#   --dir      설치 폴더(기본 /opt/frdy)
#   --repo     설치 묶음이 있는 저장소(기본 daecheol-private/frdy)
#   --yes      묻지 않고 기본값으로(토큰은 GH_TOKEN 환경 변수로, 관리자 비밀번호는 무작위 — 첫 로그인 때 바꿈)
#
# 묻는 것: GitHub 토큰(화면에 안 보임 — 저장소가 비공개라서), 버전 확인, 처음 설치면 접속 이름·IP·구독 켜기·
# 동시 구독 실행 수·관리자 비밀번호·매일 백업 예약. 토큰은 어디에도 저장하지 않고 받은 뒤 지운다.
# 필요한 것: x86_64 리눅스, Docker와 Docker Compose v2, curl, sha256sum, tar. 받은 파일은 /var/tmp에 두었다가 지운다.
set -euo pipefail

REPO="${FRDY_REPO:-daecheol-private/frdy}"
DIR=/opt/frdy
WANT=""
YES=no
API=https://api.github.com

say()  { printf '%s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
die()  { printf '\n[중단] %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --version) WANT="${2:-}"; shift 2 ;;
        --dir) DIR="${2:-}"; shift 2 ;;
        --repo) REPO="${2:-}"; shift 2 ;;
        --yes|-y) YES=yes; shift ;;
        -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "모르는 옵션: $1 (--help)" ;;
    esac
done
[ -n "$DIR" ] || die "--dir이 비었습니다"

# ---- 입력: 파이프로 받아 실행해도(curl … | sudo bash) 터미널에서 묻는다 -----------------------------------------
TTY=/dev/tty
if [ "$YES" = no ] && ! { : < "$TTY"; } 2>/dev/null; then
    die "입력할 터미널이 없습니다. 터미널에서 실행하거나 --yes와 GH_TOKEN 환경 변수를 쓰세요"
fi

# 다시 물을 때의 안내: 묻는 중이면 터미널에, --yes면 기본값이 맞지 않는 것이라 멈춘다
again() {
    if [ "$YES" = yes ]; then die "$1 (--yes라 물을 수 없음: 터미널에서 실행하세요)"; fi
    say "$1" > "$TTY"
}
# ask "질문" "기본값" → REPLY (--yes면 기본값)
ask() {
    local q="$1" def="${2:-}"
    if [ "$YES" = yes ]; then REPLY="$def"; say "$q: $def (--yes)"; return 0; fi
    if [ -n "$def" ]; then printf '%s [%s]: ' "$q" "$def" > "$TTY"; else printf '%s: ' "$q" > "$TTY"; fi
    IFS= read -r REPLY < "$TTY" || REPLY=""
    REPLY="${REPLY#"${REPLY%%[![:space:]]*}"}"; REPLY="${REPLY%"${REPLY##*[![:space:]]}"}"
    [ -n "$REPLY" ] || REPLY="$def"
}
# yesno "질문" Y|N → 0(예)/1(아니오)
yesno() {
    local q="$1" def="$2" hint="Y/n"
    [ "$def" = N ] && hint="y/N"
    if [ "$YES" = yes ]; then say "$q: $([ "$def" = Y ] && echo 예 || echo 아니오) (--yes)"; [ "$def" = Y ]; return; fi
    while :; do
        printf '%s [%s]: ' "$q" "$hint" > "$TTY"
        IFS= read -r REPLY < "$TTY" || REPLY=""
        case "${REPLY:-$def}" in [Yy]|[Yy][Ee][Ss]|예|네) return 0 ;; [Nn]|[Nn][Oo]|아니오|아니요) return 1 ;; esac
        again "y 또는 n으로 답하세요"
    done
}
secret() {   # secret "질문" → REPLY, 화면에 안 보임 (숨기기를 먼저 켜고 묻는다 — 빨리 붙여 넣어도 안 보이게)
    { stty -echo < "$TTY"; } 2>/dev/null || true
    printf '%s: ' "$1" > "$TTY"
    IFS= read -r REPLY < "$TTY" || REPLY=""
    { stty echo < "$TTY"; } 2>/dev/null || true
    printf '\n' > "$TTY"
}
tty_echo() { { stty echo < /dev/tty; } 2>/dev/null || true; }
trap tty_echo EXIT
trap 'tty_echo; printf "\n[중단됨]\n" >&2; exit 130' INT TERM

# ---- 1. 이 서버 확인 --------------------------------------------------------------------------------------------
step "1/7 이 서버 확인"
[ "$(id -u)" = 0 ] || die "관리자 권한이 필요합니다: sudo bash $0 $*"
case "$(uname -m)" in x86_64|amd64) ARCH=amd64 ;; *) die "x86_64 서버만 됩니다(이 서버: $(uname -m))" ;; esac
for c in curl sha256sum tar sed awk; do command -v "$c" >/dev/null 2>&1 || die "'$c' 명령이 없습니다"; done
command -v docker >/dev/null 2>&1 || die "Docker가 없습니다. 먼저 Docker Engine과 Compose 플러그인을 설치하세요(docs/fortisoar.md 2장)"
docker info >/dev/null 2>&1 || die "Docker에 연결할 수 없습니다(꺼져 있음?): systemctl enable --now docker"
docker compose version >/dev/null 2>&1 || die "Docker Compose v2('docker compose')가 필요합니다"
FIRST=yes
CUR=""
if [ -f "$DIR/compose.yaml" ]; then
    FIRST=no
    CUR=$(sed -n 's/^FRDY_IMAGE_TAG=\(.*\)$/\1/p' "$DIR/.env" 2>/dev/null | tail -1 || true)
    say "이미 설치됨: $DIR (지금 버전 ${CUR:-알 수 없음}) → 업그레이드합니다. 설정(.env)과 데이터는 그대로입니다"
else
    say "새로 설치: $DIR"
fi
WORKROOT="${FRDY_SETUP_TMP:-/var/tmp}"
free_mb=$(df -Pm "$WORKROOT" 2>/dev/null | awk 'NR==2 {print $4}' || echo 0)
[ "${free_mb:-0}" -ge 2000 ] || die "$WORKROOT에 빈 곳이 2GB 이상 필요합니다(지금 ${free_mb}MB). FRDY_SETUP_TMP로 다른 곳을 고를 수 있습니다"
say "Docker $(docker version --format '{{.Server.Version}}' 2>/dev/null), $(docker compose version --short 2>/dev/null | sed 's/^/Compose /'), 빈 곳 ${free_mb}MB"

# ---- 2. GitHub 토큰 ------------------------------------------------------------------------------------------------
step "2/7 GitHub 토큰"
gh_code() { curl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $GH_TOKEN" "$API/repos/$REPO" || echo 000; }
if [ -n "${GH_TOKEN:-}" ]; then
    say "GH_TOKEN 환경 변수의 토큰을 씁니다"
    code=$(gh_code)
else
    [ "$YES" = no ] || die "--yes에서는 GH_TOKEN 환경 변수가 필요합니다"
    say "저장소($REPO)가 비공개라 읽기 전용 토큰이 필요합니다(Contents: Read-only). 붙여 넣어도 화면에 안 보입니다"
    say "PuTTY에서는 마우스 오른쪽 버튼이 붙여 넣기입니다"
    code=000
    for _ in 1 2 3; do
        secret "GitHub 토큰"; GH_TOKEN="$REPLY"
        [ -n "$GH_TOKEN" ] || { say "비었습니다"; continue; }
        code=$(gh_code)
        [ "$code" = 200 ] && break
        case "$code" in
            401) say "토큰이 틀렸거나 만료됐습니다(401). 다시 넣으세요" ;;
            403|404) say "이 토큰으로는 $REPO를 볼 수 없습니다($code). Resource owner·Repository access·Contents 권한을 확인하세요" ;;
            *) say "GitHub에 닿지 못했습니다($code). 인터넷·프록시를 확인하세요" ;;
        esac
    done
fi
[ "$code" = 200 ] || die "토큰으로 $REPO를 열 수 없습니다(HTTP $code)"
say "토큰 확인됨"
gh_get() { curl -fsSL -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json" "$API/repos/$REPO/$1"; }
# JSON을 키마다 줄로 나눠 읽는다(python·jq 없이)
lines() { sed -E 's/("(url|name|tag_name|draft|prerelease)": ?)/\n\1/g'; }

# ---- 3. 버전 고르기 -------------------------------------------------------------------------------------------------
step "3/7 버전"
if [ -n "$WANT" ]; then
    case "$WANT" in v*) ;; *) WANT="v$WANT" ;; esac
    REL=$(gh_get "releases/tags/$WANT") || die "Release $WANT가 없습니다"
    TAGNAME="$WANT"
else
    LIST=$(gh_get "releases?per_page=20") || die "Release 목록을 읽지 못했습니다"
    TAGNAME=$(printf '%s' "$LIST" | lines | awk -F'"' '
        /^"tag_name":/ {t=$4} /^"draft": ?false/ && t != "" && pick == "" {pick=t} END {print pick}')
    [ -n "$TAGNAME" ] || die "$REPO에 Release가 없습니다"
    REL=$(gh_get "releases/tags/$TAGNAME") || die "Release $TAGNAME을 읽지 못했습니다"
fi
VER="${TAGNAME#v}"
BUNDLE="frdy-$VER-$ARCH.tar"
ASSETS=$(printf '%s' "$REL" | lines | awk -F'"' '
    /^"url": ?"https:\/\/api\.github\.com\/repos\/[^"]*\/releases\/assets\/[0-9]+"/ {u=$4; next}
    /^"name":/ && u != "" {print u, $4; u=""}')
TAR_URL=$(printf '%s\n' "$ASSETS" | awk -v n="$BUNDLE" '$2 == n {print $1}')
SUM_URL=$(printf '%s\n' "$ASSETS" | awk -v n="$BUNDLE.sha256" '$2 == n {print $1}')
[ -n "$TAR_URL" ] && [ -n "$SUM_URL" ] || die "Release $TAGNAME에 $BUNDLE 또는 $BUNDLE.sha256이 없습니다"
if [ "$FIRST" = no ] && [ "$CUR" = "$VER-$ARCH" ]; then
    say "이미 $VER입니다."
    yesno "같은 버전을 다시 설치할까요" N || { say "그대로 둡니다"; exit 0; }
else
    say "Release $TAGNAME"
    yesno "Friday $VER을(를) ${CUR:+$CUR에서 올려 }설치할까요" Y || { say "그만둡니다"; exit 0; }
fi

# ---- 4. 받기·검사 ---------------------------------------------------------------------------------------------------
step "4/7 받기·검사(약 600MB, 몇 분)"
WORK=$(mktemp -d "$WORKROOT/frdy-setup.XXXXXX")
trap 'tty_echo; rm -rf "$WORK"' EXIT
fetch() { curl -fL --retry 3 -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/octet-stream" "$@"; }
fetch -sS -o "$WORK/$BUNDLE.sha256" "$SUM_URL" || die "검사값 파일을 받지 못했습니다"
fetch --progress-bar -o "$WORK/$BUNDLE" "$TAR_URL" || die "설치 묶음을 받지 못했습니다"
unset GH_TOKEN
(cd "$WORK" && sha256sum -c "$BUNDLE.sha256") || die "받은 파일의 검사값이 다릅니다(망가짐). 다시 실행하세요"
tar -xf "$WORK/$BUNDLE" -C "$WORK"
rm -f "$WORK/$BUNDLE"
SRC="$WORK/frdy-$VER-$ARCH"
[ -x "$SRC/install.sh" ] || die "묶음 안에 install.sh가 없습니다"

# ---- 5. 처음이면 설정(.env) ---------------------------------------------------------------------------------------
setenv() {   # setenv KEY VALUE — .env의 그 줄을 바꾸거나 끝에 더한다
    if grep -q "^$1=" "$DIR/.env"; then sed -i "s|^$1=.*|$1=$2|" "$DIR/.env"; else printf '%s=%s\n' "$1" "$2" >> "$DIR/.env"; fi
}
if [ "$FIRST" = yes ]; then
    step "5/7 설정"
    mkdir -p "$DIR"
    if [ -f "$DIR/.env" ]; then
        say "$DIR/.env가 이미 있어 그대로 씁니다(묻지 않음)"
    else
        def_name=$(hostname -f 2>/dev/null || true)
        [ -n "$def_name" ] || def_name=$(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || true)
        def_ip=$( { hostname -I 2>/dev/null || ip -4 -o addr show scope global 2>/dev/null | awk '{sub(/\/.*/, "", $4); print $4}'; } | awk 'NF {print $1; exit}' || true)
        mem_gb=$(awk '/^MemTotal:/ {printf "%d", $2 / 1048576}' /proc/meminfo 2>/dev/null || echo 0)
        def_slots=4; [ "${mem_gb:-0}" -ge 16 ] && def_slots=8; [ "${mem_gb:-0}" -lt 8 ] && def_slots=2
        say "사람들이 브라우저로 들어올 이름과 IP입니다. 인증서와 접속 주소에 들어갑니다"
        while :; do ask "접속 이름(도메인 또는 서버 이름)" "$def_name"; NAME="$REPLY"
            [[ "$NAME" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] && break; again "접속 이름은 글자·숫자·'.'·'-'만 됩니다('$NAME')"; done
        while :; do ask "접속 IP(없으면 -)" "${def_ip:--}"; IP="$REPLY"
            [ "$IP" = - ] && IP="" && break
            [[ "$IP" =~ ^[0-9A-Fa-f:.]+$ ]] && break; again "IP 모양이 아닙니다('$IP')"; done
        PORT=9443
        if command -v ss >/dev/null 2>&1 && ss -ltnH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$PORT\$"; then
            say "포트 $PORT를 이미 다른 프로그램이 씁니다"
            while :; do ask "쓸 포트" 9444; PORT="$REPLY"; [[ "$PORT" =~ ^[0-9]+$ ]] && [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] && break; again "1~65535의 숫자"; done
        fi
        if yesno "구독(Claude Code·Codex) 연결을 켤까요 — 끄면 API 키로만 씁니다" Y; then SUB=true; else SUB=false; fi
        SLOTS=$def_slots
        if [ "$SUB" = true ]; then
            say "동시에 돌리는 구독 요청 수입니다(하나에 메모리 200~250MB, 이 서버 메모리 ${mem_gb}GB)"
            while :; do ask "동시 구독 실행 수" "$def_slots"; SLOTS="$REPLY"; [[ "$SLOTS" =~ ^[0-9]+$ ]] && [ "$SLOTS" -ge 1 ] && [ "$SLOTS" -le 32 ] && break; again "1~32의 숫자"; done
        fi
        URL="https://$NAME:$PORT"
        say ""
        say "  설치 폴더   $DIR"
        say "  접속 주소   $URL${IP:+  (https://$IP:$PORT 로도)}"
        say "  인증서 이름 $NAME${IP:+, $IP} (자체 서명)"
        say "  구독 연결   $([ "$SUB" = true ] && echo "켬, 동시 $SLOTS" || echo 끔)"
        yesno "이대로 설치할까요" Y || { say "그만둡니다(아무것도 바꾸지 않았습니다)"; exit 0; }
        cp "$SRC/.env.example" "$DIR/.env"
        chmod 600 "$DIR/.env"
        setenv FRDY_SUBSCRIPTION_ENABLED "$SUB"
        setenv FRDY_PORT "$PORT"
        setenv FRDY_TLS_NAMES "$NAME${IP:+,$IP}"
        setenv FRDY_PUBLIC_URL "$URL"
        setenv FRDY_CLI_SLOTS "$SLOTS"
    fi
else
    step "5/7 설정 — 업그레이드라 그대로 둡니다($DIR/.env)"
fi

# ---- 6. 설치(묶음의 install.sh — 처음이면 관리자 비밀번호를 묻는다) ------------------------------------------------
step "6/7 설치"
if [ "$YES" = yes ]; then
    "$SRC/install.sh" "$DIR" < /dev/null
else
    "$SRC/install.sh" "$DIR" < "$TTY"
fi

# ---- 7. 매일 백업 예약(처음 설치 때만 묻는다) ------------------------------------------------------------------------
step "7/7 마무리"
if [ "$FIRST" = yes ]; then
    DOCKER=$(command -v docker)
    LINE="30 2 * * * $DOCKER compose -f $DIR/compose.yaml exec -T api frdy-admin backup --keep 7"
    if ! command -v crontab >/dev/null 2>&1; then
        say "crontab이 없어 백업 예약은 건너뜁니다(나중에: docker compose exec api frdy-admin backup --keep 7)"
    elif crontab -l 2>/dev/null | grep -q "frdy-admin backup"; then
        say "백업 예약이 이미 있습니다"
    elif yesno "매일 새벽 2시 30분에 백업(7개까지 남김)을 예약할까요" Y; then
        { crontab -l 2>/dev/null || true; printf '%s\n' "$LINE"; } | crontab -
        say "예약함: $LINE"
    fi
fi
URL=$(sed -n 's/^FRDY_PUBLIC_URL=\(.*\)$/\1/p' "$DIR/.env" 2>/dev/null | tail -1 || true)
say ""
say "끝. Friday $VER — 브라우저에서 ${URL:-https://<이 서버>:9443} (아이디 admin)"
say "상태 보기: docker compose -f $DIR/compose.yaml exec api frdy-admin status"
[ "$FIRST" = yes ] && say "다음: 관리 → 모델·계정에서 구독 계정을 만들고 [로그인]"
exit 0
