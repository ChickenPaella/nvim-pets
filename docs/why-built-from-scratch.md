# 왜 기존 라이브러리를 쓰지 않고 직접 만들었는가

> 대상 독자: 사내 동료. "vscode-pets 비슷한 게 이미 nvim용으로 있지 않나?"
> 라는 질문에 답하는 문서.

## 결론 한 줄

**가장 유명한 `pets.nvim`은 우리 환경(WezTerm + tmux)에서 동작하지 않는다.**
의존하는 렌더링 백엔드(`hologram.nvim`)가 사실상 방치 상태이고,
tmux/WezTerm의 그래픽 프로토콜 변화를 따라가지 못한다. 우리 nvim 환경에는
이미 `image.nvim`이 들어 있으므로(Markdown 이미지 미리보기 등),
그 위에 얇은 펫 레이어를 올리는 쪽이 의존성이 적고 유지보수도 쉽다.

---

## 후보 라이브러리 조사

### 1. `giusgad/pets.nvim` — 가장 알려진 옵션

- 기능: 강아지·고양이 등 여러 종 선택, 멀티펫, `:PetsNew` / `:PetsKillAll` 등.
- 렌더링: **`giusgad/hologram.nvim`** (`edluffy/hologram.nvim` 의 fork)에 100% 의존.
- 우리 환경 실측 결과:
  - WezTerm + tmux: 강아지 스프라이트 대신 **깨진 픽셀 덩어리**(RGBA 데이터의 단편으로 보이는 번개 모양)만 표시됨. 애니메이션 없음.
  - WezTerm 단독(tmux 밖): 동일 증상.
- 즉 **로컬에서 정상 시연 자체가 불가능**.

### 2. `edluffy/hologram.nvim` (백엔드)

- Lua로 Kitty Graphics Protocol을 직접 구현.
- 마지막 활발한 개발은 수년 전. README에 **"experimental"** 명시.
- 알려진 한계:
  - tmux passthrough(`\ePtmux;...\e\\` 래핑) 미지원 — tmux가 그래픽
    이스케이프 시퀀스를 그대로 삼킴.
  - 청크 전송(chunked transmission) / 이미지 ID 충돌 처리가 단순.
  - WezTerm 측의 Kitty 프로토콜 구현 변화에 미대응.
- pets.nvim의 깨진 렌더링은 이 한계의 직접적 결과.

### 3. `3rd/image.nvim` — 우리가 쓰는 백엔드

- Kitty/Sixel/Ueberzug 백엔드를 모두 지원.
- tmux passthrough를 **자동 처리**(`tmux_show_only_in_active_window` 등 옵션).
- Markdown / Neorg 이미지 미리보기, LaTeX 미리보기 등 활발히 쓰이는 생태계.
- 사내 nvim 설정(LazyVim 기반)에 **이미 포함**되어 있음.
- 단, "펫" 같은 인터랙티브 스프라이트 애니메이션은 image.nvim 자체의
  관심사가 아님 — 그 위에 얹을 레이어가 필요.

---

## 의사결정 매트릭스

| 항목 | pets.nvim 채택 | nvim-pets 직접 구축 |
|---|---|---|
| WezTerm + tmux 환경 동작 | ❌ 깨짐 (실측) | ✅ 정상 |
| 추가 의존성 | hologram.nvim, nui.nvim | image.nvim (이미 보유) |
| 업스트림 유지보수 활성도 | 낮음(hologram 사실상 정지) | 우리가 통제 |
| 동작 안 할 때 디버깅 경로 | 외부 PR 또는 fork | 직접 수정 |
| 코드 규모 | 외부 ~수천 줄 | 자체 ~300줄 |
| 사내 환경 표준화 | 외부 호환성 리스크 | dotfiles 일부로 관리 |
| 사내 자동화(저장→happy 등) | 별도 wrapper 필요 | 로드맵에 포함 (v1.2) |

## 우리가 직접 만들 때 비용은 얼마였나

- 사용 모듈: `lua/pets/renderer.lua` (~250줄) + `lua/pets/pet.lua` (~80줄).
- 스프라이트: vscode-pets 원본을 ImageMagick으로 추출 (MIT 라이센스,
  `LICENSES.md`에 명시).
- 작업 단계:
  - v0  — 정적 스프라이트 + 토글
  - v1.0 — 프레임별 idle 애니메이션 (깜빡임 제거)
  - v1.1 — 상태 머신(idle/walk/lie) + 좌우 sprite flip + 가장자리 반전
  - v1.1.5 — wander box 경계, 런타임 크기/위치 명령, image 객체 캐싱
- 핵심 기술 이슈와 해결:
  - **프레임 전환 깜빡임** → 모든 image 객체 preload + render-then-clear 순서
  - **메모리/프로토콜 누수** → `(path, x)` 키로 image 객체 재사용 (이게 없을
    때 WezTerm이 무한 로딩에 빠지는 버그를 직접 경험)
  - **tmux 윈도우 전환 잔상** → 알려진 한계로 문서화, 워크어라운드 제공
    (`:Pets` 두 번)

## 권고

- **사내 추천**: nvim-pets 사용. 추가 의존성 없음(image.nvim이 이미 깔려 있음).
- **외부에 vscode-pets 인용 시 주의**: nvim 생태계의 동급 라이브러리는
  현재 우리 표준 환경과 호환되지 않는다는 사실을 함께 전달할 것.
- **나중에 pets.nvim/hologram.nvim의 유지보수가 재개되면** 재평가.
  그때는 우리 코드가 작아서(약 330줄) 마이그레이션 비용도 작다.

---

## 부록 A — 실측 환경

- macOS (Darwin 25.4.0)
- WezTerm (Kitty Graphics Protocol 지원)
- tmux (`allow-passthrough on`, `focus-events on`)
- Neovim 0.11.6 (LazyVim 기반)
- 시도일: 2026-05-06

## 부록 B — pets.nvim 시연 절차 (재현 가능)

```lua
-- ~/.config/nvim/lua/plugins/pets-nvim-demo/config.lua (임시)
return {
  {
    "giusgad/pets.nvim",
    dependencies = {
      "MunifTanjim/nui.nvim",
      "giusgad/hologram.nvim",
    },
    cmd = { "PetsNew", "PetsList", "PetsKillAll" },
    config = function() require("pets").setup({}) end,
  },
}
```

`:PetsNew dog` 실행 → 깨진 픽셀 덩어리.
`:PetsKillAll`로 정리 후 데모 디렉터리 제거.
