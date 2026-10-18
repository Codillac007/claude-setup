#!/bin/bash
# Claude Code bulud mühiti üçün setup script.
# Quraşdırır: find-skills, tradermonty trading skill-ləri, task-observer (+ SessionStart hook),
# claude-mem plugin-i, headroom (MCP), msitarzewski/agency-agents.
# Hər addım müstəqildir: biri uğursuz olsa, digərləri davam edir.

LOG=/root/claude-setup.log
exec > >(tee -a "$LOG") 2>&1
echo "=== claude-setup $(date '+%F %T') ==="
echo "user=$(id -un) HOME=$HOME PWD=$PWD"

# Setup mərhələsində PATH qısa ola bilər: məlum yerləri əlavə et.
for d in /opt/node22/bin /opt/node*/bin /usr/local/bin "$HOME/.local/bin" "$HOME/.bun/bin"; do
  [ -d "$d" ] && PATH="$d:$PATH"
done
export PATH
for t in node npx git jq uv claude; do
  printf '%-6s %s\n' "$t" "$(command -v $t || echo 'YOXDUR')"
done
command -v uv >/dev/null || { python3 -m pip install -q --user uv >/dev/null 2>&1 || python3 -m pip install -q --user --break-system-packages uv >/dev/null 2>&1; export PATH="$HOME/.local/bin:$PATH"; }
OBS_WORKSPACE="${OBS_WORKSPACE:-/home/user}"
AGENCY_COMMIT=652b2692f8d8ec2b1f1a38e559073e287dfdc469   # təhlükəsizlik yoxlamasından keçmiş commit

step() { echo; echo "==> $1"; }
fail() { echo "!! $1 alınmadı (davam edirəm)"; }
run() { "$@" > /tmp/claude-setup-step.log 2>&1 || { tail -5 /tmp/claude-setup-step.log; return 1; }; }

mkdir -p "$HOME/.claude/hooks" "$HOME/.claude/agents"
[ -f "$HOME/.claude/settings.json" ] || echo '{}' > "$HOME/.claude/settings.json"

step "Skill-lər (find-skills, tradermonty, task-observer)"
run npx -y skills add vercel-labs/skills --skill find-skills -g -y || fail find-skills
run npx -y skills add tradermonty/claude-trading-skills -g -y || fail tradermonty
run npx -y skills add rebelytics/one-skill-to-rule-them-all --skill task-observer -g -y || fail task-observer
ls -d "$HOME/.claude/skills"/*/ 2>/dev/null | wc -l | xargs echo "skill sayı:"

step "claude-mem plugin-i"
{
  run claude plugin marketplace add thedotmack/claude-mem &&
  run claude plugin install claude-mem@thedotmack &&
  root=$(ls -d "$HOME/.claude/plugins/cache/thedotmack/claude-mem"/*/ | sort -V | tail -1) &&
  CLAUDE_PLUGIN_ROOT="${root%/}" run node "$root/scripts/ensure-launcher.cjs"
} || fail claude-mem

step "headroom (MCP)"
{
  run uv tool install --python 3.13 "headroom-ai[all]" &&
  run headroom mcp install
} || fail headroom

step "agency-agents ($AGENCY_COMMIT)"
tmp=$(mktemp -d)
if git -C "$tmp" init -q &&
   git -C "$tmp" fetch -q --depth 1 https://github.com/msitarzewski/agency-agents.git "$AGENCY_COMMIT" &&
   git -C "$tmp" checkout -q FETCH_HEAD; then
  run bash "$tmp/scripts/install.sh" --tool claude-code --no-interactive || fail "agency-agents install"
else
  fail "agency-agents clone"
fi
rm -rf "$tmp"
ls "$HOME/.claude/agents" | wc -l | xargs echo "agent sayı:"

step "task-observer SessionStart hook"
mkdir -p "$OBS_WORKSPACE/skill-observations/observation-log"
cat > "$HOME/.claude/hooks/task-observer-session-start.sh" <<'HOOK'
#!/bin/sh
# SessionStart hook: inject task-observer activation + review state as additionalContext.
OBS_WORKSPACE="${OBS_WORKSPACE:-/home/user}"
d="$OBS_WORKSPACE/skill-observations"
open=$(find "$d/observation-log" -maxdepth 1 -name '*.md' -exec grep -l '^status: open$' {} + 2>/dev/null | wc -l | tr -d ' ')
last=$(tr -d '\r' 2>/dev/null < "$d/last-review-date.txt"); last=${last:-never}
msg="Make the first tool call of this session one batched call that both lists the task-observer workspace ($OBS_WORKSPACE) and invokes the task-observer skill; then run its Session Start Protocol. Observation files are created only by scripts/new-observation.sh in the skill directory, never by copying a header."
if [ "$open" -gt 0 ]; then
  msg="$msg $open open observations; last review: $last."
  cutoff=$(date -d '7 days ago' +%F 2>/dev/null || date -v-7d +%F)
  case "$last" in
    (never) msg="$msg Offer the review." ;;
    (*) [ "$(printf '%s\n%s\n' "$last" "$cutoff" | sort | head -1)" = "$last" ] && msg="$msg Offer the review." ;;
  esac
fi
msg=$(printf '%s' "$msg" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\000-\037')
printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$msg"
HOOK
chmod +x "$HOME/.claude/hooks/task-observer-session-start.sh"
f="$HOME/.claude/settings.json"
if ! grep -q task-observer-session-start "$f"; then
  jq '.hooks.SessionStart += [{"matcher":"startup|resume|clear|compact","hooks":[{"type":"command","command":"sh ~/.claude/hooks/task-observer-session-start.sh","timeout":30}]}]' \
    "$f" > "$f.tmp" && mv "$f.tmp" "$f" || fail "hook qeydiyyatı"
fi

step "CLAUDE.md qaydası"
if ! grep -q '## Agency agents' "$HOME/.claude/CLAUDE.md" 2>/dev/null; then
  cat >> "$HOME/.claude/CLAUDE.md" <<'MD'

## Agency agents
`~/.claude/agents/` holds the msitarzewski/agency-agents roster (282 specialist subagents: engineering, design, marketing, finance, security, testing, etc.).
When a task clearly fits one of these specialists, delegate it to (or adopt the persona of) that agent instead of handling it generically, and tell the user which agent was used.
MD
fi

ls -la "$HOME/.claude" | head -20
echo; echo "==> Hazırdır."
exit 0
