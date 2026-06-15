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
