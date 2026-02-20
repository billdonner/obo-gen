import Foundation
import PostgresNIO
import Logging
import NIOCore
import NIOPosix

// MARK: - Argument Parsing

enum Mode {
    case generate
    case list
    case export(Int)
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
      --export <id>         Export a saved deck by ID
      --help, -h            Show this help

    Examples:
      obo-gen "Solar System" --age 6-8 --output ~/Documents/decks/solar.txt
      obo-gen "US Presidents"
      obo-gen "Basic French Vocabulary" -n 30
      obo-gen --list
      obo-gen --export 3

    Requires OPENAI_API_KEY environment variable (for generation).
    Uses OBO_DATABASE_URL or defaults to postgres://nagz:nagz@localhost:5433/obo
    """, stderr)
    exit(1)
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
            guard i < args.count, let id = Int(args[i]), id > 0 else {
                fputs("Error: --export requires a positive integer deck ID\n", stderr)
                exit(1)
            }
            config.mode = .export(id)
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

func parseDBURL() -> DBConfig {
    let urlStr = ProcessInfo.processInfo.environment["OBO_DATABASE_URL"]
        ?? "postgres://nagz:nagz@localhost:5433/obo"

    // Parse: postgres://user:pass@host:port/dbname
    guard let url = URL(string: urlStr) else {
        fputs("Error: invalid OBO_DATABASE_URL\n", stderr)
        exit(1)
    }

    let host = url.host ?? "localhost"
    let port = url.port ?? 5433
    let username = url.user ?? "nagz"
    let password = url.password ?? "nagz"
    let database = String(url.path.dropFirst()) // remove leading /

    return DBConfig(host: host, port: port, username: username, password: password,
                    database: database.isEmpty ? "obo" : database)
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

    return try await PostgresConnection.connect(
        on: eventLoop.next(),
        configuration: config,
        id: 1,
        logger: logger
    )
}

func saveDeck(conn: PostgresConnection, parsed: ParsedDeck, config: Config) async throws -> Int {
    // Insert deck row
    let deckRows = try await conn.query(
        """
        INSERT INTO decks (topic, age_range, voice, card_count)
        VALUES (\(parsed.title), \(config.age), \(config.voice as String?), \(parsed.cards.count))
        RETURNING id
        """,
        logger: Logger(label: "obo-gen")
    )

    var deckId = 0
    for try await row in deckRows {
        (deckId) = try row.decode(Int.self)
    }

    guard deckId > 0 else {
        throw NSError(domain: "obo-gen", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to insert deck"])
    }

    // Insert card rows
    for (i, card) in parsed.cards.enumerated() {
        try await conn.query(
            """
            INSERT INTO cards (deck_id, position, question, answer)
            VALUES (\(deckId), \(i + 1), \(card.question), \(card.answer))
            """,
            logger: Logger(label: "obo-gen")
        )
    }

    return deckId
}

func listDecks(conn: PostgresConnection) async throws {
    let rows = try await conn.query(
        "SELECT id, topic, age_range, card_count, created_at::text FROM decks ORDER BY id",
        logger: Logger(label: "obo-gen")
    )

    var decks: [(Int, String, String, Int, String)] = []
    for try await row in rows {
        let (id, topic, ageRange, cardCount, createdAt) = try row.decode((Int, String, String, Int, String).self)
        decks.append((id, topic, ageRange, cardCount, createdAt))
    }

    if decks.isEmpty {
        print("No saved decks.")
        return
    }

    // Print table
    func pad(_ s: String, _ width: Int) -> String {
        s.count >= width ? String(s.prefix(width)) : s + String(repeating: " ", count: width - s.count)
    }
    func rpad(_ s: String, _ width: Int) -> String {
        s.count >= width ? String(s.prefix(width)) : String(repeating: " ", count: width - s.count) + s
    }
    print("\(pad("ID", 4))  \(pad("Topic", 30))  \(pad("Ages", 8))  \(rpad("Cards", 5))  \(pad("Created", 20))")
    print(String(repeating: "-", count: 75))
    for (id, topic, age, count, date) in decks {
        let truncTopic = topic.count > 30 ? String(topic.prefix(27)) + "..." : topic
        print("\(pad(String(id), 4))  \(pad(truncTopic, 30))  \(pad(age, 8))  \(rpad(String(count), 5))  \(pad(date, 20))")
    }
}

func exportDeck(conn: PostgresConnection, deckId: Int) async throws {
    // Fetch deck
    let deckRows = try await conn.query(
        "SELECT topic, age_range, voice FROM decks WHERE id = \(deckId)",
        logger: Logger(label: "obo-gen")
    )

    var topic = ""
    var voice: String? = nil
    var found = false
    for try await row in deckRows {
        let row_data = try row.decode((String, String, String?).self)
        topic = row_data.0
        voice = row_data.2
        found = true
    }

    guard found else {
        fputs("Error: deck \(deckId) not found\n", stderr)
        exit(1)
    }

    // Fetch cards
    let cardRows = try await conn.query(
        "SELECT question, answer FROM cards WHERE deck_id = \(deckId) ORDER BY position",
        logger: Logger(label: "obo-gen")
    )

    var output = "Title: \(topic)\n\n"
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
    let dbConfig = parseDBURL()
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

        case .export(let id):
            try await withDB { conn in
                try await exportDeck(conn: conn, deckId: id)
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
