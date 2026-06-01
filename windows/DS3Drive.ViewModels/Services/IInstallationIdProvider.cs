namespace DS3Drive.ViewModels.Services;

/// <summary>
/// Supplies the stable per-install identifier used in the deterministic API-key name
/// (PATTERNS §2.6 — Windows analog of Apple's <c>DefaultSettings.appUUID</c>). The id is
/// generated once via <c>Guid.NewGuid()</c> on first read and persisted to SQLite
/// (<c>singleton_state</c> row), so the same key name round-trips across launches —
/// load-bearing for cross-platform drive interoperability (the Cubbit console shows one
/// stable key per install). STRIDE T-17-09-04: the GUID collision probability between two
/// installs is negligible, so two PCs never clash on a key name.
/// </summary>
public interface IInstallationIdProvider
{
    /// <summary>The stable per-install id (lazily created + persisted on first access).</summary>
    string InstallationId { get; }
}
