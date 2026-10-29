#!/bin/bash
# Behaviour tests for the hook, plugin and installer. Runs in a throwaway $HOME.
#   ./test/run.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/libexec/trafficlight-hook"
PLUGIN="$ROOT/libexec/trafficlight-menu"
STATE="$ROOT/libexec/trafficlight-state"
CLI="$ROOT/bin/trafficlight"
export HOME="$(mktemp -d)"
export TRAFFICLIGHT_PLUGIN_DIR="$HOME/plugins"
mkdir -p "$HOME/.claude/sessions"
LIVE1="" LIVE2=""
trap 'kill $LIVE1 $LIVE2 2>/dev/null; wait 2>/dev/null; rm -rf "$HOME"' EXIT

pass=0 fail=0
check() { # name, expected, actual
  if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  \033[32m✓\033[0m %s\n' "$1"
  else fail=$((fail+1)); printf '  \033[31m✗\033[0m %s\n      expected: %s\n      actual:   %s\n' "$1" "$2" "$3"; fi
}
# event <agent> <event> <sid> [extra json]  (payload shaped like each agent's)
event() {
  local extra="${4:-}"; [ -z "$extra" ] && extra='{}'
  case "$1" in
    cursor)  jq -nc --arg s "$3" --argjson x "$extra" '{conversation_id:$s, workspace_roots:["/work/\($s)"]} + $x' ;;
    copilot) jq -nc --arg s "$3" --argjson x "$extra" '{sessionId:$s, cwd:"/work/\($s)"} + $x' ;;
    *)       jq -nc --arg s "$3" --argjson x "$extra" '{session_id:$s, cwd:"/work/\($s)"} + $x' ;;
  esac | "$HOOK" "$1" "$2"
}
state() { jq -r '.status' "$HOME/.trafficlight/sessions/$1-$2.json" 2>/dev/null || echo none; }
flow() { # agent sid "Event=expected ..."
  local agent="$1" sid="$2" step ev want
  for step in $3; do
    ev="${step%%=*}"; want="${step#*=}"
    event "$agent" "$ev" "$sid" >/dev/null
    check "$agent: $ev → $want" "$want" "$(state "$agent" "$sid")"
  done
}

echo "hook: claude"
flow claude c1 "SessionStart=done UserPromptSubmit=working PermissionRequest=waiting PostToolUse=working Stop=done"
for t in permission_prompt elicitation_dialog elicitation_url_dialog agent_needs_input; do
  event claude UserPromptSubmit c1; event claude Notification c1 "{\"notification_type\":\"$t\"}"
  check "claude: Notification $t → waiting" waiting "$(state claude c1)"
done
for t in idle_prompt auth_success agent_completed elicitation_complete quota_auto_resume_fired; do
  event claude UserPromptSubmit c1; event claude Notification c1 "{\"notification_type\":\"$t\"}"
  check "claude: Notification $t ignored" working "$(state claude c1)"
done
event claude StopFailure c1 '{"error_type":"rate_limit"}'
check "claude: StopFailure → error" error "$(state claude c1)"
check "claude: StopFailure keeps reason" rate_limit "$(jq -r .detail "$HOME/.trafficlight/sessions/claude-c1.json")"
event claude SessionEnd c1;                       check "claude: SessionEnd removes state" none "$(state claude c1)"

echo "hook: codex"
flow codex x1 "SessionStart=done UserPromptSubmit=working PermissionRequest=waiting PostToolUse=working Stop=done UserPromptSubmit=working Interrupt=done"
event codex SessionEnd x1;                        check "codex: SessionEnd removes state" none "$(state codex x1)"

echo "hook: gemini"
flow gemini g1 "SessionStart=done BeforeAgent=working Notification=waiting AfterTool=working AfterAgent=done"
event gemini SessionEnd g1;                       check "gemini: SessionEnd removes state" none "$(state gemini g1)"

echo "hook: cursor"
flow cursor u1 "sessionStart=done beforeSubmitPrompt=working postToolUse=working stop=done"
check "cursor: beforeSubmitPrompt allows the prompt" '{"continue": true}' "$(event cursor beforeSubmitPrompt u1)"
event cursor stop u1 '{"status":"aborted"}';      check "cursor: stop aborted → done" done "$(state cursor u1)"
event cursor stop u1 '{"status":"error"}';        check "cursor: stop error → error" error "$(state cursor u1)"
check "cursor: cwd from workspace_roots" /work/u1 "$(jq -r .cwd "$HOME/.trafficlight/sessions/cursor-u1.json")"
event cursor sessionEnd u1;                       check "cursor: sessionEnd removes state" none "$(state cursor u1)"

echo "hook: copilot"
flow copilot p1 "sessionStart=done userPromptSubmitted=working postToolUse=working agentStop=done"
echo '{"cwd":"/work/nosid"}' | "$HOOK" copilot userPromptSubmitted
check "copilot: no session id → one session per folder" 1 "$(ls "$HOME/.trafficlight/sessions" | grep -c '^copilot-dir-')"
event copilot sessionEnd p1;                      check "copilot: sessionEnd removes state" none "$(state copilot p1)"
echo '{"session_id":"z"}' | "$HOOK" claude Stop;  check "hook: always exits 0" 0 "$?"
rm -f "$HOME"/.trafficlight/sessions/*

echo "plugin: rendering"
sleep 600 & LIVE1=$!
sleep 600 & LIVE2=$!
now_ms=$(( $(date +%s) * 1000 ))
reg() { # pid, sid, cwd, status, name
  printf '{"pid":%s,"sessionId":"%s","cwd":"%s","status":"%s","statusUpdatedAt":%s,"name":"%s"}' \
    "$1" "$2" "$3" "$4" "$now_ms" "${5:-}" > "$HOME/.claude/sessions/$1.json"
}
put() { # agent sid status cwd [age]
  jq -nc --arg a "$1" --arg s "$2" --arg st "$3" --arg c "$4" --argjson age "${5:-0}" \
    '{agent:$a, session_id:$s, status:$st, cwd:$c, updated:((now|floor)-$age)}' > "$HOME/.trafficlight/sessions/$1-$2.json"
}
out=$("$PLUGIN");                                 check "no sessions → 🚦" "🚦" "$(head -1 <<<"$out")"
reg $LIVE1 a1 /code/alpha/api waiting
reg 999999 dead /code/gone busy                   # process not running
put claude a1 waiting /code/alpha/api
put claude dead working /code/gone
put cursor k1 working /code/web-app
put codex d1 done /code/beta/api
put gemini old working /code/stale 50000          # silent for > 12h
out=$("$PLUGIN")
check "dots sorted, amber first" "🟡🔴🟢" "$(head -1 <<<"$out")"
check "agent shown per row" 1 "$(grep -c 'web-app · Cursor · working…' <<<"$out")"
check "same folder name → parent shown" 1 "$(grep -c 'alpha/api · Claude Code · needs you' <<<"$out")"
check "dead claude session pruned" 0 "$(ls "$HOME/.trafficlight/sessions" | grep -c dead)"
check "stale session pruned after 12h" 0 "$(ls "$HOME/.trafficlight/sessions" | grep -c old)"
check "summary line" 1 "$(grep -c '🚦 trafficlight  🟡 1  🔴 1  🟢 1' <<<"$out")"
check "no em dashes in output" 0 "$(grep -c '—' <<<"$out")"

# Interrupted Claude turn: hook says working, registry went idle later → done
put claude a1 working /code/alpha/api 30
reg $LIVE1 a1 /code/alpha/api idle
out=$("$PLUGIN");                                 check "Esc-interrupted Claude turn → green" "🔴🟢🟢" "$(head -1 <<<"$out")"

# Claude session started before install shows from the registry
reg $LIVE2 b2 /code/gamma busy
out=$("$PLUGIN");                                 check "untracked Claude session shown" 1 "$(grep -c 'gamma · Claude Code · working…' <<<"$out")"

# Two sessions of one agent in the very same folder → session names
put claude b2 done /code/alpha/api
reg $LIVE1 a1 /code/alpha/api idle api-one
reg $LIVE2 b2 /code/alpha/api idle api-two
out=$("$PLUGIN")
check "same folder → session names shown" 2 "$(grep -cE 'alpha/api \[api-(one|two)\]' <<<"$out")"
rm -f "$HOME"/.trafficlight/sessions/* "$HOME"/.claude/sessions/*

echo "titles"
event codex UserPromptSubmit t1 '{"prompt":"\n  Fix the   login redirect bug\nand add a test"}'
check "first prompt line becomes the title" "Fix the login redirect bug" "$(jq -r .title "$HOME/.trafficlight/sessions/codex-t1.json")"
event codex PostToolUse t1
event codex UserPromptSubmit t1 '{"prompt":"now something else"}'
check "title kept across later prompts" "Fix the login redirect bug" "$(jq -r .title "$HOME/.trafficlight/sessions/codex-t1.json")"
event cursor beforeSubmitPrompt t2 "{\"prompt\":\"$(printf 'x%.0s' $(seq 1 80))\"}" >/dev/null
check "long titles clipped to 48 chars" 48 "$(jq -r '.title | length' "$HOME/.trafficlight/sessions/cursor-t2.json")"
event claude StopFailure t3 '{"error_type":"rate_limit"}'; event claude UserPromptSubmit t3 '{"transcript_path":"/x/t3.jsonl"}'
check "error detail cleared on the next event" null "$(jq -r .detail "$HOME/.trafficlight/sessions/claude-t3.json")"
check "transcript path kept" /x/t3.jsonl "$(jq -r .transcript "$HOME/.trafficlight/sessions/claude-t3.json")"
mkdir -p "$HOME/.claude/projects/-code-acme"
printf '%s\n' '{"type":"ai-title","aiTitle":"Old title"}' '{"type":"user"}' '{"type":"ai-title","aiTitle":"Refactor billing service"}' \
  > "$HOME/.claude/projects/-code-acme/t3.jsonl"
out=$("$PLUGIN")
check "Claude's own title shown" 1 "$(grep -c 'Refactor billing service · Claude Code · working…' <<<"$out")"
check "prompt title shown for other agents" 1 "$(grep -c 'Fix the login redirect bug · Codex · working…' <<<"$out")"
check "folder kept in tooltip" 1 "$(grep -c 'Fix the login redirect bug.*tooltip=/work/t1' <<<"$out")"
echo '{"type":"custom-title","customTitle":"Billing v2"}' >> "$HOME/.claude/projects/-code-acme/t3.jsonl"
check "renamed title wins" 1 "$("$PLUGIN" | grep -c 'Billing v2 · Claude Code')"
rm -f "$HOME"/.trafficlight/sessions/* "$HOME"/.claude/sessions/*

echo "installer"
count() { jq '[.. | objects | .command? // empty | strings | select(test("trafficlight-hook"))] | length' "$1"; }
# Last agent in the list (copilot) not present: install must still run.
mkdir -p "$HOME/.codex"
"$CLI" install >/dev/null 2>&1;                   check "install works when the last agent is missing" 0 "$?"
check "  ...and wires up what it found" 7 "$(count "$HOME/.codex/hooks.json")"
"$CLI" uninstall >/dev/null 2>&1
mkdir -p "$HOME/.claude/sessions" "$HOME/.cursor" "$HOME/.copilot"
echo '{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo keep-me"}]}],
  "PostToolUse":[{"hooks":[{"type":"command","command":"[ ! -x x ] || /old/libexec/session-status.sh"}]}]}}' > "$HOME/.claude/settings.json"
echo '{"version":1,"hooks":{"stop":[{"command":"say done"}],"postToolUse":[{"command":"[ ! -x x ] || /x/libexec/agentlights-hook cursor postToolUse"}]}}' > "$HOME/.cursor/hooks.json"
mkdir -p "$HOME/.agentlights/sessions" "$HOME/.copilot/hooks"; echo '{}' > "$HOME/.copilot/hooks/agentlights.json"
"$CLI" install >/dev/null 2>&1;                   check "install (auto-detect) exits 0" 0 "$?"
check "claude: 8 events" 8 "$(count "$HOME/.claude/settings.json")"
check "claude: legacy hook replaced" 0 "$(jq '[.. | objects | .command? // empty | strings | select(test("session-status"))] | length' "$HOME/.claude/settings.json")"
check "claude: other hooks kept" 1 "$(jq '[.hooks.Stop[].hooks[] | select(.command == "echo keep-me")] | length' "$HOME/.claude/settings.json")"
check "claude: other settings kept" opus "$(jq -r .model "$HOME/.claude/settings.json")"
check "codex: 7 events" 7 "$(count "$HOME/.codex/hooks.json")"
check "cursor: 5 events" 5 "$(count "$HOME/.cursor/hooks.json")"
check "cursor: version kept" 1 "$(jq .version "$HOME/.cursor/hooks.json")"
check "cursor: other hooks kept" "say done" "$(jq -r '.hooks.stop[0].command' "$HOME/.cursor/hooks.json")"
check "migration: agentlights hooks replaced" 0 "$(jq '[.. | objects | .command? // empty | strings | select(test("agentlights-hook"))] | length' "$HOME/.cursor/hooks.json")"
check "migration: agentlights state removed" no "$([ -d "$HOME/.agentlights" ] && echo yes || echo no)"
check "migration: old Copilot file removed" no "$([ -f "$HOME/.copilot/hooks/agentlights.json" ] && echo yes || echo no)"
check "copilot: own hook file" 5 "$(count "$HOME/.copilot/hooks/trafficlight.json")"
check "gemini: not detected, not touched" no "$([ -f "$HOME/.gemini/settings.json" ] && echo yes || echo no)"
"$CLI" install gemini >/dev/null 2>&1
check "gemini: explicit install, 6 events" 6 "$(count "$HOME/.gemini/settings.json")"
check "gemini: timeout in ms" 5000 "$(jq '.hooks.AfterAgent[0].hooks[0].timeout' "$HOME/.gemini/settings.json")"
"$CLI" install >/dev/null 2>&1;                   check "re-install is idempotent" 8 "$(count "$HOME/.claude/settings.json")"
LP="$HOME/Library/LaunchAgents/app.trafficlight.plist"
check "login item written" yes "$([ -f "$LP" ] && echo yes || echo no)"
check "  ...runs the menu bar app" 1 "$(grep -c 'Trafficlight.app/Contents/MacOS/Trafficlight' "$LP")"
check "  ...starts at login, restarts only after a crash" "true false" "$(plutil -extract RunAtLoad raw "$LP") $(plutil -extract KeepAlive.SuccessfulExit raw "$LP")"
cmd=$(jq -r '.hooks.Stop[-1].hooks[0].command' "$HOME/.claude/settings.json")
missing=$(sed "s|'[^']*trafficlight-hook'|'/nonexistent/trafficlight-hook'|g" <<<"$cmd")
echo '{}' | sh -c "$missing";                     check "hook guard: missing script exits 0" 0 "$?"
"$CLI" install bogus >/dev/null 2>&1;             check "unknown agent rejected" 1 "$?"
"$CLI" uninstall cursor >/dev/null 2>&1
check "uninstall one agent" 0 "$(count "$HOME/.cursor/hooks.json")"
check "  ...others untouched" 8 "$(count "$HOME/.claude/settings.json")"
"$CLI" uninstall >/dev/null 2>&1
check "uninstall all: claude clean" 0 "$(count "$HOME/.claude/settings.json")"
check "uninstall all: codex clean" 0 "$(count "$HOME/.codex/hooks.json")"
check "uninstall all: copilot file removed" no "$([ -f "$HOME/.copilot/hooks/trafficlight.json" ] && echo yes || echo no)"
check "uninstall all: other hooks kept" 1 "$(jq '[.hooks.Stop[].hooks[] | select(.command == "echo keep-me")] | length' "$HOME/.claude/settings.json")"
check "uninstall all: login item removed" no "$([ -e "$LP" ] && echo yes || echo no)"
check "uninstall all: state removed" no "$([ -d "$HOME/.trafficlight" ] && echo yes || echo no)"
"$CLI" install claude --no-app >/dev/null 2>&1
check "install --no-app: hooks only" "8 no" "$(count "$HOME/.claude/settings.json") $([ -e "$LP" ] && echo yes || echo no)"
"$CLI" uninstall claude --no-app >/dev/null 2>&1
check "uninstall --no-app: hooks only" 0 "$(count "$HOME/.claude/settings.json")"

echo "agent folders"
fresh=$(mktemp -d)
HOME=$fresh "$CLI" install gemini >/dev/null 2>&1
check "turning on an absent agent creates its folder" yes "$([ -d "$fresh/.gemini" ] && echo yes || echo no)"
check "  ...and it shows as wired" true "$(HOME=$fresh "$CLI" _info | jq -r '.[] | select(.id == "gemini") | .installed')"
HOME=$fresh "$CLI" uninstall gemini >/dev/null 2>&1
check "turning it off removes the folder trafficlight created" no "$([ -e "$fresh/.gemini" ] && echo yes || echo no)"
check "  ...so it no longer shows as detected" false "$(HOME=$fresh "$CLI" _info | jq -r '.[] | select(.id == "gemini") | .detected')"
HOME=$fresh "$CLI" install copilot >/dev/null 2>&1; HOME=$fresh "$CLI" uninstall copilot >/dev/null 2>&1
check "same for Copilot" no "$([ -e "$fresh/.copilot" ] && echo yes || echo no)"
mkdir -p "$fresh/.gemini"; echo '{"theme":"dark"}' > "$fresh/.gemini/settings.json"
HOME=$fresh "$CLI" install gemini >/dev/null 2>&1; HOME=$fresh "$CLI" uninstall gemini >/dev/null 2>&1
check "a folder that was already there is kept" dark "$(jq -r .theme "$fresh/.gemini/settings.json")"
rm -rf "$fresh"; mkdir -p "$fresh/.gemini"; HOME=$fresh "$CLI" install gemini >/dev/null 2>&1; echo '{"theme":"x"}' > /dev/null
jq '.model = "gemini-pro"' "$fresh/.gemini/settings.json" > "$fresh/g.json" && mv "$fresh/g.json" "$fresh/.gemini/settings.json"
HOME=$fresh "$CLI" uninstall gemini >/dev/null 2>&1
check "settings added after install are kept" gemini-pro "$(jq -r .model "$fresh/.gemini/settings.json" 2>/dev/null)"
check "VS Code Copilot extension counts as detected" true "$(fresh2=$(mktemp -d); mkdir -p "$fresh2/.vscode/extensions/github.copilot-chat-1.0"; HOME=$fresh2 "$CLI" _info | jq -r '.[] | select(.id == "copilot") | .detected'; rm -rf "$fresh2")"
rm -rf "$fresh"

echo "settings"
"$CLI" install claude >/dev/null 2>&1; "$CLI" uninstall gemini >/dev/null 2>&1
info=$("$CLI" _info)
check "_info lists all five agents" 5 "$(jq length <<<"$info")"
check "_info: claude wired" true "$(jq -r '.[] | select(.id == "claude") | .installed' <<<"$info")"
check "_info: gemini detected matches ~/.gemini, not wired" "$([ -d "$HOME/.gemini" ] && echo true || echo false) false" "$(jq -r '.[] | select(.id == "gemini") | "\(.detected) \(.installed)"' <<<"$info")"
check "text menu has no SwiftBar markup" 0 "$("$CLI" menu | grep -c ' | ')"
check "status reports the app and login item" 2 "$("$CLI" status | grep -cE '^(app|login): ')"
sleep 600 & L=$!; printf '{"pid":%s,"sessionId":"j1","cwd":"/code/json","status":"busy","statusUpdatedAt":%s}' $L "$(( $(date +%s) * 1000 ))" > "$HOME/.claude/sessions/$L.json"
st=$("$STATE")
check "state JSON for the app" "json Claude Code working working…" "$(jq -r '.rows[] | select(.name == "json") | "\(.name) \(.who) \(.status) \(.label)"' <<<"$st")"
check "  ...with counts" 1 "$(jq -r '.counts.working' <<<"$st")"
kill $L 2>/dev/null; wait $L 2>/dev/null; rm -f "$HOME/.claude/sessions/$L.json"
check "settings without a screen falls back to status" 1 "$(SSH_CONNECTION=x "$CLI" settings | grep -c 'Claude Code')"
if command -v swiftc >/dev/null && [ "$(launchctl managername 2>/dev/null)" = Aqua ]; then
  "$ROOT/script/build-app" "$HOME/app" >/dev/null 2>&1
  check "menu bar app builds" yes "$([ -x "$HOME/app/Trafficlight.app/Contents/MacOS/Trafficlight" ] && echo yes || echo no)"
  check "  ...menu bar only (no Dock icon)" true "$(plutil -extract LSUIElement raw "$HOME/app/Trafficlight.app/Contents/Info.plist")"
  check "  ...handles trafficlight:// links" trafficlight "$(plutil -extract CFBundleURLTypes.0.CFBundleURLSchemes.0 raw "$HOME/app/Trafficlight.app/Contents/Info.plist")"
  "$HOME/app/Trafficlight.app/Contents/MacOS/Trafficlight" --render "$HOME/shots" >/dev/null 2>&1
  check "  ...and renders Settings and the menu bar images" 4 "$(ls "$HOME/shots" | grep -c '\.png$')"
fi

echo "release"
check "no em dashes in shipped files" 0 "$(cat "$ROOT"/bin/* "$ROOT"/libexec/trafficlight-* "$ROOT"/app/*.swift "$ROOT"/README.md "$ROOT"/assets/*.svg 2>/dev/null | grep -c '—')"
check "no SwiftBar in the app or engine (the CLI mentions it only to migrate)" 0 "$(cat "$ROOT"/libexec/trafficlight-* "$ROOT"/app/*.swift | grep -ci 'swiftbar')"
if tag=$(git -C "$ROOT" describe --tags --exact-match 2>/dev/null); then
  check "CLI version matches tag $tag" "${tag#v}" "$("$CLI" --version)"
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
