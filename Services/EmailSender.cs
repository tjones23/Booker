using MailKit.Net.Smtp;
using MailKit.Security;
using MimeKit;

namespace Booker.Services;

public class EmailOptions
{
    public string? Host { get; set; }
    public int Port { get; set; } = 587;
    public bool UseStartTls { get; set; } = true;
    public string? Username { get; set; }
    public string? Password { get; set; }

    public string FromAddress { get; set; } = "noreply@rootedreaders.com";
    public string FromName { get; set; } = "Rooted Readers Website";

    /// <summary>
    /// The business mailbox (Ms. Amani). Receives intake/booking notifications and is
    /// used as the Reply-To on confirmations sent to families.
    /// </summary>
    public string BusinessAddress { get; set; } = "hello@rootedreaders.com";
    public string BusinessName { get; set; } = "Ms. Amani";

    /// <summary>Public phone number shown in email signatures.</summary>
    public string BusinessPhone { get; set; } = "(970) 590-1067";

    public bool IsConfigured => !string.IsNullOrWhiteSpace(Host);
}

/// <summary>An image embedded inline in the message and referenced from the HTML via <c>cid:ContentId</c>.</summary>
public class InlineImage
{
    public required string ContentId { get; init; }
    public required string FilePath { get; init; }
}

public class EmailMessage
{
    public required string ToAddress { get; init; }
    public required string ToName { get; init; }
    public required string Subject { get; init; }
    public required string HtmlBody { get; init; }
    /// <summary>Optional Reply-To (e.g. so the tutor can reply straight to the family).</summary>
    public string? ReplyToAddress { get; init; }
    public string? ReplyToName { get; init; }
    /// <summary>Images embedded inline and referenced from the HTML body via <c>cid:ContentId</c>.</summary>
    public IReadOnlyList<InlineImage> InlineImages { get; init; } = Array.Empty<InlineImage>();
}

public interface IEmailSender
{
    Task SendAsync(EmailMessage message, CancellationToken ct = default);
}

/// <summary>Sends mail via SMTP using MailKit. Used when an SMTP host is configured.</summary>
public class SmtpEmailSender : IEmailSender
{
    private readonly EmailOptions _opt;
    private readonly ILogger<SmtpEmailSender> _logger;

    public SmtpEmailSender(EmailOptions opt, ILogger<SmtpEmailSender> logger)
    {
        _opt = opt;
        _logger = logger;
    }

    public async Task SendAsync(EmailMessage message, CancellationToken ct = default)
    {
        var mime = new MimeMessage();
        mime.From.Add(new MailboxAddress(_opt.FromName, _opt.FromAddress));
        mime.To.Add(new MailboxAddress(message.ToName, message.ToAddress));
        mime.Subject = message.Subject;

        if (!string.IsNullOrWhiteSpace(message.ReplyToAddress))
            mime.ReplyTo.Add(new MailboxAddress(message.ReplyToName ?? "", message.ReplyToAddress));

        var bodyBuilder = new BodyBuilder { HtmlBody = message.HtmlBody };
        foreach (var image in message.InlineImages)
        {
            if (!File.Exists(image.FilePath))
            {
                _logger.LogWarning("Inline image not found, skipping: {Path}", image.FilePath);
                continue;
            }
            var resource = bodyBuilder.LinkedResources.Add(image.FilePath);
            resource.ContentId = image.ContentId;
        }
        mime.Body = bodyBuilder.ToMessageBody();

        using var client = new SmtpClient();
        var socketOption = _opt.UseStartTls
            ? SecureSocketOptions.StartTls
            : SecureSocketOptions.Auto;

        await client.ConnectAsync(_opt.Host!, _opt.Port, socketOption, ct);
        if (!string.IsNullOrWhiteSpace(_opt.Username))
            await client.AuthenticateAsync(_opt.Username, _opt.Password ?? string.Empty, ct);
        await client.SendAsync(mime, ct);
        await client.DisconnectAsync(true, ct);

        _logger.LogInformation("Email sent to {To}", message.ToAddress);
    }
}

/// <summary>
/// Fallback used when no SMTP host is configured (e.g. local dev). Logs the email
/// instead of sending it, so the app works out of the box without credentials.
/// </summary>
public class LoggingEmailSender : IEmailSender
{
    private readonly ILogger<LoggingEmailSender> _logger;

    public LoggingEmailSender(ILogger<LoggingEmailSender> logger) => _logger = logger;

    public Task SendAsync(EmailMessage message, CancellationToken ct = default)
    {
        _logger.LogInformation(
            "[Email not configured — would have sent]\n  To: {To} <{Addr}>\n  Subject: {Subject}\n  Reply-To: {Reply}\n  Inline images: {Images}\n{Body}",
            message.ToName, message.ToAddress, message.Subject,
            message.ReplyToAddress ?? "(none)",
            message.InlineImages.Count == 0 ? "(none)" : string.Join(", ", message.InlineImages.Select(i => i.ContentId)),
            message.HtmlBody);
        return Task.CompletedTask;
    }
}
