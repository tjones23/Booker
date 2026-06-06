using System.ComponentModel.DataAnnotations;

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

    [Range(0, 1000)]
    [DataType(DataType.Currency)]
    public decimal Price { get; set; }

    /// <summary>Bootstrap icon name shown on the service card.</summary>
    [StringLength(50)]
    public string Icon { get; set; } = "book";

    /// <summary>Controls ordering on the services page.</summary>
    public int SortOrder { get; set; }

    public bool IsActive { get; set; } = true;

    public ICollection<Booking> Bookings { get; set; } = new List<Booking>();
}
