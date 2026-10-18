# claude-setup

Claude Code bulud sessiyaları üçün setup script.

Quraşdırır: find-skills, tradermonty trading skill-ləri, task-observer (+ SessionStart hook), claude-mem, headroom (MCP), msitarzewski/agency-agents (yoxlanmış commit-ə bağlı).

Mühitin **Setup script** sahəsinə:

```bash
curl -fsSL https://raw.githubusercontent.com/Codillac007/claude-setup/main/setup-claude.sh | bash
```

## Windows (öz kompüterində)

PowerShell-i açın (administrator lazım deyil) və işə salın:

```powershell
irm https://raw.githubusercontent.com/Codillac007/claude-setup/main/setup-claude.ps1 | iex
```

Node.js, Git, uv və Claude Code yoxdursa, `winget` ilə quraşdırır. Log: `%USERPROFILE%\claude-setup.log`.
