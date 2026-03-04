import Foundation
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
    let choices: [String]?
    let correctIndex: Int?
}

struct ParsedDeck {
    let title: String
    let cards: [Card]
}

// MARK: - Errors

enum OboGenError: LocalizedError {
    case apiError(String)
    case missingKey(String)
    case serverError(Int, String)
    case notFound(String)
    case duplicateExists(String, String)

    var errorDescription: String? {
        switch self {
        case .apiError(let msg): return msg
        case .missingKey(let key): return "\(key) environment variable is not set"
        case .serverError(let code, let msg): return "Server error (\(code)): \(msg)"
        case .notFound(let msg): return msg
        case .duplicateExists(let title, let id): return "Deck '\(title)' already exists (id: \(id)). Use --force to create anyway."
        }
    }
}

// MARK: - Cardzerver API Client

struct CardzerverClient {
    let baseURL: String

    init() {
        let env = ProcessInfo.processInfo.environment
        self.baseURL = env["CARDZERVER_URL"] ?? "https://bd-cardzerver.fly.dev"
    }

    // POST /api/v1/studio/decks/bulk — create deck + cards in one call
    func createDeckWithCards(
        title: String, kind: CardKind, properties: [String: Any], cards: [[String: Any]]
    ) async throws -> (deckId: String, cardCount: Int) {
        let body: [String: Any] = [
            "title": title,
            "kind": kind.rawValue,
            "properties": properties,
            "cards": cards,
        ]
        let data = try await post(path: "/api/v1/studio/decks/bulk", body: body)
        let json = try parseJSON(data)
        guard let id = json["id"] as? String else {
            throw OboGenError.serverError(0, "Missing id in response")
        }
        let cardCount = (json["cards"] as? [[String: Any]])?.count
            ?? json["card_count"] as? Int ?? 0
        return (id, cardCount)
    }

    // GET /api/v1/decks — list decks
    func listDecks(kind: CardKind?) async throws -> [[String: Any]] {
        var path = "/api/v1/decks?limit=200"
        if let kind = kind { path += "&kind=\(kind.rawValue)" }
        let data = try await get(path: path)
        let json = try parseJSON(data)
        return json["decks"] as? [[String: Any]] ?? []
    }

    // GET /api/v1/decks/{id} — get deck with cards
    func getDeck(id: String) async throws -> [String: Any] {
        let data = try await get(path: "/api/v1/decks/\(id)")
        return try parseJSON(data)
    }

    // DELETE /api/v1/studio/decks/{id}
    func deleteDeck(id: String) async throws {
        let url = URL(string: "\(baseURL)/api/v1/studio/decks/\(id)")!
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        try checkResponse(response, data: data)
    }

    // GET /api/v1/studio/stats
    func stats() async throws -> [String: Any] {
        let data = try await get(path: "/api/v1/studio/stats")
        return try parseJSON(data)
    }

    // GET /api/v1/studio/check-duplicate?title=X&kind=Y
    func checkDuplicate(title: String, kind: CardKind) async throws -> (exists: Bool, id: String?) {
        let encoded = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? title
        let data = try await get(path: "/api/v1/studio/check-duplicate?title=\(encoded)&kind=\(kind.rawValue)")
        let json = try parseJSON(data)
        let exists = json["exists"] as? Bool ?? false
        let id = json["id"] as? String
        return (exists, id)
    }

    // MARK: Helpers

    private func get(path: String) async throws -> Data {
        let url = URL(string: "\(baseURL)\(path)")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        try checkResponse(response, data: data)
        return data
    }

    private func post(path: String, body: [String: Any]) async throws -> Data {
        let url = URL(string: "\(baseURL)\(path)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        try checkResponse(response, data: data)
        return data
    }

    private func checkResponse(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw OboGenError.apiError("Invalid response")
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            if http.statusCode == 404 {
                throw OboGenError.notFound("Not found")
            }
            throw OboGenError.serverError(http.statusCode, body)
        }
    }

    private func parseJSON(_ data: Data) throws -> [String: Any] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OboGenError.apiError("Invalid JSON response")
        }
        return json
    }
}

// MARK: - AI API Calls

struct ChatMessage: Codable {
    let role: String
    let content: String
}

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
                cards.append(Card(question: q, answer: a, choices: nil, correctIndex: nil))
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
            currentQ = trimmed.replacingOccurrences(of: "Q:", with: "").trimmingCharacters(in: .whitespaces)
            choices = []
            continue
        }
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
                cards.append(Card(question: currentQ, answer: correctAnswer, choices: choices, correctIndex: idx))
            }
            currentQ = ""
            choices = []
        }
    }
    return ParsedDeck(title: title.isEmpty ? "Untitled" : title, cards: cards)
}

// MARK: - Build API card dicts from parsed cards

func buildCardDicts(cards: [Card], kind: CardKind, difficulty: Difficulty?) -> [[String: Any]] {
    cards.enumerated().map { (_, card) in
        var props: [String: Any] = ["answer": card.answer]
        if let choices = card.choices { props["choices"] = choices }
        if let idx = card.correctIndex { props["correct_index"] = idx }
        let diff = difficulty?.rawValue ?? "medium"
        return ["question": card.question, "properties": props, "difficulty": diff] as [String: Any]
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

    @Flag(help: "Skip saving to cardzerver")
    var noSave: Bool = false

    @Flag(help: "Create even if a deck with the same title exists")
    var force: Bool = false

    func run() throws {
        let semaphore = DispatchSemaphore(value: 0)
        var exitCode: Int32 = 0
        Task {
            do { try await runAsync() }
            catch { fputs("Error: \(error.localizedDescription)\n", stderr); exitCode = 1 }
            semaphore.signal()
        }
        semaphore.wait()
        if exitCode != 0 { Foundation.exit(exitCode) }
    }

    func runAsync() async throws {
        let client = CardzerverClient()

        // Duplicate check
        if !noSave && !force {
            let (exists, existingId) = try await client.checkDuplicate(title: topic, kind: kind)
            if exists, let eid = existingId {
                throw OboGenError.duplicateExists(topic, eid)
            }
        }

        let prompts: (system: String, user: String)
        switch kind {
        case .flashcard: prompts = buildFlashcardPrompt(topic: topic, count: count, age: age, difficulty: difficulty)
        case .trivia: prompts = buildTriviaPrompt(topic: topic, count: count, age: age, difficulty: difficulty)
        }

        fputs("Generating \(count) \(kind.rawValue) cards about \"\(topic)\" for ages \(age) via \(model.rawValue)...\n", stderr)

        var content = try await callAI(model: model, systemPrompt: prompts.system, userPrompt: prompts.user)

        if let voice = voice { content += "\n\nVoice: \(voice)" }
        if !content.hasSuffix("\n") { content += "\n" }

        let parsed: ParsedDeck
        switch kind {
        case .flashcard: parsed = parseFlashcardDeck(from: content)
        case .trivia: parsed = parseTriviaDeck(from: content)
        }
        fputs("Parsed \(parsed.cards.count) cards\n", stderr)

        // Save to cardzerver
        if !noSave {
            if parsed.cards.isEmpty {
                fputs("Warning: no cards parsed, skipping save\n", stderr)
            } else {
                var props: [String: Any] = ["age_range": age]
                if let voice = voice { props["voice"] = voice }
                if let diff = difficulty { props["difficulty"] = diff.rawValue }
                let cardDicts = buildCardDicts(cards: parsed.cards, kind: kind, difficulty: difficulty)

                let (deckId, cardCount) = try await client.createDeckWithCards(
                    title: parsed.title, kind: kind, properties: props, cards: cardDicts
                )
                fputs("Saved deck \(String(deckId.prefix(8))) (\(cardCount) cards) to cardzerver\n", stderr)
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
                let client = CardzerverClient()
                let decks = try await client.listDecks(kind: kind)

                if decks.isEmpty {
                    print("No saved decks.")
                    semaphore.signal()
                    return
                }

                func pad(_ s: String, _ w: Int) -> String {
                    s.count >= w ? String(s.prefix(w)) : s + String(repeating: " ", count: w - s.count)
                }
                func rpad(_ s: String, _ w: Int) -> String {
                    s.count >= w ? String(s.prefix(w)) : String(repeating: " ", count: w - s.count) + s
                }
                print("\(pad("ID", 10))  \(pad("Kind", 10))  \(pad("Topic", 30))  \(rpad("Cards", 5))  \(pad("Created", 20))")
                print(String(repeating: "-", count: 81))
                for deck in decks {
                    let id = (deck["id"] as? String) ?? "?"
                    let title = (deck["title"] as? String) ?? "?"
                    let kind = (deck["kind"] as? String) ?? "?"
                    let cardCount = (deck["card_count"] as? Int) ?? 0
                    let created = (deck["created_at"] as? String) ?? "?"
                    let shortId = String(id.prefix(8))
                    let truncTitle = title.count > 30 ? String(title.prefix(27)) + "..." : title
                    let shortDate = String(created.prefix(16))
                    print("\(pad(shortId, 10))  \(pad(kind, 10))  \(pad(truncTitle, 30))  \(rpad(String(cardCount), 5))  \(pad(shortDate, 20))")
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
                let client = CardzerverClient()

                // If prefix, find the full ID first
                var fullId = id
                if id.count < 36 {
                    let decks = try await client.listDecks(kind: nil)
                    guard let match = decks.first(where: { ($0["id"] as? String ?? "").hasPrefix(id) }) else {
                        throw OboGenError.notFound("No deck matching '\(id)'")
                    }
                    fullId = match["id"] as? String ?? id
                }

                let deck = try await client.getDeck(id: fullId)
                let title = deck["title"] as? String ?? "Untitled"
                let kind = deck["kind"] as? String ?? "flashcard"
                let cards = deck["cards"] as? [[String: Any]] ?? []

                var output = "Title: \(title)\nKind: \(kind)\n\n"

                if kind == "trivia" {
                    for card in cards {
                        let q = card["question"] as? String ?? ""
                        let props = card["properties"] as? [String: Any] ?? [:]
                        output += "Q: \(q)\n"
                        if let choices = props["choices"] as? [String],
                           let correct = props["correct_index"] as? Int {
                            let letters = ["A", "B", "C", "D"]
                            for (i, choice) in choices.enumerated() {
                                output += "\(letters[i])) \(choice)\n"
                            }
                            if correct < letters.count {
                                output += "ANSWER: \(letters[correct])\n"
                            }
                        }
                        output += "\n"
                    }
                } else {
                    for card in cards {
                        let q = card["question"] as? String ?? ""
                        let props = card["properties"] as? [String: Any] ?? [:]
                        let a = props["answer"] as? String ?? ""
                        output += "Q: \(q) | A: \(a)\n"
                    }
                }

                let deckProps = deck["properties"] as? [String: Any] ?? [:]
                if let voice = deckProps["voice"] as? String {
                    output += "\nVoice: \(voice)\n"
                }
                print(output, terminator: "")
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
                let client = CardzerverClient()

                // Resolve prefix
                var fullId = id
                var title = "?"
                if id.count < 36 {
                    let decks = try await client.listDecks(kind: nil)
                    guard let match = decks.first(where: { ($0["id"] as? String ?? "").hasPrefix(id) }) else {
                        throw OboGenError.notFound("No deck matching '\(id)'")
                    }
                    fullId = match["id"] as? String ?? id
                    title = match["title"] as? String ?? "?"
                }

                try await client.deleteDeck(id: fullId)
                print("Deleted deck '\(title)' (\(String(fullId.prefix(8))))")
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
                let client = CardzerverClient()
                let stats = try await client.stats()

                let totalDecks = stats["total_decks"] as? Int ?? 0
                let totalCards = stats["total_cards"] as? Int ?? 0

                print("Server: \(client.baseURL)")
                print("Total: \(totalDecks) decks, \(totalCards) cards\n")

                func pad(_ s: String, _ w: Int) -> String {
                    s.count >= w ? String(s.prefix(w)) : s + String(repeating: " ", count: w - s.count)
                }
                func rpad(_ s: String, _ w: Int) -> String {
                    s.count >= w ? String(s.prefix(w)) : String(repeating: " ", count: w - s.count) + s
                }

                if let byKind = stats["by_kind"] as? [[String: Any]], !byKind.isEmpty {
                    print("\(pad("Kind", 12))  \(rpad("Decks", 6))  \(rpad("Cards", 6))")
                    print(String(repeating: "-", count: 28))
                    for entry in byKind {
                        let kind = entry["kind"] as? String ?? "?"
                        let decks = entry["decks"] as? Int ?? 0
                        let cards = entry["cards"] as? Int ?? 0
                        print("\(pad(kind, 12))  \(rpad(String(decks), 6))  \(rpad(String(cards), 6))")
                    }
                }

                if let byAge = stats["by_age_range"] as? [[String: Any]], !byAge.isEmpty {
                    print("\n\(pad("Age Range", 12))  \(rpad("Decks", 6))")
                    print(String(repeating: "-", count: 20))
                    for entry in byAge {
                        let age = entry["age_range"] as? String ?? "?"
                        let decks = entry["decks"] as? Int ?? 0
                        print("\(pad(age, 12))  \(rpad(String(decks), 6))")
                    }
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

    @Flag(help: "Skip saving to cardzerver (generate + print only)")
    var noSave: Bool = false

    func run() throws {
        let semaphore = DispatchSemaphore(value: 0)
        var exitCode: Int32 = 0
        Task {
            do { try await runAsync() }
            catch { fputs("Error: \(error.localizedDescription)\n", stderr); exitCode = 1 }
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

        let client = CardzerverClient()
        fputs("Batch generating \(topics.count) \(kind.rawValue) decks...\n", stderr)

        var succeeded = 0
        var skipped = 0
        var failed = 0

        for (i, topic) in topics.enumerated() {
            fputs("\n[\(i + 1)/\(topics.count)] \(topic)\n", stderr)

            // Duplicate check
            if !noSave && !force {
                let (exists, existingId) = try await client.checkDuplicate(title: topic, kind: kind)
                if exists {
                    fputs("  Skipped (duplicate, id: \(String((existingId ?? "?").prefix(8))))\n", stderr)
                    skipped += 1
                    continue
                }
            }

            do {
                let prompts: (system: String, user: String)
                switch kind {
                case .flashcard: prompts = buildFlashcardPrompt(topic: topic, count: count, age: age, difficulty: difficulty)
                case .trivia: prompts = buildTriviaPrompt(topic: topic, count: count, age: age, difficulty: difficulty)
                }

                let rawContent = try await callAI(model: model, systemPrompt: prompts.system, userPrompt: prompts.user)

                let parsed: ParsedDeck
                switch kind {
                case .flashcard: parsed = parseFlashcardDeck(from: rawContent)
                case .trivia: parsed = parseTriviaDeck(from: rawContent)
                }

                if parsed.cards.isEmpty {
                    fputs("  Warning: no cards parsed, skipping\n", stderr)
                    failed += 1
                    continue
                }

                if noSave {
                    fputs("  Generated \(parsed.cards.count) cards (not saved)\n", stderr)
                    print(rawContent)
                } else {
                    var props: [String: Any] = ["age_range": age]
                    if let diff = difficulty { props["difficulty"] = diff.rawValue }
                    let cardDicts = buildCardDicts(cards: parsed.cards, kind: kind, difficulty: difficulty)

                    let (deckId, cardCount) = try await client.createDeckWithCards(
                        title: parsed.title, kind: kind, properties: props, cards: cardDicts
                    )
                    fputs("  Saved \(String(deckId.prefix(8))) (\(cardCount) cards)\n", stderr)
                }
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
