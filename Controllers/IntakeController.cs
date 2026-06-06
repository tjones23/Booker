using System.Net;
using System.Text;
using Booker.Data;
using Booker.Models;
using Booker.Services;
using Microsoft.AspNetCore.Mvc;

namespace Booker.Controllers;

public class IntakeController : Controller
{
    private readonly AppDbContext _db;
    private readonly IEmailSender _email;
    private readonly EmailOptions _emailOptions;
    private readonly ILogger<IntakeController> _logger;

    public IntakeController(AppDbContext db, IEmailSender email, EmailOptions emailOptions,
        ILogger<IntakeController> logger)
    {
        _db = db;
        _email = email;
        _emailOptions = emailOptions;
        _logger = logger;
    }

    [HttpGet]
    public IActionResult Index() => View(new IntakeViewModel());

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Index(IntakeViewModel model)
    {
        if (!ModelState.IsValid)
            return View(model);

        var submission = model.ToSubmission();

        // Persist first so a lead is never lost even if email delivery fails.
        try
        {
            _db.IntakeSubmissions.Add(submission);
            await _db.SaveChangesAsync();
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to persist intake submission.");
        }

        // Email Ms. Amani the full intake details (reply goes straight to the family).
        try
        {
            await _email.SendAsync(new EmailMessage
            {
                ToAddress = _emailOptions.ToAddress,
                ToName = _emailOptions.ToName,
                Subject = $"New family intake — {submission.ChildName}",
                HtmlBody = BuildTutorEmailBody(submission),
                ReplyToAddress = submission.Email,
                ReplyToName = submission.ParentName
            });
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to send tutor intake email for submission #{Id}.", submission.Id);
        }

        // Send the family an automatic confirmation copy (reply goes to Ms. Amani).
        try
        {
            await _email.SendAsync(new EmailMessage
            {
                ToAddress = submission.Email,
                ToName = submission.ParentName,
                Subject = "We received your Rooted Readers intake form",
                HtmlBody = BuildFamilyEmailBody(submission),
                ReplyToAddress = _emailOptions.ToAddress,
                ReplyToName = _emailOptions.ToName
            });
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to send family confirmation email for submission #{Id}.", submission.Id);
        }

        return RedirectToAction(nameof(ThankYou));
    }

    [HttpGet]
    public IActionResult ThankYou() => View();

    private static string BuildTutorEmailBody(IntakeSubmission s)
    {
        var sb = new StringBuilder();
        sb.Append("""
            <div style="font-family:Arial,Helvetica,sans-serif;max-width:640px;margin:auto;color:#1a1a1a">
              <h2 style="color:#0F6E56;border-bottom:2px solid #9FE1CB;padding-bottom:8px">
                New Family Intake — Rooted Readers
              </h2>
              <p style="color:#4a6b5f">A new family submitted the intake form.</p>
            """);

        void Section(string title) => sb.Append(
            $"<h3 style='color:#0F6E56;margin:20px 0 6px'>{WebUtility.HtmlEncode(title)}</h3>" +
            "<table style='width:100%;border-collapse:collapse;font-size:14px'>");

        void Row(string label, string? value)
        {
            if (string.IsNullOrWhiteSpace(value)) return;
            sb.Append(
                "<tr>" +
                $"<td style='padding:6px 10px;background:#F7FAF8;border:1px solid #e3efe9;width:38%;font-weight:bold'>{WebUtility.HtmlEncode(label)}</td>" +
                $"<td style='padding:6px 10px;border:1px solid #e3efe9'>{WebUtility.HtmlEncode(value)}</td>" +
                "</tr>");
        }

        void End() => sb.Append("</table>");

        Section("Child");
        Row("Name", s.ChildName);
        Row("Date of birth", s.DateOfBirth?.ToString("MMMM d, yyyy"));
        Row("Grade", s.Grade);
        Row("School", s.School);
        End();

        Section("Parent / Guardian");
        Row("Name", s.ParentName);
        Row("Relationship", s.Relationship);
        Row("Phone", s.Phone);
        Row("Email", s.Email);
        Row("Preferred contact", s.ContactMethod);
        End();

        Section("About the reader");
        Row("Main concerns", s.Concerns);
        Row("Other concerns", s.OtherConcerns);
        Row("Duration of challenges", s.Duration);
        Row("Evaluated for learning difference", s.Evaluated);
        Row("Evaluation detail", s.EvaluatedDetail);
        Row("Other reading support", s.OtherSupport);
        Row("Support detail", s.OtherSupportDetail);
        Row("Interests", s.Interests);
        End();

        Section("Scheduling preferences");
        Row("Preferred days", s.Days);
        Row("Time of day", s.TimeOfDay);
        Row("Session format", s.Format);
        End();

        Section("Anything else");
        Row("Notes", s.Additional);
        End();

        sb.Append(
            $"<p style='color:#7a9a8a;font-size:12px;margin-top:18px'>Submitted {s.CreatedAt:f} UTC · " +
            "Reply to this email to respond directly to the family.</p></div>");

        return sb.ToString();
    }

    private static string BuildFamilyEmailBody(IntakeSubmission s)
    {
        var firstName = s.ParentName.Split(' ').FirstOrDefault() ?? s.ParentName;
        return $"""
            <div style="font-family:Arial,Helvetica,sans-serif;max-width:560px;margin:auto;color:#1a1a1a;line-height:1.6">
              <h2 style="color:#0F6E56">Thank you, {WebUtility.HtmlEncode(firstName)}!</h2>
              <p>I've received your intake form for <strong>{WebUtility.HtmlEncode(s.ChildName)}</strong>
                 and I'm so glad you reached out.</p>
              <p>I'll review the details and be in touch soon to schedule your
                 <strong>free 20-minute consultation</strong>. If anything changes in the meantime,
                 just reply to this email — it comes straight to me.</p>
              <p style="margin-top:24px">Warmly,<br/><strong>Ms. Amani</strong><br/>
                 <span style="color:#5a7a6e;font-style:italic">Rooted Readers — Nurturing the reader in every child</span></p>
              <hr style="border:none;border-top:1px solid #e3efe9;margin:20px 0" />
              <p style="color:#7a9a8a;font-size:12px">
                This is an automatic confirmation that your form was received. No action is needed.
              </p>
            </div>
            """;
    }
}
