import Foundation
import GRDB

public final class DatabaseManager: Sendable {
    public let dbPool: DatabasePool

    public init(url: URL = TxPaths.databaseURL) throws {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        self.dbPool = try DatabasePool(path: url.path, configuration: config)
        try migrator.migrate(dbPool)
    }

    public static func inMemory() throws -> DatabaseManager {
        let db = try DatabaseManager(url: URL(fileURLWithPath: ":memory:"))
        return db
    }

    private var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1_initial") { db in
            try db.execute(sql: """
                CREATE TABLE projects (
                    id          TEXT PRIMARY KEY,
                    name        TEXT NOT NULL,
                    color       TEXT NOT NULL,
                    created_at  REAL NOT NULL
                );
            """)

            try db.execute(sql: """
                CREATE TABLE project_rules (
                    id          TEXT PRIMARY KEY,
                    project_id  TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
                    type        TEXT NOT NULL,
                    value       TEXT NOT NULL,
                    priority    INTEGER NOT NULL DEFAULT 0
                );
            """)
            try db.execute(sql: "CREATE INDEX project_rules_project_id ON project_rules(project_id);")

            try db.execute(sql: """
                CREATE TABLE chrome_profiles (
                    id              TEXT PRIMARY KEY,
                    name            TEXT NOT NULL,
                    user_data_dir   TEXT NOT NULL UNIQUE,
                    project_id      TEXT REFERENCES projects(id) ON DELETE SET NULL,
                    color           TEXT,
                    created_at      REAL NOT NULL
                );
            """)

            try db.execute(sql: """
                CREATE TABLE sessions (
                    id                  TEXT PRIMARY KEY,
                    project_id          TEXT REFERENCES projects(id) ON DELETE SET NULL,
                    title               TEXT NOT NULL,
                    process_name        TEXT NOT NULL,
                    process_pid         INTEGER,
                    app_audio_path      TEXT,
                    mic_audio_path      TEXT,
                    playback_audio_path TEXT,
                    started_at          REAL NOT NULL,
                    ended_at            REAL,
                    duration_seconds    REAL,
                    status              TEXT NOT NULL DEFAULT 'recording',
                    chrome_profile_id   TEXT REFERENCES chrome_profiles(id) ON DELETE SET NULL,
                    meeting_url         TEXT,
                    transcript_model    TEXT,
                    created_at          REAL NOT NULL
                );
            """)
            try db.execute(sql: "CREATE INDEX sessions_project_id ON sessions(project_id);")
            try db.execute(sql: "CREATE INDEX sessions_started_at ON sessions(started_at);")
            try db.execute(sql: "CREATE INDEX sessions_status ON sessions(status);")

            try db.execute(sql: """
                CREATE TABLE segments (
                    id          TEXT PRIMARY KEY,
                    session_id  TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                    speaker     TEXT NOT NULL,
                    channel     TEXT NOT NULL,
                    text        TEXT NOT NULL,
                    start_ms    INTEGER NOT NULL,
                    end_ms      INTEGER NOT NULL,
                    confidence  REAL
                );
            """)
            try db.execute(sql: "CREATE INDEX segments_session_id ON segments(session_id);")
            try db.execute(sql: "CREATE INDEX segments_start_ms ON segments(start_ms);")

            try db.execute(sql: """
                CREATE VIRTUAL TABLE segments_fts USING fts5(
                    text,
                    content=segments,
                    content_rowid=rowid,
                    tokenize='unicode61'
                );
            """)

            try db.execute(sql: """
                CREATE TRIGGER segments_ai AFTER INSERT ON segments BEGIN
                    INSERT INTO segments_fts(rowid, text) VALUES (new.rowid, new.text);
                END;
            """)

            try db.execute(sql: """
                CREATE TRIGGER segments_ad AFTER DELETE ON segments BEGIN
                    INSERT INTO segments_fts(segments_fts, rowid, text)
                    VALUES ('delete', old.rowid, old.text);
                END;
            """)

            try db.execute(sql: """
                CREATE TRIGGER segments_au AFTER UPDATE ON segments BEGIN
                    INSERT INTO segments_fts(segments_fts, rowid, text)
                    VALUES ('delete', old.rowid, old.text);
                    INSERT INTO segments_fts(rowid, text) VALUES (new.rowid, new.text);
                END;
            """)
        }

        m.registerMigration("v2_participants") { db in
            try db.execute(sql: """
                ALTER TABLE sessions ADD COLUMN participants TEXT NOT NULL DEFAULT '[]';
            """)
        }

        m.registerMigration("v3_tags") { db in
            try db.execute(sql: """
                CREATE TABLE tags (
                    id          TEXT PRIMARY KEY,
                    name        TEXT NOT NULL,
                    color       TEXT NOT NULL DEFAULT '#8B5CF6',
                    created_at  REAL NOT NULL
                );
            """)

            try db.execute(sql: """
                CREATE TABLE session_tags (
                    session_id  TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                    tag_id      TEXT NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
                    PRIMARY KEY (session_id, tag_id)
                );
            """)
            try db.execute(sql: "CREATE INDEX session_tags_session_id ON session_tags(session_id);")
            try db.execute(sql: "CREATE INDEX session_tags_tag_id ON session_tags(tag_id);")
        }

        m.registerMigration("v4_dictations") { db in
            try db.execute(sql: """
                CREATE TABLE dictations (
                    id              TEXT PRIMARY KEY,
                    started_at      REAL NOT NULL,
                    duration_ms     INTEGER NOT NULL,
                    word_count      INTEGER NOT NULL,
                    wpm             REAL NOT NULL,
                    text            TEXT NOT NULL,
                    mode            TEXT NOT NULL,
                    target_app      TEXT,
                    target_bundle   TEXT,
                    pasted          INTEGER NOT NULL DEFAULT 1,
                    canceled        INTEGER NOT NULL DEFAULT 0,
                    audio_path      TEXT,
                    created_at      REAL NOT NULL
                );
            """)
            try db.execute(sql: "CREATE INDEX dictations_started_at ON dictations(started_at DESC);")

            try db.execute(sql: """
                CREATE VIRTUAL TABLE dictations_fts USING fts5(
                    text,
                    content=dictations,
                    content_rowid=rowid,
                    tokenize='unicode61'
                );
            """)

            try db.execute(sql: """
                CREATE TRIGGER dictations_ai AFTER INSERT ON dictations BEGIN
                    INSERT INTO dictations_fts(rowid, text) VALUES (new.rowid, new.text);
                END;
            """)
            try db.execute(sql: """
                CREATE TRIGGER dictations_ad AFTER DELETE ON dictations BEGIN
                    INSERT INTO dictations_fts(dictations_fts, rowid, text)
                    VALUES ('delete', old.rowid, old.text);
                END;
            """)
            try db.execute(sql: """
                CREATE TRIGGER dictations_au AFTER UPDATE ON dictations BEGIN
                    INSERT INTO dictations_fts(dictations_fts, rowid, text)
                    VALUES ('delete', old.rowid, old.text);
                    INSERT INTO dictations_fts(rowid, text) VALUES (new.rowid, new.text);
                END;
            """)
        }

        return m
    }
}
