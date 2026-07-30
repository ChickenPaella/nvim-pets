#!/usr/bin/env bash
# Preflight + launcher for the nvim-pets Demo Day demo.
#
# Everything that can silently kill the demo is checked here, because the
# failure mode of this plugin is "nothing appears and no error is printed".
# The timings in the beat sheet are measured, not guessed — see README.md.
#
#   ./demo.sh          run the checks, print the beat sheet, launch nvim
#   ./demo.sh --check  run the checks only
#   ./demo.sh --warm   feed the pet up to 100 first

set -uo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO_FILE="$DEMO_DIR/demo.lua"
MOOD_FILE="${XDG_DATA_HOME:-$HOME/.local/share}/nvim/nvim-pets-mood.json"
PLUGIN_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/nvim/lazy/nvim-pets"

BREAK_LINE=42       # the line holding the ")" for beat 2
BREAK_COL=49        # column of that ")"

if [[ -t 1 ]]; then
  B=$'\033[1m'; R=$'\033[0m'; GRN=$'\033[32m'; YEL=$'\033[33m'; RED=$'\033[31m'; DIM=$'\033[2m'
else
  B=""; R=""; GRN=""; YEL=""; RED=""; DIM=""
fi

fails=0
warns=0
ok()   { printf '  %s✓%s %s\n' "$GRN" "$R" "$1"; }
warn() { printf '  %s!%s %s\n' "$YEL" "$R" "$1"; warns=$((warns+1)); }
bad()  { printf '  %s✗%s %s\n' "$RED" "$R" "$1"; fails=$((fails+1)); }

printf '\n%s── PREFLIGHT ──%s\n' "$B" "$R"

# 1. ImageMagick — without it the sprites never decode and nothing is drawn,
#    with no error message anywhere.
if command -v magick >/dev/null 2>&1; then
  ok "ImageMagick $(magick -version | head -1 | awk '{print $3}')"
else
  bad "ImageMagick 없음 → 스프라이트가 조용히 안 그려집니다. brew install imagemagick"
fi

# 2. Neovim >= 0.10 (nvim_win_text_height, which the blocked grid needs)
if command -v nvim >/dev/null 2>&1; then
  ok "Neovim $(nvim --version | head -1 | awk '{print $2}')"
else
  bad "nvim 없음"
fi

# 3. Terminal has to speak the Kitty Graphics Protocol.
if [[ -n "${KITTY_WINDOW_ID:-}" ]]; then
  ok "터미널: Kitty"
elif [[ "${TERM_PROGRAM:-}" == "WezTerm" || "${TERM_PROGRAM:-}" == "ghostty" ]]; then
  ok "터미널: ${TERM_PROGRAM}"
elif [[ -n "${TMUX:-}" ]]; then
  warn "tmux 안이라 부모 터미널을 알 수 없습니다. WezTerm / Kitty / Ghostty 인지 확인하세요"
else
  bad "TERM_PROGRAM='${TERM_PROGRAM:-<unset>}' — 그래픽이 안 나올 가능성이 큽니다"
fi

# 4. tmux has to forward both the graphics bytes and the focus events.
if [[ -n "${TMUX:-}" ]]; then
  if [[ "$(tmux show -gv allow-passthrough 2>/dev/null)" == "on" ]]; then
    ok "tmux allow-passthrough on"
  else
    bad "tmux allow-passthrough 가 off → 이미지가 안 나옵니다"
  fi
  if [[ "$(tmux show -gv focus-events 2>/dev/null)" == "on" ]]; then
    ok "tmux focus-events on"
  else
    warn "tmux focus-events 가 off → 창 전환 후 복귀 시 다시 그려지지 않습니다"
  fi
else
  ok "tmux 밖에서 실행 중 (passthrough 무관)"
fi

# 5. The installed plugin must be the build these claims are true for.
if [[ -d "$PLUGIN_DIR" ]]; then
  commit=$(git -C "$PLUGIN_DIR" rev-parse --short HEAD 2>/dev/null || echo "?")
  subject=$(git -C "$PLUGIN_DIR" log -1 --format=%s 2>/dev/null | cut -c1-46)
  ok "플러그인 $commit  ${DIM}${subject}${R}"
  if git -C "$PLUGIN_DIR" grep -q "tick_displaced" -- lua/pets/pet.lua 2>/dev/null; then
    ok "「서 있는 자리에 코드가 오면 비킨다」 수정 포함됨"
  else
    bad "eviction 수정이 없는 버전 → 「文字の上に乗りません」이 거짓이 됩니다. :Lazy update"
  fi
else
  bad "플러그인이 설치되지 않았습니다: $PLUGIN_DIR"
fi

# 6. lua_ls drives beat 2. Without it there is no error to react to.
if [[ -x "${XDG_DATA_HOME:-$HOME/.local/share}/nvim/mason/bin/lua-language-server" ]]; then
  ok "lua-language-server 설치됨 (BEAT 2 의 에러 판정용)"
else
  bad "lua-language-server 없음 → BEAT 2 동작 안 함. :MasonInstall lua-language-server"
fi

# 7. Report the number that will show up in beat 4.
h="?"
if [[ -f "$MOOD_FILE" ]]; then
  h=$(sed -n 's/.*"happiness":\([0-9]*\).*/\1/p' "$MOOD_FILE")
  label="sad"
  [[ "$h" -ge 25 ]] && label="bored"
  [[ "$h" -ge 50 ]] && label="content"
  [[ "$h" -ge 80 ]] && label="happy"
  if [[ "$h" -ge 50 ]]; then
    ok "현재 幸福度 ${h}/100 (${label}) — BEAT 4 에서 이 숫자가 나옵니다"
  else
    warn "현재 幸福度 ${h}/100 (${label}) — 낮습니다. --warm 또는 <leader>pf 를 몇 번"
  fi
else
  warn "mood 파일이 아직 없습니다. 첫 실행 시 80 에서 시작합니다"
fi

# 8. image.nvim's own health check catches a broken ImageMagick/luarock
#    chain, which is the most common silent failure. Slow, so it runs last.
printf '  %s·%s :checkhealth image 실행 중...\r' "$DIM" "$R"
hc=$(mktemp)
nvim --headless "+checkhealth image" "+w! $hc" +qa >/dev/null 2>&1
if [[ -s "$hc" ]]; then
  if grep -qE '^[[:space:]]*-[[:space:]]*ERROR' "$hc"; then
    bad ":checkhealth image 에 ERROR 있음 → 아래 확인                "
    grep -E '^[[:space:]]*-[[:space:]]*ERROR' "$hc" | head -3 | sed 's/^/      /'
  else
    ok ":checkhealth image 통과 (ERROR 없음)                         "
  fi
else
  warn ":checkhealth image 결과를 읽지 못했습니다. 수동 확인 필요    "
fi
rm -f "$hc"

# ── warm the mood up if asked ────────────────────────────────────────────
if [[ "${1:-}" == "--warm" ]]; then
  nvim --headless "+lua require('lazy').load({plugins={'nvim-pets'}}); for _ = 1, 4 do require('pets.mood').add(25) end" +qa >/dev/null 2>&1
  h=$(sed -n 's/.*"happiness":\([0-9]*\).*/\1/p' "$MOOD_FILE" 2>/dev/null)
  ok "幸福度를 ${h}/100 으로 올렸습니다"
fi

# ── verdict ─────────────────────────────────────────────────────────────
printf '\n'
if (( fails > 0 )); then
  printf '%s%s✗ %d개 항목이 시연을 막습니다.%s 먼저 해결하세요.\n\n' "$B" "$RED" "$fails" "$R"
elif (( warns > 0 )); then
  printf '%s%s! 경고 %d개.%s 진행은 가능합니다.\n\n' "$B" "$YEL" "$warns" "$R"
else
  printf '%s%s✓ 전부 통과.%s\n\n' "$B" "$GRN" "$R"
fi

# ── the beat sheet ──────────────────────────────────────────────────────
cat <<SHEET
${B}── 공유 전에 (순서대로) ──${R}
  1. 공유는 ${B}「탭」이 아니라 「창」 또는 「전체 화면」${R}
  2. 공유 시작 후 하단에서 ${B}최적화를 「동작(모션)」으로${R}
     ${DIM}기본값이면 프레임레이트가 낮아 6fps 스프라이트가 정지 이미지로 보입니다${R}
  3. nvim 을 열고 ${B}3초 기다리기${R}
     ${DIM}lua_ls 워크스페이스 로딩에 약 1.7초. 끝나기 전엔 BEAT 2 가 반응하지 않습니다${R}
  4. 알림 팝업이 떠 있으면 ${B}지우기${R}
     ${DIM}알림은 float 이라 펫이 그 아래로 들어가 가려질 수 있습니다${R}

${B}── 4비트 (괄호 안은 실측값) ──${R}
  ${B}(1)${R} <leader>pp                     ${DIM}(0.45초 후 등장)${R}
      커서를 코드 위로 옮기며
      ${DIM}「文字の間だけ歩いてます」「箱の中じゃなくて、コードの間に住んでます」${R}

  ${B}(2)${R} x                              ${DIM}(0.65초 후 「!?」· 1.9초 유지)${R}
      커서는 이미 ")" 위에 있습니다. ${B}누르고 나서 잠깐 말을 멈추세요${R}
      ${B}u${R}                              ${DIM}(0.65초 후 「yay!」· 1.9초 유지)${R}
      ${DIM}「エラーが0になった瞬間、これが出ます」${R}

  ${B}(3)${R} :PetsCount 4  →  <leader>pb    ${DIM}(0.47초 후 전원 출동)${R}
      ${DIM}「全員走ってきます。ここ、今週直したところです」${R}

  ${B}(4)${R} <leader>pf  →  :PetsStatus     ${DIM}(幸福度 ${h}/100)${R}
      ${DIM}「この数字、閉じても残ります。明日も続きです」${R}

${B}── 안 될 때 ──${R}
  · (2)가 반응 없음         → lua_ls 로딩 미완. 3초 기다렸다가 u 하고 다시 x
  · (3)에서 아무도 안 움직임 → 리드 펫이 아직 swipe 중(1.9초). 2초 뒤 다시 <leader>pb
  · 아무것도 안 보임        → :Pets 두 번(끄고 켜기). 그래도 안 되면 백업 녹화로
  · 잔상이 남음             → tmux 한계. :Pets 두 번. 슬라이드 09 에 있는 내용

SHEET

if [[ "${1:-}" == "--check" ]]; then
  exit $(( fails > 0 ? 1 : 0 ))
fi

if (( fails > 0 )); then
  printf '%s실패 항목이 있어 실행하지 않습니다. 무시하고 열려면: nvim %s%s\n\n' "$DIM" "$DEMO_FILE" "$R"
  exit 1
fi

printf '%sEnter 를 누르면 nvim 이 열립니다 (커서는 BEAT 2 의 ")" 위)%s' "$DIM" "$R"
read -r _

exec nvim "+call cursor($BREAK_LINE, $BREAK_COL)" "+normal! zz" "$DEMO_FILE"
