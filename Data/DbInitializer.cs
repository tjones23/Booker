using Booker.Models;

namespace Booker.Data;

public static class DbInitializer
{
    public static void Seed(AppDbContext db)
    {
        db.Database.EnsureCreated();

        if (!db.Services.Any())
        {
            db.Services.AddRange(
                new Service
                {
                    Name = "Literacy Tutoring",
                    Slug = "literacy-tutoring",
                    Tagline = "One-on-one reading support rooted in the Science of Reading.",
                    Description = "Individualized sessions using Orton-Gillingham principles to build "
                        + "phonemic awareness, phonics, fluency, spelling, and writing. Ideal for "
                        + "students who are struggling with reading or who want to accelerate.",
                    DurationMinutes = 60,
                    Price = 380m,
                    SessionsPerMonth = 4,
                    Icon = "book-half",
                    SortOrder = 1
                },
                new Service
                {
                    Name = "Homeschool Literacy Support",
                    Slug = "homeschool-literacy-support",
                    Tagline = "Structured literacy instruction plus coaching for homeschool families.",
                    Description = "Direct instruction for your student paired with ongoing guidance for "
                        + "you as the educator, so you can confidently carry the Science of Reading "
                        + "methodology through the rest of your week.",
                    DurationMinutes = 60,
                    Price = 400m,
                    SessionsPerMonth = 4,
                    Icon = "house-heart",
                    SortOrder = 2
                },
                new Service
                {
                    Name = "Structured Math Foundations",
                    Slug = "structured-math-foundations",
                    Tagline = "Hands-on, multisensory math for grades K-4.",
                    Description = "Multisensory math instruction that emphasizes concrete, hands-on "
                        + "learning to build number sense and confidence for kindergarten through "
                        + "fourth grade.",
                    DurationMinutes = 60,
                    Price = 370m,
                    SessionsPerMonth = 4,
                    Icon = "calculator",
                    SortOrder = 3
                },
                new Service
                {
                    Name = "Free Reading Assessment",
                    Slug = "free-reading-assessment",
                    Tagline = "A no-cost first step to understand your child's needs.",
                    Description = "A relaxed 30-minute session to assess your student's current skills "
                        + "and discuss goals together. There's no obligation — it's simply the best "
                        + "way to see if we're a good fit.",
                    DurationMinutes = 30,
                    Price = 0m,
                    Icon = "clipboard-check",
                    SortOrder = 0
                });
            db.SaveChanges();
        }

        if (!db.Testimonials.Any())
        {
            db.Testimonials.AddRange(
                new Testimonial
                {
                    Author = "Jamie R.",
                    Relationship = "Parent of a 2nd grader",
                    Quote = "After one semester my daughter went from dreading books to reading "
                        + "bedtime stories to her little brother. Ms. Amani made all the difference.",
                    Rating = 5, SortOrder = 1
                },
                new Testimonial
                {
                    Author = "Daniel M.",
                    Relationship = "Homeschool dad",
                    Quote = "The coaching piece is gold. I finally understand *why* the phonics "
                        + "sequence matters, and our whole week runs more smoothly now.",
                    Rating = 5, SortOrder = 2
                },
                new Testimonial
                {
                    Author = "Priya S.",
                    Relationship = "Parent of a 4th grader",
                    Quote = "Math used to end in tears. The hands-on approach completely changed "
                        + "how my son sees himself as a learner.",
                    Rating = 5, SortOrder = 3
                });
            db.SaveChanges();
        }

        // A couple of demo bookings so the admin dashboard isn't empty.
        if (!db.Bookings.Any())
        {
            var literacy = db.Services.First(s => s.Slug == "literacy-tutoring");
            var assessment = db.Services.First(s => s.Slug == "free-reading-assessment");
            var baseDay = DateTime.Today.AddDays(2);

            db.Bookings.AddRange(
                new Booking
                {
                    ServiceId = literacy.Id,
                    ParentName = "Morgan Lee",
                    StudentName = "Ava Lee",
                    StudentGrade = "2nd grade",
                    Email = "morgan.lee@example.com",
                    Phone = "(970) 555-0142",
                    StartTime = baseDay.AddHours(10),
                    Status = BookingStatus.Confirmed,
                    Notes = "Working on short vowel sounds."
                },
                new Booking
                {
                    ServiceId = assessment.Id,
                    ParentName = "Chris Park",
                    StudentName = "Noah Park",
                    StudentGrade = "1st grade",
                    Email = "chris.park@example.com",
                    Phone = "(970) 555-0188",
                    StartTime = baseDay.AddDays(1).AddHours(15),
                    Status = BookingStatus.Pending
                });
            db.SaveChanges();
        }
    }
}
