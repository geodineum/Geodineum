# Geodineum

Geometric topology for the spatial web.

Geodineum is an ecosystem of components that power spatially-navigated websites — 3D cubes, 4D tesseracts, twisted toroids, or any geometry you can imagine. Built on WordPress, backed by a Rust topology engine and ValKey for sub-millisecond rendering.

## Quick Start

```bash
git clone https://github.com/geodineum/geodineum.git
cd geodineum
sudo ./install.sh
```

The installer walks you through choosing components and optionally deploying a WordPress site.

## Architecture

```
Child Theme (gCube / gTesseract / gIris / yours)
  └── gTemplate-wp (parent theme — bootstrap, rendering, REST, integrations)
      └── gCore (PHP framework — 18 managers, multi-platform)
          └── gNode-Client (PHP library — ValKey streams + topology)
              └── ValKey (storage + message broker)
                  └── gNode Daemon (Rust — topology engine, Tera templates)
```

## Components

| Component | Description | Required |
|-----------|-------------|----------|
| **gNode Daemon** | Rust topology engine, Tera template rendering, stream processor | For real-time features |
| **gNode-Client** | PHP library for daemon communication via ValKey streams | Yes |
| **gCore** | Manager-of-managers PHP framework (SEO, analytics, security, PWA, etc.) | Yes |
| **gTemplate-wp** | WordPress parent theme with 15+ filter hooks for child customization | Yes |
| **Your Theme** | Child theme defining geometry, layout HTML, and visual identity | Yes |

### Available Child Themes

| Theme | Geometry | Faces | Tech |
|-------|----------|-------|------|
| **gCube** | CSS 3D cube | 6 | CSS transforms, GPU-accelerated |
| **gTesseract** | CSS 4D tesseract | 8 | CSS 4D projection |
| **gIris** | Twisted hex toroid | 6 | Three.js + GSAP |

### Optional

| Component | Description |
|-----------|-------------|
| **gCore Premium** | 10 premium modules (advanced SEO, analytics, inference, comms) |
| **gNode-COMMS** | Notification daemon (email, Telegram, SMS) |
| **gShield** | Security templates and WAF rules |

## Installation Profiles

```bash
# Minimal — theme + framework, no daemon (free-tier mode)
sudo ./install.sh --profile minimal

# Standard — full stack with real-time rendering
sudo ./install.sh --profile standard

# Full — everything including premium modules
sudo ./install.sh --profile full
```

## Deploy a Site

```bash
# Install components + deploy WordPress site in one command
sudo ./install.sh --profile standard \
  --site geodineum.com \
  --theme giris \
  --env production
```

This handles: database, WordPress, Apache vhost, SSL (certbot), ValKey ACL, gCore MU-plugin, theme symlinks, gNode registration, and permission hardening (640/750, no world-readable).

## Create Your Own Theme

1. Clone this repo and run the installer to get the stack
2. Create a new directory for your theme
3. Add `style.css` with `Template: gtemplate-wp`
4. Add `functions.php` with your filter hooks:

```php
<?php
// Identity
add_filter('gtemplate_theme_prefix', fn() => 'mytheme');
add_filter('gtemplate_rest_namespace', fn() => 'mytheme/v1');
add_filter('gtemplate_face_count', fn() => 6);
add_filter('gtemplate_face_label', fn() => 'panel');
add_filter('gtemplate_customizer_face_prefix', fn() => 'mytheme_panel');

// Assets — register your geometry CSS/JS
add_filter('gtemplate_styles', function ($styles) {
    $styles['mytheme-geo'] = [
        'src' => get_stylesheet_directory_uri() . '/assets/css/geometry.css',
        'deps' => [], 'ver' => '1.0.0',
    ];
    return $styles;
});
```

5. Add `index.php` with your geometry HTML
6. Deploy: `sudo ./install.sh --site mysite.com --theme mytheme --theme-path /path/to/mytheme`

## Filter Hook API

The parent↔child contract is defined by these filters:

| Filter | Default | Purpose |
|--------|---------|---------|
| `gtemplate_face_count` | 6 | Number of navigable faces |
| `gtemplate_face_label` | 'face' | UI label (face, cell, section, panel) |
| `gtemplate_customizer_face_prefix` | 'gtemplate_face' | DB key prefix (zero migration) |
| `gtemplate_rest_namespace` | 'gtemplate/v1' | REST API namespace |
| `gtemplate_theme_prefix` | 'gtemplate' | Function/option prefix |
| `gtemplate_content_sources` | [...] | Content type handlers |
| `gtemplate_styles` | [] | CSS files to enqueue |
| `gtemplate_scripts` | [] | JS files to enqueue |
| `gtemplate_demo_content` | [...] | Default demo content |
| `gtemplate_js_settings` | [...] | Data passed to JS |
| `gtemplate_dynamic_css` | '' | Custom CSS variables |
| `gtemplate_register_customizer_sections` | action | Customizer sections |

## Requirements

- PHP 8.x with extensions: redis, json, mbstring
- Apache2
- MySQL / MariaDB
- WordPress 5.2+
- ValKey 7.2+ (for gNode features)
- Rust 1.70+ (to build gNode daemon)

## License

MIT
