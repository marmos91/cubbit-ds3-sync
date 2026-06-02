namespace DS3Drive.Sync.CfApi;

using System;
using System.IO;
using System.Security;
using System.Text.RegularExpressions;

/// <summary>
/// Per RESEARCH §Security Domain T-17-10-01: every S3 key is validated before any local
/// write (FetchData / Rename / Delete handlers call this before touching the file system).
/// <see cref="ResolveLocalPath"/> provides defense-in-depth even if
/// <see cref="TryValidateS3Key"/> missed an exotic edge case — it canonicalizes the path
/// via <see cref="Path.GetFullPath(string)"/> and re-asserts the result stays under the
/// sync root.
///
/// <para>
/// Rejection vectors (mitigating path traversal into e.g. <c>..\..\windows\system32</c>):
/// <c>..</c> segments, leading <c>/</c>, drive letters (<c>X:</c>), null bytes, control
/// chars, Windows reserved device names (CON/PRN/AUX/NUL/COM1-9/LPT1-9), and keys longer
/// than the cfapi path limit (260 chars).
/// </para>
/// </summary>
public static class PathValidation
{
    // Max length cfapi tolerates for a relative key before MAX_PATH composition.
    private const int MaxKeyLength = 260;

    // Drive-letter prefix, e.g. "C:".
    private static readonly Regex DriveLetterRegex =
        new(@"^[A-Za-z]:", RegexOptions.Compiled);

    // Windows reserved device names (case-insensitive), matched per path segment
    // against the base name (the part before any extension).
    private static readonly string[] ReservedNames =
    {
        "CON", "PRN", "AUX", "NUL",
        "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
        "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
    };

    /// <summary>
    /// Validates an S3 key for safe composition into a local path. Returns true for a
    /// safe key; false with a human-readable <paramref name="reason"/> otherwise.
    /// </summary>
    public static bool TryValidateS3Key(string key, out string? reason)
    {
        if (string.IsNullOrEmpty(key))
        {
            reason = "empty key";
            return false;
        }

        if (key.Length > MaxKeyLength)
        {
            reason = $"key exceeds the {MaxKeyLength}-char cfapi path limit";
            return false;
        }

        // Null bytes / control chars (covers '\0', '\r', '\n', etc.).
        foreach (char c in key)
        {
            if (c == '\0' || char.IsControl(c))
            {
                reason = "key contains a null byte or control character";
                return false;
            }
        }

        // Drive letter (C:\Windows\System32).
        if (DriveLetterRegex.IsMatch(key))
        {
            reason = "key contains an absolute drive letter";
            return false;
        }

        // Leading slash / backslash => absolute path.
        if (key[0] == '/' || key[0] == '\\')
        {
            reason = "key is an absolute path (leading separator)";
            return false;
        }

        // Path traversal: any ".." segment (../ or ..\ or trailing "..").
        // Split on both separators and inspect each segment.
        string[] segments = key.Split('/', '\\');
        foreach (string segment in segments)
        {
            if (segment == "..")
            {
                reason = "key contains a path-traversal segment (..\\ or ../)";
                return false;
            }

            if (IsReservedName(segment))
            {
                reason = $"key contains the Windows reserved device name '{segment}'";
                return false;
            }
        }

        reason = null;
        return true;
    }

    /// <summary>
    /// Resolves an S3 key to a canonical local path under <paramref name="syncRootPath"/>.
    /// Throws <see cref="SecurityException"/> if validation fails OR if the canonicalized
    /// path escapes the sync root (defense-in-depth — see Test 12).
    /// </summary>
    public static string ResolveLocalPath(string syncRootPath, string s3Key)
    {
        ArgumentException.ThrowIfNullOrEmpty(syncRootPath);

        if (!TryValidateS3Key(s3Key, out string? reason))
        {
            throw new SecurityException($"rejected S3 key '{s3Key}': {reason}");
        }

        string relative = s3Key.Replace('/', Path.DirectorySeparatorChar);
        string rootFull = Path.GetFullPath(syncRootPath);
        string candidate = Path.GetFullPath(Path.Combine(rootFull, relative));

        // Defense in depth: even if TryValidateS3Key missed an exotic edge case, the
        // canonicalized result must remain strictly inside the sync root.
        string rootWithSep = rootFull.EndsWith(Path.DirectorySeparatorChar)
            ? rootFull
            : rootFull + Path.DirectorySeparatorChar;

        if (!candidate.StartsWith(rootWithSep, StringComparison.OrdinalIgnoreCase))
        {
            throw new SecurityException(
                $"resolved path '{candidate}' escapes the sync root '{rootFull}'");
        }

        return candidate;
    }

    /// <summary>
    /// Converts a cfapi NormalizedPath (sync-root-relative, backslash-separated) to its S3
    /// key (forward-slash). cfapi already strips the sync-root prefix for callback
    /// NormalizedPaths; this only trims a leading separator and flips separators. Shared by
    /// every cfapi handler so this security-adjacent separator handling has one definition
    /// (it feeds straight into <see cref="TryValidateS3Key"/>).
    /// </summary>
    public static string NormalizedPathToS3Key(string normalizedPath) =>
        normalizedPath.TrimStart('\\', '/').Replace('\\', '/');

    /// <summary>
    /// Resolves a cfapi NormalizedPath to the S3 key RELATIVE to the sync root. Under
    /// <c>CF_CONNECT_FLAG_REQUIRE_FULL_FILE_PATH</c> (which we set) the NormalizedPath is the FULL
    /// volume-relative path of the item (e.g. <c>\Users\me\Cubbit\drive\dir\file.txt</c>), so the
    /// sync root's own volume-relative path must be stripped to get the in-drive key
    /// (<c>dir/file.txt</c>). Falls back to the trimmed path if it does not start with the sync root
    /// (i.e. the flag was not honored and the path is already relative).
    /// </summary>
    public static string RelativeKeyFromFullPath(string syncRootPath, string normalizedPath)
    {
        string root = Path.GetFullPath(syncRootPath).Replace('\\', '/');
        int colon = root.IndexOf(':');
        string rootRelative = (colon >= 0 ? root[(colon + 1)..] : root).Trim('/');

        string normalized = normalizedPath.Replace('\\', '/').Trim('/');

        if (rootRelative.Length > 0 && normalized.StartsWith(rootRelative, StringComparison.OrdinalIgnoreCase))
        {
            normalized = normalized[rootRelative.Length..].TrimStart('/');
        }

        return normalized;
    }

    /// <summary>
    /// Resolves a cfapi NormalizedPath to its FULL S3 object key: strips the sync root
    /// (<see cref="RelativeKeyFromFullPath"/>) and re-applies the drive's S3 prefix. The sync root
    /// maps to the drive's prefix, so the in-drive relative key is prefixed back for the S3 layer.
    /// <paramref name="drivePrefix"/> is null/empty for a root drive, otherwise ends in <c>/</c>.
    /// Centralized so every cfapi handler (fetch / close / rename / delete) keys S3 the same way.
    /// </summary>
    public static string S3KeyFromFullPath(string? drivePrefix, string syncRootPath, string normalizedPath) =>
        (drivePrefix ?? string.Empty) + RelativeKeyFromFullPath(syncRootPath, normalizedPath);

    /// <summary>
    /// Returns the parent prefix of an S3 key (including the trailing <c>/</c>), or null for
    /// a top-level key. Populates <c>PlaceholderRecord.ParentKey</c>; centralized here so the
    /// convention stays in lockstep with the <c>idx_placeholders_parent</c> index across the
    /// sync engine, the cfapi provider, and the rename handler.
    /// </summary>
    public static string? ParentOf(string key)
    {
        int slash = key.TrimEnd('/').LastIndexOf('/');
        return slash < 0 ? null : key[..(slash + 1)];
    }

    private static bool IsReservedName(string segment)
    {
        if (string.IsNullOrEmpty(segment))
        {
            return false;
        }

        // Compare the base name (strip extension) case-insensitively.
        int dot = segment.IndexOf('.');
        string baseName = dot >= 0 ? segment[..dot] : segment;

        foreach (string reserved in ReservedNames)
        {
            if (string.Equals(baseName, reserved, StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
        }

        return false;
    }
}
