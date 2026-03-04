# obo-gen

CLI content generator for the cardzerver ecosystem. Uses GPT-4o-mini, Claude Haiku, or Apple's on-device model to generate flashcard and trivia decks, saving them via the cardzerver API.

## Stack
- Swift 6.2, macOS 26+
- swift-argument-parser (AsyncParsableCommand subcommands)
- FoundationModels (Apple Intelligence on-device ~3B LLM)
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
| `-m, --model <model>` | `gpt`, `claude`, or `onboard` (see Models below) | `gpt` |
| `-d, --difficulty <level>` | `easy`, `medium`, or `hard` | unset |
| `-o, --output <path>` | Output file path | stdout |
| `--voice <hint>` | Append voice hint line | — |
| `--no-save` | Skip saving to cardzerver | `false` |
| `--force` | Create even if duplicate title exists | `false` |

### Models

| Model | Flag | API Key | Cost | Notes |
|-------|------|---------|------|-------|
| GPT-4o-mini | `--model gpt` | `OPENAI_API_KEY` | Pay per token | Default, cloud |
| Claude Haiku 4.5 | `--model claude` | `ANTHROPIC_API_KEY` | Pay per token | Cloud |
| Apple Intelligence | `--model onboard` | None | Free | On-device ~3B LLM, requires macOS 26 with Apple Intelligence enabled |

### Examples

```bash
# Flashcard deck via GPT (default)
obo-gen "Solar System" -n 30 --age 6-8

# Trivia deck via Claude Haiku
obo-gen "US Presidents" -n 20 --kind trivia --model claude

# Free on-device generation (no API key needed)
obo-gen "Volcanoes" -n 10 --kind trivia --model onboard

# Hard difficulty, save to file only
obo-gen "Quantum Physics" --difficulty hard --no-save -o ~/decks/quantum.txt

# Batch generate from file
echo "Solar System\nUS Presidents\nAncient Rome" > topics.txt
obo-gen batch topics.txt --kind trivia --model onboard -n 15

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
- AI generation via OpenAI (GPT-4o-mini), Anthropic (Claude Haiku 4.5), or Apple FoundationModels (on-device)
- Flashcard format: `Title:` header + `Q: ... | A: ...` lines
- Trivia format: `Title:` header + `Q:` + `A-D)` choices + `ANSWER:` letter
- Installed to `~/bin/obo-gen` for global PATH availability

## Features

- **Duplicate detection**: Warns if a deck with the same title+kind exists (use `--force` to override)
- **Batch mode**: Generate many decks from a topics file (one per line, `#` comments supported)
- **Difficulty tagging**: `--difficulty easy/medium/hard` stored in deck + card properties
- **Three AI models**: GPT-4o-mini (cloud), Claude Haiku 4.5 (cloud), Apple Intelligence (free, on-device)
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
