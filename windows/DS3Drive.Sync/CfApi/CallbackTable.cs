namespace DS3Drive.Sync.CfApi;

using System;
using Vanara.PInvoke;
using static Vanara.PInvoke.CldApi;

/// <summary>
/// Builds the <c>CF_CALLBACK_REGISTRATION[]</c> table passed to
/// <c>CfConnectSyncRoot</c> (RESEARCH §Pattern 1 step 3) — the four D-16 callbacks plus
/// the terminator. Maps the Apple <c>NSFileProviderReplicatedExtension</c> method
/// overrides onto cfapi callback slots.
///
/// <para>
/// GC stability (T-17-10-SC): the <see cref="CF_CALLBACK"/> delegate instances are held
/// in instance fields for the lifetime of the owning <see cref="CfApiProvider"/> so the
/// marshaller does not relocate / collect the native function pointers while cfapi holds
/// them. Never inline these delegates into the array initializer — that would let the GC
/// reclaim them after CfConnectSyncRoot returns.
/// </para>
/// </summary>
internal sealed class CallbackTable
{
    // GC-stable delegate fields (kept alive for the provider's lifetime).
    private readonly CF_CALLBACK _onFetchPlaceholders;
    private readonly CF_CALLBACK _onFetchData;
    private readonly CF_CALLBACK _onFileCloseCompletion;
    private readonly CF_CALLBACK _onRename;
    private readonly CF_CALLBACK _onDelete;

    public CallbackTable(
        FetchPlaceholdersHandler fetchPlaceholders,
        FetchDataHandler fetchData,
        NotifyFileCloseHandler fileClose,
        NotifyRenameHandler rename,
        NotifyDeleteHandler delete)
    {
        ArgumentNullException.ThrowIfNull(fetchPlaceholders);
        ArgumentNullException.ThrowIfNull(fetchData);
        ArgumentNullException.ThrowIfNull(fileClose);
        ArgumentNullException.ThrowIfNull(rename);
        ArgumentNullException.ThrowIfNull(delete);

        _onFetchPlaceholders = fetchPlaceholders.OnFetchPlaceholders;
        _onFetchData = fetchData.OnFetchData;
        _onFileCloseCompletion = fileClose.OnFileCloseCompletion;
        _onRename = rename.OnRename;
        _onDelete = delete.OnDelete;
    }

    /// <summary>
    /// Returns the registration array. CF_CALLBACK_TYPE_FETCH_PLACEHOLDERS (on-demand directory
    /// population), CF_CALLBACK_TYPE_FETCH_DATA, CF_CALLBACK_TYPE_NOTIFY_FILE_CLOSE_COMPLETION,
    /// CF_CALLBACK_TYPE_NOTIFY_RENAME, CF_CALLBACK_TYPE_NOTIFY_DELETE, then the END terminator.
    /// </summary>
    public CF_CALLBACK_REGISTRATION[] Build() => new[]
    {
        new CF_CALLBACK_REGISTRATION
        {
            Type = CF_CALLBACK_TYPE.CF_CALLBACK_TYPE_FETCH_PLACEHOLDERS,
            Callback = _onFetchPlaceholders,
        },
        new CF_CALLBACK_REGISTRATION
        {
            Type = CF_CALLBACK_TYPE.CF_CALLBACK_TYPE_FETCH_DATA,
            Callback = _onFetchData,
        },
        new CF_CALLBACK_REGISTRATION
        {
            Type = CF_CALLBACK_TYPE.CF_CALLBACK_TYPE_NOTIFY_FILE_CLOSE_COMPLETION,
            Callback = _onFileCloseCompletion,
        },
        new CF_CALLBACK_REGISTRATION
        {
            Type = CF_CALLBACK_TYPE.CF_CALLBACK_TYPE_NOTIFY_RENAME,
            Callback = _onRename,
        },
        new CF_CALLBACK_REGISTRATION
        {
            Type = CF_CALLBACK_TYPE.CF_CALLBACK_TYPE_NOTIFY_DELETE,
            Callback = _onDelete,
        },
        CF_CALLBACK_REGISTRATION.CF_CALLBACK_REGISTRATION_END,
    };
}
