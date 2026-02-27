import Foundation
import PostgresNIO
import Logging
import NIOCore
import NIOPosix

// MARK: - Argument Parsing

enum Mode {
    case generate
    case list
    case export(String)
}

struct Config {
    var mode: Mode = .generate
    var topic: String = ""
    var age: String = "8-10"
    var count: Int = 20
    var output: String? = nil
    var voice: String? = nil
    var noSave: Bool = false
}

func printUsage() -> Never {
    fputs("""
    Usage: obo-gen <topic> [options]
           obo-gen --list
           obo-gen --export <id>

    Options:
      --age, -a <range>     Target age range (default: 8-10)
      -n <count>            Number of Q&A cards (default: 20)
      --output, -o <path>   Output file path (default: stdout)
      --voice <hint>        Append a voice hint line for obo
      --no-save             Skip saving to database
      --list                List all saved decks
      --export <id>         Export a saved deck by UUID (or prefix)
      --help, -h            Show this help

    Examples:
      obo-gen "Solar System" --age 6-8 --output ~/Documents/decks/solar.txt
      obo-gen "US Presidents"
      obo-gen "Basic French Vocabulary" -n 30
      obo-gen --list
      obo-gen --export a3b2c1d4

    Requires OPENAI_API_KEY environment variable (for generation).

    Database environment variables (CE_DB_* preferred, OBO_DB_* fallback):
      CE_DB_HOST        (default: localhost)
      CE_DB_PORT        (default: 5432)
      CE_DB_USER        (default: postgres)
      CE_DB_PASSWORD    (default: postgres)
      CE_DB_NAME        (default: card_engine)
    """, stderr)
    exit(0)
}

func parseArgs() -> Config {
    let args = Array(CommandLine.arguments.dropFirst())
    guard !args.isEmpty else { printUsage() }

    var config = Config()
    var i = 0
    var topicSet = false

    while i < args.count {
        let arg = args[i]
        switch arg {
        case "--help", "-h":
            printUsage()
        case "--list":
            config.mode = .list
        case "--export":
            i += 1
            guard i < args.count, !args[i].isEmpty else {
                fputs("Error: --export requires a deck ID (UUID or prefix)\n", stderr)
                exit(1)
            }
            config.mode = .export(args[i])
        case "--no-save":
            config.noSave = true
        case "--age", "-a":
            i += 1
            guard i < args.count else {
                fputs("Error: --age requires a value\n", stderr)
                exit(1)
            }
            config.age = args[i]
        case "-n":
            i += 1
            guard i < args.count, let n = Int(args[i]), n > 0 else {
                fputs("Error: -n requires a positive integer\n", stderr)
                exit(1)
            }
            config.count = n
        case "--output", "-o":
            i += 1
            guard i < args.count else {
                fputs("Error: --output requires a path\n", stderr)
                exit(1)
            }
            config.output = args[i]
        case "--voice":
            i += 1
            guard i < args.count else {
                fputs("Error: --voice requires a value\n", stderr)
                exit(1)
            }
            config.voice = args[i]
        default:
            if arg.hasPrefix("-") {
                fputs("Error: unknown option '\(arg)'\n", stderr)
                exit(1)
            }
            if topicSet {
                fputs("Error: unexpected argument '\(arg)'\n", stderr)
                exit(1)
            }
            config.topic = arg
            topicSet = true
        }
        i += 1
    }

    if case .generate = config.mode {
        guard topicSet else {
            fputs("Error: topic is required for generation\n", stderr)
            exit(1)
        }
    }

    return config
}

// MARK: - OpenAI API

struct ChatMessage: Codable {
    let role: String
    let content: String
}

struct ChatRequest: Codable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Double
}

struct ChatResponse: Codable {
    struct Choice: Codable {
        struct Message: Codable {
            let content: String
        }
        let message: Message
    }
    let choices: [Choice]
}

struct ErrorResponse: Codable {
    struct ErrorDetail: Codable {
        let message: String
    }
    let error: ErrorDetail
}

func callOpenAI(config: Config, apiKey: String) async throws -> String {
    let systemPrompt = """
    You generate flashcard decks for children. Output ONLY the deck in this exact format, nothing else:

    Title: <topic>

    Q: <question> | A: <answer>

    Generate exactly \(config.count) question/answer pairs about "\(config.topic)" appropriate for ages \(config.age). Keep questions and answers short and clear.
    """

    let userPrompt = "Generate a \(config.count)-card flashcard deck about \"\(config.topic)\" for ages \(config.age)."

    let request = ChatRequest(
        model: "gpt-4o-mini",
        messages: [
            ChatMessage(role: "system", content: systemPrompt),
            ChatMessage(role: "user", content: userPrompt)
        ],
        temperature: 0.7
    )

    let url = URL(string: "https://api.openai.com/v1/chat/completions")!
    var urlRequest = URLRequest(url: url)
    urlRequest.httpMethod = "POST"
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    urlRequest.httpBody = try JSONEncoder().encode(request)
    urlRequest.timeoutInterval = 60

    fputs("Generating \(config.count) flashcards about \"\(config.topic)\" for ages \(config.age)...\n", stderr)

    let (data, response) = try await URLSession.shared.data(for: urlRequest)

    guard let httpResponse = response as? HTTPURLResponse else {
        throw NSError(domain: "obo-gen", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
    }

    guard httpResponse.statusCode == 200 else {
        if let errorResp = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
            throw NSError(domain: "obo-gen", code: httpResponse.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "API error (\(httpResponse.statusCode)): \(errorResp.error.message)"])
        }
        throw NSError(domain: "obo-gen", code: httpResponse.statusCode,
                      userInfo: [NSLocalizedDescriptionKey: "API error: HTTP \(httpResponse.statusCode)"])
    }

    let chatResponse = try JSONDecoder().decode(ChatResponse.self, from: data)
    guard let content = chatResponse.choices.first?.message.content else {
        throw NSError(domain: "obo-gen", code: 2, userInfo: [NSLocalizedDescriptionKey: "Empty response from API"])
    }

    return content
}

// MARK: - Card Parsing

struct Card {
    let question: String
    let answer: String
}

struct ParsedDeck {
    let title: String
    let cards: [Card]
}

func parseDeck(from content: String) -> ParsedDeck {
    let lines = content.components(separatedBy: "\n")
    var title = ""
    var cards: [Card] = []

    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if trimmed.hasPrefix("Title:") {
            title = trimmed.replacingOccurrences(of: "Title:", with: "").trimmingCharacters(in: .whitespaces)
            continue
        }

        // Match lines like "Q: ... | A: ..."
        if trimmed.hasPrefix("Q:") && trimmed.contains("| A:") {
            let parts = trimmed.components(separatedBy: "| A:")
            guard parts.count >= 2 else { continue }
            let q = parts[0]
                .replacingOccurrences(of: "Q:", with: "")
                .trimmingCharacters(in: .whitespaces)
            let a = parts.dropFirst().joined(separator: "| A:")
                .trimmingCharacters(in: .whitespaces)
            if !q.isEmpty && !a.isEmpty {
                cards.append(Card(question: q, answer: a))
            }
        }
    }

    return ParsedDeck(title: title.isEmpty ? "Untitled" : title, cards: cards)
}

// MARK: - Database

struct DBConfig {
    let host: String
    let port: Int
    let username: String
    let password: String
    let database: String
}

func loadDBConfig() -> DBConfig {
    let env = ProcessInfo.processInfo.environment
    // Prefer CE_DB_* (card-engine), fall back to OBO_DB_* (legacy)
    let host = env["CE_DB_HOST"] ?? env["OBO_DB_HOST"] ?? "localhost"
    let port = Int(env["CE_DB_PORT"] ?? env["OBO_DB_PORT"] ?? "") ?? 5432
    let username = env["CE_DB_USER"] ?? env["OBO_DB_USER"] ?? "postgres"
    let password = env["CE_DB_PASSWORD"] ?? env["OBO_DB_PASSWORD"] ?? "postgres"
    let database = env["CE_DB_NAME"] ?? env["OBO_DB_NAME"] ?? "card_engine"

    return DBConfig(host: host, port: port, username: username, password: password,
                    database: database)
}

func makeConnection(dbConfig: DBConfig, eventLoop: any EventLoopGroup) async throws -> PostgresConnection {
    var logger = Logger(label: "obo-gen")
    logger.logLevel = .error

    let config = PostgresConnection.Configuration(
        host: dbConfig.host,
        port: dbConfig.port,
        username: dbConfig.username,
        password: dbConfig.password,
        database: dbConfig.database,
        tls: .disable
    )

    // Retry up to 3 times with exponential backoff (1s, 2s, 4s)
    let maxAttempts = 3
    var lastError: Error?

    for attempt in 1...maxAttempts {
        do {
            return try await PostgresConnection.connect(
                on: eventLoop.next(),
                configuration: config,
                id: 1,
                logger: logger
            )
        } catch {
            lastError = error
            if attempt < maxAttempts {
                let delaySeconds = UInt64(1 << (attempt - 1)) // 1, 2, 4
                fputs("DB connection attempt \(attempt)/\(maxAttempts) failed, retrying in \(delaySeconds)s...\n", stderr)
                try await Task.sleep(nanoseconds: delaySeconds * 1_000_000_000)
            }
        }
    }

    throw lastError!
}

func saveDeck(conn: PostgresConnection, parsed: ParsedDeck, config: Config) async throws -> String {
    let logger = Logger(label: "obo-gen")

    // Build JSONB properties: {"age_range": "8-10", "voice": "..."}
    var propsDict: [String: String] = ["age_range": config.age]
    if let voice = config.voice {
        propsDict["voice"] = voice
    }
    let propsData = try JSONSerialization.data(withJSONObject: propsDict)
    let propsJSON = String(data: propsData, encoding: .utf8) ?? "{}"

    // Insert deck row — card-engine schema: UUID id, title, kind, properties JSONB
    let insertDeckQuery: PostgresQuery =
        "INSERT INTO decks (title, kind, properties) VALUES (\(parsed.title), 'flashcard', \(propsJSON)::jsonb) RETURNING id::text"
    let deckRows = try await conn.query(insertDeckQuery, logger: logger)

    var deckId = ""
    for try await row in deckRows {
        (deckId) = try row.decode(String.self)
    }

    guard !deckId.isEmpty else {
        throw NSError(domain: "obo-gen", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to insert deck"])
    }

    // Insert card rows — answer goes into properties JSONB
    for (i, card) in parsed.cards.enumerated() {
        let cardPropsData = try JSONSerialization.data(withJSONObject: ["answer": card.answer])
        let cardPropsJSON = String(data: cardPropsData, encoding: .utf8) ?? "{}"
        let insertCardQuery: PostgresQuery =
            "INSERT INTO cards (deck_id, position, question, properties) VALUES (\(deckId)::uuid, \(i + 1), \(card.question), \(cardPropsJSON)::jsonb)"
        try await conn.query(insertCardQuery, logger: logger)
    }

    return deckId
}

func listDecks(conn: PostgresConnection) async throws {
    let logger = Logger(label: "obo-gen")
    let listQuery: PostgresQuery = """
        SELECT id::text, title, COALESCE(properties->>'age_range', ''), card_count, created_at::text
        FROM decks WHERE kind = 'flashcard' ORDER BY created_at
        """
    let rows = try await conn.query(listQuery, logger: logger)

    var decks: [(String, String, String, Int, String)] = []
    for try await row in rows {
        let (id, title, ageRange, cardCount, createdAt) = try row.decode((String, String, String, Int, String).self)
        decks.append((id, title, ageRange, cardCount, createdAt))
    }

    if decks.isEmpty {
        print("No saved flashcard decks.")
        return
    }

    // Print table
    func pad(_ s: String, _ width: Int) -> String {
        s.count >= width ? String(s.prefix(width)) : s + String(repeating: " ", count: width - s.count)
    }
    func rpad(_ s: String, _ width: Int) -> String {
        s.count >= width ? String(s.prefix(width)) : String(repeating: " ", count: width - s.count) + s
    }
    print("\(pad("ID", 36))  \(pad("Topic", 30))  \(pad("Ages", 8))  \(rpad("Cards", 5))  \(pad("Created", 20))")
    print(String(repeating: "-", count: 107))
    for (id, topic, age, count, date) in decks {
        let truncTopic = topic.count > 30 ? String(topic.prefix(27)) + "..." : topic
        let shortId = String(id.prefix(8))
        print("\(pad(shortId, 36))  \(pad(truncTopic, 30))  \(pad(age, 8))  \(rpad(String(count), 5))  \(pad(date, 20))")
    }
}

func exportDeck(conn: PostgresConnection, deckIdPrefix: String) async throws {
    let logger = Logger(label: "obo-gen")

    // Support UUID prefix matching (e.g. "a3b2" matches "a3b2c1d4-...")
    let fetchDeckQuery: PostgresQuery =
        "SELECT id::text, title, properties->>'voice' FROM decks WHERE kind = 'flashcard' AND id::text LIKE \(deckIdPrefix + "%") LIMIT 1"
    let deckRows = try await conn.query(fetchDeckQuery, logger: logger)

    var deckId = ""
    var title = ""
    var voice: String? = nil
    var found = false
    for try await row in deckRows {
        let row_data = try row.decode((String, String, String?).self)
        deckId = row_data.0
        title = row_data.1
        voice = row_data.2
        found = true
    }

    guard found else {
        fputs("Error: no flashcard deck matching '\(deckIdPrefix)' found\n", stderr)
        exit(1)
    }

    // Fetch cards — answer is in properties JSONB
    let fetchCardsQuery: PostgresQuery =
        "SELECT question, COALESCE(properties->>'answer', '') FROM cards WHERE deck_id = \(deckId)::uuid ORDER BY position"
    let cardRows = try await conn.query(fetchCardsQuery, logger: logger)

    var output = "Title: \(title)\n\n"
    for try await row in cardRows {
        let (q, a) = try row.decode((String, String).self)
        output += "Q: \(q) | A: \(a)\n"
    }

    if let voice = voice {
        output += "\nVoice: \(voice)\n"
    }

    print(output, terminator: "")
}

// MARK: - DB Connection Helper

func withDB<T: Sendable>(_ body: @Sendable (PostgresConnection) async throws -> T) async throws -> T {
    let dbConfig = loadDBConfig()
    let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let conn = try await makeConnection(dbConfig: dbConfig, eventLoop: eventLoopGroup)
    let result: T
    do {
        result = try await body(conn)
    } catch {
        try? await conn.close()
        try? eventLoopGroup.syncShutdownGracefully()
        throw error
    }
    try? await conn.close()
    try? eventLoopGroup.syncShutdownGracefully()
    return result
}

// MARK: - Main

let config = parseArgs()

let semaphore = DispatchSemaphore(value: 0)
var exitCode: Int32 = 0

Task {
    do {
        switch config.mode {
        case .list:
            try await withDB { conn in
                try await listDecks(conn: conn)
            }

        case .export(let idPrefix):
            try await withDB { conn in
                try await exportDeck(conn: conn, deckIdPrefix: idPrefix)
            }

        case .generate:
            guard let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !apiKey.isEmpty else {
                fputs("Error: OPENAI_API_KEY environment variable is not set\n", stderr)
                exitCode = 1
                semaphore.signal()
                return
            }

            var content = try await callOpenAI(config: config, apiKey: apiKey)

            // Append voice hint if requested
            if let voice = config.voice {
                content += "\n\nVoice: \(voice)"
            }

            // Ensure trailing newline
            if !content.hasSuffix("\n") {
                content += "\n"
            }

            // Save to database unless --no-save
            if !config.noSave {
                let parsed = parseDeck(from: content)
                if parsed.cards.isEmpty {
                    fputs("Warning: no Q|A cards parsed, skipping DB save\n", stderr)
                } else {
                    do {
                        let deckId = try await withDB { conn in
                            try await saveDeck(conn: conn, parsed: parsed, config: config)
                        }
                        fputs("Saved deck #\(deckId) (\(parsed.cards.count) cards) to database\n", stderr)
                    } catch {
                        fputs("Warning: failed to save to database: \(error.localizedDescription)\n", stderr)
                    }
                }
            }

            // Output to file or stdout
            if let outputPath = config.output {
                let expandedPath = NSString(string: outputPath).expandingTildeInPath
                let dir = (expandedPath as NSString).deletingLastPathComponent
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                do {
                    try content.write(toFile: expandedPath, atomically: true, encoding: .utf8)
                    fputs("Wrote \(config.count) cards to \(expandedPath)\n", stderr)
                } catch {
                    fputs("Error writing file: \(error.localizedDescription)\n", stderr)
                    exitCode = 1
                }
            } else {
                print(content, terminator: "")
            }
        }
    } catch {
        fputs("Error: \(error.localizedDescription)\n", stderr)
        exitCode = 1
    }
    semaphore.signal()
}

semaphore.wait()
exit(exitCode)
