using Booker.Data;
using Booker.Services;
using Microsoft.AspNetCore.Authentication.Cookies;
using Microsoft.AspNetCore.HttpOverrides;
using Microsoft.Data.Sqlite;
using Microsoft.EntityFrameworkCore;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddControllersWithViews();

var connectionString = builder.Configuration.GetConnectionString("Default")
                       ?? "Data Source=booker.db";

// Ensure the directory for a file-based SQLite database exists. On Azure App
// Service the database is pointed at /home (persistent storage) via the
// ConnectionStrings__Default app setting, e.g. "Data Source=/home/data/booker.db".
var dataSource = new SqliteConnectionStringBuilder(connectionString).DataSource;
if (!string.IsNullOrEmpty(dataSource))
{
    var dbDirectory = Path.GetDirectoryName(Path.GetFullPath(dataSource));
    if (!string.IsNullOrEmpty(dbDirectory))
        Directory.CreateDirectory(dbDirectory);
}

builder.Services.AddDbContext<AppDbContext>(options =>
    options.UseSqlite(connectionString));

// Business-hours configuration drives the availability calculator.
builder.Services.AddSingleton(TimeProvider.System);
builder.Services.AddSingleton(builder.Configuration
    .GetSection("BusinessHours").Get<BusinessHoursOptions>() ?? new BusinessHoursOptions());
builder.Services.AddScoped<IAvailabilityService, AvailabilityService>();

// Email: use SMTP when a host is configured, otherwise log the message (dev-friendly).
var emailOptions = builder.Configuration.GetSection("Email").Get<EmailOptions>() ?? new EmailOptions();
builder.Services.AddSingleton(emailOptions);
if (emailOptions.IsConfigured)
    builder.Services.AddScoped<IEmailSender, SmtpEmailSender>();
else
    builder.Services.AddScoped<IEmailSender, LoggingEmailSender>();

builder.Services.AddAuthentication(CookieAuthenticationDefaults.AuthenticationScheme)
    .AddCookie(options =>
    {
        options.LoginPath = "/Account/Login";
        options.AccessDeniedPath = "/Account/Login";
        options.ExpireTimeSpan = TimeSpan.FromHours(8);
    });
builder.Services.AddAuthorization();

// Honor X-Forwarded-* headers from the HTTPS proxy in front of the app (Tailscale
// Funnel, or Fly.io's proxy) so it knows requests arrived over HTTPS — secure
// cookies, HSTS, and no HTTPS-redirect loop behind the proxy.
builder.Services.Configure<ForwardedHeadersOptions>(options =>
{
    options.ForwardedHeaders = ForwardedHeaders.XForwardedFor | ForwardedHeaders.XForwardedProto;
    options.KnownNetworks.Clear();
    options.KnownProxies.Clear();
});

var app = builder.Build();

app.UseForwardedHeaders();

// Create and seed the SQLite database on startup (demo convenience).
using (var scope = app.Services.CreateScope())
{
    var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
    DbInitializer.Seed(db);
}

if (!app.Environment.IsDevelopment())
{
    app.UseExceptionHandler("/Home/Error");
    app.UseHsts();
}

app.UseHttpsRedirection();
app.UseRouting();

app.UseAuthentication();
app.UseAuthorization();

app.UseStaticFiles();

app.MapControllerRoute(
    name: "services-details",
    pattern: "services/{slug}",
    defaults: new { controller = "Services", action = "Details" });

app.MapControllerRoute(
    name: "default",
    pattern: "{controller=Home}/{action=Index}/{id?}");

app.Run();
