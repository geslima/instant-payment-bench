using InstantPaymentBench.Application.Interfaces;
using InstantPaymentBench.Infrastructure.Data;
using InstantPaymentBench.Infrastructure.Repositories;
using Microsoft.AspNetCore.Server.Kestrel.Core;

var builder = WebApplication.CreateBuilder(args);

var connectionString = builder.Configuration.GetConnectionString("DefaultConnection")
    ?? throw new InvalidOperationException("Connection string 'DefaultConnection' not found.");

builder.WebHost.ConfigureKestrel(options =>
{
    options.Limits.MaxConcurrentConnections = 20000;
    options.Limits.MaxConcurrentUpgradedConnections = 20000;
    options.Limits.MaxRequestBodySize = 1_048_576; // 1MB
    options.Limits.MinRequestBodyDataRate = null;
    options.Limits.MinResponseDataRate = null;
});

ThreadPool.SetMinThreads(1000, 1000);

builder.Services.AddSingleton<IDbConnectionFactory>(
    new SqlConnectionFactory(connectionString));

var bgConnectionString = connectionString
    + ";Application Name=BackgroundWorker;Max Pool Size=10;Min Pool Size=2;Connect Timeout=30";
builder.Services.AddKeyedSingleton<IDbConnectionFactory>("background",
    new SqlConnectionFactory(bgConnectionString));

builder.Services.AddScoped<ITransferRepository, TransferRepository>();
builder.Services.AddScoped<IAccountRepository, AccountRepository>();

builder.Services.AddControllers();

var app = builder.Build();

app.MapControllers();

app.Run();
