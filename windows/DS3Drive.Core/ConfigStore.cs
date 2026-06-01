namespace DS3Drive.Core;

using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;

/// <summary>
/// Reads build-time / install-time defaults from <c>appsettings.json</c>
/// (Microsoft.Extensions.Configuration).
///
/// Per CONTEXT D-13: <c>appsettings.json</c> holds build-time defaults ONLY
/// (default coordinator URL, log level, API-key name prefix). User mutations
/// (custom coordinator URL, drive prefs) live in SQLite (Plan 06 SyncDatabase),
/// NOT here — D-14 forbids JSON files for runtime data. This is the Windows
/// analog of Apple's <c>DefaultSettings.swift</c>
/// (apple/DS3Lib/Sources/DS3Lib/Constants/DefaultSettings.swift).
/// </summary>
public sealed class ConfigStore
{
    private readonly IConfiguration _config;

    /// <summary>
    /// Creates a config store over a DI-injected <see cref="IConfiguration"/>
    /// (typically the host's <c>appsettings.json</c> provider).
    /// </summary>
    public ConfigStore(IConfiguration config)
    {
        _config = config ?? throw new ArgumentNullException(nameof(config));
    }

    /// <summary>Default Cubbit coordinator URL (EU prod) when unset in config.</summary>
    public string DefaultCoordinatorUrl =>
        _config["DS3:DefaultCoordinatorUrl"] ?? "https://api.eu00wi.cubbit.services";

    /// <summary>Default log verbosity; parses <c>DS3:LogLevel</c>, falling back to Information.</summary>
    public LogLevel LogLevel =>
        Enum.TryParse<LogLevel>(_config["DS3:LogLevel"], ignoreCase: true, out var level)
            ? level
            : LogLevel.Information;

    /// <summary>Deterministic API-key name prefix used when reconciling keys (default "ds3drive").</summary>
    public string ApiKeyNamePrefix =>
        _config["DS3:ApiKeyNamePrefix"] ?? "ds3drive";
}
