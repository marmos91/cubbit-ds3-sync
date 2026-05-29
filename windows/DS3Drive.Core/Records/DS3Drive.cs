namespace DS3Drive.Core.Records;

/// <summary>
/// A configured drive: a named sync target bound to a <see cref="DS3SyncAnchor"/>.
/// Port of Apple's <c>DS3Drive</c>
/// (apple/DS3Lib/Sources/DS3Lib/Models/DS3Drive.swift). The Apple type is an
/// <c>@Observable</c> class persisted to App Group JSON; the Windows record is an
/// immutable value persisted to SQLite (D-11). The drive name appears in the
/// Explorer sidebar (only when more than one drive exists), matching Finder.
/// </summary>
public sealed record DS3Drive(Guid Id, string Name, DS3SyncAnchor SyncAnchor, DateTime CreatedAt);
