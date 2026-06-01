namespace DS3Drive.Tests;
using DS3Drive.Core.Exceptions;
using Xunit;

/// <summary>
/// Verifies the DS3Error code → typed exception mapping is byte-identical to
/// Apple's <c>DS3AuthenticationError.translate(_:)</c>
/// (apple/DS3Lib/Sources/DS3Lib/DS3Authentication.swift lines 56-88). The
/// 1007 → TwoFactorRequired arm is load-bearing per Phase 16 D-15.
/// </summary>
public sealed class DS3ExceptionFactoryTests
{
    // Test 1 (load-bearing, D-15): 1007 → DS3AuthenticationException(TwoFactorRequired).
    [Fact]
    public void From_1007_ReturnsTwoFactorRequired()
    {
        var ex = Assert.IsType<DS3AuthenticationException>(
            DS3ExceptionFactory.From(1007, "needs 2fa"));
        Assert.Equal(AuthFailureReason.TwoFactorRequired, ex.Reason);
        Assert.Equal(1007, ex.ErrorCode);
    }

    // Tests 2-9: each 1001..1008 maps to the matching AuthFailureReason.
    [Theory]
    [InlineData(1001, AuthFailureReason.InvalidUrl)]
    [InlineData(1002, AuthFailureReason.ServerError)]
    [InlineData(1003, AuthFailureReason.JsonConversion)]
    [InlineData(1004, AuthFailureReason.Encoding)]
    [InlineData(1005, AuthFailureReason.LoggedOut)]
    [InlineData(1006, AuthFailureReason.TokenExpired)]
    [InlineData(1007, AuthFailureReason.TwoFactorRequired)]
    [InlineData(1008, AuthFailureReason.Cookies)]
    public void From_AuthCode_ReturnsMatchingReason(int code, AuthFailureReason expected)
    {
        var ex = Assert.IsType<DS3AuthenticationException>(DS3ExceptionFactory.From(code));
        Assert.Equal(expected, ex.Reason);
        Assert.Equal(code, ex.ErrorCode);
    }

    // Test 10: 2042 → DS3S3Exception with ErrorCode 2042, message preserved.
    [Fact]
    public void From_2042_ReturnsS3ExceptionWithCodeAndMessage()
    {
        var ex = Assert.IsType<DS3S3Exception>(
            DS3ExceptionFactory.From(2042, "S3 bucket missing"));
        Assert.Equal(2042, ex.ErrorCode);
        Assert.Contains("S3 bucket missing", ex.Message);
    }

    // Test 11: 3050 → DS3TransportException.
    [Fact]
    public void From_3050_ReturnsTransportException()
    {
        var ex = Assert.IsType<DS3TransportException>(
            DS3ExceptionFactory.From(3050, "Transport error"));
        Assert.Equal(3050, ex.ErrorCode);
    }

    // Test 12: 9999 → DS3PanicException.
    [Fact]
    public void From_9999_ReturnsPanicException()
    {
        var ex = Assert.IsType<DS3PanicException>(DS3ExceptionFactory.From(9999));
        Assert.Contains("9999", ex.Message);
    }

    // Test 13: unknown code → DS3AuthenticationException(ServerError).
    [Fact]
    public void From_UnknownCode_ReturnsServerError()
    {
        var ex = Assert.IsType<DS3AuthenticationException>(DS3ExceptionFactory.From(99999));
        Assert.Equal(AuthFailureReason.ServerError, ex.Reason);
    }

    // Every exception's Message includes the numeric code, e.g. "[1007] ...".
    [Theory]
    [InlineData(1007)]
    [InlineData(2042)]
    [InlineData(3050)]
    [InlineData(9999)]
    public void From_AnyCode_MessageIncludesNumericCode(int code)
    {
        var ex = DS3ExceptionFactory.From(code, "detail");
        Assert.Contains($"[{code}]", ex.Message);
    }
}
