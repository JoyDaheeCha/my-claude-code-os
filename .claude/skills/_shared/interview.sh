#!/usr/bin/env bash
#
# interview.sh — 구체화 결과(clarified spec) 저장소 (append log + 주입 렌더)
#
# 왜 이 스크립트가 있나:
#   interview 스킬의 "판단"(무엇이 모호한가 / 무엇을 물을까)은 LLM이 한다.
#   하지만 그 결과를 "언제·어디에·어떤 모양으로 남기느냐"는 산수와 IO다.
#   id 부여, 타임스탬프, 원자적 append, 주입용 렌더 — 이건 매번 LLM이
#   즉흥적으로 하면 형식이 흔들린다. 그래서 형식을 스크립트에 고정한다.
#   (profile.sh / notion.sh 와 같은 "결정론적 = 스크립트" 원칙.)
#
# 컨텍스트 주입 방식:
#   render 출력은 다른 스킬(capture, plan 등)이 프롬프트에 이어붙이는 페이로드다.
#   Pull · Just-in-Time · 결정론적(고정 키로 읽음) = Lazy 로딩. (RAG 아님, 상주 아님.)
#
# 데이터 모양 (clarified-specs.json = 배열, append-only 로그):
#   [{ "id":"iv-20260702-2130-ab", "created_at":"...", "raw":"원래 모호했던 요청",
#      "spec":"구체화된 실행 스펙 한 덩어리", "slots":{"what":"...","done":"..."},
#      "qa":[{"q":"...","a":"..."}], "tags":["capture"] }, ...]
#
# 사용법:
#   interview.sh save         # stdin으로 받은 spec JSON 객체를 append, 부여된 id 출력
#   interview.sh read [id]    # 전체(또는 특정 id) 원시 JSON 출력
#   interview.sh render [n]   # 최근 n개(기본 3) 스펙을 프롬프트 주입용 텍스트로
#   interview.sh list         # 최근 항목 한 줄 요약 목록
#   interview.sh delete <id>  # 특정 id 항목 제거 (되돌리기용). 삭제 개수 출력
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STORE="$SCRIPT_DIR/../../data/clarified-specs.json"

ensure() {
  [[ -f "$STORE" ]] || printf '%s' '[]' > "$STORE"
}

# id = iv-<날짜>-<시분>-<랜덤2>  (사람이 읽을 수 있고 대략 정렬됨)
gen_id() {
  printf 'iv-%s-%s' "$(date +%Y%m%d-%H%M)" "$(od -An -N2 -tx1 /dev/urandom | tr -d ' \n')"
}

cmd="${1:-render}"
arg="${2:-}"

case "$cmd" in
  save)
    ensure
    # stdin = LLM이 조립한 spec 객체. id/created_at은 여기서(결정론적으로) 부여한다.
    payload="$(cat)"
    id="$(gen_id)"
    tmp="$(mktemp)"
    printf '%s' "$payload" | jq \
      --arg id "$id" --arg ts "$(date +%FT%T)" \
      '. + {id:$id, created_at:$ts}' > "$tmp.entry"
    jq --slurpfile e "$tmp.entry" '. + $e' "$STORE" > "$tmp"
    mv "$tmp" "$STORE"
    rm -f "$tmp.entry"
    echo "$id"
    ;;

  read)
    ensure
    if [[ -n "$arg" ]]; then
      jq --arg id "$arg" '.[] | select(.id==$id)' "$STORE"
    else
      cat "$STORE"
    fi
    ;;

  render)   # arg = 개수 n (기본 3)
    ensure
    n="${arg:-3}"
    jq -r --argjson n "$n" '
      if length==0 then "## 최근 구체화된 스펙: 아직 없음"
      else
        ( ["## 최근 구체화된 스펙 (interview)"]
          + ( [.[-$n:][]] | reverse | map(
                "- [\(.id)] \(.spec)"
                + ( if (.tags|length)>0 then "  (\(.tags|join(", ")))" else "" end )
            ) )
        ) | join("\n")
      end
    ' "$STORE"
    ;;

  delete)   # arg = 지울 id
    ensure
    [[ -n "$arg" ]] || { echo "usage: interview.sh delete <id>" >&2; exit 1; }
    before="$(jq 'length' "$STORE")"
    tmp="$(mktemp)"
    jq --arg id "$arg" '[ .[] | select(.id != $id) ]' "$STORE" > "$tmp"
    mv "$tmp" "$STORE"
    after="$(jq 'length' "$STORE")"
    echo "deleted: $((before - after))"
    ;;

  list)
    ensure
    jq -r '
      if length==0 then "(비어 있음)"
      else .[] | "\(.id)  \(.raw[0:40] // "")  →  \(.spec[0:60] // "")" end
    ' "$STORE"
    ;;

  *)
    echo "usage: interview.sh {save|read [id]|render [n]|list|delete <id>}" >&2
    exit 1
    ;;
esac
