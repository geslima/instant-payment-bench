USE [InstantPaymentBench];
GO

SET NOCOUNT ON;
GO

DECLARE @Now DATETIME2(7) = SYSUTCDATETIME();

;WITH Numbers AS (
    SELECT TOP (100000)
        ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
    FROM sys.all_objects a
    CROSS JOIN sys.all_objects b
    CROSS JOIN sys.all_objects c
)
INSERT INTO [dbo].[Account] ([AccountId], [BalanceCents], [UpdatedAt])
SELECT
    n,
    CASE WHEN n <= 10 THEN 1000000000 ELSE 100000 END,
    @Now
FROM Numbers;

SELECT 'Account' AS [Table], COUNT(*) AS [Rows] FROM [dbo].[Account];

GO
