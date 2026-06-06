import Foundation

/// Structured meeting notes - matches existing notes.json schema
struct MeetingNotes: Codable {
    var title: String?
    var date: String?
    var participants: [String]?
    var summary: String?
    var enrichedNotes: String?
    var topics: [Topic]?
    var decisions: [String]?
    var actionItems: [ActionItem]?
    var insights: [String]?
    var followUps: [String]?
    var modelUsed: String?
    var transcriptStats: TranscriptStats?

    // Fallback when JSON parsing fails
    var rawText: String?
    var parseError: Bool?

    enum CodingKeys: String, CodingKey {
        case title, date, participants, summary, decisions, insights, topics
        case enrichedNotes = "enriched_notes"
        case actionItems = "action_items"
        case followUps = "follow_ups"
        case modelUsed = "model_used"
        case transcriptStats = "transcript_stats"
        case rawText = "raw_text"
        case parseError = "parse_error"
    }

    init(
        title: String? = nil,
        date: String? = nil,
        participants: [String]? = nil,
        summary: String? = nil,
        enrichedNotes: String? = nil,
        topics: [Topic]? = nil,
        decisions: [String]? = nil,
        actionItems: [ActionItem]? = nil,
        insights: [String]? = nil,
        followUps: [String]? = nil,
        modelUsed: String? = nil,
        transcriptStats: TranscriptStats? = nil,
        rawText: String? = nil,
        parseError: Bool? = nil
    ) {
        self.title = title
        self.date = date
        self.participants = participants
        self.summary = summary
        self.enrichedNotes = enrichedNotes
        self.topics = topics
        self.decisions = decisions
        self.actionItems = actionItems
        self.insights = insights
        self.followUps = followUps
        self.modelUsed = modelUsed
        self.transcriptStats = transcriptStats
        self.rawText = rawText
        self.parseError = parseError
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        date = try container.decodeIfPresent(String.self, forKey: .date)
        participants = try container.decodeIfPresent([String].self, forKey: .participants)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        enrichedNotes = try container.decodeIfPresent(String.self, forKey: .enrichedNotes)
        topics = try container.decodeIfPresent([Topic].self, forKey: .topics)
        decisions = try container.decodeFlexibleStringArrayIfPresent(forKey: .decisions)
        actionItems = try container.decodeIfPresent([ActionItem].self, forKey: .actionItems)
        insights = try container.decodeFlexibleStringArrayIfPresent(forKey: .insights)
        followUps = try container.decodeFlexibleStringArrayIfPresent(forKey: .followUps)
        modelUsed = try container.decodeIfPresent(String.self, forKey: .modelUsed)
        transcriptStats = try container.decodeIfPresent(TranscriptStats.self, forKey: .transcriptStats)
        rawText = try container.decodeIfPresent(String.self, forKey: .rawText)
        parseError = try container.decodeIfPresent(Bool.self, forKey: .parseError)
    }
}

private struct FlexibleString: Decodable {
    let value: String

    init(from decoder: Decoder) throws {
        let single = try? decoder.singleValueContainer()
        if let string = try? single?.decode(String.self) {
            value = string
            return
        }

        let object = try decoder.container(keyedBy: DynamicCodingKey.self)
        for key in ["decision", "insight", "follow_up", "followup", "text", "item", "value", "task", "title", "summary"] {
            if let codingKey = DynamicCodingKey(stringValue: key),
               let string = try object.decodeIfPresent(String.self, forKey: codingKey),
               !string.isEmpty {
                value = string
                return
            }
        }

        throw DecodingError.typeMismatch(
            String.self,
            DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected string or object containing a string value")
        )
    }
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        return nil
    }
}

private extension KeyedDecodingContainer {
    func decodeFlexibleStringArrayIfPresent(forKey key: Key) throws -> [String]? {
        try decodeIfPresent([FlexibleString].self, forKey: key)?.map(\.value)
    }
}

struct Topic: Codable {
    let topic: String
    let details: String
}

struct ActionItem: Codable, Identifiable {
    var id: String { "\(owner ?? "?")-\(task)" }

    var owner: String?
    let task: String
    var deadline: String?
    var context: String?
}

struct TranscriptStats: Codable {
    var segments: Int?
    var duration: Double?
    var sttModel: String?

    enum CodingKeys: String, CodingKey {
        case segments, duration
        case sttModel = "stt_model"
    }
}
