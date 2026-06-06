# Rooted Readers — Online Booking Site

An ASP.NET Core 9 MVC web application for Rooted Readers, the reading-tutoring
practice of Ms. Amani. It is inspired by
[mrsalovesreading.com](https://www.mrsalovesreading.com). The marketing site that
inspired this has **no online booking** (visitors must email or call) — so the
headline feature here is a real, self-service **online booking system**.

## Features

**Public site**
- Landing page with hero, services, "Meet Ms. Amani", and testimonials
- Services listing + per-service detail pages (SEO-friendly `/services/{slug}` routes)
- About and Contact pages (contact form with validation)

**Online booking (3-step flow)**
1. **Choose a service** (Literacy Tutoring, Homeschool Support, Math, Free Assessment)
2. **Pick a day & time** — open slots are computed from configurable business hours and
   automatically exclude times that overlap existing bookings
3. **Enter details & confirm** — availability is re-checked on submit to prevent
   double-booking; free assessments auto-confirm, paid sessions are marked *Pending*

**Family intake form** (`/Intake`)
- Detailed intake form (child info, parent info, reading concerns, scheduling preferences)
- On submit: the submission is **persisted** and an **email is sent to Ms. Amani** with all
  details, Reply-To set to the family so she can respond directly
- Server-side validation + antiforgery; success page mirrors the original design

**Tutor admin** (`/Admin`, cookie-authenticated)
- Dashboard of all bookings with pending/upcoming counts
- Filter by status; update a booking's status (Pending → Confirmed → Completed / Cancelled)
- Family intakes view (`/Admin/Intakes`) listing every submission

## Architecture

| Layer | Implementation |
|-------|----------------|
| Web | ASP.NET Core 9 MVC (Razor views, Bootstrap 5 + Bootstrap Icons) |
| Data | Entity Framework Core 9 + SQLite (`booker.db`, auto-created & seeded on startup) |
| Domain | `Service`, `Booking` (+ `BookingStatus`), `Testimonial`, `IntakeSubmission` |
| Availability | `AvailabilityService` — slot generation from `BusinessHoursOptions` |
| Email | `IEmailSender` — `SmtpEmailSender` (MailKit) when configured, else `LoggingEmailSender` |
| Auth | Cookie authentication for a single admin (credentials in config) |

Key folders: `Controllers/`, `Models/`, `Views/`, `Data/` (DbContext + seeder),
`Services/` (availability logic).

## Running locally

```bash
dotnet run
```

Then open the URL printed in the console (e.g. `https://localhost:7xxx`). The SQLite
database is created and seeded automatically on first run.

**Admin login:** `/Account/Login` — `admin` / `ChangeMe123!`
(configured under `Admin` in `appsettings.json`).

## Configuration (`appsettings.json`)

- `ConnectionStrings:Default` — SQLite connection string
- `Admin:Username` / `Admin:Password` — tutor login (change before any real use)
- `BusinessHours` — open/close time, slot interval, working days, booking window,
  and minimum lead time used by the availability calculator
- `Email` — SMTP settings for intake notifications. **Leave `Host` blank** and the app
  logs the email instead of sending it (so it runs with no setup). To send real email,
  fill in your provider's SMTP details:

  ```json
  "Email": {
    "Host": "smtp.gmail.com",
    "Port": 587,
    "UseStartTls": true,
    "Username": "your-account@gmail.com",
    "Password": "your-app-password",
    "FromAddress": "noreply@rootedreaders.com",
    "FromName": "Rooted Readers Website",
    "ToAddress": "amani@rootedreaders.com",
    "ToName": "Ms. Amani"
  }
  ```

  `ToAddress` is where intake submissions are delivered.

### Keeping the recipient & secrets out of source control

`appsettings.json` only holds a placeholder `ToAddress`; the real recipient and any
SMTP credentials are supplied via **[user secrets](https://learn.microsoft.com/aspnet/core/security/app-secrets)**
(loaded automatically in the Development environment) or environment variables, and
override the file values at runtime:

```bash
dotnet user-secrets set "Email:ToAddress" "amani.willis96@gmail.com"
dotnet user-secrets set "Email:Host" "smtp.gmail.com"
dotnet user-secrets set "Email:Username" "your-account@gmail.com"
dotnet user-secrets set "Email:Password" "your-app-password"
```

In production, set the same keys as environment variables, e.g.
`Email__ToAddress=...` (double underscore = nested config).

## Notes / next steps for production

- Replace the demo admin login with **ASP.NET Core Identity**
- Configure the `Email` SMTP settings (above) so intake notifications are delivered;
  optionally add booking confirmation emails to families too
- Move from `EnsureCreated()` seeding to **EF Core migrations**
- Add payment collection (e.g. Stripe) for paid sessions
- Add a calendar/ICS export and reminder notifications
