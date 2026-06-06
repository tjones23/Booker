using Booker.Data;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;

namespace Booker.Controllers;

public class ServicesController : Controller
{
    private readonly AppDbContext _db;

    public ServicesController(AppDbContext db) => _db = db;

    public async Task<IActionResult> Index()
    {
        var services = await _db.Services
            .Where(s => s.IsActive)
            .OrderBy(s => s.SortOrder)
            .ToListAsync();
        return View(services);
    }

    public async Task<IActionResult> Details(string slug)
    {
        var service = await _db.Services.FirstOrDefaultAsync(s => s.Slug == slug && s.IsActive);
        if (service is null) return NotFound();
        return View(service);
    }
}
