namespace DS3Drive.ViewModels.Services;

using System.Threading;
using System.Threading.Tasks;
using DS3Drive.Core.Records;
using DS3Drive.Sync.Storage;
using Microsoft.Data.Sqlite;

/// <summary>
/// Thin SQLite CRUD wrapper over the <c>drives</c> table (migration 001). Single
/// concern — owns the SQL so <see cref="DriveManagementService"/> stays focused on
/// lifecycle + events. All statements are parameterized (STRIDE T-17-09-01: no string
/// interpolation into SQL). The <c>local_root_path</c> column is NOT NULL in the schema;
/// the cfapi local root is finalized by Plan 10, so a deterministic default
/// (<c>%USERPROFILE%\Cubbit\&lt;drive name&gt;</c>) is written now and refined later.
/// </summary>
public sealed class DrivesRepository
{
    private readonly SyncDatabase _db;

    public DrivesRepository(SyncDatabase db) => _db = db;

    /// <summary>Loads every configured drive, ordered by creation time (oldest first).</summary>
    public async Task<IReadOnlyList<DS3Drive>> LoadAllAsync(CancellationToken ct)
    {
        var drives = new List<DS3Drive>();
        await using SqliteConnection conn = await _db.AcquireConnectionAsync(ct).ConfigureAwait(false);
        await using var cmd = conn.CreateCommand();
        cmd.CommandText =
            "SELECT id, name, bucket, prefix, project_id, iam_user_id, created_at " +
            "FROM drives ORDER BY created_at ASC;";
        await using var reader = await cmd.ExecuteReaderAsync(ct).ConfigureAwait(false);
        while (await reader.ReadAsync(ct).ConfigureAwait(false))
        {
            var id = Guid.Parse(reader.GetString(0));
            string name = reader.GetString(1);
            string bucket = reader.GetString(2);
            string? prefix = reader.IsDBNull(3) ? null : reader.GetString(3);
            string projectId = reader.GetString(4);
            string iamUserId = reader.GetString(5);
            DateTime createdAt = DateTime.Parse(reader.GetString(6),
                null, System.Globalization.DateTimeStyles.RoundtripKind);

            drives.Add(new DS3Drive(id, name,
                new DS3SyncAnchor(bucket, prefix, projectId, iamUserId), createdAt));
        }

        return drives;
    }

    /// <summary>Inserts or updates a drive (idempotent by id).</summary>
    public async Task UpsertAsync(DS3Drive drive, CancellationToken ct)
    {
        await using SqliteConnection conn = await _db.AcquireConnectionAsync(ct).ConfigureAwait(false);
        await using var cmd = conn.CreateCommand();
        cmd.CommandText =
            "INSERT INTO drives (id, name, bucket, prefix, project_id, iam_user_id, local_root_path, created_at) " +
            "VALUES (@id, @name, @bucket, @prefix, @project, @user, @root, @created) " +
            "ON CONFLICT(id) DO UPDATE SET name = @name, bucket = @bucket, prefix = @prefix, " +
            "project_id = @project, iam_user_id = @user;";
        cmd.Parameters.AddWithValue("@id", drive.Id.ToString());
        cmd.Parameters.AddWithValue("@name", drive.Name);
        cmd.Parameters.AddWithValue("@bucket", drive.SyncAnchor.Bucket);
        cmd.Parameters.AddWithValue("@prefix", (object?)drive.SyncAnchor.Prefix ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@project", drive.SyncAnchor.ProjectId);
        cmd.Parameters.AddWithValue("@user", drive.SyncAnchor.IamUserId);
        cmd.Parameters.AddWithValue("@root", DefaultLocalRootPath(drive));
        cmd.Parameters.AddWithValue("@created", drive.CreatedAt.ToString("O"));
        await cmd.ExecuteNonQueryAsync(ct).ConfigureAwait(false);
    }

    /// <summary>Deletes a drive by id (its placeholders cascade via the FK).</summary>
    public async Task DeleteAsync(Guid driveId, CancellationToken ct)
    {
        await using SqliteConnection conn = await _db.AcquireConnectionAsync(ct).ConfigureAwait(false);
        await using var cmd = conn.CreateCommand();
        cmd.CommandText = "DELETE FROM drives WHERE id = @id;";
        cmd.Parameters.AddWithValue("@id", driveId.ToString());
        await cmd.ExecuteNonQueryAsync(ct).ConfigureAwait(false);
    }

    private static string DefaultLocalRootPath(DS3Drive drive) =>
        System.IO.Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            "Cubbit", drive.Name);
}
