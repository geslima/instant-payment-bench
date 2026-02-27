namespace InstantPaymentBench.Application.Interfaces;

public interface IAccountRepository
{
    Task<long?> GetBalanceAsync(long accountId);
}
