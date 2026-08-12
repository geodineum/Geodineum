<!doctype html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>{{DOMAIN}}</title>
    <link rel="stylesheet" href="/assets/site.css">
    <style>
        :root { color-scheme: light dark; }
        body { font-family: system-ui, sans-serif; max-width: 42rem; margin: 4rem auto; padding: 0 1rem; line-height: 1.6; }
        footer { margin-top: 4rem; font-size: .85rem; opacity: .7; }
    </style>
</head>
<body>
    <main>
        <h1>{{DOMAIN}}</h1>
        <p>This site was provisioned by Geodineum. Replace this page with your content.</p>
    </main>
    <footer>
        <p>Served from a Geodineum constellation.</p>
    </footer>
    <script>
        // Cookieless visitor beacon — aggregates only, no identifier stored.
        // Read back with: geodineum visitors {{SITE_ID}}
        (function () {
            try {
                var payload = JSON.stringify({ path: location.pathname, ref: document.referrer || '' });
                if (navigator.sendBeacon) {
                    navigator.sendBeacon('/g/hit.php', new Blob([payload], { type: 'application/json' }));
                } else {
                    fetch('/g/hit.php', { method: 'POST', body: payload, keepalive: true });
                }
            } catch (e) { /* analytics must never break the page */ }
        })();
    </script>
</body>
</html>
