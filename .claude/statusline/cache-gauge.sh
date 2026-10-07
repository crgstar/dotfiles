#!/usr/bin/env bash
# ccstatusline の custom-command ウィジェット用: プロンプトキャッシュの寿命の残りをゲージで出す。
#   cache ▰▰▰▰▰▰▱▱ 47m / 1h
# why: ccstatusline 純正の Cache Timer は寿命 (5m / 1h) を手で設定し、transcript の時刻から
#      逆算する。Claude Code が statusline JSON に載せる prompt_cache (ttl / expires_at / warm) は
#      Claude Code 自身が決めた実値なので、サブスクの枠切れで 5m に落ちたときも追従できる。
#
# usage: cache-gauge.sh [--now <epoch>] < statusline.json
#        cache-gauge.sh --self-test
set -uo pipefail

# why: 色は ANSI で出す。ccstatusline 側でウィジェットの preserveColors を有効にしないと剥がされる。
# 閾値は仮置き。黄に変える寿命の残り割合 / /compact を勧める再書込量 / ミスを出し続ける秒数
render() {
  local now=$1
  jq -r --argjson now "$now" '
    def esc(code): "\u001b[\(code)m";
    def paint(code; s): esc(code) + s + esc("0");
    def tok: if . >= 1000000 then "\((. / 100000 | floor) / 10)M"
             elif . >= 1000 then "\(. / 1000 | round)k" else tostring end;
    def gauge(cells; width): ([range(0; cells)] | map("▰") | join("")) + ([range(cells; width)] | map("▱") | join(""));
    0.2 as $warn_ratio | 100000 as $compact_at | 600 as $miss_window | 8 as $width
    | .prompt_cache as $c
    | paint("1;36"; "cache") as $label
    | if $c == null then empty
      elif ($c.caching_observed | not) then paint("2"; "cache ────────")
      else
        (if $c.ttl == "1h" then 3600 else 300 end) as $life
        | (if $c.expires_at == null then 0 else ([$c.expires_at - $now, 0] | max) end) as $left
        | "\(($left / 60) | ceil)m" as $mins
        # why: 状態は残り分数の色で読ませ、寿命 (/ 1h) は添え物として沈める
        | " / \($c.ttl // "?")" as $total
        | (if $c.last_miss_at != null and ($now - $c.last_miss_at) < $miss_window
             then " " + paint("31"; "miss") else "" end) as $miss
        | if $c.warm and $left > 0 then
            ([([($left / $life * $width) | round, 1] | max), $width] | min) as $cells
            | (if $left <= $life * $warn_ratio then "33" else "32" end) as $color
            | "\($label) \(paint($color; gauge($cells; $width)))  \(paint($color; $mins))\(paint("2"; $total))\($miss)"
          else
            ($c.recache_tokens_if_cold) as $re
            | if $re == null then "\($label) \(paint("31"; gauge(0; $width)))  \(paint("31"; $mins))\(paint("2"; $total))\($miss)"
              elif $re >= $compact_at then "\($label) \(paint("31"; gauge(0; $width)))  \(paint("31"; $mins))\(paint("2"; $total)) \(paint("31"; $re | tok)) \(paint("1"; "/compact"))\($miss)"
              else "\($label) \(paint("2"; gauge(0; $width) + "  " + $mins + $total + " " + ($re | tok)))\($miss)"
              end
          end
      end
  '
}

self_test() {
  local now=1738429200 fail=0
  check() {
    local name=$1 json=$2 want=$3 got
    got=$(jq -n --argjson now "$now" "$json" | render "$now" | sed $'s/\x1b\\[[0-9;]*m//g')
    if [ "$got" = "$want" ]; then
      echo "ok   $name"
    else
      echo "FAIL $name: want [$want] got [$got]"
      fail=1
    fi
  }
  local base='caching_observed:true,ttl:"1h",hit_ratio:0.9,recache_tokens_if_cold:45000,last_miss_at:null,last_miss_cause:null'
  check "warm 1h"       "{prompt_cache:{$base,warm:true,expires_at:(\$now+2820)}}"   "cache ▰▰▰▰▰▰▱▱  47m / 1h"
  check "warm soon"     "{prompt_cache:{$base,warm:true,expires_at:(\$now+480)}}"    "cache ▰▱▱▱▱▱▱▱  8m / 1h"
  check "warm last min" "{prompt_cache:{$base,warm:true,expires_at:(\$now+50)}}"     "cache ▰▱▱▱▱▱▱▱  1m / 1h"
  check "warm 5m"       "{prompt_cache:{$base,ttl:\"5m\",warm:true,expires_at:(\$now+290)}}" "cache ▰▰▰▰▰▰▰▰  5m / 5m"
  check "miss recent"   "{prompt_cache:{$base,warm:true,expires_at:(\$now+3590),last_miss_at:(\$now-10),last_miss_cause:{causes:[\"tools_changed\"]}}}" "cache ▰▰▰▰▰▰▰▰  60m / 1h miss"
  # why: last_miss_cause は Claude Code が原因を特定できないと null になる (公式 docs)。miss 自体は起きているので出す
  check "miss no cause" "{prompt_cache:{$base,warm:true,expires_at:(\$now+3590),last_miss_at:(\$now-10),last_miss_cause:null}}" "cache ▰▰▰▰▰▰▰▰  60m / 1h miss"
  check "miss old"      "{prompt_cache:{$base,warm:true,expires_at:(\$now+3590),last_miss_at:(\$now-700),last_miss_cause:{causes:[\"tools_changed\"]}}}" "cache ▰▰▰▰▰▰▰▰  60m / 1h"
  check "cold big"      "{prompt_cache:{$base,warm:false,expires_at:(\$now-30),recache_tokens_if_cold:152000}}" "cache ▱▱▱▱▱▱▱▱  0m / 1h 152k /compact"
  check "cold small"    "{prompt_cache:{$base,ttl:\"5m\",warm:false,expires_at:(\$now-30),recache_tokens_if_cold:23000}}" "cache ▱▱▱▱▱▱▱▱  0m / 5m 23k"
  # why: warm フラグは最後に受け取った JSON 時点の値。expires_at を過ぎた再描画では warm=true のまま来うる
  check "expired warm"  "{prompt_cache:{$base,warm:true,expires_at:(\$now-1),recache_tokens_if_cold:23000}}" "cache ▱▱▱▱▱▱▱▱  0m / 1h 23k"
  check "cold unknown"  "{prompt_cache:{$base,warm:false,expires_at:null,recache_tokens_if_cold:null}}" "cache ▱▱▱▱▱▱▱▱  0m / 1h"
  check "ttl missing"   "{prompt_cache:{$base,warm:true,expires_at:(\$now+290),ttl:null}}" "cache ▰▰▰▰▰▰▰▰  5m / ?"
  check "caching off"   "{prompt_cache:{caching_observed:false,warm:false,ttl:\"5m\",expires_at:null}}" "cache ────────"
  check "no response"   "{}" ""
  return $fail
}

case "${1:-}" in
  --self-test) self_test ;;
  --now) render "${2:?--now requires an epoch}" ;;
  *) render "$(date +%s)" ;;
esac
