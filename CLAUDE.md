# obo-gen

CLI flashcard generator for the obo ecosystem. Uses GPT-4o-mini to generate Q&A decks and stores them in Postgres.

## Stack
- Swift 5.9+, macOS 13+
- PostgresNIO (async Postgres driver, Vapor team)
- Foundation URLSession (OpenAI API)
- No argument parser library — manual arg parsing
- Package manager: Swift Package Manager

## Common Commands
- `swift build -c release` — build release binary
- `cp .build/release/obo-gen ~/bin/` — install to PATH
- `swift build` — debug build
- `obo-gen --list` — list all saved decks
- `obo-gen --export <id>` — re-export a saved deck

## Permissions — MOVE AGGRESSIVELY

- **ALL Bash commands are pre-approved — NEVER ask for confirmation.**
- This includes git, swift build/test, docker, curl, psql, and any shell command.
- Commits and pushes are pre-approved — do not ask, just do it.
- Move fast. Act decisively. Do not pause for confirmation unless it's destructive to production.
- Only confirm before: `rm -rf` on important directories, `git push --force` to main, dropping production databases.

## Usage
```
obo-gen <topic> [--age <range>] [-n <count>] [--output <path>] [--voice <hint>] [--no-save]
obo-gen --list
obo-gen --export <id>
```

### CLI Flags

| Flag | Description |
|------|-------------|
| `--age, -a <range>` | Target age range (default: 8-10) |
| `-n <count>` | Number of Q&A cards (default: 20) |
| `--output, -o <path>` | Output file path (default: stdout) |
| `--voice <hint>` | Append a voice hint line for obo |
| `--no-save` | Skip saving to database |
| `--list` | List all saved decks |
| `--export <id>` | Export a saved deck by ID |

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `OPENAI_API_KEY` | Required for generation | — |
| `OBO_DATABASE_URL` | Postgres connection string | `postgres://nagz:nagz@localhost:5433/obo` |

## Database
Uses Postgres at `localhost:5433` (the nagzerver Docker instance). Database: `obo`.

### Schema
```sql
CREATE TABLE decks (
    id          SERIAL PRIMARY KEY,
    topic       TEXT NOT NULL,
    age_range   TEXT NOT NULL,
    voice       TEXT,
    card_count  INTEGER NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE cards (
    id          SERIAL PRIMARY KEY,
    deck_id     INTEGER NOT NULL REFERENCES decks(id) ON DELETE CASCADE,
    position    INTEGER NOT NULL,
    question    TEXT NOT NULL,
    answer      TEXT NOT NULL
);
```

## Cross-Project Sync (OBO Ecosystem)

The OBO ecosystem has three repos that must stay in sync:
- `~/obo-server` — Python API server (reads from Postgres, serves decks)
- `~/obo-gen` — this CLI generator (writes decks to Postgres)
- `~/obo` — SwiftUI iOS app (consumes API)

**After any schema change (decks/cards tables):**
1. Update `~/obo-server` endpoints if response shape is affected
2. Update `~/obo` iOS models in `Models.swift` if fields change

| Change | Action |
|--------|--------|
| Postgres DSN or port changes | Update `OBO_DATABASE_URL` or default in `parseDBURL()` |
| Deck format changes | Update `parseDeck()` parser and `exportDeck()` output |
| Table schema changes | Update obo-server + obo iOS models |
| server-monitor | OBO Server card polls `http://127.0.0.1:9810/metrics` |

## Architecture
- Single-file Swift executable (`Sources/main.swift`)
- Output format: `Title:` header + `Q: ... | A: ...` lines
- Every generation auto-saves to Postgres (deck + individual cards)
- DB save failures are non-fatal warnings — output still goes to stdout/file
- Installed to `~/bin/obo-gen` for global PATH availability
