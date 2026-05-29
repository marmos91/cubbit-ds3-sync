using System.Runtime.CompilerServices;

// Expose internal types (DS3ExceptionFactory, DS3Native, Native marshalling
// helpers) to the test assembly so Wave-0 unit tests can exercise them
// directly without a public surface leak. See 17-05-PLAN Task 1/2.
[assembly: InternalsVisibleTo("DS3Drive.Tests")]
