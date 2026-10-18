# Claude Code üçün Windows setup skripti (PowerShell 5.1+).
# Quraşdırır: find-skills, tradermonty trading skill-ləri, task-observer (+ SessionStart hook),
# claude-mem plugin-i, headroom (MCP), msitarzewski/agency-agents.
# İşə salmaq (PowerShell-də, adi istifadəçi kimi):
#   irm https://raw.githubusercontent.com/Codillac007/claude-setup/main/setup-claude.ps1 | iex
# Hər addım müstəqildir: biri uğursuz olsa, digərləri davam edir. Təkrar işə salmaq təhlükəsizdir.

$AgencyCommit = '652b2692f8d8ec2b1f1a38e559073e287dfdc469'   # təhlükəsizlik yoxlamasından keçmiş commit
$ClaudeDir    = Join-Path $HOME '.claude'
$ObsWorkspace = $ClaudeDir                                    # qeydlər: ~/.claude/skill-observations
$Log          = Join-Path $HOME 'claude-setup.log'
$Utf8NoBom    = New-Object System.Text.UTF8Encoding $false

Start-Transcript -Path $Log -Append | Out-Null

function Step($t) { Write-Host ""; Write-Host "==> $t" -ForegroundColor Cyan }
function Fail($t) { Write-Host "!! $t alınmadı (davam edirəm)" -ForegroundColor Yellow }
function Have($c) { [bool](Get-Command $c -ErrorAction SilentlyContinue) }
function Refresh-Path {
  $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
              [Environment]::GetEnvironmentVariable('Path', 'User') + ';' +
              (Join-Path $HOME '.local\bin')
}
# Xarici əmri işlət; uğursuz olsa çıxışın son sətirlərini göstər.
function Run {
  # @rest massiv kimi splat olunur: .ps1 (npm.ps1, npx.ps1) və .exe əmrləri arqumentləri ayrı-ayrı alır.
  # @(...) vacibdir: tək arqument massiv olmasa, sətir hərf-hərf splat olunur.
  $cmd = $args[0]; $rest = @($args | Select-Object -Skip 1)
  $global:LASTEXITCODE = 0
  $out = & $cmd @rest 2>&1
  if (-not $? -or $LASTEXITCODE -ne 0) { $out | Select-Object -Last 5 | ForEach-Object { Write-Host "   $_" }; return $false }
  return $true
}
function Write-Utf8($path, $text) { [IO.File]::WriteAllText($path, $text, $Utf8NoBom) }

New-Item -ItemType Directory -Force -Path (Join-Path $ClaudeDir 'hooks'), (Join-Path $ClaudeDir 'agents') | Out-Null
Refresh-Path

Step 'Lazımi proqramlar (Node.js, Git, uv, Claude Code)'
$winget = Have 'winget'
foreach ($p in @(@('node', 'OpenJS.NodeJS.LTS'), @('git', 'Git.Git'), @('uv', 'astral-sh.uv'))) {
  if (Have $p[0]) { Write-Host ("{0,-7} var" -f $p[0]); continue }
  if (-not $winget) { Fail "$($p[0]) yoxdur və winget tapılmadı; $($p[1]) əllə quraşdırın"; continue }
  Write-Host "$($p[0]) quraşdırılır ($($p[1]))..."
  winget install --id $p[1] -e --silent --accept-package-agreements --accept-source-agreements | Out-Null
  Refresh-Path
  if (-not (Have $p[0])) { Fail $p[0] }
}
if (-not (Have 'claude')) {
  if ((Have 'npm') -and (Run npm install -g '@anthropic-ai/claude-code')) { Refresh-Path } else { Fail 'Claude Code' }
}
foreach ($c in 'node', 'npx', 'git', 'uv', 'claude') {
  $cmd = Get-Command $c -ErrorAction SilentlyContinue
  Write-Host ("{0,-7} {1}" -f $c, $(if ($cmd) { $cmd.Source } else { 'YOXDUR' }))
}

Step 'Skill-lər (find-skills, tradermonty, task-observer)'
if (-not (Run npx -y skills add vercel-labs/skills --skill find-skills -g -y)) { Fail 'find-skills' }
if (-not (Run npx -y skills add tradermonty/claude-trading-skills -g -y)) { Fail 'tradermonty' }
if (-not (Run npx -y skills add rebelytics/one-skill-to-rule-them-all --skill task-observer -g -y)) { Fail 'task-observer' }
Write-Host ("skill sayı: {0}" -f @(Get-ChildItem (Join-Path $ClaudeDir 'skills') -Directory -ErrorAction SilentlyContinue).Count)

Step 'claude-mem plugin-i'
if ((Run claude plugin marketplace add thedotmack/claude-mem) -and (Run claude plugin install claude-mem@thedotmack)) {
  $root = Get-ChildItem (Join-Path $ClaudeDir 'plugins\cache\thedotmack\claude-mem') -Directory -ErrorAction SilentlyContinue |
          Sort-Object { try { [version]($_.Name -replace '-.*$', '') } catch { [version]'0.0' } } | Select-Object -Last 1
  if ($root) {
    $env:CLAUDE_PLUGIN_ROOT = $root.FullName
    if (-not (Run node (Join-Path $root.FullName 'scripts\ensure-launcher.cjs'))) { Fail 'claude-mem launcher' }
    Remove-Item Env:CLAUDE_PLUGIN_ROOT
  } else { Fail 'claude-mem (plugin qovluğu tapılmadı)' }
} else { Fail 'claude-mem' }

Step 'headroom (MCP)'
if ((Run uv tool install --python 3.13 'headroom-ai[all]') -and $(Refresh-Path; Run headroom mcp install)) {} else { Fail 'headroom' }

Step "agency-agents ($AgencyCommit)"
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("agency-agents-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
if ((Run git -C $tmp init -q) -and
    (Run git -C $tmp fetch -q --depth 1 https://github.com/msitarzewski/agency-agents.git $AgencyCommit) -and
    (Run git -C $tmp checkout -q FETCH_HEAD)) {
  # scripts/install.sh --tool claude-code ilə eyni: bu qovluqlardakı frontmatter-li .md faylları ~/.claude/agents-ə
  $dirs = 'academic design engineering finance game-development gis healthcare marketing paid-media product project-management research sales security spatial-computing specialized support testing' -split ' '
  foreach ($d in $dirs) {
    Get-ChildItem (Join-Path $tmp $d) -Recurse -Filter *.md -File -ErrorAction SilentlyContinue |
      Where-Object { (Get-Content $_.FullName -TotalCount 1) -eq '---' } |
      Copy-Item -Destination (Join-Path $ClaudeDir 'agents') -Force
  }
} else { Fail 'agency-agents clone' }
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ("agent sayı: {0}" -f @(Get-ChildItem (Join-Path $ClaudeDir 'agents') -Filter *.md -File).Count)

Step 'task-observer SessionStart hook'
New-Item -ItemType Directory -Force -Path (Join-Path $ObsWorkspace 'skill-observations\observation-log') | Out-Null
$hook = Join-Path $ClaudeDir 'hooks\task-observer-session-start.ps1'
Write-Utf8 $hook @'
# SessionStart hook: inject task-observer activation + review state as additionalContext.
$ws = if ($env:OBS_WORKSPACE) { $env:OBS_WORKSPACE } else { (Join-Path $HOME '.claude') -replace '\\', '/' }
$d = Join-Path $ws 'skill-observations'
$open = @(Get-ChildItem (Join-Path $d 'observation-log') -Filter *.md -File -ErrorAction SilentlyContinue |
          Where-Object { Select-String -Path $_.FullName -Pattern '^status: open$' -Quiet }).Count
$last = (Get-Content (Join-Path $d 'last-review-date.txt') -TotalCount 1 -ErrorAction SilentlyContinue)
if (-not $last) { $last = 'never' } else { $last = $last.Trim() }
$msg = "Make the first tool call of this session one batched call that both lists the task-observer workspace ($ws) and invokes the task-observer skill; then run its Session Start Protocol. Observation files are created only by scripts/new-observation.sh in the skill directory, never by copying a header."
if ($open -gt 0) {
  $msg += " $open open observations; last review: $last."
  $cutoff = (Get-Date).AddDays(-7).ToString('yyyy-MM-dd')
  if ($last -eq 'never' -or [string]::CompareOrdinal($last, $cutoff) -le 0) { $msg += ' Offer the review.' }
}
@{ hookSpecificOutput = @{ hookEventName = 'SessionStart'; additionalContext = $msg } } | ConvertTo-Json -Compress
'@
$settingsPath = Join-Path $ClaudeDir 'settings.json'
$settings = if (Test-Path $settingsPath) { Get-Content $settingsPath -Raw | ConvertFrom-Json } else { [pscustomobject]@{} }
if ((Get-Content $settingsPath -Raw -ErrorAction SilentlyContinue) -notmatch 'task-observer-session-start') {
  $entry = [pscustomobject]@{
    matcher = 'startup|resume|clear|compact'
    hooks   = @([pscustomobject]@{
      type    = 'command'
      command = 'powershell -NoProfile -ExecutionPolicy Bypass -File "' + ($hook -replace '\\', '/') + '"'
      timeout = 30
    })
  }
  if (-not $settings.PSObject.Properties['hooks']) { $settings | Add-Member hooks ([pscustomobject]@{}) }
  if (-not $settings.hooks.PSObject.Properties['SessionStart']) { $settings.hooks | Add-Member SessionStart @() }
  $settings.hooks.SessionStart = @($settings.hooks.SessionStart) + $entry
  Write-Utf8 $settingsPath ($settings | ConvertTo-Json -Depth 20)
}

Step 'CLAUDE.md qaydası'
$claudeMd = Join-Path $ClaudeDir 'CLAUDE.md'
if (-not ((Test-Path $claudeMd) -and (Select-String -Path $claudeMd -Pattern '## Agency agents' -Quiet))) {
  $existing = if (Test-Path $claudeMd) { Get-Content $claudeMd -Raw } else { '' }
  Write-Utf8 $claudeMd ($existing + @'

## Agency agents
`~/.claude/agents/` holds the msitarzewski/agency-agents roster (282 specialist subagents: engineering, design, marketing, finance, security, testing, etc.).
When a task clearly fits one of these specialists, delegate it to (or adopt the persona of) that agent instead of handling it generically, and tell the user which agent was used.
'@ + "`n")
}

Write-Host ""
Write-Host "==> Hazırdır. Log: $Log" -ForegroundColor Green
Write-Host "Claude Code-u yenidən açın ki, dəyişikliklər yüklənsin."
Stop-Transcript | Out-Null
