// Please see documentation at https://learn.microsoft.com/aspnet/core/client-side/bundling-and-minification
// for details on configuring this project to bundle and minify static web assets.

// Auto-format phone inputs as "(123) 456-7890" while the user types.
(function () {
    function formatPhone(raw) {
        var digits = raw.replace(/\D/g, "");
        // Drop a leading US country code so 11-digit "1XXXXXXXXXX" still formats cleanly.
        if (digits.length === 11 && digits.charAt(0) === "1") {
            digits = digits.slice(1);
        }
        digits = digits.slice(0, 10);

        if (digits.length === 0) return "";
        if (digits.length < 4) return "(" + digits;
        if (digits.length < 7) return "(" + digits.slice(0, 3) + ") " + digits.slice(3);
        return "(" + digits.slice(0, 3) + ") " + digits.slice(3, 6) + "-" + digits.slice(6);
    }

    function attach(input) {
        var apply = function () { input.value = formatPhone(input.value); };
        input.addEventListener("input", apply);
        apply(); // normalize any value already present (e.g. on validation re-render)
    }

    document.addEventListener("DOMContentLoaded", function () {
        document.querySelectorAll('input[type="tel"]').forEach(attach);
    });
})();

// Gentle scroll-reveal for elements marked with .reveal. The hidden state is only
// applied once JS confirms it can undo it (body.reveal-ready), so content is never
// stuck invisible without JS or IntersectionObserver support.
(function () {
    if (!("IntersectionObserver" in window)) return;
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;

    document.addEventListener("DOMContentLoaded", function () {
        var els = document.querySelectorAll(".reveal");
        if (!els.length) return;
        document.body.classList.add("reveal-ready");

        var observer = new IntersectionObserver(function (entries) {
            entries.forEach(function (entry) {
                if (entry.isIntersecting) {
                    entry.target.classList.add("reveal-in");
                    observer.unobserve(entry.target);
                }
            });
        }, { rootMargin: "0px 0px -8% 0px" });

        els.forEach(function (el, i) {
            // Stagger siblings that share a row so cards cascade in.
            var siblingIndex = 0, prev = el.previousElementSibling;
            while (prev) {
                if (prev.classList.contains("reveal")) siblingIndex++;
                prev = prev.previousElementSibling;
            }
            el.style.setProperty("--reveal-delay", Math.min(siblingIndex, 5) * 70 + "ms");
            observer.observe(el);
        });
    });
})();
