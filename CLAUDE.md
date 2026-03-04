# obo-gen

CLI content generator for the cardzerver ecosystem. Uses GPT-4o-mini or Claude Haiku to generate flashcard and trivia decks, storing them in Postgres.

## Stack
- Swift 5.9+, macOS 13+
- PostgresNIO (async Postgres driver, Vapor team)
- swift-argument-parser (CLI subcommands)
- Foundation URLSession (OpenAI + Anthropic APIs)
- Package manager: Swift Package Manager

## Common Commands
- `swift build -c release` — build release binary
- `cp .build/release/obo-gen ~/bin/` — install to PATH
- `swift build` — debug build

## Usage

```
obo-gen generate <topic> [options]     # Generate a deck (default subcommand)
obo-gen list [--kind <kind>]           # List all saved decks
obo-gen export <id>                    # Export a deck by UUID or prefix
obo-gen delete <id>                    # Delete a deck and its cards
obo-gen stats                          # Show database statistics
obo-gen batch <file> [options]         # Bulk generate from topics file
```

### Generate Options

| Flag | Description | Default |
|------|-------------|---------|
| `-a, --age <range>` | Target age range | `8-10` |
| `-n, --count <N>` | Number of cards | `20` |
| `-k, --kind <kind>` | `flashcard` or `trivia` | `flashcard` |
| `-m, --model <model>` | `gpt` (GPT-4o-mini) or `claude` (Haiku 4.5) | `gpt` |
| `-d, --difficulty <level>` | `easy`, `medium`, or `hard` | unset |
| `-o, --output <path>` | Output file path | stdout |
| `--voice <hint>` | Append voice hint line | — |
| `--no-save` | Skip saving to database | `false` |
| `--force` | Create even if duplicate title exists | `false` |

### Examples

```bash
# Flashcard deck via GPT (default)
obo-gen "Solar System" -n 30 --age 6-8

# Trivia deck via Claude Haiku
obo-gen "US Presidents" -n 20 --kind trivia --model claude

# Hard difficulty, save to file only
obo-gen "Quantum Physics" --difficulty hard --no-save -o ~/decks/quantum.txt

# Batch generate from file
echo "Solar System\nUS Presidents\nAncient Rome" > topics.txt
obo-gen batch topics.txt --kind trivia --model claude -n 15

# Database operations
obo-gen list                    # All decks
obo-gen list --kind trivia      # Only trivia
obo-gen stats                   # Deck/card counts
obo-gen export a3b2c1d4         # Export by ID prefix
obo-gen delete a3b2c1d4         # Delete by ID prefix
```

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `OPENAI_API_KEY` | Required for `--model gpt` | — |
| `ANTHROPIC_API_KEY` | Required for `--model claude` | — |
| `CE_DB_HOST` | Postgres host | `localhost` |
| `CE_DB_PORT` | Postgres port | `5432` |
| `CE_DB_USER` | Postgres username | `postgres` |
| `CE_DB_PASSWORD` | Postgres password | `postgres` |
| `CE_DB_NAME` | Postgres database name | `card_engine` |

Legacy `OBO_DB_*` env vars are still supported as fallbacks.

## Database

Uses the cardzerver Postgres database (`card_engine`). Writes to the unified `decks` + `cards` tables with UUID primary keys and JSONB `properties`.

### Schema (cardzerver unified)
```sql
-- Decks: kind = 'flashcard' or 'trivia'
CREATE TABLE decks (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    title      TEXT NOT NULL,
    kind       card_kind NOT NULL,
    properties JSONB NOT NULL DEFAULT '{}',
    card_count INTEGER NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Cards: question + properties JSONB
CREATE TABLE cards (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    deck_id    UUID NOT NULL REFERENCES decks(id) ON DELETE CASCADE,
    position   INTEGER NOT NULL,
    question   TEXT NOT NULL,
    properties JSONB NOT NULL DEFAULT '{}'
);
```

### Card Properties by Kind

| Kind | Properties JSONB fields |
|------|------------------------|
| `flashcard` | `answer`, optionally `difficulty` |
| `trivia` | `answer`, `choices` (array), `correct` (int 0-3), optionally `difficulty` |

## Features

- **Duplicate detection**: Warns if a deck with the same title+kind exists (use `--force` to override)
- **Batch mode**: Generate many decks from a topics file (one per line, `#` comments supported)
- **Difficulty tagging**: `--difficulty easy/medium/hard` stored in deck + card properties
- **Two AI models**: GPT-4o-mini (fast, cheap) and Claude Haiku 4.5 (alternative)
- **DB save failures are non-fatal**: Output still goes to stdout/file

## Cross-Project Sync (cardzerver ecosystem)

- `~/cardzerver` — Unified FastAPI backend (serves decks via API), port 9810
- `~/obo-gen` — This CLI generator (writes decks to cardzerver Postgres)
- `~/obo-ios` — SwiftUI iOS flashcard app (consumes `/api/v1/flashcards`)
- `~/alities-mobile` — SwiftUI iOS trivia app (consumes `/api/v1/trivia`)
- `~/qross` — SwiftUI iOS trivia game (consumes `/api/v1/trivia/gamedata`)
- `~/cardz-studio` — React web UI for content management (port 9850)

| Change | Action |
|--------|--------|
| Postgres host/port/credentials change | Update `CE_DB_*` env vars |
| Card properties schema changes | Update cardzerver adapters + iOS models |
| New card kind added | Add prompt builder + parser in main.swift |

## Architecture
- Single-file Swift executable (`Sources/main.swift`)
- ArgumentParser subcommands: generate, list, export, delete, stats, batch
- Flashcard format: `Title:` header + `Q: ... | A: ...` lines
- Trivia format: `Title:` header + `Q:` + `A-D)` choices + `ANSWER:` letter
- DB writes use PostgresNIO parameterized bindings (no string interpolation)
- DB connection has retry logic: 3 attempts with exponential backoff
- Installed to `~/bin/obo-gen` for global PATH availability
