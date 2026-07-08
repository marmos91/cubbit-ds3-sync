namespace DS3Drive.Tests;

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using DS3Drive.Core;
using DS3Drive.Core.Records;
using DS3Drive.Sync;
using DS3Drive.Sync.CfApi;
using DS3Drive.Sync.SyncEngine;
using DS3Drive.Sync.Storage;
using DS3Drive.Tests.Fixtures;
using Microsoft.Data.Sqlite;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;
using DS3DriveModel = DS3Drive.Core.Records.DS3Drive;

/// <summary>
/// Wave 4 (D-07) — the live-Cubbit half of the two-layer verification. Seeds a real bucket prefix
/// with &gt;2000 objects and proves the phase's enumeration guarantees end-to-end against S3:
/// full pagination (D-01), idempotent placeholder materialization (D-02), on-disk ghost removal
/// with dirty-edit preservation (D-03), and the sync-anchor short-circuit (D-06). Runs the real
/// listing/poll code through a <see cref="DriveS3SessionAccess"/> over a minted
/// <see cref="DS3DriveS3Client"/>; the native cfapi create/transfer/delete calls are replaced by
/// injected no-ops/recorders (a headless CI runner has no registered sync root — that path is the
/// manual-smoke checklist's job).
///
/// <para>
/// Gated by <see cref="RequiresCredentialsAttribute"/> + <c>[Trait("Category","Integration")]</c>:
/// self-skips when <c>CUBBIT_TEST_*</c> is unset (default PR build stays green) and runs only in the
/// credentials-enabled <c>workflow_dispatch</c> suite (threat T-17-03-01). The shared &gt;2000-object
/// set (read-only across tests) is seeded once by <see cref="EnumerationIntegrationFixture"/>;
/// remote-mutating tests seed their own small, isolated prefix so they never corrupt it.
/// </para>
/// </summary>
[Collection("Integration")]
public sealed class EnumerationIntegrationTests : IClassFixture<EnumerationIntegrationFixture>
{
    private readonly EnumerationIntegrationFixture _fx;

    public EnumerationIntegrationTests(EnumerationIntegrationFixture fx) => _fx = fx;

    // D-01: the poll's full-pagination listing must return EVERY object under the prefix, chasing
    // the continuation token to completion — nothing beyond the first 2000-key page is dropped.
    [RequiresCredentials, Trait("Category", "Integration")]
    public void FullEnumeration_ReturnsEveryObject_AcrossPages()
    {
        Assert.True(_fx.SeededCount > 2000, "the pagination regression must seed >2000 keys to cross a page boundary");

        PlaceholderMaterializer.Level level =
            PlaceholderMaterializer.ListLevel(_fx.Access!, _fx.Bucket, _fx.Prefix, CancellationToken.None);

        Assert.Equal(_fx.SeededCount, level.Files.Count); // no object pruned as a phantom deletion
        Assert.Empty(level.Folders);
    }

    // D-02: materializing the same level twice yields an identical placeholder set — the
    // (drive_id, s3_key) upsert makes re-enumeration idempotent, never duplicating rows.
    [RequiresCredentials, Trait("Category", "Integration")]
    public async Task Materialize_Twice_IsIdempotent_NoDuplicates()
    {
        var driveId = Guid.NewGuid();
        await using StoreScope scope = await StoreScope.CreateAsync(driveId, _fx.Bucket, _fx.Prefix);

        for (int run = 0; run < 2; run++)
        {
            await PlaceholderMaterializer.MaterializeAsync(
                _fx.Access!, _fx.Bucket, _fx.Prefix, @"C:\Root", scope.Store, driveId,
                NullLogger.Instance, CancellationToken.None, createPlaceholders: (_, _, _) => { });
        }

        IReadOnlyList<PlaceholderRecord> rows =
            await scope.Store.ListByPrefixAsync(driveId, _fx.Prefix, CancellationToken.None);
        Assert.Equal(_fx.SeededCount, rows.Count); // identical set, no duplicates on the second run
    }

    // D-03: a remote deletion removes both the DB row and the on-disk placeholder, EXCEPT a dirty
    // local edit, which is preserved. Uses its own isolated prefix so it never mutates the shared set.
    [RequiresCredentials, Trait("Category", "Integration")]
    public async Task RemoteDelete_RemovesPlaceholder_PreservesDirtyEdit()
    {
        var driveId = Guid.NewGuid();
        string prefix = _fx.BasePrefix + "delete/"; // sibling of the read-only bulk set, isolated
        string keptKey = prefix + "keep.txt";
        string goneKey = prefix + "gone.txt";
        string dirtyKey = prefix + "dirty.txt";
        await _fx.SeedObjectsAsync(new[] { keptKey, goneKey, dirtyKey });

        try
        {
            await using StoreScope scope = await StoreScope.CreateAsync(driveId, _fx.Bucket, prefix);
            var removed = new List<string>();
            await using SyncEngine engine = scope.NewEngine(
                _fx.Access!, deletePlaceholder: (_, key, _) => removed.Add(key));

            await engine.ForcePollAsync(CancellationToken.None);                       // baseline: 3 rows
            await scope.Store.MarkDirtyAsync(driveId, dirtyKey, true, CancellationToken.None);

            _fx.S3!.DeleteObject(_fx.Bucket, goneKey);                                  // remote-delete the clean one
            _fx.S3!.DeleteObject(_fx.Bucket, dirtyKey);                                 // and the dirty one
            await engine.ForcePollAsync(CancellationToken.None);

            Assert.Null(await scope.Store.FindAsync(driveId, goneKey, CancellationToken.None));      // pruned
            Assert.Contains(goneKey, removed);                                                       // on-disk removed
            Assert.NotNull(await scope.Store.FindAsync(driveId, dirtyKey, CancellationToken.None));  // dirty preserved
            Assert.DoesNotContain(dirtyKey, removed);
            Assert.NotNull(await scope.Store.FindAsync(driveId, keptKey, CancellationToken.None));   // untouched
        }
        finally
        {
            await _fx.DeleteObjectsAsync(new[] { keptKey }); // gone/dirty already deleted above
        }
    }

    // D-06: re-polling an unchanged prefix short-circuits before ComputeDelta/ApplyDelta. Proven by
    // deleting a local row out-of-band between polls: an unchanged anchor means it is NOT restored.
    [RequiresCredentials, Trait("Category", "Integration")]
    public async Task Repoll_NoRemoteChange_SkipsApply()
    {
        var driveId = Guid.NewGuid();
        string prefix = _fx.BasePrefix + "anchor/"; // sibling of the read-only bulk set, isolated
        string a = prefix + "a.txt";
        string b = prefix + "b.txt";
        await _fx.SeedObjectsAsync(new[] { a, b });

        try
        {
            await using StoreScope scope = await StoreScope.CreateAsync(driveId, _fx.Bucket, prefix);
            await using SyncEngine engine = scope.NewEngine(_fx.Access!, anchorStore: scope.Anchors);

            await engine.ForcePollAsync(CancellationToken.None); // reconcile + store anchor
            Assert.NotNull(await scope.Anchors.GetAsync(driveId, prefix, CancellationToken.None));

            await scope.Store.DeleteAsync(driveId, a, CancellationToken.None); // local drift the poll would normally repair
            await engine.ForcePollAsync(CancellationToken.None);               // unchanged remote => anchor match => skip

            Assert.Null(await scope.Store.FindAsync(driveId, a, CancellationToken.None)); // NOT re-added: apply was skipped
        }
        finally
        {
            await _fx.DeleteObjectsAsync(new[] { a, b });
        }
    }

    /// <summary>A throwaway SQLite store + engine factory scoped to one integration test.</summary>
    private sealed class StoreScope : IAsyncDisposable
    {
        private readonly string _dbPath;
        private readonly Guid _driveId;
        private readonly string _bucket;
        private readonly string _prefix;

        public SyncDatabase Db { get; }
        public PlaceholderStore Store { get; }
        public PrefixAnchorStore Anchors { get; }

        private StoreScope(string dbPath, SyncDatabase db, Guid driveId, string bucket, string prefix)
        {
            _dbPath = dbPath;
            Db = db;
            _driveId = driveId;
            _bucket = bucket;
            _prefix = prefix;
            Store = new PlaceholderStore(db);
            Anchors = new PrefixAnchorStore(db);
        }

        public static async Task<StoreScope> CreateAsync(Guid driveId, string bucket, string prefix)
        {
            string dbPath = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString(), "sync.db");
            var db = new SyncDatabase(dbPath);
            await db.OpenAsync(CancellationToken.None);
            var scope = new StoreScope(dbPath, db, driveId, bucket, prefix);

            // The poll's local snapshot + the FK-backed anchor table need a drives row.
            await using SqliteConnection conn = await db.AcquireConnectionAsync(CancellationToken.None);
            await using SqliteCommand cmd = conn.CreateCommand();
            cmd.CommandText =
                "INSERT INTO drives (id, name, bucket, prefix, project_id, iam_user_id, local_root_path, created_at) " +
                "VALUES (@id, 'itest', @bucket, @prefix, 'p', 'u', @root, @createdAt);";
            cmd.Parameters.AddWithValue("@id", driveId.ToString());
            cmd.Parameters.AddWithValue("@bucket", bucket);
            cmd.Parameters.AddWithValue("@prefix", prefix);
            cmd.Parameters.AddWithValue("@root", @"C:\Users\test\DS3");
            cmd.Parameters.AddWithValue("@createdAt", DateTime.UtcNow.ToString("O"));
            await cmd.ExecuteNonQueryAsync(CancellationToken.None);

            return scope;
        }

        public SyncEngine NewEngine(
            IDS3SessionAccess access,
            Action<string, string, ILogger>? deletePlaceholder = null,
            PrefixAnchorStore? anchorStore = null)
        {
            var drive = new DS3DriveModel(
                _driveId, "itest",
                new DS3SyncAnchor(_bucket, Prefix: _prefix, ProjectId: "p", IamUserId: "u"),
                DateTime.UtcNow);
            var status = new DriveStatusBroadcaster(_driveId, TimeSpan.FromMilliseconds(20));
            var uploads = new UploadQueue(access, Store, status);
            return new SyncEngine(
                drive, access, Store, uploads, status,
                config: null, isPaused: null, logger: null,
                localRootPath: Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString()),
                deletePlaceholder: deletePlaceholder,
                anchorStore: anchorStore);
        }

        public async ValueTask DisposeAsync()
        {
            await Db.DisposeAsync();
            SqliteConnection.ClearAllPools();
            try
            {
                string? dir = Path.GetDirectoryName(_dbPath);
                if (dir is not null && Directory.Exists(dir))
                {
                    Directory.Delete(dir, recursive: true);
                }
            }
            catch
            {
                // best effort
            }
        }
    }
}
