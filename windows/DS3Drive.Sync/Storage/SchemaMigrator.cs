namespace DS3Drive.Sync.Storage;

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Data.Sqlite;
using Microsoft.Extensions.Logging;

/// <summary>
/// Applies versioned SQL migrations embedded as <c>Migrations/00N_*.sql</c>
/// resources, in numeric order, skipping versions already recorded in the
/// <c>schema_version</c> table.
///
/// Each migration script is responsible for inserting its own
/// <c>schema_version</c> row (see 001_initial.sql). A migration runs inside a
/// single transaction; if it throws, the transaction rolls back and the
/// exception propagates. The caller (<see cref="SyncDatabase"/>) treats a thrown
/// migration as the schema-corruption signal and deletes + recreates the store
/// (PATTERNS §2.12 — the placeholder index is a cache, not user data).
/// </summary>
internal static class SchemaMigrator
{
    // Matches embedded resource names like "...Migrations.001_initial.sql".
    private static readonly Regex MigrationName =
        new(@"Migrations\.(?<version>\d+)_[^.]+\.sql$", RegexOptions.Compiled);

    public static async Task ApplyAsync(SqliteConnection conn, ILogger? logger, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(conn);

        // Read already-applied versions. The schema_version table is created by
        // migration 001 itself (it appears in 001_initial.sql), so we must NOT
        // pre-create it here — doing so would make the 001 CREATE TABLE conflict.
        // Treat a missing table as "no migrations applied yet".
        var applied = await GetAppliedVersionsAsync(conn, ct).ConfigureAwait(false);

        foreach (var migration in DiscoverMigrations())
        {
            if (applied.Contains(migration.Version))
            {
                continue;
            }

            logger?.LogInformation("Applying schema migration {Version} ({Resource})",
                migration.Version, migration.ResourceName);

            await using var tx = (SqliteTransaction)await conn.BeginTransactionAsync(ct).ConfigureAwait(false);
            try
            {
                await using (var cmd = conn.CreateCommand())
                {
                    cmd.Transaction = tx;
                    cmd.CommandText = migration.Sql;
                    await cmd.ExecuteNonQueryAsync(ct).ConfigureAwait(false);
                }

                await tx.CommitAsync(ct).ConfigureAwait(false);
            }
            catch (SqliteException ex)
            {
                logger?.LogError(ex, "Schema migration {Version} failed; rolling back", migration.Version);
                await tx.RollbackAsync(CancellationToken.None).ConfigureAwait(false);
                throw;
            }
        }
    }

    private static async Task<HashSet<int>> GetAppliedVersionsAsync(SqliteConnection conn, CancellationToken ct)
    {
        var versions = new HashSet<int>();

        // schema_version may not exist on a brand-new database. Probe sqlite_master
        // first so we don't throw before migration 001 has created it.
        await using (var probe = conn.CreateCommand())
        {
            probe.CommandText =
                "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'schema_version';";
            var exists = Convert.ToInt64(await probe.ExecuteScalarAsync(ct).ConfigureAwait(false)) > 0;
            if (!exists)
            {
                return versions;
            }
        }

        await using var cmd = conn.CreateCommand();
        cmd.CommandText = "SELECT version FROM schema_version;";
        await using var reader = await cmd.ExecuteReaderAsync(ct).ConfigureAwait(false);
        while (await reader.ReadAsync(ct).ConfigureAwait(false))
        {
            versions.Add(reader.GetInt32(0));
        }
        return versions;
    }

    private static IEnumerable<Migration> DiscoverMigrations()
    {
        var asm = typeof(SchemaMigrator).Assembly;
        var migrations = new List<Migration>();

        foreach (var resource in asm.GetManifestResourceNames())
        {
            var match = MigrationName.Match(resource);
            if (!match.Success)
            {
                continue;
            }

            int version = int.Parse(match.Groups["version"].Value);
            migrations.Add(new Migration(version, resource, ReadResource(asm, resource)));
        }

        return migrations.OrderBy(m => m.Version);
    }

    private static string ReadResource(Assembly asm, string resourceName)
    {
        using var stream = asm.GetManifestResourceStream(resourceName)
            ?? throw new InvalidOperationException($"Embedded migration resource not found: {resourceName}");
        using var reader = new StreamReader(stream);
        return reader.ReadToEnd();
    }

    private sealed record Migration(int Version, string ResourceName, string Sql);
}
