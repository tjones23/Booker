using System.Net;
using System.Text;
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
    private readonly IEmailSender _email;
    private readonly EmailOptions _emailOptions;
    private readonly ILogger<BookingController> _logger;

    public BookingController(AppDbContext db, IAvailabilityService availability,
        IEmailSender email, EmailOptions emailOptions, ILogger<BookingController> logger)
    {
        _db = db;
        _availability = availability;
        _email = email;
        _emailOptions = emailOptions;
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

        // Hydrate the navigation property so the email builders can show service details.
        booking.Service = service;

        // Notify the business (Ms. Amani); reply goes straight to the family.
        try
        {
            await _email.SendAsync(new EmailMessage
            {
                ToAddress = booking.Email,
                ToName = booking.ParentName,
                Subject = $"New booking — {service.Name} for {booking.StudentName}",
                HtmlBody = BuildTutorEmailBody(booking),
                ReplyToAddress = _emailOptions.BusinessAddress,
                ReplyToName = _emailOptions.BusinessName,
            });
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to send business notification for booking #{Id}.", booking.Id);
        }

        // Confirm to the family; reply goes to Ms. Amani.
        try
        {
            await _email.SendAsync(new EmailMessage
            {
                ToAddress = booking.Email,
                ToName = booking.ParentName,
                Subject = "Your Rooted Readers session is booked",
                HtmlBody = BuildFamilyEmailBody(booking),
                ReplyToAddress = _emailOptions.BusinessAddress,
                ReplyToName = _emailOptions.BusinessName
            });
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to send family confirmation for booking #{Id}.", booking.Id);
        }

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

    private static string BuildTutorEmailBody(Booking b)
    {
        var sb = new StringBuilder();
        sb.Append("""
            <div style="font-family:Arial,Helvetica,sans-serif;max-width:640px;margin:auto;color:#1a1a1a">
              <h2 style="color:#0F6E56;border-bottom:2px solid #9FE1CB;padding-bottom:8px">
                New Booking — Rooted Readers
              </h2>
              <p style="color:#4a6b5f">A family just booked a session.</p>
              <table style="width:100%;border-collapse:collapse;font-size:14px">
            """);

        void Row(string label, string? value)
        {
            if (string.IsNullOrWhiteSpace(value)) return;
            sb.Append(
                "<tr>" +
                $"<td style='padding:6px 10px;background:#F7FAF8;border:1px solid #e3efe9;width:38%;font-weight:bold'>{WebUtility.HtmlEncode(label)}</td>" +
                $"<td style='padding:6px 10px;border:1px solid #e3efe9'>{WebUtility.HtmlEncode(value)}</td>" +
                "</tr>");
        }

        Row("Confirmation #", b.Id.ToString());
        Row("Service", b.Service?.Name);
        Row("When", b.StartTime.ToString("dddd, MMMM d, yyyy 'at' h:mm tt"));
        Row("Status", b.Status.ToString());
        Row("Student", b.StudentName);
        Row("Grade", b.StudentGrade);
        Row("Parent / Guardian", b.ParentName);
        Row("Email", b.Email);
        Row("Phone", b.Phone);
        Row("Notes", b.Notes);
        sb.Append("</table>");

        sb.Append(
            $"<p style='color:#7a9a8a;font-size:12px;margin-top:18px'>Booking #{b.Id} · created {b.CreatedAt:f} UTC · " +
            "Reply to this email to respond directly to the family.</p></div>");

        return sb.ToString();
    }

    private static string BuildFamilyEmailBody(Booking b)
    {
        var firstName = b.ParentName.Split(' ').FirstOrDefault() ?? b.ParentName;
        var confirmed = b.Status == BookingStatus.Confirmed;
        var statusLine = confirmed
            ? "Your session is <strong>confirmed</strong>."
            : "Your request is in — I'll confirm shortly.";
        return $"""
            <div style="font-family:Arial,Helvetica,sans-serif;max-width:560px;margin:auto;color:#1a1a1a;line-height:1.6">
              <h2 style="color:#0F6E56">Thank you, {WebUtility.HtmlEncode(firstName)}!</h2>
              <p>{statusLine}</p>
              <table style="width:100%;border-collapse:collapse;font-size:14px;margin:12px 0">
                <tr><td style="padding:6px 10px;background:#F7FAF8;border:1px solid #e3efe9;width:38%;font-weight:bold">Confirmation #</td>
                    <td style="padding:6px 10px;border:1px solid #e3efe9">{b.Id}</td></tr>
                <tr><td style="padding:6px 10px;background:#F7FAF8;border:1px solid #e3efe9;width:38%;font-weight:bold">Service</td>
                    <td style="padding:6px 10px;border:1px solid #e3efe9">{WebUtility.HtmlEncode(b.Service?.Name ?? "")}</td></tr>
                <tr><td style="padding:6px 10px;background:#F7FAF8;border:1px solid #e3efe9;font-weight:bold">Student</td>
                    <td style="padding:6px 10px;border:1px solid #e3efe9">{WebUtility.HtmlEncode(b.StudentName)}</td></tr>
                <tr><td style="padding:6px 10px;background:#F7FAF8;border:1px solid #e3efe9;font-weight:bold">When</td>
                    <td style="padding:6px 10px;border:1px solid #e3efe9">{WebUtility.HtmlEncode(b.StartTime.ToString("dddd, MMMM d, yyyy 'at' h:mm tt"))}</td></tr>
              </table>
              <p>If anything changes or you have questions, just reply to this email — it comes straight to me.</p>
              <p style="margin-top:24px">Warmly,<br/><strong>Ms. Amani</strong><br/>
                 <span style="color:#5a7a6e;font-style:italic">Rooted Readers — Grounded in Science. Grown with Care.</span></p>
              <hr style="border:none;border-top:1px solid #e3efe9;margin:20px 0" />
              <p style="color:#7a9a8a;font-size:12px">
                This is an automatic confirmation that your booking was received.
              </p>
            </div>
            """;
    }
}
