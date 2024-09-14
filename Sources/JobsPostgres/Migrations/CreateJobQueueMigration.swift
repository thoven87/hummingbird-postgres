//
//  CreateJob.swift
//  hummingbird-postgres
//
//  Created by Stevenson Michel on 9/13/24.
//

import HummingbirdPostgres
import Logging
import PostgresNIO

struct CreateJobQueueMigration: PostgresMigration {
    func apply(connection: PostgresConnection, logger: Logger) async throws {
        try await connection.query(
            """
            CREATE TABLE IF NOT EXISTS job_queue (
                id UUID NOT NULL,
                job_name VARCHAR(255) NOT NULL,
                payload BYTEA NOT NULL,
                status SMALLINT NOT NULL,
                did_pause BOOLEAN NOT NULL DEFAULT FALSE,
                priority INTEGER DEFAULT 10,
                updated_at TIMESTAMPTZ DEFAULT NOW(),
                created_at TIMESTAMPTZ DEFAULT NOW() NOT NULL,
                delayed_until TIMESTAMPTZ,
                debounce_key VARCHAR(64),

                PRIMARY KEY (priority, created_at, id) 
            );
            """,
            logger: logger
        )
    }
    
    func revert(connection: PostgresConnection, logger: Logger) async throws {
        try await connection.query(
            "DROP TABLE job_queue",
            logger: logger
        )
    }
    
    var name: String { "_Create_JobQueue_Table_" }
    var group: PostgresMigrationGroup { .jobQueue }
}

extension PostgresMigrationGroup {
    /// JobQueue migration group
    public static var jobQueue: Self { .init("_hb_jobqueue") }
}
