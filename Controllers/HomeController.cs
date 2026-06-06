using System.Diagnostics;
using Booker.Data;
using Booker.Models;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;

namespace Booker.Controllers;

public class HomeController : Controller
{
    private readonly AppDbContext _db;
    private readonly ILogger<HomeController> _logger;

    public HomeController(AppDbContext db, ILogger<HomeController> logger)
    {
        _db = db;
        _logger = logger;
    }

    public async Task<IActionResult> Index()
    {
        var model = new HomeViewModel
        {
            Services = await _db.Services
                .Where(s => s.IsActive)
                .OrderBy(s => s.SortOrder)
                .ToListAsync(),
            Testimonials = await _db.Testimonials
                .OrderBy(t => t.SortOrder)
                .ToListAsync()
        };
        return View(model);
    }

    public IActionResult About() => View();

    [HttpGet]
    public IActionResult Contact() => View(new ContactViewModel());

    [HttpPost]
    [ValidateAntiForgeryToken]
    public IActionResult Contact(ContactViewModel model)
    {
        if (!ModelState.IsValid)
            return View(model);

        // In production this would dispatch an email / CRM entry. For the demo we log it.
        _logger.LogInformation("Contact message from {Name} <{Email}>: {Message}",
            model.Name, model.Email, model.Message);

        TempData["Flash"] = "Thanks for reaching out! Ms. Amani will get back to you within one business day.";
        return RedirectToAction(nameof(Contact));
    }

    public IActionResult Privacy() => View();

    [ResponseCache(Duration = 0, Location = ResponseCacheLocation.None, NoStore = true)]
    public IActionResult Error() =>
        View(new ErrorViewModel { RequestId = Activity.Current?.Id ?? HttpContext.TraceIdentifier });
}
