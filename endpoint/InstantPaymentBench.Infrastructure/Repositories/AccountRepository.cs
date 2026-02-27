using Dapper;
using InstantPaymentBench.Application.Interfaces;

namespace InstantPaymentBench.Infrastructure.Repositories;

public class AccountRepository : IAccountRepository
{
    private readonly IDbConnectionFactory _connectionFactory;

    public AccountRepository(IDbConnectionFactory connectionFactory)
    {
        _connectionFactory = connectionFactory;
    }

    public async Task<long?> GetBalanceAsync(long accountId)
    {
        const string sql = @"SELECT BalanceCents FROM dbo.Account WHERE AccountId = @AccountId;";
        await using var connection = await _connectionFactory.CreateConnectionAsync();
        return await connection.QuerySingleOrDefaultAsync<long?>(sql, new { AccountId = accountId });
    }
}
