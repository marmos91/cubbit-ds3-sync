namespace DS3Drive.Tests;

using System.IO;
using System.Security;
using DS3Drive.Sync.CfApi;
using Xunit;

/// <summary>
/// Security-gate tests for <see cref="PathValidation"/> covering every attack vector in
/// RESEARCH §Security Domain (T-17-10-01 path traversal). Category!=Integration.
/// </summary>
public sealed class PathValidationTests
{
    [Fact]
    public void Test1_ValidKey_ReturnsTrue()
    {
        Assert.True(PathValidation.TryValidateS3Key("docs/report.pdf", out string? reason));
        Assert.Null(reason);
    }

    [Fact]
    public void Test2_ParentTraversalForwardSlash_ReturnsFalse()
    {
        Assert.False(PathValidation.TryValidateS3Key("../escape/secrets.txt", out string? reason));
        Assert.Contains("traversal", reason);
    }

    [Fact]
    public void Test3_ParentTraversalBackslash_ReturnsFalse()
    {
        Assert.False(PathValidation.TryValidateS3Key("..\\escape", out _));
    }

    [Fact]
    public void Test4_LeadingSlash_ReturnsFalse()
    {
        Assert.False(PathValidation.TryValidateS3Key("/absolute/path", out _));
    }

    [Fact]
    public void Test5_DriveLetter_ReturnsFalse()
    {
        Assert.False(PathValidation.TryValidateS3Key("C:\\Windows\\System32", out _));
    }

    [Fact]
    public void Test6_NullByte_ReturnsFalse()
    {
        Assert.False(PathValidation.TryValidateS3Key("docs/\0evil.txt", out _));
    }

    [Fact]
    public void Test7_ReservedDeviceName_ReturnsFalse()
    {
        Assert.False(PathValidation.TryValidateS3Key("CON.txt", out _));
    }

    [Fact]
    public void Test8_ReservedNameInPath_ReturnsFalse()
    {
        Assert.False(PathValidation.TryValidateS3Key("PRN/file.txt", out _));
    }

    [Fact]
    public void Test9_SpacesAllowed_ReturnsTrue()
    {
        Assert.True(PathValidation.TryValidateS3Key("docs/file with spaces.txt", out _));
    }

    [Fact]
    public void Test10_OverLength_ReturnsFalse()
    {
        string longKey = "a/b/c/d/e/longpath/" + new string('x', 250);
        Assert.False(PathValidation.TryValidateS3Key(longKey, out _));
    }

    [Fact]
    public void Test11_ResolveLocalPath_CanonicalizesUnderRoot()
    {
        string root = Path.Combine("C:", "Users", "me", "Cubbit", "Drive1");
        string resolved = PathValidation.ResolveLocalPath(root, "docs/report.pdf");
        string expected = Path.GetFullPath(Path.Combine(root, "docs", "report.pdf"));
        Assert.Equal(expected, resolved);
    }

    [Fact]
    public void Test12_ResolveLocalPath_RejectsEscape()
    {
        string root = Path.Combine("C:", "Users", "me", "Cubbit", "Drive1");
        // TryValidate catches "..", so ResolveLocalPath throws SecurityException.
        Assert.Throws<SecurityException>(() =>
            PathValidation.ResolveLocalPath(root, "../../windows/system32/evil.dll"));
    }
}
