#!/usr/bin/env bash
# .gitignore 실효성 검증
#
# "패턴이 파일에 적혀 있는가"가 아니라 "git이 실제로 무시하는가"를 본다.
# 전역 ignore(~/.config/git/ignore), 역패턴(!Sources/ 등), 우선순위가 얽히면
# 적혀 있어도 무시되지 않거나 그 반대인 경우가 생긴다.
#
# 사용: Scripts/check-gitignore.sh
# 종료코드 0 통과, 1 실패.

set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1

fail=0

# ── 1. 민감 경로가 실제로 무시되는가 ───────────────────────────────
PATTERNS=(
  ".env" ".env.local"
  "auth.json" "credentials.json" "token.json" "oauth_creds.json"
  "test.pem" "test.p12" "test.key" "test.p8"
  "id_rsa" "id_ed25519" ".netrc"
  "foo.token" "foo.secret" "foo.credentials"
  ".claude/x.json" ".codex/auth.json" ".gemini/x.json" ".grok/auth.json"
  ".config/opencode/x.json"
  "Cookies" "Login Data" "Local State" "x.keychain-db"
  "sessions/a.json" "codex-sessions/a.json"
  "oauth-x.json" "refresh-token.txt" "access-token.txt"
  "telegram-bot-token.txt" "discord-webhook.txt"
)
for p in "${PATTERNS[@]}"; do
  if ! git check-ignore -q -- "$p" 2>/dev/null; then
    echo "FAIL  .gitignore가 무시하지 않음: $p"
    fail=1
  fi
done

# ── 2. 이미 추적 중인 민감 파일이 있는가 ────────────────────────────
# .gitignore는 "이미 추적 중인 파일"을 막지 못한다. 한 번 커밋되면 계속 따라온다.
tracked=$(git ls-files | grep -iE \
  '(^|/)\.env($|\.)|\.(pem|p12|pfx|jks|keystore|key|p8|mobileprovision|provisionprofile|kdbx|age|gpg|asc)$|(^|/)(auth|credentials|token|oauth_creds)\.json$|(^|/)id_(rsa|ed25519)$|(^|/)\.netrc$|\.(token|tokens|secret|secrets|credentials)$|(^|/)(Cookies|Login Data|Web Data|Local State)$' \
  || true)
if [ -n "$tracked" ]; then
  echo "FAIL  민감 파일이 이미 추적 중 (.gitignore는 추적 중인 파일을 막지 못한다):"
  echo "$tracked" | sed 's/^/      /'
  echo "      조치: git rm --cached <파일> 후 커밋. 이미 푸시됐다면 해당 키를 먼저 폐기·교체한다."
  fail=1
fi

# ── 3. 프로바이더 홈 디렉터리 사본이 추적되는가 ──────────────────────
# 이 앱은 ~/.claude, ~/.codex, ~/.grok 등을 읽는다. 그 구조가 저장소로 복사되면 위험하다.
home_copy=$(git ls-files | grep -E '(^|/)\.(claude|codex|gemini|grok|kiro)/' || true)
if [ -n "$home_copy" ]; then
  echo "FAIL  프로바이더 홈 디렉터리 사본이 추적 중:"
  echo "$home_copy" | sed 's/^/      /'
  fail=1
fi

# ── 4. .gitignore 자체가 존재하는가 ─────────────────────────────────
if [ ! -f .gitignore ]; then
  echo "FAIL  .gitignore 파일이 없다"
  fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "OK    .gitignore 검증 통과 (${#PATTERNS[@]}개 패턴 + 추적 파일 점검)"
fi
exit "$fail"
