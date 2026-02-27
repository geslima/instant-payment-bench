using Microsoft.AspNetCore.Mvc;
using InstantPaymentBench.Application.Interfaces;

namespace InstantPaymentBench.Api.Controllers;

[ApiController]
[Route("api/[controller]")]
public class TransfersController : ControllerBase
{
    private readonly ITransferRepository _repository;

    public TransfersController(ITransferRepository repository)
    {
        _repository = repository;
    }

    [HttpPost("commit")]
    public async Task<IActionResult> Commit([FromBody] CommitTransferRequest request)
    {
        if (string.IsNullOrWhiteSpace(request.IdempotencyKey) || request.AmountCents <= 0 || request.FromAccountId == request.ToAccountId)
            return BadRequest();

        try
        {
            var result = await _repository.CommitTransferAsync(
                request.FromAccountId,
                request.ToAccountId,
                request.AmountCents,
                request.IdempotencyKey);

            return Ok(new { transferId = result.TransferId, status = result.Status });
        }
        catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number == 1205)
        {
            return StatusCode(503, new { error = "deadlock" });
        }
    }
}

public class CommitTransferRequest
{
    public long FromAccountId { get; set; }
    public long ToAccountId { get; set; }
    public int AmountCents { get; set; }
    public string IdempotencyKey { get; set; } = string.Empty;
}
