using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

namespace DS3Drive.Core;

/// <summary>
/// Windows Credential Manager wrapper for the unpackaged DS3 Drive app's secrets
/// (<c>refreshToken</c>, S3 <c>secretKey</c>). Hand-rolled <c>Advapi32.dll</c>
/// P/Invoke per 17-RESEARCH §"Credential storage" (preferred over the AdysTech
/// community package to avoid an unvetted dependency).
///
/// Per CONTEXT D-12: secrets are stored as <c>CRED_TYPE_GENERIC</c> credentials,
/// DPAPI-sealed by Windows under the user's profile and visible in
/// Control Panel → Credential Manager → Windows Credentials. This is the
/// unpackaged-app analog of Apple's App Group container JSON files
/// (apple/DS3Lib/Sources/DS3Lib/SharedData/SharedData.swift): MSIX
/// <c>PasswordVault</c> is unavailable to a WiX/MSI-installed exe (D-12).
///
/// Target name format: <c>"&lt;targetPrefix&gt; — &lt;accountId&gt; — &lt;credentialKey&gt;"</c>
/// with an em-dash (U+2014) separator, e.g.
/// <c>"Cubbit DS3 Drive — user-abc-123 — refreshToken"</c> (D-12, plan §interfaces).
/// </summary>
public sealed class CredentialStore
{
    private const uint CRED_TYPE_GENERIC = 1;
    private const uint CRED_PERSIST_LOCAL_MACHINE = 2;
    private const int ERROR_NOT_FOUND = 1168;

    private readonly string _targetPrefix;

    /// <summary>
    /// Creates a credential store scoped to a target-name prefix.
    /// </summary>
    /// <param name="targetPrefix">Prefix for every target name (default "Cubbit DS3 Drive").</param>
    public CredentialStore(string targetPrefix = "Cubbit DS3 Drive")
    {
        if (string.IsNullOrWhiteSpace(targetPrefix))
        {
            throw new ArgumentException("Target prefix must be non-empty.", nameof(targetPrefix));
        }

        _targetPrefix = targetPrefix;
    }

    /// <summary>
    /// Em-dash (U+2014) separated target name (D-12 load-bearing — must NOT be a hyphen).
    /// </summary>
    private string TargetName(string accountId, string credentialKey) =>
        $"{_targetPrefix} — {accountId} — {credentialKey}";

    /// <summary>
    /// Persists a secret to Credential Manager (<c>CredWriteW</c>). Overwrites any
    /// existing credential with the same target name (D-12 overwrite semantics).
    /// </summary>
    /// <exception cref="ArgumentException">If <paramref name="secret"/> is null/empty.</exception>
    /// <exception cref="Win32Exception">If <c>CredWriteW</c> fails.</exception>
    public void Save(string accountId, string credentialKey, string secret)
    {
        if (string.IsNullOrEmpty(secret))
        {
            throw new ArgumentException("Secret must be non-empty.", nameof(secret));
        }

        // Threat T-17-05-02: the secret is marshalled straight into the native
        // store; no long-lived managed copy is retained beyond this call.
        byte[] blob = Encoding.Unicode.GetBytes(secret);
        string target = TargetName(accountId, credentialKey);

        IntPtr blobPtr = Marshal.AllocHGlobal(blob.Length);
        try
        {
            Marshal.Copy(blob, 0, blobPtr, blob.Length);

            var cred = new CREDENTIAL
            {
                Flags = 0,
                Type = CRED_TYPE_GENERIC,
                TargetName = target,
                Comment = IntPtr.Zero,
                CredentialBlobSize = (uint)blob.Length,
                CredentialBlob = blobPtr,
                Persist = CRED_PERSIST_LOCAL_MACHINE,
                AttributeCount = 0,
                Attributes = IntPtr.Zero,
                TargetAlias = IntPtr.Zero,
                UserName = accountId,
            };

            if (!Advapi32.CredWriteW(ref cred, 0))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), $"CredWriteW failed for '{target}'.");
            }
        }
        finally
        {
            Marshal.FreeHGlobal(blobPtr);
            Array.Clear(blob, 0, blob.Length);
        }
    }

    /// <summary>
    /// Reads a secret from Credential Manager (<c>CredReadW</c>). Returns null when
    /// the credential does not exist (<c>ERROR_NOT_FOUND</c>).
    /// </summary>
    /// <exception cref="Win32Exception">If <c>CredReadW</c> fails for a reason other than not-found.</exception>
    public string? Load(string accountId, string credentialKey)
    {
        string target = TargetName(accountId, credentialKey);

        if (!Advapi32.CredReadW(target, CRED_TYPE_GENERIC, 0, out IntPtr credPtr))
        {
            int err = Marshal.GetLastWin32Error();
            if (err == ERROR_NOT_FOUND)
            {
                return null;
            }

            throw new Win32Exception(err, $"CredReadW failed for '{target}'.");
        }

        try
        {
            var cred = Marshal.PtrToStructure<CREDENTIAL>(credPtr);
            if (cred.CredentialBlob == IntPtr.Zero || cred.CredentialBlobSize == 0)
            {
                return string.Empty;
            }

            byte[] blob = new byte[cred.CredentialBlobSize];
            Marshal.Copy(cred.CredentialBlob, blob, 0, (int)cred.CredentialBlobSize);
            return Encoding.Unicode.GetString(blob);
        }
        finally
        {
            Advapi32.CredFree(credPtr);
        }
    }

    /// <summary>
    /// Deletes a secret from Credential Manager (<c>CredDeleteW</c>). A no-op when
    /// the credential is already absent.
    /// </summary>
    /// <exception cref="Win32Exception">If <c>CredDeleteW</c> fails for a reason other than not-found.</exception>
    public void Delete(string accountId, string credentialKey)
    {
        string target = TargetName(accountId, credentialKey);

        if (!Advapi32.CredDeleteW(target, CRED_TYPE_GENERIC, 0))
        {
            int err = Marshal.GetLastWin32Error();
            if (err == ERROR_NOT_FOUND)
            {
                return;
            }

            throw new Win32Exception(err, $"CredDeleteW failed for '{target}'.");
        }
    }

    /// <summary>
    /// Enumerates every target name owned by this store's prefix
    /// (<c>CredEnumerateW</c> with a <c>"&lt;prefix&gt; — *"</c> filter). Used by
    /// sign-out to purge all of an account's secrets (T-17-05-05: strict prefix
    /// filter reduces the cross-credential collision surface).
    /// </summary>
    public IEnumerable<string> Enumerate()
    {
        string filter = $"{_targetPrefix} — *";

        if (!Advapi32.CredEnumerateW(filter, 0, out uint count, out IntPtr credArrayPtr))
        {
            int err = Marshal.GetLastWin32Error();
            if (err == ERROR_NOT_FOUND)
            {
                return Array.Empty<string>();
            }

            throw new Win32Exception(err, "CredEnumerateW failed.");
        }

        try
        {
            var names = new List<string>((int)count);
            int ptrSize = IntPtr.Size;
            for (uint i = 0; i < count; i++)
            {
                IntPtr credPtr = Marshal.ReadIntPtr(credArrayPtr, (int)i * ptrSize);
                var cred = Marshal.PtrToStructure<CREDENTIAL>(credPtr);
                if (cred.TargetName is not null)
                {
                    names.Add(cred.TargetName);
                }
            }

            return names;
        }
        finally
        {
            Advapi32.CredFree(credArrayPtr);
        }
    }

    /// <summary>
    /// Hand-rolled <c>Advapi32.dll</c> P/Invoke surface for the Windows Credential
    /// Manager. Signatures cross-verified against Microsoft Learn (wincred.h) and
    /// pinvoke.net (CredRead/CredWrite/CredDelete/CredFree/CredEnumerate).
    /// </summary>
    private static class Advapi32
    {
        [DllImport("Advapi32.dll", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool CredWriteW([In] ref CREDENTIAL credential, [In] uint flags);

        [DllImport("Advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool CredReadW(string targetName, uint type, uint flags, out IntPtr credential);

        [DllImport("Advapi32.dll", EntryPoint = "CredDeleteW", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool CredDeleteW(string targetName, uint type, uint flags);

        [DllImport("Advapi32.dll", EntryPoint = "CredEnumerateW", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool CredEnumerateW(string? filter, uint flags, out uint count, out IntPtr credentials);

        [DllImport("Advapi32.dll", EntryPoint = "CredFree", SetLastError = false)]
        internal static extern void CredFree([In] IntPtr buffer);
    }

    /// <summary>
    /// Native <c>CREDENTIAL</c> struct (wincred.h). Sequential layout with Unicode
    /// string fields; pointer fields we do not use are typed as <see cref="IntPtr"/>.
    /// </summary>
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct CREDENTIAL
    {
        public uint Flags;
        public uint Type;
        [MarshalAs(UnmanagedType.LPWStr)] public string TargetName;
        public IntPtr Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public uint CredentialBlobSize;
        public IntPtr CredentialBlob;
        public uint Persist;
        public uint AttributeCount;
        public IntPtr Attributes;
        public IntPtr TargetAlias;
        [MarshalAs(UnmanagedType.LPWStr)] public string UserName;
    }
}
