using System.Data;
using System.Data.Common;
using Microsoft.Data.SqlClient;
using InstantPaymentBench.Application.Interfaces;

namespace InstantPaymentBench.Infrastructure.Data;

public class SqlConnectionFactory : IDbConnectionFactory
{
    private readonly string _connectionString;

    public SqlConnectionFactory(string connectionString)
    {
        _connectionString = connectionString;
    }

    public DbConnection CreateConnection()
    {
        return new SqlConnection(_connectionString);
    }

    public Task<DbConnection> CreateConnectionAsync()
    {
        var connection = new SqlConnection(_connectionString);
        return Task.FromResult<DbConnection>(connection);
    }
}
