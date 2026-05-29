namespace DS3Drive.ViewModels.Services;

using System.Threading;
using DS3Drive.Sync.Storage;
using Microsoft.Data.Sqlite;

/// <summary>
/// SQLite-backed <see cref="IInstallationIdProvider"/>. Reads the
/// <c>singleton_state['installation_id']</c> row (migration 002); on first access it
/// generates a fresh <c>Guid.NewGuid()</c> and persists it with an <c>INSERT … ON
/// CONFLICT DO NOTHING</c> so concurrent first-runs converge on a single value
/// (PATTERNS §2.6, threat T-17-09-04). The value is cached after the first read.
/// </summary>
public sealed class SqliteInstallationIdProvider : IInstallationIdProvider
{
    private const string Key = "installation_id";

    private readonly SyncDatabase _db;
    private readonly object _gate = new();
    private string? _cached;

    public SqliteInstallationIdProvider(SyncDatabase db) => _db = db;

    /// <inheritdoc />
    public string InstallationId
    {
        get
        {
            lock (_gate)
            {
                if (_cached is not null)
                {
                    return _cached;
                }

                _cached = LoadOrCreate();
                return _cached;
            }
        }
    }

    private string LoadOrCreate()
    {
        // Synchronous over the async acquire: this is read once at startup / first
        // wizard run, off the UI thread (the SDK calls already run on a worker).
        using SqliteConnection conn = _db.AcquireConnectionAsync(CancellationToken.None)
            .GetAwaiter().GetResult();

        using (var read = conn.CreateCommand())
        {
            read.CommandText = "SELECT value FROM singleton_state WHERE key = @k;";
            read.Parameters.AddWithValue("@k", Key);
            if (read.ExecuteScalar() is string existing && !string.IsNullOrEmpty(existing))
            {
                return existing;
            }
        }

        string created = Guid.NewGuid().ToString("D");
        using (var insert = conn.CreateCommand())
        {
            insert.CommandText =
                "INSERT INTO singleton_state (key, value) VALUES (@k, @v) ON CONFLICT(key) DO NOTHING;";
            insert.Parameters.AddWithValue("@k", Key);
            insert.Parameters.AddWithValue("@v", created);
            insert.ExecuteNonQuery();
        }

        // A racing first-run may have won the INSERT; re-read to return the committed value.
        using (var reread = conn.CreateCommand())
        {
            reread.CommandText = "SELECT value FROM singleton_state WHERE key = @k;";
            reread.Parameters.AddWithValue("@k", Key);
            return reread.ExecuteScalar() as string ?? created;
        }
    }
}
