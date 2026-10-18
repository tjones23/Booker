# Rooted Readers — Online Booking Site

An ASP.NET Core 9 MVC web application for Rooted Readers, the reading-tutoring
practice of Ms. Amani.

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

## Running and hosting (`run-dev.command` / `run-prod.command`)

Two launchers, in the style of Outside and WhatsGood. Double-click either in
Finder for a menu, or run them from a terminal (`./run-prod.command help` lists
every command). Both share `scripts/run-common.sh` and the app's port, **5080**
(not 5000: AirPlay Receiver has that on Monterey and later), so either can see
and stop what the other started.

- **`run-dev.command`**: `dotnet watch` with hot reload, the Development
  environment, `./booker.db`, and user secrets.
- **`run-prod.command`**: the published Release build (in `.booker/publish`),
  with settings and secrets from `.env` and the database in `~/booker-data`.
  It can host on this network, on the tailnet, or publicly, at
  **https://rootedreaders.haddock-sunfish.ts.net**.

Booker gets its own Tailscale node, `rootedreaders`: a userspace `tailscaled`
that only these scripts run, separate from the Mac's own Tailscale. Tailscale
terminates HTTPS and proxies to `127.0.0.1:5080`. Public access uses
[Funnel](https://tailscale.com/kb/1223/funnel), so nothing is opened on the router.

### First time on the server Mac

1. **Install the prerequisites:** the [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0)
   and `tailscaled` (`brew install tailscale`, or
   `go install tailscale.com/cmd/tailscale{,d}@latest` if Homebrew won't install it).
   Only run the binary; never `brew services start` it.
2. **Settings:** `cp .env.example .env` and fill it in. The scripts won't make
   the site public while the admin password is still the demo one.
3. **Tailnet:** in the [admin console](https://login.tailscale.com/admin), MagicDNS
   and HTTPS certificates must be on, and the policy must grant `funnel` (the
   default policy does).
4. Then:

   ```bash
   ./run-prod.command setup     # once: lets hosting keep a closed-lid Mac awake (asks for your password)
   ./run-prod.command rebuild   # publish the Release build
   ./run-prod.command public    # first run prints a login URL for the "rootedreaders" node
   ```

5. In the admin console, **disable key expiry** for `rootedreaders`. Otherwise the
   site drops off when the node's key expires.

### Day to day

- **Ship new code:** `git pull && ./run-prod.command rebuild`. The build is
  published beside the running one and swapped in only once it succeeds, so a
  failed build doesn't interrupt the site. If the new build won't start, the
  previous one is put back.
- **Check on it:** `./run-prod.command status` / `logs`
- **Go private:** `public off` keeps the site on the tailnet only. `stop`
  withdraws it everywhere.

After a reboot, the site stays down until `./run-prod.command public` is run again.

## Notes / next steps for production

- Replace the demo admin login with **ASP.NET Core Identity**
- Configure the `Email` SMTP settings (above) so intake notifications are delivered;
  optionally add booking confirmation emails to families too
- Move from `EnsureCreated()` seeding to **EF Core migrations**
- Add payment collection (e.g. Stripe) for paid sessions
- Add a calendar/ICS export and reminder notifications
