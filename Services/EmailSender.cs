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

    public bool IsConfigured => !string.IsNullOrWhiteSpace(Host);
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

        mime.Body = new BodyBuilder { HtmlBody = message.HtmlBody }.ToMessageBody();

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
            "[Email not configured — would have sent]\n  To: {To} <{Addr}>\n  Subject: {Subject}\n  Reply-To: {Reply}\n{Body}",
            message.ToName, message.ToAddress, message.Subject,
            message.ReplyToAddress ?? "(none)", message.HtmlBody);
        return Task.CompletedTask;
    }
}
