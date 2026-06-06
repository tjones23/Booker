using Booker.Data;
using Booker.Models;
using Booker.Services;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;

namespace Booker.Controllers;

public class BookingController : Controller
{
    private readonly AppDbContext _db;
    private readonly IAvailabilityService _availability;
    private readonly ILogger<BookingController> _logger;

    public BookingController(AppDbContext db, IAvailabilityService availability,
        ILogger<BookingController> logger)
    {
        _db = db;
        _availability = availability;
        _logger = logger;
    }

    // Step 1 — choose a service.
    public async Task<IActionResult> Index()
    {
        var services = await _db.Services
            .Where(s => s.IsActive)
            .OrderBy(s => s.SortOrder)
            .ToListAsync();
        return View(services);
    }

    // Step 2 — pick a day and an open time slot.
    [HttpGet]
    public async Task<IActionResult> Schedule(int serviceId, DateOnly? date)
    {
        var service = await _db.Services.FindAsync(serviceId);
        if (service is null || !service.IsActive) return NotFound();

        var upcoming = await _availability.GetUpcomingOpenDaysAsync(service, 14);
        var selected = date ?? upcoming.FirstOrDefault(DateOnly.FromDateTime(DateTime.Today));

        var model = new ScheduleViewModel
        {
            Service = service,
            SelectedDate = selected,
            UpcomingDays = upcoming,
            AvailableSlots = await _availability.GetOpenSlotsAsync(service, selected)
        };
        return View(model);
    }

    // Step 3 — collect family details for the chosen slot.
    [HttpGet]
    public async Task<IActionResult> Details(int serviceId, DateTime start)
    {
        var service = await _db.Services.FindAsync(serviceId);
        if (service is null || !service.IsActive) return NotFound();

        if (!await _availability.IsSlotOpenAsync(service, start))
        {
            TempData["Flash"] = "Sorry, that time was just taken. Please choose another slot.";
            return RedirectToAction(nameof(Schedule),
                new { serviceId, date = DateOnly.FromDateTime(start) });
        }

        var model = new BookingDetailsViewModel
        {
            ServiceId = serviceId,
            Service = service,
            StartTime = start
        };
        return View(model);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Details(BookingDetailsViewModel model)
    {
        var service = await _db.Services.FindAsync(model.ServiceId);
        if (service is null || !service.IsActive) return NotFound();
        model.Service = service;

        if (!ModelState.IsValid)
            return View(model);

        // Re-check availability at submit time to avoid double-booking.
        if (!await _availability.IsSlotOpenAsync(service, model.StartTime))
        {
            TempData["Flash"] = "Sorry, that time was just taken. Please choose another slot.";
            return RedirectToAction(nameof(Schedule),
                new { serviceId = model.ServiceId, date = DateOnly.FromDateTime(model.StartTime) });
        }

        var booking = new Booking
        {
            ServiceId = model.ServiceId,
            ParentName = model.ParentName,
            StudentName = model.StudentName,
            StudentGrade = model.StudentGrade,
            Email = model.Email,
            Phone = model.Phone,
            StartTime = model.StartTime,
            Notes = model.Notes,
            Status = service.Price == 0 ? BookingStatus.Confirmed : BookingStatus.Pending,
            CreatedAt = DateTime.UtcNow
        };

        _db.Bookings.Add(booking);
        await _db.SaveChangesAsync();

        _logger.LogInformation("New booking #{Id} for {Service} at {Time}",
            booking.Id, service.Name, booking.StartTime);
        // Production: send confirmation email to family + notification to tutor here.

        return RedirectToAction(nameof(Confirmation), new { id = booking.Id });
    }

    public async Task<IActionResult> Confirmation(int id)
    {
        var booking = await _db.Bookings
            .Include(b => b.Service)
            .FirstOrDefaultAsync(b => b.Id == id);
        if (booking is null) return NotFound();
        return View(booking);
    }
}
