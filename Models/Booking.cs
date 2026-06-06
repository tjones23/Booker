using System.ComponentModel.DataAnnotations;

namespace Booker.Models;

public enum BookingStatus
{
    Pending = 0,
    Confirmed = 1,
    Completed = 2,
    Cancelled = 3
}

/// <summary>
/// A single scheduled session requested by a family.
/// </summary>
public class Booking
{
    public int Id { get; set; }

    public int ServiceId { get; set; }
    public Service? Service { get; set; }

    [Required, StringLength(100)]
    [Display(Name = "Parent / Guardian name")]
    public string ParentName { get; set; } = string.Empty;

    [Required, StringLength(100)]
    [Display(Name = "Student name")]
    public string StudentName { get; set; } = string.Empty;

    [Display(Name = "Student grade level")]
    [StringLength(40)]
    public string? StudentGrade { get; set; }

    [Required, EmailAddress, StringLength(200)]
    public string Email { get; set; } = string.Empty;

    [Required, Phone, StringLength(30)]
    public string Phone { get; set; } = string.Empty;

    /// <summary>Start of the session (local time of the tutor).</summary>
    [Display(Name = "Session time")]
    public DateTime StartTime { get; set; }

    [StringLength(1000)]
    [Display(Name = "Anything I should know? (optional)")]
    public string? Notes { get; set; }

    public BookingStatus Status { get; set; } = BookingStatus.Pending;

    public DateTime CreatedAt { get; set; } = DateTime.UtcNow;

    public DateTime EndTime => Service is null
        ? StartTime
        : StartTime.AddMinutes(Service.DurationMinutes);
}
