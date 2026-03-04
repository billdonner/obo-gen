# obo-gen

CLI content generator for the cardzerver ecosystem. Uses GPT-4o-mini or Claude Haiku to generate flashcard and trivia decks, saving them via the cardzerver API.

## Stack
- Swift 5.9+, macOS 13+
- swift-argument-parser (CLI subcommands)
- Foundation URLSession (OpenAI, Anthropic, and cardzerver APIs)
- No database driver — all DB operations go through cardzerver's REST API
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
| `--no-save` | Skip saving to cardzerver | `false` |
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

# Database operations (via cardzerver API)
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
| `CARDZERVER_URL` | Cardzerver API base URL | `https://bd-cardzerver.fly.dev` |

## Architecture

- Single-file Swift executable (`Sources/main.swift`)
- ArgumentParser subcommands: generate, list, export, delete, stats, batch
- **No direct database access** — all operations go through cardzerver REST API:
  - `POST /api/v1/studio/decks/bulk` — create deck + cards in one transaction
  - `GET /api/v1/decks` — list decks
  - `GET /api/v1/decks/{id}` — get deck with cards
  - `DELETE /api/v1/studio/decks/{id}` — delete deck
  - `GET /api/v1/studio/stats` — database statistics
  - `GET /api/v1/studio/check-duplicate` — duplicate title check
- AI generation via OpenAI (GPT-4o-mini) or Anthropic (Claude Haiku 4.5)
- Flashcard format: `Title:` header + `Q: ... | A: ...` lines
- Trivia format: `Title:` header + `Q:` + `A-D)` choices + `ANSWER:` letter
- Installed to `~/bin/obo-gen` for global PATH availability

## Features

- **Duplicate detection**: Warns if a deck with the same title+kind exists (use `--force` to override)
- **Batch mode**: Generate many decks from a topics file (one per line, `#` comments supported)
- **Difficulty tagging**: `--difficulty easy/medium/hard` stored in deck + card properties
- **Two AI models**: GPT-4o-mini (fast, cheap) and Claude Haiku 4.5 (alternative)
- **API-first**: All DB operations go through cardzerver, visible in cardz-studio immediately

## Cross-Project Sync (cardzerver ecosystem)

- `~/cardzerver` — Unified FastAPI backend (serves decks via API), port 9810
- `~/obo-gen` — This CLI generator (creates decks via cardzerver API)
- `~/obo-ios` — SwiftUI iOS flashcard app (consumes `/api/v1/flashcards`)
- `~/alities-mobile` — SwiftUI iOS trivia app (consumes `/api/v1/trivia`)
- `~/qross` — SwiftUI iOS trivia game (consumes `/api/v1/trivia/gamedata`)
- `~/cardz-studio` — React web UI for content management (port 9850)

| Change | Action |
|--------|--------|
| Cardzerver URL changes | Update `CARDZERVER_URL` env var |
| Studio API shape changes | Update `CardzerverClient` in main.swift |
| New card kind added | Add prompt builder + parser in main.swift |
