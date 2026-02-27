using Microsoft.AspNetCore.Mvc;
using InstantPaymentBench.Application.Interfaces;

namespace InstantPaymentBench.Api.Controllers;

[ApiController]
[Route("api/[controller]")]
public class AccountsController : ControllerBase
{
    private readonly IAccountRepository _repository;

    public AccountsController(IAccountRepository repository)
    {
        _repository = repository;
    }

    [HttpGet("{id}/balance")]
    public async Task<IActionResult> GetBalance(long id)
    {
        var balance = await _repository.GetBalanceAsync(id);
        if (balance == null) return NotFound();
        return Ok(new { accountId = id, balanceCents = balance });
    }
}
