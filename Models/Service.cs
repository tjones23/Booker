using System.ComponentModel.DataAnnotations;
using System.ComponentModel.DataAnnotations.Schema;

namespace Booker.Models;

/// <summary>
/// A tutoring offering that families can book (e.g. Literacy Tutoring).
/// </summary>
public class Service
{
    public int Id { get; set; }

    [Required, StringLength(100)]
    public string Name { get; set; } = string.Empty;

    /// <summary>URL-friendly identifier used in routes, e.g. "literacy-tutoring".</summary>
    [Required, StringLength(120)]
    public string Slug { get; set; } = string.Empty;

    [Required, StringLength(200)]
    public string Tagline { get; set; } = string.Empty;

    [Required]
    public string Description { get; set; } = string.Empty;

    /// <summary>Length of a single session in minutes.</summary>
    [Range(15, 240)]
    public int DurationMinutes { get; set; } = 60;

    [Range(0, 2000)]
    [DataType(DataType.Currency)]
    public decimal Price { get; set; }

    /// <summary>
    /// Number of sessions included per month. 0 means a single/drop-in offering
    /// (e.g. the free assessment); greater than 0 means a recurring monthly package.
    /// </summary>
    public int SessionsPerMonth { get; set; }

    /// <summary>Bootstrap icon name shown on the service card.</summary>
    [StringLength(50)]
    public string Icon { get; set; } = "book";

    /// <summary>Controls ordering on the services page.</summary>
    public int SortOrder { get; set; }

    public bool IsActive { get; set; } = true;

    public ICollection<Booking> Bookings { get; set; } = new List<Booking>();

    /// <summary>Price formatted for display, e.g. "Free", "$380/mo", or "$65".</summary>
    [NotMapped]
    public string PriceDisplay =>
        Price == 0 ? "Free"
        : SessionsPerMonth > 0 ? $"{Price:C0}/mo"
        : Price.ToString("C0");

    /// <summary>Session cadence, e.g. "4 × 60-min sessions / month" or "30 min".</summary>
    [NotMapped]
    public string CadenceDisplay =>
        SessionsPerMonth > 0
            ? $"{SessionsPerMonth} × {DurationMinutes}-min sessions / month"
            : $"{DurationMinutes} min";
}
