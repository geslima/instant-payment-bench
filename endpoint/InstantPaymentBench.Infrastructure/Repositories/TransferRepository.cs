using Dapper;
using InstantPaymentBench.Application.Interfaces;

namespace InstantPaymentBench.Infrastructure.Repositories;

public class TransferRepository : ITransferRepository
{
    private readonly IDbConnectionFactory _connectionFactory;

    public TransferRepository(IDbConnectionFactory connectionFactory)
    {
        _connectionFactory = connectionFactory;
    }

    public async Task<(long TransferId, byte Status)> CommitTransferAsync(long fromAccountId, long toAccountId, int amountCents, string idempotencyKey)
    {
        const string sql = @"
SET NOCOUNT ON;

BEGIN TRY
    BEGIN TRAN;

    DECLARE @ExistingTransferId bigint, @ExistingStatus tinyint;
    SELECT @ExistingTransferId = TransferId, @ExistingStatus = Status
    FROM dbo.Transfer WITH (UPDLOCK, HOLDLOCK)
    WHERE IdempotencyKey = @IdempotencyKey;

    IF @ExistingTransferId IS NOT NULL
    BEGIN
        COMMIT TRAN;
        SELECT @ExistingTransferId AS TransferId, @ExistingStatus AS Status;
        RETURN;
    END

    DECLARE @Now datetime2 = SYSUTCDATETIME();
    DECLARE @NewTransferId bigint;
    
    INSERT INTO dbo.Transfer (FromAccountId, ToAccountId, AmountCents, Status, IdempotencyKey, CreatedAt)
    VALUES (@FromAccountId, @ToAccountId, @AmountCents, 1, @IdempotencyKey, @Now);
    SET @NewTransferId = SCOPE_IDENTITY();

    DECLARE @LowerAccountId bigint = CASE WHEN @FromAccountId < @ToAccountId THEN @FromAccountId ELSE @ToAccountId END;
    DECLARE @HigherAccountId bigint = CASE WHEN @FromAccountId > @ToAccountId THEN @FromAccountId ELSE @ToAccountId END;

    DECLARE @Dummy int;
    SELECT @Dummy = 1 FROM dbo.Account WITH (UPDLOCK, HOLDLOCK) WHERE AccountId = @LowerAccountId;
    SELECT @Dummy = 1 FROM dbo.Account WITH (UPDLOCK, HOLDLOCK) WHERE AccountId = @HigherAccountId;

    UPDATE dbo.Account
    SET BalanceCents = BalanceCents - @AmountCents, UpdatedAt = @Now
    WHERE AccountId = @FromAccountId AND BalanceCents >= @AmountCents;

    IF @@ROWCOUNT = 0
    BEGIN
        UPDATE dbo.Transfer SET Status = 3 WHERE TransferId = @NewTransferId;
        COMMIT TRAN;
        SELECT @NewTransferId AS TransferId, 3 AS Status;
        RETURN;
    END

    UPDATE dbo.Account
    SET BalanceCents = BalanceCents + @AmountCents, UpdatedAt = @Now
    WHERE AccountId = @ToAccountId;

    INSERT INTO dbo.LedgerEntry (TransferId, AccountId, Direction, AmountCents, CreatedAt)
    VALUES 
        (@NewTransferId, @FromAccountId, 'D', @AmountCents, @Now),
        (@NewTransferId, @ToAccountId, 'C', @AmountCents, @Now);

    UPDATE dbo.Transfer SET Status = 2 WHERE TransferId = @NewTransferId;
    COMMIT TRAN;
    SELECT @NewTransferId AS TransferId, 2 AS Status;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0
        ROLLBACK TRAN;
    THROW;
END CATCH
";
        await using var connection = await _connectionFactory.CreateConnectionAsync();
        return await connection.QuerySingleAsync<(long, byte)>(sql, new { FromAccountId = fromAccountId, ToAccountId = toAccountId, AmountCents = amountCents, IdempotencyKey = idempotencyKey });
    }
}
