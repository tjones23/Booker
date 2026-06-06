using System.ComponentModel.DataAnnotations;

namespace Booker.Models;

public class Testimonial
{
    public int Id { get; set; }

    [Required, StringLength(100)]
    public string Author { get; set; } = string.Empty;

    /// <summary>Short descriptor, e.g. "Parent of a 2nd grader".</summary>
    [StringLength(100)]
    public string Relationship { get; set; } = string.Empty;

    [Required, StringLength(600)]
    public string Quote { get; set; } = string.Empty;

    [Range(1, 5)]
    public int Rating { get; set; } = 5;

    public int SortOrder { get; set; }
}
