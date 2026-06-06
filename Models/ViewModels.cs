using System.ComponentModel.DataAnnotations;

namespace Booker.Models;

/// <summary>Step 2 of booking: a chosen service plus the day being viewed.</summary>
public class ScheduleViewModel
{
    public Service Service { get; set; } = null!;
    public DateOnly SelectedDate { get; set; }
    public List<DateTime> AvailableSlots { get; set; } = new();

    /// <summary>The next few days that have at least one open slot, for quick navigation.</summary>
    public List<DateOnly> UpcomingDays { get; set; } = new();
}

/// <summary>Step 3: collect family details for a chosen service + time.</summary>
public class BookingDetailsViewModel
{
    public int ServiceId { get; set; }
    public Service? Service { get; set; }

    [Display(Name = "Session time")]
    public DateTime StartTime { get; set; }

    [Required, StringLength(100)]
    [Display(Name = "Parent / guardian name")]
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

    [StringLength(1000)]
    [Display(Name = "Anything I should know? (optional)")]
    public string? Notes { get; set; }
}

public class ContactViewModel
{
    [Required, StringLength(100)]
    public string Name { get; set; } = string.Empty;

    [Required, EmailAddress, StringLength(200)]
    public string Email { get; set; } = string.Empty;

    [Phone, StringLength(30)]
    public string? Phone { get; set; }

    [Required, StringLength(2000)]
    public string Message { get; set; } = string.Empty;
}

public class HomeViewModel
{
    public List<Service> Services { get; set; } = new();
    public List<Testimonial> Testimonials { get; set; } = new();
}

public class LoginViewModel
{
    [Required]
    public string Username { get; set; } = string.Empty;

    [Required, DataType(DataType.Password)]
    public string Password { get; set; } = string.Empty;

    public string? ReturnUrl { get; set; }
}
