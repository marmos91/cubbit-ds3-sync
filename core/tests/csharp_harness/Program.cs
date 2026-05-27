// DS3CoreFFI C# Integration Test Harness
//
// Tests the csbindgen-generated P/Invoke bindings against real Cubbit S3.
// Requires DS3_TEST_EMAIL, DS3_TEST_PASSWORD, DS3_TEST_BUCKET env vars.
//
// The generated NativeMethods.g.cs is copied from core/ds3-ffi/out/.
// The ds3_ffi native library (ds3_ffi.dll on Windows) must be in the output path.
//
// Run: cd core/tests/csharp_harness && dotnet run
//
// Per D-08: this harness runs on Windows CI only (not locally on macOS).

using System;
using System.Runtime.InteropServices;
using System.Text;

namespace DS3Drive.Core.Test;

/// <summary>
/// Minimal P/Invoke declarations matching the csbindgen output.
/// These mirror NativeMethods.g.cs but are self-contained for the test harness.
/// </summary>
internal static class NativeMethods
{
    private const string DllName = "ds3_ffi";

    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl)]
    public static extern unsafe int ds3_authenticate(
        byte* email, nuint email_len,
        byte* password, nuint password_len,
        byte* tenant_id, nuint tenant_id_len,
        byte* coordinator_url, nuint coordinator_url_len,
        void** out_handle,
        int* out_error);

    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl)]
    public static extern unsafe void ds3_session_destroy(void* handle);

    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl)]
    public static extern unsafe int ds3_account_info(
        void* handle,
        byte** out_json, nuint* out_json_len,
        int* out_error);

    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl)]
    public static extern unsafe int ds3_get_projects(
        void* handle,
        byte** out_json, nuint* out_json_len,
        int* out_error);

    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl)]
    public static extern unsafe int ds3_refresh_token(
        void* handle,
        int* out_error);

    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl)]
    public static extern unsafe void ds3_free_string(byte* ptr, nuint len);
}

internal static class Program
{
    private static int testCount = 0;
    private static int passCount = 0;

    static unsafe string? RequireEnv(string name)
    {
        var value = Environment.GetEnvironmentVariable(name);
        if (string.IsNullOrEmpty(value))
        {
            Console.WriteLine($"SKIP: {name} not set");
            Environment.Exit(0);
        }
        return value;
    }

    static unsafe string ReadFfiString(byte* ptr, nuint len)
    {
        if (ptr == null || len == 0) return string.Empty;
        return Encoding.UTF8.GetString(ptr, (int)len);
    }

    static void Test(string name, Action body)
    {
        testCount++;
        try
        {
            body();
            passCount++;
            Console.WriteLine($"  PASS: {name}");
        }
        catch (Exception ex)
        {
            Console.WriteLine($"  FAIL: {name} -- {ex.Message}");
            Environment.Exit(1);
        }
    }

    static unsafe void Main(string[] args)
    {
        Console.WriteLine("DS3CoreFFI C# Integration Tests");
        Console.WriteLine("================================");

        var email = RequireEnv("DS3_TEST_EMAIL")!;
        var password = RequireEnv("DS3_TEST_PASSWORD")!;
        var bucket = RequireEnv("DS3_TEST_BUCKET")!;

        void* sessionHandle = null;

        // Test 1: Authenticate
        {
            var emailBytes = Encoding.UTF8.GetBytes(email);
            var passwordBytes = Encoding.UTF8.GetBytes(password);
            int error = 0;

            int result;
            fixed (byte* emailPtr = emailBytes)
            fixed (byte* passwordPtr = passwordBytes)
            {
                result = NativeMethods.ds3_authenticate(
                    emailPtr, (nuint)emailBytes.Length,
                    passwordPtr, (nuint)passwordBytes.Length,
                    null, 0,  // tenant_id
                    null, 0,  // coordinator_url
                    &sessionHandle,
                    &error);
            }

            if (result != 0)
                throw new Exception($"ds3_authenticate returned {result}, error code: {error}");
            if (sessionHandle == null)
                throw new Exception("session handle is null after successful auth");
            Console.WriteLine("  PASS: authenticate");
        }

        // Test 2: Account info
        Test("account_info", () =>
        {
            byte* jsonPtr = null;
            nuint jsonLen = 0;
            int error = 0;

            int result = NativeMethods.ds3_account_info(
                sessionHandle, &jsonPtr, &jsonLen, &error);

            if (result != 0)
                throw new Exception($"ds3_account_info returned {result}, error code: {error}");

            var json = ReadFfiString(jsonPtr, jsonLen);
            if (string.IsNullOrEmpty(json))
                throw new Exception("account info JSON is empty");

            Console.WriteLine($"    Account info: {json.Substring(0, Math.Min(80, json.Length))}...");

            // Free the string
            NativeMethods.ds3_free_string(jsonPtr, jsonLen);
        });

        // Test 3: Refresh token
        Test("refresh_token", () =>
        {
            int error = 0;
            int result = NativeMethods.ds3_refresh_token(sessionHandle, &error);

            if (result != 0)
                throw new Exception($"ds3_refresh_token returned {result}, error code: {error}");
        });

        // Test 4: Get projects
        Test("get_projects", () =>
        {
            byte* jsonPtr = null;
            nuint jsonLen = 0;
            int error = 0;

            int result = NativeMethods.ds3_get_projects(
                sessionHandle, &jsonPtr, &jsonLen, &error);

            if (result != 0)
                throw new Exception($"ds3_get_projects returned {result}, error code: {error}");

            var json = ReadFfiString(jsonPtr, jsonLen);
            if (string.IsNullOrEmpty(json) || !json.StartsWith("["))
                throw new Exception($"expected JSON array, got: {json}");

            Console.WriteLine($"    Projects: {json.Substring(0, Math.Min(80, json.Length))}...");

            NativeMethods.ds3_free_string(jsonPtr, jsonLen);
        });

        // Test 5: Panic safety - null handle
        Test("panic_safety_null_handle", () =>
        {
            byte* jsonPtr = null;
            nuint jsonLen = 0;
            int error = 0;

            // Calling with null handle should return error, not crash
            int result = NativeMethods.ds3_account_info(
                null, &jsonPtr, &jsonLen, &error);

            if (result == 0)
                throw new Exception("expected error for null handle, got success");

            Console.WriteLine($"    Null handle correctly returned error code: {error}");
        });

        // Cleanup
        if (sessionHandle != null)
        {
            NativeMethods.ds3_session_destroy(sessionHandle);
            sessionHandle = null;
        }

        Console.WriteLine();
        Console.WriteLine($"All C# integration tests passed ({passCount}/{testCount})");
    }
}
