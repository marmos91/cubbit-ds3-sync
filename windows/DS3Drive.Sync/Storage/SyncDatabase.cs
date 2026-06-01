namespace DS3Drive.Sync.Storage;

using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Data.Sqlite;
using Microsoft.Extensions.Logging;

/// <summary>
/// SQLite-backed persistence layer for the Windows sync engine — the Apple
/// <c>SharedData</c> + <c>MetadataStore</c> analog (PATTERNS §3.4). Opens
/// <c>%LOCALAPPDATA%\Cubbit\DS3Drive\sync.db</c> (CONTEXT D-11) and runs
/// embedded migrations on first open.
///
/// The placeholder index is a cache, not user data. Schema recovery deletes and
/// recreates the store — it never prompts the user. The canonical state lives in
/// S3 plus the cfapi placeholder bits, so a dropped index is re-enumerated from
/// the cloud on the next sync. See MetadataStore.swift lines 15-47; future
/// maintainers will be tempted to "preserve" the index — do not.
///
/// The database path is user-scoped under <c>%LOCALAPPDATA%</c>, which carries
/// per-user ACLs by default on Windows (threat T-17-06-02): other users cannot
/// read it. No secrets are stored here regardless (D-12 / D-14).
/// </summary>
public sealed class SyncDatabase : IAsyncDisposable
{
    private readonly string _dbPath;
    private readonly ILogger<SyncDatabase>? _logger;

    public SyncDatabase(string? dbPath = null, ILogger<SyncDatabase>? logger = null)
    {
        _dbPath = dbPath ?? DefaultDbPath();
        _logger = logger;
        ConnectionString = new SqliteConnectionStringBuilder
        {
            DataSource = _dbPath,
            Mode = SqliteOpenMode.ReadWriteCreate,
            // Private cache (default): each connection has its own page cache and
            // WAL gives the concurrent-reader / single-writer behaviour we need
            // (D-11). Shared cache is for in-memory DBs and would not improve a
            // file-backed store here.
            Cache = SqliteCacheMode.Private,
        }.ToString();
    }

    /// <summary>The Microsoft.Data.Sqlite connection string for downstream stores.</summary>
    public string ConnectionString { get; }

    /// <summary>The resolved on-disk path of the SQLite database file.</summary>
    public string DatabasePath => _dbPath;

    /// <summary>Default location: <c>%LOCALAPPDATA%\Cubbit\DS3Drive\sync.db</c> (D-11).</summary>
    private static string DefaultDbPath() => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "Cubbit", "DS3Drive", "sync.db");

    /// <summary>
    /// Ensures the parent directory exists, opens a connection, and runs
    /// migrations. If migration throws (corrupt or unreadable store), the
    /// <c>.db</c> / <c>.db-shm</c> / <c>.db-wal</c> files are deleted and the
    /// open is retried once (PATTERNS §2.12). If the retry also fails, the
    /// exception propagates.
    /// </summary>
    public async Task OpenAsync(CancellationToken ct)
    {
        var dir = Path.GetDirectoryName(_dbPath);
        if (!string.IsNullOrEmpty(dir))
        {
            Directory.CreateDirectory(dir);
        }

        try
        {
            await OpenAndMigrateAsync(ct).ConfigureAwait(false);
        }
        catch (SqliteException ex)
        {
            _logger?.LogWarning(ex,
                "sync.db open/migrate failed — deleting and recreating (cache, not user data)");

            // Connection pooling can keep file handles open; clear before delete.
            SqliteConnection.ClearAllPools();
            DeleteStoreFiles();

            await OpenAndMigrateAsync(ct).ConfigureAwait(false);
        }
    }

    private async Task OpenAndMigrateAsync(CancellationToken ct)
    {
        await using var conn = new SqliteConnection(ConnectionString);
        await conn.OpenAsync(ct).ConfigureAwait(false);

        await using (var pragma = conn.CreateCommand())
        {
            // WAL for concurrent cfapi reader / engine writer (D-11). Touching a
            // journal pragma also forces SQLite to read the header, so a corrupt
            // file surfaces here as a SqliteException → recovery path.
            pragma.CommandText = "PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON;";
            await pragma.ExecuteNonQueryAsync(ct).ConfigureAwait(false);
        }

        await SchemaMigrator.ApplyAsync(conn, _logger, ct).ConfigureAwait(false);
    }

    /// <summary>
    /// Opens a fresh connection per call (Microsoft.Data.Sqlite pools internally)
    /// with <c>PRAGMA foreign_keys = ON</c> so <c>ON DELETE CASCADE</c> fires.
    /// </summary>
    public async Task<SqliteConnection> AcquireConnectionAsync(CancellationToken ct)
    {
        var conn = new SqliteConnection(ConnectionString);
        await conn.OpenAsync(ct).ConfigureAwait(false);
        await using (var pragma = conn.CreateCommand())
        {
            pragma.CommandText = "PRAGMA foreign_keys = ON;";
            await pragma.ExecuteNonQueryAsync(ct).ConfigureAwait(false);
        }
        return conn;
    }

    private void DeleteStoreFiles()
    {
        foreach (var suffix in new[] { "", "-shm", "-wal" })
        {
            var path = _dbPath + suffix;
            try
            {
                if (File.Exists(path))
                {
                    File.Delete(path);
                }
            }
            catch (IOException ex)
            {
                _logger?.LogWarning(ex, "Could not delete store file {Path} during recovery", path);
            }
        }
    }

    /// <summary>
    /// No-op: Microsoft.Data.Sqlite's connection pool owns connection lifetime;
    /// each <see cref="AcquireConnectionAsync"/> caller disposes its own
    /// connection. Present to satisfy the <see cref="IAsyncDisposable"/> contract
    /// and allow future long-lived-connection cleanup without an API change.
    /// </summary>
    public ValueTask DisposeAsync() => ValueTask.CompletedTask;
}
