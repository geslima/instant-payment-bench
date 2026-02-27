USE [InstantPaymentBench];
GO

SET NOCOUNT ON;

SELECT 'HOT_ACCOUNT|' + CAST(AccountId AS VARCHAR(20))
FROM dbo.Account
WHERE AccountId <= 10
ORDER BY AccountId ASC;
GO
