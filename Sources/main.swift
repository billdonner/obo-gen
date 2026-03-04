import Foundation
import PostgresNIO
import Logging
import NIOCore
import NIOPosix
import ArgumentParser

// MARK: - Shared Types

enum CardKind: String, CaseIterable, ExpressibleByArgument {
    case flashcard
    case trivia
}

enum Difficulty: String, CaseIterable, ExpressibleByArgument {
    case easy
    case medium
    case hard
}

enum AIModel: String, CaseIterable, ExpressibleByArgument {
    case gpt = "gpt"
    case claude = "claude"
}

struct Card {
    let question: String
    let answer: String
    let choices: [String]?       // trivia only
    let correctIndex: Int?       // trivia only
    let difficulty: Difficulty?
}

struct ParsedDeck {
    let title: String
    let cards: [Card]
}

// MARK: - Database Config

struct DBConfig {
    let host: String
    let port: Int
    let username: String
    let password: String
    let database: String
}

func loadDBConfig() -> DBConfig {
    let env = ProcessInfo.processInfo.environment
    let host = env["CE_DB_HOST"] ?? env["OBO_DB_HOST"] ?? "localhost"
    let port = Int(env["CE_DB_PORT"] ?? env["OBO_DB_PORT"] ?? "") ?? 5432
    let username = env["CE_DB_USER"] ?? env["OBO_DB_USER"] ?? "postgres"
    let password = env["CE_DB_PASSWORD"] ?? env["OBO_DB_PASSWORD"] ?? "postgres"
    let database = env["CE_DB_NAME"] ?? env["OBO_DB_NAME"] ?? "card_engine"
    return DBConfig(host: host, port: port, username: username, password: password, database: database)
}

func makeConnection(dbConfig: DBConfig, eventLoop: any EventLoopGroup) async throws -> PostgresConnection {
    var logger = Logger(label: "obo-gen")
    logger.logLevel = .error
    let config = PostgresConnection.Configuration(
        host: dbConfig.host, port: dbConfig.port,
        username: dbConfig.username, password: dbConfig.password,
        database: dbConfig.database, tls: .disable
    )
    let maxAttempts = 3
    var lastError: Error?
    for attempt in 1...maxAttempts {
        do {
            return try await PostgresConnection.connect(
                on: eventLoop.next(), configuration: config, id: 1, logger: logger
            )
        } catch {
            lastError = error
            if attempt < maxAttempts {
                let delay = UInt64(1 << (attempt - 1))
                fputs("DB connection attempt \(attempt)/\(maxAttempts) failed, retrying in \(delay)s...\n", stderr)
                try await Task.sleep(nanoseconds: delay * 1_000_000_000)
            }
        }
    }
    throw lastError!
}

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

// MARK: - AI API Calls

struct ChatMessage: Codable {
    let role: String
    let content: String
}

// OpenAI
struct OpenAIChatRequest: Codable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Double
}

struct OpenAIChatResponse: Codable {
    struct Choice: Codable {
        struct Message: Codable { let content: String }
        let message: Message
    }
    let choices: [Choice]
}

struct OpenAIErrorResponse: Codable {
    struct ErrorDetail: Codable { let message: String }
    let error: ErrorDetail
}

// Claude (Anthropic Messages API)
struct ClaudeRequest: Codable {
    let model: String
    let max_tokens: Int
    let messages: [ChatMessage]
    let system: String?
    let temperature: Double?
}

struct ClaudeResponse: Codable {
    struct ContentBlock: Codable { let text: String? }
    let content: [ContentBlock]
}

struct ClaudeErrorResponse: Codable {
    struct ErrorDetail: Codable { let message: String }
    let error: ErrorDetail
}

func callOpenAI(systemPrompt: String, userPrompt: String, apiKey: String) async throws -> String {
    let request = OpenAIChatRequest(
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

    let (data, response) = try await URLSession.shared.data(for: urlRequest)
    guard let httpResponse = response as? HTTPURLResponse else {
        throw OboGenError.apiError("Invalid response")
    }
    guard httpResponse.statusCode == 200 else {
        if let err = try? JSONDecoder().decode(OpenAIErrorResponse.self, from: data) {
            throw OboGenError.apiError("OpenAI (\(httpResponse.statusCode)): \(err.error.message)")
        }
        throw OboGenError.apiError("OpenAI HTTP \(httpResponse.statusCode)")
    }
    let chatResponse = try JSONDecoder().decode(OpenAIChatResponse.self, from: data)
    guard let content = chatResponse.choices.first?.message.content else {
        throw OboGenError.apiError("Empty response from OpenAI")
    }
    return content
}

func callClaude(systemPrompt: String, userPrompt: String, apiKey: String) async throws -> String {
    let request = ClaudeRequest(
        model: "claude-haiku-4-5-20251001",
        max_tokens: 4096,
        messages: [ChatMessage(role: "user", content: userPrompt)],
        system: systemPrompt,
        temperature: 0.7
    )
    let url = URL(string: "https://api.anthropic.com/v1/messages")!
    var urlRequest = URLRequest(url: url)
    urlRequest.httpMethod = "POST"
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
    urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    urlRequest.httpBody = try JSONEncoder().encode(request)
    urlRequest.timeoutInterval = 60

    let (data, response) = try await URLSession.shared.data(for: urlRequest)
    guard let httpResponse = response as? HTTPURLResponse else {
        throw OboGenError.apiError("Invalid response")
    }
    guard httpResponse.statusCode == 200 else {
        if let err = try? JSONDecoder().decode(ClaudeErrorResponse.self, from: data) {
            throw OboGenError.apiError("Claude (\(httpResponse.statusCode)): \(err.error.message)")
        }
        throw OboGenError.apiError("Claude HTTP \(httpResponse.statusCode)")
    }
    let claudeResponse = try JSONDecoder().decode(ClaudeResponse.self, from: data)
    guard let text = claudeResponse.content.first?.text else {
        throw OboGenError.apiError("Empty response from Claude")
    }
    return text
}

func callAI(model: AIModel, systemPrompt: String, userPrompt: String) async throws -> String {
    let env = ProcessInfo.processInfo.environment
    switch model {
    case .gpt:
        guard let key = env["OPENAI_API_KEY"], !key.isEmpty else {
            throw OboGenError.missingKey("OPENAI_API_KEY")
        }
        return try await callOpenAI(systemPrompt: systemPrompt, userPrompt: userPrompt, apiKey: key)
    case .claude:
        guard let key = env["ANTHROPIC_API_KEY"], !key.isEmpty else {
            throw OboGenError.missingKey("ANTHROPIC_API_KEY")
        }
        return try await callClaude(systemPrompt: systemPrompt, userPrompt: userPrompt, apiKey: key)
    }
}

// MARK: - Prompt Building

func buildFlashcardPrompt(topic: String, count: Int, age: String, difficulty: Difficulty?) -> (system: String, user: String) {
    let difficultyHint = difficulty.map { " at \($0.rawValue) difficulty level" } ?? ""
    let system = """
    You generate flashcard decks for children. Output ONLY the deck in this exact format, nothing else:

    Title: <topic>

    Q: <question> | A: <answer>

    Generate exactly \(count) question/answer pairs about "\(topic)" appropriate for ages \(age)\(difficultyHint). Keep questions and answers short and clear.
    """
    let user = "Generate a \(count)-card flashcard deck about \"\(topic)\" for ages \(age)\(difficultyHint)."
    return (system, user)
}

func buildTriviaPrompt(topic: String, count: Int, age: String, difficulty: Difficulty?) -> (system: String, user: String) {
    let difficultyHint = difficulty.map { " at \($0.rawValue) difficulty level" } ?? ""
    let system = """
    You generate trivia question decks. Output ONLY the deck in this exact format, nothing else:

    Title: <topic>

    Q: <question>
    A) <choice 1>
    B) <choice 2>
    C) <choice 3>
    D) <choice 4>
    ANSWER: <letter>

    Generate exactly \(count) multiple-choice trivia questions about "\(topic)" appropriate for ages \(age)\(difficultyHint). Each question must have exactly 4 choices labeled A-D. Keep questions and choices concise.
    """
    let user = "Generate \(count) multiple-choice trivia questions about \"\(topic)\" for ages \(age)\(difficultyHint)."
    return (system, user)
}

// MARK: - Parsing

func parseFlashcardDeck(from content: String) -> ParsedDeck {
    let lines = content.components(separatedBy: "\n")
    var title = ""
    var cards: [Card] = []

    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("Title:") {
            title = trimmed.replacingOccurrences(of: "Title:", with: "").trimmingCharacters(in: .whitespaces)
            continue
        }
        if trimmed.hasPrefix("Q:") && trimmed.contains("| A:") {
            let parts = trimmed.components(separatedBy: "| A:")
            guard parts.count >= 2 else { continue }
            let q = parts[0].replacingOccurrences(of: "Q:", with: "").trimmingCharacters(in: .whitespaces)
            let a = parts.dropFirst().joined(separator: "| A:").trimmingCharacters(in: .whitespaces)
            if !q.isEmpty && !a.isEmpty {
                cards.append(Card(question: q, answer: a, choices: nil, correctIndex: nil, difficulty: nil))
            }
        }
    }
    return ParsedDeck(title: title.isEmpty ? "Untitled" : title, cards: cards)
}

func parseTriviaDeck(from content: String) -> ParsedDeck {
    let lines = content.components(separatedBy: "\n")
    var title = ""
    var cards: [Card] = []

    var currentQ = ""
    var choices: [String] = []

    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("Title:") {
            title = trimmed.replacingOccurrences(of: "Title:", with: "").trimmingCharacters(in: .whitespaces)
            continue
        }
        if trimmed.hasPrefix("Q:") {
            // Save previous question if we have one pending
            // (shouldn't happen unless ANSWER: was missing)
            currentQ = trimmed.replacingOccurrences(of: "Q:", with: "").trimmingCharacters(in: .whitespaces)
            choices = []
            continue
        }
        // Match choice lines: A) ..., B) ..., C) ..., D) ...
        if let firstChar = trimmed.first, "ABCD".contains(firstChar),
           trimmed.count > 2 && trimmed.dropFirst(1).hasPrefix(")") {
            let choiceText = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            choices.append(choiceText)
            continue
        }
        if trimmed.uppercased().hasPrefix("ANSWER:") {
            let letter = trimmed.replacingOccurrences(of: "ANSWER:", with: "", options: .caseInsensitive)
                .trimmingCharacters(in: .whitespaces).uppercased()
            let idx = ["A": 0, "B": 1, "C": 2, "D": 3][letter] ?? 0
            if !currentQ.isEmpty && choices.count == 4 {
                let correctAnswer = choices[idx]
                cards.append(Card(
                    question: currentQ, answer: correctAnswer,
                    choices: choices, correctIndex: idx, difficulty: nil
                ))
            }
            currentQ = ""
            choices = []
            continue
        }
    }
    return ParsedDeck(title: title.isEmpty ? "Untitled" : title, cards: cards)
}

// MARK: - Database Operations

func checkDuplicate(conn: PostgresConnection, title: String, kind: CardKind) async throws -> String? {
    let logger = Logger(label: "obo-gen")
    let query: PostgresQuery =
        "SELECT id::text FROM decks WHERE LOWER(title) = LOWER(\(title)) AND kind = \(kind.rawValue) LIMIT 1"
    let rows = try await conn.query(query, logger: logger)
    for try await row in rows {
        return try row.decode(String.self)
    }
    return nil
}

func saveDeck(conn: PostgresConnection, parsed: ParsedDeck, kind: CardKind, age: String, voice: String?, difficulty: Difficulty?) async throws -> String {
    let logger = Logger(label: "obo-gen")

    var propsDict: [String: Any] = ["age_range": age]
    if let voice = voice { propsDict["voice"] = voice }
    if let diff = difficulty { propsDict["difficulty"] = diff.rawValue }
    let propsData = try JSONSerialization.data(withJSONObject: propsDict)
    let propsJSON = String(data: propsData, encoding: .utf8) ?? "{}"

    let insertDeckQuery: PostgresQuery =
        "INSERT INTO decks (title, kind, properties) VALUES (\(parsed.title), \(kind.rawValue), \(propsJSON)::jsonb) RETURNING id::text"
    let deckRows = try await conn.query(insertDeckQuery, logger: logger)

    var deckId = ""
    for try await row in deckRows {
        deckId = try row.decode(String.self)
    }
    guard !deckId.isEmpty else {
        throw OboGenError.dbError("Failed to insert deck")
    }

    for (i, card) in parsed.cards.enumerated() {
        var cardProps: [String: Any] = ["answer": card.answer]
        if let choices = card.choices {
            cardProps["choices"] = choices
        }
        if let idx = card.correctIndex {
            cardProps["correct"] = idx
        }
        if let diff = difficulty {
            cardProps["difficulty"] = diff.rawValue
        }
        let cardPropsData = try JSONSerialization.data(withJSONObject: cardProps)
        let cardPropsJSON = String(data: cardPropsData, encoding: .utf8) ?? "{}"
        let insertCardQuery: PostgresQuery =
            "INSERT INTO cards (deck_id, position, question, properties) VALUES (\(deckId)::uuid, \(i + 1), \(card.question), \(cardPropsJSON)::jsonb)"
        try await conn.query(insertCardQuery, logger: logger)
    }

    return deckId
}

func listDecks(conn: PostgresConnection, kind: CardKind?) async throws {
    let logger = Logger(label: "obo-gen")
    let listQuery: PostgresQuery
    if let kind = kind {
        listQuery = """
            SELECT id::text, title, kind, COALESCE(properties->>'age_range', ''), card_count, created_at::text
            FROM decks WHERE kind = \(kind.rawValue) ORDER BY created_at
            """
    } else {
        listQuery = """
            SELECT id::text, title, kind, COALESCE(properties->>'age_range', ''), card_count, created_at::text
            FROM decks ORDER BY created_at
            """
    }
    let rows = try await conn.query(listQuery, logger: logger)

    var decks: [(String, String, String, String, Int, String)] = []
    for try await row in rows {
        let (id, title, rkind, ageRange, cardCount, createdAt) = try row.decode((String, String, String, String, Int, String).self)
        decks.append((id, title, rkind, ageRange, cardCount, createdAt))
    }

    if decks.isEmpty {
        print("No saved decks.")
        return
    }

    func pad(_ s: String, _ width: Int) -> String {
        s.count >= width ? String(s.prefix(width)) : s + String(repeating: " ", count: width - s.count)
    }
    func rpad(_ s: String, _ width: Int) -> String {
        s.count >= width ? String(s.prefix(width)) : String(repeating: " ", count: width - s.count) + s
    }
    print("\(pad("ID", 10))  \(pad("Kind", 10))  \(pad("Topic", 30))  \(pad("Ages", 8))  \(rpad("Cards", 5))  \(pad("Created", 20))")
    print(String(repeating: "-", count: 91))
    for (id, topic, rkind, age, count, date) in decks {
        let truncTopic = topic.count > 30 ? String(topic.prefix(27)) + "..." : topic
        let shortId = String(id.prefix(8))
        let shortDate = String(date.prefix(16))
        print("\(pad(shortId, 10))  \(pad(rkind, 10))  \(pad(truncTopic, 30))  \(pad(age, 8))  \(rpad(String(count), 5))  \(pad(shortDate, 20))")
    }
}

func exportDeck(conn: PostgresConnection, deckIdPrefix: String) async throws {
    let logger = Logger(label: "obo-gen")

    let fetchDeckQuery: PostgresQuery =
        "SELECT id::text, title, kind, properties->>'voice' FROM decks WHERE id::text LIKE \(deckIdPrefix + "%") LIMIT 1"
    let deckRows = try await conn.query(fetchDeckQuery, logger: logger)

    var deckId = ""
    var title = ""
    var kind = ""
    var voice: String? = nil
    var found = false
    for try await row in deckRows {
        let data = try row.decode((String, String, String, String?).self)
        deckId = data.0; title = data.1; kind = data.2; voice = data.3
        found = true
    }
    guard found else {
        throw OboGenError.notFound("No deck matching '\(deckIdPrefix)'")
    }

    let fetchCardsQuery: PostgresQuery =
        "SELECT question, COALESCE(properties->>'answer', ''), COALESCE(properties::text, '{}') FROM cards WHERE deck_id = \(deckId)::uuid ORDER BY position"
    let cardRows = try await conn.query(fetchCardsQuery, logger: logger)

    var output = "Title: \(title)\nKind: \(kind)\n\n"

    if kind == "trivia" {
        for try await row in cardRows {
            let (q, _, propsStr) = try row.decode((String, String, String).self)
            output += "Q: \(q)\n"
            if let propsData = propsStr.data(using: .utf8),
               let props = try? JSONSerialization.jsonObject(with: propsData) as? [String: Any],
               let choices = props["choices"] as? [String],
               let correct = props["correct"] as? Int {
                let letters = ["A", "B", "C", "D"]
                for (i, choice) in choices.enumerated() {
                    output += "\(letters[i])) \(choice)\n"
                }
                output += "ANSWER: \(letters[correct])\n\n"
            }
        }
    } else {
        for try await row in cardRows {
            let (q, a, _) = try row.decode((String, String, String).self)
            output += "Q: \(q) | A: \(a)\n"
        }
    }

    if let voice = voice {
        output += "\nVoice: \(voice)\n"
    }
    print(output, terminator: "")
}

func deleteDeck(conn: PostgresConnection, deckIdPrefix: String) async throws -> (String, String, Int) {
    let logger = Logger(label: "obo-gen")

    // Find the deck first
    let findQuery: PostgresQuery =
        "SELECT id::text, title, card_count FROM decks WHERE id::text LIKE \(deckIdPrefix + "%") LIMIT 1"
    let rows = try await conn.query(findQuery, logger: logger)

    var deckId = ""
    var title = ""
    var cardCount = 0
    var found = false
    for try await row in rows {
        let data = try row.decode((String, String, Int).self)
        deckId = data.0; title = data.1; cardCount = data.2
        found = true
    }
    guard found else {
        throw OboGenError.notFound("No deck matching '\(deckIdPrefix)'")
    }

    // Cards cascade-delete via FK
    let deleteQuery: PostgresQuery = "DELETE FROM decks WHERE id = \(deckId)::uuid"
    try await conn.query(deleteQuery, logger: logger)

    return (deckId, title, cardCount)
}

func showStats(conn: PostgresConnection) async throws {
    let logger = Logger(label: "obo-gen")

    // Total decks and cards by kind
    let summaryQuery: PostgresQuery = """
        SELECT kind, COUNT(*)::int, COALESCE(SUM(card_count), 0)::int
        FROM decks GROUP BY kind ORDER BY kind
        """
    let rows = try await conn.query(summaryQuery, logger: logger)

    var totalDecks = 0
    var totalCards = 0
    var kindRows: [(String, Int, Int)] = []
    for try await row in rows {
        let (kind, deckCount, cardCount) = try row.decode((String, Int, Int).self)
        kindRows.append((kind, deckCount, cardCount))
        totalDecks += deckCount
        totalCards += cardCount
    }

    print("Database: \(loadDBConfig().database) @ \(loadDBConfig().host)")
    print("Total: \(totalDecks) decks, \(totalCards) cards\n")

    if kindRows.isEmpty {
        print("No decks found.")
        return
    }

    func pad(_ s: String, _ w: Int) -> String {
        s.count >= w ? String(s.prefix(w)) : s + String(repeating: " ", count: w - s.count)
    }
    func rpad(_ s: String, _ w: Int) -> String {
        s.count >= w ? String(s.prefix(w)) : String(repeating: " ", count: w - s.count) + s
    }

    print("\(pad("Kind", 12))  \(rpad("Decks", 6))  \(rpad("Cards", 6))")
    print(String(repeating: "-", count: 28))
    for (kind, dc, cc) in kindRows {
        print("\(pad(kind, 12))  \(rpad(String(dc), 6))  \(rpad(String(cc), 6))")
    }

    // Age range breakdown
    let ageQuery: PostgresQuery = """
        SELECT COALESCE(properties->>'age_range', 'unset'), COUNT(*)::int
        FROM decks GROUP BY 1 ORDER BY 1
        """
    let ageRows = try await conn.query(ageQuery, logger: logger)
    print("\n\(pad("Age Range", 12))  \(rpad("Decks", 6))")
    print(String(repeating: "-", count: 20))
    for try await row in ageRows {
        let (age, count) = try row.decode((String, Int).self)
        print("\(pad(age, 12))  \(rpad(String(count), 6))")
    }
}

// MARK: - Errors

enum OboGenError: LocalizedError {
    case apiError(String)
    case missingKey(String)
    case dbError(String)
    case notFound(String)
    case duplicateExists(String, String)
    case parseError(String)

    var errorDescription: String? {
        switch self {
        case .apiError(let msg): return msg
        case .missingKey(let key): return "\(key) environment variable is not set"
        case .dbError(let msg): return msg
        case .notFound(let msg): return msg
        case .duplicateExists(let title, let id): return "Deck '\(title)' already exists (id: \(id)). Use --force to create anyway."
        case .parseError(let msg): return msg
        }
    }
}

// MARK: - CLI Commands

struct OboGen: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "obo-gen",
        abstract: "Generate flashcard and trivia decks for the cardzerver ecosystem",
        subcommands: [Generate.self, List.self, Export.self, Delete.self, Stats.self, Batch.self],
        defaultSubcommand: Generate.self
    )
}

struct Generate: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Generate a deck from an AI model")

    @Argument(help: "Topic for the deck (e.g. \"Solar System\")")
    var topic: String

    @Option(name: [.short, .long], help: "Target age range (default: 8-10)")
    var age: String = "8-10"

    @Option(name: [.customShort("n"), .long], help: "Number of cards to generate (default: 20)")
    var count: Int = 20

    @Option(name: [.short, .long], help: "Kind of deck: flashcard or trivia (default: flashcard)")
    var kind: CardKind = .flashcard

    @Option(name: [.short, .long], help: "AI model: gpt or claude (default: gpt)")
    var model: AIModel = .gpt

    @Option(name: .shortAndLong, help: "Output file path (default: stdout)")
    var output: String? = nil

    @Option(help: "Append a voice hint line")
    var voice: String? = nil

    @Option(name: .shortAndLong, help: "Difficulty level: easy, medium, hard")
    var difficulty: Difficulty? = nil

    @Flag(help: "Skip saving to database")
    var noSave: Bool = false

    @Flag(help: "Create even if a deck with the same title exists")
    var force: Bool = false

    func run() throws {
        let semaphore = DispatchSemaphore(value: 0)
        var exitCode: Int32 = 0

        Task {
            do {
                try await runAsync()
            } catch {
                fputs("Error: \(error.localizedDescription)\n", stderr)
                exitCode = 1
            }
            semaphore.signal()
        }
        semaphore.wait()
        if exitCode != 0 { Foundation.exit(exitCode) }
    }

    func runAsync() async throws {
        // Duplicate check
        if !noSave && !force {
            if let existingId = try? await withDB({ conn in
                try await checkDuplicate(conn: conn, title: topic, kind: kind)
            }) {
                throw OboGenError.duplicateExists(topic, existingId)
            }
        }

        let prompts: (system: String, user: String)
        switch kind {
        case .flashcard:
            prompts = buildFlashcardPrompt(topic: topic, count: count, age: age, difficulty: difficulty)
        case .trivia:
            prompts = buildTriviaPrompt(topic: topic, count: count, age: age, difficulty: difficulty)
        }

        fputs("Generating \(count) \(kind.rawValue) cards about \"\(topic)\" for ages \(age) via \(model.rawValue)...\n", stderr)

        var content = try await callAI(model: model, systemPrompt: prompts.system, userPrompt: prompts.user)

        if let voice = voice {
            content += "\n\nVoice: \(voice)"
        }
        if !content.hasSuffix("\n") { content += "\n" }

        // Parse
        let parsed: ParsedDeck
        switch kind {
        case .flashcard:
            parsed = parseFlashcardDeck(from: content)
        case .trivia:
            parsed = parseTriviaDeck(from: content)
        }

        fputs("Parsed \(parsed.cards.count) cards\n", stderr)

        // Save to database
        if !noSave {
            if parsed.cards.isEmpty {
                fputs("Warning: no cards parsed, skipping DB save\n", stderr)
            } else {
                do {
                    let deckId = try await withDB { conn in
                        try await saveDeck(conn: conn, parsed: parsed, kind: kind, age: age, voice: voice, difficulty: difficulty)
                    }
                    fputs("Saved deck \(String(deckId.prefix(8))) (\(parsed.cards.count) cards) to database\n", stderr)
                } catch {
                    fputs("Warning: failed to save to database: \(error.localizedDescription)\n", stderr)
                }
            }
        }

        // Output
        if let outputPath = output {
            let expandedPath = NSString(string: outputPath).expandingTildeInPath
            let dir = (expandedPath as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try content.write(toFile: expandedPath, atomically: true, encoding: .utf8)
            fputs("Wrote to \(expandedPath)\n", stderr)
        } else {
            print(content, terminator: "")
        }
    }
}

struct List: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List all saved decks")

    @Option(name: [.short, .long], help: "Filter by kind: flashcard or trivia")
    var kind: CardKind? = nil

    func run() throws {
        let semaphore = DispatchSemaphore(value: 0)
        var exitCode: Int32 = 0
        Task {
            do {
                try await withDB { conn in
                    try await listDecks(conn: conn, kind: kind)
                }
            } catch {
                fputs("Error: \(error.localizedDescription)\n", stderr)
                exitCode = 1
            }
            semaphore.signal()
        }
        semaphore.wait()
        if exitCode != 0 { Foundation.exit(exitCode) }
    }
}

struct Export: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Export a saved deck by UUID or prefix")

    @Argument(help: "Deck UUID or prefix")
    var id: String

    func run() throws {
        let semaphore = DispatchSemaphore(value: 0)
        var exitCode: Int32 = 0
        Task {
            do {
                try await withDB { conn in
                    try await exportDeck(conn: conn, deckIdPrefix: id)
                }
            } catch {
                fputs("Error: \(error.localizedDescription)\n", stderr)
                exitCode = 1
            }
            semaphore.signal()
        }
        semaphore.wait()
        if exitCode != 0 { Foundation.exit(exitCode) }
    }
}

struct Delete: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Delete a deck and its cards")

    @Argument(help: "Deck UUID or prefix")
    var id: String

    func run() throws {
        let semaphore = DispatchSemaphore(value: 0)
        var exitCode: Int32 = 0
        Task {
            do {
                let (deckId, title, cardCount) = try await withDB { conn in
                    try await deleteDeck(conn: conn, deckIdPrefix: id)
                }
                print("Deleted deck '\(title)' (\(String(deckId.prefix(8))), \(cardCount) cards)")
            } catch {
                fputs("Error: \(error.localizedDescription)\n", stderr)
                exitCode = 1
            }
            semaphore.signal()
        }
        semaphore.wait()
        if exitCode != 0 { Foundation.exit(exitCode) }
    }
}

struct Stats: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show database statistics")

    func run() throws {
        let semaphore = DispatchSemaphore(value: 0)
        var exitCode: Int32 = 0
        Task {
            do {
                try await withDB { conn in
                    try await showStats(conn: conn)
                }
            } catch {
                fputs("Error: \(error.localizedDescription)\n", stderr)
                exitCode = 1
            }
            semaphore.signal()
        }
        semaphore.wait()
        if exitCode != 0 { Foundation.exit(exitCode) }
    }
}

struct Batch: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Generate decks from a topics file (one topic per line)")

    @Argument(help: "Path to topics file (one topic per line)")
    var file: String

    @Option(name: [.short, .long], help: "Target age range (default: 8-10)")
    var age: String = "8-10"

    @Option(name: [.customShort("n"), .long], help: "Cards per deck (default: 20)")
    var count: Int = 20

    @Option(name: [.short, .long], help: "Kind: flashcard or trivia (default: flashcard)")
    var kind: CardKind = .flashcard

    @Option(name: [.short, .long], help: "AI model: gpt or claude (default: gpt)")
    var model: AIModel = .gpt

    @Option(name: .shortAndLong, help: "Difficulty level: easy, medium, hard")
    var difficulty: Difficulty? = nil

    @Flag(help: "Create even if duplicate titles exist")
    var force: Bool = false

    func run() throws {
        let semaphore = DispatchSemaphore(value: 0)
        var exitCode: Int32 = 0
        Task {
            do {
                try await runAsync()
            } catch {
                fputs("Error: \(error.localizedDescription)\n", stderr)
                exitCode = 1
            }
            semaphore.signal()
        }
        semaphore.wait()
        if exitCode != 0 { Foundation.exit(exitCode) }
    }

    func runAsync() async throws {
        let expandedPath = NSString(string: file).expandingTildeInPath
        let content = try String(contentsOfFile: expandedPath, encoding: .utf8)
        let topics = content.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }

        guard !topics.isEmpty else {
            fputs("No topics found in \(expandedPath)\n", stderr)
            return
        }

        fputs("Batch generating \(topics.count) \(kind.rawValue) decks...\n", stderr)

        var succeeded = 0
        var skipped = 0
        var failed = 0

        for (i, topic) in topics.enumerated() {
            fputs("\n[\(i + 1)/\(topics.count)] \(topic)\n", stderr)

            // Duplicate check
            if !force {
                if let existingId = try? await withDB({ conn in
                    try await checkDuplicate(conn: conn, title: topic, kind: kind)
                }) {
                    fputs("  Skipped (duplicate, id: \(String(existingId.prefix(8))))\n", stderr)
                    skipped += 1
                    continue
                }
            }

            do {
                let prompts: (system: String, user: String)
                switch kind {
                case .flashcard:
                    prompts = buildFlashcardPrompt(topic: topic, count: count, age: age, difficulty: difficulty)
                case .trivia:
                    prompts = buildTriviaPrompt(topic: topic, count: count, age: age, difficulty: difficulty)
                }

                let rawContent = try await callAI(model: model, systemPrompt: prompts.system, userPrompt: prompts.user)

                let parsed: ParsedDeck
                switch kind {
                case .flashcard:
                    parsed = parseFlashcardDeck(from: rawContent)
                case .trivia:
                    parsed = parseTriviaDeck(from: rawContent)
                }

                if parsed.cards.isEmpty {
                    fputs("  Warning: no cards parsed, skipping\n", stderr)
                    failed += 1
                    continue
                }

                let deckId = try await withDB { conn in
                    try await saveDeck(conn: conn, parsed: parsed, kind: kind, age: age, voice: nil, difficulty: difficulty)
                }
                fputs("  Saved \(String(deckId.prefix(8))) (\(parsed.cards.count) cards)\n", stderr)
                succeeded += 1
            } catch {
                fputs("  Failed: \(error.localizedDescription)\n", stderr)
                failed += 1
            }
        }

        fputs("\nBatch complete: \(succeeded) created, \(skipped) skipped, \(failed) failed\n", stderr)
    }
}

OboGen.main()
