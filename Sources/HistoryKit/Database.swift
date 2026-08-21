import Foundation
import SQLite3

/// SQLite's "copy this buffer, I may free mine" destructor. Swift strings are
/// only guaranteed valid for the duration of `withCString`, so every text bind
/// must be transient — `STATIC` here would bind freed memory.
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum HistoryError: LocalizedError, Equatable {
    case sqlite(String)
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .sqlite(let message):      return "History database error: \(message)"
        case .unavailable(let message): return "History unavailable: \(message)"
        }
    }
}

/// A thin wrapper over the C API — enough to prepare, bind, and step, and no
/// more. Deliberately not `Sendable`: a connection is owned by exactly one
/// actor (`HistoryRecorder`), which is what keeps the threading model simple.
final class Database {
    fileprivate var handle: OpaquePointer?

    /// SQLite bytecode steps executed on this connection, accumulated as each
    /// statement is finalised.
    ///
    /// A cost that can be *asserted on* rather than timed. "This must not become
    /// O(n²)" used to be written as a wall-clock threshold, which is a
    /// measurement of the machine as much as of the code: on a loaded box it
    /// fails for reasons that have nothing to do with the query, and on a fast
    /// one it passes however quadratic the plan became. Steps are a property of
    /// the statements and the data, so the same trace costs the same on any
    /// machine, under any load.
    fileprivate(set) var workUnits: Int = 0

    init(path: String) throws {
        var opened: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let code = sqlite3_open_v2(path, &opened, flags, nil)
        guard code == SQLITE_OK, let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) }
                ?? "could not open \(path) (code \(code))"
            sqlite3_close_v2(opened)
            throw HistoryError.sqlite(message)
        }
        handle = opened
        // WAL means a reader never blocks the recorder's 10-second flush.
        sqlite3_busy_timeout(opened, 3_000)
    }

    deinit {
        if let handle { sqlite3_close_v2(handle) }
    }

    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(error)
            throw HistoryError.sqlite("\(message) — \(sql)")
        }
    }

    func prepare(_ sql: String) throws -> Statement {
        try Statement(database: self, sql: sql)
    }

    /// IMMEDIATE rather than DEFERRED: the write lock is taken up front, so a
    /// batch insert can't fail halfway through with SQLITE_BUSY.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }

    /// Rows changed by the most recent statement.
    var changes: Int { Int(sqlite3_changes(handle)) }

    var userVersion: Int32 {
        get {
            guard let statement = try? prepare("PRAGMA user_version"),
                  (try? statement.step()) == true else { return 0 }
            return Int32(statement.int64(0))
        }
    }

    func setUserVersion(_ version: Int32) throws {
        // PRAGMA won't take a bound parameter; the value is an Int32 we produced.
        try execute("PRAGMA user_version = \(version)")
    }
}

/// A prepared statement. Bind indices are 1-based, column indices 0-based —
/// SQLite's convention, kept rather than papered over.
final class Statement {
    private var statement: OpaquePointer?
    /// Strong, so the connection cannot be closed out from under a live
    /// statement — the ordering that makes `sqlite3_finalize` in `deinit` safe.
    private let database: Database

    init(database: Database, sql: String) throws {
        self.database = database
        guard let handle = database.handle else {
            throw HistoryError.sqlite("connection is closed")
        }
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw HistoryError.sqlite("\(String(cString: sqlite3_errmsg(handle))) — \(sql)")
        }
    }

    deinit {
        // Read before finalising: the counter lives on the statement, and
        // `sqlite3_finalize` is what destroys it. Totalled here rather than per
        // `step` so a statement reset and re-run in a loop — the batch insert —
        // is counted once, in full.
        if let statement {
            database.workUnits += Int(sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_VM_STEP, 0))
        }
        sqlite3_finalize(statement)
    }

    @discardableResult
    func bind(_ index: Int32, _ value: Int64) -> Statement {
        sqlite3_bind_int64(statement, index, value)
        return self
    }

    @discardableResult
    func bind(_ index: Int32, _ value: Double) -> Statement {
        sqlite3_bind_double(statement, index, value)
        return self
    }

    @discardableResult
    func bind(_ index: Int32, _ value: String) -> Statement {
        sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
        return self
    }

    @discardableResult
    func bind(_ index: Int32, _ value: Int64?) -> Statement {
        if let value { return bind(index, value) }
        sqlite3_bind_null(statement, index)
        return self
    }

    @discardableResult
    func bind(_ index: Int32, _ value: Double?) -> Statement {
        if let value { return bind(index, value) }
        sqlite3_bind_null(statement, index)
        return self
    }

    @discardableResult
    func bind(_ index: Int32, _ value: String?) -> Statement {
        if let value { return bind(index, value) }
        sqlite3_bind_null(statement, index)
        return self
    }

    /// True when a row is available, false at end of results.
    @discardableResult
    func step() throws -> Bool {
        switch sqlite3_step(statement) {
        case SQLITE_ROW:  return true
        case SQLITE_DONE: return false
        default:
            let message = database.handle.map { String(cString: sqlite3_errmsg($0)) } ?? "step failed"
            throw HistoryError.sqlite(message)
        }
    }

    /// Step a statement that returns no rows.
    func run() throws {
        _ = try step()
    }

    func reset() {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
    }

    func int64(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
    func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }

    func string(_ column: Int32) -> String {
        guard let text = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: text)
    }

    func isNull(_ column: Int32) -> Bool {
        sqlite3_column_type(statement, column) == SQLITE_NULL
    }

    func optionalDouble(_ column: Int32) -> Double? {
        isNull(column) ? nil : double(column)
    }

    func optionalInt64(_ column: Int32) -> Int64? {
        isNull(column) ? nil : int64(column)
    }

    func optionalString(_ column: Int32) -> String? {
        isNull(column) ? nil : string(column)
    }
}
