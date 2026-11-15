# Friday 설치

Friday(회사용 AI 창구)를 리눅스 서버에 설치하거나 업그레이드하는 스크립트입니다. Friday 본체와 설치 묶음은 비공개 저장소에 있고, 스크립트가 실행 중에 **읽기 전용 GitHub 토큰**을 물어 받아 옵니다.

## 설치·업그레이드

```bash
curl -fsSLO https://raw.githubusercontent.com/daecheol-private/public/main/frdy/frdy-setup.sh
```

```bash
sudo bash frdy-setup.sh
```

`curl`이 없으면 `wget -q https://raw.githubusercontent.com/daecheol-private/public/main/frdy/frdy-setup.sh`로 받습니다.

스크립트가 묻는 것만 답하면 나머지는 알아서 합니다.

| 묻는 것 | 언제 |
|---|---|
| GitHub 토큰(화면에 안 보임) | 늘 |
| 설치할 버전 확인 | 늘 — 가장 새 Release |
| 접속 이름·IP, 구독 연결 켜기, 동시 구독 실행 수 | 처음 설치 |
| 첫 관리자(`admin`) 비밀번호 | 처음 설치 |
| 매일 백업 예약 | 처음 설치 |

이미 설치된 서버에서 같은 명령을 실행하면 **업그레이드**합니다. 설정(`/opt/frdy/.env`)과 데이터는 그대로이고, 데이터베이스를 바꾸기 전에 자동으로 백업합니다.

## 준비

- x86_64 리눅스, Docker Engine과 Compose 플러그인(`docker compose`), `curl`, 인터넷(GitHub)
- `/var/tmp`에 빈 곳 2GB 이상
- **GitHub 토큰**: GitHub → Settings → Developer settings → Personal access tokens → Fine-grained tokens → Generate. Resource owner `daecheol-private`, Repository access는 `frdy` 하나만, Permissions는 **Contents: Read-only**, 만료는 짧게(예: 7일). 토큰은 어디에도 저장되지 않고 받은 뒤 지워집니다.

## 옵션

```text
sudo bash frdy-setup.sh --version v1.0.0.dev2   # 정한 버전
sudo bash frdy-setup.sh --dir /srv/frdy         # 다른 설치 폴더(기본 /opt/frdy)
sudo GH_TOKEN=... bash frdy-setup.sh --yes      # 묻지 않고 기본값(관리자 비밀번호는 무작위)
```

설치가 끝나면 브라우저에서 `https://<접속 이름>:9443`로 들어가 `admin`으로 로그인합니다. 상태 보기:

```bash
sudo docker compose -f /opt/frdy/compose.yaml exec api frdy-admin status
```
