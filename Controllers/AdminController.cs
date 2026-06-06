using Booker.Data;
using Booker.Models;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;

namespace Booker.Controllers;

[Authorize(Roles = "Admin")]
public class AdminController : Controller
{
    private readonly AppDbContext _db;

    public AdminController(AppDbContext db) => _db = db;

    // Dashboard: upcoming bookings + at-a-glance counts.
    public async Task<IActionResult> Index(BookingStatus? status)
    {
        var query = _db.Bookings.Include(b => b.Service).AsQueryable();
        if (status is not null)
            query = query.Where(b => b.Status == status);

        var bookings = await query
            .OrderBy(b => b.StartTime)
            .ToListAsync();

        ViewBag.StatusFilter = status;
        ViewBag.PendingCount = await _db.Bookings.CountAsync(b => b.Status == BookingStatus.Pending);
        ViewBag.UpcomingCount = await _db.Bookings.CountAsync(b =>
            b.StartTime >= DateTime.Now && b.Status != BookingStatus.Cancelled);

        return View(bookings);
    }

    // Family intake submissions received via the public form.
    public async Task<IActionResult> Intakes()
    {
        var intakes = await _db.IntakeSubmissions
            .OrderByDescending(i => i.CreatedAt)
            .ToListAsync();
        return View(intakes);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> UpdateStatus(int id, BookingStatus status)
    {
        var booking = await _db.Bookings.FindAsync(id);
        if (booking is null) return NotFound();

        booking.Status = status;
        await _db.SaveChangesAsync();
        TempData["Flash"] = $"Booking #{id} marked {status}.";
        return RedirectToAction(nameof(Index));
    }
}
