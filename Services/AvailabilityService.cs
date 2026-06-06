using Booker.Data;
using Booker.Models;
using Microsoft.EntityFrameworkCore;

namespace Booker.Services;

/// <summary>
/// Computes open appointment slots from configured business hours, excluding
/// times that already overlap an existing (non-cancelled) booking.
/// </summary>
public interface IAvailabilityService
{
    Task<List<DateTime>> GetOpenSlotsAsync(Service service, DateOnly date);
    Task<List<DateOnly>> GetUpcomingOpenDaysAsync(Service service, int count);
    Task<bool> IsSlotOpenAsync(Service service, DateTime start);
}

public class BusinessHoursOptions
{
    /// <summary>First slot start time of the day.</summary>
    public TimeOnly OpenTime { get; set; } = new(9, 0);

    /// <summary>No session may start at/after this time.</summary>
    public TimeOnly CloseTime { get; set; } = new(17, 0);

    /// <summary>Minutes between consecutive slot start times.</summary>
    public int SlotIntervalMinutes { get; set; } = 30;

    /// <summary>Days of the week the tutor accepts bookings.</summary>
    public DayOfWeek[] WorkingDays { get; set; } =
    {
        DayOfWeek.Monday, DayOfWeek.Tuesday, DayOfWeek.Wednesday,
        DayOfWeek.Thursday, DayOfWeek.Friday, DayOfWeek.Saturday
    };

    /// <summary>How far in advance the calendar may be booked.</summary>
    public int BookingWindowDays { get; set; } = 30;

    /// <summary>Minimum lead time before a session can be booked.</summary>
    public int MinLeadTimeHours { get; set; } = 12;
}

public class AvailabilityService : IAvailabilityService
{
    private readonly AppDbContext _db;
    private readonly BusinessHoursOptions _hours;
    private readonly TimeProvider _clock;

    public AvailabilityService(AppDbContext db, BusinessHoursOptions hours, TimeProvider clock)
    {
        _db = db;
        _hours = hours;
        _clock = clock;
    }

    private DateTime Now => _clock.GetLocalNow().DateTime;

    public async Task<List<DateTime>> GetOpenSlotsAsync(Service service, DateOnly date)
    {
        if (!_hours.WorkingDays.Contains(date.DayOfWeek))
            return new List<DateTime>();

        var dayStart = date.ToDateTime(_hours.OpenTime);
        var dayEnd = date.ToDateTime(_hours.CloseTime);
        var earliest = Now.AddHours(_hours.MinLeadTimeHours);

        // Pull bookings that fall on this day once, then test overlap in memory.
        var nextDay = date.AddDays(1).ToDateTime(TimeOnly.MinValue);
        var booked = await _db.Bookings
            .Include(b => b.Service)
            .Where(b => b.Status != BookingStatus.Cancelled
                        && b.StartTime >= dayStart.Date
                        && b.StartTime < nextDay)
            .ToListAsync();

        var slots = new List<DateTime>();
        for (var t = dayStart; t < dayEnd; t = t.AddMinutes(_hours.SlotIntervalMinutes))
        {
            var slotEnd = t.AddMinutes(service.DurationMinutes);
            if (slotEnd > dayEnd) break;
            if (t < earliest) continue;

            bool overlaps = booked.Any(b =>
                t < b.EndTime && slotEnd > b.StartTime);

            if (!overlaps)
                slots.Add(t);
        }

        return slots;
    }

    public async Task<List<DateOnly>> GetUpcomingOpenDaysAsync(Service service, int count)
    {
        var days = new List<DateOnly>();
        var cursor = DateOnly.FromDateTime(Now);
        var limit = cursor.AddDays(_hours.BookingWindowDays);

        while (days.Count < count && cursor <= limit)
        {
            if (_hours.WorkingDays.Contains(cursor.DayOfWeek))
            {
                var slots = await GetOpenSlotsAsync(service, cursor);
                if (slots.Count > 0)
                    days.Add(cursor);
            }
            cursor = cursor.AddDays(1);
        }

        return days;
    }

    public async Task<bool> IsSlotOpenAsync(Service service, DateTime start)
    {
        var date = DateOnly.FromDateTime(start);
        var open = await GetOpenSlotsAsync(service, date);
        return open.Contains(start);
    }
}
