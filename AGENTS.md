# AGENTS.md

Enact is a thin action layer for application writes. `spec.md` is the design. `usage-rules.md` is for host-app authors. `RELEASING.md` describes how releases are cut. Agent skills for repo workflows live in `.agents/skills/` (`.claude/skills` is a symlink to it).

## Commands

- `mix test` — package suite
- `mix format` — Elixir formatter
- `mix docs` — ExDoc

## Documentation and comments

Follow the [Google developer documentation style guide](https://developers.google.com/style).

Write dead prose. State what the code does, what the caller gets, and what to do next. Do not argue the design, narrate the change, or explain why an alternative was rejected — that belongs in `spec.md`.

- Present tense, active voice, second person ("you", not "we" or "let's")
- Short sentences. Lead with the fact.
- No aphorisms, slogans, or flourishes
- Do not call a step trivial ("simply call", "just pass", "it's easy to")
- No metaphors or figurative language
- Comments explain non-obvious constraints, not what the next line does
