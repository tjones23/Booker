using System.ComponentModel.DataAnnotations;

namespace Booker.Models;

/// <summary>
/// A stored family intake submission. Multi-select fields (concerns, days) are
/// persisted as comma-joined strings.
/// </summary>
public class IntakeSubmission
{
    public int Id { get; set; }

    // Child
    [Required, StringLength(120)]
    public string ChildName { get; set; } = string.Empty;
    public DateOnly? DateOfBirth { get; set; }
    [StringLength(40)] public string? Grade { get; set; }
    [StringLength(160)] public string? School { get; set; }

    // Parent / guardian
    [Required, StringLength(120)]
    public string ParentName { get; set; } = string.Empty;
    [StringLength(40)] public string? Relationship { get; set; }
    [StringLength(40)] public string? Phone { get; set; }
    [Required, EmailAddress, StringLength(200)]
    public string Email { get; set; } = string.Empty;
    [StringLength(40)] public string? ContactMethod { get; set; }

    // About the reader
    [StringLength(400)] public string? Concerns { get; set; }
    [StringLength(400)] public string? OtherConcerns { get; set; }
    [StringLength(40)] public string? Duration { get; set; }
    [StringLength(10)] public string? Evaluated { get; set; }
    [StringLength(300)] public string? EvaluatedDetail { get; set; }
    [StringLength(10)] public string? OtherSupport { get; set; }
    [StringLength(300)] public string? OtherSupportDetail { get; set; }
    [StringLength(300)] public string? Interests { get; set; }

    // Scheduling
    [StringLength(120)] public string? Days { get; set; }
    [StringLength(40)] public string? TimeOfDay { get; set; }
    [StringLength(40)] public string? Format { get; set; }

    [StringLength(2000)] public string? Additional { get; set; }

    public DateTime CreatedAt { get; set; } = DateTime.UtcNow;
    public bool Handled { get; set; }
}

/// <summary>Bound from the public intake form. Lists come from checkbox groups.</summary>
public class IntakeViewModel
{
    [Required(ErrorMessage = "Please enter the child's name.")]
    [Display(Name = "Child's full name")]
    public string ChildName { get; set; } = string.Empty;

    [Display(Name = "Date of birth")]
    [DataType(DataType.Date)]
    public DateOnly? DateOfBirth { get; set; }

    [Display(Name = "Current grade")]
    public string? Grade { get; set; }

    [Display(Name = "Current school")]
    public string? School { get; set; }

    [Required(ErrorMessage = "Please enter your name.")]
    [Display(Name = "Full name")]
    public string ParentName { get; set; } = string.Empty;

    [Display(Name = "Relationship to child")]
    public string? Relationship { get; set; }

    [Phone]
    [Display(Name = "Phone number")]
    public string? Phone { get; set; }

    [Required(ErrorMessage = "Please enter an email address.")]
    [EmailAddress]
    [Display(Name = "Email address")]
    public string Email { get; set; } = string.Empty;

    public string? ContactMethod { get; set; }

    public List<string> Concerns { get; set; } = new();
    public string? OtherConcerns { get; set; }
    public string? Duration { get; set; }
    public string? Evaluated { get; set; }
    public string? EvaluatedDetail { get; set; }
    public string? OtherSupport { get; set; }
    public string? OtherSupportDetail { get; set; }
    public string? Interests { get; set; }

    public List<string> Days { get; set; } = new();
    public string? TimeOfDay { get; set; }
    public string? Format { get; set; }

    public string? Additional { get; set; }

    public IntakeSubmission ToSubmission() => new()
    {
        ChildName = ChildName.Trim(),
        DateOfBirth = DateOfBirth,
        Grade = Grade,
        School = School,
        ParentName = ParentName.Trim(),
        Relationship = Relationship,
        Phone = Phone,
        Email = Email.Trim(),
        ContactMethod = ContactMethod,
        Concerns = Concerns.Count > 0 ? string.Join(", ", Concerns) : null,
        OtherConcerns = OtherConcerns,
        Duration = Duration,
        Evaluated = Evaluated,
        EvaluatedDetail = EvaluatedDetail,
        OtherSupport = OtherSupport,
        OtherSupportDetail = OtherSupportDetail,
        Interests = Interests,
        Days = Days.Count > 0 ? string.Join(", ", Days) : null,
        TimeOfDay = TimeOfDay,
        Format = Format,
        Additional = Additional,
        CreatedAt = DateTime.UtcNow
    };
}
