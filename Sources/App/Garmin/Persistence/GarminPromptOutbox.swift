import Foundation
import GRDB
import Shared

struct GarminPromptOutboxRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = GarminPromptOutboxTable().tableName

    var id: String
    var pendingPrompt: GarminPendingNotificationPrompt
    var attemptCount: Int
    var nextRetryAt: TimeInterval?
    var lastError: GarminIntegrationError?
    var lastSentAt: TimeInterval?
    var deliveredAt: TimeInterval?
}

enum GarminPromptOutbox {
    private static let maxPendingPrompts = 20

    static func save(_ pendingPrompt: GarminPendingNotificationPrompt) throws {
        try GarminDatabaseSchema.createIfNeeded()
        try Current.database().write { db in
            try GarminPromptOutboxRecord(
                id: pendingPrompt.prompt.id,
                pendingPrompt: pendingPrompt,
                attemptCount: 0
            ).save(db)
            try pruneOverflow(db)
        }
    }

    static func pendingPrompts(limit: Int = maxPendingPrompts) throws -> [GarminPendingNotificationPrompt] {
        try GarminDatabaseSchema.createIfNeeded()
        return try Current.database().write { db in
            try pruneExpired(db)
            let now = Current.date().timeIntervalSince1970
            return try GarminPromptOutboxRecord
                .filter(Column(GarminPromptOutboxTable.Column.deliveredAt.rawValue) == nil)
                .fetchAll(db)
                .filter { record in
                    if record.lastSentAt != nil, record.lastError == nil {
                        return false
                    }
                    guard let nextRetryAt = record.nextRetryAt else { return true }
                    return nextRetryAt <= now
                }
                .sorted { $0.pendingPrompt.createdAt < $1.pendingPrompt.createdAt }
                .prefix(limit)
                .map(\.pendingPrompt)
        }
    }

    static func pendingPrompt(promptId: String) throws -> GarminPendingNotificationPrompt? {
        try GarminDatabaseSchema.createIfNeeded()
        return try Current.database().read { db in
            try GarminPromptOutboxRecord.fetchOne(db, key: promptId)?.pendingPrompt
        }
    }

    static func recordSendSuccess(promptId: String) throws {
        try update(promptId: promptId) { record in
            record.lastSentAt = Current.date().timeIntervalSince1970
            record.lastError = nil
            record.nextRetryAt = nil
        }
    }

    static func recordSendFailure(promptId: String, error: GarminIntegrationError) throws {
        try update(promptId: promptId) { record in
            record.attemptCount += 1
            record.lastError = error
            record.nextRetryAt = Current.date().timeIntervalSince1970 + retryDelay(attemptCount: record.attemptCount)
        }
    }

    static func markDelivered(promptId: String) throws {
        try update(promptId: promptId) { record in
            record.deliveredAt = Current.date().timeIntervalSince1970
            record.lastError = nil
            record.nextRetryAt = nil
        }
    }

    static func delete(promptId: String) throws {
        try GarminDatabaseSchema.createIfNeeded()
        try Current.database().write { db in
            _ = try GarminPromptOutboxRecord.deleteOne(db, key: promptId)
        }
    }

    private static func update(
        promptId: String,
        _ updateRecord: (inout GarminPromptOutboxRecord) -> Void
    ) throws {
        try GarminDatabaseSchema.createIfNeeded()
        try Current.database().write { db in
            guard var record = try GarminPromptOutboxRecord.fetchOne(db, key: promptId) else { return }
            updateRecord(&record)
            try record.save(db)
        }
    }

    private static func pruneExpired(_ db: Database) throws {
        let now = Int(Current.date().timeIntervalSince1970)
        let records = try GarminPromptOutboxRecord.fetchAll(db)
        for record in records {
            if let expiresAt = record.pendingPrompt.prompt.expiresAt, expiresAt <= now {
                try record.delete(db)
            }
        }
    }

    private static func pruneOverflow(_ db: Database) throws {
        let records = try GarminPromptOutboxRecord
            .fetchAll(db)
            .sorted { $0.pendingPrompt.createdAt < $1.pendingPrompt.createdAt }
        guard records.count > maxPendingPrompts else { return }
        for record in records.prefix(records.count - maxPendingPrompts) {
            try record.delete(db)
        }
    }

    private static func retryDelay(attemptCount: Int) -> TimeInterval {
        switch attemptCount {
        case 0, 1:
            return 5
        case 2:
            return 15
        case 3:
            return 60
        default:
            return 300
        }
    }
}
