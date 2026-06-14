using System.Collections.Concurrent;
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

/// <summary>Operating window for a single day of the week.</summary>
public class DayHours
{
    /// <summary>First slot start time of the day.</summary>
    public TimeOnly Open { get; set; }

    /// <summary>No session may run past this time.</summary>
    public TimeOnly Close { get; set; }
}

public class BusinessHoursOptions
{
    /// <summary>
    /// Operating hours keyed by day of week. A day that is absent is treated as
    /// closed. Defaults mirror the advertised hours of operation.
    /// </summary>
    public Dictionary<DayOfWeek, DayHours> Schedule { get; set; } = new()
    {
        [DayOfWeek.Monday]    = new() { Open = new(16, 30), Close = new(18, 0) },
        [DayOfWeek.Tuesday]   = new() { Open = new(16, 30), Close = new(18, 0) },
        [DayOfWeek.Wednesday] = new() { Open = new(16, 30), Close = new(18, 0) },
        [DayOfWeek.Thursday]  = new() { Open = new(16, 30), Close = new(18, 0) },
        [DayOfWeek.Friday]    = new() { Open = new(16, 30), Close = new(18, 0) },
        [DayOfWeek.Saturday]  = new() { Open = new(9, 0),  Close = new(17, 0) },
        [DayOfWeek.Sunday]    = new() { Open = new(9, 0),  Close = new(17, 0) },
    };

    /// <summary>Minutes between consecutive slot start times.</summary>
    public int SlotIntervalMinutes { get; set; } = 30;

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
        // Closed on days outside the operating schedule and on US federal holidays.
        if (!_hours.Schedule.TryGetValue(date.DayOfWeek, out var dayHours))
            return new List<DateTime>();
        if (IsFederalHoliday(date))
            return new List<DateTime>();

        var dayStart = date.ToDateTime(dayHours.Open);
        var dayEnd = date.ToDateTime(dayHours.Close);
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
            if (_hours.Schedule.ContainsKey(cursor.DayOfWeek) && !IsFederalHoliday(cursor))
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

    private static readonly ConcurrentDictionary<int, HashSet<DateOnly>> _holidayCache = new();

    /// <summary>True when the date is a US federal holiday (including weekday observance).</summary>
    private static bool IsFederalHoliday(DateOnly date) =>
        _holidayCache.GetOrAdd(date.Year, ComputeFederalHolidays).Contains(date);

    private static HashSet<DateOnly> ComputeFederalHolidays(int year)
    {
        var set = new HashSet<DateOnly>();

        // Fixed-date holidays, plus the federal weekday observance:
        // a Saturday holiday is observed Friday, a Sunday holiday is observed Monday.
        void AddFixed(int month, int day)
        {
            var d = new DateOnly(year, month, day);
            set.Add(d);
            if (d.DayOfWeek == DayOfWeek.Saturday) set.Add(d.AddDays(-1));
            else if (d.DayOfWeek == DayOfWeek.Sunday) set.Add(d.AddDays(1));
        }

        DateOnly NthWeekday(int month, DayOfWeek dow, int nth)
        {
            var first = new DateOnly(year, month, 1);
            int offset = ((int)dow - (int)first.DayOfWeek + 7) % 7;
            return first.AddDays(offset + 7 * (nth - 1));
        }

        DateOnly LastWeekday(int month, DayOfWeek dow)
        {
            var last = new DateOnly(year, month, DateTime.DaysInMonth(year, month));
            int offset = ((int)last.DayOfWeek - (int)dow + 7) % 7;
            return last.AddDays(-offset);
        }

        AddFixed(1, 1);                                 // New Year's Day
        set.Add(NthWeekday(1, DayOfWeek.Monday, 3));    // Martin Luther King Jr. Day
        set.Add(NthWeekday(2, DayOfWeek.Monday, 3));    // Washington's Birthday (Presidents' Day)
        set.Add(LastWeekday(5, DayOfWeek.Monday));      // Memorial Day
        AddFixed(6, 19);                                // Juneteenth National Independence Day
        AddFixed(7, 4);                                 // Independence Day
        set.Add(NthWeekday(9, DayOfWeek.Monday, 1));    // Labor Day
        set.Add(NthWeekday(10, DayOfWeek.Monday, 2));   // Columbus Day
        AddFixed(11, 11);                               // Veterans Day
        set.Add(NthWeekday(11, DayOfWeek.Thursday, 4)); // Thanksgiving Day
        AddFixed(12, 25);                               // Christmas Day

        return set;
    }
}
