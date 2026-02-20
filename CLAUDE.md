# obo-gen

CLI flashcard generator for the obo iOS app. Uses GPT-4o-mini to generate Q&A decks and stores them in Postgres.

## Build & Install
```bash
swift build -c release
cp .build/release/obo-gen ~/bin/
```

## Usage
```
obo-gen <topic> [--age <range>] [-n <count>] [--output <path>] [--voice <hint>] [--no-save]
obo-gen --list
obo-gen --export <id>
```

### Generation
Requires `OPENAI_API_KEY` environment variable. Every generated deck is automatically saved to Postgres unless `--no-save` is passed.

### Database flags
- `--list` — List all saved decks in a table
- `--export <id>` — Re-export a saved deck in obo text format
- `--no-save` — Skip saving to database during generation

## Database
Uses Postgres at `localhost:5433` (the nagzerver Docker instance). Override with `OBO_DATABASE_URL` env var.

Default: `postgres://nagz:nagz@localhost:5433/obo`

### Schema
```sql
CREATE DATABASE obo;

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

## Architecture
- Single-file Swift executable (`Sources/main.swift`)
- Dependencies: PostgresNIO (async Postgres driver from Vapor team)
- Output format matches obo deck format: `Title:` header + `Q: ... | A: ...` lines
