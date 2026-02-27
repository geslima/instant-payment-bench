using System.Data;
using System.Data.Common;

namespace InstantPaymentBench.Application.Interfaces;

public interface IDbConnectionFactory
{
    DbConnection CreateConnection();
    Task<DbConnection> CreateConnectionAsync();
}
