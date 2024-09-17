//===----------------------------------------------------------------------===//
//
// This source file is part of the Hummingbird server framework project
//
// Copyright (c) 2024 the Hummingbird authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See hummingbird/CONTRIBUTORS.txt for the list of Hummingbird authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Foundation
import HummingbirdPostgres
import Jobs
import Logging
import NIOConcurrencyHelpers
import NIOCore
import PostgresNIO

/// Postgres Job queue implementation
///
/// The Postgres driver uses the database migration service ``/HummingbirdPostgres/PostgresMigrations``
/// to create its database tables. Before the server is running you should run the migrations
/// to build your table.
/// ```
/// let migrations = PostgresMigrations()
/// let jobqueue = await JobQueue(
///     PostgresQueue(
///         client: postgresClient,
///         migrations: postgresMigrations,
///         configuration: configuration,
///         logger: logger
///    ),
///    numWorkers: numWorkers,
///    logger: logger
/// )
/// var app = Application(...)
/// app.beforeServerStarts {
///     try await migrations.apply(client: postgresClient, logger: logger, dryRun: applyMigrations)
/// }
/// ```
public final class PostgresJobQueue: JobQueueDriver {
    public typealias JobID = UUID

    /// what to do with failed/processing jobs from last time queue was handled
    public enum JobInitialization: Sendable {
        case doNothing
        case rerun
        case remove
    }

    /// Errors thrown by PostgresJobQueue
    public enum PostgresQueueError: Error, CustomStringConvertible {
        case failedToAdd

        public var description: String {
            switch self {
            case .failedToAdd:
                return "Failed to add job to queue"
            }
        }
    }

    /// Job Status
    enum Status: Int16, PostgresCodable {
        case pending = 0
        case processing = 1
        case failed = 2
    }

    /// Queue configuration
    public struct Configuration: Sendable {
        let pendingJobsInitialization: JobInitialization
        let failedJobsInitialization: JobInitialization
        let processingJobsInitialization: JobInitialization
        let pollTime: Duration

        public init(
            pendingJobsInitialization: JobInitialization = .doNothing,
            failedJobsInitialization: JobInitialization = .rerun,
            processingJobsInitialization: JobInitialization = .rerun,
            pollTime: Duration = .milliseconds(100)
        ) {
            self.pendingJobsInitialization = pendingJobsInitialization
            self.failedJobsInitialization = failedJobsInitialization
            self.processingJobsInitialization = processingJobsInitialization
            self.pollTime = pollTime
        }
    }

    /// Postgres client used by Job queue
    public let client: PostgresClient
    /// Job queue configuration
    public let configuration: Configuration
    /// Logger used by queue
    public let logger: Logger

    let migrations: PostgresMigrations
    let isStopped: NIOLockedValueBox<Bool>

    /// Initialize a PostgresJobQueue
    public init(client: PostgresClient, migrations: PostgresMigrations, configuration: Configuration = .init(), logger: Logger) async {
        self.client = client
        self.configuration = configuration
        self.logger = logger
        self.isStopped = .init(false)
        self.migrations = migrations
        await migrations.add(CreateJobQueueMetadata())
        await migrations.add(CreateJobQueueMigration())
    }

    /// Run on initialization of the job queue
    public func onInit() async throws {
        do {
            self.logger.info("Waiting for JobQueue migrations")
            try await self.migrations.waitUntilCompleted()
            _ = try await self.client.withConnection { connection in
                self.logger.info("Update Jobs at initialization")
                try await self.updateJobsOnInit(withStatus: .pending, onInit: self.configuration.pendingJobsInitialization, connection: connection)
                try await self.updateJobsOnInit(withStatus: .processing, onInit: self.configuration.processingJobsInitialization, connection: connection)
                try await self.updateJobsOnInit(withStatus: .failed, onInit: self.configuration.failedJobsInitialization, connection: connection)
            }
        } catch let error as PSQLError {
            self.logger.info("failed to run migrations", metadata: [
                "error": "\(String(reflecting: error))"
            ])
            throw error
        }
    }

    /// Push Job onto queue
    /// - Returns: Identifier of queued job
    @discardableResult public func push(_ buffer: ByteBuffer, options: JobOptions) async throws -> JobID {
        let queuedJob = QueuedJob<JobID>(id: .init(), jobBuffer: buffer)
        try await self.addJob(queuedJob, buffer: buffer, options: options, connection: self.client)
        return queuedJob.id
    }
    
    private func addJob(_ job: QueuedJob<JobID>, buffer: ByteBuffer, options: JobOptions, connection: PostgresClient) async throws {
        /// TODO: compute debounce and update the query
        try await connection.query(
            """
            INSERT INTO job_queue (
                id,
                job_name,
                payload,
                status,
                delayed_until,
                debounce_key,
                priority
            )
            VALUES(
                \(job.id),
                'DEFAULT', -- TODO: take in job name
                \(buffer),
                \(Status.pending),
                \(options.delayUntil),
                MD5('\(job.id)|NOW()|\(Status.pending)'),
                \(options.priority)
            )
            """,
            logger: logger
        )
        
    }
    /// This is called to say job has finished processing and it can be deleted
    public func finished(jobId: JobID) async throws {
        try await self.delete(jobId: jobId)
    }

    /// This is called to say job has failed to run and should be put aside
    public func failed(jobId: JobID, error: Error) async throws {
        try await self.setStatus(jobId: jobId, status: .failed)
    }

    /// stop serving jobs
    public func stop() async {
        self.isStopped.withLockedValue { $0 = true }
    }

    /// shutdown queue once all active jobs have been processed
    public func shutdownGracefully() async {}

    public func getMetadata(_ key: String) async throws -> ByteBuffer? {
        let stream = try await self.client.query(
            "SELECT value FROM _hb_pg_job_queue_metadata WHERE key = \(key)",
            logger: self.logger
        )
        for try await value in stream.decode(ByteBuffer.self) {
            return value
        }
        return nil
    }

    public func setMetadata(key: String, value: ByteBuffer) async throws {
        try await self.client.query(
            """
            INSERT INTO _hb_pg_job_queue_metadata (key, value) VALUES (\(key), \(value))
            ON CONFLICT (key)
            DO UPDATE SET value = \(value)
            """,
            logger: self.logger
        )
    }

    func popFirst() async throws -> QueuedJob<JobID>? {
        do {
            let result = try await self.client.withTransaction(logger: self.logger) { connection -> Result<QueuedJob<JobID>?, Error> in
                while true {
                    try Task.checkCancellation()
                    
                    var maybeFailedJobId: JobID? = nil

                    do {
                        let stream = try await connection.query(
                            """
                            UPDATE job_queue
                            SET status = \(Status.processing)
                            WHERE id = (
                                SELECT
                                    id
                                FROM job_queue
                                WHERE status = \(Status.pending)
                                AND (delayed_until IS NULL OR delayed_until <= NOW())
                                ORDER BY priority, created_at, delayed_until ASC
                                FOR UPDATE SKIP LOCKED
                                LIMIT 1
                            )
                            RETURNING id, payload
                            """,
                            logger: self.logger
                        )
                        // return nil if nothing in queue
                        let (jobId, buffer) = try await stream.decode((UUID, ByteBuffer).self, context: .default).first(where: { _ in true }) ?? (nil, nil)
                        
                        guard let jobId else {
                            // return nil if nothing in queue
                            return Result.success(nil)
                        }
                        
                        maybeFailedJobId = jobId
                        
                        guard let buffer = buffer else {
                            continue
                        }
                        return Result.success(QueuedJob(id: jobId, jobBuffer: buffer))
                    } catch {
                        /// Job Id should be set if we get here
                        if let jobId = maybeFailedJobId {
                            try await self.setStatus(jobId: jobId, status: .failed, connection: connection)
                        }
                        return Result.failure(JobQueueError.decodeJobFailed)
                    }
                }
            }
            return try result.get()
        } catch let error as PSQLError {
            logger.error("Failed to get job from queue", metadata: [
                "error": "\(String(reflecting: error))",
            ])
            throw error
        } catch let error as JobQueueError {
            logger.error("Job failed", metadata: [
                "error": "\(String(reflecting: error))",
            ])
            throw error
        }
    }

    func delete(jobId: JobID) async throws {
        try await self.client.query(
            "DELETE FROM job_queue WHERE id = \(jobId)",
            logger: self.logger
        )
    }

    func setStatus(jobId: JobID, status: Status, connection: PostgresConnection) async throws {
        try await connection.query(
            "UPDATE job_queue SET status = \(status), updated_at = \(Date.now) WHERE id = \(jobId)",
            logger: self.logger
        )
    }

    func setStatus(jobId: JobID, status: Status) async throws {
        try await self.client.query(
            "UPDATE job_queue SET status = \(status), updated_at = \(Date.now) WHERE id = \(jobId)",
            logger: self.logger
        )
    }

    func getJobs(withStatus status: Status) async throws -> [JobID] {
        let stream = try await self.client.query(
            "SELECT id FROM job_queue WHERE status = \(status) FOR UPDATE SKIP LOCKED",
            logger: self.logger
        )
        var jobs: [JobID] = []
        for try await id in stream.decode(JobID.self, context: .default) {
            jobs.append(id)
        }
        return jobs
    }

    func updateJobsOnInit(withStatus status: Status, onInit: JobInitialization, connection: PostgresConnection) async throws {
        switch onInit {
        case .remove:
            try await connection.query(
                "DELETE FROM job_queue WHERE status = \(status)",
                logger: self.logger
            )

        case .rerun:
            guard status != .pending else { return }

            let jobs = try await getJobs(withStatus: status)
            self.logger.info("Moving \(jobs.count) jobs with status: \(status) to status QUEUED")
            for jobId in jobs {
                try await self.setStatus(jobId: jobId, status: .pending, connection: connection)
            }

        case .doNothing:
            break
        }
    }
}

/// extend PostgresJobQueue to conform to AsyncSequence
extension PostgresJobQueue {
    public struct AsyncIterator: AsyncIteratorProtocol {
        public typealias Element = QueuedJob<JobID>

        let queue: PostgresJobQueue

        public func next() async throws -> Element? {
            while true {
                if self.queue.isStopped.withLockedValue({ $0 }) {
                    return nil
                }

                if let job = try await queue.popFirst() {
                    return job
                }
                // we only sleep if we didn't receive a job
                try await Task.sleep(for: self.queue.configuration.pollTime)
            }
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        return .init(queue: self)
    }
}

extension JobQueueDriver where Self == PostgresJobQueue {
    /// Return Postgres driver for Job Queue
    /// - Parameters:
    ///   - client: Postgres client
    ///   - configuration: Queue configuration
    ///   - logger: Logger used by queue
    public static func postgres(client: PostgresClient, migrations: PostgresMigrations, configuration: PostgresJobQueue.Configuration = .init(), logger: Logger) async -> Self {
        await Self(client: client, migrations: migrations, configuration: configuration, logger: logger)
    }
}
