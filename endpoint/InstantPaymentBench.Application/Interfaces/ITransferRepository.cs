using System.Data;
using Dapper;

namespace InstantPaymentBench.Application.Interfaces;

public interface ITransferRepository
{
    Task<(long TransferId, byte Status)> CommitTransferAsync(long fromAccountId, long toAccountId, int amountCents, string idempotencyKey);
}
