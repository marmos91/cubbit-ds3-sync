namespace DS3Drive.Tests;

using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using DS3Drive.Sync.Storage;
using Microsoft.Data.Sqlite;
using Xunit;

/// <summary>
/// Tests for <see cref="SyncDatabase"/> — first-open schema creation, silent
/// schema-recovery on corruption (PATTERNS §2.12), and re-entrant dispose. Each
/// test isolates state in a temp directory and cleans up in a <c>finally</c>.
/// </summary>
public sealed class SyncDatabaseTests
{
    // Number of embedded migration scripts: 001_initial + 002_singleton_state (Plan 09).
    // Each script inserts one schema_version row, so a fully-migrated db has this many rows.
    private const long MigrationCount = 2L;

    private static string NewTempDbPath() =>
        Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString(), "sync.db");

    private static void Cleanup(string dbPath)
    {
        SqliteConnection.ClearAllPools();
        var dir = Path.GetDirectoryName(dbPath);
        try
        {
            if (dir is not null && Directory.Exists(dir))
            {
                Directory.Delete(dir, recursive: true);
            }
        }
        catch (IOException)
        {
            // Best-effort: WAL/SHM handles may linger briefly on Windows.
        }
    }

    private static async Task<long> CountSchemaVersionRowsAsync(SyncDatabase db)
    {
        await using var conn = await db.AcquireConnectionAsync(CancellationToken.None);
        await using var cmd = conn.CreateCommand();
        cmd.CommandText = "SELECT COUNT(*) FROM schema_version;";
        return (long)(await cmd.ExecuteScalarAsync())!;
    }

    // Test: OpenAsync on a fresh directory creates the schema_version table.
    [Fact]
    public async Task OpenAsync_OnFreshDirectory_CreatesSchemaVersionTable()
    {
        string dbPath = NewTempDbPath();
        try
        {
            await using var db = new SyncDatabase(dbPath);
            await db.OpenAsync(CancellationToken.None);

            Assert.True(File.Exists(dbPath));
            // One row per applied migration: 001_initial + 002_singleton_state (Plan 09).
            Assert.Equal(MigrationCount, await CountSchemaVersionRowsAsync(db));
        }
        finally
        {
            Cleanup(dbPath);
        }
    }

    // Test: OpenAsync on a corrupt .db file deletes and recreates it (PATTERNS §2.12).
    [Fact]
    public async Task OpenAsync_OnCorruptDb_DeletesAndRecreates()
    {
        string dbPath = NewTempDbPath();
        try
        {
            var dir = Path.GetDirectoryName(dbPath)!;
            Directory.CreateDirectory(dir);
            // Garbage bytes that are NOT a valid SQLite header.
            await File.WriteAllTextAsync(dbPath, "this is not a sqlite database, just noise");

            await using var db = new SyncDatabase(dbPath);
            await db.OpenAsync(CancellationToken.None);

            // Recovery succeeded: a valid schema now exists (all migrations re-applied).
            Assert.Equal(MigrationCount, await CountSchemaVersionRowsAsync(db));
        }
        finally
        {
            Cleanup(dbPath);
        }
    }

    // Test: DisposeAsync is re-entrant and never throws.
    [Fact]
    public async Task OpenAsync_ReentrantClose_DoesNotThrow()
    {
        string dbPath = NewTempDbPath();
        try
        {
            var db = new SyncDatabase(dbPath);
            await db.OpenAsync(CancellationToken.None);

            await db.DisposeAsync();
            await db.DisposeAsync(); // second dispose must be a no-op
        }
        finally
        {
            Cleanup(dbPath);
        }
    }

    // Test: re-opening an already-migrated db does not duplicate schema_version rows.
    [Fact]
    public async Task OpenAsync_OnExistingDb_DoesNotReapplyMigration()
    {
        string dbPath = NewTempDbPath();
        try
        {
            await using (var first = new SyncDatabase(dbPath))
            {
                await first.OpenAsync(CancellationToken.None);
            }

            await using var second = new SyncDatabase(dbPath);
            await second.OpenAsync(CancellationToken.None);

            // Re-open must not duplicate rows: still exactly one row per migration.
            Assert.Equal(MigrationCount, await CountSchemaVersionRowsAsync(second));
        }
        finally
        {
            Cleanup(dbPath);
        }
    }
}
